<#
.SYNOPSIS
    Plug'n'Heal read-only diagnosis (facts + finding codes) and deterministic success checks.

.DESCRIPTION
    Contract: docs/ARCHITECTURE.md section 5.5.

      Invoke-PnhDiagnose [-Sections <string[]>]  -> @{Facts; Flags; DurationMs; Errors}
      Invoke-PnhSuccessCheck -Id <check id>     -> @{Passed; Details; Summary}

    Rules: read-only, offline-capable, under 30 seconds, compact output (short keys). Only exit
    codes, objects, registry values and XML are evaluated, never localized text. Every probe runs
    in its own try/catch; a failure is recorded under Errors and never aborts the diagnosis.
    Finding codes are derived from the facts by a pure function (Get-PnhDiagnoseFlags), so the
    rules are testable without Windows.

    This file only defines functions; nothing Windows-specific runs at load time.
    Encoding: UTF-8 with BOM.
#>

if (-not (Get-Command -Name Test-PnhPing -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path (Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'toolbox') 'helpers.ps1')
}

$script:PnhDiagnoseSections = @('system', 'network', 'security', 'disk', 'performance', 'printer', 'audio', 'update', 'display', 'events')
$script:PnhSuccessCheckIds = @('check.network', 'check.slow', 'check.disk', 'check.printer', 'check.sound', 'check.update', 'check.display', 'check.other', 'check.all')

# Thresholds shared by the C_FREE_* findings and check.disk / check.slow.
$script:PnhDiskCriticalBytes = 2GB
$script:PnhDiskLowBytes = 10GB
$script:PnhDiskLowPercent = 10
$script:PnhDiskPercentRuleMaxBytes = 30GB
$script:PnhUptimeLongHours = 168
$script:PnhPrintJobStuckMask = 2 -bor 32 -bor 64 -bor 512 -bor 1024   # Error, Offline, PaperOut, Blocked, UserIntervention

# ------------------------------------------------------------------ small helpers

function Invoke-PnhProbe {
    <#
    .SYNOPSIS
        Runs one measurement; on error records the message under -Errors[-Name] and returns nothing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name, [System.Collections.IDictionary]$Errors, [Parameter(Mandatory = $true)][scriptblock]$Script)
    # Non-terminating errors become exceptions, so they are recorded instead of leaking.
    $ErrorActionPreference = 'Stop'
    try {
        return (& $Script)
    } catch {
        if ($null -ne $Errors) { $Errors[$Name] = $_.Exception.Message }
        return
    }
}

function Get-PnhFact {
    <#
    .SYNOPSIS
        Reads a dotted path (e.g. 'network.test.gw') from nested hashtables or PSCustomObjects.
    #>
    [CmdletBinding()]
    param($Facts, [Parameter(Mandatory = $true)][string]$Path)
    $cur = $Facts
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $cur) { return $null }
        if ($cur -is [System.Collections.IDictionary]) {
            if ($cur.Contains($part)) { $cur = $cur[$part] } else { return $null }
        } else {
            $p = $cur.PSObject.Properties[$part]
            if ($p) { $cur = $p.Value } else { return $null }
        }
    }
    return $cur
}

function Test-PnhDiskSpaceLow {
    <#
    .SYNOPSIS
        Low disk space rule: under 10 GB free, or under 10 % free while under 30 GB free.
    .OUTPUTS
        'critical' (under 2 GB), 'low' or 'ok'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([double]$FreeBytes, [double]$SizeBytes)
    if ($FreeBytes -lt $script:PnhDiskCriticalBytes) { return 'critical' }
    $pct = $(if ($SizeBytes -gt 0) { 100 * $FreeBytes / $SizeBytes } else { 100 })
    if ($FreeBytes -lt $script:PnhDiskLowBytes) { return 'low' }
    if ($pct -lt $script:PnhDiskLowPercent -and $FreeBytes -lt $script:PnhDiskPercentRuleMaxBytes) { return 'low' }
    return 'ok'
}

function Get-PnhToolDriveLetter {
    <#
    .SYNOPSIS
        Drive letter of the rescue drive (never cleaned, marked in the facts).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    try { return (Split-Path -Path (Get-PnhDriveRoot) -Qualifier).TrimEnd(':').ToUpperInvariant() } catch { return '' }
}

function Test-PnhRebootPending {
    <#
    .SYNOPSIS
        Pending restart sources: CBS, WU (registry keys), PFRO (pending file renames).
    #>
    [CmdletBinding()]
    param()
    $pend = @()
    if (Test-Path -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $pend += 'CBS' }
    if (Test-Path -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $pend += 'WU' }
    if ((Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue).PendingFileRenameOperations) { $pend += 'PFRO' }
    return $pend
}

# ------------------------------------------------------------------ fact collectors (Windows)

function Get-PnhFactsSystem {
    <#
    .SYNOPSIS
        meta, os, hw, time, prof, rp, svc, dev, appx.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Facts is a set.')]
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Errors)
    $f = [ordered]@{}
    $f.meta = Invoke-PnhProbe 'system.meta' $Errors {
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        [ordered]@{
            ts         = (Get-Date).ToString('s')
            admin      = (Test-PnhElevated)
            user       = $me
            other_user = (Test-PnhOtherUserElevation)
            ui         = (Get-UICulture).Name
            ps         = $PSVersionTable.PSVersion.ToString()
            x64        = [Environment]::Is64BitProcess
            lang_mode  = "$($ExecutionContext.SessionState.LanguageMode)"
        }
    }
    $f.os = Invoke-PnhProbe 'system.os' $Errors {
        $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem
        $build = [int]$cv.CurrentBuild
        $hb = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -ErrorAction SilentlyContinue).HiberbootEnabled
        $entra = [bool]@(Get-ChildItem -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo' -ErrorAction SilentlyContinue).Count
        $mdm = [bool]@(Get-ChildItem -Path 'HKLM:\SOFTWARE\Microsoft\Enrollments' -ErrorAction SilentlyContinue |
                Where-Object { (Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction SilentlyContinue).UPN }).Count
        [ordered]@{
            name           = $(if ($build -ge 22000) { 'Windows 11' } else { 'Windows 10' })
            edition        = $cv.EditionID
            ver            = $(if ($cv.DisplayVersion) { $cv.DisplayVersion } else { $cv.ReleaseId })
            build          = "$($cv.CurrentBuild).$($cv.UBR)"
            server         = ([int]$os.ProductType -ne 1)
            lang           = (Get-Culture).Name
            boot           = $os.LastBootUpTime.ToString('s')
            uptime_h       = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
            pending_reboot = @(Test-PnhRebootPending)
            fast_startup   = ($hb -eq 1)
            domain         = [bool]$cs.PartOfDomain
            entra          = $entra
            mdm            = $mdm
        }
    }
    $f.hw = Invoke-PnhProbe 'system.hw' $Errors {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        [ordered]@{
            maker       = $cs.Manufacturer
            model       = $cs.Model
            ram_gb      = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
            ram_free_gb = [math]::Round($os.FreePhysicalMemory * 1KB / 1GB, 1)
            battery     = [bool](Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue)
        }
    }
    $f.time = Invoke-PnhProbe 'system.time' $Errors {
        $now = Get-Date
        $w = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters' -ErrorAction SilentlyContinue
        $newest = Get-WinEvent -LogName System -MaxEvents 1 -ErrorAction SilentlyContinue
        $future = [bool]($newest -and $newest.TimeCreated -gt $now.AddMinutes(10))
        [ordered]@{
            local       = $now.ToString('s')
            tz          = (Get-TimeZone).Id
            ntp_type    = $w.Type
            w32time     = "$((Get-Service -Name W32Time -ErrorAction SilentlyContinue).Status)"
            implausible = (($now -lt (Get-PnhBuildDate)) -or $future)
            future_ev   = $future
        }
    }
    $f.prof = Invoke-PnhProbe 'system.prof' $Errors {
        $pl = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
        $bak = @(Get-ChildItem -Path $pl -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -like '*.bak' } | ForEach-Object { $_.PSChildName })
        $tmp = [IO.Path]::GetTempPath()
        [ordered]@{
            temp_profile = ($env:USERPROFILE -match '\\Users\\TEMP(\.|$)')
            bak_keys     = $bak
            temp_ok      = (Test-Path -LiteralPath $tmp)
        }
    }
    $f.rp = Invoke-PnhProbe 'system.rp' $Errors {
        $last = $null
        if (Test-PnhElevated) {
            $p = @(Get-PnhRestorePointList | Sort-Object Sequence -Descending | Select-Object -First 1)
            if ($p.Count) { $last = $p[0].Created.ToString('s') }
        }
        [ordered]@{ on = (Test-PnhSystemProtection); last = $last }
    }
    $f.svc = @(Invoke-PnhProbe 'system.svc' $Errors {
            foreach ($n in 'Dhcp', 'Dnscache', 'NlaSvc', 'nsi', 'BFE', 'mpssvc', 'EventLog', 'Winmgmt', 'ProfSvc', 'Audiosrv', 'AudioEndpointBuilder', 'Spooler', 'CryptSvc', 'WlanSvc') {
                $s = Get-Service -Name $n -ErrorAction SilentlyContinue
                if ($s -and "$($s.Status)" -ne 'Running') { [ordered]@{ n = $n; st = "$($s.Status)"; start = "$($s.StartType)" } }
            }
        })
    $f.dev = @(Invoke-PnhProbe 'system.dev' $Errors {
            Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue | Where-Object { "$($_.Status)" -eq 'Error' } | Select-Object -First 15 | ForEach-Object {
                [ordered]@{ n = $_.FriendlyName; cls = $_.Class; code = $_.ConfigManagerErrorCode }
            }
        })
    $f.appx = @(Invoke-PnhProbe 'system.appx' $Errors {
            Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object { "$($_.Status)" -ne 'Ok' } | Select-Object -First 10 | ForEach-Object {
                [ordered]@{ n = $_.Name; st = "$($_.Status)" }
            }
        })
    return $f
}

