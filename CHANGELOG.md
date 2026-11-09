# Changelog

All notable changes to Plug'n'Heal are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

First public version. Not yet tried on real home PCs; see the status note in the [README](README.md).

### Added

- **Start:** `START.cmd` in the root of the drive starts Windows PowerShell 5.1 with `-ExecutionPolicy Bypass`.
  `Start.ps1` stops with a plain message when Windows reports S mode or PowerShell runs in Constrained Language Mode
  (company PCs, App Control), asks once for administrator rights (UAC) and opens the window without a console. Refusing the UAC
  prompt opens a look-only mode.
- **Window** (`Ui.ps1`, WinForms): welcome page with one big button, preparation steps, nine problem tiles
  (check everything, internet, slow, disk full, printer, sound, Windows Update, screen, something else with a text
  box), live step list, Yes/No confirmation dialogs, result page with report. German and English, chosen from the
  Windows display language. Demo mode (`-Demo`) for trying the window without changes.
- **Headless runner** `Run-Headless.ps1` for CI, experts and scripted tests (`-Category`, `-AutoConfirm`, `-Model`,
  `-ReadOnly`, `-Json`).
- **Hardware detection** (`Hardware.ps1`): GPUs with VRAM from the registry (and `nvidia-smi`), RAM, CPU, Windows
  edition, S mode, language mode, drive.
- **Model catalogue** (`src/catalog/models.json`): six Apache-2.0 models from Qwen3.5 2B to Qwen3.8 27B with measured
  sizes; profiles `small` (5.3 GB), `standard` (29.6 GB) and `full` (62.6 GB). Automatic selection by VRAM and RAM,
  followed by a speed test (5, 10 or 15 tokens per second by tier; GPU tiers at least 90 % on the GPU) that steps
  down to a smaller model, each with its own context length. A PC whose RAM is below what every model needs gets a
  plain "not enough memory" message.
- **Ollama runtime** 0.40.15 (portable Windows build), started from the drive per run, listening on `127.0.0.1`
  only, with its models, home folder and keys on the drive.
- **Diagnosis** (`Diagnose.ps1`): read-only fact collection in ten sections, 63 finding codes, success checks per
  category.
- **Toolbox** (`src/toolbox/`): 92 catalogue actions (61 changing, 20 core, 8 experimental) with detection, backup,
  run, verification and rollback; restore point before the first change of a run; deny-list for free commands.
- **Agent** (`Agent.ps1`): tool loop against Ollama `/api/chat`, candidate actions only from set findings, stop
  findings (managed device, Defender for Endpoint isolation, failing disk, fatal hardware errors), filtered free
  PowerShell for the largest models, a "Yes" before every change while the smallest model works
  (`confirmAllChanges`), summary built from verified results only.
- **Logs** on the drive per run: `run.log`, `run.jsonl`, `diagnose.json`, `chat.jsonl`, `backups\`, `summary.txt`.
- **Builder** for Windows (`BUILD.cmd`, wizard and `-NonInteractive` mode) and for Linux/macOS
  (`builder/build-drive.sh`): pinned runtime with size and SHA-256 check, resumable downloads, model sizes checked
  against the catalogue, every blob verified, Mark-of-the-Web removed from the copied files, licences, `drive.json`
  and `README.txt` written to the drive. Never formats; refuses FAT32.
- **Tests:** Pester 5 tests for every part, for Windows PowerShell 5.1 and PowerShell 7.
- **Documentation:** README in English and German, architecture, safety, toolbox, models, building and testing
  guides, licence files, security policy, contributing guide, issue and pull request templates.

### Known limitations

- No catalogue action has run on a real Windows PC yet ([docs/TOOLBOX.md](docs/TOOLBOX.md#11-what-still-needs-real-windows)).
- `defender.update_from_ssd` and `sysfile.dism_restorehealth_ssd` find nothing yet, because the builder does not
  put virus definitions or a Windows image on the drive.
- `time.set_manual` is never offered until the window has a field for the correct time.
- Behaviour under Smart App Control, on Windows on ARM and on macOS (builder) is untested.

[0.1.0]: https://github.com/MisterDeeds/plug-n-heal/commits/main
