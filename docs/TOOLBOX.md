# Toolbox: the action catalogue

This document explains how Plug'n'Heal repairs things: which actions exist, how they are described, how the engine
runs them, and the rules every action has to follow. The binding contract is `docs/ARCHITECTURE.md` (sections 2, 5.5,
5.6, 5.7). The research behind the catalogue (German, with sources) is `docs/research/werkzeugkasten.md`.

Status: version 0.1. Every PowerShell block in the catalogue has been checked with the PowerShell parser and the engine
has unit tests, but **no action has run on a real Windows PC yet** (see "What still needs real Windows").

## 1. The idea in short

| Role | Does | Must not |
|---|---|---|
| Diagnosis (`Invoke-PnhDiagnose`) | measures read-only in under 30 s, returns facts and finding codes | change anything |
| Model | explains, picks ONE action from the offered candidates, picks parameter values from detection | write commands, invent values |
| Engine (`Invoke-PnhAction`) | validates, asks the user, makes a restore point, backs up, runs, verifies, logs | change without backup or without asking when the rules say so |
| Success check (`Invoke-PnhSuccessCheck`) | decides with a script whether the problem is solved | trust the model |
| User | confirms, gives knowledge (Wi-Fi password, the correct time), follows guides | - |

The model never sees all actions. A finding code (for example `PRINT_JOBS_STUCK`) names one to seven candidate actions;
only the candidates of the codes that are set, plus the read-only diagnostics of the chosen category, become tools.

## 2. Files

| File | Content |
|---|---|
| `src/toolbox/actions.json` | the catalogue: one entry per action (schema below) |
| `src/toolbox/findings.json` | finding codes: meaning, severity, candidate actions, optional stop text and blocks |
| `src/toolbox/categories.json` | the problem categories of the UI: diagnosis sections, success check, action scope |
| `src/toolbox/helpers.ps1` | tested helper functions that catalogue scripts may call |
| `src/lib/Toolbox.ps1` | the engine: catalogue access, tool definitions, `Invoke-PnhAction`, `Undo-PnhAction`, `New-PnhRestorePoint`, `Test-PnhCommandDenied` |
| `src/lib/Diagnose.ps1` | `Invoke-PnhDiagnose`, finding rules, `Invoke-PnhSuccessCheck` |
| `tests/Catalog.Tests.ps1` | schema and safety tests of the three JSON files |
| `tests/Toolbox.Tests.ps1`, `tests/Diagnose.Tests.ps1` | engine and diagnosis tests |

**Encoding.** Every `.ps1` file is either ASCII-only or UTF-8 **with BOM**: Windows PowerShell 5.1 reads BOM-less files
as ANSI and would garble any non-ASCII character (the CI lint job enforces this rule). Files that contain German text,
such as `src/lib/Agent.ps1`, carry the BOM; the others are plain ASCII. Every PowerShell block inside `actions.json` is
ASCII-only (a test enforces this). The JSON files are UTF-8 without BOM (RFC 8259) and are read with an explicit UTF-8
decoder (`[IO.File]::ReadAllText(..., UTF8)`), never with `Get-Content` without `-Encoding`.

## 3. Action schema (`actions.json`)

```json
{ "schema": 1, "catalogDate": "2026-11-09", "actions": [ {
  "id": "net.flush_dns",            "category": "network",   "area": "net",   "kind": "repair",
  "title":   { "de": "...", "en": "..." },
  "explain": { "de": "...", "en": "..." },
  "params":  { "type": "object", "properties": {}, "required": [], "additionalProperties": false },
  "changes": true, "admin": true, "reboot": false, "risk": "low", "confirm": false, "deletes": false,
  "context": "system", "offline": "yes", "core": true, "experimental": false, "timeoutSeconds": 60,
  "detect": "<PowerShell or null>", "backup": "<PowerShell or null>", "run": "<PowerShell>",
  "verify": "<PowerShell returning exactly $true/$false>", "verifyAfterReboot": false,
  "rollback": "<PowerShell or null>",
  "sources": ["https://learn.microsoft.com/..."] } ] }
```

| Field | Meaning |
|---|---|
| `id` | `<area>.<name>`, lower case. Also the tool name the model sees. |
| `category` | primary UI category: network, slow, disk, printer, sound, update, display, other |
| `area` | technical area from the research draft (`net`, `wifi`, `sec`, `wu`, `disk`, `fs`, `boot`, `print`, `audio`, `display`, `hw`, `time`, `defender`, `sysfile`, `shell`, `apps`, `profile`, `bitlocker`, `events`, `sys`) |
| `kind` | `diagnose` (read-only), `repair`, `backup`, `guide` (instructions for the user) |
| `title`, `explain` | plain language, German (Sie-form, Swiss spelling: no sharp s) and English; shown in confirmation dialogs and used as tool description |
| `params` | JSON-schema subset, see section 4 |
| `changes` | the action changes the system. Changing actions get confirmation rules, a restore point, a backup folder, verification and rollback. |
| `admin` | needs administrator rights (Plug'n'Heal normally runs elevated) |
| `reboot` | needs or causes a restart |
| `risk` | `low`, `medium`, `high` |
| `confirm` | always ask the user first (see the confirmation rule) |
| `deletes` | deletes or moves data or settings away from the PC |
| `context` | `user`: changes the signed-in user's settings (HKCU, sound, Explorer). Refused when Plug'n'Heal runs under another administrator account (finding `ELEVATED_OTHER_USER`). |
| `offline` | `yes` or `partial` (works offline, the effect only shows with internet). Actions that need internet are not shipped. |
| `core` | part of the version 1 core set (20 actions) |
| `experimental` | relies on undocumented or unconfirmed behaviour; never offered to the model and refused by `Invoke-PnhAction` unless `-AllowExperimental`. `experimentalReason` says why. |
| `timeoutSeconds` | limit for each script phase (backup, run, rollback; verify gets at least 60 s) |
| `detect` | read-only script that lists what the action could act on; used for parameter choices |
| `detectFrom` | instead of `detect`, another read-only action provides the list (for example `boot.startup_list`) |
| `backup` | script that saves the old state into `$Backup` before `run`. If it throws, `run` never starts. |
| `backupNote` | required when a changing action has no `backup`: why none is needed (English) |
| `run` | the change itself (for diagnostics: the measurement). Its output becomes `Data` and `Output` of the result. |
| `verify` | script whose **last output is exactly `[bool]`**; anything else counts as not verified. Read-only actions use `$true`. |
| `verifyAfterReboot` | verification only makes sense after a restart; the result is `Ok = $true, Verified = $false, NeedsReboot = $true` |
| `rollback` | script that restores the old state from `$Backup` |
| `rollbackNote` | required when a changing action has no `rollback`: why (some are deliberate, e.g. never switch the firewall off again) |
| `skipRestorePoint` | no automatic restore point before this action (the restore point actions themselves) |
| `guide` | for `kind = guide`: `{de, en, question: {de, en}}`; `{Name}` placeholders are filled from the run output |
| `stopWhen` | `{property, finding}`: when the run output has `property = $true`, the result carries `Stop` with that finding's stop text (used by `sec.detect_isolation`) |
| `sources` | documentation the action follows (mostly Microsoft Learn / Support) |

