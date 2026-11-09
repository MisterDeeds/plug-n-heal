<#
.SYNOPSIS
    Plug'n'Heal entry point, started by START.cmd in the root of the drive.

.DESCRIPTION
    0. Checks for Windows in S mode (registry value SkuPolicyRequired = 1, the same one Get-PnhSMode reads) and
       explains that Plug'n'Heal cannot run there. Real S mode normally blocks cmd.exe and powershell.exe
       before this script starts (Windows then shows its own message); the check covers the cases where the
       script does get to run, so that the person gets the right explanation instead of a later failure.
    1. Checks the PowerShell language mode. Company PCs (AppLocker/WDAC) and possibly Smart App Control force
       ConstrainedLanguage; then nothing of Plug'n'Heal can work, so it explains that and stops.
    2. Asks Windows once for administrator rights (UAC): it starts an elevated copy of itself with absolute
       paths and waits until that copy has opened the window. If the person says "No", the window still opens,
       in read-only mode (-ReadOnly), and explains that without permission it can only look, not repair.
    3. Starts Ui.ps1 without a console window (ProcessStartInfo, CreateNoWindow, -STA) and exits, so the
       START.cmd window closes.

    Rules for this file:
      * ASCII only: Windows PowerShell 5.1 reads scripts without BOM as ANSI.
      * Everything up to the language-mode check, and the console branch of Show-StartMessage, must work in
        ConstrainedLanguage: cmdlets only, no .NET types or methods, no Add-Type.
      * Never Read-Host in the elevated copy: its console window is hidden.

    Exit codes (START.cmd shows its own message for every other code):
      0  = the window was started (here or by the elevated copy)
      20 = blocked by the language mode (message shown)
      21 = files missing or damaged (message shown)
      22 = the window could not be started (message shown)
      23 = Windows is in S mode (message shown)

.PARAMETER ReadOnly
    Do not ask for administrator rights; open the window in read-only mode.
.PARAMETER ReadOnlyReason
    Why read-only (decides the explanation in the window): uac_refused, elevation_failed, not_admin.
.PARAMETER Elevated
    Internal: set on the elevated copy so that it never asks again.
.PARAMETER RunFolder
    Internal: log folder created by the first copy, so that one run has one folder.
.PARAMETER Demo
    Opens the window in demo mode (simulated work, no rights needed, nothing is changed).
#>
[CmdletBinding()]
param(
    [switch]$ReadOnly,
    [ValidateSet('uac_refused', 'elevation_failed', 'not_admin')]
    [string]$ReadOnlyReason,
    [switch]$Elevated,
    [string]$RunFolder,
    [switch]$Demo
)

$ErrorActionPreference = 'Stop'
$script:AppDir = $PSScriptRoot
$script:FullLanguage = ($ExecutionContext.SessionState.LanguageMode -eq 'FullLanguage')
$script:RunFolderPath = $null
$script:StartLogFile = $null

# -------------------------------------------------------------------------------------------------------------
# Helpers that must also work in ConstrainedLanguage
# -------------------------------------------------------------------------------------------------------------

function Get-StartLanguage {
    try {
        if ((Get-UICulture).TwoLetterISOLanguageName -eq 'de') { return 'de' }
    } catch {
        $null = $_
    }
    return 'en'
}

function Get-StartText {
    <#
    .SYNOPSIS
        Text for a key: Get-PnhText when Common.ps1 is loaded, else straight from i18n\<lang>.json, else the
        fallback, else the key itself.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$Fallback = ''
    )
    if ($script:FullLanguage -and (Get-Command -Name Get-PnhText -CommandType Function -ErrorAction SilentlyContinue)) {
        try {
            $text = Get-PnhText -Key $Key
            if ($text -and $text -ne $Key) { return [string]$text }
        } catch {
            $null = $_
        }
    }
    foreach ($lang in @((Get-StartLanguage), 'en')) {
        try {
            $file = Join-Path -Path (Join-Path -Path $script:AppDir -ChildPath 'i18n') -ChildPath ($lang + '.json')
            if (Test-Path -LiteralPath $file) {
                $json = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
                $value = $json.$Key
                if ($value) { return [string]$value }
            }
        } catch {
            $null = $_
        }
    }
    if ($Fallback) { return $Fallback }
    return $Key
}

