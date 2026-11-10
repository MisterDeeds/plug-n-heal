<#
.SYNOPSIS
    Plug'n'Heal window: one window, big buttons, plain language (WinForms, Windows PowerShell 5.1).

.DESCRIPTION
    Pages: welcome -> preparing -> category (or "something else" with a text box) -> working -> result.
    Every failure ends on a friendly page; technical details go to the run log (Write-PnhLog), never on screen.

    Threading (docs/ARCHITECTURE.md 5.8): all slow work runs in ONE background runspace. Events come back
    through a ConcurrentQueue that a Windows.Forms.Timer (200 ms) drains on the UI thread. Confirmation answers
    travel through a synchronized hashtable; the background waits for them. The UI thread never blocks.

    This file is ASCII only on purpose: Windows PowerShell 5.1 reads scripts without BOM as ANSI. Symbols and
    emoji are built from code points; every word on screen comes from i18n\<lang>.json via Get-PnhText.

    DPI: the process is made system-DPI-aware and all pixel sizes are scaled by hand. Per-monitor awareness is
    not used: WinForms on .NET Framework only rescales on a monitor change when powershell.exe.config opts in,
    which we cannot ship. System-aware is sharp on the main screen and scaled by Windows elsewhere.

.PARAMETER Demo
    Simulates hardware detection, Ollama and the agent with fake events. No Ollama, no model, no changes.
.PARAMETER DemoFailure
    Only with -Demo: let one stage fail to show its error page (ollama, nomodel, slow, weak, crash).
.PARAMETER ReadOnly
    No administrator rights: look only, never repair. Confirmation requests are answered with No.
.PARAMETER ReadOnlyReason
    Why there are no rights; decides the explanation shown first (uac_refused, elevation_failed, not_admin).
.PARAMETER RunFolder
    Log folder created by Start.ps1. Without it the window creates its own.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\Ui.ps1 -Demo
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Scope = 'Function', Target = '*-Pnh*',
    Justification = 'Demo stand-ins carry the names fixed by ARCHITECTURE.md')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Scope = 'Function', Target = '*-Pnh*',
    Justification = 'Demo stand-ins carry the names fixed by ARCHITECTURE.md')]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSupportsShouldProcess', '', Scope = 'Function', Target = 'Invoke-PnhAgent',
    Justification = 'Its -Confirm parameter is the confirmation callback of ARCHITECTURE.md 5.7')]
[CmdletBinding()]
param(
    [switch]$Demo,
    [ValidateSet('none', 'ollama', 'nomodel', 'slow', 'weak', 'crash')]
    [string]$DemoFailure = 'none',
    [switch]$ReadOnly,
    [ValidateSet('uac_refused', 'elevation_failed', 'not_admin')]
    [string]$ReadOnlyReason,
    [string]$RunFolder
)

$ErrorActionPreference = 'Stop'

$script:AppDir = $PSScriptRoot
$script:IsDemo = [bool]$Demo
$script:DemoFailure = $DemoFailure
$script:IsReadOnly = [bool]$ReadOnly -or [bool]$ReadOnlyReason
$script:ReadOnlyReasonKey = $ReadOnlyReason
if ($script:IsReadOnly -and -not $script:ReadOnlyReasonKey) { $script:ReadOnlyReasonKey = 'not_admin' }

# State shared with the background runspace (ARCHITECTURE.md 5.8)
$script:Queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
$script:Sync = [hashtable]::Synchronized(@{ Cancel = $false; Server = $null; ModelEntry = $null })

# UI state
$script:Language = 'en'
$script:RunFolderPath = $null
$script:StartupError = $null
$script:Runspace = $null
$script:Job = $null
$script:Timer = $null
$script:Form = $null
$script:PageHost = $null
$script:Pages = @{}
$script:Ui = @{}
$script:Fonts = @{}
$script:WrapControls = New-Object System.Collections.ArrayList
$script:Scale = 1.0
$script:Theme = @{}
$script:HighContrast = $false
$script:InDialog = $false
$script:SpinFrame = 0
$script:PhaseStart = Get-Date
$script:CancelAt = $null
$script:CloseWhenIdle = $false
$script:ForceClose = $false
$script:CurrentPage = ''
$script:PrepRows = [ordered]@{}
$script:WorkRows = [ordered]@{}
$script:ActionTitles = @{}
$script:KeepSentence = $false
$script:CategoryId = ''
$script:CategoryTitle = ''
$script:UserText = ''
$script:Mutex = $null
$script:OwnsMutex = $false

# Minimal stand-ins for Common.ps1, used only when it is missing (demo without libraries, or a damaged drive,
# so that the error page can still speak). Shared with the background runspace as text.
$script:UiFallbackLib = @'
function Get-PnhLanguage {
    try { if ((Get-UICulture).TwoLetterISOLanguageName -eq 'de') { return 'de' } } catch { $null = $_ }
    return 'en'
}
function Get-PnhText {
    param([Parameter(Mandatory = $true, Position = 0)][string]$Key, [Parameter(Position = 1)][object[]]$Arguments)
    if (-not $script:PnhFallbackTexts) {
        $script:PnhFallbackTexts = @{}
        foreach ($lang in @('en', (Get-PnhLanguage))) {
            $file = Join-Path -Path (Join-Path -Path $script:PnhFallbackAppDir -ChildPath 'i18n') -ChildPath ($lang + '.json')
            if (Test-Path -LiteralPath $file) {
                $json = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
                foreach ($p in $json.PSObject.Properties) { $script:PnhFallbackTexts[$p.Name] = [string]$p.Value }
            }
        }
    }
    $text = $script:PnhFallbackTexts[$Key]
    if ($null -eq $text) { return $Key }
    if ($Arguments -and $Arguments.Count -gt 0) { try { return ($text -f $Arguments) } catch { return $text } }
    return $text
}
function Write-PnhLog {
    param([string]$Message, [string]$Level = 'Info', [object]$Data)
    if (-not $script:PnhRunFolder) { return }
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpperInvariant(), $Message
    if ($null -ne $Data) { try { $line += ' ' + ($Data | ConvertTo-Json -Depth 6 -Compress) } catch { $null = $_ } }
    Add-Content -LiteralPath (Join-Path -Path $script:PnhRunFolder -ChildPath 'run.log') -Value $line -Encoding UTF8
}
'@

# =============================================================================================================
# Pure helpers (no WinForms; covered by tests\Ui.Tests.ps1)
# =============================================================================================================

function Get-UiText {
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Key,
        [Parameter(Position = 1)][object[]]$Arguments
    )
    try {
        if ($Arguments -and $Arguments.Count -gt 0) {
            $text = Get-PnhText -Key $Key -Arguments $Arguments
        } else {
            $text = Get-PnhText -Key $Key
        }
        if ($null -ne $text -and [string]$text -ne '') { return [string]$text }
    } catch {
        $null = $_
    }
    return $Key
}

function Test-UiText {
    param([Parameter(Mandatory = $true, Position = 0)][string]$Key)
    return ((Get-UiText -Key $Key) -ne $Key)
}

function Write-UiLog {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('Info', 'Warn', 'Error')][string]$Level = 'Info',
        [object]$Data
    )
    try {
        if ($null -ne $Data) {
            Write-PnhLog -Message ('UI: ' + $Message) -Level $Level -Data $Data
        } else {
            Write-PnhLog -Message ('UI: ' + $Message) -Level $Level
        }
    } catch {
        $null = $_
    }
}

function Format-UiElapsed {
    param([double]$Seconds)
    if ($Seconds -lt 0) { $Seconds = 0 }
    $total = [int][Math]::Floor($Seconds)
    $hours = [int][Math]::Floor($total / 3600)
    $minutes = [int][Math]::Floor(($total % 3600) / 60)
    $secs = $total % 60
    if ($hours -gt 0) { return ('{0}:{1:00}:{2:00}' -f $hours, $minutes, $secs) }
    return ('{0}:{1:00}' -f $minutes, $secs)
}

function Get-UiRiskKey {
    param([AllowNull()][object]$Risk)
    $r = ([string]$Risk).Trim().ToLowerInvariant()
    if (@('low', 'medium', 'high') -contains $r) { return ('confirm.risk.' + $r) }
    return 'confirm.risk.unknown'
}

function Get-UiStepGlyph {
    param([string]$State, [int]$Frame = 0)
    switch ($State) {
        'waiting' { return [string][char]0x25CB }
        'running' {
            $frames = @(0x25D0, 0x25D3, 0x25D1, 0x25D2)
            return [string][char]($frames[[Math]::Abs($Frame) % 4])
        }
        'done' { return [string][char]0x2713 }
        'problem' { return [string][char]0x26A0 }
        'skipped' { return [string][char]0x2013 }
    }
    return [string][char]0x25CB
}

function Get-UiCategoryList {
    <#
    .SYNOPSIS
        Tiles for the "What is wrong?" page: "check everything" first (wide), then the categories from
        toolbox\categories.json (or the built-in six), then "something else".
    .PARAMETER HasText
        Scriptblock that returns $true when a text key exists; categories without a title text are skipped.
    #>
    param(
        [string]$Path,
        [scriptblock]$HasText = { param($k) $null = $k; $true }
    )
    $icons = @{
        network = 0x1F310; slow = 0x1F422; disk = 0x1F4BE; printer = 0x1F5A8
        sound = 0x1F50A; update = 0x1F504; other = 0x1F4AC; all = 0x1F50D
    }
    $fromFile = @()
    if ($Path -and (Test-Path -LiteralPath $Path)) {
        try {
            $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json.categories) { $fromFile = @($json.categories) }
        } catch {
            $fromFile = @()
        }
    }
    if ($fromFile.Count -eq 0) {
        $fromFile = @('network', 'slow', 'disk', 'printer', 'sound', 'update') | ForEach-Object { [pscustomobject]@{ id = $_ } }
    }
    $special = @{}
    $tiles = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($c in $fromFile) {
        if ($null -eq $c) { continue }
        $id = [string]$c.id
        if (-not $id -or $seen.ContainsKey($id)) { continue }
        $seen[$id] = $true
        $titleKey = [string]$c.titleKey
        if (-not $titleKey) { $titleKey = 'cat.' + $id }
        $icon = [string]$c.icon
        if (-not $icon) {
            if ($icons.ContainsKey($id)) { $icon = [char]::ConvertFromUtf32($icons[$id]) } else { $icon = [string][char]0x2753 }
        }
        if ($id -eq 'all' -or $id -eq 'other') { $special[$id] = @{ TitleKey = $titleKey; Icon = $icon }; continue }
        if (-not (& $HasText $titleKey)) { continue }
        $null = $tiles.Add([pscustomobject]@{ Id = $id; TitleKey = $titleKey; Icon = $icon; Kind = 'tile' })
    }
    $result = New-Object System.Collections.ArrayList
    foreach ($id in @('all', 'other')) {
        if (-not $special.ContainsKey($id)) { $special[$id] = @{ TitleKey = ('cat.' + $id); Icon = [char]::ConvertFromUtf32($icons[$id]) } }
    }
    $null = $result.Add([pscustomobject]@{ Id = 'all'; TitleKey = $special['all'].TitleKey; Icon = $special['all'].Icon; Kind = 'wide' })
    foreach ($t in $tiles) { $null = $result.Add($t) }
    $null = $result.Add([pscustomobject]@{ Id = 'other'; TitleKey = $special['other'].TitleKey; Icon = $special['other'].Icon; Kind = 'tile' })
    return $result.ToArray()
}

function Get-UiResultKind {
    param([AllowNull()][object]$Result, [switch]$Cancelled)
    if ($Cancelled) { return 'cancelled' }
    if ($null -ne $Result -and [bool]$Result.Solved) { return 'solved' }
    return 'unsolved'
}

function Get-UiStoppedKey {
    <#
    .SYNOPSIS
        Maps the agent's StoppedReason ('isolated', 'max-rounds', 'errors' ...) to result.stopped.<x>, if that text
        exists. The other reasons (finished, exhausted, time-limit ...) are explained in the agent's summary.
    #>
    param(
        [AllowNull()][object]$Reason,
        [scriptblock]$HasText = { param($k) $null = $k; $true }
    )
    $r = [string]$Reason
    if (-not $r) { return $null }
    $r = ($r -creplace '([a-z0-9])([A-Z])', '$1_$2').ToLowerInvariant() -replace '[^a-z0-9]+', '_'
    $r = $r.Trim('_')
    if (-not $r) { return $null }
    $key = 'result.stopped.' + $r
    if (& $HasText $key) { return $key }
    return $null
}

