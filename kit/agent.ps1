<#
  agent.ps1 - Plug'n'Heal network rescue kit.

  Runs a local AI agent (Codex CLI + Ollama) in rounds until the network check passes.
  Started by Start-Repair.cmd (as Administrator). Windows PowerShell 5.1.

  - The harness, not the model, decides when the job is done: only tools\check-network.ps1 with exit code 0 ends it.
  - Every round is a fresh agent session that gets the current check result, the owner's notes and the tail of
    work\protocol.md (its memory across rounds and restarts).
  - Live status: every message of the model and every command it runs is shown with a time stamp, written to
    work\status.log, and the window title shows round, run time and the last status.
  - The agent may stop early only by writing work\STOP.txt (truly blocked) or work\NEEDS_REBOOT.txt.

  Exit code: 0 = network works, 1 = not solved (stopped, reboot needed, rounds used up, start failure).
#>
param(
    [int]$MaxRounds = 30,
    [string]$Model = '',
    [string]$Effort = '',
    [int]$RoundMinutes = 45,
    [int]$ContextLength = 65536,
    [int]$OllamaPort = 11434,
    [string]$Shell = 'powershell.exe',
    [string]$CodexPath = '',
    [switch]$SkipOllama
)
$ErrorActionPreference = 'Continue'
$Root = $PSScriptRoot
$Work = Join-Path $Root 'work'
$Tools = Join-Path $Root 'tools'
$Proto = Join-Path $Work 'protocol.md'
$StatusLog = Join-Path $Work 'status.log'
$NotesFile = Join-Path $Work 'NOTES.md'
$CheckScript = Join-Path $Tools 'check-network.ps1'
$BlockerScript = Join-Path $Tools 'find-blockers.ps1'
$Ollama = Join-Path (Join-Path $Root 'ollama') 'ollama.exe'
if (-not $CodexPath) { $CodexPath = Join-Path (Join-Path (Join-Path $Root 'codex') 'bin') 'codex.exe' }
$Base = 'http://127.0.0.1:' + $OllamaPort
$OnWindows = ($env:OS -eq 'Windows_NT')
New-Item -ItemType Directory -Force -Path $Work, (Join-Path $Root 'codex-home') | Out-Null

# model: parameter, else what sync-drive.ps1 wrote into kit.json, else the default
$KitFile = Join-Path $Root 'kit.json'
$kitInfo = $null
if (Test-Path -LiteralPath $KitFile) { try { $kitInfo = Get-Content -LiteralPath $KitFile -Raw | ConvertFrom-Json } catch { } }
if ((-not $Model) -and $kitInfo -and $kitInfo.model) { $Model = [string]$kitInfo.model }
if (-not $Model) { $Model = 'qwen3.8:27b' }
# reasoning effort sent to the model. qwen3.8 in Ollama 0.40 knows low, medium (its default) and xhigh; a name the
# model does not know falls back to its default, and models with on/off thinking just think.
if ((-not $Effort) -and $kitInfo -and $kitInfo.effort) { $Effort = [string]$kitInfo.effort }
if (-not $Effort) { $Effort = 'xhigh' }

# the agent reads AGENTS.md from its working folder; refresh it from the kit on every start
$mission = Join-Path $Root 'AGENTS.md'
if (Test-Path -LiteralPath $mission) { Copy-Item -LiteralPath $mission -Destination (Join-Path $Work 'AGENTS.md') -Force }

$env:OLLAMA_MODELS = Join-Path $Root 'models'
$env:OLLAMA_HOST = '127.0.0.1:' + $OllamaPort
$env:OLLAMA_CONTEXT_LENGTH = [string]$ContextLength
$env:OLLAMA_FLASH_ATTENTION = '1'
$env:OLLAMA_KV_CACHE_TYPE = 'q8_0'
$env:OLLAMA_NOPRUNE = '1'
$env:CODEX_HOME = Join-Path $Root 'codex-home'
$env:CODEX_OSS_BASE_URL = $Base + '/v1'
if ($OnWindows) {
    $env:PATH = (Join-Path $Root 'codex\codex-path') + ';' + (Join-Path $Root 'codex\bin') + ';' + (Join-Path $Root 'ollama\lib\ollama\vulkan') + ';' + $env:PATH
}

