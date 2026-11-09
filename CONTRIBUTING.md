# Contributing to Plug'n'Heal

Thank you for helping. Plug'n'Heal runs with administrator rights on computers of people who cannot judge what it
does. Every contribution is measured against that.

## Ways to help

| You can | How |
|---|---|
| Test it on a real PC | Build a drive, run it, and file a [test report](https://github.com/MisterDeeds/plug-n-heal/issues/new?template=test_report.yml). This is the most useful help right now. |
| Report a bug | [Bug report](https://github.com/MisterDeeds/plug-n-heal/issues/new?template=bug_report.yml) with `summary.txt` and `run.log` (personal data removed) |
| Report a security problem | Privately, see [SECURITY.md](SECURITY.md). Not in a public issue. |
| Propose a repair action | Open an issue first (see below), then a pull request |
| Improve texts | Plain German and English in `src/i18n/`, the READMEs and `docs/` |
| Write code | Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) first: it is the contract between the parts |

For anything larger than a small fix, open an issue first so we can agree on the approach.

## Ground rules

These come from [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) section 2 and are not negotiable:

1. **Never fight security.** No code and no action disables, weakens or bypasses Defender, tamper protection,
   SmartScreen, the firewall, UAC, BitLocker, App Control or Defender-for-Endpoint isolation. Pull requests that do
   are closed, whatever the use case.
2. **Measure first, then ask the model.** The model gets facts from read-only diagnosis, not a blank shell.
3. **The model chooses, the script acts.** Parameters come from detection output, never from the model.
4. **Success is decided by a script.** A model saying "fixed" means nothing.
5. **Every change is reversible or confirmed.** Backup before, rollback known, confirmation for risky steps.
6. **One window, big buttons, plain language.** No jargon and no question the user cannot answer.
7. **Nothing hard-coded about the drive.** Drive letters change; derive paths from `$PSScriptRoot` /
   `Get-PnhPaths`.
8. **Windows PowerShell 5.1 is the target.** It must run on a stock Windows 10/11 without installing anything.
   PowerShell 7 must work too.

If code and `docs/ARCHITECTURE.md` disagree, fix one of them in the same change.

## Proposing a repair action

1. Open an issue that answers: Which problem? Which finding code (`src/toolbox/findings.json`) detects it, or which
   new one is needed? Which Microsoft documentation describes the fix? What is backed up, and how is it undone?
2. It does **not** belong in the catalogue if it
   - weakens or bypasses a security feature (see ground rule 1),
   - needs internet to work,
   - deletes anything that is not clearly temporary (user files, Recycle Bin, Downloads, restore points, profiles,
     event logs),
   - relies on parsing localized console text,
   - is one of the things listed in [docs/TOOLBOX.md](docs/TOOLBOX.md#12-not-in-the-catalogue-on-purpose), section 12.
3. Then follow [docs/TOOLBOX.md, section 10 "Adding an action safely"](docs/TOOLBOX.md#10-adding-an-action-safely):
   schema, `detect` / `backup` / `run` / `verify` / `rollback`, confirmation rule, finding candidates, category scope.
4. Mark it `experimental` while anything about it is undocumented or unconfirmed on real Windows.
5. Run `tests/Catalog.Tests.ps1`. It checks schema, confirmation rule, backups and rollbacks, parsing, PowerShell 7
   syntax, the deny-list and the fixed list of deleting actions. If you add a deleting action, that list test must
   change too, and the pull request must say why.
6. Run the action on a test PC with German and English Windows, and report the result in the pull request.

## PowerShell rules

| Rule | Why |
|---|---|
| `.ps1` files are **ASCII only**, or **UTF-8 with BOM** if non-ASCII is unavoidable. In ASCII files build umlauts from code points, for example `[char]0x00FC`. | Windows PowerShell 5.1 reads a file without BOM as ANSI and garbles every non-ASCII character. |
| PowerShell blocks inside `src/toolbox/actions.json` are ASCII only. | Enforced by `tests/Catalog.Tests.ps1`. |
| JSON files are UTF-8 **without** BOM and are read with an explicit UTF-8 decoder (`[IO.File]::ReadAllText($p, [Text.Encoding]::UTF8)` or `Get-Content -Raw -Encoding UTF8`). | `Get-Content` without `-Encoding` uses the ANSI code page in 5.1. |
| Keep line endings as `.gitattributes` says: CRLF for `.cmd` and `.ps1`, LF for `.sh`, `.json`, `.md`. | `cmd.exe` misreads LF-only batch files. |
| **No PowerShell-7-only syntax:** no `??`, `??=`, `?.`, `?[]`, no ternary `a ? b : c`, no pipeline chains `&&` / `\|\|`, no `ConvertFrom-Json -AsHashtable`, no `ForEach-Object -Parallel`. Guard `$IsWindows` (it does not exist in 5.1). | Target PCs only have 5.1. |
| Functions use the prefix `Pnh` and return `[pscustomobject]` or hashtables that survive `ConvertTo-Json -Depth 10`. | Contract in ARCHITECTURE.md section 5. |
| No console output; log with `Write-PnhLog`. | The window runs without a console. |
| Start external programs hidden (`Start-PnhHidden`; in catalogue scripts `Invoke-PnhNative`). Evaluate exit codes, objects, registry values, never localized text. | No flashing windows; German and English Windows must behave the same. |
| `Invoke-WebRequest` always with `-UseBasicParsing`. | 5.1 otherwise depends on Internet Explorer components and may prompt. |
| Every word on screen comes from `src/i18n/en.json` **and** `src/i18n/de.json`. German: "Sie" form, Swiss spelling (`ss`, never the sharp s `U+00DF`), short sentences. | Two languages, one source; `tests/Ui.Tests.ps1` checks that both files match. |

## Tests

- Tests use **Pester 5** and must pass on **Windows PowerShell 5.1** and **PowerShell 7** (Windows, and Linux for
  everything that does not need Windows). New code comes with tests; Windows-only tests use
  `-Skip:(-not $onWindows)` like the existing ones.
- **PSScriptAnalyzer** with `tests/PSScriptAnalyzerSettings.psd1` must not report warnings or errors (it also
  checks that syntax and commands exist in Windows PowerShell 5.1). If a rule has to be suppressed in one place, use
  `[Diagnostics.CodeAnalysis.SuppressMessageAttribute(...)]` with a `Justification`.

```powershell
# once, in Windows PowerShell 5.1 (it ships with the old Pester 3)
Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck -MinimumVersion 5.5 -MaximumVersion 5.99
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force

# every time
powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-Tests.ps1     # Windows PowerShell 5.1
pwsh -NoProfile -File tests/Invoke-Tests.ps1                                    # PowerShell 7
Invoke-ScriptAnalyzer -Path src -Recurse -Settings tests/PSScriptAnalyzerSettings.psd1
```

More, including the manual checklist for real PCs: [docs/TESTING.md](docs/TESTING.md).

## Pull requests

- One topic per pull request. Describe what changed, why, and how you tested it (the template asks for it).
- Update the docs in the same pull request: `README.md` **and** `README.de.md` for anything users see, the files in
  `docs/` for behaviour, and the topmost (unreleased) section of [CHANGELOG.md](CHANGELOG.md).
- Do not add third-party code, binaries or model files to the repository. The builder downloads such things from
  their sources (see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)).
- Never commit logs from real computers, or passwords, keys or tokens.

## Licence of contributions

Plug'n'Heal is licensed under the [Apache License 2.0](LICENSE). By submitting a contribution you agree that it is
licensed under the same terms (section 5 of the licence).

## Code of conduct

This project follows the [Contributor Covenant 2.1](CODE_OF_CONDUCT.md).
