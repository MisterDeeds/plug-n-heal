# Building a Plug'n'Heal drive

The builder turns an empty external SSD into a Plug'n'Heal drive that later works without internet. There are
two builders with the same result on the drive; on Windows there is also the one-line entry point
`install.ps1` (README, "One line, on Windows"), which downloads the current version from GitHub, runs
the Windows builder with `-NonInteractive` and then `sync-drive.ps1` for the network rescue kit on the same drive
(skip it with `$env:PNH_KIT='no'`).

| Builder | Runs on | Start | How it gets the models |
|---|---|---|---|
| `builder/Build-Drive.ps1` | Windows 10/11 (Windows PowerShell 5.1) | double-click `BUILD.cmd` (wizard) or `BUILD.cmd -NonInteractive ...` | starts Ollama from the drive and lets it pull each model (`POST /api/pull`); models that are not in the Ollama registry are downloaded from Hugging Face (pinned in `builder/hf-models.json`) |
| `builder/build-drive.sh` | Linux, macOS (bash, curl, python3) | `./builder/build-drive.sh <target> [profile]` | downloads manifest and blobs straight from `registry.ollama.ai`, no Ollama needed; models that are not in the Ollama registry are downloaded from Hugging Face (pinned in `builder/hf-models.json`) |

The step-by-step guide for laypeople is in the [README](../README.md#build-your-plugnheal-drive). This page has the
details. The contract is [ARCHITECTURE.md](ARCHITECTURE.md) sections 3.2 and 5.9.

## 1. What you need

- A PC with internet. Windows 10 (version 1803 or later, for the built-in `curl.exe` and `tar.exe`) or Windows 11;
  or Linux or macOS with `bash`, `curl` and `python3`.
- An external SSD formatted with **exFAT** (recommended) or NTFS, with enough free space for the chosen profile:

| Profile | Models | Download | Needed on the drive | Suggested SSD |
|---|---|---|---|---|
| `small` | `qwen3.5:2b`, `qwen3.5:4b` | about 6.9 GB | about 8.1 GB | 16 GB |
| `standard` (default) | + `qwen3.5:9b`, `qwen3.8:27b`, `qwen3.8-27b-abliterated` | about 48.9 GB | about 50.1 GB | 64 GB |
| `full` | + `qwen3.5:9b-q8_0`, `qwen3.6:35b-a3b` | about 82.0 GB | about 83.2 GB | 128 GB |

"Needed on the drive" = models + unpacked runtime (2.26 GB) + a reserve of 512 MiB. While the runtime is being
installed, its ZIP (1.6 GB) is also on the drive for a short time; the space check includes it. Model details:
[MODELS.md](MODELS.md).

Download time depends on your connection: at 100 Mbit/s, `standard` takes roughly 45 minutes and `full` about
1.5 hours, plus the time the SSD needs to write.

## 2. Format the SSD with exFAT

**Formatting erases everything on the SSD.** Copy important files somewhere else first. Plug'n'Heal never formats a
drive itself; it refuses FAT32 (no files over 4 GiB) and explains how to format.

Why exFAT: files larger than 4 GiB are possible (the models are larger), Windows, macOS and Linux can all write it,
and it cannot store Windows' "downloaded from the internet" mark, so files on the drive never carry it. NTFS is also
accepted.

### Windows

1. In File Explorer, right-click the SSD and choose **Format...**.
2. File system: **exFAT**. Volume label: **PLUGNHEAL**. Keep **Quick Format** ticked.
3. Click **Start** and confirm.

Or in PowerShell (replace `E` with the letter of the SSD; check twice):

```powershell
Format-Volume -DriveLetter E -FileSystem exFAT -NewFileSystemLabel PLUGNHEAL
```

### macOS

Disk Utility → **View** → **Show All Devices** → select the SSD (the device, not only the volume) → **Erase** →
Name **PLUGNHEAL**, Format **ExFAT**, Scheme **GUID Partition Map** → **Erase**.

Or in Terminal (find the right `diskN` with `diskutil list` first):

```bash
diskutil list
diskutil eraseDisk ExFAT PLUGNHEAL GPT /dev/diskN
```

### Linux

With GNOME Disks: select the SSD → partition → **Format Partition...** → type **exFAT**, name **PLUGNHEAL**.

Or on the command line with `exfatprogs` (find the right partition with `lsblk` first, and unmount it):

```bash
lsblk -o NAME,SIZE,MODEL,MOUNTPOINT
sudo umount /dev/sdX1
sudo mkfs.exfat -L PLUGNHEAL /dev/sdX1
```

## 3. The Windows builder

### Wizard

Double-click `BUILD.cmd` in the unpacked repository folder. If you downloaded the ZIP from GitHub, unblock it first
(right-click → **Properties** → **Unblock**), see the [README](../README.md#on-windows) for why.

1. **"Which SSD should be prepared?"** The list shows external and removable drives (USB, also USB-attached SSDs
   that report as SCSI). **Show all drives** adds internal ones, for example a Thunderbolt NVMe enclosure. The
   Windows drive itself is never offered.
2. **"How much should go onto the SSD?"** The sizes shown include the runtime and the reserve, and each choice says
   which PCs it helps and which SSD size it needs (16, 64 or 128 GB, computed from the catalogue): *Small* is enough
   without a graphics card and for cards up to 8 GB, *Standard* adds the 9B (cards from 10 GB) and the 27B (24 GB
   cards), *Full* only helps PCs with a 16 or 20 GB card. A choice that does not fit is reported. Space already used
   by an earlier, interrupted build counts as available.
3. **"Building the SSD"** shows one progress bar for all downloads, with the remaining time. The PC is kept awake.
   **Cancel** stops the build; the next start continues where it stopped.

### Without a window

```bat
BUILD.cmd -NonInteractive -Drive E: -Profile standard
```

| Parameter | Meaning |
|---|---|
| `-NonInteractive` | no window; progress goes to the console |
| `-Drive` | drive letter (`E`, `E:` or `E:\`), or an existing folder for tests |
| `-Profile` | `small`, `standard` (default) or `full` |
| `-Language` | `de` or `en` (default: Windows display language) |
| `-Catalog` | another `models.json` (tests) |

Exit codes: `0` done, `1` failed (run again to resume), `2` refused (usage, FAT32, not enough space, catalogue), `3`
cancelled.

### What it does, in order

1. **Checks:** `builder/versions.json` and `src/catalog/models.json` are valid; the drive is not the Windows drive,
   is ready and uses exFAT or NTFS.
2. **Model sizes:** fetches each model's manifest from the registry and refuses to build when the size differs from
   the catalogue by more than 1 % ("Please use a newer Plug'n'Heal version"). A model with `"source": "huggingface"`
   is not in the registry: its files are pinned by size and SHA-256 in `builder/hf-models.json`, and the builder
   builds the manifest from the pin (the pinned metadata blobs in `builder/hf-models/` must match the pin, or the
   build is refused with exit code 2).
3. **Space:** remaining runtime download + unpacked runtime + missing model blobs (minus partial downloads already on
   the drive) + 512 MiB must fit into the free space.
4. **Runtime:** downloads the pinned `ollama-windows-amd64.zip` with `curl.exe` into `PlugNHeal\downloads\`. Every
   attempt is a new `curl -L -C -` call (fresh redirect, resume from the bytes on disk), up to 100 attempts. Then it
   checks size and SHA-256 against `versions.json`, unpacks with `tar.exe` (fallback `Expand-Archive`) into
   `PlugNHeal\runtime\ollama\`, writes the marker `runtime.json` and deletes the ZIP.
5. **App:** copies `src\` to `PlugNHeal\app\` (files that no longer exist in `src\` are removed there) and
   `src\START.cmd` to the root of the drive. Then it removes the Mark-of-the-Web ("downloaded from the internet")
   from everything under `PlugNHeal\` and from `START.cmd` (`Unblock-File`). On NTFS this matters when the repository
   ZIP was not unblocked; exFAT cannot store the mark, so there it changes nothing. A failure is logged, never fatal.
6. **Models:** starts `ollama.exe serve` from the drive on `127.0.0.1` with `OLLAMA_MODELS` on the drive and
   `OLLAMA_NOPRUNE=1`, and pulls every missing model. Ollama resumes interrupted downloads and verifies each blob's
   digest. The Hugging Face models are downloaded straight from the pinned URLs (resume, SHA-256), and their
   manifest is written into `models/manifests/` afterwards.
7. **Verification:** every blob of every manifest must be present with the size the manifest states.
8. **Finish:** writes the licences, `drive.json` and `README.txt`, and removes the empty `downloads` folder.

The builder writes only `<drive>\PlugNHeal\`, `<drive>\START.cmd` and `<drive>\README.txt`. Every path is checked
before it is written. Other files on the SSD stay untouched.

The build log is on the drive: `PlugNHeal\logs\build-<PC name>-<date>-<time>\build.log` (and `ollama-serve.log`).

## 4. The Linux and macOS builder

```bash
./builder/build-drive.sh <target-dir> [small|standard|full] [--catalog FILE] [--verify]
```

| Argument | Meaning |
|---|---|
| `<target-dir>` | root of the mounted SSD, for example `/media/$USER/PLUGNHEAL` or `/Volumes/PLUGNHEAL` |
| profile | `small`, `standard` (default) or `full` |
| `--verify` | also re-hash the blobs that are already on the drive (slow; finds corrupted files) |
| `--catalog FILE` | another `models.json` (tests) |
| `PNH_MAX_ATTEMPTS` | environment variable: download attempts per file (default 50) |

Exit codes: `0` done, `1` failed (re-run to resume), `2` refused (usage, FAT32, missing catalogue, not enough space),
`130` interrupted.

What it does differently from the Windows builder: it never runs Ollama. It downloads each model's manifest and
blobs straight from `registry.ollama.ai` with `curl -C -`, checks the SHA-256 of every blob before moving it into
`models/blobs/`, and writes the manifests last, unchanged, to
`models/manifests/registry.ollama.ai/library/<name>/<tag>`. This is the layout Ollama 0.40.15 reads offline. The
file system check refuses FAT32 and warns about anything that is not exFAT or NTFS.

A model with `"source": "huggingface"` is handled the same way: its manifest is built from the pin
(`builder/hf-models.json`), the small Ollama metadata blobs are copied from `builder/hf-models/`, and the
GGUF files are downloaded from the pinned Hugging Face URLs (resume, SHA-256; the SHA-256 is the repository's
Git-LFS object id, so the download is verified by its content).

`build-drive.sh` has no automated tests yet and has not been tried on macOS. Please report how it went.

## 5. Interrupted? Run it again

Both builders are safe to re-run with the same arguments:

- Complete parts are skipped: the runtime (when `runtime.json` matches the pinned version and SHA-256) and complete
  models (all blobs present with the right size).
- Partial downloads continue where they stopped.
- To force a fresh runtime (for example after an antivirus removed a file), delete the folder `PlugNHeal\runtime`
  and run the builder again.
- To check existing model files thoroughly, use `build-drive.sh ... --verify`.

## 6. What ends up on the drive

```
X:\START.cmd                     the only file a user clicks
X:\README.txt                    short instructions in German and English, with build date, profile and models
X:\PlugNHeal\app\                copy of src\ (Start.ps1, Ui.ps1, lib\, toolbox\, i18n\, ...)
X:\PlugNHeal\runtime\ollama\     unpacked ollama-windows-amd64.zip (ollama.exe, lib\ollama\...)
X:\PlugNHeal\runtime\runtime.json  marker: Ollama version, asset, SHA-256, time of extraction
X:\PlugNHeal\models\blobs\       model files, named sha256-<hex>
X:\PlugNHeal\models\manifests\   registry.ollama.ai\library\<name>\<tag>
X:\PlugNHeal\home\               USERPROFILE/HOME of the Ollama process (Ollama keeps its key pair here)
X:\PlugNHeal\logs\               build logs, and later one folder per run
X:\PlugNHeal\licenses\           THIRD-PARTY-NOTICES.md, ollama-LICENSE.txt, runtime\*.txt, models\*.LICENSE.txt
X:\PlugNHeal\drive.json          build manifest
```

`drive.json` example:

```json
{
  "builtAt": "2026-11-09T21:48:00Z",
  "builder": "plug-n-heal 0.1.0",
  "ollama": "0.40.15",
  "profile": "standard",
  "models": [
    { "id": "qwen3.5-2b", "tag": "qwen3.5:2b-q4_K_M", "bytes": 1945781358 }
  ]
}
```

Nothing of this is installed on the PC that builds the drive.

## 7. Updating a drive

Run the builder of a newer Plug'n'Heal version on the same drive. It replaces `PlugNHeal\app\` with the new `src\`,
replaces the runtime when the pinned Ollama version changed, and adds models that are missing for the chosen
profile. Models that are already on the drive stay there, also when they are not part of the profile. Logs stay.

To go from `standard` to `full`, run the builder again and choose `full`: only the two extra models are downloaded.

## 8. Why you can trust the downloads

- The runtime version, URL, size and SHA-256 are pinned in [`builder/versions.json`](../builder/versions.json); a
  mismatch stops the build.
- Model sizes must match the catalogue within 1 %. Blob digests are verified by Ollama (Windows builder) or by the
  script itself (Linux/macOS builder).
- Downloads use HTTPS from the original sources only: GitHub releases of Ollama and the Ollama registry.
- There are no Plug'n'Heal release packages yet. Get the code from the GitHub repository.

## 9. Builder problems

| Message | What to do |
|---|---|
| "No external SSD found" | Plug it in, click **Refresh list**, or **Show all drives** |
| "This SSD is formatted with FAT32 and must first be formatted with exFAT." | [Format it with exFAT](#2-format-the-ssd-with-exfat) |
| "This is the Windows drive." | Pick the external SSD |
| "Not enough space on the SSD" | Choose a smaller profile or a larger SSD |
| "The size of ... does not match the model list" | A model changed on the registry; use a newer Plug'n'Heal version |
| "The model server cannot be reached" | Check the internet connection, proxy or firewall, then run again |
| "The download failed after ... attempts" / "Unpacking failed" | Run again; it resumes. If it repeats, see the build log |
| "Ollama could not be started from the SSD" | An antivirus may have blocked or removed a file; see `ollama-serve.log` in the build log folder |
| Windows warns or blocks `BUILD.cmd` | Unblock the ZIP before unpacking (Properties → Unblock), then unpack again |