$script:LastStatus = 'starting'
$script:RunStart = Get-Date
$script:GpuShown = $false

function Cut([string]$t, [int]$n) {
    if ($null -eq $t) { return '' }
    $t = ($t -replace '\s+', ' ').Trim()
    if ($t.Length -gt $n) { return $t.Substring(0, $n) + ' ...' }
    return $t
}
function Say([string]$t, [string]$c = 'Gray') { Write-Host $t -ForegroundColor $c }
function Log([string]$t) { Add-Content -LiteralPath $Proto -Value $t -Encoding UTF8 }
function Stamp { Get-Date -Format 'yyyyMMdd-HHmmss' }
function Status([string]$kind, [string]$text, [string]$color = 'Gray') {
    $line = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $kind + ': ' + $text
    Write-Host $line -ForegroundColor $color
    try { Add-Content -LiteralPath $StatusLog -Value $line -Encoding UTF8 } catch { }
    $script:LastStatus = $kind + ': ' + (Cut $text 80)
}
function Set-Title([int]$round) {
    $d = (Get-Date) - $script:RunStart
    $t = 'AI repair | round {0}/{1} | {2:00}:{3:00}:{4:00} | {5}' -f $round, $MaxRounds, [int][math]::Floor($d.TotalHours), $d.Minutes, $d.Seconds, $script:LastStatus
    try { $Host.UI.RawUI.WindowTitle = $t } catch { }
}

function Test-Network {
    $out = & $Shell -NoProfile -ExecutionPolicy Bypass -File $CheckScript 2>&1 | Out-String
    return [pscustomobject]@{ Passed = ($LASTEXITCODE -eq 0); Text = $out.Trim() }
}
function Test-OllamaReady {
    try { Invoke-RestMethod -UseBasicParsing -Uri ($Base + '/api/tags') -TimeoutSec 2 | Out-Null; return $true } catch { return $false }
}
function Show-GpuShare {
    if ($script:GpuShown -or $SkipOllama) { return }
    try {
        $ps = Invoke-RestMethod -UseBasicParsing -Uri ($Base + '/api/ps') -TimeoutSec 5
        foreach ($m in @($ps.models)) {
            $pct = 0
            if ($m.size -gt 0) { $pct = [int](100 * $m.size_vram / $m.size) }
            Status 'MODEL' ('{0} loaded, {1} % on the graphics card, context {2}' -f $m.name, $pct, $m.context_length) 'DarkCyan'
            if ($pct -lt 90) { Status 'NOTE' 'The model does not fit completely on the graphics card, so it answers more slowly.' 'DarkYellow' }
            $script:GpuShown = $true
        }
    } catch { }
}

