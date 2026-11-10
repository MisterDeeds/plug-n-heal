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
  prompts/system.md             the one system prompt, English for every UI language ({LANGUAGE} placeholder)
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
       ├─ S mode (SkuPolicyRequired = 1) → message error.smode + exit 23 (real S mode usually blocks cmd.exe and
       │    powershell.exe before this point; then Windows shows its own message)
       ├─ LanguageMode must be FullLanguage, else message + exit (company PC / Smart App Control)
       ├─ not elevated → relaunch itself elevated once (UAC "Yes"); if refused → continue in read-only mode
       │    (a big banner explains it; diagnostics only, every change is skipped, the result says what would help;
       │    `Invoke-PnhAgent -ReadOnly`)
       └─ start Ui.ps1 hidden (CreateNoWindow), exit → console closes
Ui.ps1
  1. Welcome: big button "Help me" / "Hilfe starten"
  2. Background runspace: Get-PnhHardware → Select-PnhModel → Start-PnhOllama → Test-PnhModelFit (may step down
     through Select-PnhModel's Candidates, each with its own num_ctx; no model fits the RAM → error.computer_too_weak)
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
      "freeShell": false, "confirmAllChanges": true, "default": true, "notes": "..." } ] }
```
(`confirmAllChanges`, optional: every changing catalogue action needs a "Yes", see 5.6 and 5.7; set for tier 1.)
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
                # -> @{Model=<catalog entry>; Reason=<i18n key>; Ctx=<int>; UseGpu=<bool>; Fallbacks=@(<entries>);
                #      Candidates=@(@{Model; Tag; UseGpu; Ctx}); Path='gpu'|'cpu'|'preferred'|'weak'|'too_weak'|'none'}
Get-PnhModelContext -ModelEntry <entry> [-UseGpu]   # -> num_ctx: catalogue ctx, capped at 16384 on the CPU
```
Rule: largest installed model whose `minVramGB` ≤ (best dedicated NVIDIA/AMD VRAM − 1.5 GB); without a usable GPU the
largest whose `minRamGB` ≤ RAM − 4 GB and `tier` ≤ 2 (CPU speed). Nothing fits: the smallest installed model whose
`minRamGB` ≤ RAM (`weak`); if RAM is known and even that does not exist, no model (`too_weak`, the window shows
`error.computer_too_weak`). `Fallbacks` = next smaller installed models. `Candidates` = the chosen model and the
fallbacks in step-down order, each with its own `UseGpu` and `Ctx` (`Get-PnhModelContext`); `Candidates[i].Model` is a
copy of the entry whose `ctx` is that value and is passed to `Test-PnhModelFit` and `Invoke-PnhAgent` as is. The context
of a fallback is sent per request (`num_ctx`); Ollama is not restarted for a step-down.

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
Test-PnhModelFit -Server <obj> -Model <tag> [-ModelEntry <entry>] [-UseGpu] [-NumCtx <int>]
                 [-MinTokensPerSecond <double>] [-MinGpuPercent <int>]
                 # loads with a tiny prompt; -> @{OnGpuPercent; TokensPerSecond; Ok; Reason; MinTokensPerSecond;
                 #                                 MinGpuPercent; ...}
```
Pass marks (`Get-PnhFitThreshold`): tokens per second by tier, 5 for tiers 1–2 (and ad-hoc models), 10 for tier 3,
15 for tier 4 (thinking). GPU tiers (3–4) chosen with `UseGpu` must also sit at least 90 % on the GPU (`size_vram / size`
from `/api/ps`), except `partialOffload` models; CPU tiers are judged by speed only.

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
Invoke-PnhAction -Id <s> -Parameters <hashtable> -RunFolder <s> -Confirm <scriptblock> [-ForceConfirm]
                 # validate → (confirm if confirm/risk>=medium/reboot/deletes; with -ForceConfirm every change)
                 # → restore point before first change
                 # → backup → run (timeout) → verify
                 # -> @{Id; Ok; Verified; Declined; Output(short); Error; RolledBack; NeedsReboot}
New-PnhRestorePoint -Description <s>         # once per run; -> @{Created; Reason}
Undo-PnhAction -Result <obj>                 # runs rollback from the stored backup
```

### 5.7 Agent.ps1

