# Security policy

Plug'n'Heal runs with administrator rights on other people's computers. We take security reports seriously and
thank everyone who reports a problem responsibly.

## How to report a vulnerability

**Please do not open a public issue.** Report it privately through GitHub:

1. Open <https://github.com/MisterDeeds/plug-n-heal/security/advisories/new>
   (repository page → **Security** → **Report a vulnerability**).
2. Describe what is wrong, how to reproduce it, and what an attacker could do with it.
3. If a log helps, attach only the parts that are needed and remove personal data (computer and user names,
   network details) first.

GitHub explains the process here:
[Privately reporting a security vulnerability](https://docs.github.com/en/code-security/security-advisories/guidance-on-reporting-and-writing-information-about-vulnerabilities/privately-reporting-a-security-vulnerability).

This is a volunteer project without guaranteed response times. We will confirm your report as soon as we can, fix
confirmed problems first, and credit you in the advisory and the [CHANGELOG](CHANGELOG.md) unless you prefer not to
be named.

## Supported versions

| Version | Supported |
|---|---|
| 0.1.x (current development) | yes |

There are no releases yet; reports against the `main` branch are welcome.

## Scope

In scope, for example:

- A way to make Plug'n'Heal change the system **without** the confirmation its rules require, or despite a "No".
- A way around the free-command filter for large models (deny-list `Test-PnhCommandDenied`, read-only check), for
  example a command that is classified as read-only but changes something.
- Text from the computer (event messages, file names, printer names, tool output) that makes the model or the
  agent do something it should not (prompt injection with an effect beyond the offered tools).
- Catalogue actions that delete, weaken a security feature or cannot be undone, contrary to
  [docs/TOOLBOX.md](docs/TOOLBOX.md) section 9.
- Parameter validation that lets a value through which did not come from detection.
- The builder accepting a download whose size or SHA-256 does not match, or writing outside `PlugNHeal\`,
  `START.cmd` and `README.txt` on the target drive.
- The local Ollama server being reachable from the network, or anything being sent off the computer.
- Logs that collect secrets (passwords, keys, BitLocker recovery keys).

Out of scope:

- Vulnerabilities in Ollama, llama.cpp, the models, Windows or other third-party components. Please report them to
  their projects. Tell us too if Plug'n'Heal should react (for example by pinning another Ollama version).
- An attacker who can already change the files on the SSD. Whoever controls the SSD controls what runs. Keep the
  drive in a safe place.
- Wrong repair choices of the AI model that stay within the rules (a reviewed action that does not help). Please
  open a normal [issue](https://github.com/MisterDeeds/plug-n-heal/issues) for those.

## The safety model in short

- The model **chooses**, the script **acts**: the model can only call the tools the agent offers for this run,
  mostly reviewed catalogue actions whose parameters come from read-only detection.
- Every change is backed up first and verified by a script afterwards. A restore point is attempted before the
  first change of a run.
- Risky actions, restarts and anything that deletes need the person's "Yes". Without administrator rights
  Plug'n'Heal only looks.
- Only the largest models may propose free PowerShell. It is parsed, checked against a deny-list (never runs, even
  with "Yes") and against a read-only allow-list; everything else needs a "Yes".
- Plug'n'Heal never disables or bypasses Defender, the firewall, SmartScreen, UAC, BitLocker or device isolation.
- Ollama listens only on `127.0.0.1` on a free port and runs with `OLLAMA_NO_CLOUD=1`. Nothing is sent anywhere.

The full description, including known limits, is in [docs/SAFETY.md](docs/SAFETY.md).
