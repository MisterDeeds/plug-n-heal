<#
.SYNOPSIS
    Shared helper functions for the Plug'n'Heal action catalogue (toolbox/actions.json).

.DESCRIPTION
    Dot-sourced by lib/Toolbox.ps1 and lib/Diagnose.ps1. Defines functions only: nothing
    Windows-specific runs at load time, so the file loads in Windows PowerShell 5.1, in
    PowerShell 7 and on Linux (for tests).

    Catalogue scripts run in the same runspace and may call every function in this file.
    Rules for this file:
      - Evaluate exit codes, objects, registry values and XML only, never localized text.
      - The only deleting helper is Remove-PnhOldFile (temp folders, files older than N days).
      - Invoke-PnhNative honours the action deadline ($script:PnhActionDeadline) set by
        Invoke-PnhAction and kills the program when the deadline passes.

    Encoding: UTF-8 with BOM (Windows PowerShell 5.1 reads BOM-less files as ANSI).
#>

# Folder of this file (<app>\toolbox); captured at load time, used by Get-PnhToolboxDir.
$script:PnhToolboxDir = $PSScriptRoot

function Get-PnhToolboxDir {
    <#
    .SYNOPSIS
        Returns the toolbox folder (<app>\toolbox) that holds actions.json, categories.json,
        findings.json and this file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($script:PnhToolboxDir) { return $script:PnhToolboxDir }
    return $PSScriptRoot
}

function Get-PnhDriveRoot {
    <#
    .SYNOPSIS
        Returns the Plug'n'Heal root (X:\PlugNHeal). Uses Get-PnhRoot from Common.ps1 when it is
        loaded, otherwise two levels above the toolbox folder (<root>\app\toolbox).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (Get-Command -Name Get-PnhRoot -CommandType Function -ErrorAction SilentlyContinue) {
        try {
            $r = Get-PnhRoot
            if ($r) { return [string]$r }
        } catch {
            Write-Verbose "Get-PnhRoot failed: $($_.Exception.Message)"
        }
    }
    return (Split-Path -Path (Split-Path -Path (Get-PnhToolboxDir) -Parent) -Parent)
}

function Get-PnhBuildDate {
    <#
    .SYNOPSIS
        Date the drive was built (drive.json builtAt), else the catalogue date. Used to detect
        a clock that is certainly wrong (time before the build date).
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param()
    $fallback = [datetime]::new(2026, 11, 1)
    try {
        $dj = Join-Path (Get-PnhDriveRoot) 'drive.json'
        if (Test-Path -LiteralPath $dj) {
            $b = (Read-PnhStateJson -Path $dj).builtAt
            if ($b) { return [datetime]::Parse([string]$b, [Globalization.CultureInfo]::InvariantCulture) }
        }
        $cat = Join-Path (Get-PnhToolboxDir) 'actions.json'
        if (Test-Path -LiteralPath $cat) {
            $d = (Read-PnhStateJson -Path $cat).catalogDate
            if ($d) { return [datetime]::ParseExact([string]$d, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture) }
        }
    } catch {
        Write-Verbose "Get-PnhBuildDate: $($_.Exception.Message)"
    }
    return $fallback
}

# ------------------------------------------------------------------ platform and rights

function Test-PnhIsWindows {
    <#
    .SYNOPSIS
        Returns $true on Windows (Windows PowerShell 5.1 or PowerShell 7 on Windows).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if ($PSVersionTable.PSEdition -ne 'Core') { return $true }
    return [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
}

function Test-PnhElevated {
    <#
    .SYNOPSIS
        Returns $true if the current process runs with administrator rights (Windows only).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not (Test-PnhIsWindows)) { return $false }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-PnhOtherUserElevation {
    <#
    .SYNOPSIS
        Returns $true if this process runs as a different account than the one that owns the
        desktop (Explorer) in the same session, i.e. a layperson confirmed UAC with another
        administrator account. HKCU, sound and Explorer actions would then hit the wrong user.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not (Test-PnhIsWindows)) { return $false }
    try {
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $session = (Get-Process -Id $PID).SessionId
        $ex = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop |
                Where-Object { $_.SessionId -eq $session }) | Select-Object -First 1
        if (-not $ex) { return $false }
        $owner = Invoke-CimMethod -InputObject $ex -MethodName GetOwnerSid -ErrorAction Stop
        if (-not $owner.Sid) { return $false }
        return ($owner.Sid -ne $me)
    } catch {
        Write-Verbose "Test-PnhOtherUserElevation: $($_.Exception.Message)"
        return $false
    }
}

function Test-PnhManagedDevice {
    <#
    .SYNOPSIS
        Returns $true if the PC is managed by an organization: domain member, Entra ID joined,
        MDM enrolled or onboarded to Microsoft Defender for Endpoint. Registry and CIM only.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (-not (Test-PnhIsWindows)) { return $false }
    $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cs -and $cs.PartOfDomain) { return $true }
    if (@(Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo' -ErrorAction SilentlyContinue).Count) { return $true }
    $mdm = @(Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue |
            Where-Object { (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).UPN })
    if ($mdm.Count) { return $true }
    $atp = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection\Status' -ErrorAction SilentlyContinue
    return [bool]($atp -and $atp.OnboardingState -eq 1)
}

# ------------------------------------------------------------------ JSON files

function Write-PnhStateJson {
    <#
    .SYNOPSIS
        Writes an object as JSON (UTF-8) to a file. One-element arrays stay arrays.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()]$InputObject,
        [Parameter(Mandatory = $true)][string]$Path
    )
    $json = ConvertTo-Json -InputObject $InputObject -Depth 10
    [IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-PnhStateJson {
    <#
    .SYNOPSIS
        Reads a JSON file (UTF-8 with or without BOM) and returns the parsed object.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $text = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8)
    return (ConvertFrom-Json -InputObject $text)
}