```powershell
Invoke-PnhAgent -Server <obj> -ModelEntry <obj> -Category <id> [-UserText <s>] -RunFolder <s>
                -OnEvent <scriptblock> -Confirm <scriptblock> [-MaxRounds 30] [-MaxMinutes 30] [-Language de|en]
                [-ReadOnly]
                # -> @{Solved(bool); Summary(string); Rounds; Actions=@(results); StoppedReason; Check; Model;
                #      Category; Seconds; Error; ReadOnly; WouldHelp; Nudges; Rediagnoses; Compactions;
                #      Tried=@(@{Name; Args; Outcome; Round})}
```
`StoppedReason`: `solved`, `finished` (the model called `finish`), `exhausted` (every candidate was tried and the model
brought nothing new), `max-rounds`, `time-limit`, `errors` (3 failed model requests in a row), `cancelled`, `isolation`,
`stop-finding`, `error`. `Nudges`, `Rediagnoses` and `Compactions` count what loop rules 5, 3 and 7 did; `Tried` has one
entry per attempted change.

Events passed to `OnEvent` (one hashtable each, `Type` decides the rest):
`step-start {Key; Text}`, `step-done {Key; Ok}`, `thinking {Round}`, `action {Id; Title}`, `action-result {Result}`,
`message {Text; Source='model'|'agent'}`, `done {Solved; Summary}`, `error {Text}`.
Text with `Source='model'` is the model's own wording and **unverified**; the UI shows it as such.
Text with `Source='agent'` is the harness speaking to the person in their language (i18n keys `agent.keepgoing`,
`agent.keepgoing.last`, `agent.rediagnose`, `event.action_readonly`): it is sent with every nudge and after every change
that did not fix the problem ("I keep going. Next I try: ..."), so the person always sees what happens next.
`OnEvent` may throw `PNH_CANCELLED` (the window does when the person cancels): the loop stops with `cancelled` and
starts nothing any more, also not the action it was about to run.
`Confirm` gets `@{Kind='action'|'question'|'command'; Title; Explain; Risk; Reboot; Command}` and returns `$true`/`$false`.
In `-ReadOnly` mode `Confirm` is never called; changing calls are skipped and reported under `WouldHelp`.
`ModelEntry.ctx` is the `num_ctx` of every request (`Server.ContextLength` only when it is missing), so a fallback keeps
its own context length. For entries with `confirmAllChanges = true` (or `tier` 1) every catalogue action is run with
`Invoke-PnhAction -ForceConfirm`: each change asks first, whatever the action's own rule says.

**The model is instructed in English, whatever language the person reads.** `prompts/system.md` is the one system
prompt; `{LANGUAGE}` becomes `English` or `German (address the person formally with "Sie")`. The first user message,
the tool descriptions, the findings, every tool result and every nudge are English too. Only what the model writes for
the person (the `finish` summary, `ask_user` questions, the reason for a command) is asked for in the person's language,
in plain words without Markdown or emoji. Small models follow English instructions best.

Stop findings: `findings.json` entries may carry `blocks` (action ids or areas they forbid) and `stopWhen` (a read-only
check action). The agent runs `stopWhen` before asking the model: positive → stop and explain; clearly negative → the
suspicion is dropped; unclear → the finding stays in force and only removes the changing actions it blocks. A stop
finding that first shows up when the diagnosis is run again (loop rule 3) is measured in the same way and is never
lifted again during the run.

Loop rules:
1. Messages: the system prompt, then one user message with the topic, the user's own words, the state of the success
   check, the findings (strongest first), the diagnosis JSON (trimmed to ~1500 tokens), the candidate repairs (most
   promising first), the look-only tools and the task.
2. Tools = candidate actions of the set flags that were not tried yet (see 5.5) + the category's read-only diagnostics
   + `finish(summary)` + `ask_user(question)` (yes/no only) + for `freeShell` models
   `run_powershell(command, why)` with a filter: read-only verbs run directly; everything else needs `Confirm`;
   deny-list always blocks (format, diskpart, bcdedit /delete, cipher /w, Remove-Item on system paths, anything
   touching Defender/firewall reset/BitLocker/isolation, registry deletes under HKLM\SYSTEM, user data deletes).
3. After every changing action or command, also one that reports a failure, the harness runs the category success
   check itself and puts the result into the tool result: `Success check: Passed|Failed. <summary of the check>`
   followed by the next step (`Untried candidates: <names>. Call the most promising one now.`). Passed → the model is
   told to call `finish`. The action's own verify passed but the check still fails → the diagnosis is run again: new
   findings bring their candidates into the tool set, and the tool result names what is new and what is gone.
4. Tried changes are tracked by tool and parameters. A change is never run twice with the same values; an action
   without parameters leaves the tool set once it was tried (run, failed, refused or skipped), so only untried
   candidates are offered. Read-only looks never count as tried; the same look is answered from memory until a change
   was made. One change per model answer.