function Get-UiActionLine {
    <#
    .SYNOPSIS
        One plain-language line for an action result (Invoke-PnhAction result shape).
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Result,
        [hashtable]$Titles = @{},
        [switch]$ReadOnly
    )
    $id = [string]$Result.Id
    $title = $id
    if ($Titles -and $id -and $Titles.ContainsKey($id) -and $Titles[$id]) {
        $title = [string]$Titles[$id]
    } elseif ($Result.Title) {
        $title = [string]$Result.Title
    }
    $ok = [bool]$Result.Ok -and ($Result.Verified -ne $false)
    $key = 'event.action_failed'
    if ([bool]$Result.Declined) {
        if ($ReadOnly) { $key = 'event.action_readonly' } else { $key = 'event.action_declined' }
    } elseif ([bool]$Result.RolledBack) {
        $key = 'event.action_rolledback'
    } elseif ($ok -and [bool]$Result.NeedsReboot) {
        $key = 'event.action_reboot'
    } elseif ($ok) {
        $key = 'event.action_ok'
    }
    return [pscustomobject]@{ Key = $key; Title = $title; Ok = $ok; Text = (Get-UiText -Key $key -Arguments @($title)) }
}

function Format-UiSummary {
    <#
    .SYNOPSIS
        Text of summary.txt: short, readable aloud or as a photo for the grandchild on the phone.
    #>
    param(
        [string]$ResultTitle,
        [string]$ResultText,
        [string]$CategoryTitle,
        [string]$UserText,
        [string]$Summary,
        [string[]]$ActionLines = @(),
        [switch]$NeedsReboot,
        [switch]$ReadOnly,
        [string]$LogFolder,
        [string]$Computer = $env:COMPUTERNAME,
        [datetime]$Date = (Get-Date)
    )
    $lines = New-Object System.Collections.Generic.List[string]
    $title = Get-UiText -Key 'report.title'
    $lines.Add($title)
    $lines.Add(('=' * [Math]::Max(10, $title.Length)))
    $lines.Add((Get-UiText -Key 'report.date' -Arguments @($Date.ToString('yyyy-MM-dd HH:mm'))))
    if ($Computer) { $lines.Add((Get-UiText -Key 'report.computer' -Arguments @($Computer))) }
    if ($CategoryTitle) { $lines.Add((Get-UiText -Key 'report.problem' -Arguments @($CategoryTitle))) }
    if ($UserText) { $lines.Add((Get-UiText -Key 'report.user_text' -Arguments @($UserText))) }
    $lines.Add((Get-UiText -Key 'report.result' -Arguments @($ResultTitle)))
    if ($ResultText) { $lines.Add(''); $lines.Add($ResultText) }
    if ($Summary) {
        $lines.Add('')
        $lines.Add((Get-UiText -Key 'report.summary'))
        $lines.Add($Summary)
    }
    $lines.Add('')
    $lines.Add((Get-UiText -Key 'report.actions'))
    $actions = @($ActionLines | Where-Object { $_ })
    if ($actions.Count -eq 0) { $lines.Add('- ' + (Get-UiText -Key 'result.actions.none')) }
    foreach ($a in $actions) { $lines.Add('- ' + $a) }
    if ($NeedsReboot) { $lines.Add(''); $lines.Add((Get-UiText -Key 'report.reboot')) }
    if ($ReadOnly) { $lines.Add(''); $lines.Add((Get-UiText -Key 'report.readonly')) }
    if ($LogFolder) { $lines.Add(''); $lines.Add((Get-UiText -Key 'report.log' -Arguments @($LogFolder))) }
    return (($lines -join "`r`n") + "`r`n")
}

function Build-UiJob {
    <#
    .SYNOPSIS
        A [powershell] instance that runs the job script in the given runspace with named parameters.
    #>
    param(
        [Parameter(Mandatory = $true)][object]$Runspace,
        [Parameter(Mandatory = $true)][scriptblock]$Script,
        [hashtable]$Parameters = @{}
    )
    $ps = [powershell]::Create()
    $ps.Runspace = $Runspace
    $null = $ps.AddScript($Script.ToString())
    foreach ($k in $Parameters.Keys) { $null = $ps.AddParameter($k, $Parameters[$k]) }
    return $ps
}

# =============================================================================================================
# Background job (runs in the background runspace; talks to the UI only through Queue and Sync)
# =============================================================================================================

$script:JobScript = {
    param(
        [string]$Kind,
        [string]$AppDir,
        [string]$RunFolder,
        [object]$Queue,
        [object]$Sync,
        [bool]$Demo = $false,
        [string]$DemoFailure = 'none',
        [double]$DemoDelay = 1.0,
        [string]$FallbackLib = '',
        [bool]$ReadOnly = $false,
        [string]$Language = 'en',
        [string]$Category = '',
        [string]$UserText = ''
    )
    $ErrorActionPreference = 'Stop'
    $PnhUiQueue = $Queue
    $PnhUiSync = $Sync

    function Send-JobEvent {
        param([hashtable]$Data)
        $PnhUiQueue.Enqueue($Data)
    }
    function Write-JobLog {
        param([string]$Message, [string]$Level = 'Info', [object]$Data)
        try {
            if ($null -ne $Data) { Write-PnhLog -Message ('Job: ' + $Message) -Level $Level -Data $Data }
            else { Write-PnhLog -Message ('Job: ' + $Message) -Level $Level }
        } catch {
            $null = $_
        }
    }
    function Assert-JobNotCancelled {
        if ($PnhUiSync.Cancel) { throw 'PNH_CANCELLED' }
    }
    function Wait-Demo {
        param([int]$Milliseconds)
        Start-Sleep -Milliseconds ([int][Math]::Max(1, $Milliseconds * $DemoDelay))
    }

    # --- libraries -------------------------------------------------------------------------------------
    try {
        $libDir = Join-Path -Path $AppDir -ChildPath 'lib'
        $commonFile = Join-Path -Path $libDir -ChildPath 'Common.ps1'
        if (Test-Path -LiteralPath $commonFile) {
            . $commonFile
        } elseif ($Demo -and $FallbackLib) {
            $script:PnhFallbackAppDir = $AppDir
            . ([scriptblock]::Create($FallbackLib))
        } else {
            throw ('Missing library: ' + $commonFile)
        }
        if (-not $Demo) {
            foreach ($name in @('Hardware', 'Models', 'Ollama', 'Diagnose', 'Toolbox', 'Agent')) {
                . (Join-Path -Path $libDir -ChildPath ($name + '.ps1'))
            }
        }
        $script:PnhRunFolder = $RunFolder
    } catch {
        $loadError = $_
        $script:PnhRunFolder = $RunFolder
        Write-JobLog -Level Error -Message ('Cannot load libraries: ' + $loadError.Exception.Message) -Data @{ Stack = $loadError.ScriptStackTrace }
        Send-JobEvent @{ Type = 'fatal'; Key = 'error.damaged' }
        return
    }

    # --- demo stand-ins: same flow, fake work -----------------------------------------------------------
    if ($Demo) {
        Write-JobLog -Message ('Demo mode (' + $Kind + '), simulated failure: ' + $DemoFailure + ', delay factor ' + $DemoDelay)
        function Get-PnhHardware {
            Wait-Demo 1200
            if ($DemoFailure -eq 'crash') { throw 'Demo: simulated crash during hardware detection' }
            return @{ RamBytes = 16GB; FreeRamBytes = 9GB; BestDedicatedVramBytes = 0; CpuName = 'Demo CPU'; Gpus = @()
                Os = @{ Caption = 'Windows 11 (demo)'; SMode = $false }; LanguageMode = 'FullLanguage'; IsAdmin = $true }
        }
        function Get-PnhInstalledModels {
            if ($DemoFailure -eq 'nomodel') { return @() }
            return @('qwen3.5:2b-q4_K_M', 'qwen3.5:0.8b-q8_0')
        }
        function Get-PnhPaths { return @{ Root = $AppDir; App = $AppDir } }
        function Select-PnhModel {
            param([object]$Hardware, [string[]]$Installed, [string]$Prefer)
            $null = $Hardware, $Installed, $Prefer
            Wait-Demo 800
            if ($DemoFailure -eq 'weak') {
                return @{ Model = $null; Reason = 'model.reason.weak_hardware'; Path = 'too_weak'; Ctx = 0; UseGpu = $false; Fallbacks = @(); Candidates = @() }
            }
            $first = @{ id = 'demo-2b'; tag = 'qwen3.5:2b-q4_K_M'; tier = 1; ctx = 8192 }
            $second = @{ id = 'demo-0.8b'; tag = 'qwen3.5:0.8b-q8_0'; tier = 1; ctx = 4096 }
            return @{ Model = $first; Reason = 'model.reason.cpu'; Path = 'cpu'; Ctx = 8192; UseGpu = $false; Fallbacks = @($second)
                Candidates = @(@{ Model = $first; Tag = $first.tag; UseGpu = $false; Ctx = 8192 }, @{ Model = $second; Tag = $second.tag; UseGpu = $false; Ctx = 4096 }) }
        }
        function Start-PnhOllama {
            param([object]$Paths, [int]$Port, [int]$ContextLength)
            $null = $Paths, $Port, $ContextLength
            Wait-Demo 2000
            if ($DemoFailure -eq 'ollama') { throw 'Demo: simulated Ollama start failure' }
            return @{ BaseUrl = 'http://127.0.0.1:0'; Port = 0; Process = $null; Version = 'demo' }
        }
        function Stop-PnhOllama { param([object]$Server) $null = $Server }
        function Test-PnhModelFit {
            param([object]$Server, [string]$Model, [object]$ModelEntry, [switch]$UseGpu, [int]$NumCtx)
            $null = $Server, $Model, $ModelEntry, $UseGpu, $NumCtx
            Wait-Demo 1500
            return @{ OnGpuPercent = 0; TokensPerSecond = 12.5; Ok = ($DemoFailure -ne 'slow') }
        }
        function Invoke-PnhAgent {
            param([object]$Server, [object]$ModelEntry, [string]$Category, [string]$UserText, [string]$RunFolder,
                [scriptblock]$OnEvent, [scriptblock]$Confirm, [int]$MaxRounds = 30, [int]$MaxMinutes = 30, [string]$Language = 'en')
            $null = $Server, $ModelEntry, $Category, $UserText, $RunFolder, $MaxRounds, $MaxMinutes, $Language
            & $OnEvent @{ Type = 'step-start'; Key = 'step.diagnose'; Text = (Get-PnhText -Key 'step.diagnose') }
            Wait-Demo 2500
            & $OnEvent @{ Type = 'step-done'; Key = 'step.diagnose'; Ok = $true }
            & $OnEvent @{ Type = 'thinking' }
            Wait-Demo 2000
            & $OnEvent @{ Type = 'message'; Text = (Get-PnhText -Key 'demo.message') }
            Wait-Demo 1500
            & $OnEvent @{ Type = 'step-start'; Key = 'step.repair'; Text = (Get-PnhText -Key 'step.repair') }
            $title1 = Get-PnhText -Key 'demo.action1.title'
            & $OnEvent @{ Type = 'action'; Id = 'net.flush_dns'; Title = $title1 }
            Wait-Demo 2000
            $r1 = @{ Id = 'net.flush_dns'; Ok = $true; Verified = $true; Declined = $false; Output = ''; Error = $null; RolledBack = $false; NeedsReboot = $false }
            & $OnEvent @{ Type = 'action-result'; Result = $r1 }
            $title2 = Get-PnhText -Key 'demo.action2.title'
            & $OnEvent @{ Type = 'action'; Id = 'net.restart_adapter'; Title = $title2 }
            $yes = [bool](& $Confirm @{ Title = $title2; Explain = (Get-PnhText -Key 'demo.action2.explain'); Risk = 'medium'; Reboot = $false })
            Wait-Demo 1500
            $r2 = @{ Id = 'net.restart_adapter'; Ok = $yes; Verified = $yes; Declined = (-not $yes); Output = ''; Error = $null; RolledBack = $false; NeedsReboot = $false }
            & $OnEvent @{ Type = 'action-result'; Result = $r2 }
            & $OnEvent @{ Type = 'step-done'; Key = 'step.repair'; Ok = $true }
            & $OnEvent @{ Type = 'step-start'; Key = 'step.verify'; Text = (Get-PnhText -Key 'step.verify') }
            Wait-Demo 2000
            & $OnEvent @{ Type = 'step-done'; Key = 'step.verify'; Ok = $true }
            $summary = Get-PnhText -Key 'demo.summary'
            & $OnEvent @{ Type = 'done'; Solved = $true; Summary = $summary }
            return @{ Solved = $true; Summary = $summary; Rounds = 3; Actions = @($r1, $r2); StoppedReason = 'finished' }
        }
    }

    # --- job: prepare (hardware -> model -> Ollama -> fit test, stepping down) ---------------------------
    if ($Kind -eq 'prepare') {
        $server = $null
        $failKey = 'error.unexpected'
        $current = 'step.hardware'
        try {
            Send-JobEvent @{ Type = 'prep-step'; Key = 'step.hardware'; State = 'running' }
            $hardware = Get-PnhHardware
            Write-JobLog -Message 'Hardware detected' -Data $hardware
            Send-JobEvent @{ Type = 'prep-step'; Key = 'step.hardware'; State = 'done' }
            Assert-JobNotCancelled

            $current = 'step.model'
            Send-JobEvent @{ Type = 'prep-step'; Key = 'step.model'; State = 'running' }
            $installed = @(Get-PnhInstalledModels | Where-Object { $_ })
            Write-JobLog -Message ('Installed models: ' + ($installed -join ', '))
            if ($installed.Count -eq 0) { $failKey = 'error.no_model'; throw 'No model installed on the drive.' }
            $selection = Select-PnhModel -Hardware $hardware -Installed $installed
            if ($null -eq $selection -or $null -eq $selection.Model) {
                # Select-PnhModel returns no model when the RAM is smaller than every installed model needs
                # (Path 'too_weak') or when nothing is installed (Reason none_installed).
                $failKey = 'error.computer_too_weak'
                if ($null -ne $selection -and [string]$selection.Reason -eq 'model.reason.none_installed' -and -not $Demo) { $failKey = 'error.no_model' }
                throw 'No installed model fits this computer.'
            }
            Write-JobLog -Message 'Model selected' -Data @{ Tag = [string]$selection.Model.tag; Reason = [string]$selection.Reason; Ctx = $selection.Ctx; UseGpu = $selection.UseGpu }
            Send-JobEvent @{ Type = 'prep-step'; Key = 'step.model'; State = 'done'; ReasonKey = [string]$selection.Reason }
            Assert-JobNotCancelled

            $current = 'step.start'
            Send-JobEvent @{ Type = 'prep-step'; Key = 'step.start'; State = 'running' }
            $failKey = 'error.ollama_start'
            $startArgs = @{ Paths = (Get-PnhPaths) }
            if ([int]$selection.Ctx -gt 0) { $startArgs.ContextLength = [int]$selection.Ctx }
            $server = Start-PnhOllama @startArgs
            $PnhUiSync.Server = $server
            Write-JobLog -Message 'Ollama started' -Data @{ BaseUrl = [string]$server.BaseUrl; Version = [string]$server.Version }
            $failKey = 'error.unexpected'

            # Step down through Select-PnhModel's Candidates: each one with its own GPU/CPU placement and context
            # length (Get-PnhModelContext), sent per request as num_ctx, so no Ollama restart is needed.
            $chosen = $null
            $candidates = @()
            if ($selection.ContainsKey('Candidates')) { $candidates = @(@($selection.Candidates) | Where-Object { $null -ne $_ }) }
            if ($candidates.Count -eq 0) { $candidates = @(@{ Model = $selection.Model; UseGpu = [bool]$selection.UseGpu; Ctx = [int]$selection.Ctx }) }
            foreach ($candidate in $candidates) {
                Assert-JobNotCancelled
                $tag = [string]$candidate.Model.tag
                $fitArgs = @{ Server = $server; Model = $tag; ModelEntry = $candidate.Model; UseGpu = [bool]$candidate.UseGpu }
                if ([int]$candidate.Ctx -gt 0) { $fitArgs.NumCtx = [int]$candidate.Ctx }
                $fit = Test-PnhModelFit @fitArgs
                Write-JobLog -Message ('Model fit ' + $tag) -Data $fit
                if ($null -ne $fit -and [bool]$fit.Ok) { $chosen = $candidate; break }
            }
            if ($null -eq $chosen) { $failKey = 'error.model_too_slow'; throw 'No installed model is fast enough on this computer.' }
            # The agent gets the candidate's entry: its ctx is the context length this model was tested with.
            $PnhUiSync.ModelEntry = $chosen.Model
            Write-JobLog -Message 'Model chosen' -Data @{ Tag = [string]$chosen.Model.tag; UseGpu = [bool]$chosen.UseGpu; Ctx = [int]$chosen.Ctx }
            Send-JobEvent @{ Type = 'prep-step'; Key = 'step.start'; State = 'done' }
            Send-JobEvent @{ Type = 'prepared'; Model = [string]$chosen.Model.tag }
        } catch {
            $err = $_
            if ($null -ne $server) {
                try { Stop-PnhOllama -Server $server } catch { Write-JobLog -Level Warn -Message ('Stop-PnhOllama failed: ' + $_.Exception.Message) }
                $PnhUiSync.Server = $null
            }
            if ($PnhUiSync.Cancel) {
                Write-JobLog -Message 'Preparation cancelled by the user'
                Send-JobEvent @{ Type = 'cancelled' }
            } else {
                Write-JobLog -Level Error -Message ('Preparation failed (' + $failKey + '): ' + $err.Exception.Message) -Data @{ Stack = $err.ScriptStackTrace; Detail = ($err | Out-String) }
                Send-JobEvent @{ Type = 'prep-step'; Key = $current; State = 'problem' }
                Send-JobEvent @{ Type = 'fatal'; Key = $failKey }
            }
        }
        return
    }

    # --- job: agent --------------------------------------------------------------------------------------
    if ($Kind -eq 'agent') {
        try {
            $onEvent = {
                param($Data)
                if ($PnhUiSync.Cancel) { throw 'PNH_CANCELLED' }
                $PnhUiQueue.Enqueue($Data)
            }.GetNewClosure()
            $confirm = {
                param($Request)
                if ($PnhUiSync.Cancel) { return $false }
                $id = [guid]::NewGuid().ToString('N')
                $answerKey = 'answer.' + $id
                $PnhUiQueue.Enqueue(@{ Type = 'confirm'; Id = $id; Request = $Request })
                while ($true) {
                    if ($PnhUiSync.ContainsKey($answerKey)) {
                        $answer = [bool]$PnhUiSync[$answerKey]
                        $PnhUiSync.Remove($answerKey)
                        return $answer
                    }
                    if ($PnhUiSync.Cancel) { return $false }
                    Start-Sleep -Milliseconds 150
                }
            }.GetNewClosure()

            $agentParams = @{
                Server     = $PnhUiSync.Server
                ModelEntry = $PnhUiSync.ModelEntry
                Category   = $Category
                RunFolder  = $RunFolder
                OnEvent    = $onEvent
                Confirm    = $confirm
            }
            $agentCommand = Get-Command -Name Invoke-PnhAgent
            if ($agentCommand.Parameters.ContainsKey('Language')) { $agentParams.Language = $Language }
            if ($UserText) { $agentParams.UserText = $UserText }
            if ($ReadOnly -and $agentCommand.Parameters.ContainsKey('ReadOnly')) { $agentParams.ReadOnly = $true }
            Write-JobLog -Message ('Agent starts, category ' + $Category)
            $result = @(Invoke-PnhAgent @agentParams) | Select-Object -Last 1
            Write-JobLog -Message 'Agent finished' -Data @{ Solved = [bool]$result.Solved; Rounds = $result.Rounds; StoppedReason = [string]$result.StoppedReason }
            Send-JobEvent @{ Type = 'finished'; Result = $result; Cancelled = [bool]$PnhUiSync.Cancel }
        } catch {
            $err = $_
            if ($PnhUiSync.Cancel) {
                Write-JobLog -Message 'Agent cancelled by the user'
                Send-JobEvent @{ Type = 'finished'; Result = $null; Cancelled = $true }
            } else {
                Write-JobLog -Level Error -Message ('Agent failed: ' + $err.Exception.Message) -Data @{ Stack = $err.ScriptStackTrace; Detail = ($err | Out-String) }
                Send-JobEvent @{ Type = 'fatal'; Key = 'error.unexpected' }
            }
        }
        return
    }

    Send-JobEvent @{ Type = 'fatal'; Key = 'error.unexpected' }
}