function Get-PnhFactsNetwork {
    <#
    .SYNOPSIS
        Adapters, gateway, language-independent tests (lo/gw/ext/dns/tcp), proxy, hosts, VPN,
        split routes, NRPT, foreign Winsock providers and NDIS filters, radios.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Facts is a set.')]
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Errors)
    $f = [ordered]@{}
    $vpnRx = Get-PnhVpnPattern
    $f.ad = @(Invoke-PnhProbe 'network.ad' $Errors {
            foreach ($a in @(Get-NetAdapter -ErrorAction Stop)) {
                $ip4 = @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue)
                $dhcp = (Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp
                $k = "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($a.InterfaceGuid)"
                [ordered]@{
                    n          = $a.Name
                    d          = $a.InterfaceDescription
                    st         = "$($a.Status)"
                    hw         = [bool]$a.HardwareInterface
                    wifi       = (("$($a.PhysicalMediaType)" -match '802\.11') -or ($a.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN|802\.11'))
                    vpn        = (($a.InterfaceDescription -match $vpnRx) -or ($a.Name -match $vpnRx))
                    dhcp       = "$dhcp"
                    ip4        = @($ip4 | ForEach-Object { "$($_.IPAddress)/$($_.PrefixLength)" })
                    dns_manual = (Get-ItemProperty -Path $k -ErrorAction SilentlyContinue).NameServer
                }
            }
        })
    $f.gw = Invoke-PnhProbe 'network.gw' $Errors { Get-PnhDefaultGateway }
    $f.test = Invoke-PnhProbe 'network.test' $Errors {
        $gw = $f.gw
        $dnsSrv = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.ServerAddresses } | Select-Object -First 1 -ExpandProperty ServerAddresses)
        [ordered]@{
            lo  = (Test-PnhPing -Target '127.0.0.1').Result
            gw  = $(if ($gw) { (Test-PnhPing -Target $gw).Result } else { 'NO_GATEWAY' })
            ext = (Test-PnhPing -Target '1.1.1.1').Result
            dns = $(if ($dnsSrv) { (Test-PnhDns -Server $dnsSrv[0]).Result } else { 'NO_SERVER' })
            tcp = (Test-PnhTcp -Target '1.1.1.1' -Port 443).Result
        }
    }
    $f.proxy = Invoke-PnhProbe 'network.proxy' $Errors {
        $is = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
        [ordered]@{ user = [int]$is.ProxyEnable; server = $is.ProxyServer; pac = $is.AutoConfigURL; winhttp = (Get-PnhWinHttpProxyState) }
    }
    $f.hosts = Invoke-PnhProbe 'network.hosts' $Errors {
        @(Get-Content -Path (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts') -ErrorAction Stop | Where-Object { $_ -match '^\s*[^#\s]' }).Count
    }
    $f.vpn = @(Invoke-PnhProbe 'network.vpn' $Errors {
            @(@(Get-VpnConnection -ErrorAction SilentlyContinue) + @(Get-VpnConnection -AllUserConnection -ErrorAction SilentlyContinue)) | Where-Object { $_ } |
                ForEach-Object { [ordered]@{ n = $_.Name; st = "$($_.ConnectionStatus)" } }
        })
    $f.split = Invoke-PnhProbe 'network.split' $Errors { @(Get-NetRoute -DestinationPrefix '0.0.0.0/1', '128.0.0.0/1' -ErrorAction SilentlyContinue).Count }
    $f.nrpt = Invoke-PnhProbe 'network.nrpt' $Errors { @(Get-DnsClientNrptPolicy -Effective -ErrorAction SilentlyContinue).Count }
    $f.lsp = @(Invoke-PnhProbe 'network.lsp' $Errors { Get-PnhWinsockProvider | Where-Object { -not $_.Microsoft } | ForEach-Object { $_.Path } })
    $f.ndis = @(Invoke-PnhProbe 'network.ndis' $Errors {
            Get-NetAdapterBinding -AllBindings -IncludeHidden -ErrorAction SilentlyContinue |
                Where-Object { $_.Enabled -and $_.ComponentID -notlike 'ms_*' } | Select-Object -ExpandProperty DisplayName -Unique
        })
    $f.radio = @(Invoke-PnhProbe 'network.radio' $Errors { Get-PnhRadio | ForEach-Object { [ordered]@{ k = "$($_.Kind)"; s = "$($_.State)" } } })
    $f.wlansvc = Invoke-PnhProbe 'network.wlansvc' $Errors { "$((Get-Service -Name WlanSvc -ErrorAction SilentlyContinue).Status)" }
    return $f
}

function Get-PnhFactsSecurity {
    <#
    .SYNOPSIS
        Defender state, other antivirus, threats (30 days), firewall profiles, Defender for
        Endpoint hints, BitLocker status (never keys).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Facts is a set.')]
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Errors)
    $f = [ordered]@{}
    $f.av = Invoke-PnhProbe 'security.av' $Errors {
        $mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
        $products = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName AntiVirusProduct -ErrorAction Stop | ForEach-Object { $_.displayName })
        $thr = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -gt (Get-Date).AddDays(-30) })
        [ordered]@{
            mode       = "$($mp.AMRunningMode)"
            rtp        = $mp.RealTimeProtectionEnabled
            sig_age_d  = $mp.AntivirusSignatureAge
            sig_ver    = $mp.AntivirusSignatureVersion
            tamper     = $mp.IsTamperProtected
            qscan_age  = $mp.QuickScanAge
            products   = $products
            threats30d = $thr.Count
        }
    }
    $f.fw = @(Invoke-PnhProbe 'security.fw' $Errors {
            Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop | ForEach-Object {
                [ordered]@{ p = "$($_.Name)"; on = "$($_.Enabled)"; out = "$($_.DefaultOutboundAction)" }
            }
        })
    $f.fw_products = @(Invoke-PnhProbe 'security.fw_products' $Errors {
            Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName FirewallProduct -ErrorAction SilentlyContinue | ForEach-Object { $_.displayName }
        })
    $f.mde = Invoke-PnhProbe 'security.mde' $Errors {
        $k = 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection'
        $st = Get-ItemProperty -Path "$k\Status" -ErrorAction SilentlyContinue
        [ordered]@{
            onboarded = [bool]($st -and $st.OnboardingState -eq 1)
            sense     = "$((Get-Service -Name Sense -ErrorAction SilentlyContinue).Status)"
            org       = $st.OrgId
            iso_hint  = [bool](Get-ItemProperty -Path $k -Name 'DisableEnterpriseAuthProxyValueToRestoreAfterIsolation' -ErrorAction SilentlyContinue)
        }
    }
    $f.bl = Invoke-PnhProbe 'security.bl' $Errors {
        if (-not (Test-PnhElevated)) { return 'needs_admin' }
        $b = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        [ordered]@{
            status     = "$($b.VolumeStatus)"
            prot       = "$($b.ProtectionStatus)"
            pct        = $b.EncryptionPercentage
            protectors = @($b.KeyProtector | ForEach-Object { "$($_.KeyProtectorType)" })
        }
    }
    return $f
}