# ------------------------------------------------------------------ native programs

function ConvertTo-PnhArgumentString {
    <#
    .SYNOPSIS
        Builds a Windows command line from single arguments (quoting rules of CommandLineToArgvW).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string[]]$ArgumentList = @())
    $parts = foreach ($arg in $ArgumentList) {
        if ($null -eq $arg -or $arg -eq '') { '""'; continue }
        if ($arg -notmatch '[\s"]') { $arg; continue }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('"')
        $slashes = 0
        foreach ($ch in $arg.ToCharArray()) {
            if ($ch -eq [char]'\') { $slashes++; continue }
            if ($ch -eq [char]'"') {
                [void]$sb.Append(('\' * (2 * $slashes + 1)))
                [void]$sb.Append('"')
            } else {
                if ($slashes) { [void]$sb.Append(('\' * $slashes)) }
                [void]$sb.Append($ch)
            }
            $slashes = 0
        }
        if ($slashes) { [void]$sb.Append(('\' * (2 * $slashes))) }
        [void]$sb.Append('"')
        $sb.ToString()
    }
    return (@($parts) -join ' ')
}

function Stop-PnhNativeProcess {
    <#
    .SYNOPSIS
        Kills a process and its children (used when a native program runs past its deadline).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal: only kills a process this module started.')]
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process)
    try {
        if (Test-PnhIsWindows) {
            $tk = Join-Path $env:SystemRoot 'System32\taskkill.exe'
            if (Test-Path -LiteralPath $tk) {
                $p = Start-Process -FilePath $tk -ArgumentList @('/PID', "$($Process.Id)", '/T', '/F') -WindowStyle Hidden -PassThru -Wait
                Write-Verbose "taskkill exit code $($p.ExitCode)"
            }
        }
        if (-not $Process.HasExited) { $Process.Kill() }
    } catch {
        Write-Verbose "Stop-PnhNativeProcess: $($_.Exception.Message)"
    }
}

function Invoke-PnhNative {
    <#
    .SYNOPSIS
        Runs a console program without a window and returns its exit code.

    .DESCRIPTION
        Output of console programs is localized, so callers evaluate only ExitCode/Ok.
        The program is killed when -TimeoutSeconds or the action deadline set by
        Invoke-PnhAction ($script:PnhActionDeadline) passes; then an exception is thrown.

    .OUTPUTS
        [pscustomobject]@{ ExitCode; Ok; Output (string[]) }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int[]]$OkExitCodes = @(0),
        [int]$TimeoutSeconds = 0
    )
    $limitMs = -1
    if ($TimeoutSeconds -gt 0) { $limitMs = $TimeoutSeconds * 1000 }
    $deadline = $script:PnhActionDeadline
    if ($deadline -is [datetime]) {
        $left = [int][math]::Max(1000, ($deadline - (Get-Date)).TotalMilliseconds)
        if ($limitMs -lt 0 -or $left -lt $limitMs) { $limitMs = $left }
    }
    if ($limitMs -lt 0) { $limitMs = 600000 }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ConvertTo-PnhArgumentString -ArgumentList $ArgumentList
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $timedOut = -not $proc.WaitForExit($limitMs)
    if ($timedOut) { Stop-PnhNativeProcess -Process $proc } else { $proc.WaitForExit() }
    $out = ''
    $err = ''
    if ($outTask.Wait(5000)) { $out = $outTask.Result }
    if ($errTask.Wait(5000)) { $err = $errTask.Result }
    $code = $(if ($timedOut) { -1 } else { $proc.ExitCode })
    $proc.Dispose()
    if ($timedOut) { throw ('Timed out after {0} s: {1}' -f [int]($limitMs / 1000), $FilePath) }
    $lines = @((($out + "`n" + $err) -split "\r?\n") | Where-Object { $_ -ne '' })
    return [pscustomobject]@{ ExitCode = $code; Ok = ($OkExitCodes -contains $code); Output = $lines }
}

# ------------------------------------------------------------------ registry backup

function Save-PnhRegKey {
    <#
    .SYNOPSIS
        Exports a registry key with reg.exe. If the key does not exist, writes <File>.absent.
    .OUTPUTS
        [bool] $true if exported, $false if the key was absent.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Key, [Parameter(Mandatory = $true)][string]$File)
    if (-not (Test-Path -LiteralPath ('Registry::' + $Key))) {
        [IO.File]::WriteAllText($File + '.absent', $Key)
        return $false
    }
    $r = Invoke-PnhNative -FilePath 'reg.exe' -ArgumentList @('export', $Key, $File, '/y')
    if (-not $r.Ok) { throw "reg export failed: $Key" }
    return $true
}

function Restore-PnhRegKey {
    <#
    .SYNOPSIS
        Restores a key saved by Save-PnhRegKey. If it was absent before, removes the key the
        action created (only that key, recorded in <File>.absent).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Key, [Parameter(Mandatory = $true)][string]$File)
    if (Test-Path -LiteralPath ($File + '.absent')) {
        $recorded = [IO.File]::ReadAllText($File + '.absent').Trim()
        if ($recorded -ne $Key) { throw "Backup marker does not match the key: $Key" }
        Remove-Item -LiteralPath ('Registry::' + $Key) -Recurse -Force -ErrorAction SilentlyContinue
        return
    }
    $r = Invoke-PnhNative -FilePath 'reg.exe' -ArgumentList @('import', $File)
    if (-not $r.Ok) { throw "reg import failed: $File" }
}

# ------------------------------------------------------------------ network tests (language independent)

function Get-PnhDefaultGateway {
    <#
    .SYNOPSIS
        Returns the IPv4 default gateway with the lowest metric, or $null.
    #>
    [CmdletBinding()]
    param()
    Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue |
        Sort-Object { $_.RouteMetric + $_.InterfaceMetric } |
        Select-Object -First 1 -ExpandProperty NextHop
}

function Test-PnhPing {
    <#
    .SYNOPSIS
        Pings a target and returns a language-independent result code.
    .DESCRIPTION
        11050 = IP_GENERAL_FAILURE ("General failure"): Windows did not send the packet at all.
        The .NET IPStatus enum does not know 11050, so the numeric value is evaluated.
    .OUTPUTS
        [pscustomobject]@{ Target; Code; Result } with Result SUCCESS, TIMED_OUT, GENERAL_FAILURE,
        NET_UNREACHABLE, HOST_UNREACHABLE or OTHER.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Target, [int]$TimeoutMs = 1000)
    $code = $null
    try {
        $reply = (New-Object System.Net.NetworkInformation.Ping).Send($Target, $TimeoutMs)
        $code = [int]$reply.Status
    } catch {
        $e = $_.Exception
        while ($e -and -not ($e -is [System.ComponentModel.Win32Exception])) { $e = $e.InnerException }
        if ($e) { $code = $e.NativeErrorCode } else { $code = -1 }
    }
    $name = switch ($code) {
        0 { 'SUCCESS' }
        11002 { 'NET_UNREACHABLE' }
        11003 { 'HOST_UNREACHABLE' }
        11010 { 'TIMED_OUT' }
        11050 { 'GENERAL_FAILURE' }
        1231 { 'NET_UNREACHABLE' }
        1232 { 'HOST_UNREACHABLE' }
        default { 'OTHER' }
    }
    return [pscustomobject]@{ Target = $Target; Code = $code; Result = $name }
}

function Test-PnhTcp {
    <#
    .SYNOPSIS
        Opens a TCP connection and returns a result code (CONNECTED, BLOCKED_LOCAL, TIMEOUT, ...).
    .DESCRIPTION
        10013 (WSAEACCES) while connecting means a local filter (WFP) refused the connection.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Target, [int]$Port = 443, [int]$TimeoutMs = 2000)
    $client = New-Object System.Net.Sockets.TcpClient
    $res = 'ERROR'
    try {
        $iar = $client.BeginConnect($Target, $Port, $null, $null)
        if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            try {
                $client.EndConnect($iar)
                $res = 'CONNECTED'
            } catch {
                $e = $_.Exception
                while ($e -and -not ($e -is [System.Net.Sockets.SocketException])) { $e = $e.InnerException }
                $code = $(if ($e) { $e.NativeErrorCode } else { -1 })
                $res = switch ($code) {
                    10013 { 'BLOCKED_LOCAL' }
                    10051 { 'NET_UNREACHABLE' }
                    10060 { 'TIMEOUT' }
                    10061 { 'REFUSED' }
                    10065 { 'HOST_UNREACHABLE' }
                    default { 'ERROR_' + $code }
                }
            }
        } else {
            $res = 'TIMEOUT'
        }
    } catch {
        $res = 'ERROR'
    } finally {
        $client.Close()
    }
    return [pscustomobject]@{ Target = $Target; Port = $Port; Result = $res }
}

