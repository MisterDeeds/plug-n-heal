## What and why

<!-- What does this change, and which problem does it solve? Link the issue, e.g. "Closes #12". -->

## How it was tested

<!-- Commands you ran, and for anything that touches Windows: which Windows version and language, real PC or VM. -->

## Checklist

- [ ] The tests pass in Windows PowerShell 5.1 and PowerShell 7 (`tests/Invoke-Tests.ps1`), new code has tests.
- [ ] PSScriptAnalyzer with `tests/PSScriptAnalyzerSettings.psd1` reports no warnings or errors.
- [ ] `.ps1` files are ASCII only, or UTF-8 with BOM; no PowerShell-7-only syntax.
- [ ] Every new user-visible text is in `src/i18n/en.json` **and** `src/i18n/de.json` (German: Sie form, `ss`, never the sharp s `U+00DF`).
- [ ] Docs updated where needed: `README.md` **and** `README.de.md`, `docs/`, `CHANGELOG.md`.
- [ ] Code and `docs/ARCHITECTURE.md` still agree.
- [ ] No logs from real computers, no passwords, keys or tokens, no third-party binaries or model files.
- [ ] Nothing disables, weakens or bypasses a security feature (Defender, firewall, SmartScreen, UAC, BitLocker,
      App Control, device isolation).

### For new or changed catalogue actions

- [ ] Followed [docs/TOOLBOX.md, section 10](https://github.com/MisterDeeds/plug-n-heal/blob/main/docs/TOOLBOX.md#10-adding-an-action-safely): detection,
      backup or `backupNote`, verify, rollback or `rollbackNote`, confirmation rule, finding candidate, category scope.
- [ ] Sources (Microsoft documentation) are in `sources`.
- [ ] Marked `experimental` if anything is undocumented or not yet confirmed on real Windows.
- [ ] Ran it on a real Windows PC or VM: <!-- Windows version, language, result -->
