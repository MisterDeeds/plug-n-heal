# Safety

This page explains what Plug'n'Heal's agent may and may not do on someone else's computer, when it asks first, and
where its limits are. The binding contract is [ARCHITECTURE.md](ARCHITECTURE.md) (sections 2 and 5.5–5.7); the code is
`src/lib/Agent.ps1` (the loop) and `src/lib/Toolbox.ps1` (the actions and the deny-list).

## The short version

- The language model **chooses**, the script **acts**. The model can only call tools the agent offers; it never gets a
  shell of its own (except the filtered `run_powershell` for large models, see below).
- Every change comes from a **catalogue of tested actions** with a backup, a verification and, where possible, a
  rollback. A restore point is attempted before the first change of a run.
- **Success is decided by a script**, never by the model. "Solved" means the category's success check passed.
- Plug'n'Heal **never fights security**: it does not switch off or bypass Defender, the firewall, SmartScreen,
  BitLocker or device isolation. An isolated computer is explained and left alone.
- Everything stays on the SSD. Nothing is sent anywhere.

## What the agent offers the model

For one run the model sees only:

| Tool | When | What it does |
|---|---|---|
| Candidate actions | the diagnosis set a finding that lists them (`toolbox/findings.json`) | a tested catalogue action |
| Read-only diagnostics | they belong to the chosen category (`toolbox/categories.json`) | looks, changes nothing |
| `ask_user(question)` | always, except in read-only mode | a yes/no question to the person |
| `finish(summary)` | always | ends the run; the text is only used as wording |
| `run_powershell(command, why)` | only models marked `freeShell` in `catalog/models.json` (large models) | a filtered PowerShell command |

Special categories: **all** ("I don't know, check everything") runs the full diagnosis and offers the candidates of all
findings, most important first. **other** (free text) runs the full diagnosis and offers only the candidates of the
findings: no extra diagnostics and no free PowerShell. Small models (tier 1) get at most 12 actions, tier 2 at most 16,
larger models at most 20.

Parameters must come from the diagnosis, not from the model's imagination. The agent normalises obvious slips of small
models (`"C:"` for a drive letter, numbers written as text, wrong letter case) and refuses anything that still does not
fit the action's schema; the toolbox validates again before it runs anything.

## Confirmation rules

| Situation | Asked? |
|---|---|
| Catalogue action with `confirm: true`, risk medium or high, or a restart | yes, the toolbox asks before it runs |
| Any changing catalogue action while the smallest model works (`confirmAllChanges`, tier 1) | yes, whatever the action's own rule says |
| Other catalogue actions (low risk, backed up, reversible) | no |
| `run_powershell` with a read-only command | no |
| `run_powershell` with any other command | yes; a restore point is attempted first |
| `run_powershell` with a deny-listed command | never runs, the person is not even asked |
| Read-only mode (the person refused administrator rights) | never; changes are skipped and listed as "what would help" |

A "No" is final for that step: the model is told not to try the same thing again, and the same call twice in a row
ends the run. The confirmation text shows the action's title, a plain explanation, the risk and whether a restart is
needed. For free commands it shows the model's reason and the exact command.

## Free PowerShell (large models only)

`run_powershell` goes through these filters, in this order:

1. **Deny-list** (`Test-PnhCommandDenied` in `Toolbox.ps1`): always blocks, also with "Yes". It covers at least
   `format`, `diskpart`, `bcdedit /delete`, `cipher /w`, `Remove-Item` on system paths, anything that touches
   Defender, firewall reset, BitLocker or device isolation, registry deletes under `HKLM\SYSTEM`, and deleting user data.
   If the deny-list is not loaded, every free command is blocked.
2. **Parse**: a command with syntax errors is not run.
3. **Read-only check** (parsed, not text matching): every command in it must be on the allow-list: cmdlets with the
   verbs `Get-`, `Test-`, `Measure-`, `Select-`, `Resolve-`, `Find-` (without `-Repair`, `-Fix`, `-Reset` and similar,
   and not `Get-Credential`), formatting and filtering cmdlets (`Format-Table`, `Where-Object`, `Sort-Object`, ...), and
   known executables with read-only arguments only (`ipconfig /all`, `ping`, `tracert`, `nslookup <name>`,
   `netsh ... show ...`, `whoami`, `systeminfo`, `driverquery`, `sc.exe query`, `reg query`, ...). Redirection to files,
   method calls other than harmless string and lookup methods, dot-sourcing and dynamic command names do not count as
   read-only. `netsh wlan show profile ... key=clear` is not read-only because it would reveal a Wi-Fi password.