function Write-StartLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('Info', 'Warn', 'Error')][string]$Level = 'Info'
    )
    try {
        if ($script:FullLanguage -and (Get-Command -Name Write-PnhLog -CommandType Function -ErrorAction SilentlyContinue)) {
            Write-PnhLog -Message ('Start: ' + $Message) -Level $Level
            return
        }
        if ($script:StartLogFile) {
            $line = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' [' + $Level.ToUpper() + '] Start: ' + $Message
            Add-Content -LiteralPath $script:StartLogFile -Value $line -Encoding UTF8
        }
    } catch {
        $null = $_
    }
}

function Test-StartSMode {
    <#
    .SYNOPSIS
        $true when Windows reports S mode: HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy, SkuPolicyRequired = 1
        (the value Get-PnhSMode in lib\Hardware.ps1 reads). Cmdlets only: it runs before the language-mode check.
    #>
    try {
        $policy = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -Name 'SkuPolicyRequired' -ErrorAction Stop
        return ([string]$policy.SkuPolicyRequired -eq '1')
    } catch {
        return $false
    }
}

function Initialize-StartFallbackLog {
    <#
    .SYNOPSIS
        Log file for the ConstrainedLanguage case, where Common.ps1 cannot be used. Only on a real drive
        (the PlugNHeal folder has a runtime folder); never in a source checkout.
    #>
    try {
        $root = Split-Path -Parent $script:AppDir
        if (-not (Test-Path -LiteralPath (Join-Path -Path $root -ChildPath 'runtime'))) { return }
        $folder = Join-Path -Path (Join-Path -Path $root -ChildPath 'logs') -ChildPath ($env:COMPUTERNAME + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
        $null = New-Item -ItemType Directory -Path $folder -Force
        $script:StartLogFile = Join-Path -Path $folder -ChildPath 'run.log'
    } catch {
        $script:StartLogFile = $null
    }
}

function Show-StartMessage {
    <#
    .SYNOPSIS
        Shows <Key>.title and <Key>.text: as a message box in FullLanguage, else in the visible START.cmd
        console (ConstrainedLanguage cannot load WinForms).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$FallbackTitle = "Plug'n'Heal",
        [string]$FallbackText = '',
        [switch]$Warning
    )
    $title = Get-StartText -Key ($Key + '.title') -Fallback $FallbackTitle
    $text = Get-StartText -Key ($Key + '.text') -Fallback $FallbackText
    Write-StartLog -Level Warn -Message ('Message shown: ' + $Key)
    if ($script:FullLanguage) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            Add-Type -AssemblyName System.Drawing
            # An invisible topmost owner keeps the message in front of the console window.
            $owner = New-Object System.Windows.Forms.Form
            $owner.TopMost = $true
            $owner.ShowInTaskbar = $false
            $owner.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
            $owner.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
            $owner.Size = New-Object System.Drawing.Size(1, 1)
            $owner.Opacity = 0
            $owner.Show()
            $icon = [System.Windows.Forms.MessageBoxIcon]::Information
            if ($Warning) { $icon = [System.Windows.Forms.MessageBoxIcon]::Warning }
            $null = [System.Windows.Forms.MessageBox]::Show($owner, $text, $title, [System.Windows.Forms.MessageBoxButtons]::OK, $icon)
            $owner.Close()
            $owner.Dispose()
            return
        } catch {
            Write-StartLog -Level Warn -Message ('Message box failed: ' + $_.Exception.Message)
        }
    }
    Write-Information -MessageData '' -InformationAction Continue
    Write-Information -MessageData ('  ' + $title) -InformationAction Continue
    Write-Information -MessageData '' -InformationAction Continue
    foreach ($line in ($text -split "`n")) {
        Write-Information -MessageData ('  ' + $line) -InformationAction Continue
    }
    Write-Information -MessageData '' -InformationAction Continue
    if (-not $Elevated) {
        $null = Read-Host -Prompt ('  ' + (Get-StartText -Key 'error.console.close' -Fallback 'Press Enter to close this window.'))
    }
}

# -------------------------------------------------------------------------------------------------------------
# Helpers for FullLanguage
# -------------------------------------------------------------------------------------------------------------