function Test-PnhDns {
    <#
    .SYNOPSIS
        Resolves a name with DNS only (no hosts file, no cache when -Server is given).
    .OUTPUTS
        Result RESOLVED, NXDOMAIN (the server answered: DNS works), TIMEOUT or FAILED.
    #>
    [CmdletBinding()]
    param([string]$Name = 'www.msftconnecttest.com', [string]$Server)
    $q = @{ Name = $Name; Type = 'A'; DnsOnly = $true; QuickTimeout = $true; ErrorAction = 'Stop' }
    if ($Server) { $q['Server'] = $Server }
    try {
        $answers = @(Resolve-DnsName @q | Where-Object { "$($_.Type)" -eq 'A' })
        return [pscustomobject]@{ Name = $Name; Server = $Server; Result = $(if ($answers.Count) { 'RESOLVED' } else { 'NO_ANSWER' }); Code = 0; Count = $answers.Count }
    } catch {
        $code = $null
        $e = $_.Exception
        while ($e) {
            if ($e -is [System.ComponentModel.Win32Exception]) { $code = $e.NativeErrorCode; break }
            $e = $e.InnerException
        }
        $res = 'FAILED'
        if ($code -eq 9003) { $res = 'NXDOMAIN' } elseif ($code -eq 1460) { $res = 'TIMEOUT' }
        return [pscustomobject]@{ Name = $Name; Server = $Server; Result = $res; Code = $code; Count = 0 }
    }
}