function Get-PnhFactsDisk {
    <#
    .SYNOPSIS
        Fixed volumes (free space, health, system/rescue drive marked) and physical disks.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Facts is a set.')]
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Errors)
    $f = [ordered]@{}
    $sys = "$env:SystemDrive".TrimEnd(':').ToUpperInvariant()
    $tool = Get-PnhToolDriveLetter
    $f.vol = @(Invoke-PnhProbe 'disk.vol' $Errors {
            Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter -and "$($_.DriveType)" -eq 'Fixed' } | ForEach-Object {
                $l = "$($_.DriveLetter)".ToUpperInvariant()
                [ordered]@{
                    l        = $l
                    sys      = ($l -eq $sys)
                    tool     = ($l -eq $tool)
                    fs       = $_.FileSystemType
                    size_gb  = [math]::Round($_.Size / 1GB, 1)
                    free_gb  = [math]::Round($_.SizeRemaining / 1GB, 1)
                    free_pct = $(if ($_.Size) { [math]::Round(100 * $_.SizeRemaining / $_.Size, 1) } else { $null })
                    health   = "$($_.HealthStatus)"
                    op       = "$($_.OperationalStatus)"
                }
            }
        })
    $f.phys = @(Invoke-PnhProbe 'disk.phys' $Errors {
            Get-PhysicalDisk -ErrorAction Stop | ForEach-Object {
                [ordered]@{
                    name    = $_.FriendlyName
                    media   = "$($_.MediaType)"
                    bus     = "$($_.BusType)"
                    health  = "$($_.HealthStatus)"
                    op      = "$($_.OperationalStatus -join ',')"
                    size_gb = [math]::Round($_.Size / 1GB, 0)
                }
            }
        })
    return $f
}

function Get-PnhFactsPerformance {
    <#
    .SYNOPSIS
        Uptime, memory, CPU load, biggest memory users, number of autostart entries.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Facts is a set.')]
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Errors)
    $f = [ordered]@{}
    $base = Invoke-PnhProbe 'performance.base' $Errors {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        [ordered]@{
            uptime_h    = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
            ram_gb      = [math]::Round($os.TotalVisibleMemorySize * 1KB / 1GB, 1)
            ram_free_gb = [math]::Round($os.FreePhysicalMemory * 1KB / 1GB, 1)
        }
    }
    if ($base) { foreach ($k in $base.Keys) { $f[$k] = $base[$k] } }
    $f.cpu_pct = Invoke-PnhProbe 'performance.cpu' $Errors {
        [math]::Round((@(Get-CimInstance -ClassName Win32_Processor -ErrorAction Stop) | Measure-Object -Property LoadPercentage -Average).Average, 0)
    }
    $f.top_mem = @(Invoke-PnhProbe 'performance.top_mem' $Errors {
            Get-Process -ErrorAction Stop | Sort-Object WorkingSet64 -Descending | Select-Object -First 5 | ForEach-Object { "$($_.ProcessName)=$([math]::Round($_.WorkingSet64 / 1MB))MB" }
        })
    $f.autostart = Invoke-PnhProbe 'performance.autostart' $Errors {
        $n = 0
        foreach ($k in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run') {
            $i = Get-Item -Path $k -ErrorAction SilentlyContinue
            if ($i) { $n += $i.ValueCount }
        }
        $n += @(Get-ChildItem -LiteralPath ([Environment]::GetFolderPath('Startup')), ([Environment]::GetFolderPath('CommonStartup')) -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' }).Count
        $n
    }
    return $f
}

function Get-PnhFactsPrinter {
    <#
    .SYNOPSIS
        Spooler state, printers, jobs and stuck jobs (Win32_PrintJob.StatusMask, numeric).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Facts is a set.')]
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Errors)
    $f = [ordered]@{}
    $sp = Invoke-PnhProbe 'printer.spooler' $Errors { Get-Service -Name Spooler -ErrorAction Stop }
    $f.spooler = "$($sp.Status)"
    $f.spooler_start = "$($sp.StartType)"
    if ("$($sp.Status)" -eq 'Running') {
        $jobs = @(Invoke-PnhProbe 'printer.jobs' $Errors { Get-CimInstance -ClassName Win32_PrintJob -ErrorAction Stop })
        $f.printers = @(Invoke-PnhProbe 'printer.list' $Errors {
                Get-CimInstance -ClassName Win32_Printer -ErrorAction Stop | ForEach-Object {
                    $name = $_.Name
                    $mine = @($jobs | Where-Object { $_.Name -and $_.Name.Substring(0, [math]::Max(0, $_.Name.LastIndexOf(','))) -eq $name })
                    $stuck = @($mine | Where-Object { ([int]$_.StatusMask -band $script:PnhPrintJobStuckMask) -or ($_.TimeSubmitted -and $_.TimeSubmitted -lt (Get-Date).AddHours(-2)) })
                    [ordered]@{ n = $name; def = [bool]$_.Default; offline = [bool]$_.WorkOffline; net = [bool]$_.Network; jobs = $mine.Count; stuck = $stuck.Count }
                }
            })
    } else {
        $f.printers = @()
    }
    return $f
}

function Get-PnhFactsAudio {
    <#
    .SYNOPSIS
        Audio services, endpoints and default device volume/mute (Core Audio; empty under
        Constrained Language Mode).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Facts is a set.')]
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Errors)
    $f = [ordered]@{}
    $f.svc = @(Invoke-PnhProbe 'audio.svc' $Errors {
            Get-Service -Name Audiosrv, AudioEndpointBuilder -ErrorAction Stop | ForEach-Object { [ordered]@{ n = $_.Name; st = "$($_.Status)" } }
        })
    $f.endpoints = @(Invoke-PnhProbe 'audio.endpoints' $Errors {
            Get-PnpDevice -Class AudioEndpoint -PresentOnly -ErrorAction Stop | Select-Object -First 10 | ForEach-Object { [ordered]@{ n = $_.FriendlyName; st = "$($_.Status)" } }
        })
    $st = Invoke-PnhProbe 'audio.volume' $Errors { Get-PnhAudioState }
    $f.vol_pct = $(if ($st) { [math]::Round($st.Volume * 100) } else { $null })
    $f.mute = $(if ($st) { [bool]$st.Mute } else { $null })
    return $f
}