# =============================================================================================================
# WinForms helpers
# =============================================================================================================

function ConvertTo-UiPx {
    param([double]$Value)
    return [int][Math]::Round($Value * $script:Scale)
}

function Initialize-UiDpi {
    <#
    .SYNOPSIS
        Makes the process system-DPI-aware before the first window exists (guarded; failures are logged only).
    #>
    try {
        $setMode = [System.Windows.Forms.Application].GetMethod('SetHighDpiMode')
        if ($null -ne $setMode) {
            # PowerShell 7 (.NET WinForms)
            $modeType = [System.Windows.Forms.Application].Assembly.GetType('System.Windows.Forms.HighDpiMode')
            $null = $setMode.Invoke($null, @([Enum]::Parse($modeType, 'SystemAware')))
            return 'SetHighDpiMode(SystemAware)'
        }
    } catch {
        Write-UiLog -Level Warn -Message ('SetHighDpiMode failed: ' + $_.Exception.Message)
    }
    try {
        if (-not ('PnhUiNative' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PnhUiNative {
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("shcore.dll")]
    public static extern int SetProcessDpiAwareness(int value);
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
'@
        }
    } catch {
        Write-UiLog -Level Warn -Message ('DPI helper not available: ' + $_.Exception.Message)
        return 'none'
    }
    try { if ([PnhUiNative]::SetProcessDpiAwarenessContext([IntPtr]::new(-2))) { return 'SystemAware(context)' } } catch { $null = $_ }
    try { if ([PnhUiNative]::SetProcessDpiAwareness(1) -eq 0) { return 'SystemAware(shcore)' } } catch { $null = $_ }
    try { if ([PnhUiNative]::SetProcessDPIAware()) { return 'SystemAware(legacy)' } } catch { $null = $_ }
    return 'none'
}

function Initialize-UiTheme {
    $script:HighContrast = [bool][System.Windows.Forms.SystemInformation]::HighContrast
    if ($script:HighContrast) {
        $sc = [System.Drawing.SystemColors]
        $script:Theme = @{
            Back = $sc::Window; Text = $sc::WindowText; Muted = $sc::WindowText
            Primary = $sc::Highlight; PrimaryText = $sc::HighlightText
            Button = $sc::ButtonFace; ButtonText = $sc::ButtonText; Border = $sc::WindowText; Focus = $sc::Highlight
            Ok = $sc::WindowText; Warn = $sc::WindowText; Banner = $sc::Info; BannerText = $sc::InfoText
            Tile = $sc::ButtonFace; TileText = $sc::ButtonText; Link = $sc::HotTrack
        }
        return
    }
    $c = { param($hex) [System.Drawing.ColorTranslator]::FromHtml($hex) }
    # Contrast on white: Text 17:1, Muted 10:1, Primary 6.4:1, Ok 6:1, Warn 6.7:1 (WCAG AA for all sizes)
    $script:Theme = @{
        Back = (& $c '#FFFFFF'); Text = (& $c '#1A1A1A'); Muted = (& $c '#404040')
        Primary = (& $c '#0B5CAD'); PrimaryText = (& $c '#FFFFFF')
        Button = (& $c '#E6E6E6'); ButtonText = (& $c '#1A1A1A'); Border = (& $c '#5A5A5A'); Focus = (& $c '#000000')
        Ok = (& $c '#0E6E0E'); Warn = (& $c '#8A4600'); Banner = (& $c '#FFF4CE'); BannerText = (& $c '#3B2E00')
        Tile = (& $c '#EEF3F9'); TileText = (& $c '#1A1A1A'); Link = (& $c '#0B5CAD')
    }
}

function Get-UiFont {
    param([double]$Size = 15, [switch]$Bold, [string]$Family = 'Segoe UI')
    $key = '{0}|{1}|{2}' -f $Family, $Size, [bool]$Bold
    if (-not $script:Fonts.ContainsKey($key)) {
        $style = [System.Drawing.FontStyle]::Regular
        if ($Bold) { $style = [System.Drawing.FontStyle]::Bold }
        $script:Fonts[$key] = New-Object System.Drawing.Font($Family, [single]$Size, $style, [System.Drawing.GraphicsUnit]::Point)
    }
    return $script:Fonts[$key]
}

function New-UiPadding {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates a value object only')]
    param([double]$Left = 0, [double]$Top = 0, [double]$Right = 0, [double]$Bottom = 0)
    return New-Object System.Windows.Forms.Padding((ConvertTo-UiPx $Left), (ConvertTo-UiPx $Top), (ConvertTo-UiPx $Right), (ConvertTo-UiPx $Bottom))
}

function Register-UiWrap {
    param([Parameter(Mandatory = $true)][object]$Control, [int]$Indent = 0, [switch]$FixedWidth)
    $null = $script:WrapControls.Add(@{ Control = $Control; Indent = $Indent; Fixed = [bool]$FixedWidth })
}

function Update-UiWrap {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Layout only')]
    param()
    if (-not $script:PageHost) { return }
    $width = $script:PageHost.ClientSize.Width - (ConvertTo-UiPx 64) - [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth - (ConvertTo-UiPx 4)
    if ($width -lt (ConvertTo-UiPx 240)) { $width = ConvertTo-UiPx 240 }
    foreach ($entry in $script:WrapControls) {
        $max = $width - $entry.Indent
        if ($max -lt 120) { $max = 120 }
        if ($entry.Fixed) {
            $entry.Control.Width = $max
        } else {
            $entry.Control.MaximumSize = New-Object System.Drawing.Size($max, 0)
        }
    }
}

function Build-UiLabel {
    param(
        [string]$Text = '',
        [double]$Size = 17,
        [switch]$Bold,
        [string]$Color = 'Text',
        [string]$Family = 'Segoe UI',
        [int]$Indent = 0,
        [switch]$NoWrap
    )
    $label = New-Object System.Windows.Forms.Label
    $label.Text = $Text
    $label.UseMnemonic = $false
    $label.AutoSize = $true
    $label.Font = Get-UiFont -Size $Size -Bold:$Bold -Family $Family
    $label.ForeColor = $script:Theme[$Color]
    $label.BackColor = [System.Drawing.Color]::Transparent
    $label.Margin = New-UiPadding 0 0 0 10
    if (-not $NoWrap) { Register-UiWrap -Control $label -Indent $Indent }
    return $label
}

function Format-UiButton {
    <#
    .SYNOPSIS
        Colours and a thick, clearly visible focus frame for keyboard users. High contrast: system look.
    #>
    param([Parameter(Mandatory = $true)][object]$Button, [ValidateSet('primary', 'secondary', 'tile')][string]$Style = 'secondary')
    $Button.Cursor = [System.Windows.Forms.Cursors]::Hand
    if ($script:HighContrast) {
        $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Standard
        return
    }
    $Button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $Button.UseVisualStyleBackColor = $false
    switch ($Style) {
        'primary' { $back = $script:Theme.Primary; $fore = $script:Theme.PrimaryText; $border = $script:Theme.Primary }
        'tile' { $back = $script:Theme.Tile; $fore = $script:Theme.TileText; $border = $script:Theme.Border }
        default { $back = $script:Theme.Button; $fore = $script:Theme.ButtonText; $border = $script:Theme.Border }
    }
    $Button.BackColor = $back
    $Button.ForeColor = $fore
    $Button.FlatAppearance.BorderColor = $border
    $Button.FlatAppearance.BorderSize = 2
    # Same colour on hover and press, so that emoji images keep a matching background.
    $Button.FlatAppearance.MouseOverBackColor = $back
    $Button.FlatAppearance.MouseDownBackColor = $back
    $focusColor = $script:Theme.Focus
    $normalBorder = $border
    $Button.Add_GotFocus({ param($s, $e) $null = $e; $s.FlatAppearance.BorderColor = $focusColor; $s.FlatAppearance.BorderSize = 5 }.GetNewClosure())
    $Button.Add_LostFocus({ param($s, $e) $null = $e; $s.FlatAppearance.BorderColor = $normalBorder; $s.FlatAppearance.BorderSize = 2 }.GetNewClosure())
    $Button.Add_MouseEnter({ param($s, $e) $null = $e; if (-not $s.Focused) { $s.FlatAppearance.BorderSize = 4 } }.GetNewClosure())
    $Button.Add_MouseLeave({ param($s, $e) $null = $e; if (-not $s.Focused) { $s.FlatAppearance.BorderSize = 2 } }.GetNewClosure())
}

function Build-UiButton {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [switch]$Primary,
        [double]$FontSize = 18,
        [double]$MinWidth = 220,
        [double]$MinHeight = 64
    )
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.UseMnemonic = $false
    $b.AutoSize = $true
    $b.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $b.MinimumSize = New-Object System.Drawing.Size((ConvertTo-UiPx $MinWidth), (ConvertTo-UiPx $MinHeight))
    $b.Padding = New-UiPadding 18 6 18 6
    $b.Margin = New-UiPadding 0 0 16 8
    $b.Font = Get-UiFont -Size $FontSize -Bold:$Primary
    $b.AccessibleName = $Text
    $style = 'secondary'
    if ($Primary) { $style = 'primary' }
    Format-UiButton -Button $b -Style $style
    return $b
}

function Build-UiEmojiImage {
    <#
    .SYNOPSIS
        Renders an emoji (monochrome, GDI) on an opaque background into a bitmap for a tile button.
    #>
    param([string]$Emoji, [double]$Size = 34, [System.Drawing.Color]$Fore, [System.Drawing.Color]$Back)
    $font = New-Object System.Drawing.Font('Segoe UI Emoji', [single]$Size, [System.Drawing.FontStyle]::Regular, [System.Drawing.GraphicsUnit]::Point)
    try {
        $sz = [System.Windows.Forms.TextRenderer]::MeasureText($Emoji, $font)
        $bmp = New-Object System.Drawing.Bitmap([Math]::Max(1, $sz.Width), [Math]::Max(1, $sz.Height))
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        try {
            $g.Clear($Back)
            [System.Windows.Forms.TextRenderer]::DrawText($g, $Emoji, $font, (New-Object System.Drawing.Point(0, 0)), $Fore, $Back)
        } finally {
            $g.Dispose()
        }
        return $bmp
    } finally {
        $font.Dispose()
    }
}

function Build-UiIcon {
    # A white cross on a blue circle, so that the window is easy to find in the taskbar.
    $bmp = New-Object System.Drawing.Bitmap(32, 32)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.Clear([System.Drawing.Color]::Transparent)
        $brush = New-Object System.Drawing.SolidBrush([System.Drawing.ColorTranslator]::FromHtml('#0B5CAD'))
        $g.FillEllipse($brush, 1, 1, 30, 30)
        $brush.Dispose()
        $g.FillRectangle([System.Drawing.Brushes]::White, 13, 6, 6, 20)
        $g.FillRectangle([System.Drawing.Brushes]::White, 6, 13, 20, 6)
    } finally {
        $g.Dispose()
    }
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}