# ---------- live reading of the Codex event stream (JSON lines) ----------
function Reset-Reader {
    $script:OutPos = [int64]0
    $script:OutRest = ''
    $script:Decoder = [System.Text.Encoding]::UTF8.GetDecoder()
    $script:ReadError = ''
    $script:RoundLog = New-Object System.Collections.ArrayList
}
function Read-NewLines([string]$path) {
    $lines = @()
    if (-not (Test-Path -LiteralPath $path)) { return , $lines }
    try {
        $fs = New-Object System.IO.FileStream($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            if ($fs.Length -gt $script:OutPos) {
                [void]$fs.Seek($script:OutPos, [System.IO.SeekOrigin]::Begin)
                $len = [int]($fs.Length - $script:OutPos)
                $buf = New-Object byte[] $len
                $n = $fs.Read($buf, 0, $len)
                $script:OutPos += $n
                $chars = New-Object char[] ([System.Text.Encoding]::UTF8.GetMaxCharCount($n))
                $c = $script:Decoder.GetChars($buf, 0, $n, $chars, 0)
                $text = $script:OutRest + [string]::new($chars, 0, $c)
                $parts = $text -split "`n"
                $script:OutRest = $parts[$parts.Length - 1]
                if ($parts.Length -gt 1) { $lines = @($parts[0..($parts.Length - 2)]) }
            }
        } finally { $fs.Close() }
    } catch { $script:ReadError = $_.Exception.Message }
    return , $lines
}
function Show-Event([string]$line) {
    $line = $line.Trim()
    if (-not $line.StartsWith('{')) { return $false }
    try { $e = $line | ConvertFrom-Json } catch { return $false }
    $type = [string]$e.type
    $item = $e.item
    if ($type -eq 'item.started' -and $item -and [string]$item.type -eq 'command_execution') {
        Status 'COMMAND' (Cut ([string]$item.command) 260) 'Yellow'
        return $true
    }
    if ($type -eq 'item.completed' -and $item) {
        $it = [string]$item.type
        if ($it -eq 'agent_message') {
            Status 'AI' (Cut ([string]$item.text) 700) 'White'
            [void]$script:RoundLog.Add('- AGENT SAID: ' + (Cut ([string]$item.text) 300))
        }
        elseif ($it -eq 'reasoning') { Status 'thinking' (Cut ([string]$item.text) 220) 'DarkGray' }
        elseif ($it -eq 'command_execution') {
            Status ('  -> result (exit ' + [string]$item.exit_code + ')') (Cut ([string]$item.aggregated_output) 320) 'Gray'
            [void]$script:RoundLog.Add('- RAN (exit ' + [string]$item.exit_code + '): ' + (Cut ([string]$item.command) 220) + '  =>  ' + (Cut ([string]$item.aggregated_output) 180))
        }
        elseif ($it -eq 'error') {
            # Codex always reports that it has no metadata for local models; that is not a fault.
            if ([string]$item.message -match 'Model metadata') { return $false }
            Status 'ERROR' (Cut ([string]$item.message) 400) 'Red'
        }
        return $true
    }
    if ($type -eq 'error' -or $type -eq 'turn.failed') { Status 'ERROR' (Cut $line 500) 'Red'; return $true }
    if ($type -eq 'turn.completed' -and $e.usage) {
        Status 'ROUND' ('finished, tokens in {0}, out {1}' -f $e.usage.input_tokens, $e.usage.output_tokens) 'DarkGray'
        return $true
    }
    return $false
}

# ---------- signals from earlier runs ----------
$reboot = Join-Path $Work 'NEEDS_REBOOT.txt'
$stop = Join-Path $Work 'STOP.txt'
$note = ''
if (Test-Path -LiteralPath $reboot) {
    $note = 'A reboot was requested in the previous run (see NEEDS_REBOOT-done-*.txt) and has happened now. Check whether static IP addresses must be restored from protocol.md.'
    Rename-Item -LiteralPath $reboot -NewName ('NEEDS_REBOOT-done-' + (Stamp) + '.txt')
}
if (Test-Path -LiteralPath $stop) {
    Say ''; Say 'In the last run the agent stopped because:' Yellow
    Get-Content -LiteralPath $stop | ForEach-Object { Say ('  ' + $_) Yellow }
    $a = ''
    try { $a = Read-Host 'Try again anyway? (y/n)' } catch { }
    if ($a -notmatch '^[yYjJ]') { Say 'Ended. The reason is in work\STOP.txt.'; exit 1 }
    Rename-Item -LiteralPath $stop -NewName ('STOP-' + (Stamp) + '.txt')
    $note = 'The previous run stopped with STOP.txt (renamed to STOP-*.txt). The owner wants you to try again: read that file, then try what was not tried yet.'
}

# ---------- notes from the owner (asked once) ----------
if (-not (Test-Path -LiteralPath $NotesFile)) {
    Say ''
    Say 'Optional: describe the problem in one or two sentences. What stopped working, since when, what did you try?' Cyan
    $txt = ''
    try { $txt = Read-Host 'Your description (or just press Enter)' } catch { }
    if ($txt -and $txt.Trim()) { Set-Content -LiteralPath $NotesFile -Value $txt.Trim() -Encoding UTF8 }
    else { Set-Content -LiteralPath $NotesFile -Value '(none)' -Encoding UTF8 }
}
$notes = ''
try { $notes = ([string](Get-Content -LiteralPath $NotesFile -Raw)).Trim() } catch { }
$notesBlock = ''
if ($notes -and $notes -ne '(none)') { $notesBlock = "Notes from the owner of this PC (facts, treat them as true):`n" + $notes }

