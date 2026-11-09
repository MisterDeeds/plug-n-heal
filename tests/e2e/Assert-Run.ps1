#Requires -Version 5.1
<#
.SYNOPSIS
    End-to-end checks for the CI job "e2e-windows": runs Plug'n'Heal from a built drive and asserts the outcome.

.DESCRIPTION
    Scenarios (-Scenario):

      diagnose          Invoke-PnhDiagnose (all sections, read-only) in this process with the drive's libraries.
                        Asserts: finishes in under -MaxDiagnoseSeconds (default 60), returns Facts and Flags, every
                        flag is a finding code from toolbox\findings.json.

      printer           Run-Headless.ps1 -Category printer -AutoConfirm -Json in a separate Windows PowerShell 5.1
                        (powershell.exe). Run tests\e2e\Break-Printer.ps1 first. Asserts: exit code 0, the JSON
                        result says solved, the Print Spooler runs again, check.printer passes, a changing catalogue
                        action ran, the run folder holds its files, and the restore point attempt was logged as
                        skipped (Windows Server has no System Restore; on a client "created" is accepted too).

      network-readonly  Run-Headless.ps1 -Category network -ReadOnly -Json. Asserts: exit code 0 or 1, never 2;
                        no changing catalogue action ran (each was skipped), no restore point attempt, no backup
                        folder of a changing action, and the network configuration is the same before and after
                        (adapters, IPv4 addresses, DNS servers, default routes, proxies, hosts file, firewall
                        profiles, Winsock catalogue, network services).

    While a headless run is going on, a guard calls "shutdown.exe /a" every few seconds: with -AutoConfirm a small
    model may pick "restart the computer" (sys.restart, shutdown /r /t 60), which would kill the CI runner. An aborted
    restart is reported as a warning. -NoShutdownGuard switches the guard off.

    Evidence goes to -OutDir: <scenario>.stdout.txt (the JSON result), <scenario>.stderr.txt (progress lines),
    <scenario>.assert.json, network-before.json / network-after.json, diagnose.json. On GitHub Actions a summary table
    is appended to the job page and failed checks become error annotations.

    Exit code: 0 = all checks passed, 1 = at least one check failed, 2 = could not run (setup problem).

.PARAMETER Scenario
    diagnose, printer or network-readonly.
.PARAMETER AppPath
    The app folder of the drive, for example P:\PlugNHeal\app. Default: <repo>\src.
.PARAMETER Model
    Model tag passed to Run-Headless.ps1 -Model (must be installed on the drive). Default: automatic choice.
.PARAMETER OutDir
    Folder for the evidence. Default: <repo>\TestResults\e2e.
.PARAMETER TimeoutMinutes
    Limit for one headless run (default 20). The process tree is killed when it is reached.
.PARAMETER MaxDiagnoseSeconds
    Limit for the diagnose scenario (default 60).
.PARAMETER PowerShellPath
    Windows PowerShell used for the headless run. Default: %SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe.
.PARAMETER NoShutdownGuard
    Do not abort pending restarts while a headless run is going on.

.EXAMPLE
    .\tests\e2e\Assert-Run.ps1 -Scenario printer -AppPath P:\PlugNHeal\app -Model qwen3.5:2b-q4_K_M
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('diagnose', 'printer', 'network-readonly')]
    [string]$Scenario,
    [string]$AppPath,
    [string]$Model,
    [string]$OutDir,
    [ValidateRange(1, 180)][int]$TimeoutMinutes = 20,
    [ValidateRange(1, 600)][int]$MaxDiagnoseSeconds = 60,
    [string]$PowerShellPath,
    [switch]$NoShutdownGuard
)

$ErrorActionPreference = 'Stop'
$script:E2eChecks = New-Object System.Collections.Generic.List[object]
$script:E2eNotes = New-Object System.Collections.Generic.List[string]
$script:E2eStart = Get-Date

# ---------------------------------------------------------------------------------------------------------------------
# Output and bookkeeping
# ---------------------------------------------------------------------------------------------------------------------
function Write-PnhE2eLine {
    param([string]$Text)
    [Console]::Out.WriteLine(('[{0}] {1}' -f (Get-Date).ToString('HH:mm:ss'), $Text))
}

function Add-PnhE2eCheck {
    param([Parameter(Mandatory = $true)][string]$Name, [bool]$Ok, [string]$Detail)
    $script:E2eChecks.Add([pscustomobject][ordered]@{ Name = $Name; Ok = $Ok; Detail = $Detail })
    $word = 'FAIL'
    if ($Ok) { $word = 'PASS' }
    $line = '{0}  {1}' -f $word, $Name
    if ($Detail) { $line += '  (' + $Detail + ')' }
    Write-PnhE2eLine $line
}