function Build-UiPage {
    <#
    .SYNOPSIS
        A page: scrollable body (top to bottom) and a button bar that always stays visible at the bottom.
    #>
    param([Parameter(Mandatory = $true)][string]$Name)
    $page = New-Object System.Windows.Forms.TableLayoutPanel
    $page.Dock = [System.Windows.Forms.DockStyle]::Fill
    $page.ColumnCount = 1
    $page.RowCount = 2
    $null = $page.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $null = $page.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $null = $page.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $page.Padding = New-UiPadding 32 24 32 18
    $page.BackColor = $script:Theme.Back
    $page.Visible = $false

    $scroll = New-Object System.Windows.Forms.Panel
    $scroll.Dock = [System.Windows.Forms.DockStyle]::Fill
    $scroll.AutoScroll = $true
    $scroll.Margin = New-Object System.Windows.Forms.Padding(0)

    $body = New-Object System.Windows.Forms.FlowLayoutPanel
    $body.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
    $body.WrapContents = $false
    $body.AutoSize = $true
    $body.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $body.Location = New-Object System.Drawing.Point(0, 0)
    $body.Margin = New-Object System.Windows.Forms.Padding(0)
    $scroll.Controls.Add($body)

    $bar = New-Object System.Windows.Forms.FlowLayoutPanel
    $bar.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $bar.WrapContents = $true
    $bar.AutoSize = $true
    $bar.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $bar.Dock = [System.Windows.Forms.DockStyle]::Fill
    $bar.Margin = New-UiPadding 0 12 0 0

    $page.Controls.Add($scroll, 0, 0)
    $page.Controls.Add($bar, 0, 1)
    $script:PageHost.Controls.Add($page)
    $p = @{ Name = $Name; Page = $page; Body = $body; Bar = $bar; Scroll = $scroll; Focus = $null; Accept = $null; Cancel = $null }
    $script:Pages[$Name] = $p
    return $p
}

function Show-UiPage {
    param([Parameter(Mandatory = $true)][string]$Name)
    $target = $script:Pages[$Name]
    foreach ($p in $script:Pages.Values) { if ($p.Name -ne $Name) { $p.Page.Visible = $false } }
    $target.Page.Visible = $true
    $script:CurrentPage = $Name
    $script:Form.AcceptButton = $target.Accept
    $script:Form.CancelButton = $target.Cancel
    Update-UiWrap
    $target.Scroll.AutoScrollPosition = New-Object System.Drawing.Point(0, 0)
    if ($target.Focus) { $null = $target.Focus.Focus() }
    Write-UiLog -Message ('Page: ' + $Name)
}

function Build-UiStepList {
    $t = New-Object System.Windows.Forms.TableLayoutPanel
    $t.ColumnCount = 2
    $t.RowCount = 0
    $t.AutoSize = $true
    $t.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $null = $t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $null = $t.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $t.Margin = New-UiPadding 0 6 0 14
    return $t
}

function Clear-UiStepList {
    param([Parameter(Mandatory = $true)][object]$List, [Parameter(Mandatory = $true)][object]$Rows)
    foreach ($k in @($Rows.Keys)) {
        $r = $Rows[$k]
        $null = $script:WrapControls.Remove(($script:WrapControls | Where-Object { $_.Control -eq $r.Label } | Select-Object -First 1))
        $r.Glyph.Dispose()
        $r.Label.Dispose()
    }
    $Rows.Clear()
    $List.Controls.Clear()
    $List.RowStyles.Clear()
    $List.RowCount = 0
}

function Add-UiStep {
    param(
        [Parameter(Mandatory = $true)][object]$List,
        [Parameter(Mandatory = $true)][object]$Rows,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][string]$Text
    )
    $glyph = New-Object System.Windows.Forms.Label
    $glyph.AutoSize = $true
    $glyph.UseMnemonic = $false
    $glyph.Font = Get-UiFont -Size 20 -Family 'Segoe UI Symbol'
    $glyph.MinimumSize = New-Object System.Drawing.Size((ConvertTo-UiPx 46), 0)
    $glyph.Margin = New-UiPadding 0 0 8 8
    $label = Build-UiLabel -Text $Text -Size 17 -Indent (ConvertTo-UiPx 60)
    $label.Margin = New-UiPadding 0 4 0 8
    $row = $List.RowCount
    $List.RowCount = $row + 1
    $null = $List.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $List.Controls.Add($glyph, 0, $row)
    $List.Controls.Add($label, 1, $row)
    $Rows[$Key] = @{ Glyph = $glyph; Label = $label; State = 'waiting' }
    Write-UiStepState -Rows $Rows -Key $Key -State 'waiting'
}

function Write-UiStepState {
    param([Parameter(Mandatory = $true)][object]$Rows, [string]$Key, [string]$State)
    if (-not $Key -or -not $Rows.Contains($Key)) { return }
    $r = $Rows[$Key]
    $r.State = $State
    $r.Glyph.Text = Get-UiStepGlyph -State $State -Frame $script:SpinFrame
    switch ($State) {
        'running' { $r.Glyph.ForeColor = $script:Theme.Primary }
        'done' { $r.Glyph.ForeColor = $script:Theme.Ok }
        'problem' { $r.Glyph.ForeColor = $script:Theme.Warn }
        default { $r.Glyph.ForeColor = $script:Theme.Muted }
    }
    $r.Glyph.AccessibleName = Get-UiText -Key ('step.state.' + $State)
    $r.Label.AccessibleName = $r.Label.Text + ': ' + $r.Glyph.AccessibleName
    $r.Label.Font = Get-UiFont -Size 17 -Bold:($State -eq 'running')
    if ($State -eq 'waiting' -or $State -eq 'skipped') { $r.Label.ForeColor = $script:Theme.Muted } else { $r.Label.ForeColor = $script:Theme.Text }
}

function Complete-UiStepList {
    param([Parameter(Mandatory = $true)][object]$Rows, [string]$RunningState = 'done')
    foreach ($k in @($Rows.Keys)) {
        $state = $Rows[$k].State
        if ($state -eq 'running') { Write-UiStepState -Rows $Rows -Key $k -State $RunningState }
        elseif ($state -eq 'waiting') { Write-UiStepState -Rows $Rows -Key $k -State 'skipped' }
    }
}

