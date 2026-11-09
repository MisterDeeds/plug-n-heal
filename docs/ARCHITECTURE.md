# Plug'n'Heal – Architecture and contracts

Status: design for version 0.1. This file is the contract between the parts. If code and this file disagree, fix one of
them in the same change.

## 1. Idea in one paragraph

A person plugs an external SSD into a Windows 10/11 PC and double-clicks `START.cmd`. Plug'n'Heal detects the hardware,
starts a local language model with Ollama (no internet needed), asks in plain words what is wrong (or checks
everything), collects facts with a fixed read-only diagnosis, and lets the model pick repair steps from a catalogue of
tested, reversible actions. Every change is backed up first, verified afterwards by a script (not by the model), and
written to a log on the SSD. Large models may additionally propose free PowerShell commands, which are filtered and need
the user's "Yes" when they change something.

A separate builder fills an empty SSD on any PC with internet: runtime, models chosen by size, scripts, licences.

## 2. Principles

1. **Measure first, then ask the model.** The model gets facts, not a blank shell.
2. **The model chooses, the script acts.** Actions are code we wrote and tested. Arguments are validated.
3. **Success is decided by a script.** A model saying "fixed" means nothing until the category check passes.
4. **Every change is reversible or confirmed.** Backup before, rollback known, restore point before the first change.
5. **Never fight security.** No action disables or bypasses Defender, firewall policy, SmartScreen, BitLocker or
   device isolation. If Defender for Endpoint isolated the PC, Plug'n'Heal explains it and stops.
6. **One window, big buttons, plain language.** No console, no jargon, no question the user cannot answer.
7. **Nothing hard-coded about the drive.** Drive letters change; everything is derived from `$PSScriptRoot`.
8. **Windows PowerShell 5.1 is the target.** Everything must run on a stock Windows 10 21H2+ / 11 without installing
   anything. PowerShell 7 must also work (CI tests both).

## 3. Layout

### 3.1 Repository

```
README.md, README.de.md, LICENSE (Apache-2.0), NOTICE, THIRD-PARTY-NOTICES.md, SECURITY.md, CONTRIBUTING.md, CHANGELOG.md
BUILD.cmd                      builder entry for Windows (double-click on a PC with internet)
builder/
  Build-Drive.ps1              builder logic (Windows, PowerShell 5.1), WinForms wizard + -NonInteractive mode
  build-drive.sh               builder for Linux/macOS (bash + curl + python3), same result on the drive
  versions.json                pinned runtime version, URL, size, sha256
src/                           copied 1:1 to <drive>\PlugNHeal\app\
  START.cmd                    copied to the drive root
  Start.ps1                    entry point (checks, single UAC prompt, launches Ui.ps1 without console)
  Ui.ps1                       WinForms user interface
  Run-Headless.ps1             same flow without UI (CI, experts, scripted tests)
  lib/Common.ps1               paths, logging, i18n, hidden process start, JSON helpers
  lib/Hardware.ps1             GPU/VRAM, RAM, CPU, disk, Windows edition, language mode
  lib/Models.ps1               model catalogue and selection
  lib/Ollama.ps1               start/stop server, wait, chat, ps, version
  lib/Diagnose.ps1             read-only fact collection per category
  lib/Toolbox.ps1              action catalogue engine: validate, backup, run, verify, rollback, restore point
  lib/Agent.ps1                the agent loop
  catalog/models.json          model ladder
  toolbox/actions.json         action catalogue
  toolbox/categories.json      problem categories, their diagnosis sections and success checks
  i18n/de.json, i18n/en.json   all user-visible strings
  prompts/system.de.md, prompts/system.en.md
tests/                         Pester 5 tests (run on PS 5.1 and 7)
docs/                          ARCHITECTURE.md, SAFETY.md, MODELS.md, TOOLBOX.md, BUILDING.md, TESTING.md, research/
.github/workflows/ci.yml
```

### 3.2 The finished drive (exFAT, label `PLUGNHEAL`)

```
X:\START.cmd                   the only thing a user clicks
X:\README.txt                  short bilingual instructions
X:\PlugNHeal\app\              copy of src\
X:\PlugNHeal\runtime\ollama\   extracted ollama-windows-amd64.zip (ollama.exe, lib\ollama\...)
X:\PlugNHeal\models\           OLLAMA_MODELS (blobs\, manifests\)
X:\PlugNHeal\home\             USERPROFILE/HOME for the Ollama process (its key pair stays on the drive)
X:\PlugNHeal\logs\<COMPUTERNAME>-<yyyyMMdd-HHmmss>\   one folder per run
X:\PlugNHeal\licenses\         THIRD-PARTY-NOTICES.md and licence texts of runtime and models
X:\PlugNHeal\drive.json        build manifest (see 5.3)
```

## 4. Runtime flow