function Add-PnhE2eNote {
    param([Parameter(Mandatory = $true)][string]$Text, [switch]$Warning)
    $script:E2eNotes.Add($Text)
    Write-PnhE2eLine ('NOTE  ' + $Text)
    if ($Warning -and $env:GITHUB_ACTIONS -eq 'true') {
        [Console]::Out.WriteLine(('::warning title=e2e {0}::{1}' -f $Scenario, ($Text -replace '[\r\n]+', ' ')))
    }
}

function Get-PnhE2eMember {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Write-PnhE2eText {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-PnhE2eText {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Complete-PnhE2e {
    # writes <scenario>.assert.json and the job summary, returns the exit code
    param([int]$SetupError = 0)
    $failed = @($script:E2eChecks | Where-Object { -not $_.Ok })
    $code = 0
    if ($failed.Count -gt 0) { $code = 1 }
    if ($SetupError) { $code = 2 }
    $doc = [ordered]@{
        scenario = $Scenario
        started  = $script:E2eStart.ToString('o')
        seconds  = [Math]::Round(((Get-Date) - $script:E2eStart).TotalSeconds, 1)
        exitCode = $code
        checks   = $script:E2eChecks.ToArray()
        notes    = $script:E2eNotes.ToArray()
    }
    if ($OutDir -and (Test-Path -LiteralPath $OutDir)) {
        try { Write-PnhE2eText -Path (Join-Path $OutDir ($Scenario + '.assert.json')) -Text (ConvertTo-Json -InputObject $doc -Depth 5) } catch { Write-PnhE2eLine ('could not write assert.json: ' + $_.Exception.Message) }
    }
    if ($env:GITHUB_ACTIONS -eq 'true') {
        foreach ($f in $failed) {
            [Console]::Out.WriteLine(('::error title=e2e {0}::{1} {2}' -f $Scenario, $f.Name, ([string]$f.Detail -replace '[\r\n]+', ' ')))
        }
    }
    if ($env:GITHUB_STEP_SUMMARY) {
        $state = 'passed'
        if ($code -eq 1) { $state = 'FAILED' } elseif ($code -eq 2) { $state = 'could not run' }
        $md = New-Object System.Collections.Generic.List[string]
        $md.Add(('### e2e {0}: {1} ({2} s)' -f $Scenario, $state, $doc.seconds))
        $md.Add('')
        if ($script:E2eChecks.Count -gt 0) {
            $md.Add('| | Check | Detail |')
            $md.Add('|---|---|---|')
            foreach ($c in $script:E2eChecks) {
                $mark = 'FAIL'
                if ($c.Ok) { $mark = 'ok' }
                $md.Add(('| {0} | {1} | {2} |' -f $mark, $c.Name.Replace('|', '/'), ([string]$c.Detail).Replace('|', '/')))
            }
        }
        foreach ($n in $script:E2eNotes) { $md.Add(('- ' + $n)) }
        $md.Add('')
        try { [System.IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, ($md -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false))) } catch { Write-PnhE2eLine ('could not write the step summary: ' + $_.Exception.Message) }
    }
    Write-PnhE2eLine ('{0}: {1} checks, {2} failed -> exit {3}' -f $Scenario, $script:E2eChecks.Count, $failed.Count, $code)
    return $code
}

# ---------------------------------------------------------------------------------------------------------------------
# Processes
# ---------------------------------------------------------------------------------------------------------------------
function ConvertTo-PnhE2eArgument {
    # quoting rules of CommandLineToArgvW
    param([string]$Value)
    if ($Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = [regex]::Replace($Value, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Invoke-PnhE2eNative {
    # small native call without PowerShell's stderr handling (Windows PowerShell 5.1 turns redirected stderr into
    # terminating errors when $ErrorActionPreference is Stop) -> @{ExitCode; Output}
    param([Parameter(Mandatory = $true)][string]$FilePath, [string[]]$ArgumentList = @(), [int]$TimeoutSeconds = 60)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = (@($ArgumentList | ForEach-Object { ConvertTo-PnhE2eArgument $_ }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $errTask = $p.StandardError.ReadToEndAsync()
    $out = $p.StandardOutput.ReadToEnd()
    if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
        try { $p.Kill() } catch { Write-Verbose $_.Exception.Message }
        return @{ ExitCode = -1; Output = $out }
    }
    $p.WaitForExit()
    $err = ''
    try { $err = $errTask.Result } catch { $err = '' }
    return @{ ExitCode = $p.ExitCode; Output = ($out + $err) }
}

function Read-PnhE2eNewText {
    # new bytes of a file another process is still writing
    param([string]$Path, [ref]$Position)
    try {
        $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
        try {
            $len = $fs.Length
            if ($len -le $Position.Value) { return '' }
            [void]$fs.Seek($Position.Value, [System.IO.SeekOrigin]::Begin)
            $buf = New-Object byte[] ([int]($len - $Position.Value))
            $n = $fs.Read($buf, 0, $buf.Length)
            $Position.Value = $Position.Value + $n
            return [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
        } finally { $fs.Dispose() }
    } catch {
        return ''
    }
}

function Stop-PnhE2eDriveOllama {
    # Ollama processes started from this drive that are still alive after a run
    param([string]$Root)
    $left = @()
    foreach ($p in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'ollama*' })) {
        $path = $null
        try { $path = $p.Path } catch { $path = $null }
        # the image path may be reported through the subst letter or through the real folder behind it
        if ($path -and ($path.StartsWith($Root, [System.StringComparison]::OrdinalIgnoreCase) -or $path -like '*\PlugNHeal\runtime\*')) {
            $left += ('{0} (pid {1})' -f $p.ProcessName, $p.Id)
            try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { Write-Verbose $_.Exception.Message }
        }
    }
    return $left
}

function Invoke-PnhE2eHeadless {
    # runs Run-Headless.ps1 in Windows PowerShell 5.1 -> @{ExitCode; TimedOut; StdOut; StdErr; Seconds; AbortedRestarts}
    param([Parameter(Mandatory = $true)][string[]]$Arguments, [Parameter(Mandatory = $true)][string]$Label)
    $headless = Join-Path $AppPath 'Run-Headless.ps1'
    $stdoutPath = Join-Path $OutDir ($Label + '.stdout.txt')
    $stderrPath = Join-Path $OutDir ($Label + '.stderr.txt')
    $stdinPath = Join-Path $OutDir ($Label + '.stdin.txt')
    Write-PnhE2eText -Path $stdinPath -Text ''
    $all = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $headless) + $Arguments
    $argLine = (@($all | ForEach-Object { ConvertTo-PnhE2eArgument $_ }) -join ' ')
    Write-PnhE2eLine ('start: ' + $PowerShellPath + ' ' + $argLine)
    # the drive's libraries derive the root from their own location; an inherited override would point elsewhere
    Remove-Item -Path 'Env:PNH_ROOT' -ErrorAction SilentlyContinue
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $PowerShellPath -ArgumentList $argLine -NoNewWindow -PassThru `
        -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -RedirectStandardInput $stdinPath
    $null = $p.Handle   # keep the handle: without it Windows PowerShell 5.1 may report no ExitCode
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $pos = [long]0
    $timedOut = $false
    $aborted = 0
    $lastGuard = [datetime]::MinValue
    while (-not $p.HasExited) {
        if ((Get-Date) -gt $deadline) {
            $timedOut = $true
            Write-PnhE2eLine ('timeout after {0} min, killing the process tree' -f $TimeoutMinutes)
            try { [void](Invoke-PnhE2eNative -FilePath 'taskkill.exe' -ArgumentList @('/T', '/F', '/PID', [string]$p.Id)) } catch { Write-PnhE2eLine ('taskkill failed: ' + $_.Exception.Message) }
            try { if (-not $p.HasExited) { $p.Kill() } } catch { Write-Verbose $_.Exception.Message }
            break
        }
        if (-not $NoShutdownGuard -and ((Get-Date) - $lastGuard).TotalSeconds -ge 5) {
            $lastGuard = Get-Date
            $g = @{ ExitCode = -1 }
            try { $g = Invoke-PnhE2eNative -FilePath 'shutdown.exe' -ArgumentList @('/a') -TimeoutSeconds 15 } catch { Write-Verbose $_.Exception.Message }
            if ($g.ExitCode -eq 0) {
                $aborted++
                Write-PnhE2eLine 'guard: a pending restart was aborted (shutdown /a)'
            }
        }
        $chunk = Read-PnhE2eNewText -Path $stderrPath -Position ([ref]$pos)
        if ($chunk) { [Console]::Out.Write($chunk) }
        Start-Sleep -Milliseconds 1000
    }
    [void]$p.WaitForExit(30000)
    $chunk = Read-PnhE2eNewText -Path $stderrPath -Position ([ref]$pos)
    if ($chunk) { [Console]::Out.Write($chunk) }
    $code = $null
    try { $code = $p.ExitCode } catch { $code = $null }
    if ($timedOut) { $code = -1 }
    $sw.Stop()
    return @{
        ExitCode        = $code
        TimedOut        = $timedOut
        StdOut          = (Read-PnhE2eText -Path $stdoutPath)
        StdErr          = (Read-PnhE2eText -Path $stderrPath)
        Seconds         = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
        AbortedRestarts = $aborted
    }
}

function ConvertFrom-PnhE2eResultJson {
    # stdout of Run-Headless -Json is the result object; tolerate stray host lines around it
    param([string]$Text)
    if (-not $Text -or -not $Text.Trim()) { return $null }
    try { return (ConvertFrom-Json -InputObject $Text) } catch { Write-Verbose $_.Exception.Message }
    $m = [regex]::Match($Text, '(?ms)^\{.*^\}')
    if ($m.Success) {
        try { return (ConvertFrom-Json -InputObject $m.Value) } catch { Write-Verbose $_.Exception.Message }
    }
    return $null
}

# ---------------------------------------------------------------------------------------------------------------------
# Facts about the run
# ---------------------------------------------------------------------------------------------------------------------
function Get-PnhE2eChangeMap {
    # catalogue ids with "changes": true
    $path = Join-Path (Join-Path $AppPath 'toolbox') 'actions.json'
    $cat = ConvertFrom-Json -InputObject (Read-PnhE2eText -Path $path)
    $ids = @{}
    foreach ($a in @($cat.actions)) { $ids[[string]$a.id] = [bool]$a.changes }
    return $ids
}

function Get-PnhE2eRunFolder {
    param($Result)
    $rf = [string](Get-PnhE2eMember $Result 'runFolder')
    if ($rf -and (Test-Path -LiteralPath $rf -PathType Container)) { return $rf }
    $logs = Join-Path $script:E2eRoot 'logs'
    $newest = Get-ChildItem -LiteralPath $logs -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notlike 'build-*' -and $_.LastWriteTime -ge $script:E2eStart.AddMinutes(-1) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($newest) { return $newest.FullName }
    return $null
}

function Test-PnhE2eServerSystem {
    try { return ([int](Get-CimInstance -ClassName Win32_OperatingSystem).ProductType -ne 1) } catch { return $false }
}

function Get-PnhE2eNetworkSnapshot {
    # read-only picture of the network configuration; each entry is compact JSON or "error: ..."
    $snap = [ordered]@{}
    $probe = {
        param([string]$Name, [scriptblock]$Read)
        try { $snap[$Name] = ConvertTo-Json -InputObject @(& $Read) -Depth 4 -Compress }
        catch { $snap[$Name] = 'error: ' + $_.Exception.Message }
    }
    & $probe 'adapters' { Get-NetAdapter | Sort-Object Name | ForEach-Object { '{0} | {1} | admin {2} | {3}' -f $_.Name, $_.InterfaceDescription, $_.AdminStatus, $_.Status } }
    & $probe 'interfaces' { Get-NetIPInterface -AddressFamily IPv4 | Sort-Object InterfaceAlias | ForEach-Object { '{0} | dhcp {1} | metric {2} | auto {3}' -f $_.InterfaceAlias, $_.Dhcp, $_.InterfaceMetric, $_.AutomaticMetric } }
    & $probe 'ipv4' { Get-NetIPAddress -AddressFamily IPv4 | Sort-Object InterfaceAlias, IPAddress | ForEach-Object { '{0} | {1}/{2} | {3}' -f $_.InterfaceAlias, $_.IPAddress, $_.PrefixLength, $_.PrefixOrigin } }
    & $probe 'dnsServers' { Get-DnsClientServerAddress -AddressFamily IPv4 | Sort-Object InterfaceAlias | ForEach-Object { '{0} | {1}' -f $_.InterfaceAlias, (@($_.ServerAddresses) -join ',') } }
    & $probe 'dnsGlobal' { $g = Get-DnsClientGlobalSetting; 'suffixes ' + (@($g.SuffixSearchList) -join ',') + ' | devolution ' + $g.UseDevolution }
    & $probe 'nrpt' { Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { '{0} | {1}' -f (@($_.Namespace) -join ','), (@($_.NameServers) -join ',') } }
    & $probe 'defaultRoutes' { Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object InterfaceAlias, NextHop | ForEach-Object { '{0} | via {1} | metric {2}' -f $_.InterfaceAlias, $_.NextHop, $_.RouteMetric } }
    & $probe 'proxyUser' { $i = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue; 'enable {0} | server {1} | pac {2} | override {3}' -f $i.ProxyEnable, $i.ProxyServer, $i.AutoConfigURL, $i.ProxyOverride }
    & $probe 'proxyWinHttp' { (Invoke-PnhE2eNative -FilePath 'netsh.exe' -ArgumentList @('winhttp', 'show', 'proxy')).Output.Trim() -replace '\s+', ' ' }
    & $probe 'hosts' { (Get-FileHash -LiteralPath (Join-Path $env:SystemRoot 'System32\drivers\etc\hosts') -Algorithm SHA256).Hash }
    & $probe 'winsock' {
        $text = (Invoke-PnhE2eNative -FilePath 'netsh.exe' -ArgumentList @('winsock', 'show', 'catalog')).Output
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))).Replace('-', '') } finally { $sha.Dispose() }
    }
    & $probe 'firewall' { Get-NetFirewallProfile | Sort-Object Name | ForEach-Object { '{0} | enabled {1} | in {2} | out {3}' -f $_.Name, $_.Enabled, $_.DefaultInboundAction, $_.DefaultOutboundAction } }
    & $probe 'services' { Get-Service -Name 'Dnscache', 'Dhcp', 'NlaSvc', 'nsi', 'BFE', 'mpssvc' -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object { '{0} | {1} | {2}' -f $_.Name, $_.Status, $_.StartType } }
    return $snap
}

# ---------------------------------------------------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------------------------------------------------
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not $AppPath) { $AppPath = Join-Path $repoRoot 'src' }
if (-not $OutDir) { $OutDir = Join-Path (Join-Path $repoRoot 'TestResults') 'e2e' }
if (-not (Test-Path -LiteralPath $OutDir)) { [void](New-Item -ItemType Directory -Path $OutDir -Force) }
$OutDir = [System.IO.Path]::GetFullPath($OutDir)

$onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
if (-not $onWindows) {
    Write-PnhE2eLine 'ERROR: the end-to-end checks need Windows.'
    exit (Complete-PnhE2e -SetupError 1)
}
if (-not $PowerShellPath) { $PowerShellPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe' }
$AppPath = [System.IO.Path]::GetFullPath($AppPath)
$script:E2eRoot = Split-Path -Parent $AppPath
$libDir = Join-Path $AppPath 'lib'
foreach ($need in @((Join-Path $AppPath 'Run-Headless.ps1'), (Join-Path $libDir 'Diagnose.ps1'), (Join-Path (Join-Path $AppPath 'toolbox') 'actions.json'), $PowerShellPath)) {
    if (-not (Test-Path -LiteralPath $need -PathType Leaf)) {
        Write-PnhE2eLine ('ERROR: missing ' + $need)
        exit (Complete-PnhE2e -SetupError 1)
    }
}
Write-PnhE2eLine ('scenario {0}, app {1}, PowerShell {2} ({3}), out {4}' -f $Scenario, $AppPath, $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, $OutDir)

# The drive's own libraries (same order as Run-Headless.ps1), for the diagnosis and the success checks.
foreach ($lib in @('Common', 'Hardware', 'Models', 'Ollama', 'Diagnose', 'Toolbox', 'Agent')) {
    . (Join-Path $libDir ($lib + '.ps1'))
}

$headlessArgs = @()
if ($Model) { $headlessArgs += @('-Model', $Model) }
$headlessArgs += @('-Language', 'en', '-Json')

# ---------------------------------------------------------------------------------------------------------------------
# Scenarios
# ---------------------------------------------------------------------------------------------------------------------
switch ($Scenario) {
    'diagnose' {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $diag = $null
        $err = $null
        try { $diag = Invoke-PnhDiagnose } catch { $err = $_.Exception.Message }
        $sw.Stop()
        $sec = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
        Add-PnhE2eCheck -Name 'Invoke-PnhDiagnose returns without throwing' -Ok ($null -eq $err -and $null -ne $diag) -Detail $err
        Add-PnhE2eCheck -Name ('finishes in under {0} s' -f $MaxDiagnoseSeconds) -Ok ($sw.Elapsed.TotalSeconds -lt $MaxDiagnoseSeconds) -Detail ('{0} s wall clock, DurationMs {1}' -f $sec, (Get-PnhE2eMember $diag 'DurationMs'))
        if ($diag) {
            try { Write-PnhE2eText -Path (Join-Path $OutDir 'diagnose.json') -Text (ConvertTo-Json -InputObject $diag -Depth 10) } catch { Add-PnhE2eNote ('diagnose.json not written: ' + $_.Exception.Message) }
            $hasFlags = [bool]$diag.PSObject.Properties['Flags']
            $flags = @($diag.Flags | Where-Object { $null -ne $_ } | ForEach-Object { [string]$_ })
            Add-PnhE2eCheck -Name 'returns Flags (finding codes)' -Ok $hasFlags -Detail ('{0} flag(s): {1}' -f $flags.Count, ($flags -join ', '))
            $known = @{}
            $findings = ConvertFrom-Json -InputObject (Read-PnhE2eText -Path (Join-Path (Join-Path $AppPath 'toolbox') 'findings.json'))
            foreach ($f in @($findings.findings)) { $known[[string]$f.code] = $true }
            $unknown = @($flags | Where-Object { -not $known.ContainsKey($_) })
            Add-PnhE2eCheck -Name 'every flag is a code from toolbox\findings.json' -Ok ($unknown.Count -eq 0) -Detail ($unknown -join ', ')
            $facts = Get-PnhE2eMember $diag 'Facts'
            $sections = @()
            if ($facts -is [System.Collections.IDictionary]) { $sections = @($facts.Keys | ForEach-Object { [string]$_ }) }
            elseif ($facts) { $sections = @($facts.PSObject.Properties | ForEach-Object { $_.Name }) }
            Add-PnhE2eCheck -Name 'returns Facts including the system section' -Ok ($sections -contains 'system') -Detail ('sections: ' + ($sections -join ', '))
            $errs = Get-PnhE2eMember $diag 'Errors'
            $errKeys = @()
            if ($errs -is [System.Collections.IDictionary]) { $errKeys = @($errs.Keys | ForEach-Object { [string]$_ }) }
            if ($errKeys.Count -gt 0) { Add-PnhE2eNote ('probe errors (recorded by the diagnosis, not fatal): ' + ($errKeys -join ', ')) }
            Add-PnhE2eCheck -Name 'diagnosis knows it runs on Windows' -Ok ($errKeys -notcontains 'platform')
        }
    }

    'printer' {
        $svc = Get-Service -Name Spooler -ErrorAction SilentlyContinue
        $pre = ($null -ne $svc -and [string]$svc.Status -eq 'Stopped')
        Add-PnhE2eCheck -Name 'precondition: Print Spooler is stopped (run Break-Printer.ps1 first)' -Ok $pre -Detail $(if ($svc) { [string]$svc.Status } else { 'no Spooler service' })
        if (-not $pre) { exit (Complete-PnhE2e) }

        $run = Invoke-PnhE2eHeadless -Label 'printer' -Arguments (@('-Category', 'printer', '-AutoConfirm') + $headlessArgs)
        $left = @(Stop-PnhE2eDriveOllama -Root $script:E2eRoot)
        Add-PnhE2eCheck -Name ('Run-Headless finished within {0} min' -f $TimeoutMinutes) -Ok (-not $run.TimedOut) -Detail ('{0} s' -f $run.Seconds)
        Add-PnhE2eCheck -Name 'exit code 0 (solved)' -Ok ($run.ExitCode -eq 0) -Detail ('exit ' + $run.ExitCode)
        $result = ConvertFrom-PnhE2eResultJson -Text $run.StdOut
        Add-PnhE2eCheck -Name 'stdout is the JSON result' -Ok ($null -ne $result)
        if ($result) {
            Add-PnhE2eCheck -Name 'JSON: solved = true and exitCode = 0' -Ok ((Get-PnhE2eMember $result 'solved') -eq $true -and [int](Get-PnhE2eMember $result 'exitCode') -eq 0) -Detail ('stoppedReason {0}, rounds {1}, model {2}, error {3}' -f (Get-PnhE2eMember $result 'stoppedReason'), (Get-PnhE2eMember $result 'rounds'), (Get-PnhE2eMember $result 'model'), (Get-PnhE2eMember $result 'error'))
        }
        $deadline = (Get-Date).AddSeconds(30)
        $svc = Get-Service -Name Spooler
        while ([string]$svc.Status -ne 'Running' -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1; $svc = Get-Service -Name Spooler }
        Add-PnhE2eCheck -Name 'Print Spooler runs again' -Ok ([string]$svc.Status -eq 'Running') -Detail ([string]$svc.Status)
        $check = Invoke-PnhSuccessCheck -Id 'check.printer'
        Add-PnhE2eCheck -Name 'check.printer passes (independent re-check)' -Ok ([bool]$check.Passed) -Detail ([string]$check.Summary)

        $changing = Get-PnhE2eChangeMap
        $actions = @()
        if ($result) { $actions = @(Get-PnhE2eMember $result 'actions' | Where-Object { $null -ne $_ }) }
        $ran = @($actions | Where-Object { $changing[[string](Get-PnhE2eMember $_ 'id')] -eq $true -and (Get-PnhE2eMember $_ 'ok') -eq $true -and -not (Get-PnhE2eMember $_ 'skipped') })
        $list = (@($actions | ForEach-Object { '{0}:ok={1}' -f (Get-PnhE2eMember $_ 'id'), (Get-PnhE2eMember $_ 'ok') }) -join ', ')
        Add-PnhE2eCheck -Name 'a changing catalogue action ran and was verified' -Ok ($ran.Count -gt 0) -Detail $list
        if (@($actions | Where-Object { [string](Get-PnhE2eMember $_ 'id') -eq 'sys.restart' }).Count -gt 0 -or $run.AbortedRestarts -gt 0) {
            Add-PnhE2eNote -Warning ('the model asked for a restart of the computer ({0} aborted by the CI guard)' -f $run.AbortedRestarts)
        }

        $rf = Get-PnhE2eRunFolder -Result $result
        Add-PnhE2eCheck -Name 'run folder exists' -Ok ([bool]$rf) -Detail $rf
        if ($rf) {
            $missing = @(@('run.log', 'run.jsonl', 'diagnose.json', 'chat.jsonl', 'summary.txt') | Where-Object { -not (Test-Path -LiteralPath (Join-Path $rf $_) -PathType Leaf) })
            Add-PnhE2eCheck -Name 'run folder has run.log, run.jsonl, diagnose.json, chat.jsonl, summary.txt' -Ok ($missing.Count -eq 0) -Detail $(if ($missing.Count) { 'missing: ' + ($missing -join ', ') } else { '' })
            $log = Read-PnhE2eText -Path (Join-Path $rf 'run.log')
            $rp = [regex]::Match($log, 'Restore point (skipped|created)[^\r\n]*')
            if (Test-PnhE2eServerSystem) {
                Add-PnhE2eCheck -Name 'restore point attempt logged as skipped (Windows Server)' -Ok ($rp.Success -and $rp.Value -like 'Restore point skipped: server-os*') -Detail $rp.Value
            } else {
                Add-PnhE2eCheck -Name 'restore point attempt logged (created or skipped)' -Ok $rp.Success -Detail $rp.Value
            }
        }
        if ($left.Count -gt 0) { Add-PnhE2eNote -Warning ('Ollama processes were still running after the run and were stopped: ' + ($left -join ', ')) }
        if ($result) { Add-PnhE2eNote ('summary: ' + ([string](Get-PnhE2eMember $result 'summary') -replace '\s+', ' ')) }
    }

    'network-readonly' {
        $before = Get-PnhE2eNetworkSnapshot
        Write-PnhE2eText -Path (Join-Path $OutDir 'network-before.json') -Text (ConvertTo-Json -InputObject $before -Depth 3)

        $run = Invoke-PnhE2eHeadless -Label 'network-readonly' -Arguments (@('-Category', 'network', '-ReadOnly') + $headlessArgs)
        $left = @(Stop-PnhE2eDriveOllama -Root $script:E2eRoot)
        $after = Get-PnhE2eNetworkSnapshot
        Write-PnhE2eText -Path (Join-Path $OutDir 'network-after.json') -Text (ConvertTo-Json -InputObject $after -Depth 3)

        Add-PnhE2eCheck -Name ('Run-Headless finished within {0} min' -f $TimeoutMinutes) -Ok (-not $run.TimedOut) -Detail ('{0} s' -f $run.Seconds)
        Add-PnhE2eCheck -Name 'exit code 0 or 1, never 2' -Ok ($run.ExitCode -eq 0 -or $run.ExitCode -eq 1) -Detail ('exit ' + $run.ExitCode)
        $result = ConvertFrom-PnhE2eResultJson -Text $run.StdOut
        Add-PnhE2eCheck -Name 'stdout is the JSON result' -Ok ($null -ne $result)
        if ($result) {
            Add-PnhE2eCheck -Name 'JSON: readOnly = true and exitCode matches the process' -Ok ((Get-PnhE2eMember $result 'readOnly') -eq $true -and [string](Get-PnhE2eMember $result 'exitCode') -eq [string]$run.ExitCode) -Detail ('solved {0}, stoppedReason {1}, rounds {2}, wouldHelp: {3}' -f (Get-PnhE2eMember $result 'solved'), (Get-PnhE2eMember $result 'stoppedReason'), (Get-PnhE2eMember $result 'rounds'), (@(Get-PnhE2eMember $result 'wouldHelp') -join '; '))
        }

        $changing = Get-PnhE2eChangeMap
        $actions = @()
        if ($result) { $actions = @(Get-PnhE2eMember $result 'actions' | Where-Object { $null -ne $_ }) }
        $bad = @($actions | Where-Object { $changing[[string](Get-PnhE2eMember $_ 'id')] -eq $true -and -not (Get-PnhE2eMember $_ 'skipped') })
        $list = (@($actions | ForEach-Object { '{0}:skipped={1}' -f (Get-PnhE2eMember $_ 'id'), (Get-PnhE2eMember $_ 'skipped') }) -join ', ')
        Add-PnhE2eCheck -Name 'no changing catalogue action ran (each one was skipped)' -Ok ($bad.Count -eq 0) -Detail $list
        $unknownIds = @($actions | Where-Object { -not $changing.ContainsKey([string](Get-PnhE2eMember $_ 'id')) } | ForEach-Object { [string](Get-PnhE2eMember $_ 'id') })
        if ($unknownIds.Count -gt 0) { Add-PnhE2eNote ('calls that are not catalogue actions: ' + ($unknownIds -join ', ')) }

        $rf = Get-PnhE2eRunFolder -Result $result
        Add-PnhE2eCheck -Name 'run folder exists' -Ok ([bool]$rf) -Detail $rf
        if ($rf) {
            $missing = @(@('run.log', 'diagnose.json', 'summary.txt') | Where-Object { -not (Test-Path -LiteralPath (Join-Path $rf $_) -PathType Leaf) })
            Add-PnhE2eCheck -Name 'run folder has run.log, diagnose.json, summary.txt' -Ok ($missing.Count -eq 0) -Detail $(if ($missing.Count) { 'missing: ' + ($missing -join ', ') } else { '' })
            $log = Read-PnhE2eText -Path (Join-Path $rf 'run.log')
            $rp = [regex]::Match($log, 'Restore point (skipped|created)[^\r\n]*')
            Add-PnhE2eCheck -Name 'no restore point attempt' -Ok (-not $rp.Success) -Detail $rp.Value
            $changedBackups = @()
            $backups = Join-Path $rf 'backups'
            if (Test-Path -LiteralPath $backups) {
                foreach ($req in @(Get-ChildItem -LiteralPath $backups -Recurse -Filter 'request.json' -File -ErrorAction SilentlyContinue)) {
                    $id = ''
                    try { $id = [string](ConvertFrom-Json -InputObject (Read-PnhE2eText -Path $req.FullName)).Id } catch { $id = $req.Directory.Name }
                    if (-not $changing.ContainsKey($id) -or $changing[$id]) { $changedBackups += $id }
                }
            }
            Add-PnhE2eCheck -Name 'no backup folder of a changing action' -Ok ($changedBackups.Count -eq 0) -Detail ($changedBackups -join ', ')
        }

        $diff = @($before.Keys | Where-Object { [string]$before[$_] -ne [string]$after[$_] })
        $detail = ''
        foreach ($k in $diff) { $detail += ('{0}: before {1} after {2}; ' -f $k, $before[$k], $after[$k]) }
        Add-PnhE2eCheck -Name 'network configuration unchanged' -Ok ($diff.Count -eq 0) -Detail $(if ($diff.Count) { $detail } else { ('{0} probes compared' -f $before.Count) })
        if ($left.Count -gt 0) { Add-PnhE2eNote -Warning ('Ollama processes were still running after the run and were stopped: ' + ($left -join ', ')) }
        if ($run.AbortedRestarts -gt 0) { Add-PnhE2eNote -Warning ('a restart was requested in read-only mode and aborted by the CI guard ({0})' -f $run.AbortedRestarts) }
        if ($result) { Add-PnhE2eNote ('summary: ' + ([string](Get-PnhE2eMember $result 'summary') -replace '\s+', ' ')) }
    }
}

exit (Complete-PnhE2e)