function Get-UiStepPosition {
    param([Parameter(Mandatory = $true)][object]$Rows)
    $i = 0
    $pos = 0
    foreach ($k in $Rows.Keys) {
        $i++
        if ($Rows[$k].State -ne 'waiting') { $pos = $i }
    }
    if ($pos -eq 0) { $pos = 1 }
    return @{ Current = $pos; Total = $Rows.Count }
}

function Show-UiDialog {
    <#
    .SYNOPSIS
        Own modal dialog with large text and large buttons. Returns $true for the Yes button.
        The queue timer is paused while it is open, so that dialogs never stack.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Heading,
        [string]$Title,
        [string[]]$Lines = @(),
        [string]$Emphasis,
        [Parameter(Mandatory = $true)][string]$YesText,
        [string]$NoText,
        [switch]$TopMost,
        [switch]$FocusYes
    )
    $d = New-Object System.Windows.Forms.Form
    $d.Text = Get-UiText -Key 'app.name'
    $d.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $d.MaximizeBox = $false
    $d.MinimizeBox = $false
    $d.ShowInTaskbar = $false
    $d.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $d.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $d.AutoSize = $true
    $d.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $d.BackColor = $script:Theme.Back
    $d.ForeColor = $script:Theme.Text
    $d.Font = Get-UiFont -Size 16
    $d.Padding = New-UiPadding 28 24 28 20
    $d.TopMost = [bool]$TopMost
    if ($script:Form -and $script:Form.Icon) { $d.Icon = $script:Form.Icon }

    $width = ConvertTo-UiPx 640
    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.FlowDirection = [System.Windows.Forms.FlowDirection]::TopDown
    $flow.WrapContents = $false
    $flow.AutoSize = $true
    $flow.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $parts = New-Object System.Collections.ArrayList
    $null = $parts.Add(@{ Text = $Heading; Size = 22; Bold = $true; Color = 'Text' })
    if ($Title) { $null = $parts.Add(@{ Text = $Title; Size = 18; Bold = $true; Color = 'Primary' }) }
    foreach ($l in $Lines) { if ($l) { $null = $parts.Add(@{ Text = $l; Size = 16; Bold = $false; Color = 'Text' }) } }
    if ($Emphasis) { $null = $parts.Add(@{ Text = $Emphasis; Size = 16; Bold = $true; Color = 'Warn' }) }
    foreach ($part in $parts) {
        $label = Build-UiLabel -Text $part.Text -Size $part.Size -Bold:$part.Bold -Color $part.Color -NoWrap
        $label.MaximumSize = New-Object System.Drawing.Size($width, 0)
        $label.Margin = New-UiPadding 0 0 0 14
        $flow.Controls.Add($label)
    }
    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $buttons.AutoSize = $true
    $buttons.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $buttons.Margin = New-UiPadding 0 10 0 0
    $yes = Build-UiButton -Text $YesText -Primary -MinWidth 200
    $yes.DialogResult = [System.Windows.Forms.DialogResult]::Yes
    $buttons.Controls.Add($yes)
    $focusTarget = $yes
    if ($NoText) {
        $no = Build-UiButton -Text $NoText -MinWidth 200
        $no.DialogResult = [System.Windows.Forms.DialogResult]::No
        $buttons.Controls.Add($no)
        $d.CancelButton = $no
        if (-not $FocusYes) { $focusTarget = $no }
    } else {
        $d.AcceptButton = $yes
        $d.CancelButton = $yes
    }
    $flow.Controls.Add($buttons)
    $d.Controls.Add($flow)
    $d.ActiveControl = $focusTarget

    $timerWasOn = $false
    if ($script:Timer) { $timerWasOn = $script:Timer.Enabled; $script:Timer.Stop() }
    $script:InDialog = $true
    try {
        if ($script:Form -and $script:Form.Visible) { $answer = $d.ShowDialog($script:Form) } else { $answer = $d.ShowDialog() }
    } finally {
        $script:InDialog = $false
        if ($timerWasOn) { $script:Timer.Start() }
        $d.Dispose()
    }
    return ($answer -eq [System.Windows.Forms.DialogResult]::Yes)
}