function Get-PnhWinHttpProxyState {
    <#
    .SYNOPSIS
        Returns 'PROXY' if a WinHTTP (system) proxy is set, else 'DIRECT'. Reads the binary
        WinHttpSettings value (byte 8, bit 2) instead of the localized netsh output.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    $v = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Internet Settings\Connections' -Name WinHttpSettings -ErrorAction SilentlyContinue).WinHttpSettings
    if (-not $v -or $v.Length -lt 12) { return 'DIRECT' }
    if ($v[8] -band 2) { return 'PROXY' }
    return 'DIRECT'
}

function Get-PnhVpnPattern {
    <#
    .SYNOPSIS
        Regex of adapter/service names that belong to VPN software (heuristic).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    'TAP-|TAP Adapter|WireGuard|Wintun|OpenVPN|Fortinet|FortiClient|AnyConnect|Cisco|PANGP|GlobalProtect|Juniper|Pulse Secure|Ivanti|NordLynx|NordVPN|ProtonVPN|Mullvad|Surfshark|ExpressVPN|Cloudflare WARP|Tailscale|ZeroTier|Hamachi|SonicWall|Check Point|WatchGuard|Sophos|Zscaler|VPN'
}

function Get-PnhSecurityAgentPattern {
    <#
    .SYNOPSIS
        Regex of security agents whose adapters, filters or entries are never switched off.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    'Zscaler|Netskope|Forcepoint|Umbrella|Defender|Sense|CrowdStrike|SentinelOne|Sophos|Harmony|Check Point|Cloudflare One|Prisma|Cortex|Carbon Black|Cylance|ESET|Kaspersky|Bitdefender|Trend Micro|McAfee|Trellix|Symantec|Norton'
}

function Get-PnhWinsockProvider {
    <#
    .SYNOPSIS
        Lists Winsock catalogue providers from the registry (instead of localized netsh output).
    #>
    [CmdletBinding()]
    param()
    $msRx = '\\(mswsock|napinsp|pnrpnsp|winrnr|wshbth|nlansp_c|hvsocket|rsvpsp|wshqos|vmbussocks?)\.dll$'
    $base = 'HKLM:\SYSTEM\CurrentControlSet\Services\WinSock2\Parameters'
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($cat in 'Protocol_Catalog9\Catalog_Entries', 'Protocol_Catalog9\Catalog_Entries64') {
        foreach ($k in @(Get-ChildItem -Path (Join-Path $base $cat) -ErrorAction SilentlyContinue)) {
            $b = (Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).PackedCatalogItem
            if ($b) {
                $path = ([Text.Encoding]::ASCII.GetString($b, 0, [Math]::Min(260, $b.Length))).Split([char]0)[0]
                $out.Add([pscustomobject]@{ Catalog = 'Protocol'; Path = $path; Microsoft = ($path -match $msRx) })
            }
        }
    }
    foreach ($cat in 'NameSpace_Catalog5\Catalog_Entries', 'NameSpace_Catalog5\Catalog_Entries64') {
        foreach ($k in @(Get-ChildItem -Path (Join-Path $base $cat) -ErrorAction SilentlyContinue)) {
            $path = (Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue).LibraryPath
            if ($path) { $out.Add([pscustomobject]@{ Catalog = 'NameSpace'; Path = $path; Microsoft = ($path -match $msRx) }) }
        }
    }
    $out | Sort-Object Catalog, Path -Unique
}

# ------------------------------------------------------------------ IP configuration backup

function Backup-PnhIpConfig {
    <#
    .SYNOPSIS
        Saves the network configuration before a reset: netsh dump (Microsoft's way), registry
        export of Tcpip/Tcpip6 and a JSON of fixed settings per adapter GUID (robust if adapter
        names change).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Destination)
    $dump = Invoke-PnhNative -FilePath 'netsh.exe' -ArgumentList @('-c', 'interface', 'dump')
    if (-not $dump.Ok) { throw 'netsh interface dump failed' }
    [IO.File]::WriteAllLines((Join-Path $Destination 'netsh-interface-dump.txt'), [string[]]$dump.Output)
    [void](Save-PnhRegKey -Key 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -File (Join-Path $Destination 'tcpip-parameters.reg'))
    [void](Save-PnhRegKey -Key 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' -File (Join-Path $Destination 'tcpip6-parameters.reg'))
    $cfg = foreach ($a in @(Get-NetAdapter -ErrorAction SilentlyContinue)) {
        $ipif = Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $k = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($a.InterfaceGuid)"
        [pscustomobject]@{
            Name       = $a.Name
            Guid       = "$($a.InterfaceGuid)"
            Dhcp       = "$($ipif.Dhcp)"
            ManualIPv4 = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                    Where-Object { "$($_.PrefixOrigin)" -eq 'Manual' } |
                    ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" })
            Routes     = @(Get-NetRoute -InterfaceIndex $a.ifIndex -PolicyStore PersistentStore -ErrorAction SilentlyContinue |
                    ForEach-Object { "$($_.DestinationPrefix)|$($_.NextHop)|$($_.RouteMetric)" })
            ManualDns  = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).NameServer
        }
    }
    Write-PnhStateJson -InputObject @($cfg) -Path (Join-Path $Destination 'ip-config.json')
}

