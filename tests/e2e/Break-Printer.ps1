#Requires -Version 5.1
<#
.SYNOPSIS
    CI only: breaks something harmless for the end-to-end test by stopping the Print Spooler, and proves that the
    Plug'n'Heal diagnosis sees it.

.DESCRIPTION
    Meant for throw-away CI machines (GitHub-hosted windows-latest). On any other computer it refuses to run unless
    -Force is given, because it stops the print service.

    Steps:
      1. Record the spooler state (status, start type) in -StateFile (JSON) for the evidence.
      2. If the start type is Disabled, set it to Manual: print.restart_spooler deliberately refuses a disabled
         spooler, and a disabled service is not what this test breaks.
      3. Stop-Service Spooler -Force and wait until it is stopped (max 60 s).
      4. With the app's own libraries (-AppPath, normally <drive>\PlugNHeal\app): Invoke-PnhDiagnose -Sections printer
         must set the finding SPOOLER_STOPPED, and Invoke-PnhSuccessCheck -Id check.printer must fail. Otherwise the
         end-to-end run that follows could not prove anything.

    Exit code: 0 = spooler stopped and the precondition holds, 1 = precondition not met, 2 = cannot run here.

.PARAMETER AppPath
    The app folder whose lib\ is used for the precondition check. Default: <repo>\src.
.PARAMETER StateFile
    Where to write the spooler state before the change (JSON). Optional.
.PARAMETER Force
    Run even outside GitHub Actions.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\e2e\Break-Printer.ps1 -AppPath P:\PlugNHeal\app
#>
[CmdletBinding()]
param(
    [string]$AppPath,
    [string]$StateFile,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

function Write-PnhE2eLine {
    param([string]$Text)
    [Console]::Out.WriteLine(('[{0}] {1}' -f (Get-Date).ToString('HH:mm:ss'), $Text))
}

$onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
if (-not $onWindows) {
    Write-PnhE2eLine 'ERROR: Break-Printer.ps1 needs Windows.'
    exit 2
}
if ($env:GITHUB_ACTIONS -ne 'true' -and -not $Force) {
    Write-PnhE2eLine 'ERROR: this script stops the Print Spooler and is meant for CI machines. Use -Force to run it here anyway.'
    exit 2
}
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-PnhE2eLine 'ERROR: administrator rights are needed to stop the Print Spooler.'
    exit 2
}
if (-not $AppPath) { $AppPath = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src' }
$AppPath = [System.IO.Path]::GetFullPath($AppPath)
$libDir = Join-Path $AppPath 'lib'
if (-not (Test-Path -LiteralPath (Join-Path $libDir 'Diagnose.ps1'))) {
    Write-PnhE2eLine ('ERROR: app libraries not found under ' + $libDir)
    exit 2
}

# 1. State before
$svc = Get-Service -Name Spooler -ErrorAction SilentlyContinue
if (-not $svc) {
    Write-PnhE2eLine 'ERROR: the Print Spooler service does not exist on this machine (Server Core image?).'
    exit 2
}
$before = [ordered]@{
    Time      = (Get-Date).ToString('o')
    Status    = [string]$svc.Status
    StartType = [string]$svc.StartType
    Computer  = $env:COMPUTERNAME
}
Write-PnhE2eLine ('Spooler before: status {0}, start type {1}' -f $before.Status, $before.StartType)
if ($StateFile) {
    $dir = Split-Path -Parent ([System.IO.Path]::GetFullPath($StateFile))
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
    [System.IO.File]::WriteAllText($StateFile, (ConvertTo-Json -InputObject $before), (New-Object System.Text.UTF8Encoding($false)))
}

# 2. A disabled spooler is a different problem (and one the toolbox does not touch on purpose)
if ($before.StartType -eq 'Disabled') {
    Write-PnhE2eLine 'Spooler is disabled on this image; setting the start type to Manual (CI only).'
    Set-Service -Name Spooler -StartupType Manual
}

# 3. Break it
if ($svc.Status -ne 'Stopped') {
    Stop-Service -Name Spooler -Force
}
$deadline = (Get-Date).AddSeconds(60)
do {
    Start-Sleep -Milliseconds 500
    $svc = Get-Service -Name Spooler
} while ($svc.Status -ne 'Stopped' -and (Get-Date) -lt $deadline)
if ($svc.Status -ne 'Stopped') {
    Write-PnhE2eLine ('ERROR: the spooler did not stop (status {0}).' -f $svc.Status)
    exit 1
}
Write-PnhE2eLine 'Spooler stopped.'

# 4. Precondition with the app's own diagnosis and success check
foreach ($lib in @('Common', 'Hardware', 'Models', 'Ollama', 'Diagnose', 'Toolbox', 'Agent')) {
    . (Join-Path $libDir ($lib + '.ps1'))
}
$failed = @()
$diag = Invoke-PnhDiagnose -Sections @('printer')
$flags = @($diag.Flags | ForEach-Object { [string]$_ })
Write-PnhE2eLine ('Diagnosis (printer) in {0} ms, flags: {1}' -f $diag.DurationMs, ($flags -join ', '))
if ($flags -notcontains 'SPOOLER_STOPPED') { $failed += 'the diagnosis did not set SPOOLER_STOPPED' }
$check = Invoke-PnhSuccessCheck -Id 'check.printer'
Write-PnhE2eLine ('check.printer: passed={0} ({1})' -f $check.Passed, $check.Summary)
if ($check.Passed) { $failed += 'check.printer passes although the spooler is stopped' }

if ($failed.Count -gt 0) {
    foreach ($f in $failed) { Write-PnhE2eLine ('PRECONDITION FAILED: ' + $f) }
    exit 1
}
Write-PnhE2eLine 'Precondition holds: the printer is broken and Plug''n''Heal can see it.'
exit 0
