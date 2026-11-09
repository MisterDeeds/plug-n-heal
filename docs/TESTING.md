# Testing

Plug'n'Heal is tested on three levels:

| Level | What | Where |
|---|---|---|
| Unit tests | Pester 5 tests for every part, with fakes for WMI, the registry, Ollama and the model | your machine and CI, Windows PowerShell 5.1 and PowerShell 7, Windows and Linux |
| End-to-end | the full flow without a window (`Run-Headless.ps1`) with a real Ollama and a small model | CI (Windows) and test PCs |
| Real PCs | the checklist below, on Windows 10 and 11, German and English, with and without GPU | volunteers, test VMs |

Status for version 0.1: the unit tests exist for all parts; **no catalogue action has run on a real Windows PC yet**
(see [TOOLBOX.md section 11](TOOLBOX.md#11-what-still-needs-real-windows)). Real-PC reports are the most useful help
right now: please use the
[test report form](https://github.com/MisterDeeds/plug-n-heal/issues/new?template=test_report.yml).

## 1. Unit tests

| File | Covers |
|---|---|
| `tests/Common.Tests.ps1` | paths from `$PSScriptRoot`, run folders, logging, i18n lookup, hidden process start, JSON helpers |
| `tests/Hardware.Tests.ps1` | GPU/VRAM detection (registry, `nvidia-smi`), RAM, CPU, Windows edition, S mode, language mode (all mocked) |
| `tests/Models.Tests.ps1` | `models.json` fields, sizes and profile sums; installed-model detection; `Select-PnhModel` for typical PCs |
| `tests/Ollama.Tests.ps1` | server start environment, chat requests and tool-call parsing (HTTP mocked), fit test; optional integration test |
| `tests/Diagnose.Tests.ps1` | finding rules (`Get-PnhDiagnoseFlags`) on recorded facts, success checks; read-only diagnosis on Windows |
| `tests/Toolbox.Tests.ps1` | parameter validation, confirmation rule, backup, run, verify, rollback, restore point reasons, deny-list |
| `tests/Catalog.Tests.ps1` | schema and safety rules of `actions.json`, `findings.json`, `categories.json` (parser, PS7-only syntax, ASCII, deny-list, list of deleting actions) |
| `tests/Agent.Tests.ps1` | the agent loop with scripted model answers: candidates, stop findings, read-only mode, free PowerShell filter, end conditions, summary |
| `tests/Ui.Tests.ps1` | `START.cmd` as text, `Start.ps1` and `Ui.ps1` helpers, i18n completeness (German vs English), the background job in demo mode |
| `tests/Builder.Tests.ps1` | `Build-Drive.ps1`: paths, file system and space checks, manifests, download retry loop (mocked), `drive.json`, `README.txt` |

`builder/build-drive.sh` has no unit tests; the CI job `builder-linux` checks it with shellcheck and a real build
(section 3).

Tests that need real Windows are marked with `-Skip:(-not $onWindows)` and are skipped on Linux.

### Run them locally

`tests/Invoke-Tests.ps1` is the single entry point, locally and in CI. It needs **Pester 5.5 or newer (below 6)**.
Windows PowerShell 5.1 ships with the old Pester 3.4, so install Pester 5 once:

```powershell
Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck -MinimumVersion 5.5 -MaximumVersion 5.99
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
```

Then, in the repository folder:

```powershell
# Windows PowerShell 5.1
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-Tests.ps1

# PowerShell 7 (Windows, Linux or macOS)
pwsh -NoProfile -File tests/Invoke-Tests.ps1

# one file, more detail
pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Path tests/Models.Tests.ps1 -Output Detailed
```

It writes NUnit and JUnit result files (`<Name>.nunit.xml`, `<Name>.junit.xml`; `-Name` sets the base name, default
`pester-<edition><major>.<minor>-<os>`, for example `pester-core7.4-linux`) to `TestResults/` (ignored by git;
`-OutputDirectory` moves them, `-NoResultFiles` switches them off) and returns failed tests + failed blocks + failed
files as exit code, capped at 255 (255 also means the run could not start, for example without Pester 5). On GitHub
Actions it adds a summary table to the job page.
`-Tag` and `-ExcludeTag` select tests by tag, `-Output` sets the console detail. Plain `Invoke-Pester -Path ./tests`
works too, as long as Pester 5 is the version that is loaded.

Without a local PowerShell, the same run works in a container:

```bash
docker run --rm -v "$PWD:/r" -w /r mcr.microsoft.com/powershell:lts-debian-12 pwsh -NoProfile -Command \
  'Install-Module Pester -RequiredVersion 5.7.1 -Force -Scope CurrentUser *> $null; ./tests/Invoke-Tests.ps1'
```

**Static analysis** with the project settings (severity Error and Warning; compatibility rules for Windows
PowerShell 5.1 and PowerShell 7):

```powershell
Invoke-ScriptAnalyzer -Path src -Recurse -Settings tests/PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer -Path builder -Recurse -Settings tests/PSScriptAnalyzerSettings.psd1
Invoke-ScriptAnalyzer -Path tests -Recurse -Settings tests/PSScriptAnalyzerSettings.psd1
```

The settings file explains each excluded rule.

### Optional Ollama integration test

`tests/Ollama.Tests.ps1` contains tests tagged `Integration` that talk to a real Ollama binary. They are skipped
unless both variables are set:

```powershell
$env:PNH_IT_ROOT  = 'E:\PlugNHeal'          # a root with runtime\ollama and models\
$env:PNH_IT_MODEL = 'qwen3.5:2b-q4_K_M'     # an installed model with tool support
pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Path tests/Ollama.Tests.ps1 -Tag Integration -Output Detailed
```

## 2. End-to-end without a window

`src/Run-Headless.ps1` runs the same flow as the window: hardware, model, Ollama, diagnosis, agent. Exit code `0` =
solved (the success check passed), `1` = not solved, `2` = error.

On a Windows test PC or VM with a built drive (here `E:`), in a PowerShell started with **Run as administrator**:

```powershell
Stop-Service -Name Spooler            # break something harmless
powershell -NoProfile -ExecutionPolicy Bypass -File E:\PlugNHeal\app\Run-Headless.ps1 `
    -Category printer -AutoConfirm -Model qwen3.5:2b-q4_K_M
$LASTEXITCODE                         # expected: 0
```

With `-AutoConfirm` every confirmation is answered "Yes", including "restart the computer" (`sys.restart`
schedules a restart in 60 seconds). On a test PC you can cancel it with `shutdown /a`.

The CI scripts in `tests/e2e/` do the same with checks:

| Script | Does |
|---|---|
| `Break-Printer.ps1` | stops the Print Spooler and proves that the diagnosis sees it (finding `SPOOLER_STOPPED`, `check.printer` fails). Refuses to run outside GitHub Actions unless `-Force` is given. |
| `Assert-Run.ps1 -Scenario diagnose` | full read-only diagnosis with the drive's libraries; time limit, only known finding codes |
| `Assert-Run.ps1 -Scenario printer` | `Run-Headless.ps1 -Category printer -AutoConfirm -Json`; expects "solved", a running spooler, a changing action, the run folder files and a logged restore point attempt |
| `Assert-Run.ps1 -Scenario network-readonly` | `Run-Headless.ps1 -Category network -ReadOnly -Json`; expects no change at all (network configuration compared before and after) |

`Assert-Run.ps1` aborts pending restarts while a run is going on, writes its evidence to `TestResults/e2e/` and
exits with `0` (all checks passed), `1` (a check failed) or `2` (could not run). Example:

```powershell
.\tests\e2e\Break-Printer.ps1 -AppPath E:\PlugNHeal\app -Force
.\tests\e2e\Assert-Run.ps1 -Scenario printer -AppPath E:\PlugNHeal\app -Model qwen3.5:2b-q4_K_M
```

Useful switches: `-ReadOnly` (look only, list what would help), `-Json` (result as JSON on stdout), `-UserText
"..."`, `-Language de|en`, `-MaxRounds <n>`, `-NoOllamaStart -BaseUrl http://127.0.0.1:11434` (use a running Ollama).
Without `-AutoConfirm`, an interactive console asks each confirmation; a non-interactive run answers "No".

No spare SSD? The builder also accepts a folder: `BUILD.cmd -NonInteractive -Drive D:\pnh-test -Profile small`
creates `D:\pnh-test\PlugNHeal\...`.

To see the window without any change and without a model, use the demo mode:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\src\Ui.ps1 -Demo
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\src\Ui.ps1 -Demo -DemoFailure slow   # error pages: ollama, nomodel, slow, weak, crash
```

## 3. CI

CI runs on GitHub Actions (free for public repositories) and is defined in `.github/workflows/ci.yml`; that file is
the reference for the exact steps and versions. It runs on every push to `main`, on pull requests and by hand, with
four jobs and only public downloads (no secrets). It follows [ARCHITECTURE.md section 7](ARCHITECTURE.md#7-testing):

| Job | Runs on | Does |
|---|---|---|
| `lint` | `windows-latest`, PowerShell 7 | PSScriptAnalyzer 1.25.0 with `tests/PSScriptAnalyzerSettings.psd1` over `src/`, `builder/` and `tests/`, plus a strict pass over `src/` that keeps `PSAvoidUsingEmptyCatchBlock`, `PSUseDeclaredVarsMoreThanAssignments` and `PSAvoidGlobalVars`. Repository checks on every tracked text file: valid UTF-8, no sharp s, strict JSON without BOM, CRLF in `.cmd`/`.bat`, `.ps1`/`.psm1`/`.psd1` ASCII-only or UTF-8 with BOM, identical keys in `src/i18n/de.json` and `en.json` |
| `unit` | matrix `windows-ps5.1` (Windows PowerShell 5.1), `windows-ps7` (PowerShell 7 on Windows), `ubuntu-ps7` (PowerShell 7 on Linux) | installs Pester 5 (5.5 to 5.99) and runs `tests/Invoke-Tests.ps1 -Name pester-<matrix name>`; uploads `TestResults/` as artifact `test-results-<matrix name>` |
| `builder-linux` | `ubuntu-latest` | shellcheck (`koalaman/shellcheck:v0.11.0`) over every `*.sh`; `builder/build-drive.sh` builds profile `small` from a CI catalogue that holds only the CI model (`PNH_CI_MODEL`, `qwen3.5:2b-q4_K_M`); checks the drive (files, `drive.json`, manifest and blob sizes, BOM/CRLF of `README.txt`, CRLF of `START.cmd`); then the official Linux Ollama of the pinned version reads the built models in a network namespace without a route out (`ollama list`, `show`, a tiny generation) |
| `e2e-windows` | `windows-latest`, Windows PowerShell 5.1 | `Build-Drive.ps1 -NonInteractive` onto a `subst` drive `P:` with the same CI catalogue; `tests/e2e/Assert-Run.ps1 -Scenario diagnose` (under 60 s); `tests/e2e/Break-Printer.ps1`; `Assert-Run.ps1 -Scenario printer` (`Run-Headless.ps1 -AutoConfirm` with the CI model on the CPU, must fix the spooler); `Assert-Run.ps1 -Scenario network-readonly` (must change nothing); uploads run folders, build log and evidence |

The two build jobs cache the runtime ZIP and the model blobs between runs.

The Windows runner is Windows Server: System Restore does not exist there, so the restore point is reported as
skipped (reason `server-os`), which is the expected result. The runner has no GPU, no consumer features and no
German Windows; that is what the manual checklist is for.

## 4. Manual test checklist for real PCs

Use a PC or VM whose data does not matter, or make a full backup first. Report every run with the
[test report form](https://github.com/MisterDeeds/plug-n-heal/issues/new?template=test_report.yml) and attach
`summary.txt` and `run.log` (remove personal data).

### Test matrix

Cover as many cells as you can; each report says which ones it covers.

| Dimension | Values |
|---|---|
| Windows | Windows 10 22H2; Windows 11 24H2; Windows 11 25H2 |
| Display language | German; English |
| Graphics | NVIDIA card (6–8 GB, 12 GB, 16 GB, 24 GB); AMD card; Intel or built-in graphics only |
| Memory | 8 GB; 16 GB; 32 GB or more |
| Account | administrator; standard user (UAC asks for an admin password) |
| Protection | Defender only; third-party antivirus; BitLocker on; Smart App Control on (Windows 11) |
| Management | private PC; company-managed (domain, Entra ID or MDM); onboarded to Defender for Endpoint (test tenant) |
| Drive | exFAT SSD; NTFS SSD; USB 3; USB 2 |

### A. Build

- [ ] Windows wizard with an unblocked ZIP: drive list, profile sizes, progress and remaining time, "Done".
- [ ] Windows wizard with a ZIP that was **not** unblocked: what does Windows show? (Report the exact message.)
- [ ] Cancel during the model download, start again: it resumes and finishes.
- [ ] FAT32 drive: refused with the exFAT explanation, nothing written.
- [ ] Linux or macOS: `build-drive.sh` with `small`, interrupt with Ctrl+C, run again.
- [ ] `README.txt`, `drive.json` and `PlugNHeal\licenses\` are on the drive.

### B. Start

- [ ] Double-click `START.cmd`: the console window disappears once the window is open (also with Windows Terminal as
      the default terminal on Windows 11).
- [ ] The UAC prompt shows "Windows PowerShell", publisher "Microsoft Windows".
- [ ] UAC **No**: the window opens in look-only mode with the banner, nothing is changed, the result lists what would
      help.
- [ ] Standard user: UAC asks for an administrator password; with it, repair mode works.
- [ ] Second double-click while it runs: "Plug'n'Heal is already open".
- [ ] With Smart App Control on: does it start? Is the language mode `FullLanguage` (see `run.log`)?
- [ ] On a company PC with AppLocker/WDAC: the "not allowed to run here" message appears, nothing else happens.

### C. Preparation

- [ ] Time from "Start help" to the category page: ______ s.
- [ ] Model chosen and reason in `run.log` ("Model selected"), fit test result ("Model fit measured": tokens per
      second, GPU share).
- [ ] The chosen model matches the table in [MODELS.md](MODELS.md#2-how-a-pc-gets-its-model).
- [ ] Diagnosis duration (`diagnose.json`, `DurationMs`): target under 30 seconds.

### D. Repairs with a prepared, harmless fault

Cause the fault in an elevated PowerShell (test PC only), then run Plug'n'Heal with the category in the table and
check: the expected finding is in `diagnose.json` (`Flags`), the expected action ran, the result page says "fixed",
`backups\` has a folder for the action, and the fault is really gone.

| Category | Cause the fault | Expected finding | Expected action |
|---|---|---|---|
| Printer | `Stop-Service -Name Spooler` | `SPOOLER_STOPPED` | `print.restart_spooler` |
| Sound | mute the speakers | `AUDIO_MUTED` | `audio.unmute` |
| Internet | `Disable-NetAdapter -Name '<adapter>'` (local access needed) | `ADAPTER_DISABLED` | `net.enable_adapter` |
| Internet | turn Wi-Fi off in quick settings | `WLAN_RADIO_OFF` | `wifi.radio_on` |
| Internet | `Set-DnsClientServerAddress -InterfaceAlias '<adapter>' -ServerAddresses 192.0.2.1` | `MANUAL_DNS`, `DNS_FAILS_NET_OK` | `net.dns_auto` (asks first) |
| Internet | set a non-existent proxy in Settings → Network → Proxy | `PROXY_USER_SET` | `net.proxy_user_reset` |
| Windows Update | `Set-Service -Name wuauserv -StartupType Disabled` | `WU_SERVICE_DISABLED` | `wu.service_defaults` (asks first) |
| Check everything | `Set-NetFirewallProfile -Profile Private -Enabled False` | `FIREWALL_OFF` | `net.firewall_enable` |

- [ ] An action that asks first: answering **No** is respected and not asked again.
- [ ] The report (`summary.txt`) is understandable to a layperson and matches what happened.
- [ ] Restore point: created ("Plug'n'Heal: ..." in System Restore), or the reason is in `run.log`.
- [ ] Rollback: in an elevated Windows PowerShell, `. E:\PlugNHeal\app\lib\Common.ps1`,
      `. E:\PlugNHeal\app\lib\Toolbox.ps1`, then
      `Undo-PnhAction -Result <run folder>\backups\<action folder>\result.json` restores the old state.

### E. Stop findings

- [ ] Company-managed PC: network, Windows Update and time changes are not offered; the result explains why.
- [ ] Defender for Endpoint isolation (test tenant): the run stops at once with the "call your IT" message and changes
      nothing.

### F. End

- [ ] **Finish** closes the window and stops Ollama (no `ollama.exe` left in Task Manager).
- [ ] The SSD can be ejected right after.
- [ ] `logs\` contains no passwords or keys (search `chat.jsonl` and `diagnose.json`).

### G. Open questions from the toolbox

Section 11 of [TOOLBOX.md](TOOLBOX.md#11-what-still-needs-real-windows) lists what only real Windows can answer (the
experimental actions, the 24-hour restore point limit, Core Audio under Constrained Language Mode, WinRT radios, the
timeout kill of external programs). Reports on any of these are welcome.