function Restore-PnhIpConfig {
    <#
    .SYNOPSIS
        Restores fixed (manual) IPv4 addresses, routes and DNS servers from Backup-PnhIpConfig.
        Adapters are matched by GUID.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Source)
    foreach ($c in @(Read-PnhStateJson -Path (Join-Path $Source 'ip-config.json'))) {
        $a = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { "$($_.InterfaceGuid)" -eq $c.Guid } | Select-Object -First 1
        if (-not $a) { continue }
        $ips = @($c.ManualIPv4 | Where-Object { $_ })
        if ($ips.Count) {
            Set-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -Dhcp Disabled
            foreach ($ip in $ips) {
                $parts = $ip -split '/'
                if (-not (Get-NetIPAddress -InterfaceIndex $a.ifIndex -IPAddress $parts[0] -ErrorAction SilentlyContinue)) {
                    New-NetIPAddress -InterfaceIndex $a.ifIndex -IPAddress $parts[0] -PrefixLength ([int]$parts[1]) | Out-Null
                }
            }
        }
        foreach ($rt in @($c.Routes | Where-Object { $_ })) {
            $f = $rt -split '\|'
            if (-not (Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix $f[0] -NextHop $f[1] -ErrorAction SilentlyContinue)) {
                New-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix $f[0] -NextHop $f[1] -RouteMetric ([int]$f[2]) | Out-Null
            }
        }
        if ($c.ManualDns) {
            Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses @($c.ManualDns -split '[ ,]+' | Where-Object { $_ })
        }
    }
}

function Test-PnhIpConfigRestored {
    <#
    .SYNOPSIS
        Returns $true if every fixed IPv4 address from the backup is present again.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][string]$Source)
    $missing = 0
    foreach ($c in @(Read-PnhStateJson -Path (Join-Path $Source 'ip-config.json'))) {
        foreach ($ip in @($c.ManualIPv4 | Where-Object { $_ })) {
            if (-not (Get-NetIPAddress -IPAddress ($ip -split '/')[0] -ErrorAction SilentlyContinue)) { $missing++ }
        }
    }
    return ($missing -eq 0)
}

function Find-PnhLatestBackup {
    <#
    .SYNOPSIS
        Finds the newest backup folder of given actions on this drive (this computer only),
        also in earlier runs (needed after a restart). Returns the folder path or $null.
    .PARAMETER RunFolder
        The current run folder (logs\<COMPUTERNAME>-<timestamp>); its parent is searched.
    .PARAMETER ActionId
        Action ids whose backup folders qualify (folder names end with -<id>).
    .PARAMETER File
        A file that must exist in the backup folder.
    .PARAMETER Before
        Only folders written before this time (excludes the current action's own folder).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$RunFolder,
        [Parameter(Mandatory = $true)][string[]]$ActionId,
        [Parameter(Mandatory = $true)][string]$File,
        [datetime]$Before = [datetime]::MaxValue
    )
    $logs = Split-Path -Path $RunFolder -Parent
    if (-not $logs -or -not (Test-Path -LiteralPath $logs)) { return $null }
    $machine = $(if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [Environment]::MachineName })
    $hits = foreach ($run in @(Get-ChildItem -LiteralPath $logs -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$machine-*" })) {
        $bk = Join-Path $run.FullName 'backups'
        foreach ($dir in @(Get-ChildItem -LiteralPath $bk -Directory -ErrorAction SilentlyContinue)) {
            $match = $false
            foreach ($id in $ActionId) { if ($dir.Name.EndsWith('-' + $id, [StringComparison]::OrdinalIgnoreCase)) { $match = $true } }
            if (-not $match) { continue }
            $f = Join-Path $dir.FullName $File
            if ((Test-Path -LiteralPath $f) -and ((Get-Item -LiteralPath $f).LastWriteTime -lt $Before)) {
                [pscustomobject]@{ Path = $dir.FullName; Time = (Get-Item -LiteralPath $f).LastWriteTime }
            }
        }
    }
    $best = @($hits) | Sort-Object Time -Descending | Select-Object -First 1
    if ($best) { return $best.Path }
    return $null
}

# ------------------------------------------------------------------ Windows Filtering Platform