```
START.cmd
  └─ powershell 5.1 -NoProfile -ExecutionPolicy Bypass -File app\Start.ps1
       ├─ LanguageMode must be FullLanguage, else message + exit (company PC / Smart App Control)
       ├─ not elevated → relaunch itself elevated once (UAC "Yes"); if refused → continue in read-only mode
       │    (a big banner explains it; diagnostics only, every change is skipped, the result says what would help;
       │    `Invoke-PnhAgent -ReadOnly`)
       └─ start Ui.ps1 hidden (CreateNoWindow), exit → console closes
Ui.ps1
  1. Welcome: big button "Help me" / "Hilfe starten"
  2. Background runspace: Get-PnhHardware → Select-PnhModel → Start-PnhOllama → Test-PnhModelFit (may step down)
  3. "What is wrong?": category buttons (internet, slow, disk full, printer, sound, Windows Update, other(text),
     "I don't know – check everything")
  4. Invoke-PnhAgent with events → step list with ○ / spinner / ✓ / ⚠, confirmation dialogs
  5. Result page: plain summary, "Open report", log path; "Done" stops Ollama and closes
```

## 5. Contracts

All functions use the prefix `Pnh`. All return plain `[pscustomobject]` / hashtables that serialize with
`ConvertTo-Json -Depth 10`. No function writes to the console except through `Write-PnhLog`.

### 5.1 Common.ps1

```powershell
Get-PnhRoot                       # -> X:\PlugNHeal   (from $PSScriptRoot, never stored)
Get-PnhPaths                      # -> @{Root; App; Runtime; OllamaExe; Models; Home; Logs; Licenses; DriveJson}
New-PnhRunFolder                  # -> path of logs\<COMPUTERNAME>-<timestamp>\ (creates it, sets $script:PnhRunFolder)
Write-PnhLog -Message <s> [-Level Info|Warn|Error] [-Data <obj>]   # appends to run.log (UTF-8) and run.jsonl
Get-PnhText -Key <s> [-Arguments <object[]>]      # i18n lookup, fallback en, then key itself
Get-PnhLanguage                   # 'de' if (Get-UICulture).TwoLetterISOLanguageName -eq 'de', else 'en'
Start-PnhHidden -FilePath <s> -ArgumentList <s> [-Environment <hashtable>] [-WorkingDirectory <s>]
                [-TimeoutSeconds <int>] [-NoWait]
                # ProcessStartInfo: UseShellExecute=$false, CreateNoWindow=$true, stdout/stderr redirected & read async
                # -> @{ExitCode; StdOut; StdErr; TimedOut; Process}   (with -NoWait: @{Process})
ConvertTo-PnhJson -InputObject <obj>               # ConvertTo-Json -Depth 10 -Compress, UTF-8 safe
Test-PnhAdmin                     # -> [bool]
```

### 5.2 Hardware.ps1

```powershell
Get-PnhHardware   # -> @{
                  #   Gpus = @(@{Name; Vendor('nvidia'|'amd'|'intel'|'other'); VramBytes; Integrated(bool); Driver})
                  #   BestDedicatedVramBytes; RamBytes; FreeRamBytes; CpuName; Cores; LogicalCpus; Avx2(bool|null)
                  #   Os=@{Caption; Version; Build; Edition; SMode(bool)}; LanguageMode; IsAdmin
                  #   Drive=@{Letter; FileSystem; FreeBytes; Label} }
```
VRAM from the display class registry key (`HardwareInformation.qwMemorySize`, fallback `MemorySize`), matched to
`Win32_VideoController.PNPDeviceID`; `nvidia-smi` if present overrides for NVIDIA. Never `AdapterRAM` alone.

### 5.3 Models.ps1 and catalog/models.json

`models.json`:
```json
{ "schema": 1,
  "models": [
    { "id": "qwen3.5-2b", "tag": "qwen3.5:2b-q4_K_M", "bytes": 1950000000, "license": "Apache-2.0",
      "tier": 1, "minVramGB": 3, "minRamGB": 6, "ctx": 16384, "think": false,
      "freeShell": false, "default": true, "notes": "..." } ] }
```
(`bytes` are measured from the registry manifest; the builder re-measures and refuses mismatches > 1 %.)
Profiles: `"profiles": { "small": {"description": "...", "models": ["<tag>", ...], "bytes": <sum>}, "standard": {...},
"full": {...} }`.

Measured Ollama behaviour the code relies on (0.40.15): it writes `models/manifests-v2/` and `models/metadata/` at
start (the drive must be writable); after a pull the local manifest carries one extra layer (a copy of the registry
manifest) that must be ignored when comparing; it prunes partial blobs at start unless `OLLAMA_NOPRUNE=1` is set (set it
in the builder and at runtime).