function Get-PnhFactsUpdate {
    <#
    .SYNOPSIS
        Windows Update services, last hotfix, pause, policy, errors in 30 days (event 20 count).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Facts is a set.')]
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Errors)
    $f = [ordered]@{}
    $f.svc = @(Invoke-PnhProbe 'update.svc' $Errors {
            foreach ($n in 'wuauserv', 'BITS', 'CryptSvc', 'UsoSvc') {
                $s = Get-Service -Name $n -ErrorAction SilentlyContinue
                if ($s) { [ordered]@{ n = $n; st = "$($s.Status)"; start = "$($s.StartType)" } }
            }
        })
    $last = Invoke-PnhProbe 'update.last' $Errors { Get-HotFix -ErrorAction Stop | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1 }
    $f.last_kb = $(if ($last) { $last.HotFixID } else { $null })
    $f.last_kb_date = $(if ($last) { $last.InstalledOn.ToString('yyyy-MM-dd') } else { $null })
    $f.paused_until = Invoke-PnhProbe 'update.pause' $Errors { (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -ErrorAction SilentlyContinue).PauseUpdatesExpiryTime }
    $f.policy = Invoke-PnhProbe 'update.policy' $Errors { Test-Path -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' }
    $f.fail_30d = Invoke-PnhProbe 'update.fail' $Errors {
        @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-WindowsUpdateClient/Operational'; Id = 20; StartTime = (Get-Date).AddDays(-30) } -MaxEvents 50 -ErrorAction SilentlyContinue).Count
    }
    return $f
}

function Get-PnhFactsDisplay {
    <#
    .SYNOPSIS
        Graphics adapters (driver, problem code, basic display driver) and monitors.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Facts is a set.')]
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Errors)
    $f = [ordered]@{}
    $f.adapters = @(Invoke-PnhProbe 'display.adapters' $Errors {
            Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop | ForEach-Object {
                [ordered]@{
                    n      = $_.Name
                    drv    = $_.DriverVersion
                    date   = $(if ($_.DriverDate) { $_.DriverDate.ToString('yyyy-MM-dd') } else { $null })
                    cm_err = $_.ConfigManagerErrorCode
                    basic  = ("$($_.InfFilename)" -eq 'display.inf')
                    res    = "$($_.CurrentHorizontalResolution)x$($_.CurrentVerticalResolution)"
                }
            }
        })
    $f.monitors = Invoke-PnhProbe 'display.monitors' $Errors { @(Get-PnpDevice -Class Monitor -PresentOnly -ErrorAction Stop).Count }
    return $f
}

function Get-PnhFactsEvents {
    <#
    .SYNOPSIS
        Counters of known error patterns (by provider and event id) and the 15 most frequent
        errors of the last 7 days.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Facts is a set.')]
    [CmdletBinding()]
    param([System.Collections.IDictionary]$Errors, [int]$Days = 7)
    $f = [ordered]@{ days = $Days }
    $since = (Get-Date).AddDays(-$Days)
    $sysEv = @(Invoke-PnhProbe 'events.system' $Errors { Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2, 3; StartTime = $since } -MaxEvents 4000 -ErrorAction SilentlyContinue })
    $appEv = @(Invoke-PnhProbe 'events.application' $Errors { Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Level = 1, 2, 3; StartTime = $since } -MaxEvents 2000 -ErrorAction SilentlyContinue })
    $count = {
        param($List, [string]$Provider, [int[]]$Ids)
        @($List | Where-Object { $_.ProviderName -like $Provider -and $Ids -contains $_.Id }).Count
    }
    $f.known = [ordered]@{
        unexpected_shutdown = (& $count $sysEv 'Microsoft-Windows-Kernel-Power' 41) + (& $count $sysEv 'EventLog' 6008)
        bugcheck            = & $count $sysEv 'Microsoft-Windows-WER-SystemErrorReporting' 1001
        disk                = & $count $sysEv 'disk' 7, 51, 153
        ntfs                = & $count $sysEv '*Ntfs' 55, 98
        tdr                 = & $count $sysEv 'Display' 4101
        whea_fatal          = & $count $sysEv 'Microsoft-Windows-WHEA-Logger' 1, 18, 20
        whea_corrected      = & $count $sysEv 'Microsoft-Windows-WHEA-Logger' 17, 19, 47
        svc_fail            = & $count $sysEv 'Service Control Manager' 7000, 7001, 7009, 7011, 7023, 7031, 7034
        dns_timeout         = & $count $sysEv 'Microsoft-Windows-DNS-Client' 1014
        profile_temp        = & $count $appEv 'Microsoft-Windows-User Profiles Service' 1511, 1515
        app_crash           = & $count $appEv 'Application Error' 1000
        app_hang            = & $count $appEv 'Application Hang' 1002
    }
    $f.top = @(@($sysEv + $appEv | Where-Object { $_.Level -le 2 }) | Group-Object ProviderName, Id | Sort-Object Count -Descending | Select-Object -First 15 | ForEach-Object {
            $g = @($_.Group | Sort-Object TimeCreated -Descending)
            [ordered]@{ src = $g[0].ProviderName; id = $g[0].Id; n = $_.Count; last = $g[0].TimeCreated.ToString('s') }
        })
    return $f
}

function Get-PnhSectionFacts {
    <#
    .SYNOPSIS
        Dispatches one diagnosis section to its collector.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Facts is a set.')]
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name, [System.Collections.IDictionary]$Errors)
    switch ($Name) {
        'system' { return (Get-PnhFactsSystem -Errors $Errors) }
        'network' { return (Get-PnhFactsNetwork -Errors $Errors) }
        'security' { return (Get-PnhFactsSecurity -Errors $Errors) }
        'disk' { return (Get-PnhFactsDisk -Errors $Errors) }
        'performance' { return (Get-PnhFactsPerformance -Errors $Errors) }
        'printer' { return (Get-PnhFactsPrinter -Errors $Errors) }
        'audio' { return (Get-PnhFactsAudio -Errors $Errors) }
        'update' { return (Get-PnhFactsUpdate -Errors $Errors) }
        'display' { return (Get-PnhFactsDisplay -Errors $Errors) }
        'events' { return (Get-PnhFactsEvents -Errors $Errors) }
        default { throw "Unknown diagnosis section: $Name" }
    }
}

# ------------------------------------------------------------------ finding codes (pure)