function Get-PnhWfpDrop {
    <#
    .SYNOPSIS
        Evaluates "netsh wfp show netevents/filters/state" XML (not localized): which filter
        drops packets, and which provider it belongs to.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$NetEventsFile,
        [Parameter(Mandatory = $true)][string]$FiltersFile,
        [string]$StateFile
    )
    $x = New-Object System.Xml.XmlDocument
    $x.Load($NetEventsFile)
    $fx = New-Object System.Xml.XmlDocument
    $fx.Load($FiltersFile)
    $filters = @{}
    foreach ($i in $fx.SelectNodes('//filters/item')) {
        $idNode = $i.SelectSingleNode('filterId')
        if ($idNode) { $filters[$idNode.InnerText] = $i }
    }
    $providers = @{}
    if ($StateFile -and (Test-Path -LiteralPath $StateFile)) {
        $sx = New-Object System.Xml.XmlDocument
        $sx.Load($StateFile)
        foreach ($pv in $sx.SelectNodes('//providers/item')) {
            $key = $pv.SelectSingleNode('providerKey')
            $nm = $pv.SelectSingleNode('displayData/name')
            if ($key -and $nm) { $providers[$key.InnerText] = $nm.InnerText }
        }
    }
    $rows = foreach ($e in $x.SelectNodes('//netEvents/item')) {
        $typeNode = $e.SelectSingleNode('type')
        if (-not $typeNode -or $typeNode.InnerText -notmatch 'DROP') { continue }
        $fidNode = $e.SelectSingleNode('.//filterId')
        $fid = $(if ($fidNode) { $fidNode.InnerText } else { '' })
        $f = $filters[$fid]
        $pk = ''
        $fname = ''
        if ($f) {
            if ($f.SelectSingleNode('providerKey')) { $pk = $f.SelectSingleNode('providerKey').InnerText }
            if ($f.SelectSingleNode('displayData/name')) { $fname = $f.SelectSingleNode('displayData/name').InnerText }
        }
        $app = $e.SelectSingleNode('header/appId/asString')
        $remote = $e.SelectSingleNode('header/remoteAddrV4')
        [pscustomobject]@{
            FilterId = $fid
            Filter   = $fname
            Provider = $(if ($providers.ContainsKey($pk)) { $providers[$pk] } else { $pk })
            App      = $(if ($app) { Split-Path -Leaf $app.InnerText } else { '' })
            Remote   = $(if ($remote) { $remote.InnerText } else { '' })
        }
    }
    @($rows) | Group-Object FilterId, Filter, Provider | Sort-Object Count -Descending | ForEach-Object {
        $g = $_.Group[0]
        [pscustomobject]@{
            Count    = $_.Count
            FilterId = $g.FilterId
            Filter   = $g.Filter
            Provider = $g.Provider
            Apps     = (@($_.Group | Select-Object -ExpandProperty App -Unique) -join ',')
            Remotes  = (@($_.Group | Select-Object -ExpandProperty Remote -Unique | Select-Object -First 5) -join ',')
        }
    }
}

# ------------------------------------------------------------------ files (temp clean-up only)

function Get-PnhFileSafe {
    <#
    .SYNOPSIS
        Recursive file list that never follows junctions or symbolic links.
    .PARAMETER OlderThan
        Only files last written before this time.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path, [datetime]$OlderThan = [datetime]::MaxValue)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $stack = New-Object System.Collections.Stack
    $stack.Push($Path)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
            if ($item.PSIsContainer) { $stack.Push($item.FullName) }
            elseif ($item.LastWriteTime -lt $OlderThan) { $item }
        }
    }
}

function Get-PnhSizeMB {
    <#
    .SYNOPSIS
        Size of a folder in MB (rounded), without following links.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Path)
    $sum = (@(Get-PnhFileSafe -Path $Path) | Measure-Object -Property Length -Sum).Sum
    if (-not $sum) { return 0 }
    return [math]::Round($sum / 1MB, 0)
}

function Remove-PnhOldFile {
    <#
    .SYNOPSIS
        The only deleting helper: deletes files older than -Days in a Temp folder.

    .DESCRIPTION
        Refuses any path whose last segment is not Temp/Tmp and any path on the rescue drive.
        Writes the full list (path, size, date) to -ManifestFile before deleting. Never follows
        links (Get-PnhFileSafe). Files in use are skipped.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Called only by catalogue actions after the engine asked the user.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [ValidateRange(1, 3650)][int]$Days = 7,
        [Parameter(Mandatory = $true)][string]$ManifestFile,
        [string]$ProtectedRoot
    )
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '[\\/](Temp|Tmp)[\\/]?$') { throw "Path is not a temp folder: $full" }
    if ($ProtectedRoot) {
        $root = [IO.Path]::GetFullPath($ProtectedRoot)
        if ($full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw 'Path is on the rescue drive' }
    }
    $cut = (Get-Date).AddDays(-$Days)
    $files = @(Get-PnhFileSafe -Path $full -OlderThan $cut)
    $files | Select-Object FullName, Length, LastWriteTime | Export-Csv -LiteralPath $ManifestFile -NoTypeInformation -Encoding UTF8
    $freed = 0L
    $removed = 0
    $skipped = 0
    foreach ($f in $files) {
        try {
            Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop
            $freed += $f.Length
            $removed++
        } catch {
            $skipped++
        }
    }
    return [pscustomobject]@{ Path = $full; Removed = $removed; Skipped = $skipped; FreedMB = [math]::Round($freed / 1MB, 1) }
}

function Move-PnhToQuarantine {
    <#
    .SYNOPSIS
        Moves single files to the rescue drive (reversible) and writes manifest.csv.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string[]]$Paths, [Parameter(Mandatory = $true)][string]$Destination)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $manifest = New-Object System.Collections.Generic.List[object]
    foreach ($src in $Paths) {
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
        $rel = $src -replace '^[A-Za-z]:\\', ''
        $dst = Join-Path $Destination $rel
        New-Item -ItemType Directory -Path (Split-Path -Path $dst -Parent) -Force | Out-Null
        Move-Item -LiteralPath $src -Destination $dst -Force
        $manifest.Add([pscustomobject]@{ Source = $src; Target = $dst })
    }
    $manifest | Export-Csv -LiteralPath (Join-Path $Destination 'manifest.csv') -NoTypeInformation -Encoding UTF8
    $manifest
}