function Show-UiConfirm {
    param([AllowNull()][object]$Request)
    $lines = @()
    if ($Request -and $Request.Explain) { $lines += [string]$Request.Explain }
    $lines += Get-UiText -Key (Get-UiRiskKey -Risk $Request.Risk)
    $emphasis = $null
    if ($Request -and [bool]$Request.Reboot) { $emphasis = Get-UiText -Key 'confirm.reboot' }
    $title = ''
    if ($Request) { $title = [string]$Request.Title }
    return (Show-UiDialog -Heading (Get-UiText -Key 'confirm.heading') -Title $title -Lines $lines -Emphasis $emphasis `
            -YesText (Get-UiText -Key 'confirm.yes') -NoText (Get-UiText -Key 'confirm.no') -TopMost)
}

# =============================================================================================================
# Flow
# =============================================================================================================

function Invoke-UiSafe {
    <#
    .SYNOPSIS
        Runs an event handler body; any error is logged and ends on the friendly error page.
    #>
    param([Parameter(Mandatory = $true)][scriptblock]$Action)
    try {
        & $Action
    } catch {
        $err = $_
        Write-UiLog -Level Error -Message ('UI error: ' + $err.Exception.Message) -Data @{ Stack = $err.ScriptStackTrace }
        try { if ($script:CurrentPage -ne 'result') { Show-UiErrorPage -Key 'error.unexpected' } } catch { $null = $_ }
    }
}

function Test-UiBusy {
    return ($null -ne $script:Job -and -not $script:Job.Done)
}

function Invoke-UiBackground {
    param([Parameter(Mandatory = $true)][string]$Kind, [hashtable]$Extra = @{})
    if ($script:Job -and $script:Job.PS) { try { $script:Job.PS.Dispose() } catch { $null = $_ } }
    if (-not $script:Runspace) {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $rs.Open()
        $script:Runspace = $rs
    }
    $script:Sync.Cancel = $false
    $script:CancelAt = $null
    $jobParams = @{
        Kind = $Kind; AppDir = $script:AppDir; RunFolder = [string]$script:RunFolderPath
        Queue = $script:Queue; Sync = $script:Sync; Demo = $script:IsDemo; DemoFailure = $script:DemoFailure; DemoDelay = 1.0
        FallbackLib = $script:UiFallbackLib; ReadOnly = $script:IsReadOnly; Language = $script:Language
    }
    foreach ($k in $Extra.Keys) { $jobParams[$k] = $Extra[$k] }
    $ps = Build-UiJob -Runspace $script:Runspace -Script $script:JobScript -Parameters $jobParams
    $handle = $ps.BeginInvoke()
    $script:Job = @{ PS = $ps; Handle = $handle; Kind = $Kind; Done = $false }
    $script:PhaseStart = Get-Date
    $script:Timer.Start()
    Write-UiLog -Message ('Background job started: ' + $Kind)
}

function Invoke-UiPreparation {
    foreach ($k in @($script:PrepRows.Keys)) { Write-UiStepState -Rows $script:PrepRows -Key $k -State 'waiting' }
    $script:Ui.PrepSentence.Text = ''
    $script:Ui.PrepHint.Visible = $false
    $script:Ui.PrepCancel.Enabled = $true
    Show-UiPage -Name 'preparing'
    Invoke-UiBackground -Kind 'prepare'
}

function Select-UiCategory {
    param([Parameter(Mandatory = $true)][string]$Id)
    if ($Id -eq 'other') {
        $script:Ui.OtherError.Visible = $false
        Show-UiPage -Name 'other'
        return
    }
    Invoke-UiAgent -Category $Id -UserText ''
}

function Invoke-UiAgent {
    param([Parameter(Mandatory = $true)][string]$Category, [string]$UserText = '')
    $script:CategoryId = $Category
    $script:UserText = $UserText
    $script:CategoryTitle = Get-UiText -Key ('cat.' + $Category)
    $script:ActionTitles = @{}
    Write-UiLog -Message ('Category chosen: ' + $Category)
    $script:Ui.WorkTitle.Text = Get-UiText -Key 'ui.work.title' -Arguments @($script:CategoryTitle)
    Clear-UiStepList -List $script:Ui.WorkSteps -Rows $script:WorkRows
    foreach ($k in @('step.diagnose', 'step.repair', 'step.verify')) {
        Add-UiStep -List $script:Ui.WorkSteps -Rows $script:WorkRows -Key $k -Text (Get-UiText -Key $k)
    }
    $script:Ui.WorkSentence.Text = Get-UiText -Key 'ui.work.starting'
    $script:KeepSentence = $false
    $script:Ui.WorkActivity.Items.Clear()
    $script:Ui.WorkActivityCaption.Visible = $false
    $script:Ui.WorkActivity.Visible = $false
    $script:Ui.WorkCancel.Enabled = $true
    Write-UiStepCounter
    Show-UiPage -Name 'working'
    Invoke-UiBackground -Kind 'agent' -Extra @{ Category = $Category; UserText = $UserText }
}

function Write-UiStepCounter {
    $pos = Get-UiStepPosition -Rows $script:WorkRows
    $script:Ui.WorkStepOf.Text = Get-UiText -Key 'ui.step_of' -Arguments @($pos.Current, $pos.Total)
}

function Add-UiActivity {
    param([string]$Text)
    if (-not $Text) { return }
    # The same line twice in a row says nothing new (a skipped step and the agent's sentence about it, a repeated
    # "I keep going").
    $count = $script:Ui.WorkActivity.Items.Count
    if ($count -gt 0 -and [string]$script:Ui.WorkActivity.Items[$count - 1] -ceq $Text) { return }
    $script:Ui.WorkActivityCaption.Visible = $true
    $script:Ui.WorkActivity.Visible = $true
    $null = $script:Ui.WorkActivity.Items.Add($Text)
    $script:Ui.WorkActivity.TopIndex = [Math]::Max(0, $script:Ui.WorkActivity.Items.Count - 1)
}

function Set-UiSentence {
    <#
    .SYNOPSIS
        The big sentence of the working page. With -Keep the next 'thinking' event leaves it standing (what the
        agent announced stays readable while the model thinks); any other sentence replaces it as usual.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes a label only')]
    param([string]$Text, [switch]$Keep)
    if (-not $Text) { return }
    if ($Text.Length -gt 400) { $Text = $Text.Substring(0, 400) + ' ...' }
    $script:Ui.WorkSentence.Text = $Text
    $script:KeepSentence = [bool]$Keep
}

function Receive-UiConfirm {
    param([Parameter(Mandatory = $true)][object]$Item)
    $request = $Item.Request
    $answer = $false
    if ($script:IsReadOnly) {
        Write-UiLog -Message 'Confirmation declined automatically (read-only)' -Data @{ Title = [string]$request.Title }
    } elseif ($script:Sync.Cancel) {
        $answer = $false
    } else {
        $answer = [bool](Show-UiConfirm -Request $request)
        Write-UiLog -Message 'Confirmation answered' -Data @{ Title = [string]$request.Title; Risk = [string]$request.Risk; Answer = $answer }
    }
    $script:Sync[('answer.' + [string]$Item.Id)] = $answer
}

function Receive-UiEvent {
    <#
    .SYNOPSIS
        Handles one queue item on the UI thread: own job events and the agent events of ARCHITECTURE.md 5.7.
    #>
    param([Parameter(Mandatory = $true)][object]$Item)
    $type = [string]$Item.Type
    switch ($type) {
        'prep-step' {
            Write-UiStepState -Rows $script:PrepRows -Key ([string]$Item.Key) -State ([string]$Item.State)
            if ($Item.State -eq 'running' -and (Test-UiText ([string]$Item.Key + '.detail'))) {
                $script:Ui.PrepSentence.Text = Get-UiText -Key ([string]$Item.Key + '.detail')
            }
            if ($Item.ReasonKey -and (Test-UiText ([string]$Item.ReasonKey))) {
                $script:Ui.PrepSentence.Text = Get-UiText -Key ([string]$Item.ReasonKey)
            }
        }
        'prepared' {
            if (Complete-UiJob) { return }
            Write-UiLog -Message ('Ready with model ' + [string]$Item.Model)
            Show-UiPage -Name 'category'
        }
        'cancelled' { Show-UiResult -Cancelled }
        'fatal' { Show-UiErrorPage -Key ([string]$Item.Key) }
        'finished' { Show-UiResult -Result $Item.Result -Cancelled:([bool]$Item.Cancelled) }
        'confirm' { Receive-UiConfirm -Item $Item }
        'step-start' {
            $key = [string]$Item.Key
            $text = [string]$Item.Text
            if (-not $key) { $key = 'step.' + $text }
            $label = $text
            if (Test-UiText $key) { $label = Get-UiText -Key $key }
            if (-not $label) { $label = $key }
            foreach ($k in @($script:WorkRows.Keys)) {
                if ($k -ne $key -and $script:WorkRows[$k].State -eq 'running') { Write-UiStepState -Rows $script:WorkRows -Key $k -State 'done' }
            }
            if (-not $script:WorkRows.Contains($key)) { Add-UiStep -List $script:Ui.WorkSteps -Rows $script:WorkRows -Key $key -Text $label; Update-UiWrap }
            Write-UiStepState -Rows $script:WorkRows -Key $key -State 'running'
            if (Test-UiText ($key + '.detail')) { Set-UiSentence (Get-UiText -Key ($key + '.detail')) } else { Set-UiSentence $label }
            Write-UiStepCounter
        }
        'step-done' {
            $state = 'done'
            if ($Item.Ok -eq $false) { $state = 'problem' }
            Write-UiStepState -Rows $script:WorkRows -Key ([string]$Item.Key) -State $state
            Write-UiStepCounter
        }
        'thinking' {
            # What the agent itself just announced ("I keep going. Next I try: ...") stays while the model thinks.
            if ($script:KeepSentence) { $script:KeepSentence = $false } else { Set-UiSentence (Get-UiText -Key 'event.thinking') }
        }
        'action' {
            $title = [string]$Item.Title
            if (-not $title) { $title = [string]$Item.Id }
            if ($Item.Id) { $script:ActionTitles[[string]$Item.Id] = $title }
            Set-UiSentence (Get-UiText -Key 'event.action' -Arguments @($title))
        }
        'action-result' {
            if ($null -ne $Item.Result) {
                $line = Get-UiActionLine -Result $Item.Result -Titles $script:ActionTitles -ReadOnly:$script:IsReadOnly
                Add-UiActivity $line.Text
            }
        }
        'message' {
            # Text from the language model is unverified (it may claim things it did not do) - label it as such.
            # Text from the agent itself (Source 'agent': why it goes on, what it tries next) is the big sentence,
            # stays there while the model thinks, and is kept in the list so that it never just flashes by.
            $msgSource = $null
            if ($Item -is [System.Collections.IDictionary] -and $Item.Contains('Source')) { $msgSource = [string]$Item['Source'] }
            if ($msgSource -eq 'model') {
                Add-UiActivity (Get-UiText -Key 'event.model_says' -Arguments @([string]$Item.Text))
            } elseif ($msgSource -eq 'agent') {
                Set-UiSentence ([string]$Item.Text) -Keep
                Add-UiActivity ([string]$Item.Text)
            } else {
                Set-UiSentence ([string]$Item.Text)
            }
        }
        'done' {
            if ([bool]$Item.Solved) { Set-UiSentence (Get-UiText -Key 'event.done.solved') } else { Set-UiSentence (Get-UiText -Key 'event.done.unsolved') }
        }
        'error' { Add-UiActivity (Get-UiText -Key 'event.error' -Arguments @([string]$Item.Text)) }
        default { Write-UiLog -Level Warn -Message ('Unknown event type: ' + $type) }
    }
}

function Complete-UiJob {
    <#
    .SYNOPSIS
        Marks the background job as finished. Returns $true when the window is closing instead (the person
        closed it while work was running), so that the caller shows no further page.
    #>
    if ($script:Job) { $script:Job.Done = $true }
    if ($script:CloseWhenIdle) {
        $script:ForceClose = $true
        Close-UiOllama
        $script:Form.Close()
        return $true
    }
    return $false
}

function Request-UiCancel {
    <#
    .SYNOPSIS
        Asks "Do you want to stop?" while work runs. Returns $true when the person wants to stop (or nothing runs).
    #>
    if (-not (Test-UiBusy)) { return $true }
    if ($script:Sync.Cancel) { return $true }
    $stop = Show-UiDialog -Heading (Get-UiText -Key 'ui.cancel.title') -Lines @(Get-UiText -Key 'ui.cancel.text') `
        -YesText (Get-UiText -Key 'ui.cancel.yes') -NoText (Get-UiText -Key 'ui.cancel.no')
    if (-not $stop) { return $false }
    if (-not (Test-UiBusy)) { return $true }
    $script:Sync.Cancel = $true
    $script:CancelAt = Get-Date
    Write-UiLog -Message 'Cancel requested by the user'
    $text = Get-UiText -Key 'ui.work.cancelling'
    $script:Ui.WorkSentence.Text = $text
    $script:Ui.PrepSentence.Text = $text
    $script:Ui.WorkCancel.Enabled = $false
    $script:Ui.PrepCancel.Enabled = $false
    return $true
}

function Close-UiOllama {
    <#
    .SYNOPSIS
        Stops the Ollama server of this run (idempotent) and any ollama process left over from our runtime folder.
    #>
    $server = $script:Sync.Server
    $script:Sync.Server = $null
    if ($null -ne $server) {
        try {
            if (Get-Command -Name Stop-PnhOllama -ErrorAction SilentlyContinue) { Stop-PnhOllama -Server $server }
        } catch {
            Write-UiLog -Level Warn -Message ('Stop-PnhOllama failed: ' + $_.Exception.Message)
        }
        try {
            $p = $server.Process
            if ($null -ne $p -and -not $p.HasExited) { $p.Kill() }
        } catch {
            $null = $_
        }
    }
    if ($script:IsDemo) { return }
    try {
        $runtime = [string](Get-PnhPaths).Runtime
        if ($runtime) {
            Get-Process -Name 'ollama*' -ErrorAction SilentlyContinue |
                Where-Object { $_.Path -and $_.Path.StartsWith($runtime, [System.StringComparison]::OrdinalIgnoreCase) } |
                ForEach-Object {
                    Write-UiLog -Level Warn -Message ('Stopping leftover Ollama process ' + $_.Id)
                    Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
                }
        }
    } catch {
        $null = $_
    }
}

function Close-UiApp {
    $script:ForceClose = $true
    $script:Form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    Close-UiOllama
    $script:Form.Close()
}

function Write-UiResultPage {
    param(
        [bool]$Ok,
        [string]$Title,
        [string]$Text,
        [string]$Extra,
        [string]$Summary,
        [string[]]$Actions = @(),
        [bool]$ShowActions = $true,
        [bool]$Reboot
    )
    $u = $script:Ui
    if ($Ok) {
        $u.ResultGlyph.Text = [string][char]0x2713
        $u.ResultGlyph.ForeColor = $script:Theme.Ok
    } else {
        $u.ResultGlyph.Text = [string][char]0x26A0
        $u.ResultGlyph.ForeColor = $script:Theme.Warn
    }
    $u.ResultGlyph.AccessibleName = $Title
    $u.ResultTitle.Text = $Title
    $u.ResultText.Text = $Text
    $u.ResultText.Visible = [bool]$Text
    $u.ResultExtra.Text = $Extra
    $u.ResultExtra.Visible = [bool]$Extra
    $u.ResultSummary.Text = ($Summary -replace "`r?`n", "`r`n")
    $u.ResultSummary.Visible = [bool]$Summary
    $u.ResultActions.Items.Clear()
    $list = @($Actions | Where-Object { $_ })
    if ($list.Count -eq 0) { $list = @(Get-UiText -Key 'result.actions.none') }
    foreach ($a in $list) { $null = $u.ResultActions.Items.Add($a) }
    $u.ResultActionsCaption.Visible = $ShowActions
    $u.ResultActions.Visible = $ShowActions
    $u.ResultReboot.Visible = $Reboot
    if ($script:RunFolderPath) {
        $u.ResultPath.Text = Get-UiText -Key 'result.report_path' -Arguments @([string]$script:RunFolderPath)
        $u.ResultPath.Visible = $true
    } else {
        $u.ResultPath.Visible = $false
    }
}

function Save-UiSummary {
    param(
        [string]$ResultTitle,
        [string]$ResultText,
        [string]$Summary,
        [string[]]$ActionLines = @(),
        [bool]$NeedsReboot
    )
    $folder = [string]$script:RunFolderPath
    if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { return }
    $path = Join-Path -Path $folder -ChildPath 'summary.txt'
    if (Test-Path -LiteralPath $path) { return }
    try {
        $text = Format-UiSummary -ResultTitle $ResultTitle -ResultText $ResultText -CategoryTitle $script:CategoryTitle `
            -UserText $script:UserText -Summary $Summary -ActionLines $ActionLines -NeedsReboot:$NeedsReboot `
            -ReadOnly:$script:IsReadOnly -LogFolder $folder
        [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($true)))
    } catch {
        Write-UiLog -Level Warn -Message ('Cannot write summary.txt: ' + $_.Exception.Message)
    }
}

function Show-UiResult {
    param([AllowNull()][object]$Result, [switch]$Cancelled)
    if (Complete-UiJob) { return }
    Complete-UiStepList -Rows $script:WorkRows
    Complete-UiStepList -Rows $script:PrepRows
    $kind = Get-UiResultKind -Result $Result -Cancelled:$Cancelled
    $extra = New-Object System.Collections.Generic.List[string]
    if ($null -ne $Result -and $kind -ne 'solved') {
        $stoppedKey = Get-UiStoppedKey -Reason $Result.StoppedReason -HasText ${function:Test-UiText}
        if ($stoppedKey) { $extra.Add((Get-UiText -Key $stoppedKey)) }
    }
    if ($script:IsReadOnly -and $kind -ne 'solved') { $extra.Add((Get-UiText -Key 'result.readonly.text')) }
    $actions = @()
    $reboot = $false
    if ($null -ne $Result -and $Result.Actions) {
        foreach ($a in @($Result.Actions)) {
            if ($null -eq $a) { continue }
            $line = Get-UiActionLine -Result $a -Titles $script:ActionTitles -ReadOnly:$script:IsReadOnly
            $actions += $line.Text
            if ($line.Ok -and [bool]$a.NeedsReboot) { $reboot = $true }
        }
    }
    $summary = ''
    if ($null -ne $Result) { $summary = [string]$Result.Summary }
    $title = Get-UiText -Key ('result.' + $kind + '.title')
    $text = Get-UiText -Key ('result.' + $kind + '.text')
    Write-UiLog -Message ('Result: ' + $kind) -Data @{ Actions = $actions; Reboot = $reboot }
    Write-UiResultPage -Ok ($kind -eq 'solved') -Title $title -Text $text -Extra ($extra -join "`n`n") -Summary $summary `
        -Actions $actions -ShowActions ($kind -ne 'cancelled' -or $actions.Count -gt 0) -Reboot $reboot
    Save-UiSummary -ResultTitle $title -ResultText $text -Summary $summary -ActionLines $actions -NeedsReboot $reboot
    Show-UiPage -Name 'result'
}

function Show-UiErrorPage {
    param([Parameter(Mandatory = $true)][string]$Key)
    if (Complete-UiJob) { return }
    Write-UiLog -Level Warn -Message ('Error page: ' + $Key)
    Close-UiOllama
    Complete-UiStepList -Rows $script:PrepRows -RunningState 'problem'
    Complete-UiStepList -Rows $script:WorkRows -RunningState 'problem'
    $title = Get-UiText -Key ($Key + '.title')
    $text = Get-UiText -Key ($Key + '.text')
    if ($script:Ui.ResultTitle) {
        Write-UiResultPage -Ok $false -Title $title -Text $text -Extra '' -Summary '' -Actions @() -ShowActions $false -Reboot $false
        $script:Ui.ResultFinish.Text = Get-UiText -Key 'ui.button.close'
        $script:Ui.ResultFinish.AccessibleName = $script:Ui.ResultFinish.Text
        Save-UiSummary -ResultTitle $title -ResultText $text
        Show-UiPage -Name 'result'
    }
}

function Open-UiReport {
    $folder = [string]$script:RunFolderPath
    $target = $null
    if ($folder) {
        foreach ($name in @('summary.txt', 'run.log')) {
            $candidate = Join-Path -Path $folder -ChildPath $name
            if (Test-Path -LiteralPath $candidate) { $target = $candidate; break }
        }
    }
    if (-not $target) {
        $null = Show-UiDialog -Heading (Get-UiText -Key 'result.show_report') -Lines @(Get-UiText -Key 'result.report_missing') -YesText (Get-UiText -Key 'ui.button.ok')
        return
    }
    $notepad = Join-Path -Path $env:SystemRoot -ChildPath 'System32\notepad.exe'
    Start-Process -FilePath $notepad -ArgumentList ('"' + $target + '"')
}

function Update-UiProgress {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Labels only')]
    param()
    if (-not (Test-UiBusy)) { return }
    $script:SpinFrame++
    $rows = $null
    if ($script:CurrentPage -eq 'preparing') { $rows = $script:PrepRows }
    elseif ($script:CurrentPage -eq 'working') { $rows = $script:WorkRows }
    if ($null -ne $rows) {
        foreach ($k in $rows.Keys) {
            if ($rows[$k].State -eq 'running') { $rows[$k].Glyph.Text = Get-UiStepGlyph -State 'running' -Frame $script:SpinFrame }
        }
    }
    $seconds = ((Get-Date) - $script:PhaseStart).TotalSeconds
    $elapsed = Get-UiText -Key 'ui.elapsed' -Arguments @(Format-UiElapsed -Seconds $seconds)
    if ($script:CurrentPage -eq 'preparing') {
        $script:Ui.PrepElapsed.Text = $elapsed
        # An honest time hint only after about 10 seconds (technik.md 3).
        if ($seconds -ge 10 -and -not $script:Ui.PrepHint.Visible) { $script:Ui.PrepHint.Visible = $true }
    } elseif ($script:CurrentPage -eq 'working') {
        $script:Ui.WorkElapsed.Text = $elapsed
    }
}

function Test-UiJobHealth {
    $job = $script:Job
    if ($null -eq $job -or $job.Done) { return }
    if ($script:Sync.Cancel -and $script:CancelAt -and ((Get-Date) - $script:CancelAt).TotalSeconds -gt 20) {
        Write-UiLog -Level Warn -Message 'The background work did not stop within 20 seconds; stopping it'
        Close-UiOllama
        try { $null = $job.PS.BeginStop($null, $null) } catch { $null = $_ }
        Show-UiResult -Cancelled
        return
    }
    if ($job.Handle.IsCompleted -and $script:Queue.IsEmpty) {
        $detail = ''
        try { $null = $job.PS.EndInvoke($job.Handle) } catch { $detail = $_.Exception.ToString() }
        try { foreach ($e in $job.PS.Streams.Error) { $detail += "`n" + ($e | Out-String) } } catch { $null = $_ }
        Write-UiLog -Level Error -Message ('The background work ended without a result. ' + $detail)
        if ($script:Sync.Cancel) { Show-UiResult -Cancelled } else { Show-UiErrorPage -Key 'error.unexpected' }
    }
}