function Get-PnhDiagnoseFlags {
    <#
    .SYNOPSIS
        Derives the finding codes (toolbox\findings.json) from the facts. Pure function: no system
        access, so every rule is unit-tested. Missing facts never produce a finding.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns a set of codes.')]
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Facts)
    $flags = New-Object System.Collections.Generic.List[string]
    $add = { param($c) if (-not $flags.Contains($c)) { $flags.Add($c) } }
    $F = { param($p) Get-PnhFact -Facts $Facts -Path $p }

    # system
    if ((& $F 'system.meta.admin') -eq $false) { & $add 'NOT_ADMIN' }
    if ((& $F 'system.meta.other_user') -eq $true) { & $add 'ELEVATED_OTHER_USER' }
    if ((& $F 'system.os.domain') -eq $true -or (& $F 'system.os.entra') -eq $true -or (& $F 'system.os.mdm') -eq $true) { & $add 'MANAGED_DEVICE' }
    $pend = @(& $F 'system.os.pending_reboot')
    if ($pend -contains 'CBS' -or $pend -contains 'WU') { & $add 'PENDING_REBOOT' }
    $up = & $F 'system.os.uptime_h'
    if ($null -eq $up) { $up = & $F 'performance.uptime_h' }
    if ($null -ne $up -and [double]$up -gt $script:PnhUptimeLongHours) { & $add 'UPTIME_LONG' }
    $svc = @(@(& $F 'system.svc') | Where-Object { $_ } | ForEach-Object { [string](Get-PnhFact $_ 'n') })
    if (@($svc | Where-Object { $_ -in @('Dhcp', 'Dnscache', 'NlaSvc', 'nsi') }).Count) { & $add 'NET_SERVICE_STOPPED' }
    if (@($svc | Where-Object { $_ -in @('BFE', 'mpssvc') }).Count) { & $add 'FIREWALL_SERVICE_STOPPED' }
    if (@($svc | Where-Object { $_ -in @('Audiosrv', 'AudioEndpointBuilder') }).Count) { & $add 'AUDIO_SERVICE_STOPPED' }
    if ($svc -contains 'Spooler') { & $add 'SPOOLER_STOPPED' }
    if ((& $F 'system.time.implausible') -eq $true) { & $add 'TIME_IMPLAUSIBLE' }
    if ((& $F 'system.time.ntp_type') -eq 'NoSync') { & $add 'W32TIME_NOSYNC' }
    if ((& $F 'system.prof.temp_profile') -eq $true -or @(& $F 'system.prof.bak_keys' | Where-Object { $_ }).Count) { & $add 'TEMP_PROFILE' }
    if ((& $F 'system.prof.temp_ok') -eq $false) { & $add 'TEMP_DIR_MISSING' }
    if ((& $F 'system.rp.on') -eq $false -and (& $F 'system.os.server') -ne $true) { & $add 'RESTORE_OFF' }
    if (@(& $F 'system.dev' | Where-Object { $_ }).Count) { & $add 'DEVICE_ERRORS' }
    if (@(& $F 'system.appx' | Where-Object { $_ }).Count) { & $add 'APPX_BROKEN' }

    # disk
    foreach ($v in @(& $F 'disk.vol' | Where-Object { $_ })) {
        if ((Get-PnhFact $v 'tool') -eq $true) { continue }
        if ((Get-PnhFact $v 'sys') -eq $true) {
            $free = [double](Get-PnhFact $v 'free_gb') * 1GB
            $size = [double](Get-PnhFact $v 'size_gb') * 1GB
            $state = Test-PnhDiskSpaceLow -FreeBytes $free -SizeBytes $size
            if ($state -eq 'critical') { & $add 'C_FREE_CRITICAL'; & $add 'C_FREE_LOW' }
            elseif ($state -eq 'low') { & $add 'C_FREE_LOW' }
        }
        $h = [string](Get-PnhFact $v 'health')
        $o = [string](Get-PnhFact $v 'op')
        if (($h -and $h -ne 'Healthy') -or ($o -and $o -ne 'OK')) { & $add 'VOLUME_NOT_HEALTHY' }
    }
    foreach ($p in @(& $F 'disk.phys' | Where-Object { $_ })) {
        $h = [string](Get-PnhFact $p 'health')
        if ($h -and $h -ne 'Healthy') { & $add 'DISK_UNHEALTHY' }
    }

    # network
    $ads = @(& $F 'network.ad' | Where-Object { $_ })
    if ($ads.Count) {
        $upAds = @($ads | Where-Object { (Get-PnhFact $_ 'st') -eq 'Up' })
        if (-not @($upAds | Where-Object { (Get-PnhFact $_ 'vpn') -ne $true }).Count) { & $add 'NO_ADAPTER_UP' }
        if (@($ads | Where-Object { (Get-PnhFact $_ 'st') -eq 'Disabled' -and (Get-PnhFact $_ 'hw') -eq $true }).Count) { & $add 'ADAPTER_DISABLED' }
        foreach ($a in $upAds) {
            $ips = @(Get-PnhFact $a 'ip4' | Where-Object { $_ })
            if ($ips.Count -and -not @($ips | Where-Object { $_ -notlike '169.254.*' }).Count) { & $add 'APIPA_ADDRESS' }
            if (Get-PnhFact $a 'dns_manual') { & $add 'MANUAL_DNS' }
        }
        if (@($ads | Where-Object { (Get-PnhFact $_ 'vpn') -eq $true }).Count) { & $add 'VPN_ADAPTER' }
        $netFacts = Get-PnhFact -Facts $Facts -Path 'network'
        $hasGwFact = $false
        if ($netFacts -is [System.Collections.IDictionary]) { $hasGwFact = $netFacts.Contains('gw') }
        elseif ($netFacts) { $hasGwFact = [bool]$netFacts.PSObject.Properties['gw'] }
        if ($upAds.Count -and $hasGwFact -and -not (& $F 'network.gw')) { & $add 'NO_DEFAULT_GATEWAY' }
    }
    $t = & $F 'network.test'
    if ($t) {
        $lo = [string](Get-PnhFact $t 'lo'); $gw = [string](Get-PnhFact $t 'gw'); $ext = [string](Get-PnhFact $t 'ext')
        $dns = [string](Get-PnhFact $t 'dns'); $tcp = [string](Get-PnhFact $t 'tcp')
        if ($lo -and $lo -ne 'SUCCESS') { & $add 'LOOPBACK_FAILS' }
        if ($gw -eq 'GENERAL_FAILURE' -or $ext -eq 'GENERAL_FAILURE') { & $add 'PING_GENERAL_FAILURE' }
        if ($gw -in @('TIMED_OUT', 'HOST_UNREACHABLE')) { & $add 'GW_UNREACHABLE' }
        if ($tcp -eq 'BLOCKED_LOCAL') { & $add 'TCP_BLOCKED_LOCAL' }
        $dnsOk = $dns -in @('RESOLVED', 'NXDOMAIN')
        if ($dns -and -not $dnsOk -and $tcp -eq 'CONNECTED') { & $add 'DNS_FAILS_NET_OK' }
        if ($dnsOk -and $tcp -and $tcp -ne 'CONNECTED' -and $ext -ne 'SUCCESS') { & $add 'ONLY_DNS_WORKS' }
    }
    if ((& $F 'network.proxy.user') -eq 1 -or (& $F 'network.proxy.pac')) { & $add 'PROXY_USER_SET' }
    $wh = & $F 'network.proxy.winhttp'
    if ($wh -and $wh -ne 'DIRECT') { & $add 'PROXY_WINHTTP_SET' }
    if ([int](& $F 'network.hosts') -gt 0) { & $add 'HOSTS_MODIFIED' }
    if ([int](& $F 'network.split') -gt 0) { & $add 'SPLIT_DEFAULT_ROUTE' }
    if (@(& $F 'network.lsp' | Where-Object { $_ }).Count) { & $add 'NON_MS_LSP' }
    if (@(& $F 'network.ndis' | Where-Object { $_ }).Count) { & $add 'NON_MS_NDIS_FILTER' }
    if (@(& $F 'network.radio' | Where-Object { $_ -and (Get-PnhFact $_ 'k') -eq 'WiFi' -and (Get-PnhFact $_ 's') -ne 'On' }).Count) { & $add 'WLAN_RADIO_OFF' }
    $wl = & $F 'network.wlansvc'
    if ($wl -and $wl -ne 'Running' -and @($ads | Where-Object { (Get-PnhFact $_ 'wifi') -eq $true }).Count) { & $add 'WLANSVC_STOPPED' }

    # security
    foreach ($p in @(& $F 'security.fw' | Where-Object { $_ })) {
        if ([string](Get-PnhFact $p 'on') -ne 'True') { & $add 'FIREWALL_OFF' }
        if ([string](Get-PnhFact $p 'out') -eq 'Block') { & $add 'FIREWALL_OUTBOUND_BLOCK' }
    }
    if ((& $F 'security.mde.onboarded') -eq $true) {
        & $add 'MDE_ONBOARDED'
        if ((& $F 'security.mde.iso_hint') -eq $true -or $flags.Contains('ONLY_DNS_WORKS') -or $flags.Contains('PING_GENERAL_FAILURE')) { & $add 'MDE_ISOLATION_SUSPECT' }
    }
    $av = & $F 'security.av'
    if ($av) {
        $mode = [string](Get-PnhFact $av 'mode')
        $rtp = Get-PnhFact $av 'rtp'
        if ($mode -eq 'Normal' -and $rtp -eq $false) { & $add 'DEFENDER_RTP_OFF' }
        $age = Get-PnhFact $av 'sig_age_d'
        if ($mode -and $null -ne $age -and [int]$age -gt 7) { & $add 'DEFENDER_SIG_OLD' }
        if ([int](Get-PnhFact $av 'threats30d') -gt 0) { & $add 'DEFENDER_THREATS' }
        $others = @(Get-PnhFact $av 'products' | Where-Object { $_ -and $_ -notmatch 'Defender' })
        if ($rtp -ne $true -and -not $others.Count) { & $add 'NO_ACTIVE_AV' }
    }
    $bl = & $F 'security.bl'
    if ($bl -and -not ($bl -is [string])) {
        if ([string](Get-PnhFact $bl 'prot') -eq 'On') { & $add 'BITLOCKER_ON' }
        $bs = [string](Get-PnhFact $bl 'status')
        if ($bs -and $bs -ne 'FullyDecrypted' -and [string](Get-PnhFact $bl 'prot') -eq 'Off') { & $add 'BITLOCKER_SUSPENDED' }
    }

    # performance
    if ([int](& $F 'performance.autostart') -gt 15) { & $add 'MANY_AUTOSTARTS' }

    # printer
    $spool = & $F 'printer.spooler'
    if ($spool -and $spool -ne 'Running') { & $add 'SPOOLER_STOPPED' }
    foreach ($p in @(& $F 'printer.printers' | Where-Object { $_ })) {
        if ((Get-PnhFact $p 'def') -eq $true -and (Get-PnhFact $p 'offline') -eq $true) { & $add 'PRINTER_OFFLINE' }
        if ([int](Get-PnhFact $p 'stuck') -gt 0) { & $add 'PRINT_JOBS_STUCK' }
    }

    # audio
    foreach ($s in @(& $F 'audio.svc' | Where-Object { $_ })) { if ([string](Get-PnhFact $s 'st') -ne 'Running') { & $add 'AUDIO_SERVICE_STOPPED' } }
    $audioFacts = Get-PnhFact -Facts $Facts -Path 'audio'
    if ($audioFacts) {
        $eps = @(& $F 'audio.endpoints' | Where-Object { $_ })
        $epKnown = $false
        if ($audioFacts -is [System.Collections.IDictionary]) { $epKnown = $audioFacts.Contains('endpoints') } else { $epKnown = [bool]$audioFacts.PSObject.Properties['endpoints'] }
        if ($epKnown -and -not @($eps | Where-Object { (Get-PnhFact $_ 'st') -eq 'OK' }).Count) { & $add 'AUDIO_NO_ENDPOINT' }
    }
    if ((& $F 'audio.mute') -eq $true) { & $add 'AUDIO_MUTED' }
    $vol = & $F 'audio.vol_pct'
    if ($null -ne $vol -and [double]$vol -lt 5) { & $add 'AUDIO_VOLUME_LOW' }

    # update
    foreach ($s in @(& $F 'update.svc' | Where-Object { $_ })) {
        if ([string](Get-PnhFact $s 'n') -ne 'UsoSvc' -and [string](Get-PnhFact $s 'start') -eq 'Disabled') { & $add 'WU_SERVICE_DISABLED' }
    }
    if ([int](& $F 'update.fail_30d') -gt 0) { & $add 'WU_ERRORS' }

    # display
    if (@(& $F 'display.adapters' | Where-Object { $_ -and [int](Get-PnhFact $_ 'cm_err') -ne 0 }).Count) { & $add 'DEVICE_ERRORS' }

    # events
    $k = & $F 'events.known'
    if ($k) {
        if ([int](Get-PnhFact $k 'unexpected_shutdown') -gt 0 -or [int](Get-PnhFact $k 'bugcheck') -gt 0) { & $add 'CRASHES' }
        if ([int](Get-PnhFact $k 'disk') -gt 0 -or [int](Get-PnhFact $k 'ntfs') -gt 0) { & $add 'DISK_ERRORS_EVENTS' }
        if ([int](Get-PnhFact $k 'whea_fatal') -gt 0) { & $add 'WHEA_ERRORS' }
        if ([int](Get-PnhFact $k 'tdr') -gt 0) { & $add 'DISPLAY_TDR' }
        if ([int](Get-PnhFact $k 'profile_temp') -gt 0) { & $add 'TEMP_PROFILE' }
        if ([int](Get-PnhFact $k 'app_crash') -gt 5) { & $add 'APP_CRASHES' }
    }
    return $flags.ToArray()
}