function Test-PnhProtectedStartup {
    <#
    .SYNOPSIS
        Returns $true for startup entries of security software (never disabled).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Name, [string]$Command)
    $rx = 'SecurityHealth|Windows Defender|Microsoft Defender|MSASCui|MsMpEng|avast|AVG|avira|bitdefender|eset|egui|ekrn|kaspersky|avp\.exe|norton|symantec|mcafee|sophos|trend ?micro|f-secure|malwarebytes|g ?data|panda|webroot|comodo|emsisoft|crowdstrike|sentinel|cylance|carbon ?black|forti|MsSense|SenseCE|zscaler|netskope'
    return (("$Name $Command") -match $rx)
}

# ------------------------------------------------------------------ Wi-Fi and radios

function Get-PnhWlanProfile {
    <#
    .SYNOPSIS
        Exports saved Wi-Fi profiles WITHOUT clear-text keys (the key stays encrypted and bound
        to this machine) into -WorkDir and reads the XML.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$WorkDir)
    New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    [void](Invoke-PnhNative -FilePath 'netsh.exe' -ArgumentList @('wlan', 'export', 'profile', ('folder=' + $WorkDir)))
    foreach ($f in @(Get-ChildItem -LiteralPath $WorkDir -Filter '*.xml' -ErrorAction SilentlyContinue)) {
        $x = New-Object System.Xml.XmlDocument
        $x.Load($f.FullName)
        $ns = New-Object System.Xml.XmlNamespaceManager($x.NameTable)
        $ns.AddNamespace('w', 'http://www.microsoft.com/networking/WLAN/profile/v1')
        $nameNode = $x.SelectSingleNode('/w:WLANProfile/w:name', $ns)
        $modeNode = $x.SelectSingleNode('/w:WLANProfile/w:connectionMode', $ns)
        $authNode = $x.SelectSingleNode('//w:authentication', $ns)
        [pscustomobject]@{
            Name = $(if ($nameNode) { $nameNode.InnerText } else { '' })
            Mode = $(if ($modeNode) { $modeNode.InnerText } else { '' })
            Auth = $(if ($authNode) { $authNode.InnerText } else { '' })
            File = $f.FullName
        }
    }
}

function Invoke-PnhAwait {
    <#
    .SYNOPSIS
        Waits for a WinRT async operation in Windows PowerShell 5.1.
    #>
    [CmdletBinding()]
    param($Operation, [Type]$ResultType)
    $m = [System.WindowsRuntimeSystemExtensions].GetMethods() |
        Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } |
        Select-Object -First 1
    $task = $m.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    [void]$task.Wait(10000)
    $task.Result
}

function Get-PnhRadio {
    <#
    .SYNOPSIS
        Radios (Wi-Fi, Bluetooth) via Windows.Devices.Radios (WinRT, Windows PowerShell 5.1 only).
    #>
    [CmdletBinding()]
    param()
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    [void][Windows.Devices.Radios.Radio,Windows.System.Devices,ContentType=WindowsRuntime]
    [void][Windows.Devices.Radios.RadioAccessStatus,Windows.System.Devices,ContentType=WindowsRuntime]
    [void](Invoke-PnhAwait ([Windows.Devices.Radios.Radio]::RequestAccessAsync()) ([Windows.Devices.Radios.RadioAccessStatus]))
    Invoke-PnhAwait ([Windows.Devices.Radios.Radio]::GetRadiosAsync()) ([System.Collections.Generic.IReadOnlyList[Windows.Devices.Radios.Radio]])
}

function Set-PnhRadioState {
    <#
    .SYNOPSIS
        Switches all radios of a kind on or off (WinRT).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Called only by catalogue actions after the engine asked the user.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][ValidateSet('WiFi', 'Bluetooth')][string]$Kind,
        [Parameter(Mandatory = $true)][ValidateSet('On', 'Off')][string]$State
    )
    foreach ($radio in @(Get-PnhRadio | Where-Object { "$($_.Kind)" -eq $Kind })) {
        [void](Invoke-PnhAwait ($radio.SetStateAsync($State)) ([Windows.Devices.Radios.RadioAccessStatus]))
    }
}

# ------------------------------------------------------------------ sound (Core Audio)