```powershell
Get-PnhModelCatalog                         # -> parsed models.json
Get-PnhInstalledModels                      # -> tags present under models\manifests (no Ollama needed)
Select-PnhModel -Hardware <obj> [-Installed <string[]>] [-Prefer <tag>]
                # -> @{Model=<catalog entry>; Reason=<i18n key>; Ctx=<int>; UseGpu=<bool>; Fallbacks=@(<entries>)}
```
Rule: largest installed model whose `minVramGB` ≤ (best dedicated NVIDIA/AMD VRAM − 1.5 GB); without a usable GPU the
largest whose `minRamGB` ≤ RAM − 4 GB and `tier` ≤ 2 (CPU speed). `Fallbacks` = next smaller installed models.

### 5.4 Ollama.ps1

```powershell
Start-PnhOllama -Paths <obj> [-Port <int>] [-ContextLength <int>]
                # env per process only: OLLAMA_MODELS, OLLAMA_HOST=127.0.0.1:<free port>, OLLAMA_NO_CLOUD=1,
                # OLLAMA_CONTEXT_LENGTH, OLLAMA_FLASH_ATTENTION=1, OLLAMA_KV_CACHE_TYPE=q8_0,
                # USERPROFILE/HOME=<Home>, PATH=<runtime>\lib\ollama\vulkan;<PATH>  (VC++ runtime for CPU backends)
                # waits for GET /api/version (max 60 s) -> @{BaseUrl; Port; Process; Version}
Stop-PnhOllama -Server <obj>
Invoke-PnhChat -Server <obj> -Model <tag> -Messages <array> [-Tools <array>] [-Think <bool>] [-NumCtx <int>]
               [-TimeoutSeconds <int>]
               # POST /api/chat, stream=false, temperature 0, body as UTF-8 bytes, -UseBasicParsing
               # -> @{Content; Thinking; ToolCalls=@(@{Id; Name; Arguments(hashtable)}); Raw; DurationMs}
Get-PnhLoadedModels -Server <obj>           # GET /api/ps -> @(@{Name; Size; SizeVram})
Test-PnhModelFit -Server <obj> -Model <tag> # loads with a tiny prompt; -> @{OnGpuPercent; TokensPerSecond; Ok}
```

### 5.5 Diagnose.ps1 and toolbox/categories.json

`categories.json`: `{ "categories": [ { "id": "network", "icon": "🌐", "titleKey": "cat.network",
"diagnose": ["network","security"], "success": "check.network", "actions": ["net.*","sec.detect_isolation"] } ] }`

```powershell
Invoke-PnhDiagnose [-Sections <string[]>]    # read-only, fast (< 30 s), offline-capable
                                             # -> @{Facts=@{<section>=@{...}}; Flags=@(<finding codes>); DurationMs}
                                             # sections: system, network, security, disk, performance, printer,
                                             #           audio, update, display, events
Invoke-PnhSuccessCheck -Id <check id>        # -> @{Passed(bool); Details(hashtable); Summary(string)}
```

**Finding codes** (`toolbox/findings.json`): every flag the diagnosis can set, its meaning, the candidate action ids
(1–7) and an optional `stop` reason (e.g. Defender for Endpoint isolation → stop all network repairs, tell the user
to contact whoever manages the device). The agent is offered **only** the candidates of the flags that are set, plus
the category's read-only diagnostics. Parameters come from detection output, never invented by the model.

The toolbox runs in **Windows PowerShell 5.1 (64-bit)**: `Checkpoint-Computer` and some WinRT calls do not exist in
PowerShell 7. All other libs must work in both.

### 5.6 Toolbox.ps1 and toolbox/actions.json