# ------------------------------------------------------------------ diagnosis

function Invoke-PnhDiagnose {
    <#
    .SYNOPSIS
        Read-only fact collection per section plus finding codes. Offline, normally under 30 s.

    .PARAMETER Sections
        Any of: system, network, security, disk, performance, printer, audio, update, display,
        events. 'system' always runs (it decides about managed devices and rights). Default: all.

    .PARAMETER BudgetSeconds
        Sections that would start after this time are skipped and listed under Errors.

    .OUTPUTS
        [pscustomobject]@{ Facts = @{<section> = @{...}}; Flags = @(<codes>); DurationMs; Errors }
    #>
    [CmdletBinding()]
    param([string[]]$Sections, [int]$BudgetSeconds = 25)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $facts = [ordered]@{}
    $errors = [ordered]@{}
    $want = New-Object System.Collections.Generic.List[string]
    $want.Add('system')
    $req = @($Sections | Where-Object { $_ })
    if (-not $req.Count) { $req = $script:PnhDiagnoseSections }
    foreach ($s in $req) {
        $n = ([string]$s).ToLowerInvariant()
        if ($script:PnhDiagnoseSections -notcontains $n) { $errors["section.$n"] = 'unknown section'; continue }
        if (-not $want.Contains($n)) { $want.Add($n) }
    }
    if (-not (Test-PnhIsWindows)) { $errors['platform'] = 'The diagnosis needs Windows; facts are empty.' }
    foreach ($s in $want) {
        if ($sw.Elapsed.TotalSeconds -gt $BudgetSeconds) { $errors[$s] = 'skipped: time budget used up'; continue }
        try {
            $facts[$s] = Get-PnhSectionFacts -Name $s -Errors $errors
        } catch {
            $errors[$s] = $_.Exception.Message
        }
    }
    $flags = @()
    try { $flags = @(Get-PnhDiagnoseFlags -Facts $facts) } catch { $errors['flags'] = $_.Exception.Message }
    $result = [pscustomobject]@{
        Facts      = $facts
        Flags      = $flags
        DurationMs = [int]$sw.ElapsedMilliseconds
        Errors     = $errors
    }
    if (Get-Command -Name Write-PnhLog -CommandType Function -ErrorAction SilentlyContinue) {
        try { Write-PnhLog -Message ('Diagnosis: ' + ($want -join ',') + " in $($result.DurationMs) ms") -Data @{ flags = $flags; errors = $errors } } catch { Write-Verbose $_.Exception.Message }
    }
    return $result
}