function Initialize-PnhAudio {
    <#
    .SYNOPSIS
        Compiles a tiny Core Audio (IAudioEndpointVolume) wrapper once per process.
        Fails under Constrained Language Mode (Add-Type blocked); callers catch that.
    #>
    [CmdletBinding()]
    param()
    if ('PnhAudio' -as [type]) { return }
    Add-Type -Language CSharp -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
[Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioEndpointVolume {
    int f(); int g(); int h(); int i();
    int SetMasterVolumeLevelScalar(float fLevel, Guid pguidEventContext);
    int j();
    int GetMasterVolumeLevelScalar(out float pfLevel);
    int k(); int l(); int m(); int n();
    int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, Guid pguidEventContext);
    int GetMute([MarshalAs(UnmanagedType.Bool)] out bool pbMute);
}
[Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice {
    int Activate(ref Guid id, int clsCtx, int activationParams, out IAudioEndpointVolume aev);
}
[Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator {
    int f();
    int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
}
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorComObject { }
public static class PnhAudio {
    static IAudioEndpointVolume Vol() {
        var enumerator = new MMDeviceEnumeratorComObject() as IMMDeviceEnumerator;
        IMMDevice dev = null;
        Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(0, 1, out dev));
        IAudioEndpointVolume epv = null;
        var epvid = typeof(IAudioEndpointVolume).GUID;
        Marshal.ThrowExceptionForHR(dev.Activate(ref epvid, 23, 0, out epv));
        return epv;
    }
    public static float GetVolume() { float v = -1; Marshal.ThrowExceptionForHR(Vol().GetMasterVolumeLevelScalar(out v)); return v; }
    public static void SetVolume(float v) { Marshal.ThrowExceptionForHR(Vol().SetMasterVolumeLevelScalar(v, Guid.Empty)); }
    public static bool GetMute() { bool m; Marshal.ThrowExceptionForHR(Vol().GetMute(out m)); return m; }
    public static void SetMute(bool m) { Marshal.ThrowExceptionForHR(Vol().SetMute(m, Guid.Empty)); }
}
'@
}

function Get-PnhAudioState {
    <#
    .SYNOPSIS
        Volume (0..1) and mute state of the default playback device.
    #>
    [CmdletBinding()]
    param()
    Initialize-PnhAudio
    return [pscustomobject]@{ Volume = [PnhAudio]::GetVolume(); Mute = [PnhAudio]::GetMute() }
}

function Set-PnhAudioState {
    <#
    .SYNOPSIS
        Sets volume (0..1) and/or mute of the default playback device.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Called only by catalogue actions after the engine asked the user.')]
    [CmdletBinding()]
    param([Nullable[double]]$Volume, [Nullable[bool]]$Mute)
    Initialize-PnhAudio
    if ($null -ne $Mute) { [PnhAudio]::SetMute([bool]$Mute) }
    if ($null -ne $Volume) { [PnhAudio]::SetVolume([float][math]::Min(1, [math]::Max(0, $Volume))) }
}

# ------------------------------------------------------------------ Defender package, logs, events

function Get-PnhDefenderPackage {
    <#
    .SYNOPSIS
        Defender definition package on the rescue drive: <Root>\packages\defender\mpam-fe.exe.
        File version = definition version. SignatureOk only for a valid Microsoft signature.
    #>
    [CmdletBinding()]
    param([string]$Root)
    if (-not $Root) { return $null }
    $f = Join-Path $Root 'packages\defender\mpam-fe.exe'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    $sig = Get-AuthenticodeSignature -LiteralPath $f
    return [pscustomobject]@{
        Path        = $f
        Version     = (Get-Item -LiteralPath $f).VersionInfo.FileVersion
        SignatureOk = ("$($sig.Status)" -eq 'Valid' -and $sig.SignerCertificate.Subject -match 'O=Microsoft Corporation')
    }
}

function Get-PnhCbsSrLine {
    <#
    .SYNOPSIS
        SFC lines ([SR]) from CBS.log since a point in time. CBS.log is not localized.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][datetime]$Since)
    $cbs = Join-Path $env:SystemRoot 'Logs\CBS\CBS.log'
    foreach ($m in @(Select-String -LiteralPath $cbs -Pattern '[SR]' -SimpleMatch -ErrorAction SilentlyContinue)) {
        $ts = [datetime]::MinValue
        if ($m.Line.Length -ge 19 -and [datetime]::TryParseExact($m.Line.Substring(0, 19), 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$ts)) {
            if ($ts -ge $Since) { $m.Line }
        }
    }
}

function Get-PnhEventData {
    <#
    .SYNOPSIS
        EventData of an event record as hashtable (field names are not localized).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Record)
    $d = @{}
    foreach ($n in @(([xml]$Record.ToXml()).Event.EventData.Data)) {
        if ($n -and $n.Name) { $d[$n.Name] = $n.'#text' }
    }
    return $d
}

# ------------------------------------------------------------------ restore points

function ConvertFrom-PnhDmtfDate {
    <#
    .SYNOPSIS
        Converts a WMI/DMTF date string (yyyyMMddHHmmss.ffffff+UUU) to local [datetime].
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value.Length -lt 14) { return $null }
    $dt = [datetime]::ParseExact($Value.Substring(0, 14), 'yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture)
    $offset = 0
    if ($Value.Length -ge 25) { [void][int]::TryParse($Value.Substring(21, 4), [ref]$offset) }
    $dto = New-Object DateTimeOffset($dt, [TimeSpan]::FromMinutes($offset))
    return $dto.LocalDateTime
}

function Get-PnhRestorePointList {
    <#
    .SYNOPSIS
        Restore points via CIM (root/default SystemRestore); works in PowerShell 5.1 and 7.
    .OUTPUTS
        [pscustomobject]@{ Sequence; Created ([datetime]); Description; Type }
    #>
    [CmdletBinding()]
    param()
    foreach ($rp in @(Get-CimInstance -Namespace 'root/default' -ClassName SystemRestore -ErrorAction Stop)) {
        [pscustomobject]@{
            Sequence    = [int]$rp.SequenceNumber
            Created     = ConvertFrom-PnhDmtfDate -Value "$($rp.CreationTime)"
            Description = $rp.Description
            Type        = [int]$rp.RestorePointType
        }
    }
}

function Test-PnhSystemProtection {
    <#
    .SYNOPSIS
        Returns $true if System Protection is on for the system drive.
    .DESCRIPTION
        Reads the SPP client registry value - a widely used but undocumented method. The real
        test is whether New-PnhRestorePoint succeeds.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    $v = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SPP\Clients' -ErrorAction SilentlyContinue).'{09F7EDC5-294E-4180-AF6A-FB0E6A0E9513}'
    return [bool](@($v) -match [regex]::Escape('(' + $env:SystemDrive.TrimEnd(':') + '%3A)'))
}
