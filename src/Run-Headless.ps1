<#
.SYNOPSIS
    Plug'n'Heal without a window: hardware -> model -> Ollama -> agent, the same flow as the UI.
.DESCRIPTION
    Used by CI, experts and scripted tests. Prints one progress line per step. With -Json the progress lines go
    to stderr and stdout carries only the result as JSON (exitCode, solved, stoppedReason, rounds, nudges,
    rediagnoses, compactions, seconds, category, model, runFolder, summary, readOnly, wouldHelp, actions, tried,
    error).
    The agent keeps going until the success check passes or nothing is left to try; -MaxRounds and -MaxMinutes are
    its hard limits.
    Exit code: 0 = solved (the category success check passed), 1 = not solved, 2 = error.
.PARAMETER Category
    Problem category id from toolbox\categories.json (network, slow, disk, printer, sound, update, other, all).
.PARAMETER UserText
    The person's own words (optional).
.PARAMETER AutoConfirm
    Answer every confirmation with "Yes". Without it, an interactive console asks; a non-interactive run says "No".
.PARAMETER Model
    Model tag to use instead of the automatic choice (must be installed; no step-down when given).
.PARAMETER NoOllamaStart
    Use an Ollama server that is already running at -BaseUrl instead of starting the one on the drive.
.PARAMETER BaseUrl
    For -NoOllamaStart, e.g. http://127.0.0.1:11434.
.PARAMETER Json
    Print the result as JSON on stdout.
.PARAMETER ReadOnly
    Only look, change nothing (same as refusing the UAC prompt in the UI): confirmations are never asked, the summary
    lists what would help.
.PARAMETER MaxRounds
    Agent rounds at most (default 30).
.PARAMETER MaxMinutes
    Wall-clock limit of the agent loop in minutes (default 30).
.PARAMETER Language
    de or en (default: Windows display language).
.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File .\Run-Headless.ps1 -Category printer -AutoConfirm -Model qwen3.5:2b-q4_K_M
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Category,
    [string]$UserText,
    [switch]$AutoConfirm,
    [string]$Model,
    [switch]$NoOllamaStart,
    [string]$BaseUrl,
    [switch]$Json,
    [int]$MaxRounds = 30,
    [int]$MaxMinutes = 30,
    [ValidateSet('de', 'en')][string]$Language,
    [switch]$ReadOnly
)

$ErrorActionPreference = 'Stop'
$script:HeadlessJson = [bool]$Json
$script:HeadlessStart = Get-Date

function Write-PnhHeadlessLine {
    param([string]$Text)
    $line = '[{0}] {1}' -f (Get-Date).ToString('HH:mm:ss'), $Text
    if ($script:HeadlessJson) { [Console]::Error.WriteLine($line) } else { [Console]::Out.WriteLine($line) }
}