# ------------------------------------------------------------------ success checks

function Get-PnhSuccessCheckIds {
    <#
    .SYNOPSIS
        Ids of all success checks (referenced by categories.json "success").
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns a set.')]
    [CmdletBinding()]
    param()
    return $script:PnhSuccessCheckIds
}

function Get-PnhCheckProbe {
    <#
    .SYNOPSIS
        Collects the raw data for one success check (Windows). Mocked in tests.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)
    $ErrorActionPreference = 'Stop'
    switch ($Name) {
        'network' {
            $gw = Get-PnhDefaultGateway
            $gwPing = $(if ($gw) { (Test-PnhPing -Target $gw).Result } else { 'NO_GATEWAY' })
            $tcp = 'NOT_TESTED'
            $target = $null
            foreach ($ip in '1.1.1.1', '8.8.8.8') {
                $target = $ip
                $tcp = (Test-PnhTcp -Target $ip -Port 443).Result
                if ($tcp -eq 'CONNECTED') { break }
            }
            $dns = (Test-PnhDns -Name 'www.msftconnecttest.com').Result
            return @{ Gateway = $gw; GatewayPing = $gwPing; Tcp443 = $tcp; TcpTarget = $target; Dns = $dns }
        }
        'printer' {
            $sp = Get-Service -Name Spooler -ErrorAction SilentlyContinue
            $jobs = @()
            if ($sp -and "$($sp.Status)" -eq 'Running') { $jobs = @(Get-CimInstance -ClassName Win32_PrintJob -ErrorAction SilentlyContinue) }
            $stuck = @($jobs | Where-Object { ([int]$_.StatusMask -band $script:PnhPrintJobStuckMask) -or ($_.TimeSubmitted -and $_.TimeSubmitted -lt (Get-Date).AddHours(-2)) })
            return @{ SpoolerStatus = "$($sp.Status)"; SpoolerStartType = "$($sp.StartType)"; Jobs = $jobs.Count; StuckJobs = $stuck.Count }
        }
        'disk' {
            $d = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='" + $env:SystemDrive + "'") -ErrorAction Stop
            return @{ Drive = $env:SystemDrive; FreeBytes = [double]$d.FreeSpace; SizeBytes = [double]$d.Size }
        }
        'sound' {
            $svc = @{}
            foreach ($s in @(Get-Service -Name Audiosrv, AudioEndpointBuilder -ErrorAction SilentlyContinue)) { $svc[$s.Name] = "$($s.Status)" }
            $ok = @(Get-PnpDevice -Class AudioEndpoint -PresentOnly -ErrorAction SilentlyContinue | Where-Object { "$($_.Status)" -eq 'OK' }).Count
            $vol = $null
            $mute = $null
            try { $st = Get-PnhAudioState; $vol = [double]$st.Volume; $mute = [bool]$st.Mute } catch { Write-Verbose "Audio state: $($_.Exception.Message)" }
            return @{ Services = $svc; EndpointsOk = $ok; Volume = $vol; Mute = $mute }
        }
        'update' {
            $svc = @{}
            foreach ($s in @(Get-Service -Name wuauserv, BITS, CryptSvc -ErrorAction SilentlyContinue)) { $svc[$s.Name] = @{ Status = "$($s.Status)"; StartType = "$($s.StartType)" } }
            $p = @(Test-PnhRebootPending)
            return @{ Services = $svc; PendingReboot = [bool](($p -contains 'CBS') -or ($p -contains 'WU')) }
        }
        'display' {
            $ad = @(Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop | ForEach-Object { @{ Name = $_.Name; Problem = [int]$_.ConfigManagerErrorCode; Basic = ("$($_.InfFilename)" -eq 'display.inf') } })
            return @{ Adapters = $ad }
        }
        'slow' {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            $d = Get-CimInstance -ClassName Win32_LogicalDisk -Filter ("DeviceID='" + $env:SystemDrive + "'") -ErrorAction SilentlyContinue
            $p = @(Test-PnhRebootPending)
            return @{
                UptimeHours   = [math]::Round(((Get-Date) - $os.LastBootUpTime).TotalHours, 1)
                PendingReboot = [bool](($p -contains 'CBS') -or ($p -contains 'WU'))
                FreeBytes     = $(if ($d) { [double]$d.FreeSpace } else { $null })
                SizeBytes     = $(if ($d) { [double]$d.Size } else { $null })
                RamFreePct    = [math]::Round(100 * $os.FreePhysicalMemory / [math]::Max(1, $os.TotalVisibleMemorySize), 0)
            }
        }
        'other' {
            $stopped = @(foreach ($n in 'EventLog', 'Winmgmt', 'ProfSvc', 'Dnscache', 'CryptSvc', 'BFE') {
                    $s = Get-Service -Name $n -ErrorAction SilentlyContinue
                    if ($s -and "$($s.Status)" -ne 'Running') { $n }
                })
            return @{
                StoppedServices = $stopped
                TempOk          = (Test-Path -LiteralPath ([IO.Path]::GetTempPath()))
                TempProfile     = ($env:USERPROFILE -match '\\Users\\TEMP(\.|$)')
                ExplorerRunning = [bool](Get-Process -Name explorer -ErrorAction SilentlyContinue)
            }
        }
        default { throw "Unknown check: $Name" }
    }
}