4. Read-only commands run directly; everything else needs the person's "Yes".
5. While a stop finding is in force (see below) only read-only commands run.

Each command runs in a separate hidden Windows PowerShell process with a 120-second timeout; the output given back to
the model is cut to about 2000 characters.

## Stop findings and device isolation

Some findings mean "repairing here would be wrong" (`stop` in `findings.json`), for example a company-managed device, a
failing disk, hardware errors or a suspected Defender for Endpoint isolation.

- If a read-only probe exists for the finding (an action whose `stopWhen` names it, such as `sec.detect_isolation`),
  the agent runs it **before** asking the model. Positive: the run stops at once and the person is told to call
  whoever manages the computer. Clearly negative: the suspicion is dropped. Unclear: the finding stays in force.
- A finding in force removes the changing actions it `blocks` (for example `net.*` on a managed device, everything
  needing a restart on a failing disk). Looking is still allowed. If no repair is left for the problem, the run ends
  with the finding's explanation and the model is not asked at all.
- If the model itself runs a probe that comes back positive, the run stops the same way.

## How a run ends

The loop stops when the success check passed (the model is then only asked for wording), when the model calls
`finish`, after 12 rounds, when the same call comes twice without anything changing in between, after 3 errors in a
row, after a second unusable answer in a row (the first one gets one corrective message), or on a stop finding.

**Solved** is `true` only if the category's success check passes at the end, and the check either failed at the start
or a verified change was made. A model that says "fixed" while the check fails produces "not solved", and its words
appear in the report only as "the assistant's guess (not checked)".

## Backups, rollback, restore points

The toolbox backs up before each change into the run folder and verifies afterwards; when the verification fails it
can roll back from that backup (the action result says whether it did). A system restore point is attempted once per run before the first change. Restore points are
often impossible (switched off, Windows Server, created less than 24 hours ago); that is logged and the run continues,
because every catalogue action has its own backup.

## Logs and privacy

Everything a run produces stays in its run folder on the SSD (`logs\<COMPUTERNAME>-<timestamp>\`):

| File | Content |
|---|---|
| `run.log`, `run.jsonl` | every step and action with its result |
| `diagnose.json` | the full read-only diagnosis |
| `chat.jsonl` | every request to and answer from the local model (messages, tool calls, model thinking) |
| `backups\` | what the actions saved before changing anything |
| `summary.txt` | the plain report for the person |

The diagnosis and the chat contain details of the computer (computer and printer names, network settings, event
messages, the person's own words). No secrets are collected on purpose, but command output can contain personal data.
Delete the `logs` folder before giving the SSD to someone else.

Text that comes back from the computer (tool output, event messages, file names) is treated as data. The system prompt
tells the model not to follow instructions found there, and even if it did, it can only choose from the offered tools.

## Honest limits

- **Small models make mistakes.** In our tests a 2-billion-parameter model chose the right repair, but also asked
  unnecessary questions, picked an unrelated restart in read-only mode, and once wrote "I restarted the computer"
  when nothing had been done. The agent's report is built from verified results only, but the model's live messages
  (events with `Source = 'model'`) are its own words and are not checked.
- **Ollama's tool-call parsers are not perfect.** Malformed calls can arrive as HTTP 500, as text, or disappear
  silently. The agent recovers tool calls written as text, retries once with a correction, and otherwise stops.
- **The free-command filter is not a sandbox.** It is a parsed allow-list plus a deny-list. A cmdlet from a third-party
  module with a `Get-` verb could in theory change something; that is why free PowerShell is only offered to large
  models and every non-read-only command needs a "Yes".
- **The catalogue decides what can be fixed.** Problems without a matching finding get a diagnosis and a plain
  explanation, not a repair.
- **The success checks are narrow.** "The print spooler runs" does not prove that paper comes out of the printer.
- **Not yet proven on real Windows hardware at scale.** Unit tests use fake models and fake actions; the end-to-end
  test in CI breaks something harmless (the print spooler) and expects the check to pass. Field reports are welcome.

To report a security problem, see [SECURITY.md](../SECURITY.md).