Action schema:
```json
{ "id": "net.flush_dns", "category": "network",
  "title": {"de": "...", "en": "..."}, "explain": {"de": "...", "en": "..."},
  "params": {"type": "object", "properties": {}, "required": []},
  "changes": true, "admin": true, "reboot": false, "risk": "low|medium|high",
  "confirm": false, "timeoutSeconds": 60,
  "detect": "<PowerShell>", "backup": "<PowerShell or null>", "run": "<PowerShell>",
  "verify": "<PowerShell returning $true/$false>", "rollback": "<PowerShell or null>",
  "sources": ["https://learn.microsoft.com/..."] }
```
Script blocks receive `$P` (validated parameters as hashtable) and `$Backup` (path of the action's backup folder).

```powershell
Get-PnhActions [-Category <id>]              # -> catalogue entries
ConvertTo-PnhToolDefinitions -Actions <arr> -Language <de|en>   # -> Ollama "tools" array
Invoke-PnhAction -Id <s> -Parameters <hashtable> -RunFolder <s> -Confirm <scriptblock>
                 # validate → (confirm if confirm/risk>=medium/reboot) → restore point before first change
                 # → backup → run (timeout) → verify
                 # -> @{Id; Ok; Verified; Declined; Output(short); Error; RolledBack; NeedsReboot}
New-PnhRestorePoint -Description <s>         # once per run; -> @{Created; Reason}
Undo-PnhAction -Result <obj>                 # runs rollback from the stored backup
```

### 5.7 Agent.ps1

```powershell
Invoke-PnhAgent -Server <obj> -ModelEntry <obj> -Category <id> [-UserText <s>] -RunFolder <s>
                -OnEvent <scriptblock> -Confirm <scriptblock> [-MaxRounds 12] [-Language de|en] [-ReadOnly]
                # -> @{Solved(bool); Summary(string); Rounds; Actions=@(results); StoppedReason; Check; Model;
                #      Category; Seconds; Error; ReadOnly; WouldHelp}
```
Events passed to `OnEvent` (one hashtable each, `Type` decides the rest):
`step-start {Key; Text}`, `step-done {Key; Ok}`, `thinking {}`, `action {Id; Title}`, `action-result {Result}`,
`message {Text; Source='model'|'agent'}`, `done {Solved; Summary}`, `error {Text}`.
Text with `Source='model'` is the model's own wording and **unverified**; the UI shows it as such.
`Confirm` gets `@{Kind='action'|'question'|'command'; Title; Explain; Risk; Reboot; Command}` and returns `$true`/`$false`.
In `-ReadOnly` mode `Confirm` is never called; changing calls are skipped and reported under `WouldHelp`.

Stop findings: `findings.json` entries may carry `blocks` (action ids or areas they forbid) and `stopWhen` (a read-only
check action). The agent runs `stopWhen` before asking the model: positive → stop and explain; clearly negative → the
suspicion is dropped; unclear → the finding stays in force and only removes the changing actions it blocks.

Loop rules:
1. Messages: system prompt (language), then one user message with the category, the user's own words and the
   diagnosis JSON (trimmed to ~1500 tokens).
2. Tools = candidate actions of the set flags (see 5.5) + the category's read-only diagnostics + `finish(summary)` +
   `ask_user(question)` (yes/no only) + for `freeShell` models
   `run_powershell(command, why)` with a filter: read-only verbs run directly; everything else needs `Confirm`;
   deny-list always blocks (format, diskpart, bcdedit /delete, cipher /w, Remove-Item on system paths, anything
   touching Defender/firewall reset/BitLocker/isolation, registry deletes under HKLM\SYSTEM, user data deletes).
3. After each changing action: run the category success check; if passed → tell the model and ask for `finish`.
4. Stop: success check passed and finished, `MaxRounds` reached, same call twice without effect, 3 errors in a row,
   or isolation detected (`sec.detect_isolation` positive → explain, stop).
5. The final summary shown to the user is built from the verified results, the model's text is only used as wording.

### 5.8 UI ↔ background

`Ui.ps1` runs the work in one background runspace. Communication through `[System.Collections.Concurrent.ConcurrentQueue[object]]`
(events out) and a synchronized hashtable for confirmation answers; a `System.Windows.Forms.Timer` (200 ms) drains the
queue on the UI thread. The UI never blocks.

### 5.9 Builder

`builder/versions.json` pins: Ollama version, asset URL, size, sha256. Model list comes from `src/catalog/models.json`.
Profiles: `small` (tier 1–2, ~5 GB), `standard` (default, ~30 GB), `full` (all, ~62 GB). Steps: choose drive →
check exFAT/NTFS and free space → download runtime with resume and hash check → extract → copy `src\` → start Ollama
from the drive with internet and `POST /api/pull` each model (progress) → verify every blob against the manifest →
write `drive.json`, `README.txt`, licences → done. `build-drive.sh` does the same with `curl` + registry download
(manifest + blobs, sha256-verified) so it works without running Ollama.

`drive.json`: `{ "builtAt": "...", "builder": "plug-n-heal <version>", "ollama": "0.40.15", "models": [{"tag"; "bytes"}] }`

## 6. Logs and privacy

Everything a run produces stays in its run folder on the SSD: `run.log`, `run.jsonl`, `diagnose.json`, `chat.jsonl`,
`backups\`, `summary.txt`. Nothing is sent anywhere. The README tells people to delete the `logs` folder before giving
the SSD to someone else.

## 7. Testing

- Pester 5 unit tests for every lib (catalogue validation, model selection, argument validation, deny-list, JSON).
- `Run-Headless.ps1 -Category <id> -AutoConfirm -Model <tag>` drives the full flow without UI.
- CI (`windows-latest`, PS 5.1 and 7): PSScriptAnalyzer, Pester, then an end-to-end run: portable Ollama + smallest
  model on CPU, break something harmless (stop the Print Spooler), run headless `printer`, expect the success check to
  pass. Restore points cannot be created on the server runner; the code must treat that as "skipped" and log it.