function Invoke-UiTick {
    if ($script:InDialog) { return }
    $item = $null
    $count = 0
    while ($count -lt 50 -and $script:Queue.TryDequeue([ref]$item)) {
        $count++
        if ($null -eq $script:Job -or $script:Job.Done) {
            Write-UiLog -Message ('Late event ignored: ' + [string]$item.Type)
            if ([string]$item.Type -eq 'confirm') { $script:Sync[('answer.' + [string]$item.Id)] = $false }
            continue
        }
        try {
            Receive-UiEvent -Item $item
        } catch {
            Write-UiLog -Level Error -Message ('Event handling failed (' + [string]$item.Type + '): ' + $_.Exception.Message) -Data @{ Stack = $_.ScriptStackTrace }
        }
    }
    Update-UiProgress
    Test-UiJobHealth
}

# =============================================================================================================
# Pages
# =============================================================================================================

function Build-UiWelcomePage {
    $p = Build-UiPage -Name 'welcome'
    $title = Build-UiLabel -Text (Get-UiText -Key 'ui.welcome.title') -Size 26 -Bold
    $text = Build-UiLabel -Text (Get-UiText -Key 'ui.welcome.text') -Size 18
    $start = Build-UiButton -Text (Get-UiText -Key 'ui.welcome.start') -Primary -FontSize 24 -MinWidth 380 -MinHeight 100
    $start.Margin = New-UiPadding 0 26 0 22
    $start.Add_Click({ Invoke-UiSafe { Invoke-UiPreparation } })
    $link = New-Object System.Windows.Forms.LinkLabel
    $link.Text = Get-UiText -Key 'ui.welcome.what'
    $link.AutoSize = $true
    $link.UseMnemonic = $false
    $link.Font = Get-UiFont -Size 16
    $link.TabStop = $true
    if (-not $script:HighContrast) { $link.LinkColor = $script:Theme.Link; $link.ActiveLinkColor = $script:Theme.Text }
    $link.Add_LinkClicked({
            Invoke-UiSafe {
                $null = Show-UiDialog -Heading (Get-UiText -Key 'ui.about.title') -Lines @(Get-UiText -Key 'ui.about.text') `
                    -YesText (Get-UiText -Key 'ui.button.close')
            }
        })
    $p.Body.Controls.AddRange(@($title, $text, $start, $link))
    $p.Focus = $start
    $p.Accept = $start
}

function Build-UiPreparingPage {
    $p = Build-UiPage -Name 'preparing'
    $title = Build-UiLabel -Text (Get-UiText -Key 'ui.prepare.title') -Size 24 -Bold
    $steps = Build-UiStepList
    $sentence = Build-UiLabel -Text '' -Size 17 -Bold -Color 'Primary'
    $hint = Build-UiLabel -Text (Get-UiText -Key 'ui.prepare.hint') -Size 16 -Color 'Muted'
    $hint.Visible = $false
    $elapsed = Build-UiLabel -Text '' -Size 15 -Color 'Muted'
    $p.Body.Controls.AddRange(@($title, $steps, $sentence, $hint, $elapsed))
    foreach ($k in @('step.hardware', 'step.model', 'step.start')) {
        Add-UiStep -List $steps -Rows $script:PrepRows -Key $k -Text (Get-UiText -Key $k)
    }
    $cancel = Build-UiButton -Text (Get-UiText -Key 'ui.button.cancel')
    $cancel.Add_Click({ Invoke-UiSafe { $null = Request-UiCancel } })
    $p.Bar.Controls.Add($cancel)
    $p.Focus = $cancel
    $p.Cancel = $cancel
    $script:Ui.PrepSentence = $sentence
    $script:Ui.PrepHint = $hint
    $script:Ui.PrepElapsed = $elapsed
    $script:Ui.PrepCancel = $cancel
}

function Build-UiCategoryPage {
    $p = Build-UiPage -Name 'category'
    $title = Build-UiLabel -Text (Get-UiText -Key 'ui.category.title') -Size 26 -Bold
    $text = Build-UiLabel -Text (Get-UiText -Key 'ui.category.text') -Size 17
    $tiles = New-Object System.Windows.Forms.FlowLayoutPanel
    $tiles.FlowDirection = [System.Windows.Forms.FlowDirection]::LeftToRight
    $tiles.WrapContents = $true
    $tiles.AutoSize = $true
    $tiles.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $tiles.Margin = New-UiPadding 0 8 0 0
    Register-UiWrap -Control $tiles
    $categoriesPath = Join-Path -Path $script:AppDir -ChildPath 'toolbox\categories.json'
    $first = $null
    foreach ($c in (Get-UiCategoryList -Path $categoriesPath -HasText ${function:Test-UiText})) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = Get-UiText -Key $c.TitleKey
        $b.Tag = $c.Id
        $b.UseMnemonic = $false
        $b.AccessibleName = $b.Text
        $b.Font = Get-UiFont -Size 16 -Bold
        $b.Margin = New-UiPadding 0 0 14 14
        Format-UiButton -Button $b -Style 'tile'
        $fore = $b.ForeColor
        $back = $b.BackColor
        if ($script:HighContrast) { $fore = [System.Drawing.SystemColors]::ControlText; $back = [System.Drawing.SystemColors]::Control }
        try { $b.Image = Build-UiEmojiImage -Emoji $c.Icon -Size 30 -Fore $fore -Back $back } catch { Write-UiLog -Level Warn -Message ('Emoji image failed: ' + $_.Exception.Message) }
        if ($c.Kind -eq 'wide') {
            $b.Size = New-Object System.Drawing.Size((ConvertTo-UiPx 528), (ConvertTo-UiPx 110))
            $b.TextImageRelation = [System.Windows.Forms.TextImageRelation]::ImageBeforeText
        } else {
            $b.Size = New-Object System.Drawing.Size((ConvertTo-UiPx 257), (ConvertTo-UiPx 160))
            $b.TextImageRelation = [System.Windows.Forms.TextImageRelation]::ImageAboveText
        }
        $b.Add_Click({ $chosen = [string]$this.Tag; Invoke-UiSafe { Select-UiCategory -Id $chosen } })
        $tiles.Controls.Add($b)
        if ($c.Kind -eq 'wide') { $tiles.SetFlowBreak($b, $true) }
        if (-not $first) { $first = $b }
    }
    $p.Body.Controls.AddRange(@($title, $text, $tiles))
    $quit = Build-UiButton -Text (Get-UiText -Key 'ui.button.quit')
    $quit.Add_Click({ Invoke-UiSafe { Close-UiApp } })
    $p.Bar.Controls.Add($quit)
    $p.Focus = $first
    # No Esc shortcut here: one stray key press would throw away the preparation (1 to 2 minutes).
    $p.Cancel = $null
}

function Build-UiOtherPage {
    $p = Build-UiPage -Name 'other'
    $title = Build-UiLabel -Text (Get-UiText -Key 'ui.other.title') -Size 26 -Bold
    $text = Build-UiLabel -Text (Get-UiText -Key 'ui.other.text') -Size 17
    $box = New-Object System.Windows.Forms.TextBox
    $box.Multiline = $true
    $box.AcceptsReturn = $false
    $box.WordWrap = $true
    $box.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $box.MaxLength = 500
    $box.Font = Get-UiFont -Size 18
    $box.Height = ConvertTo-UiPx 130
    $box.Margin = New-UiPadding 0 6 0 10
    $box.AccessibleName = Get-UiText -Key 'ui.other.text'
    Register-UiWrap -Control $box -FixedWidth
    $example = Build-UiLabel -Text (Get-UiText -Key 'ui.other.example') -Size 15 -Color 'Muted'
    $errorLabel = Build-UiLabel -Text (Get-UiText -Key 'ui.other.empty') -Size 16 -Bold -Color 'Warn'
    $errorLabel.Visible = $false
    $p.Body.Controls.AddRange(@($title, $text, $box, $example, $errorLabel))
    $continue = Build-UiButton -Text (Get-UiText -Key 'ui.button.continue') -Primary
    $continue.Add_Click({
            Invoke-UiSafe {
                $words = $script:Ui.OtherBox.Text.Trim()
                if ($words.Length -lt 3) {
                    $script:Ui.OtherError.Visible = $true
                    $null = $script:Ui.OtherBox.Focus()
                    return
                }
                Invoke-UiAgent -Category 'other' -UserText $words
            }
        })
    $back = Build-UiButton -Text (Get-UiText -Key 'ui.button.back')
    $back.Add_Click({ Invoke-UiSafe { Show-UiPage -Name 'category' } })
    $p.Bar.Controls.AddRange(@($continue, $back))
    $p.Focus = $box
    $p.Accept = $continue
    $p.Cancel = $back
    $script:Ui.OtherBox = $box
    $script:Ui.OtherError = $errorLabel
}

function Build-UiWorkingPage {
    $p = Build-UiPage -Name 'working'
    $title = Build-UiLabel -Text '' -Size 24 -Bold
    $stepOf = Build-UiLabel -Text '' -Size 15 -Color 'Muted'
    $steps = Build-UiStepList
    $sentence = Build-UiLabel -Text '' -Size 18 -Bold -Color 'Primary'
    $sentence.Margin = New-UiPadding 0 4 0 14
    $caption = Build-UiLabel -Text (Get-UiText -Key 'ui.work.activity') -Size 15 -Bold -Color 'Muted'
    $activity = New-Object System.Windows.Forms.ListBox
    $activity.Font = Get-UiFont -Size 14
    $activity.IntegralHeight = $false
    $activity.HorizontalScrollbar = $true
    $activity.Height = ConvertTo-UiPx 150
    $activity.Margin = New-UiPadding 0 0 0 12
    $activity.AccessibleName = Get-UiText -Key 'ui.work.activity'
    if (-not $script:HighContrast) { $activity.BackColor = $script:Theme.Back; $activity.ForeColor = $script:Theme.Text }
    Register-UiWrap -Control $activity -FixedWidth
    $hint = Build-UiLabel -Text (Get-UiText -Key 'ui.work.hint') -Size 15 -Color 'Muted'
    $elapsed = Build-UiLabel -Text '' -Size 15 -Color 'Muted'
    $p.Body.Controls.AddRange(@($title, $stepOf, $steps, $sentence, $caption, $activity, $hint, $elapsed))
    $cancel = Build-UiButton -Text (Get-UiText -Key 'ui.button.cancel')
    $cancel.Add_Click({ Invoke-UiSafe { $null = Request-UiCancel } })
    $p.Bar.Controls.Add($cancel)
    $p.Focus = $cancel
    $p.Cancel = $cancel
    $script:Ui.WorkTitle = $title
    $script:Ui.WorkStepOf = $stepOf
    $script:Ui.WorkSteps = $steps
    $script:Ui.WorkSentence = $sentence
    $script:Ui.WorkActivityCaption = $caption
    $script:Ui.WorkActivity = $activity
    $script:Ui.WorkElapsed = $elapsed
    $script:Ui.WorkCancel = $cancel
}

function Build-UiResultPage {
    $p = Build-UiPage -Name 'result'
    $glyph = New-Object System.Windows.Forms.Label
    $glyph.AutoSize = $true
    $glyph.UseMnemonic = $false
    $glyph.Font = Get-UiFont -Size 54 -Family 'Segoe UI Symbol'
    $glyph.Margin = New-UiPadding 0 0 0 4
    $title = Build-UiLabel -Text '' -Size 26 -Bold
    $text = Build-UiLabel -Text '' -Size 18
    $extra = Build-UiLabel -Text '' -Size 17 -Bold
    $summary = New-Object System.Windows.Forms.TextBox
    $summary.Multiline = $true
    $summary.ReadOnly = $true
    $summary.WordWrap = $true
    $summary.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $summary.Font = Get-UiFont -Size 16
    $summary.Height = ConvertTo-UiPx 140
    $summary.Margin = New-UiPadding 0 4 0 12
    $summary.AccessibleName = Get-UiText -Key 'report.summary'
    if (-not $script:HighContrast) { $summary.BackColor = $script:Theme.Back; $summary.ForeColor = $script:Theme.Text }
    Register-UiWrap -Control $summary -FixedWidth
    $caption = Build-UiLabel -Text (Get-UiText -Key 'result.actions.title') -Size 16 -Bold
    $actions = New-Object System.Windows.Forms.ListBox
    $actions.Font = Get-UiFont -Size 14
    $actions.IntegralHeight = $false
    $actions.HorizontalScrollbar = $true
    $actions.Height = ConvertTo-UiPx 120
    $actions.Margin = New-UiPadding 0 0 0 12
    $actions.AccessibleName = Get-UiText -Key 'result.actions.title'
    if (-not $script:HighContrast) { $actions.BackColor = $script:Theme.Back; $actions.ForeColor = $script:Theme.Text }
    Register-UiWrap -Control $actions -FixedWidth
    $reboot = Build-UiLabel -Text (Get-UiText -Key 'result.reboot') -Size 18 -Bold -Color 'Warn'
    $path = Build-UiLabel -Text '' -Size 13 -Color 'Muted'
    $p.Body.Controls.AddRange(@($glyph, $title, $text, $extra, $summary, $caption, $actions, $reboot, $path))
    $report = Build-UiButton -Text (Get-UiText -Key 'result.show_report')
    $report.Add_Click({ Invoke-UiSafe { Open-UiReport } })
    $finish = Build-UiButton -Text (Get-UiText -Key 'result.finish') -Primary
    $finish.Add_Click({ Invoke-UiSafe { Close-UiApp } })
    $p.Bar.Controls.AddRange(@($finish, $report))
    $p.Focus = $finish
    $p.Accept = $finish
    $p.Cancel = $finish
    $script:Ui.ResultGlyph = $glyph
    $script:Ui.ResultTitle = $title
    $script:Ui.ResultText = $text
    $script:Ui.ResultExtra = $extra
    $script:Ui.ResultSummary = $summary
    $script:Ui.ResultActionsCaption = $caption
    $script:Ui.ResultActions = $actions
    $script:Ui.ResultReboot = $reboot
    $script:Ui.ResultPath = $path
    $script:Ui.ResultFinish = $finish
}

function Build-UiWindow {
    $form = New-Object System.Windows.Forms.Form
    $script:Form = $form
    $form.Text = Get-UiText -Key 'app.window_title'
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $area = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $w = [Math]::Min((ConvertTo-UiPx 1080), [int]($area.Width * 0.92))
    $h = [Math]::Min((ConvertTo-UiPx 800), [int]($area.Height * 0.92))
    $form.Size = New-Object System.Drawing.Size($w, $h)
    $form.MinimumSize = New-Object System.Drawing.Size([Math]::Min((ConvertTo-UiPx 640), $w), [Math]::Min((ConvertTo-UiPx 480), $h))
    $form.BackColor = $script:Theme.Back
    $form.ForeColor = $script:Theme.Text
    $form.Font = Get-UiFont -Size 15
    try { $form.Icon = Build-UiIcon } catch { Write-UiLog -Level Warn -Message ('Icon failed: ' + $_.Exception.Message) }

    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.Dock = [System.Windows.Forms.DockStyle]::Fill
    $root.ColumnCount = 1
    $root.RowCount = 2
    $null = $root.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $null = $root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $null = $root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $banner = New-Object System.Windows.Forms.Label
    $banner.Text = [string][char]0x26A0 + '  ' + (Get-UiText -Key 'ui.readonly.banner')
    $banner.UseMnemonic = $false
    $banner.AutoSize = $true
    $banner.Dock = [System.Windows.Forms.DockStyle]::Fill
    $banner.Font = Get-UiFont -Size 15 -Bold
    $banner.Padding = New-UiPadding 32 10 32 10
    $banner.Margin = New-Object System.Windows.Forms.Padding(0)
    $banner.BackColor = $script:Theme.Banner
    $banner.ForeColor = $script:Theme.BannerText
    $banner.Visible = $script:IsReadOnly
    $hostPanel = New-Object System.Windows.Forms.Panel
    $hostPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $hostPanel.Margin = New-Object System.Windows.Forms.Padding(0)
    $root.Controls.Add($banner, 0, 0)
    $root.Controls.Add($hostPanel, 0, 1)
    $form.Controls.Add($root)
    $script:PageHost = $hostPanel

    Build-UiWelcomePage
    Build-UiPreparingPage
    Build-UiCategoryPage
    Build-UiOtherPage
    Build-UiWorkingPage
    Build-UiResultPage

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 200
    $timer.Add_Tick({ Invoke-UiTick })
    $script:Timer = $timer

    $form.Add_Resize({ Update-UiWrap })
    $form.Add_Shown({
            Invoke-UiSafe {
                # Bring the window to the front once: it was started by a hidden process.
                $script:Form.TopMost = $true
                $script:Form.Activate()
                $script:Form.TopMost = $false
                Update-UiWrap
                if ($script:StartupError) {
                    Show-UiErrorPage -Key $script:StartupError
                    return
                }
                Show-UiPage -Name 'welcome'
                if ($script:IsReadOnly) {
                    $key = 'error.' + $script:ReadOnlyReasonKey
                    $null = Show-UiDialog -Heading (Get-UiText -Key ($key + '.title')) -Lines @(Get-UiText -Key ($key + '.text')) `
                        -YesText (Get-UiText -Key 'ui.button.understood')
                    if ($script:Pages['welcome'].Focus) { $null = $script:Pages['welcome'].Focus.Focus() }
                }
            }
        })
    $form.Add_FormClosing({
            param($s, $e)
            $null = $s
            if ($script:ForceClose) { return }
            if (Test-UiBusy) {
                $e.Cancel = $true
                if (Request-UiCancel) { $script:CloseWhenIdle = $true }
            }
        })
    $form.Add_FormClosed({
            try { $script:Timer.Stop() } catch { $null = $_ }
            Close-UiOllama
            Write-UiLog -Message 'Window closed'
        })
    return $form
}