function Get-PnhCheckVerdict {
    <#
    .SYNOPSIS
        Pure evaluation of a success check from its probe data -> @{Passed; Details; Summary}.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name, [Parameter(Mandatory = $true)]$Data)
    $D = { param($k) Get-PnhFact -Facts $Data -Path $k }
    $passed = $false
    $summary = ''
    switch ($Name) {
        'network' {
            $tcpOk = (& $D 'Tcp443') -eq 'CONNECTED'
            $dnsOk = (& $D 'Dns') -eq 'RESOLVED'
            $gwPing = [string](& $D 'GatewayPing')
            # Some routers do not answer ping; a working internet connection proves the router works.
            $gwOk = ($gwPing -eq 'SUCCESS') -or (($gwPing -eq 'TIMED_OUT') -and $tcpOk)
            $passed = $gwOk -and $tcpOk -and $dnsOk
            $bad = @()
            if (-not $gwOk) { $bad += "router ($gwPing)" }
            if (-not $tcpOk) { $bad += "internet connection ($(& $D 'Tcp443'))" }
            if (-not $dnsOk) { $bad += "name lookup ($(& $D 'Dns'))" }
            $summary = $(if ($passed) { 'Router, internet connection and name lookup work.' } else { 'Not working: ' + ($bad -join ', ') + '.' })
        }
        'printer' {
            $run = (& $D 'SpoolerStatus') -eq 'Running'
            $stuck = [int](& $D 'StuckJobs')
            $passed = $run -and ($stuck -eq 0)
            $summary = $(if ($passed) { 'The print service runs and no print job is stuck.' } elseif (-not $run) { "The print service is not running ($(& $D 'SpoolerStatus'), start type $(& $D 'SpoolerStartType'))." } else { "$stuck print job(s) are stuck." })
        }
        'disk' {
            $state = Test-PnhDiskSpaceLow -FreeBytes ([double](& $D 'FreeBytes')) -SizeBytes ([double](& $D 'SizeBytes'))
            $passed = ($state -eq 'ok')
            $summary = ('{0:N1} GB free on the system drive ({1}).' -f ([double](& $D 'FreeBytes') / 1GB), $state)
        }
        'sound' {
            $svc = & $D 'Services'
            $svcOk = $true
            foreach ($n in 'Audiosrv', 'AudioEndpointBuilder') { if ((Get-PnhFact -Facts $svc -Path $n) -ne 'Running') { $svcOk = $false } }
            $epOk = [int](& $D 'EndpointsOk') -gt 0
            $mute = & $D 'Mute'
            $vol = & $D 'Volume'
            $volOk = ($mute -ne $true) -and ($null -eq $vol -or [double]$vol -ge 0.05)
            $passed = $svcOk -and $epOk -and $volOk
            $bad = @()
            if (-not $svcOk) { $bad += 'sound services stopped' }
            if (-not $epOk) { $bad += 'no working sound device' }
            if ($mute -eq $true) { $bad += 'muted' }
            if ($null -ne $vol -and [double]$vol -lt 0.05) { $bad += 'volume almost zero' }
            $summary = $(if ($passed) { 'Sound services run, a sound device works and the sound is not muted.' } else { 'Problem: ' + ($bad -join ', ') + '.' })
        }
        'update' {
            $svc = & $D 'Services'
            $wu = [string](Get-PnhFact -Facts $svc -Path 'wuauserv.StartType')
            $bits = [string](Get-PnhFact -Facts $svc -Path 'BITS.StartType')
            $crypt = [string](Get-PnhFact -Facts $svc -Path 'CryptSvc.Status')
            $pend = (& $D 'PendingReboot') -eq $true
            $passed = ($wu -and $wu -ne 'Disabled') -and ($bits -and $bits -ne 'Disabled') -and ($crypt -eq 'Running') -and -not $pend
            $summary = $(if ($passed) { 'Update services are allowed to run and no restart is pending. Whether updates download can only be seen with internet.' } elseif ($pend) { 'Windows waits for a restart.' } else { "Update services: wuauserv=$wu, BITS=$bits, CryptSvc=$crypt." })
        }
        'display' {
            $ad = @(& $D 'Adapters' | Where-Object { $_ })
            $problem = @($ad | Where-Object { [int](Get-PnhFact $_ 'Problem') -ne 0 })
            $basicOnly = $ad.Count -and -not @($ad | Where-Object { (Get-PnhFact $_ 'Basic') -ne $true }).Count
            $passed = $ad.Count -gt 0 -and -not $problem.Count -and -not $basicOnly
            $summary = $(if ($passed) { 'The graphics adapter works with its own driver.' } elseif (-not $ad.Count) { 'No graphics adapter found.' } elseif ($problem.Count) { 'A graphics adapter reports a problem code.' } else { 'Only the basic Windows display driver is active (the manufacturer driver is missing).' })
        }
        'slow' {
            $up = [double](& $D 'UptimeHours')
            $pend = (& $D 'PendingReboot') -eq $true
            $free = & $D 'FreeBytes'
            $diskState = $(if ($null -ne $free) { Test-PnhDiskSpaceLow -FreeBytes ([double]$free) -SizeBytes ([double](& $D 'SizeBytes')) } else { 'ok' })
            $passed = ($up -lt $script:PnhUptimeLongHours) -and -not $pend -and ($diskState -eq 'ok')
            $bad = @()
            if ($up -ge $script:PnhUptimeLongHours) { $bad += "running for $([int]$up) hours without restart" }
            if ($pend) { $bad += 'restart pending' }
            if ($diskState -ne 'ok') { $bad += "disk space $diskState" }
            $summary = $(if ($passed) { 'No restart pending, recently restarted and enough disk space.' } else { 'Still slowing down: ' + ($bad -join ', ') + '.' })
        }
        'other' {
            $stopped = @(& $D 'StoppedServices' | Where-Object { $_ })
            $tempOk = (& $D 'TempOk') -eq $true
            $tempProfile = (& $D 'TempProfile') -eq $true
            $explorer = (& $D 'ExplorerRunning') -eq $true
            $passed = (-not $stopped.Count) -and $tempOk -and -not $tempProfile -and $explorer
            $bad = @()
            if ($stopped.Count) { $bad += 'stopped services: ' + ($stopped -join ', ') }
            if (-not $tempOk) { $bad += 'temp folder missing' }
            if ($tempProfile) { $bad += 'temporary user profile' }
            if (-not $explorer) { $bad += 'taskbar/Explorer not running' }
            $summary = $(if ($passed) { 'Core Windows services, the user profile and the taskbar are fine.' } else { 'Problem: ' + ($bad -join '; ') + '.' })
        }
        default { throw "Unknown check: $Name" }
    }
    return [pscustomobject]@{ Passed = [bool]$passed; Details = $Data; Summary = $summary }
}

function Invoke-PnhSuccessCheck {
    <#
    .SYNOPSIS
        Deterministic success check of a category: a script decides, not the model.

    .DESCRIPTION
        check.network  gateway ping (or ICMP blocked while TCP works) + TCP 443 to a public IP
                       (1.1.1.1, fallback 8.8.8.8) + DNS resolution (www.msftconnecttest.com)
        check.printer  spooler running + no stuck job (StatusMask error bits or older than 2 h)
        check.disk     system drive free space above the threshold (Test-PnhDiskSpaceLow)
        check.sound    audio services running + a working endpoint + not muted / volume >= 5 %
        check.update   wuauserv/BITS not disabled + CryptSvc running + no pending restart
        check.display  an adapter without problem code, not only the basic display driver
        check.slow     restarted within 7 days + no pending restart + disk space ok
        check.other    core services running + temp folder + no temporary profile + Explorer
        check.all      network + disk + update + other must pass; printer, sound and display
                       are reported in Details only

    .OUTPUTS
        [pscustomobject]@{ Passed (bool); Details (hashtable); Summary (string, English) }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Id)
    $name = $Id -replace '^check\.', ''
    if ($script:PnhSuccessCheckIds -notcontains ('check.' + $name)) {
        return [pscustomobject]@{ Passed = $false; Details = @{ Error = 'unknown check' }; Summary = "Unknown success check: $Id" }
    }
    if (-not (Test-PnhIsWindows)) {
        return [pscustomobject]@{ Passed = $false; Details = @{ Error = 'not windows' }; Summary = 'Success checks need Windows.' }
    }
    if ($name -eq 'all') {
        $details = [ordered]@{}
        $core = @('network', 'disk', 'update', 'other')
        $failed = @()
        foreach ($n in @($core + @('printer', 'sound', 'display'))) {
            try {
                $v = Get-PnhCheckVerdict -Name $n -Data (Get-PnhCheckProbe -Name $n)
            } catch {
                $v = [pscustomobject]@{ Passed = $false; Details = @{ Error = $_.Exception.Message }; Summary = "Check failed: $($_.Exception.Message)" }
            }
            $details[$n] = [ordered]@{ Passed = $v.Passed; Summary = $v.Summary }
            if ($core -contains $n -and -not $v.Passed) { $failed += $n }
        }
        $sum = $(if ($failed.Count) { 'Not fine yet: ' + ($failed -join ', ') + '.' } else { 'Network, disk space, updates and core Windows functions are fine.' })
        return [pscustomobject]@{ Passed = (-not $failed.Count); Details = $details; Summary = $sum }
    }
    try {
        return (Get-PnhCheckVerdict -Name $name -Data (Get-PnhCheckProbe -Name $name))
    } catch {
        return [pscustomobject]@{ Passed = $false; Details = @{ Error = $_.Exception.Message }; Summary = "The check could not run: $($_.Exception.Message)" }
    }
}