5. Persistence. A model turn without a tool call (text only, an empty answer, a failed request), or `finish` while the
   check fails and untried candidates are left, gets the nudge
   `The check still fails: <summary of the check>. Untried candidates: <names>. Call the most promising one now.`
   and the loop goes on. Such a `finish` is refused at most twice (`Do not finish yet. ...`); the third one is accepted
   and the run is reported as not solved. The harness does not push in read-only mode or while a stop finding is in
   force.
6. The loop stops only when: the success check passed (the model then only supplies the wording); every candidate was
   tried and the model finishes (`finished`) or two turns in a row bring nothing new (`exhausted`); isolation or
   another measured stop finding (`sec.detect_isolation` positive → explain, stop); a stop finding is in force or the
   run is read-only and the model finishes or has nothing new; the person cancels; or a hard limit is reached:
   `MaxRounds` model rounds (default 30), `MaxMinutes` of wall-clock time (default 30, checked before every round; the
   timeout of a request is cut to the time that is left, at least 30 s), 3 failed model requests in a row.
7. Compaction. Before a request, when system prompt + tool definitions + messages exceed ~70 % of `num_ctx` (estimate:
   4 characters per token), the conversation is cut down to the system prompt, the first user message (the facts) and
   a summary written by the harness: what was tried and how it ended, what was looked at, the current findings, the
   current state of the success check and the next step.
8. The final summary shown to the user is built from the verified results, the model's text is only used as wording.
   Words of a refused `finish` and words from before the last change are dropped.

Nudges, refused finishes, diagnosis re-runs and compactions are written to `run.jsonl` (`Nudge`, `Finish refused`,
`Diagnosis re-run`, `Conversation compacted`, `Tried: <tool>`); compactions also to `chat.jsonl`.

### 5.8 UI ↔ background

`Ui.ps1` runs the work in one background runspace. Communication through `[System.Collections.Concurrent.ConcurrentQueue[object]]`
(events out) and a synchronized hashtable for confirmation answers; a `System.Windows.Forms.Timer` (200 ms) drains the
queue on the UI thread. The UI never blocks. A `message` with `Source='agent'` becomes the big sentence of the working
page, stays there while the model thinks and is added to the list below it; text with `Source='model'` only goes to that
list, marked as not checked.

### 5.9 Builder

`builder/versions.json` pins: Ollama version, asset URL, size, sha256. Model list comes from `src/catalog/models.json`.
Profiles (model bytes / on the drive incl. unpacked runtime and 512 MiB reserve / suggested SSD): `small` (tier 1–2,
5.3 GB / 8.1 GB / 16 GB), `standard` (default, 29.6 GB / 32.4 GB / 64 GB), `full` (all, 62.6 GB / 65.4 GB / 128 GB).
The wizard computes these from `models.json` and `versions.json` (`Get-PnhProfileOption`). Steps: choose drive →
check exFAT/NTFS and free space → download runtime with resume and hash check → extract → copy `src\` → remove the
Mark-of-the-Web from `PlugNHeal\` and `START.cmd` (`Unblock-File`, best effort; exFAT has no streams) → start Ollama
from the drive with internet and `POST /api/pull` each model (progress) → verify every blob against the manifest →
write `drive.json`, `README.txt`, licences → done. `build-drive.sh` does the same with `curl` + registry download
(manifest + blobs, sha256-verified) so it works without running Ollama.

`drive.json`: `{ "builtAt": "...", "builder": "plug-n-heal <version>", "ollama": "0.40.15", "profile": "standard",
"models": [{"id"; "tag"; "bytes"}] }` (both builders write the same shape).

## 6. Logs and privacy

Everything a run produces stays in its run folder on the SSD: `run.log`, `run.jsonl`, `diagnose.json`, `chat.jsonl`,
`backups\`, `summary.txt`. Nothing is sent anywhere. The README tells people to delete the `logs` folder before giving
the SSD to someone else.

## 7. Testing

- Pester 5 unit tests for every lib (catalogue validation, model selection, argument validation, deny-list, JSON).
- `Run-Headless.ps1 -Category <id> -AutoConfirm -Model <tag>` drives the full flow without UI (`-MaxRounds` and
  `-MaxMinutes` are passed on to the agent; with `-Json` the result also carries `nudges`, `rediagnoses`, `compactions`
  and `tried`).
- CI (`windows-latest`, PS 5.1 and 7): PSScriptAnalyzer, Pester, then an end-to-end run: portable Ollama + smallest
  model on CPU, break something harmless (stop the Print Spooler), run headless `printer`, expect the success check to
  pass. Restore points cannot be created on the server runner; the code must treat that as "skipped" and log it.
