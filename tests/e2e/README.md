# End-to-end tests

These scripts drive the CI job `e2e-windows` (`.github/workflows/ci.yml`): a real drive is built, a real model runs on
the runner's CPU, and something harmless is broken and must be repaired by Plug'n'Heal. They are not Pester tests and
are not picked up by `tests/Invoke-Tests.ps1`.

| File | Purpose |
|---|---|
| `Break-Printer.ps1` | Stops the Print Spooler and proves with the app's own diagnosis that it is broken (`SPOOLER_STOPPED` set, `check.printer` fails). |
| `Assert-Run.ps1` | Runs one scenario and checks the outcome: `diagnose`, `printer` or `network-readonly`. |

## What the CI job does

1. Builds a drive with `builder\Build-Drive.ps1 -NonInteractive` (Windows PowerShell 5.1) into a folder that is mapped
   as `P:` with `subst`, so every path is derived from a drive letter as on a real SSD. The model list is a copy of
   `src\catalog\models.json` whose profile `small` holds only the CI model (`-Catalog`), currently `qwen3.5:2b-q4_K_M`.
2. `Assert-Run.ps1 -Scenario diagnose`: `Invoke-PnhDiagnose` (all sections, read-only) must finish in under 60 s and
   return facts and flags; every flag must be a code from `toolbox\findings.json`.
3. `Break-Printer.ps1`: stops the spooler (CI machines only).
4. `Assert-Run.ps1 -Scenario printer`: `P:\PlugNHeal\app\Run-Headless.ps1 -Category printer -AutoConfirm -Json` in
   `powershell.exe` (5.1). Expected: exit code 0, `solved = true`, the spooler runs again, `check.printer` passes, a
   changing catalogue action ran, and `run.log` contains `Restore point skipped: server-os` (Windows Server runners have
   no System Restore; on a Windows client "created" or "skipped" is accepted).
5. `Assert-Run.ps1 -Scenario network-readonly`: `Run-Headless.ps1 -Category network -ReadOnly -Json`. Expected: exit
   code 0 or 1, never 2; every changing action was skipped; no restore point attempt; no backup folder of a changing
   action; the network configuration is identical before and after (adapters, IPv4 addresses, DNS servers, default
   routes, proxies, hosts file, firewall profiles, Winsock catalogue, network services).
6. The run folders (`P:\PlugNHeal\logs\...`), the build log and the evidence of `Assert-Run.ps1` are uploaded as the
   artifact `e2e-windows-logs`, also when a step failed.

**Restart guard.** With `-AutoConfirm` a small model could pick "restart the computer" (`sys.restart` runs
`shutdown /r /t 60`), which would kill the runner. While a headless run is going on, `Assert-Run.ps1` calls
`shutdown.exe /a` every 5 seconds and reports an aborted restart as a warning. `-NoShutdownGuard` switches this off.

## Running it on your own test machine

Use a throw-away Windows 10/11 VM, not your own PC: the printer scenario stops the print service and lets the model
change the system with automatic "Yes" answers.

```powershell
# in an elevated Windows PowerShell 5.1, from the repository root, with a drive already built to E:
.\tests\e2e\Assert-Run.ps1 -Scenario diagnose -AppPath E:\PlugNHeal\app
.\tests\e2e\Break-Printer.ps1 -AppPath E:\PlugNHeal\app -Force
.\tests\e2e\Assert-Run.ps1 -Scenario printer -AppPath E:\PlugNHeal\app -Model qwen3.5:2b-q4_K_M
.\tests\e2e\Assert-Run.ps1 -Scenario network-readonly -AppPath E:\PlugNHeal\app -Model qwen3.5:2b-q4_K_M
```

Outside GitHub Actions `Break-Printer.ps1` refuses to run without `-Force`. The evidence goes to
`TestResults\e2e\` (or `-OutDir`):

| File | Content |
|---|---|
| `<scenario>.assert.json` | every check with result and detail, notes |
| `<scenario>.stdout.txt` | the JSON result of `Run-Headless.ps1 -Json` |
| `<scenario>.stderr.txt` | the progress lines of the run |
| `diagnose.json` | the full diagnosis of the `diagnose` scenario |
| `network-before.json`, `network-after.json` | the snapshots compared by `network-readonly` |
| `spooler-before.json` | spooler state before `Break-Printer.ps1` (when `-StateFile` is given) |

Exit codes of both scripts: 0 = all checks passed, 1 = a check failed, 2 = could not run (not Windows, no admin
rights, files missing).

## Limits

- The printer scenario depends on a 2-billion-parameter model choosing `print.restart_spooler`. It usually does, but
  it is a real model on a CPU; a failed run shows its reasoning in `chat.jsonl` of the run folder.
- Only Windows Server runners are available on GitHub, so restore points, Store apps and audio cannot be tested there.
- `Assert-Run.ps1` checks what a script can see. "The spooler runs" does not prove that paper comes out of a printer.