# =============================================================================================================
# Main
# =============================================================================================================

try {
    # --- libraries: Common.ps1 for texts and log, Ollama.ps1 for Stop-PnhOllama ----------------------------
    $commonLoaded = $false
    try {
        . (Join-Path -Path $script:AppDir -ChildPath 'lib\Common.ps1')
        $commonLoaded = $true
    } catch {
        $script:LibraryError = $_
    }
    if (-not $commonLoaded) {
        $script:PnhFallbackAppDir = $script:AppDir
        . ([scriptblock]::Create($script:UiFallbackLib))
        if (-not $script:IsDemo) { $script:StartupError = 'error.damaged' }
    }
    if ($commonLoaded -and -not $script:IsDemo) {
        try { . (Join-Path -Path $script:AppDir -ChildPath 'lib\Ollama.ps1') } catch { $script:LibraryError = $_ }
    }

    # --- run folder -----------------------------------------------------------------------------------------
    try {
        if ($RunFolder -and (Test-Path -LiteralPath $RunFolder)) {
            $script:PnhRunFolder = $RunFolder
        } elseif ($commonLoaded -and -not $script:IsDemo) {
            $script:PnhRunFolder = New-PnhRunFolder
        } else {
            $demoRoot = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath 'PlugNHeal-demo'
            $script:PnhRunFolder = Join-Path -Path $demoRoot -ChildPath ($env:COMPUTERNAME + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
            $null = New-Item -ItemType Directory -Path $script:PnhRunFolder -Force
        }
        $script:RunFolderPath = [string]$script:PnhRunFolder
    } catch {
        $script:RunFolderPath = $null
    }
    if ($script:LibraryError) {
        Write-UiLog -Level Error -Message ('Library failed to load: ' + $script:LibraryError.Exception.Message) -Data @{ Stack = $script:LibraryError.ScriptStackTrace }
    }
    try { $script:Language = Get-PnhLanguage } catch { $script:Language = 'en' }
    Write-UiLog -Message ('Ui.ps1 started: PowerShell {0}, language {1}, demo={2}, readonly={3} ({4})' -f
        $PSVersionTable.PSVersion, $script:Language, $script:IsDemo, $script:IsReadOnly, $script:ReadOnlyReasonKey)

    # --- WinForms ---------------------------------------------------------------------------------------------
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $dpiMode = Initialize-UiDpi
    try { [System.Windows.Forms.Application]::EnableVisualStyles() } catch { $null = $_ }
    try { [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false) } catch { $null = $_ }
    try { [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException) } catch { $null = $_ }
    [System.Windows.Forms.Application]::add_ThreadException({
            param($s, $e)
            $null = $s
            Write-UiLog -Level Error -Message ('Unhandled UI exception: ' + $e.Exception.ToString())
            try { if ($script:CurrentPage -ne 'result') { Show-UiErrorPage -Key 'error.unexpected' } } catch { $null = $_ }
        })
    $g = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    try { $script:Scale = [Math]::Max(1.0, $g.DpiX / 96.0) } finally { $g.Dispose() }
    Write-UiLog -Message ('DPI: ' + $dpiMode + ', scale ' + $script:Scale)
    Initialize-UiTheme

    # --- one window only --------------------------------------------------------------------------------------
    if (-not $script:IsDemo) {
        $createdNew = $false
        try {
            $script:Mutex = New-Object System.Threading.Mutex($true, 'Local\PlugNHeal.Ui', [ref]$createdNew)
            $script:OwnsMutex = $createdNew
        } catch {
            $script:OwnsMutex = $false
        }
        if (-not $script:OwnsMutex) {
            Write-UiLog -Level Warn -Message 'Another Plug''n''Heal window is already open'
            $null = Show-UiDialog -Heading (Get-UiText -Key 'error.already_running.title') -Lines @(Get-UiText -Key 'error.already_running.text') `
                -YesText (Get-UiText -Key 'ui.button.ok')
            return
        }
    }

    $null = Build-UiWindow
    [System.Windows.Forms.Application]::Run($script:Form)
} catch {
    $fatal = $_
    Write-UiLog -Level Error -Message ('Ui.ps1 failed: ' + $fatal.Exception.Message) -Data @{ Stack = $fatal.ScriptStackTrace }
    try {
        $null = [System.Windows.Forms.MessageBox]::Show((Get-UiText -Key 'error.unexpected.text'), (Get-UiText -Key 'error.unexpected.title'),
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
    } catch {
        $null = $_
    }
} finally {
    try { Close-UiOllama } catch { $null = $_ }
    if ($script:Mutex) {
        try { if ($script:OwnsMutex) { $script:Mutex.ReleaseMutex() } } catch { $null = $_ }
        $script:Mutex.Dispose()
    }
    $stillRunning = $false
    if ($script:Job -and $script:Job.Handle -and -not $script:Job.Handle.IsCompleted) { $stillRunning = $true }
    if (-not $stillRunning -and $script:Runspace) { try { $script:Runspace.Dispose() } catch { $null = $_ } }
    if ($stillRunning) {
        # A background step that cannot be interrupted must not keep the process (and the drive) busy.
        [System.Environment]::Exit(0)
    }
}