### Variables available to catalogue scripts

Scripts run in the same runspace as the engine through `[scriptblock]::Create` with `$ErrorActionPreference = 'Stop'`
(non-terminating errors fail the step) and receive:

| Variable | Content |
|---|---|
| `$P` | validated parameters (hashtable) |
| `$Backup` | the action's own new folder `<run>\backups\<yyyyMMdd-HHmmss>-<nn>-<id>` on the rescue drive |
| `$PnhRoot` | drive root `X:\PlugNHeal` (never cleaned; packages under `packages\`, Windows images under `sources\`) |
| `$PnhStart` | `[datetime]` start of the action (for checks like "restarted since") |
| `$PnhBuildDate` | `[datetime]` build date of the drive (`drive.json`), used to recognize a clock that is certainly wrong |
| `$PnhRunFolder` | the run folder (earlier runs are its siblings; `Find-PnhLatestBackup` searches them after a restart) |
| `$PnhLanguage` | `de` or `en` |

## 4. Parameters

`params` is a JSON-schema subset that `Test-PnhParameters` enforces: `type` (string, integer, number, boolean), `enum`,
`pattern` (.NET regex, anchored), `required`, `maxLength`, `minimum`, `maximum`, no unknown properties, and no control
characters or quotes in strings. Integer strings like `"3"` are accepted and converted (small models often quote numbers);
enum values are matched case-insensitively and normalized.

Two extensions:

| Key | Meaning |
|---|---|
| `x-setBy` | `model`: the model may set it (from detection output). `user`: only the user can give it (e.g. the correct time); such actions are not offered to the model. |
| `x-choices` | `{from: "detect" or <action id>, property, filter}`: the allowed values are this property of the rows the detection returns (after the equality filter). |

Parameter values must come from detection, never from the model's imagination. This is enforced twice:

1. `ConvertTo-PnhToolDefinitions` runs the detection (on Windows, unless `-Choices` or `-NoChoices` is given) and puts the
   found values into `enum`. When a required parameter has no values (nothing to act on), the action is not offered.
2. `Invoke-PnhAction` runs the detection again and refuses any value it does not find.

## 5. How `Invoke-PnhAction` runs an action

```
Invoke-PnhAction -Id <id> -Parameters <hashtable> -RunFolder <dir> -Confirm <scriptblock>
                 [-Language de|en] [-Flags <codes>] [-AllowExperimental] [-SkipChoiceCheck] [-ForceConfirm]
                 [-Action <entry>]
```

1. Look up the action; refuse experimental actions without `-AllowExperimental`.
2. Validate the parameters (section 4).
3. Refuse a changing action that a set stop finding blocks (`-Flags`; the agent applies the same blocks itself).
4. Refuse when administrator rights are missing, or when a `context = user` change would run under another account.
5. Check parameter values against the detection.
6. **Confirmation rule** (`Test-PnhConfirmRequired`): ask when `confirm = true` OR `risk` is medium/high OR `reboot`
   OR `deletes`; with `-ForceConfirm` also for every action with `changes = true`. The agent sets `-ForceConfirm` for
   models with `confirmAllChanges` (the tier-1 model, whose tool use is weak). It only adds questions. The `Confirm`
   scriptblock gets `@{Id; Title; Explain; Risk; Reboot; Deletes; Parameters}` and must return exactly `$true`. Anything
   else, an exception, or a missing scriptblock means "declined": nothing runs, `Declined = $true`.
7. Before the **first changing action of a run**: `New-PnhRestorePoint` (once per run folder; later calls reuse the
   result). When no point can be made, it logs "Restore point skipped: <reason>" and the action continues.
8. Create the backup folder, write `request.json`, run `backup`. A failing backup ends the action: nothing changed.
9. Run `run` with the timeout. If it throws, the rollback runs automatically (`RolledBack = $true`).
10. Run `verify`; `Ok` is the verification result (for `verifyAfterReboot`: `Ok = $true`, `NeedsReboot = $true`).
11. Write `result.json` into the backup folder and log through `Write-PnhLog`.

Result: `[pscustomobject]@{ Id; Ok; Verified; Declined; Output; Error; RolledBack; NeedsReboot; Data; Stop; Title;
Changes; Parameters; BackupPath; RestorePoint; DurationMs }`. `Output` is a short text (compact JSON, max 1500
characters); `Data` is the structured object the run returned (for guides `{Guide; Question; Values}`); `Stop` is set
by `stopWhen`.

**Timeouts.** Scripts run in the engine's runspace, so in-process cmdlets cannot be interrupted; they are only reported
when late. Every external program must be started with `Invoke-PnhNative`, which kills the program (and its children)
when the action's deadline passes and then throws. A verify that is not exactly `$true` is a failure.

**Rollback later.** `Undo-PnhAction -Result <result or result.json>` runs the rollback with the stored parameters and
backup folder, also in a later run (for example after a restart). A verify that returns `$false` does **not** roll back
automatically: the change may still be partly useful, and the agent or the user decides.

**Restore point reasons** (`New-PnhRestorePoint` -> `@{Created; Reason; Detail; Sequence; Time}`): `created`,
`not-windows`, `not-admin`, `server-os` (no System Restore, e.g. the CI runner), `frequency-limit` (Windows allows one
point per 24 hours; the existing point is used), `system-protection-disabled`, `not-created`, `error`. It uses CIM
(`root/default:SystemRestore`) and therefore works in PowerShell 5.1 and 7.

## 6. Other engine functions

| Function | Purpose |
|---|---|
| `Get-PnhActions [-Category <id>]` | catalogue entries; with a category only those in its scope (`actions` patterns of categories.json; `all` = everything) |
| `Get-PnhAction -Id` | one entry |
| `Get-PnhCategoryCatalog`, `Get-PnhFindingCatalog` | parsed categories.json, findings.json (hashtable code -> entry) |
| `Get-PnhCandidateActions -Flags -Category` | candidates of the set flags (in finding order) plus the category's read-only diagnostics (for `all` only the core ones); without experimental and blocked actions; also returns `Stops` and `Blocked` |
| `ConvertTo-PnhToolDefinitions -Actions -Language [-Choices] [-NoChoices] [-IncludeExperimental]` | Ollama `tools` array (write it with `@()`); name = action id; description = title + explanation + "asks first" / "restarts"; only `x-setBy = model` parameters |
| `Resolve-PnhToolName -Name` | maps a model's tool name back to an id (`net_flush_dns` -> `net.flush_dns`) |
| `Get-PnhParameterChoices -Action` | runs the detection and returns allowed parameter values |
| `Test-PnhParameters -Action -Parameters` | validation only |
| `Test-PnhConfirmRequired -Action`, `Test-PnhActionBlocked -Action -Flags` | the two rules as functions |
| `Test-PnhCommandDenied -Command [-Detailed]` | deny-list for free PowerShell (section 9) |

## 7. Diagnosis and success checks

`Invoke-PnhDiagnose [-Sections <...>]` returns `@{Facts = @{<section> = @{...}}; Flags = @(<codes>); DurationMs; Errors}`.
Sections: `system` (always runs: rights, OS, pending restart, managed device, time, profile, restore points, stopped
core services, problem devices, broken Store apps), `network` (adapters, gateway, the tests `lo/gw/ext/dns/tcp` as codes,
proxy, hosts, VPN, split routes, NRPT, foreign Winsock providers and NDIS filters, radios), `security` (Defender, other
antivirus, threats, firewall profiles, Defender for Endpoint hints, BitLocker status, never keys), `disk`,
`performance`, `printer`, `audio`, `update`, `display`, `events`. Keys are short to keep the output small. Every probe runs
in its own try/catch; failures are listed under `Errors` and never stop the diagnosis. Sections that would start after
25 s are skipped. Ping results are evaluated by number (11050 = `GENERAL_FAILURE`, which .NET does not know), TCP
errors by socket code (10013 = `BLOCKED_LOCAL`).

Finding codes are computed by the pure function `Get-PnhDiagnoseFlags -Facts`, so every rule is unit-tested without
Windows. Thresholds: low disk space = under 10 GB free, or under 10 % while under 30 GB free; critical = under 2 GB;
long uptime = over 168 hours; a WHEA finding only for fatal hardware errors (corrected ones are common noise).

`Invoke-PnhSuccessCheck -Id <check id>` returns `@{Passed (bool); Details; Summary (English)}`; a probe that fails gives
`Passed = $false`, never an exception:

| Check | Passed when |
|---|---|
| `check.network` | gateway answers ping (or ignores ping while TCP works) AND TCP 443 to 1.1.1.1 (fallback 8.8.8.8) connects AND `www.msftconnecttest.com` resolves |
| `check.printer` | spooler running AND no print job with error/offline/paper/blocked/user-intervention status or older than 2 hours (`Win32_PrintJob.StatusMask`) |
| `check.disk` | system drive not low (thresholds above) |
| `check.sound` | Audiosrv and AudioEndpointBuilder running AND a working audio endpoint AND not muted AND volume at least 5 % (volume ignored when Core Audio is unavailable) |
| `check.update` | wuauserv and BITS not disabled AND CryptSvc running AND no pending restart (whether updates download can only be seen online) |
| `check.display` | a graphics adapter without problem code AND not only the basic display driver |
| `check.slow` | restarted within 7 days AND no pending restart AND disk space not low |
| `check.other` | core services (EventLog, Winmgmt, ProfSvc, Dnscache, CryptSvc, BFE) running AND temp folder exists AND no temporary profile AND Explorer running |
| `check.all` | network, disk, update and other pass; printer, sound and display are only reported in `Details` |

## 8. Findings and categories

`findings.json`: `{code, severity, meaning {de,en}, candidates [ids, at most 7], stop {de,en} or null, blocks [patterns]}`.
Severity: 1 stop or critical, 2 broken function (likely cause), 3 contributing condition, 4 information.
A finding with `stop` explains to the user why repairs are limited; its `blocks` say which **changing** actions are
not allowed while it is set: wildcard ids (`net.*`), `@reboot` (every action with a restart). A stop always has blocks
(the agent treats a stop without blocks as "block everything"). Read-only actions are never blocked.

| Stop finding | Blocks |
|---|---|
| `MANAGED_DEVICE` (domain, Entra ID, MDM) | `net.*`, `wifi.forget_profile`, `wu.*`, `time.*` |
| `MDE_ISOLATION_SUSPECT` | `net.*`, `wifi.*`; `sec.detect_isolation` is run first; positive = stop and tell the user to contact their IT |
| `DISK_UNHEALTHY` | `@reboot`, `fs.*`, `sysfile.*`, `disk.move_crash_dumps` (back up data first) |
| `WHEA_ERRORS` (fatal) | `@reboot`, `sysfile.*`, `fs.*`, `hw.*` |

`categories.json`: `{id, icon, titleKey ("cat.<id>"), diagnose [sections], success (check id), actions [patterns]}` for
`network, slow, disk, printer, sound, update, display, other, all`. `actions` is the scope: candidates outside it are
not offered (except in `all`).

## 9. Safety rules

1. **Never fight security.** No action disables, weakens or bypasses Defender, the firewall, SmartScreen, UAC,
   BitLocker or device isolation. Defender actions only raise protection (`Set-MpPreference` only with
   `-Disable...:$false`); `net.firewall_enable` has deliberately no rollback; the BitLocker actions only read the
   status and never the recovery key. Defender-for-Endpoint isolation is detected and explained, never lifted.
2. **Measure first.** Read-only diagnosis before any change; parameters only from detection output.
3. **One change, then verify.** A script decides success; the model's "fixed" means nothing.
4. **Reversible or confirmed.** Every changing action has a backup or a documented reason and a rollback or a
   documented reason. Restore point before the first change of a run.
5. **Delete only clearly temporary data, always with confirmation.** The deleting actions are exactly:
   `disk.clean_user_temp`, `disk.clean_windows_temp` (files older than 7 days in temp folders; full list kept,
   links never followed, the rescue drive refused), `disk.clean_delivery_optimization` (documented cmdlet),
   `disk.move_crash_dumps` and `print.clear_queue` (moved to the rescue drive, can be moved back),
   `wifi.forget_profile` (the profile is exported first, with the key encrypted for this machine only, and can be
   re-imported). A test fails when this list changes.
6. **Managed devices are read-only for network, proxy, DNS, time and update settings** (finding `MANAGED_DEVICE`;
   several actions also refuse on their own).
7. **No localized text is parsed.** Only exit codes, objects, registry values, XML, GUIDs and event data fields.
8. **Experimental means never automatic.**

### Deny-list for free PowerShell (`Test-PnhCommandDenied`)

Large models may propose their own PowerShell (`run_powershell` in the agent). `Test-PnhCommandDenied -Command <s>`
returns `$true` when the command must never run, whatever the user answers (`-Detailed` returns `{Denied; Rule;
Reason}`). Rules (checked on three normalized variants of the text: lower case without backticks, carets and quotes;
with `+` concatenations joined; with `-ArgumentList`/`-FilePath`, brackets and commas removed, so
`Start-Process netsh -ArgumentList 'advfirewall reset'` is caught; plus an AST pass):

| Rule | Blocks |
|---|---|
| `dynamic-code` | `Invoke-Expression`/`iex`, `-EncodedCommand`, `FromBase64String`, `Add-Type`, `[scriptblock]::Create`, `& $variable` and other commands built at run time |
| `defender` | `Add-/Remove-MpPreference`, `Set-MpPreference` with anything but `-Disable...:$false`, Defender removal, writes to Defender, Defender-for-Endpoint, SmartScreen, firewall-policy or UAC registry keys |
| `security-service` | stopping or disabling WinDefend, Sense, WdFilter, mpssvc, BFE, wscsvc, SecurityHealthService and related processes |
| `firewall` | `netsh advfirewall reset/import`, turning profiles off, allowing inbound by default, adding/removing/disabling rules |
| `bitlocker` | any BitLocker change (`Disable/Suspend/...-BitLocker`, key protectors, `manage-bde` except `-status`), and anything that can reveal the recovery key (`Get-BitLockerVolume`, `RecoveryPassword`, `KeyProtector`) |
| `isolation` | disabling network bindings/filters (`Disable-NetAdapterBinding`, `netcfg -u`, `fltmc unload`, `netsh wfp set/add/delete`) |
| `disk-destroy` | `format`, `Format-Volume`, `diskpart`, partition and disk cmdlets, `bcdedit` except `/enum`, `bcdboot`/`bootrec`, `cipher /w`, `sdelete`, `chkdsk /r /b /x`, `fsutil` except `dirty query/set`, `fsinfo` |
| `backups` | deleting or shrinking shadow copies and restore points (`vssadmin delete/resize`, `wmic shadowcopy delete`, `Disable-ComputerRestore`, `wbadmin delete`) |
| `user-data` | `Clear-RecycleBin`, deleting user profiles, removing or resetting apps, clearing event logs or audit policy, `robocopy /mir /purge /move`, .NET file deletes |
| `accounts` | creating, changing or deleting accounts, passwords and group memberships |
| `policy` | `Set-ExecutionPolicy` beyond `-Scope Process`, AppLocker / App Control changes |
| `credential-protection` | writes to LSA / Credential Guard settings |
| `registry-system` | any delete under `HKLM\SYSTEM`, `HKLM\SAM`, `HKLM\SECURITY` |
| `delete` | `Remove-Item` and aliases, `Clear-Content`, `cmd /c del/rd` unless every path is clearly a temp folder (`$env:TEMP`, `$env:TMP`, `[IO.Path]::GetTempPath()`, `C:\Windows\Temp`, `...\AppData\Local\Temp`, no `..`); also delete commands hidden in strings |
| `unparsable` | anything the PowerShell parser rejects |

It is a last line of defence, not a sandbox: read-only versus changing commands, and asking the user, are decided by the
agent. The catalogue itself is reviewed code; `tests/Catalog.Tests.ps1` runs every catalogue script through the
deny-list and allows exactly five reviewed exceptions (a grow-only `vssadmin resize`, a Base64 registry restore, an
`fsutil dirty set` written as an argument array, two BitLocker reads that select only type and ID).

## 10. Adding an action safely

1. Write it down first: what problem, which finding code, which Microsoft documentation. If it needs internet, if it
   weakens a security feature, or if it deletes anything that is not clearly temporary, it does not belong here.
2. Pick `id` (`<area>.<name>`), `category`, `kind`. Write `title` and `explain` in plain words, German in Sie-form with
   Swiss spelling, English; at most two short sentences; say what changes and whether it can be undone.
3. `detect`: read-only, lists what the action could act on, with the property names your parameters use in
   `x-choices`. Parameters get a `pattern` or `enum` (free strings are rejected by the tests).
4. `backup`: save exactly what `run` changes into `$Backup` (`Write-PnhStateJson`, `Save-PnhRegKey`, `Copy-Item`,
   `Backup-PnhIpConfig`). No backup possible? Write `backupNote`.
5. `run`: one change. Start external programs only with `Invoke-PnhNative` (exit codes only, timeout-aware). Never
   evaluate console text. Throw on failure.
6. `verify`: the last output must be `[bool]`. Check the effect, not that the command ran.
7. `rollback` from `$Backup`, or `rollbackNote` explaining why not.
8. Set `risk`, `admin`, `reboot`, `deletes`, `context`, `offline`, `timeoutSeconds`; `confirm` must be true for
   deletes / reboot / medium / high. Mark `experimental` when anything is undocumented or unconfirmed.
9. Add the id to a finding's `candidates` (at most 7 per finding) and make sure a category's `actions` pattern
   covers it.
10. Keep every script ASCII-only and Windows PowerShell 5.1 compatible (no `??`, `?.`, `&&`, `-AsHashtable`,
    `-Parallel`).
11. Run the tests (`tests/Catalog.Tests.ps1` checks schema, confirmation rule, backups/rollbacks, parser, PS7-only syntax,
    helper names, declared parameters, the deny-list and the list of deleting actions). Then run the action on a
    test PC in German and English Windows.

## 11. What still needs real Windows

Everything that touches the system has only been parsed and unit-tested with test actions on Linux. Before release:

- Run every catalogue action on Windows 10 22H2 and Windows 11 24H2/25H2, German and English, with and without
  administrator rights; one PC with BitLocker, one with third-party antivirus, one onboarded to Defender for Endpoint
  (trigger isolation in a test tenant and confirm the hints in `sec.detect_isolation`).
- Confirm the experimental actions (see the list) and then remove the flag: SPP registry value for System Protection,
  restore point type 6 after a restore, WFP XML paths, `auditpol /backup` CSV columns, Diagnostics-Performance event
  fields, writing `Win32_Printer.WorkOffline`, StartupApproved, Start-menu re-registration.
- Measure the diagnosis time on slow PCs (target under 30 s), the restore point behaviour (24-hour limit, server, off),
  the Core Audio helper under Constrained Language Mode, WinRT radios, `Invoke-PnhNative` kill on timeout.
- `defender.update_from_ssd` needs `<root>\packages\defender\mpam-fe.exe` and `sysfile.dism_restorehealth_ssd` needs
  `<root>\sources\...\install.wim|esd`; the builder does not provide them yet, so both actions currently find nothing.
- `time.set_manual` needs a UI field for the correct time (`x-setBy = user`); until then it is never offered.

## 12. Not in the catalogue, on purpose

Switching off or weakening Defender, tamper protection, SmartScreen or the firewall; `netsh advfirewall reset`;
"Network reset" in Settings; lifting or bypassing Defender-for-Endpoint isolation, deleting WFP filters or NDIS filters;
suspending, decrypting or reading BitLocker keys; `DISM /ResetBase`; emptying the Recycle Bin, Downloads, Windows.old or
restore points; `Reset-AppxPackage` and re-registering all apps of all users; deleting user profiles; `chkdsk /r` or a
boot-time check on a failing disk; installing or rolling back drivers; enabling a deliberately disabled print spooler;
registry cleaners and "tuning" scripts; changing the execution policy permanently; accounts and passwords; MSDT
troubleshooters (removed by Microsoft); disabling scheduled tasks and services at start-up; repairing the component store
via Windows Update (`sysfile.dism_restorehealth_online`, needs internet). Reasons: `docs/research/werkzeugkasten.md`,
section 6.

## 13. Catalogue

`core` = version 1 core set, `exp.` = experimental (never offered automatically). Admin / restart / confirm / deletes as
in the catalogue.

92 actions: 31 read-only (diagnoses and guides), 61 changing; 20 core, 8 experimental.

### network (26)

| ID | Title | Kind | Risk | Admin | Restart | Confirm | Deletes | Rollback | Flags |
|---|---|---|---|---|---|---|---|---|---|
| `net.test_connectivity` | Check the internet connection | diagnose | low | - | - | - | - | n/a | core |
| `net.triage_general_failure` | Narrow down a network failure | diagnose | low | - | - | - | - | n/a | core |
| `net.enable_adapter` | Turn a disabled network adapter back on | repair | low | yes | - | - | - | yes | core |
| `net.restart_adapter` | Restart the network adapter | repair | low | yes | - | - | - | - | core |
| `net.renew_dhcp` | Get a new IP address from the router | repair | low | yes | - | - | - | - | core |
| `net.flush_dns` | Clear remembered internet addresses | repair | low | yes | - | - | - | - | core |
| `net.dns_auto` | Get DNS servers automatically again | repair | medium | yes | - | yes | - | yes |  |
| `net.backup_ip_config` | Back up network settings | backup | low | yes | - | - | - | n/a |  |
| `net.reset_winsock` | Reset Windows networking (Winsock) | repair | medium | yes | yes | yes | - | yes |  |
| `net.reset_tcpip` | Reset internet settings to defaults (TCP/IP) | repair | medium | yes | yes | yes | - | yes |  |
| `net.restore_static_ip` | Restore fixed network settings | repair | medium | yes | - | yes | - | yes |  |
| `net.proxy_user_reset` | Turn off the proxy setting | repair | low | - | - | - | - | yes | user |
| `net.proxy_system_reset` | Turn off the system proxy (WinHTTP) | repair | low | yes | - | - | - | yes |  |
| `net.hosts_reset` | Reset the hosts file to the default | repair | medium | yes | - | yes | - | yes |  |
| `net.firewall_report` | Show the firewall status | diagnose | low | - | - | - | - | n/a |  |
| `net.firewall_enable` | Turn Windows Firewall back on | repair | low | yes | - | - | - | - |  |
| `net.wfp_drop_events` | Find out which filter drops network traffic | diagnose | low | yes | - | - | - | n/a | exp. |
| `net.wfp_audit_trace` | Briefly log blocked connections | diagnose | low | yes | - | - | - | yes | exp. |
| `sec.detect_isolation` | Check whether the organization isolated this device | diagnose | low | yes | - | - | - | n/a | core |
| `net.vpn_report` | Show VPN software and leftovers | diagnose | low | - | - | - | - | n/a |  |
| `net.vpn_disable_adapter` | Switch off a leftover VPN adapter | repair | medium | yes | - | yes | - | yes |  |
| `wifi.report` | Show the Wi-Fi status | diagnose | low | - | - | - | - | n/a | core |
| `wifi.radio_on` | Turn Wi-Fi on | repair | low | - | - | - | - | yes | core, user |
| `wifi.restart_service` | Restart the Wi-Fi service | repair | low | yes | - | - | - | - |  |
| `wifi.forget_profile` | Forget a saved Wi-Fi network | repair | medium | yes | - | yes | yes | yes |  |
| `wifi.connect` | Connect to a saved Wi-Fi network | repair | low | - | - | - | - | yes |  |

### slow (4)

| ID | Title | Kind | Risk | Admin | Restart | Confirm | Deletes | Rollback | Flags |
|---|---|---|---|---|---|---|---|---|---|
| `boot.report` | Show start-up time and what slows it down | diagnose | low | yes | - | - | - | n/a | exp. |
| `boot.startup_list` | List startup programs | diagnose | low | - | - | - | - | n/a | user |
| `boot.startup_disable` | Stop a program from starting automatically | repair | low | yes | - | - | - | yes | exp., user |
| `boot.fast_startup_off` | Turn off Fast Startup | repair | low | yes | - | - | - | yes |  |

### disk (10)

| ID | Title | Kind | Risk | Admin | Restart | Confirm | Deletes | Rollback | Flags |
|---|---|---|---|---|---|---|---|---|---|
| `disk.report` | Show what uses space on C: | diagnose | low | yes | - | - | - | n/a | core |
| `disk.clean_user_temp` | Delete old temporary files of the user | repair | low | - | - | yes | yes | - | core, user |
| `disk.clean_windows_temp` | Delete old Windows temporary files | repair | low | yes | - | yes | yes | - |  |
| `disk.clean_delivery_optimization` | Empty the update download cache | repair | low | yes | - | yes | yes | - |  |
| `disk.move_crash_dumps` | Move crash dumps to the rescue drive | repair | low | yes | - | yes | yes | yes |  |
| `disk.hibernation_off` | Turn off hibernation to free space | repair | medium | yes | - | yes | - | yes |  |
| `disk.open_storage_settings` | Open storage settings and the Recycle Bin | guide | low | - | - | - | - | n/a | user |
| `fs.health` | Check disk health | diagnose | low | yes | - | - | - | n/a |  |
| `fs.scan_online` | Scan drive C: for errors | repair | low | yes | - | - | - | - |  |
| `fs.check_on_restart` | Repair drive C: at the next restart | repair | medium | yes | yes | yes | - | - |  |

### printer (5)

| ID | Title | Kind | Risk | Admin | Restart | Confirm | Deletes | Rollback | Flags |
|---|---|---|---|---|---|---|---|---|---|
| `print.report` | Show printers and print jobs | diagnose | low | yes | - | - | - | n/a | core |
| `print.restart_spooler` | Restart the print service | repair | low | yes | - | - | - | - | core |
| `print.clear_queue` | Clear stuck print jobs | repair | low | yes | - | yes | yes | yes | core |
| `print.set_online` | Put the printer back online | repair | low | yes | - | - | - | yes | exp. |
| `print.set_default` | Set the default printer | repair | low | - | - | - | - | yes | user |

### sound (4)

| ID | Title | Kind | Risk | Admin | Restart | Confirm | Deletes | Rollback | Flags |
|---|---|---|---|---|---|---|---|---|---|
| `audio.report` | Check sound devices and volume | diagnose | low | - | - | - | - | n/a | core, user |
| `audio.restart_services` | Restart the sound services | repair | low | yes | - | - | - | - |  |
| `audio.unmute` | Unmute and turn the volume up | repair | low | - | - | - | - | yes | core, user |
| `audio.restart_device` | Restart the sound device | repair | medium | yes | - | yes | - | yes |  |

### update (4)

| ID | Title | Kind | Risk | Admin | Restart | Confirm | Deletes | Rollback | Flags |
|---|---|---|---|---|---|---|---|---|---|
| `wu.report` | Show the Windows Update status | diagnose | low | yes | - | - | - | n/a |  |
| `wu.restart_services` | Restart the update services | repair | low | yes | - | - | - | - |  |
| `wu.reset_components` | Rebuild the Windows Update caches | repair | medium | yes | - | yes | - | yes | online effect |
| `wu.service_defaults` | Re-enable disabled update services | repair | medium | yes | - | yes | - | - |  |

### display (3)

| ID | Title | Kind | Risk | Admin | Restart | Confirm | Deletes | Rollback | Flags |
|---|---|---|---|---|---|---|---|---|---|
| `display.report` | Check the graphics adapter and monitors | diagnose | low | - | - | - | - | n/a |  |
| `display.hotkey_reset` | Refresh the screen with a key combination | guide | low | - | - | - | - | n/a | user |
| `display.restart_adapter` | Restart the graphics adapter | repair | medium | yes | - | yes | - | - |  |

### other (36)

| ID | Title | Kind | Risk | Admin | Restart | Confirm | Deletes | Rollback | Flags |
|---|---|---|---|---|---|---|---|---|---|
| `sys.restart` | Restart the computer | repair | low | - | yes | yes | - | yes | core |
| `sys.restore_status` | Show restore points | diagnose | low | yes | - | - | - | n/a |  |
| `sys.enable_restore` | Turn on System Protection | repair | low | yes | - | - | - | - | exp. |
| `sys.create_restore_point` | Create a restore point | backup | low | yes | - | - | - | - | core |
| `sys.rollback_restore_point` | Roll the computer back to an earlier state | repair | high | yes | yes | yes | - | - | exp. |
| `hw.problem_devices` | Show devices with problems | diagnose | low | - | - | - | - | n/a |  |
| `hw.enable_device` | Switch a disabled device back on | repair | medium | yes | - | yes | - | yes |  |
| `hw.restart_device` | Restart a device | repair | medium | yes | - | yes | - | - |  |
| `time.report` | Check the time and time zone | diagnose | low | - | - | - | - | n/a |  |
| `time.set_timezone` | Set the time zone | repair | low | - | - | - | - | yes |  |
| `time.enable_sync` | Turn automatic time back on | repair | low | yes | - | - | - | yes | online effect |
| `time.set_manual` | Set the time by hand | repair | medium | yes | - | yes | - | - |  |
| `defender.report` | Show the antivirus status | diagnose | low | yes | - | - | - | n/a | core |
| `defender.update_from_ssd` | Update virus definitions from the rescue drive | repair | low | yes | - | - | - | - |  |
| `defender.realtime_on` | Turn real-time protection back on | repair | low | yes | - | - | - | - |  |
| `defender.quick_scan` | Quick malware scan | repair | low | yes | - | - | - | - |  |
| `defender.offline_scan` | Thorough scan at restart | repair | medium | yes | yes | yes | - | - |  |
| `sysfile.dism_checkhealth` | Quick check of the Windows component store | diagnose | low | yes | - | - | - | n/a |  |
| `sysfile.dism_scanhealth` | Thorough check of the Windows component store | diagnose | low | yes | - | - | - | n/a |  |
| `sysfile.sfc` | Check and repair Windows system files | repair | low | yes | - | - | - | - |  |
| `sysfile.dism_restorehealth_ssd` | Repair the component store from an image on the rescue drive | repair | low | yes | - | - | - | - |  |
| `shell.restart_explorer` | Restart the taskbar and File Explorer | repair | low | - | - | - | - | - | core, user |
| `shell.restart_startmenu` | Restart the Start menu | repair | low | - | - | - | - | - | user |
| `shell.restart_search` | Restart Windows search | repair | low | - | - | - | - | - | user |
| `shell.reregister_startmenu` | Register the Start menu again | repair | medium | - | - | yes | - | - | exp., user |
| `apps.report` | Show broken Store apps | diagnose | low | - | - | - | - | n/a | user |
| `apps.reregister` | Register a Store app again | repair | low | - | - | - | - | - | user |
| `apps.store_reset` | Clear the Microsoft Store cache | repair | low | - | - | - | - | - | user, online effect |
| `profile.report` | Check the user profile | diagnose | low | - | - | - | - | n/a |  |
| `profile.fix_temp_folder` | Create the missing temp folder | repair | low | - | - | - | - | yes | user |
| `profile.fix_bak_entry` | Reconnect the original user profile | repair | high | yes | yes | yes | - | yes |  |
| `bitlocker.report` | Check drive encryption (BitLocker) | diagnose | low | yes | - | - | - | n/a |  |
| `bitlocker.recovery_key_hint` | Show where to find the recovery key | guide | low | yes | - | - | - | n/a | online effect |
| `events.summary` | Most frequent errors in Event Viewer | diagnose | low | - | - | - | - | n/a |  |
| `events.crashes` | Crashes in the last 30 days | diagnose | low | - | - | - | - | n/a |  |
| `events.reliability` | Evaluate the reliability history | diagnose | low | - | - | - | - | n/a |  |

`user` = changes or reads the signed-in user's settings; `online effect` = works offline, the effect shows with internet.

## 14. Finding codes

| Code | Severity | Meaning | Candidates | Stop |
|---|---|---|---|---|
| `NOT_ADMIN` | 4 | The check ran without administrator rights; some measurements are missing. | - | - |
| `ELEVATED_OTHER_USER` | 4 | Started with another account's administrator rights: settings of the signed-in user (sound, proxy, Explorer, default printer) must not be changed this way. | - | - |
| `MANAGED_DEVICE` | 1 | The device belongs to a company or school (domain, Entra ID or device management). | - | yes (blocks: `net.*`, `wifi.forget_profile`, `wu.*`, `time.*`) |
| `PENDING_REBOOT` | 3 | Windows is waiting for a restart. | `sys.restart` | - |
| `UPTIME_LONG` | 3 | The computer has not been properly restarted for more than 7 days. | `sys.restart`, `boot.fast_startup_off` | - |
| `C_FREE_CRITICAL` | 1 | Less than 2 GB is free on the system drive. | `disk.report`, `disk.clean_user_temp`, `disk.clean_windows_temp`, `disk.clean_delivery_optimization`, `disk.move_crash_dumps`, `disk.hibernation_off`, `disk.open_storage_settings` | - |
| `C_FREE_LOW` | 3 | Little space is free on the system drive. | `disk.report`, `disk.clean_user_temp`, `disk.clean_windows_temp`, `disk.clean_delivery_optimization`, `disk.open_storage_settings` | - |
| `VOLUME_NOT_HEALTHY` | 2 | A drive reports file system errors. | `fs.health`, `fs.scan_online` | - |
| `DISK_UNHEALTHY` | 1 | A disk reports a bad health state. | `fs.health` | yes (blocks: `@reboot`, `fs.*`, `sysfile.*`, `disk.move_crash_dumps`) |
| `DISK_ERRORS_EVENTS` | 3 | The event log contains disk or file system errors. | `fs.health` | - |
| `NO_ADAPTER_UP` | 2 | No network adapter is connected. | `net.enable_adapter`, `wifi.report`, `net.restart_adapter` | - |
| `ADAPTER_DISABLED` | 2 | A network adapter is switched off in Windows. | `net.enable_adapter` | - |
| `NET_SERVICE_STOPPED` | 2 | An important network service (DHCP, DNS client, network awareness) is not running. | `sys.restart` | - |
| `APIPA_ADDRESS` | 2 | The address starts with 169.254: the router did not hand out an address. | `net.renew_dhcp`, `net.restart_adapter` | - |
| `NO_DEFAULT_GATEWAY` | 2 | No router (default gateway) is configured. | `net.renew_dhcp`, `net.restart_adapter` | - |
| `LOOPBACK_FAILS` | 2 | The self-test (127.0.0.1) fails: Windows networking is broken. | `net.triage_general_failure`, `net.reset_winsock`, `net.reset_tcpip` | - |
| `PING_GENERAL_FAILURE` | 2 | Ping reports "General failure": Windows does not even send the packet. | `net.triage_general_failure`, `sec.detect_isolation`, `net.wfp_drop_events` | - |
| `GW_UNREACHABLE` | 2 | The router does not answer. | `net.restart_adapter`, `net.renew_dhcp`, `wifi.report` | - |
| `TCP_BLOCKED_LOCAL` | 2 | Connections are refused on this computer (error 10013): a filter blocks them. | `net.triage_general_failure`, `sec.detect_isolation`, `net.wfp_drop_events`, `net.firewall_report` | - |
| `ONLY_DNS_WORKS` | 2 | Name lookup (DNS) answers, but neither ping nor connections to the internet work. | `sec.detect_isolation`, `net.wfp_drop_events`, `net.vpn_report` | - |
| `DNS_FAILS_NET_OK` | 2 | The internet is reachable, but name lookup (DNS) does not answer. | `net.dns_auto`, `net.flush_dns`, `net.hosts_reset` | - |
| `MANUAL_DNS` | 3 | DNS servers are set manually on an active network adapter. | `net.dns_auto` | - |
| `PROXY_USER_SET` | 3 | A proxy or proxy script is set for the user. | `net.proxy_user_reset` | - |
| `PROXY_WINHTTP_SET` | 3 | A system proxy (WinHTTP) is set for Windows services. | `net.proxy_system_reset` | - |
| `HOSTS_MODIFIED` | 3 | The hosts file contains active entries. | `net.hosts_reset` | - |
| `VPN_ADAPTER` | 3 | A VPN adapter is present. | `net.vpn_report` | - |
| `SPLIT_DEFAULT_ROUTE` | 3 | There are split default routes (0.0.0.0/1 and 128.0.0.0/1), typical for VPNs. | `net.vpn_report` | - |
| `NON_MS_LSP` | 3 | Third-party Winsock providers are installed. | `net.reset_winsock` | - |
| `NON_MS_NDIS_FILTER` | 3 | Third-party network filters are attached to the adapters (VPN, antivirus, virtualization). | `net.vpn_report`, `net.wfp_drop_events` | - |
| `FIREWALL_OFF` | 3 | Windows Firewall is off in at least one profile. | `net.firewall_report`, `net.firewall_enable` | - |
| `FIREWALL_OUTBOUND_BLOCK` | 3 | The firewall blocks outgoing connections by default. | `net.firewall_report` | - |
| `FIREWALL_SERVICE_STOPPED` | 2 | The firewall or filter service (mpssvc, BFE) is not running. | `sys.restart` | - |
| `MDE_ONBOARDED` | 4 | The device is onboarded to Microsoft Defender for Endpoint (corporate protection). | `sec.detect_isolation` | - |
| `MDE_ISOLATION_SUSPECT` | 1 | Suspicion: the organization isolated the device from the network via Defender for Endpoint. | `sec.detect_isolation` | yes (blocks: `net.*`, `wifi.*`) |
| `WLAN_RADIO_OFF` | 2 | Wi-Fi is switched off. | `wifi.radio_on` | - |
| `WLANSVC_STOPPED` | 2 | The Wi-Fi service is not running. | `wifi.restart_service` | - |
| `DEFENDER_RTP_OFF` | 2 | Defender real-time protection is off although Defender is in charge. | `defender.report`, `defender.realtime_on` | - |
| `DEFENDER_SIG_OLD` | 3 | The virus definitions are older than 7 days. | `defender.update_from_ssd` | - |
| `DEFENDER_THREATS` | 2 | Defender reported threats in the last 30 days. | `defender.report`, `defender.quick_scan`, `defender.offline_scan` | - |
| `NO_ACTIVE_AV` | 2 | No active antivirus protection found. | `defender.report` | - |
| `TIME_IMPLAUSIBLE` | 2 | The computer's clock is certainly wrong. | `time.report`, `time.set_timezone`, `time.set_manual` | - |
| `W32TIME_NOSYNC` | 3 | Automatic time is turned off. | `time.enable_sync` | - |
| `WU_SERVICE_DISABLED` | 2 | A Windows Update service is disabled. | `wu.service_defaults` | - |
| `WU_ERRORS` | 3 | Windows Update reported errors in the last 30 days. | `wu.report`, `wu.restart_services`, `wu.reset_components` | - |
| `SPOOLER_STOPPED` | 2 | The print service is not running. | `print.report`, `print.restart_spooler` | - |
| `PRINTER_OFFLINE` | 2 | The default printer is set to "Use printer offline". | `print.set_online` | - |
| `PRINT_JOBS_STUCK` | 2 | Print jobs are stuck. | `print.restart_spooler`, `print.clear_queue` | - |
| `AUDIO_SERVICE_STOPPED` | 2 | A sound service is not running. | `audio.restart_services` | - |
| `AUDIO_NO_ENDPOINT` | 2 | No working sound device found. | `audio.report`, `audio.restart_device` | - |
| `AUDIO_MUTED` | 2 | The default sound device is muted. | `audio.unmute` | - |
| `AUDIO_VOLUME_LOW` | 2 | The volume is below 5 %. | `audio.unmute` | - |
| `DISPLAY_TDR` | 3 | Windows restarted the graphics driver (event 4101). | `display.report` | - |
| `DEVICE_ERRORS` | 3 | Devices report errors (problem code in Device Manager). | `hw.problem_devices` | - |
| `TEMP_PROFILE` | 2 | Signs of a temporary user profile. | `profile.report` | - |
| `TEMP_DIR_MISSING` | 2 | The folder for temporary files is missing. | `profile.fix_temp_folder` | - |
| `APPX_BROKEN` | 3 | Store apps report an error state. | `apps.report` | - |
| `MANY_AUTOSTARTS` | 3 | More than 15 programs start automatically. | `boot.startup_list`, `boot.report` | - |
| `RESTORE_OFF` | 4 | System Protection is off for the system drive (no restore points). | `sys.enable_restore` | - |
| `BITLOCKER_ON` | 4 | The system drive is encrypted with BitLocker. | `bitlocker.recovery_key_hint` | - |
| `BITLOCKER_SUSPENDED` | 3 | BitLocker is suspended (protection off). | `bitlocker.report` | - |
| `CRASHES` | 3 | Unexpected shutdowns or blue screens. | `events.crashes` | - |
| `WHEA_ERRORS` | 1 | Windows reports a fatal hardware error (WHEA). | `events.crashes` | yes (blocks: `@reboot`, `sysfile.*`, `fs.*`, `hw.*`) |
| `APP_CRASHES` | 3 | Programs crash often. | `events.crashes`, `apps.report` | - |
