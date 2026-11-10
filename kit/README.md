# Network rescue kit

A free-running local AI agent for one hard case: **a Windows PC that has lost its network connection**.

It is the direct tool next to the guided Plug'n'Heal app. The app lets a model choose from a catalogue of reviewed
repair steps. The kit gives a large local model a real command line with administrator rights and a clear mission,
and a harness that does not let it stop before the network works.

> [!CAUTION]
> **The agent runs commands on its own, as administrator, without asking.** It follows strict written rules (below),
> but it is an AI model and can be wrong. Use the kit on your own PC, when you understand that risk, and when the
> normal ways have failed. Not for a computer of your employer or school.

## Prepare or update the drive

On any Windows 10/11 PC with internet: plug in the drive, open PowerShell and paste

```powershell
irm -UseBasicParsing https://raw.githubusercontent.com/MisterDeeds/plug-n-heal/main/sync-drive.ps1 | iex
```

The command lists the drives, asks for the letter of your drive and then does everything by itself:

| Part | Size | When it is downloaded |
|---|---|---|
| Kit files (scripts, instructions) | < 1 MB | every time, so the drive always has the current version |
| Ollama runtime 0.40.15 | 1.6 GB download, 2.3 GB on the drive | only when missing |
| Codex CLI 0.167.0 (the agent program) | 0.2 GB | only when missing |
| Language model `qwen3.8:27b` | 17.7 GB | only when missing or incomplete; an interrupted download resumes |

Run the same command again whenever you want to update the drive. Nothing is deleted, and nothing outside the
folder `AI` on the drive is touched (a drive prepared with an early version keeps its folder `KI`).

With parameters:

```powershell
& ([scriptblock]::Create((irm -UseBasicParsing https://raw.githubusercontent.com/MisterDeeds/plug-n-heal/main/sync-drive.ps1))) -Drive E -Notes 'No network since Monday morning, on cable and on Wi-Fi.'
```

| Parameter | Meaning |
|---|---|
| `-Drive E` | drive letter, instead of being asked |
| `-Notes '...'` | facts about the fault for the agent; saved as `work\NOTES.md` |
| `-Model <tag>` | another Ollama model that can call tools, for example `qwen3.5:9b-q4_K_M` (6.6 GB) for a graphics card with 8 to 12 GB |
| `-Effort xhigh` | how hard the model thinks before each step: `low`, `medium` or `xhigh` (the default of the kit). `qwen3.8` on its own would use `medium`. Higher is slower per step and more careful. |
| `-Ref <branch, tag or commit>` | take the kit files from another version of this repository |

The drive must be exFAT or NTFS (FAT32 cannot hold files over 4 GB) and needs about 25 GB of free space.

## Use it

1. Plug the drive into the PC with the problem.
2. Open the drive and double-click `AI\Start-Repair.cmd`. Answer the Windows question with **Yes**.
3. The first time it asks you to describe the problem in a sentence or two. You may just press Enter.
4. Watch. Every line has a time stamp:

```
[06:10:23] AI: I am checking which filters block the network traffic.
[06:10:23] COMMAND: powershell ... find-blockers.ps1
[06:10:36]   -> result (exit 0): MDE verdict: NOT_ONBOARDED | ...
```

The window title shows the round, the run time and the last status. When the model thinks for a long time, a
"still working" line appears every 45 seconds.

It ends in one of three ways:

- **SOLVED**: the network check passed.
- **RESTART**: a repair needs a reboot. Restart, double-click `Start-Repair.cmd` again, and it continues.
- **STOPPED**: the agent is blocked and explains why and what a person must do, for example when the PC was
  isolated by Microsoft Defender for Endpoint. That can only be lifted in the Defender portal.

Speed: `qwen3.8:27b` wants a graphics card with 24 GB of memory. On smaller cards it still runs but slowly.

## How it works

| File on the drive | Job |
|---|---|
| `Start-Repair.cmd` | asks for administrator rights and starts `agent.ps1` |
| `agent.ps1` | the harness: runs the check, starts one agent round after the other, shows live status |
| `tools\check-network.ps1` | read-only check: TCP to the internet, DNS, gateway ping, adapters. Exit code 0 = the network works |
| `tools\find-blockers.ps1` | read-only deep diagnosis: what inside Windows blocks traffic (WFP filters by provider, Defender for Endpoint isolation evidence, foreign adapter bindings and drivers, firewall profiles, IPsec, Winsock, security and VPN software, changes since yesterday) |
| `AGENTS.md` | the mission for the model: how to read the check, how to work, the repair playbook, the hard rules |
| `work\` | everything a run writes: `protocol.md` (the agent's memory), `status.log`, `round-N.jsonl`, `report-*.txt`, backups |

- **The harness decides, not the model.** Only `check-network.ps1` with exit code 0 ends the job. When the model
  ends its turn while the check still fails, the next round starts by itself, up to 30 rounds.
- **Every round is a fresh session** that gets the current check output, your notes and the last part of
  `protocol.md`. The harness also writes into the protocol what the agent really ran, so the memory does not depend
  on the model's own notes.
- **Everything stays on the drive.** Nothing is sent anywhere.

## The rules the agent works under

From `AGENTS.md`:

- never delete user data
- never disable, uninstall, weaken or bypass Microsoft Defender, Defender for Endpoint, BitLocker, Secure Boot or
  device isolation
- never reset the firewall, never format or repartition disks
- one change at a time, old state saved first, check after every change, undo what did not help
- uninstall a product only with evidence that its filters block the traffic; never Microsoft software, hardware
  drivers or remote support agents

These rules are instructions to a language model, not a technical lock. That is the difference to the Plug'n'Heal
app, where the model cannot leave the catalogue.

## Status

| What | Tested how |
|---|---|
| `sync-drive.ps1` on a fresh drive and a second run that downloads nothing | on every change, on GitHub's Windows runner (Windows PowerShell 5.1), with a small model |
| `check-network.ps1`, `find-blockers.ps1` | on a real Windows 11 PC and on the Windows runner |
| Harness: rounds, live status, stops only after the check passes | on a real Windows 11 PC with a stand-in agent, and on Linux with the real Codex CLI and a small model |
| A real repair of a broken network with `qwen3.8:27b` | **not proven yet** |