function Get-PnhHeadlessMember {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

# Libraries (dot-sourced at script level so their functions and script variables live here).
$libDir = Join-Path $PSScriptRoot 'lib'
foreach ($lib in @('Common', 'Hardware', 'Models', 'Ollama', 'Diagnose', 'Toolbox', 'Agent')) {
    $path = Join-Path $libDir ($lib + '.ps1')
    if (-not (Test-Path -LiteralPath $path)) {
        Write-PnhHeadlessLine ('ERROR: library missing: ' + $path)
        exit 2
    }
    . $path
}

$exitCode = 2
$server = $null
$startedServer = $false
$result = $null
$runFolder = $null
$entry = $null
$errorText = $null

$onEvent = {
    param($ev)
    switch ([string]$ev.Type) {
        'step-start' { Write-PnhHeadlessLine ('> ' + $ev.Text) }
        'step-done' { Write-PnhHeadlessLine ('  {0}: {1}' -f $ev.Key, $(if ($ev.Ok) { 'ok' } else { 'not ok' })) }
        'thinking' { Write-PnhHeadlessLine ('  round {0}: the model is thinking' -f $ev.Round) }
        'action' { Write-PnhHeadlessLine ('  action: {0} ({1})' -f $ev.Title, $ev.Id) }
        'action-result' {
            $r = $ev.Result
            $err = [string](Get-PnhHeadlessMember $r 'Error')
            Write-PnhHeadlessLine ('    -> ok={0} verified={1} declined={2}{3}' -f (Get-PnhHeadlessMember $r 'Ok'), (Get-PnhHeadlessMember $r 'Verified'), (Get-PnhHeadlessMember $r 'Declined'), $(if ($err) { ' error=' + $err } else { '' }))
        }
        'message' { Write-PnhHeadlessLine ('  {0}: {1}' -f $(if ($ev.Source) { $ev.Source } else { 'message' }), $ev.Text) }
        'done' { Write-PnhHeadlessLine ('> done: solved=' + $ev.Solved) }
        'error' { Write-PnhHeadlessLine ('  ERROR: ' + $ev.Text) }
        default { Write-PnhHeadlessLine ('  ' + $ev.Type) }
    }
}

if ($AutoConfirm) {
    $confirm = {
        param($req)
        Write-PnhHeadlessLine ('  confirm (automatic yes): ' + $req.Title)
        return $true
    }
} else {
    $confirm = {
        param($req)
        $interactive = [Environment]::UserInteractive
        try { if ([Console]::IsInputRedirected) { $interactive = $false } } catch { $interactive = $false }
        if (-not $interactive) {
            Write-PnhHeadlessLine ('  confirm (no -AutoConfirm, answered no): ' + $req.Title)
            return $false
        }
        $text = [string]$req.Title
        if ($req.Explain) { $text = $text + ' - ' + [string]$req.Explain }
        $answer = Read-Host ($text + ' [y/n]')
        return ($answer -match '^\s*(y|yes|j|ja)\s*$')
    }
}

try {
    $lang = $Language
    if (-not $lang) { $lang = Get-PnhLanguage }
    $runFolder = New-PnhRunFolder
    Write-PnhHeadlessLine ('Plug''n''Heal headless, category ' + $Category + ', run folder ' + $runFolder)
    Write-PnhLog -Message 'Headless run starts' -Data @{ category = $Category; model = $Model; noOllamaStart = [bool]$NoOllamaStart; autoConfirm = [bool]$AutoConfirm; readOnly = [bool]$ReadOnly }

    # 1. Hardware
    Write-PnhHeadlessLine ('> ' + (Get-PnhText -Key 'step.hardware' -Language $lang))
    $hw = $null
    try {
        $hw = Get-PnhHardware
        Write-PnhHeadlessLine ('  RAM {0:N1} GB, best dedicated VRAM {1:N1} GB, CPU {2}' -f ([double](Get-PnhHeadlessMember $hw 'RamBytes') / 1GB), ([double](Get-PnhHeadlessMember $hw 'BestDedicatedVramBytes') / 1GB), (Get-PnhHeadlessMember $hw 'CpuName'))
    } catch {
        Write-PnhHeadlessLine ('  hardware detection failed, continuing: ' + $_.Exception.Message)
        Write-PnhLog -Level Warn -Message ('Hardware detection failed: ' + $_.Exception.Message)
        $hw = @{ Gpus = @(); BestDedicatedVramBytes = 0; RamBytes = 0; FreeRamBytes = 0 }
    }

    # 2. Model
    Write-PnhHeadlessLine ('> ' + (Get-PnhText -Key 'step.model' -Language $lang))
    if ($NoOllamaStart) {
        if (-not $BaseUrl) { throw '-NoOllamaStart needs -BaseUrl' }
        $BaseUrl = $BaseUrl.TrimEnd('/')
        $tags = Invoke-RestMethod -Uri ($BaseUrl + '/api/tags') -UseBasicParsing -TimeoutSec 30
        $installed = @(@($tags.models) | ForEach-Object { [string]$_.name } | Where-Object { $_ })
    } else {
        $installed = @(Get-PnhInstalledModels)
    }
    $selArgs = @{ Hardware = $hw; Installed = $installed }
    if ($Model) { $selArgs['Prefer'] = $Model }
    $sel = Select-PnhModel @selArgs
    if (-not (Get-PnhHeadlessMember $sel 'Model')) {
        if ((Get-PnhHeadlessMember $sel 'Path') -eq 'too_weak') { throw ('This computer does not have enough memory for any installed model (RAM {0} GiB; installed: {1})' -f (Get-PnhHeadlessMember $sel 'RamGB'), ($installed -join ', ')) }
        throw ('No usable model installed (reason: {0}; installed: {1})' -f (Get-PnhHeadlessMember $sel 'Reason'), ($installed -join ', '))
    }
    # Candidates: the chosen model first, then the fallbacks, each with its own GPU/CPU placement and context length
    # (Get-PnhModelContext). Their Model entries already carry that ctx, which the agent sends with every request.
    $candidates = @(@(Get-PnhHeadlessMember $sel 'Candidates') | Where-Object { $_ })
    if ($candidates.Count -eq 0) { throw 'Select-PnhModel returned no candidates' }
    $candidate = $candidates[0]
    $entry = Get-PnhHeadlessMember $candidate 'Model'
    if ($Model -and [string](Get-PnhHeadlessMember $entry 'tag') -ne $Model) { throw ('Model {0} is not installed' -f $Model) }
    $ctx = [int](Get-PnhHeadlessMember $candidate 'Ctx')
    Write-PnhHeadlessLine ('  model {0}, ctx {1}, gpu {2}, reason {3}' -f (Get-PnhHeadlessMember $entry 'tag'), $ctx, (Get-PnhHeadlessMember $candidate 'UseGpu'), (Get-PnhHeadlessMember $sel 'Reason'))

    # 3. Ollama
    Write-PnhHeadlessLine ('> ' + (Get-PnhText -Key 'step.start' -Language $lang))
    if ($NoOllamaStart) {
        $ver = Invoke-RestMethod -Uri ($BaseUrl + '/api/version') -UseBasicParsing -TimeoutSec 30
        $server = @{ BaseUrl = $BaseUrl; Port = ([uri]$BaseUrl).Port; Process = $null; Version = [string]$ver.version; ContextLength = $ctx }
    } else {
        $server = Start-PnhOllama -Paths (Get-PnhPaths) -ContextLength $ctx
        $startedServer = $true
        $fit = Test-PnhModelFit -Server $server -Model ([string]$entry.tag) -ModelEntry $entry -UseGpu:([bool](Get-PnhHeadlessMember $candidate 'UseGpu')) -NumCtx $ctx
        Write-PnhHeadlessLine ('  fit: ok={0} reason={1} gpu={2}% {3} tokens/s' -f $fit.Ok, $fit.Reason, $fit.OnGpuPercent, $fit.TokensPerSecond)
        if (-not $fit.Ok -and -not $Model) {
            foreach ($fb in @($candidates | Select-Object -Skip 1)) {
                $fbEntry = Get-PnhHeadlessMember $fb 'Model'
                $fbCtx = [int](Get-PnhHeadlessMember $fb 'Ctx')
                $fit = Test-PnhModelFit -Server $server -Model ([string]$fbEntry.tag) -ModelEntry $fbEntry -UseGpu:([bool](Get-PnhHeadlessMember $fb 'UseGpu')) -NumCtx $fbCtx
                Write-PnhHeadlessLine ('  step down to {0} (ctx {1}): ok={2} reason={3} {4} tokens/s' -f $fbEntry.tag, $fbCtx, $fit.Ok, $fit.Reason, $fit.TokensPerSecond)
                $entry = $fbEntry
                $ctx = $fbCtx
                if ($fit.Ok) { break }
            }
        }
    }
    Write-PnhHeadlessLine ('  Ollama {0} at {1}' -f (Get-PnhHeadlessMember $server 'Version'), (Get-PnhHeadlessMember $server 'BaseUrl'))

    # 4. Agent (the candidate's entry carries its own ctx, the one the fit test loaded the model with: no reload)
    $agentArgs = @{
        Server = $server; ModelEntry = $entry; Category = $Category; RunFolder = $runFolder
        OnEvent = $onEvent; Confirm = $confirm; MaxRounds = $MaxRounds; MaxMinutes = $MaxMinutes; Language = $lang
    }
    if ($UserText) { $agentArgs['UserText'] = $UserText }
    if ($ReadOnly) { $agentArgs['ReadOnly'] = $true }
    $result = Invoke-PnhAgent @agentArgs
    if ($result.StoppedReason -eq 'error') { $exitCode = 2; $errorText = $result.Error }
    elseif ($result.Solved) { $exitCode = 0 }
    else { $exitCode = 1 }
} catch {
    $errorText = $_.Exception.Message
    Write-PnhHeadlessLine ('ERROR: ' + $errorText)
    try { Write-PnhLog -Level Error -Message ('Headless run failed: ' + $errorText) } catch { Write-Verbose $_.Exception.Message }
    $exitCode = 2
} finally {
    if ($startedServer -and $server) {
        try { Stop-PnhOllama -Server $server } catch { Write-PnhHeadlessLine ('  could not stop Ollama: ' + $_.Exception.Message) }
    }
}

$seconds = [Math]::Round(((Get-Date) - $script:HeadlessStart).TotalSeconds, 1)
if ($Json) {
    $actions = @()
    $tried = @()
    if ($result) {
        foreach ($t in @($result.Tried)) {
            if ($null -eq $t) { continue }
            $tried += , [ordered]@{ name = [string](Get-PnhHeadlessMember $t 'Name'); outcome = [string](Get-PnhHeadlessMember $t 'Outcome'); round = (Get-PnhHeadlessMember $t 'Round') }
        }
        foreach ($a in @($result.Actions)) {
            $actions += , [ordered]@{
                id = [string](Get-PnhHeadlessMember $a 'Id'); ok = (Get-PnhHeadlessMember $a 'Ok'); verified = (Get-PnhHeadlessMember $a 'Verified')
                declined = (Get-PnhHeadlessMember $a 'Declined'); skipped = [bool](Get-PnhHeadlessMember $a 'Skipped'); error = (Get-PnhHeadlessMember $a 'Error')
            }
        }
    }
    $out = [ordered]@{
        exitCode      = $exitCode
        solved        = $(if ($result) { [bool]$result.Solved } else { $false })
        stoppedReason = $(if ($result) { $result.StoppedReason } else { 'error' })
        rounds        = $(if ($result) { $result.Rounds } else { 0 })
        nudges        = $(if ($result) { [int]$result.Nudges } else { 0 })
        rediagnoses   = $(if ($result) { [int]$result.Rediagnoses } else { 0 })
        compactions   = $(if ($result) { [int]$result.Compactions } else { 0 })
        seconds       = $seconds
        category      = $Category
        model         = $(if ($entry) { [string](Get-PnhHeadlessMember $entry 'tag') } else { $null })
        runFolder     = $runFolder
        summary       = $(if ($result) { $result.Summary } else { $null })
        readOnly      = [bool]$ReadOnly
        wouldHelp     = $(if ($result) { @($result.WouldHelp) } else { @() })
        actions       = $actions
        tried         = $tried
        error         = $errorText
    }
    [Console]::Out.WriteLine((ConvertTo-Json -InputObject $out -Depth 6))
} else {
    if ($result) {
        [Console]::Out.WriteLine('')
        [Console]::Out.WriteLine($result.Summary)
        [Console]::Out.WriteLine('')
    }
    if ($result) { Write-PnhHeadlessLine ('stopped: {0}, rounds {1}, nudges {2}' -f $result.StoppedReason, $result.Rounds, $result.Nudges) }
    Write-PnhHeadlessLine ('exit {0} after {1} s' -f $exitCode, $seconds)
}
exit $exitCode