# ---------- Ollama ----------
if (-not $SkipOllama) {
    if (-not (Test-OllamaReady)) {
        Get-Process ollama -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Process -FilePath $Ollama -ArgumentList 'serve' -WindowStyle Minimized
        Status 'START' 'Starting the language model ...' 'Cyan'
        for ($i = 0; $i -lt 90 -and -not (Test-OllamaReady); $i++) { Start-Sleep -Seconds 1 }
    }
    if (-not (Test-OllamaReady)) { Say 'Ollama does not start. Giving up.' Red; exit 1 }
}

if (-not (Test-Path -LiteralPath $Proto)) { Set-Content -LiteralPath $Proto -Value '# Repair protocol (written by the agent and the harness)' -Encoding UTF8 }
Log ''
Log ('## ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' Harness started (max ' + $MaxRounds + ' rounds, model ' + $Model + ', reasoning effort ' + $Effort + ')')
Say ''
Say 'How to read this:  AI = what the model says   COMMAND = what it runs right now   -> result = what came back' DarkCyan
Say ('Everything is also written to ' + $StatusLog) DarkCyan
Say ('Model: ' + $Model + '   reasoning effort: ' + $Effort) DarkCyan

$checkCmd = $Shell + ' -NoProfile -ExecutionPolicy Bypass -File "' + $CheckScript + '"'
$blockCmd = $Shell + ' -NoProfile -ExecutionPolicy Bypass -File "' + $BlockerScript + '"'
$ctxCodex = [int]($ContextLength * 0.9)
$ctxCompact = [int]($ContextLength * 0.7)
$quickFails = 0

# ---------- rounds ----------
for ($round = 1; $round -le $MaxRounds; $round++) {
    Set-Title $round
    $check = Test-Network
    if ($check.Passed) {
        Log ('## ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' Harness: check-network.ps1 PASSED. Network works. Done.')
        Status 'SOLVED' 'The network works again.' 'Green'
        Say ('What was done is written in ' + $Proto) Green
        Set-Title $round
        exit 0
    }
    if (Test-Path -LiteralPath $stop) {
        Status 'STOPPED' 'The agent stopped and explains why:' 'Yellow'
        Get-Content -LiteralPath $stop | ForEach-Object { Say ('  ' + $_) Yellow }
        Say 'Show this to whoever helps you with this PC.' Yellow
        exit 1
    }
    if (Test-Path -LiteralPath $reboot) {
        Status 'RESTART' 'The computer must restart:' 'Cyan'
        Get-Content -LiteralPath $reboot | ForEach-Object { Say ('  ' + $_) Cyan }
        Say 'Please restart now and then double-click Start-Repair.cmd again. The agent continues where it stopped.' Cyan
        exit 1
    }

    $tail = (Get-Content -LiteralPath $Proto -Tail 200 -ErrorAction SilentlyContinue) -join "`n"
    $prompt = @"
ROUND $round of $MaxRounds.
Follow AGENTS.md in this folder exactly. You run on this PC as Administrator and execute the commands yourself.

Check command (exit code 0 = fixed):
$checkCmd
Deep diagnosis command (read-only):
$blockCmd

The automatic check FAILS right now. Its output:
$($check.Text)

$notesBlock

$note

Last part of protocol.md (your memory of earlier rounds; the 'Automatic summary' blocks list what was really run):
$tail

Continue from where the protocol ends: do the next concrete diagnosis or repair steps NOW by running commands.
Before each step, tell the user in ONE short English sentence what you are doing now and why.
Do not repeat a fix the protocol shows already failed. Append every step to protocol.md.
Do not end your turn until the check command returns exit code 0, or you created STOP.txt (truly blocked, explain
why), or NEEDS_REBOOT.txt (a reboot is needed, explain why).
"@
    $note = ''
    $pf = Join-Path $Work ('prompt-round-' + $round + '.txt')
    $outFile = Join-Path $Work ('round-' + $round + '.jsonl')
    $errFile = Join-Path $Work ('round-' + $round + '.err.txt')
    [System.IO.File]::WriteAllText($pf, $prompt, (New-Object System.Text.UTF8Encoding($false)))
    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    Log ('## ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' Harness: round ' + $round + ' starts, check FAILED')

    Say ''
    Status ('ROUND ' + $round + '/' + $MaxRounds) 'The network is still broken, the agent keeps working.' 'Cyan'
    $argList = 'exec --json --oss --local-provider ollama -c model_provider=ollama' +
        ' -c model_context_window=' + $ctxCodex + ' -c model_auto_compact_token_limit=' + $ctxCompact +
        ' -c model_reasoning_effort=' + $Effort +
        ' -m ' + $Model + ' --dangerously-bypass-approvals-and-sandbox --skip-git-repo-check' +
        ' -C "' + $Work + '" -o "' + (Join-Path $Work 'last-answer.txt') + '" -'
    $roundStart = Get-Date
    $p = Start-Process -FilePath $CodexPath -ArgumentList $argList -RedirectStandardInput $pf -RedirectStandardOutput $outFile -RedirectStandardError $errFile -NoNewWindow -PassThru
    $null = $p.Handle   # keeps the exit code readable in Windows PowerShell 5.1
    Reset-Reader
    $events = 0
    $lastEvent = Get-Date
    $nextBeat = 45
    $killed = $false
    while (-not $p.HasExited) {
        foreach ($l in (Read-NewLines $outFile)) {
            if (Show-Event $l) { $events++; $lastEvent = Get-Date; $nextBeat = 45 }
        }
        if ($events -gt 0) { Show-GpuShare }
        $idle = [int]((Get-Date) - $lastEvent).TotalSeconds
        if ($idle -ge $nextBeat) {
            Write-Host ('[' + (Get-Date -Format 'HH:mm:ss') + '] ... the model is still working (no new message for ' + $idle + ' s)') -ForegroundColor DarkGray
            $nextBeat += 45
        }
        Set-Title $round
        if (((Get-Date) - $roundStart).TotalMinutes -ge $RoundMinutes) {
            Status 'TIME' ('Round ' + $round + ' takes longer than ' + $RoundMinutes + ' minutes; stopping it and starting the next one.') 'DarkYellow'
            if ($OnWindows) { & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null } else { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
            $killed = $true
            break
        }
        Start-Sleep -Milliseconds 700
    }
    if (-not $killed) { $p.WaitForExit() }
    Start-Sleep -Milliseconds 300
    foreach ($l in (Read-NewLines $outFile)) { if (Show-Event $l) { $events++ } }
    $code = $p.ExitCode
    $secs = [int]((Get-Date) - $roundStart).TotalSeconds
    if ($script:RoundLog.Count -gt 0) {
        Log ('### Automatic summary of round ' + $round + ' (written by the harness from what the agent really did)')
        $take = @($script:RoundLog)
        if ($take.Count -gt 40) { Log ('- (' + ($take.Count - 40) + ' earlier entries omitted)'); $take = $take[($take.Count - 40)..($take.Count - 1)] }
        foreach ($x in $take) { Log $x }
    }
    Log ('## ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' Harness: round ' + $round + ' ended (codex exit ' + $code + ', ' + $events + ' events, ' + $secs + ' s)')
    if ($code -ne 0 -or $events -eq 0) {
        $errTail = (Get-Content -LiteralPath $errFile -Tail 6 -ErrorAction SilentlyContinue) -join ' | '
        Status 'ERROR' ('The agent ended with exit code ' + $code + ' and ' + $events + ' messages. ' + (Cut $errTail 500) + ' ' + $script:ReadError) 'Red'
    }
    if ($events -eq 0 -and $secs -lt 60) { $quickFails++ } else { $quickFails = 0 }
    if ($quickFails -ge 3) {
        Say ''
        Say 'The agent failed to start three times in a row. Giving up.' Red
        Say ('Details are in ' + $errFile) Red
        exit 1
    }
}

$final = Test-Network
if ($final.Passed) {
    Status 'SOLVED' 'The network works again.' 'Green'
    exit 0
}
Log ('## ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + ' Harness: ' + $MaxRounds + ' rounds used, network still broken.')
Say ('After ' + $MaxRounds + ' rounds the network is still broken. What was tried is in ' + $Proto) Yellow
exit 1