function ConvertTo-StartArgument {
    <#
    .SYNOPSIS
        Quotes one command-line argument by the Windows rules (CommandLineToArgvW), so that paths with spaces,
        quotes or a trailing backslash arrive unchanged.
    #>
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function Get-StartPowerShellPath {
    <#
    .SYNOPSIS
        The PowerShell executable for the window: the running one (5.1 from START.cmd, pwsh in development);
        from a 32-bit host on 64-bit Windows the 64-bit Windows PowerShell (Sysnative).
    #>
    $exe = $null
    try { $exe = (Get-Process -Id $PID).Path } catch { $exe = $null }
    if (-not $exe -or -not (Test-Path -LiteralPath $exe)) {
        $exe = Join-Path -Path $env:SystemRoot -ChildPath 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }
    if ([System.Environment]::Is64BitOperatingSystem -and -not [System.Environment]::Is64BitProcess) {
        $native = Join-Path -Path $env:SystemRoot -ChildPath 'Sysnative\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $native) { $exe = $native }
    }
    return $exe
}

function Invoke-StartElevated {
    <#
    .SYNOPSIS
        Starts this script elevated (one UAC prompt) and waits until the elevated copy has opened the window.
    .OUTPUTS
        'started' | 'refused' (the person said No) | 'failed' (anything else; the caller continues read-only)
    #>
    $argList = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', (ConvertTo-StartArgument -Value $PSCommandPath), '-Elevated')
    if ($script:RunFolderPath) { $argList += @('-RunFolder', (ConvertTo-StartArgument -Value $script:RunFolderPath)) }
    if ($Demo) { $argList += '-Demo' }
    $process = $null
    try {
        $process = Start-Process -FilePath (Get-StartPowerShellPath) -ArgumentList ($argList -join ' ') -Verb RunAs `
            -WindowStyle Hidden -PassThru -ErrorAction Stop
    } catch {
        $err = $_
        $inner = $err.Exception
        while ($null -ne $inner -and -not ($inner -is [System.ComponentModel.Win32Exception])) { $inner = $inner.InnerException }
        if ($null -ne $inner -and $inner.NativeErrorCode -eq 1223) {
            Write-StartLog -Message 'UAC prompt answered with No'
            return 'refused'
        }
        Write-StartLog -Level Warn -Message ('Elevation failed: ' + $err.Exception.Message)
        return 'failed'
    }
    # The elevated copy exits as soon as it has started the window (a few seconds). Waiting catches silent
    # failures, for example a drive letter the elevated process cannot see.
    try {
        if ($null -ne $process -and $process.WaitForExit(120000)) {
            $code = $process.ExitCode
            Write-StartLog -Message ('Elevated copy finished with code ' + $code)
            if ($code -eq 0) { return 'started' }
            return 'failed'
        }
    } catch {
        Write-StartLog -Level Warn -Message ('Cannot read the result of the elevated copy: ' + $_.Exception.Message)
    }
    return 'started'
}

function Invoke-StartUi {
    <#
    .SYNOPSIS
        Starts Ui.ps1 in its own PowerShell process without any console window.
    .DESCRIPTION
        ProcessStartInfo with UseShellExecute=$false and CreateNoWindow=$true (technik.md 4.2). No output
        redirection: this process exits right away, and a redirected pipe without a reader could break the
        window's process later. Start-PnhHidden is therefore not used here.
    #>
    param(
        [bool]$ReadOnlyMode,
        [string]$Reason
    )
    $ui = Join-Path -Path $script:AppDir -ChildPath 'Ui.ps1'
    $argList = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', (ConvertTo-StartArgument -Value $ui))
    if ($script:RunFolderPath) { $argList += @('-RunFolder', (ConvertTo-StartArgument -Value $script:RunFolderPath)) }
    if ($ReadOnlyMode) {
        $argList += '-ReadOnly'
        if ($Reason) { $argList += @('-ReadOnlyReason', $Reason) }
    }
    if ($Demo) { $argList += '-Demo' }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Get-StartPowerShellPath
    $psi.Arguments = $argList -join ' '
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $process = [System.Diagnostics.Process]::Start($psi)
    Write-StartLog -Message ('Window process started: ' + $process.Id + ' ' + $psi.Arguments)
}

# -------------------------------------------------------------------------------------------------------------
# 1. S mode and language mode (everything above this line is ConstrainedLanguage-safe)
# -------------------------------------------------------------------------------------------------------------
if (Test-StartSMode) {
    Initialize-StartFallbackLog
    Write-StartLog -Level Error -Message 'Windows is in S mode (SkuPolicyRequired = 1), stopping'
    Show-StartMessage -Key 'error.smode' -Warning `
        -FallbackTitle "Plug'n'Heal" `
        -FallbackText 'This computer is in S mode. In S mode Windows only allows apps from the Microsoft Store, so Plug''n''Heal cannot run here.'
    exit 23
}
if (-not $script:FullLanguage) {
    Initialize-StartFallbackLog
    Write-StartLog -Level Error -Message ('Language mode is ' + $ExecutionContext.SessionState.LanguageMode + ', stopping')
    Show-StartMessage -Key 'error.language_mode' -Warning `
        -FallbackTitle "Plug'n'Heal" `
        -FallbackText 'Helper programs like Plug''n''Heal are blocked on this computer. Please ask the person who looks after this computer.'
    exit 20
}

# -------------------------------------------------------------------------------------------------------------
# 2. Libraries and files
# -------------------------------------------------------------------------------------------------------------
$commonPath = Join-Path -Path $script:AppDir -ChildPath 'lib\Common.ps1'
$uiPath = Join-Path -Path $script:AppDir -ChildPath 'Ui.ps1'
try {
    . $commonPath
} catch {
    Show-StartMessage -Key 'error.damaged' -Warning -FallbackText ('Plug''n''Heal is incomplete: ' + $commonPath)
    exit 21
}
if (-not (Test-Path -LiteralPath $uiPath)) {
    Write-StartLog -Level Error -Message ('Missing: ' + $uiPath)
    Show-StartMessage -Key 'error.damaged' -Warning -FallbackText ('Plug''n''Heal is incomplete: ' + $uiPath)
    exit 21
}

# -------------------------------------------------------------------------------------------------------------
# 3. One log folder per run, shared by the elevated copy and the window
# -------------------------------------------------------------------------------------------------------------
try {
    if ($RunFolder -and (Test-Path -LiteralPath $RunFolder)) {
        $script:PnhRunFolder = $RunFolder
    } else {
        $script:PnhRunFolder = New-PnhRunFolder
    }
    $script:RunFolderPath = [string]$script:PnhRunFolder
} catch {
    $script:RunFolderPath = $null
}
Write-StartLog -Message ('Start.ps1 PowerShell {0}, elevated copy={1}, readonly={2}, demo={3}' -f
    $PSVersionTable.PSVersion, [bool]$Elevated, [bool]$ReadOnly, [bool]$Demo)

# -------------------------------------------------------------------------------------------------------------
# 4. Administrator rights: ask once
# -------------------------------------------------------------------------------------------------------------
$isAdmin = $false
try { $isAdmin = [bool](Test-PnhAdmin) } catch { $isAdmin = $false }
$readOnlyMode = $false
$reason = ''
if ($isAdmin) {
    Write-StartLog -Message 'Running with administrator rights'
} elseif ($Demo) {
    Write-StartLog -Message 'Demo mode: no rights needed'
} elseif ($ReadOnly -or $ReadOnlyReason) {
    $readOnlyMode = $true
    $reason = $ReadOnlyReason
    if (-not $reason) { $reason = 'not_admin' }
} elseif ($Elevated) {
    # The elevated copy has no rights after all: never ask a second time.
    $readOnlyMode = $true
    $reason = 'elevation_failed'
} else {
    $elevation = Invoke-StartElevated
    if ($elevation -eq 'started') {
        Write-StartLog -Message 'The elevated copy opened the window'
        exit 0
    }
    $readOnlyMode = $true
    if ($elevation -eq 'refused') { $reason = 'uac_refused' } else { $reason = 'elevation_failed' }
}

# -------------------------------------------------------------------------------------------------------------
# 5. Open the window without a console, then exit (the START.cmd window closes)
# -------------------------------------------------------------------------------------------------------------
try {
    Invoke-StartUi -ReadOnlyMode $readOnlyMode -Reason $reason
} catch {
    Write-StartLog -Level Error -Message ('Cannot start the window: ' + $_.Exception.Message)
    Show-StartMessage -Key 'error.ui_start' -Warning
    exit 22
}
exit 0
