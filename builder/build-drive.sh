#!/usr/bin/env bash
# Plug'n'Heal builder for Linux and macOS (bash + curl + python3).
#
#   ./builder/build-drive.sh <target-dir> [small|standard|full] [--catalog FILE] [--verify]
#
# <target-dir> is the root of the mounted SSD (exFAT recommended, for example /media/$USER/PLUGNHEAL or
# /Volumes/PLUGNHEAL). The result is the same drive layout Build-Drive.ps1 produces (docs/ARCHITECTURE.md 3.2):
#
#   <target>/START.cmd, <target>/README.txt
#   <target>/PlugNHeal/app/              copy of src/
#   <target>/PlugNHeal/runtime/ollama/   extracted ollama-windows-amd64.zip (pinned in builder/versions.json)
#   <target>/PlugNHeal/models/           blobs/sha256-<hex> and manifests/registry.ollama.ai/<ns>/<name>/<tag>
#   <target>/PlugNHeal/home/, licenses/, drive.json
#
# Ollama is not run here: models come straight from the registry (manifest + blobs, every blob sha256-verified),
# the layout Ollama 0.40.15 reads offline (docs/research/technik.md 6.2, "Weg B").
# Re-running skips what is complete and resumes partial downloads (curl -C -, fresh redirect per attempt).
# Writes only <target>/PlugNHeal/, <target>/START.cmd and <target>/README.txt. Never formats anything.
#
# Exit codes: 0 done, 1 failed (re-run to resume), 2 refused (usage, FAT32, missing catalogue, not enough space).

set -euo pipefail
umask 022

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
VERSIONS_FILE="$SCRIPT_DIR/versions.json"
TEMPLATE_FILE="$SCRIPT_DIR/README.txt.template"
CATALOG_FILE="$REPO_ROOT/src/catalog/models.json"
SRC_DIR="$REPO_ROOT/src"
PROFILE=standard
TARGET=""
VERIFY=0
MAX_ATTEMPTS=${PNH_MAX_ATTEMPTS:-50}

WORK=""
CURL_PID=""
PROGRESS_OPEN=0
LAST_PRINT=0
DL_START=0
DONE=0
TOTAL=0

usage() {
  cat <<'EOF'
Usage: ./builder/build-drive.sh <target-dir> [small|standard|full] [--catalog FILE] [--verify]

  <target-dir>   root of the mounted SSD (exFAT or NTFS; FAT32 is refused)
  profile        small | standard (default) | full, as defined in src/catalog/models.json
  --catalog FILE use another model catalogue (tests)
  --verify       re-hash blobs that are already on the drive

Re-run the same command after an interruption: finished parts are kept, partial downloads resume.
EOF
}

say() { progress_break; printf '%s\n' "$*"; }
warn() { progress_break; printf 'WARNING: %s\n' "$*" >&2; }
die() { progress_break; printf '\nERROR: %s\nRe-run the same command to resume.\n' "$*" >&2; exit 1; }
refuse() { progress_break; printf '\nREFUSED: %s\n' "$*" >&2; exit 2; }

cleanup() {
  if [[ -n $CURL_PID ]] && kill -0 "$CURL_PID" 2>/dev/null; then kill "$CURL_PID" 2>/dev/null || true; fi
  if [[ -n $WORK && -d $WORK ]]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT
trap 'progress_break; printf "\nInterrupted. Re-run the same command to resume.\n" >&2; exit 130' INT TERM

# ---------------------------------------------------------------------------------------------------------------------
# python3 helper (JSON, sha256, zip, mirror copy, README/drive.json). Run isolated (-I): nothing from cwd is imported.
# ---------------------------------------------------------------------------------------------------------------------
IFS= read -r -d '' PY_HELPER <<'PY' || true
import hashlib, json, os, re, shlex, shutil, subprocess, sys, zipfile

NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
DIGEST_RE = re.compile(r"^sha256:([0-9a-f]{64})$")


def die(msg, code=1):
    sys.stderr.write("ERROR: %s\n" % msg)
    sys.exit(code)


def load_json(path, what):
    try:
        with open(path, "rb") as f:
            return json.loads(f.read().decode("utf-8-sig"))
    except FileNotFoundError:
        die("%s not found: %s" % (what, path), 2)
    except (ValueError, UnicodeDecodeError) as e:
        die("%s is not valid JSON (%s): %s" % (what, e, path), 2)


def write_atomic(path, data):
    tmp = path + ".pnh-tmp"
    with open(tmp, "wb") as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def split_tag(tag):
    name, t = tag, "latest"
    i, s = tag.rfind(":"), tag.rfind("/")
    if i > s:
        name, t = tag[:i], tag[i + 1:]
    ns = "library"
    if "/" in name:
        parts = name.split("/")
        if len(parts) != 2:
            die("unsupported model name (only registry.ollama.ai models): %s" % tag, 2)
        ns, name = parts
    for p in (ns, name, t):
        if not NAME_RE.match(p):
            die("invalid model tag: %s" % tag, 2)
    return ns, name, t


def manifest_entries(m, path="manifest"):
    if not isinstance(m, dict) or not isinstance(m.get("config"), dict) or not isinstance(m.get("layers"), list):
        die("not an Ollama manifest: %s" % path)
    out = []
    for e in [m["config"]] + m["layers"]:
        mt = DIGEST_RE.match(str(e.get("digest", "")))
        size = e.get("size")
        if not mt or not isinstance(size, int) or size < 0:
            die("bad layer in manifest %s: %r" % (path, e))
        out.append((mt.group(1), size, str(e.get("mediaType", ""))))
    return out


def blob_complete(blobs, hexd, size):
    p = os.path.join(blobs, "sha256-" + hexd)
    return os.path.isfile(p) and os.path.getsize(p) == size


def fmt_gb(b):
    return "%.1f GB" % (b / 1e9)


def safe_tag(tag):
    return tag.replace("/", "_").replace(":", "_")


def cmd_versions(path):
    v = load_json(path, "builder/versions.json")
    o, r = v["ollama"], v["registry"]
    if not re.match(r"^[0-9a-f]{64}$", str(o["sha256"]).lower()) or int(o["size"]) <= 0:
        die("versions.json: ollama.sha256/size invalid", 2)
    vals = {
        "PNH_NAME": v["builder"]["name"], "PNH_VERSION": v["builder"]["version"],
        "OLLAMA_VERSION": o["version"], "OLLAMA_ASSET": o["asset"], "OLLAMA_URL": o["url"],
        "OLLAMA_SIZE": int(o["size"]), "OLLAMA_SHA256": str(o["sha256"]).lower(),
        "OLLAMA_EXTRACTED": int(o.get("extractedBytes") or 0), "OLLAMA_LICENSE_URL": o["licenseUrl"],
        "REGISTRY_URL": str(r["url"]).rstrip("/"), "REGISTRY_HOST": r["host"],
        "MANIFEST_ACCEPT": r["manifestAccept"], "RESERVE_BYTES": int(v.get("reserveBytes") or 0),
        "SIZE_TOLERANCE": float(v.get("sizeTolerancePercent") or 1),
    }
    for k, val in vals.items():
        print("%s=%s" % (k, shlex.quote(str(val))))


def cmd_profile(catalog, profile):
    c = load_json(catalog, "model catalogue (src/catalog/models.json)")
    models, profiles = c.get("models"), c.get("profiles")
    if not isinstance(models, list) or not models:
        die("model catalogue has no 'models' list: %s" % catalog, 2)
    if not isinstance(profiles, dict):
        die("model catalogue has no 'profiles' object {small, standard, full}: %s" % catalog, 2)
    # a profile is a list of model ids/tags, or an object with such a list under "models"
    pdef = profiles.get(profile)
    refs = pdef.get("models") if isinstance(pdef, dict) else pdef
    if not isinstance(refs, list):
        die("profile '%s' is not defined in %s (defined: %s)" % (profile, catalog, ", ".join(sorted(profiles))), 2)
    by_id, by_tag = {}, {}
    for m in models:
        if not isinstance(m, dict) or not isinstance(m.get("id"), str) or not isinstance(m.get("tag"), str):
            die("model catalogue entry without id/tag: %r" % (m,), 2)
        by_id[m["id"]] = m
        by_tag[m["tag"]] = m
    seen, out = set(), []
    for ref in refs:
        m = by_id.get(ref) or by_tag.get(ref)
        if m is None:
            die("profile '%s' lists unknown model '%s'" % (profile, ref), 2)
        if m["tag"] in seen:
            continue
        seen.add(m["tag"])
        split_tag(m["tag"])
        out.append("%s\t%s\t%d" % (m["id"], m["tag"], int(m.get("bytes") or 0)))
    if not out:
        die("profile '%s' is empty" % profile, 2)
    print("\n".join(out))


def cmd_tagpath(tag):
    print("\t".join(split_tag(tag)))


def cmd_entries(path):
    for hexd, size, mt in manifest_entries(load_json(path, "manifest"), path):
        print("%s\t%d\t%s" % (hexd, size, mt))


def cmd_sizecheck(expected, actual, tol):
    expected, actual, tol = int(expected), int(actual), float(tol)
    if expected <= 0:
        sys.exit(0)
    sys.exit(0 if abs(actual - expected) * 100.0 <= expected * tol else 1)


def cmd_sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            b = f.read(4 << 20)
            if not b:
                break
            h.update(b)
    print(h.hexdigest())


def cmd_zipsize(path):
    with zipfile.ZipFile(path) as z:
        print(sum(i.file_size for i in z.infolist()))


def cmd_unzip(path, dest):
    dest = os.path.abspath(dest)
    os.makedirs(dest, exist_ok=True)
    with zipfile.ZipFile(path) as z:
        infos = z.infolist()
        total = sum(i.file_size for i in infos)
        done = last = 0
        for info in infos:
            name = info.filename.replace("\\", "/")
            parts = [p for p in name.split("/") if p not in ("", ".")]
            if not parts:
                continue
            if name.startswith("/") or ".." in parts or ":" in parts[0]:
                die("unsafe path in archive: %r" % info.filename)
            target = os.path.join(dest, *parts)
            if name.endswith("/"):
                os.makedirs(target, exist_ok=True)
                continue
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with z.open(info) as src, open(target, "wb") as dst:
                shutil.copyfileobj(src, dst, 1 << 20)
            done += info.file_size
            if done - last >= 250_000_000 or done == total:
                print("  extracted %s of %s" % (fmt_gb(done), fmt_gb(total)), flush=True)
                last = done


def cmd_mirror(src, dest):
    src, dest = os.path.abspath(src), os.path.abspath(dest)
    keep_files, copied = set(), 0
    os.makedirs(dest, exist_ok=True)
    for root, dirs, files in os.walk(src):
        rel = os.path.relpath(root, src)
        tdir = dest if rel == "." else os.path.join(dest, rel)
        for f in files:
            os.makedirs(tdir, exist_ok=True)
            t = os.path.join(tdir, f)
            shutil.copyfile(os.path.join(root, f), t)  # content only: exFAT has no permission bits
            keep_files.add(t)
            copied += 1
    removed = 0
    for root, dirs, files in os.walk(dest, topdown=False):
        for f in files:
            p = os.path.join(root, f)
            if p not in keep_files:
                os.remove(p)
                removed += 1
        for d in dirs:
            try:
                os.rmdir(os.path.join(root, d))  # only succeeds for empty directories
            except OSError:
                pass
    print("  %d files copied, %d stale files removed" % (copied, removed))


def cmd_marker_ok(path, version, sha):
    try:
        m = load_json(path, "runtime marker")
    except SystemExit:
        sys.exit(1)
    sys.exit(0 if m.get("ollama") == version and str(m.get("sha256", "")).lower() == sha.lower() else 1)


def cmd_write_marker(path, version, sha, asset, at):
    doc = {"ollama": version, "asset": asset, "sha256": sha, "extractedAt": at}
    write_atomic(path, (json.dumps(doc, indent=2) + "\n").encode("utf-8"))


def cmd_installed(catalog, models_dir, host):
    c = load_json(catalog, "model catalogue")
    blobs = os.path.join(models_dir, "blobs")
    for m in c.get("models", []):
        ns, name, t = split_tag(m["tag"])
        mp = os.path.join(models_dir, "manifests", host, ns, name, t)
        if not os.path.isfile(mp):
            continue
        ents = manifest_entries(load_json(mp, "manifest"), mp)
        if all(blob_complete(blobs, h, s) for h, s, _ in ents):
            # Ollama's own manifests list a copy of the registry manifest as a layer: not part of the model size
            size = sum(s for _, s, mt in ents if not mt.endswith("distribution.manifest.v2+json"))
            print("%s\t%s\t%d" % (m["id"], m["tag"], size))


def cmd_missing(manifest, blobs):
    bad = [h for h, s, _ in manifest_entries(load_json(manifest, "manifest"), manifest)
           if not blob_complete(blobs, h, s)]
    print(" ".join(bad))
    sys.exit(1 if bad else 0)


def cmd_licenses(manifest, blobs, tag, out_dir):
    texts = []
    for h, s, mt in manifest_entries(load_json(manifest, "manifest"), manifest):
        if mt.endswith(".license"):
            with open(os.path.join(blobs, "sha256-" + h), "rb") as f:
                texts.append(f.read().decode("utf-8", "replace").strip())
    if not texts:
        print("none")
        return
    os.makedirs(out_dir, exist_ok=True)
    head = "Licence of the model %s (from its Ollama registry manifest)\n\n" % tag
    body = head + ("\n\n" + "-" * 70 + "\n\n").join(texts) + "\n"
    write_atomic(os.path.join(out_dir, safe_tag(tag) + ".LICENSE.txt"), body.replace("\r\n", "\n").encode("utf-8"))
    print(safe_tag(tag) + ".LICENSE.txt")


def read_tsv(path):
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if line:
                i, tag, b = line.split("\t")
                rows.append((i, tag, int(b)))
    return rows


def cmd_readme(template, out, built_at, builder, ollama, profile, models_tsv):
    with open(template, encoding="utf-8-sig") as f:
        tpl = f.read()
    rows = read_tsv(models_tsv)
    vals = {
        "BUILT_AT": built_at, "BUILDER": builder, "OLLAMA_VERSION": ollama, "PROFILE": profile,
        "MODELS": "\n".join("  - %s  (%s)" % (tag, fmt_gb(b)) for _, tag, b in rows) or "  -",
    }
    for k, v in vals.items():
        tpl = tpl.replace("{{%s}}" % k, v)
    text = "\r\n".join(tpl.splitlines()) + "\r\n"
    write_atomic(out, b"\xef\xbb\xbf" + text.encode("utf-8"))


def cmd_drivejson(out, built_at, builder, ollama, profile, models_tsv):
    doc = {
        "builtAt": built_at, "builder": builder, "ollama": ollama, "profile": profile,
        "models": [{"id": i, "tag": tag, "bytes": b} for i, tag, b in read_tsv(models_tsv)],
    }
    write_atomic(out, (json.dumps(doc, indent=2) + "\n").encode("utf-8"))


def cmd_fstype(path):
    p = os.path.realpath(path)
    best_mp, best_fs = "", "unknown"
    try:
        if sys.platform.startswith("linux"):
            with open("/proc/self/mountinfo", encoding="utf-8", errors="replace") as f:
                for line in f:
                    fields = line.split()
                    sep = fields.index("-")
                    mp = re.sub(r"\\([0-7]{3})", lambda x: chr(int(x.group(1), 8)), fields[4])
                    if (p == mp or p.startswith(mp.rstrip("/") + "/")) and len(mp) >= len(best_mp):
                        best_mp, best_fs = mp, fields[sep + 1]
        elif sys.platform == "darwin":
            out = subprocess.run(["/sbin/mount"], capture_output=True, text=True).stdout
            for line in out.splitlines():
                m = re.match(r"^.* on (.*) \(([^,)]+)", line)
                if m and (p == m.group(1) or p.startswith(m.group(1).rstrip("/") + "/")) and len(m.group(1)) >= len(best_mp):
                    best_mp, best_fs = m.group(1), m.group(2)
    except (OSError, ValueError):
        pass
    print(best_fs.lower())


CMDS = {
    "versions": cmd_versions, "profile": cmd_profile, "tagpath": cmd_tagpath, "entries": cmd_entries,
    "sizecheck": cmd_sizecheck, "sha256": cmd_sha256, "zipsize": cmd_zipsize, "unzip": cmd_unzip,
    "mirror": cmd_mirror, "marker-ok": cmd_marker_ok, "write-marker": cmd_write_marker,
    "installed": cmd_installed, "missing": cmd_missing, "licenses": cmd_licenses, "readme": cmd_readme,
    "drivejson": cmd_drivejson, "fstype": cmd_fstype,
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in CMDS:
        die("internal: unknown helper command %r" % sys.argv[1:2])
    CMDS[sys.argv[1]](*sys.argv[2:])
PY

py() { python3 -I -c "$PY_HELPER" "$@"; }

# ---------------------------------------------------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------------------------------------------------
fsize() { # size of a file in bytes, 0 if missing (GNU and BSD stat)
  if [[ -f $1 ]]; then stat -c %s "$1" 2>/dev/null || stat -f %z "$1"; else echo 0; fi
}

gb() { awk -v b="$1" 'BEGIN { printf "%.1f GB", b / 1e9 }'; }

now_utc() { date -u +%Y-%m-%dT%H:%M:%SZ; }

progress_break() {
  if [[ $PROGRESS_OPEN == 1 ]]; then printf '\n'; PROGRESS_OPEN=0; fi
}

# progress <bytes done in total> <label>: one overall line, GB done/total, speed and remaining time in plain words
progress() {
  local now line
  now=$(date +%s)
  if [[ ! -t 1 ]] && (( now - LAST_PRINT < 10 )); then return 0; fi
  LAST_PRINT=$now
  line=$(awk -v d="$1" -v t="$TOTAL" -v e="$((now - DL_START))" -v l="$2" 'BEGIN {
    pct = (t > 0) ? int(d * 100 / t) : 100
    rate = (e > 0) ? d / e : 0
    if (rate <= 0 || e < 3) eta = "estimating time left"
    else {
      left = (t - d) / rate
      if (left < 60) eta = "less than a minute left"
      else if (left < 5400) eta = sprintf("about %d min left", int((left + 59) / 60))
      else eta = sprintf("about %d h %d min left", int(left / 3600), int((left - int(left / 3600) * 3600) / 60))
    }
    printf "%s  %.2f / %.2f GB (%d%%)  %.1f MB/s  %s", l, d / 1e9, t / 1e9, pct, rate / 1e6, eta }')
  if [[ -t 1 ]]; then printf '\r\033[K%s' "$line"; PROGRESS_OPEN=1; else printf '%s\n' "$line"; fi
}

# fetch_file <url> <dest> <expected size> <label>
# Retry loop in the shell, not curl --retry: every attempt is a fresh curl -L -C - (new signed redirect, resume).
fetch_file() {
  local url=$1 dest=$2 size=$3 label=$4
  local base=$DONE start have attempt=0 rc wait_s
  start=$(fsize "$dest")
  while :; do
    have=$(fsize "$dest")
    if (( have >= size )); then break; fi
    attempt=$((attempt + 1))
    if (( attempt > MAX_ATTEMPTS )); then die "download failed after $MAX_ATTEMPTS attempts: $url"; fi
    curl -L --fail -C - -sS --connect-timeout 30 --speed-limit 1024 --speed-time 60 -A "$UA" \
      -o "$dest" "$url" 2>"$WORK/curl.err" &
    CURL_PID=$!
    while kill -0 "$CURL_PID" 2>/dev/null; do
      progress $((base + $(fsize "$dest") - start)) "$label"
      sleep 1
    done
    rc=0
    wait "$CURL_PID" || rc=$?
    CURL_PID=""
    if (( rc != 0 )); then
      wait_s=$((attempt * 5)); if (( wait_s > 60 )); then wait_s=60; fi
      warn "curl exit $rc ($(tail -n 1 "$WORK/curl.err" 2>/dev/null)), attempt $attempt, next try in ${wait_s}s"
      if (( rc == 33 )); then rm -f "$dest"; start=0; fi  # server refused the range: start this file over
      sleep "$wait_s"
    fi
  done
  have=$(fsize "$dest")
  if (( have != size )); then
    rm -f "$dest"
    die "$label: got $have bytes, expected $size (file removed, will be fetched again)"
  fi
  DONE=$((base + size - start))
  progress "$DONE" "$label"
}

# fetch_small <url> <dest> [accept]: small files (manifests, licence) with a few retries; 404 ends at once
fetch_small() {
  local url=$1 dest=$2 accept=${3:-} attempt code
  for attempt in 1 2 3 4 5; do
    code=$(curl -sS -L --connect-timeout 30 --max-time 300 -A "$UA" ${accept:+-H "Accept: $accept"} \
      -o "$dest.pnh-tmp" -w '%{http_code}' "$url" 2>"$WORK/curl.err") || code="curl"
    if [[ $code == 200 ]]; then mv -f "$dest.pnh-tmp" "$dest"; return 0; fi
    rm -f "$dest.pnh-tmp"
    if [[ $code == 404 ]]; then return 4; fi
    warn "GET $url: $code $(tail -n 1 "$WORK/curl.err" 2>/dev/null), attempt $attempt"
    sleep $((attempt * 3))
  done
  return 1
}

explain_fat32() {
  cat >&2 <<'EOF'
The target is formatted with FAT32. FAT32 cannot store files larger than 4 GB, and the language models are larger.
Format the SSD with exFAT first (this ERASES everything on it; copy important files away before):
  Windows: Explorer > right-click the drive > Format... > File system: exFAT, Volume label: PLUGNHEAL > Start
  macOS:   Disk Utility > select the SSD > Erase > Format: ExFAT, Name: PLUGNHEAL
  Linux:   for example GNOME Disks > Format Partition > exFAT, or: mkfs.exfat -L PLUGNHEAL /dev/sdX1
The builder never formats a drive by itself.
EOF
}

# ---------------------------------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------------------------------
main() {
  local positional=()
  while (($#)); do
    case $1 in
      -h|--help) usage; exit 0 ;;
      --catalog) [[ $# -ge 2 ]] || { usage >&2; exit 2; }; CATALOG_FILE=$2; shift 2 ;;
      --catalog=*) CATALOG_FILE=${1#--catalog=}; shift ;;
      --verify) VERIFY=1; shift ;;
      -*) printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
      *) positional+=("$1"); shift ;;
    esac
  done
  if (( ${#positional[@]} < 1 || ${#positional[@]} > 2 )); then usage >&2; exit 2; fi
  TARGET=${positional[0]}
  if (( ${#positional[@]} == 2 )); then PROFILE=${positional[1]}; fi
  case $PROFILE in small|standard|full) ;; *) refuse "unknown profile '$PROFILE' (small, standard or full)" ;; esac

  command -v curl >/dev/null 2>&1 || refuse "curl is missing"
  command -v python3 >/dev/null 2>&1 || refuse "python3 is missing"
  [[ -d $TARGET ]] || refuse "target directory does not exist: $TARGET (mount the SSD first)"
  TARGET=$(cd "$TARGET" && pwd)
  [[ -f $CATALOG_FILE ]] || refuse "model catalogue not found: $CATALOG_FILE
The builder takes the model list from src/catalog/models.json (docs/ARCHITECTURE.md 5.3). Use --catalog FILE for another one."
  [[ -f $SRC_DIR/START.cmd ]] || refuse "src/START.cmd is missing in $REPO_ROOT; the app is incomplete"
  [[ -f $TEMPLATE_FILE ]] || refuse "builder/README.txt.template is missing"

  local vout
  vout=$(py versions "$VERSIONS_FILE")
  eval "$vout"
  UA="$PNH_NAME-builder/$PNH_VERSION"
  local builder_id="$PNH_NAME $PNH_VERSION"

  local fs
  fs=$(py fstype "$TARGET")
  case $fs in
    vfat|msdos|fat|fat12|fat16|fat32) explain_fat32; refuse "FAT32 target ($TARGET)" ;;
    exfat|ntfs|ntfs3|fuseblk) ;;
    *) say "Note: $TARGET is on '$fs'. Windows PCs need the SSD in exFAT (recommended) or NTFS." ;;
  esac

  local PNH="$TARGET/PlugNHeal"
  local APP="$PNH/app" RUNTIME="$PNH/runtime" HOMEDIR="$PNH/home"
  local LICENSES="$PNH/licenses" DOWNLOADS="$PNH/downloads"
  local OLLAMA_DIR="$RUNTIME/ollama" MARKER="$RUNTIME/runtime.json" BLOBS="$PNH/models/blobs"
  local MANIFESTS="$PNH/models/manifests/$REGISTRY_HOST"
  mkdir -p "$APP" "$RUNTIME" "$BLOBS" "$MANIFESTS" "$HOMEDIR" "$LICENSES" "$DOWNLOADS"
  WORK=$(mktemp -d "${TMPDIR:-/tmp}/pnh-build.XXXXXX")

  say "Plug'n'Heal builder $PNH_VERSION -> $TARGET (profile $PROFILE, Ollama $OLLAMA_VERSION)"

  # 1. Models of the profile and their manifests (re-measured; refuse catalogue mismatches > tolerance)
  py profile "$CATALOG_FILE" "$PROFILE" >"$WORK/models.tsv"
  local idx=0 id tag cbytes ns name t total hexd size
  : >"$WORK/plan.tsv"
  : >"$WORK/blobs.tsv"
  while IFS=$'\t' read -r id tag cbytes <&3; do
    IFS=$'\t' read -r ns name t < <(py tagpath "$tag")
    local mf="$WORK/manifest-$idx.json"
    if fetch_small "$REGISTRY_URL/v2/$ns/$name/manifests/$t" "$mf" "$MANIFEST_ACCEPT"; then :; else
      [[ $? == 4 ]] && refuse "model $tag not found in the registry"
      die "could not fetch the manifest of $tag"
    fi
    py entries "$mf" >"$WORK/entries-$idx.tsv"
    total=0
    while IFS=$'\t' read -r hexd size _ <&4; do
      total=$((total + size))
      printf '%s\t%s\t%s\t%s\n' "$hexd" "$size" "$ns/$name" "$tag" >>"$WORK/blobs.tsv"
    done 4<"$WORK/entries-$idx.tsv"
    if ! py sizecheck "$cbytes" "$total" "$SIZE_TOLERANCE"; then
      refuse "size of $tag differs from the catalogue by more than $SIZE_TOLERANCE %: catalogue $cbytes, registry $total bytes. Update src/catalog/models.json."
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$idx" "$id" "$tag" "$ns" "$name" "$t" "$total" >>"$WORK/plan.tsv"
    say "  model $tag: $(gb "$total") in $(wc -l <"$WORK/entries-$idx.tsv" | tr -d ' ') blobs"
    idx=$((idx + 1))
  done 3<"$WORK/models.tsv"

  # 2. What is still missing (blobs are deduplicated by digest: licence/template blobs are shared)
  local need_bytes=0 need_disk=0 have
  : >"$WORK/need.tsv"
  local seen=" "
  while IFS=$'\t' read -r hexd size repo tag <&3; do
    case $seen in *" $hexd "*) continue ;; esac
    seen="$seen$hexd "
    local blob="$BLOBS/sha256-$hexd"
    if [[ -f $blob && $(fsize "$blob") == "$size" ]]; then
      if [[ $VERIFY == 1 ]]; then
        if [[ $(py sha256 "$blob") == "$hexd" ]]; then continue; fi
        warn "blob sha256-$hexd is corrupt, fetching it again"
        rm -f "$blob"
      else
        continue
      fi
    fi
    have=$(fsize "$DOWNLOADS/sha256-$hexd.part")
    need_bytes=$((need_bytes + size - have))
    need_disk=$((need_disk + size - have))
    printf '%s\t%s\t%s\t%s\n' "$hexd" "$size" "$repo" "$tag" >>"$WORK/need.tsv"
  done 3<"$WORK/blobs.tsv"

  local runtime_ok=0 zip="$DOWNLOADS/$OLLAMA_ASSET"
  if [[ -f $OLLAMA_DIR/ollama.exe ]] && py marker-ok "$MARKER" "$OLLAMA_VERSION" "$OLLAMA_SHA256"; then runtime_ok=1; fi
  if [[ $runtime_ok == 0 ]]; then
    have=$(fsize "$zip")
    need_bytes=$((need_bytes + OLLAMA_SIZE - have))
    need_disk=$((need_disk + OLLAMA_SIZE - have + OLLAMA_EXTRACTED))
  fi

  # 3. Free space
  local free_bytes
  free_bytes=$(( $(df -Pk "$TARGET" | awk 'NR == 2 { print $4 }') * 1024 ))
  need_disk=$((need_disk + RESERVE_BYTES))
  say "  to download: $(gb "$need_bytes"); space needed: $(gb "$need_disk"); free: $(gb "$free_bytes")"
  if (( need_disk > free_bytes )); then
    refuse "not enough free space on $TARGET: needs $(gb "$need_disk"), free $(gb "$free_bytes"). Choose profile small or a larger SSD."
  fi

  TOTAL=$need_bytes
  DONE=0
  DL_START=$(date +%s)

  # 4. Runtime: download with resume, sha256, extract, marker
  if [[ $runtime_ok == 1 ]]; then
    say "[runtime] Ollama $OLLAMA_VERSION already on the drive"
  else
    local tries
    for tries in 1 2; do
      fetch_file "$OLLAMA_URL" "$zip" "$OLLAMA_SIZE" "[runtime]"
      say "[runtime] checking sha256 ..."
      if [[ $(py sha256 "$zip") == "$OLLAMA_SHA256" ]]; then break; fi
      rm -f "$zip"
      [[ $tries == 2 ]] && die "sha256 of $OLLAMA_ASSET does not match versions.json"
      warn "sha256 mismatch, downloading $OLLAMA_ASSET again"
    done
    if [[ -e $MARKER || -d $OLLAMA_DIR ]]; then
      [[ $OLLAMA_DIR == "$PNH/runtime/ollama" ]] || die "internal: unexpected runtime path"
      say "[runtime] replacing the old runtime"
      rm -rf "$OLLAMA_DIR"
      rm -f "$MARKER"
    fi
    say "[runtime] extracting ..."
    py unzip "$zip" "$OLLAMA_DIR"
    [[ -f $OLLAMA_DIR/ollama.exe ]] || die "ollama.exe missing after extraction"
    py write-marker "$MARKER" "$OLLAMA_VERSION" "$OLLAMA_SHA256" "$OLLAMA_ASSET" "$(now_utc)"
    rm -f "$zip"
  fi

  # 5. App
  say "[app] copying src/ to PlugNHeal/app/"
  py mirror "$SRC_DIR" "$APP"
  cp -f "$SRC_DIR/START.cmd" "$TARGET/START.cmd.pnh-tmp"
  mv -f "$TARGET/START.cmd.pnh-tmp" "$TARGET/START.cmd"

  # 6. Model blobs straight from the registry, each sha256-verified before it is moved into blobs/
  local n=0 count
  count=$(wc -l <"$WORK/need.tsv" | tr -d ' ')
  while IFS=$'\t' read -r hexd size repo tag <&3; do
    n=$((n + 1))
    local part="$DOWNLOADS/sha256-$hexd.part" label tries
    label="[models] $tag, file $n/$count"
    for tries in 1 2; do
      fetch_file "$REGISTRY_URL/v2/$repo/blobs/sha256:$hexd" "$part" "$size" "$label"
      if (( size >= 100000000 )); then say "$label: checking sha256 ..."; fi
      if [[ $(py sha256 "$part") == "$hexd" ]]; then break; fi
      rm -f "$part"
      [[ $tries == 2 ]] && die "sha256 mismatch for blob $hexd of $tag"
      warn "sha256 mismatch for blob $hexd of $tag, downloading again"
    done
    mv -f "$part" "$BLOBS/sha256-$hexd"
  done 3<"$WORK/need.tsv"
  progress_break

  # 7. Manifests (unchanged bytes) last, then check every blob of every manifest
  while IFS=$'\t' read -r idx id tag ns name t total <&3; do
    mkdir -p "$MANIFESTS/$ns/$name"
    cp -f "$WORK/manifest-$idx.json" "$MANIFESTS/$ns/$name/$t.pnh-tmp"
    mv -f "$MANIFESTS/$ns/$name/$t.pnh-tmp" "$MANIFESTS/$ns/$name/$t"
    local missing
    missing=$(py missing "$MANIFESTS/$ns/$name/$t" "$BLOBS") || die "$tag: blobs missing or wrong size: $missing"
  done 3<"$WORK/plan.tsv"
  say "[models] all blobs present with the size their manifest states"

  # 8. Licences, drive.json, README.txt
  if [[ -f $REPO_ROOT/THIRD-PARTY-NOTICES.md ]]; then
    cp -f "$REPO_ROOT/THIRD-PARTY-NOTICES.md" "$LICENSES/THIRD-PARTY-NOTICES.md"
  else
    warn "THIRD-PARTY-NOTICES.md not found in the repository root, not copied"
  fi
  fetch_small "$OLLAMA_LICENSE_URL" "$LICENSES/ollama-LICENSE.txt" || die "could not fetch the Ollama licence ($OLLAMA_LICENSE_URL)"
  local lic
  mkdir -p "$LICENSES/runtime"
  for lic in "$OLLAMA_DIR"/lib/ollama/*LICENSE*; do  # licences shipped inside the runtime ZIP (llama.cpp, Go, ...)
    [[ -f $lic ]] && cp -f "$lic" "$LICENSES/runtime/$(basename "$lic").txt"
  done
  while IFS=$'\t' read -r idx id tag ns name t total <&3; do
    py licenses "$MANIFESTS/$ns/$name/$t" "$BLOBS" "$tag" "$LICENSES/models" >/dev/null
  done 3<"$WORK/plan.tsv"

  py installed "$CATALOG_FILE" "$PNH/models" "$REGISTRY_HOST" >"$WORK/installed.tsv"
  local built_at
  built_at=$(now_utc)
  py drivejson "$PNH/drive.json" "$built_at" "$builder_id" "$OLLAMA_VERSION" "$PROFILE" "$WORK/installed.tsv"
  py readme "$TEMPLATE_FILE" "$TARGET/README.txt" "$built_at" "$builder_id" "$OLLAMA_VERSION" "$PROFILE" \
    "$WORK/installed.tsv"
  rmdir "$DOWNLOADS" 2>/dev/null || true

  say ""
  say "Done. $TARGET is ready to be used offline:"
  while IFS=$'\t' read -r id tag total <&3; do say "  $tag  ($(gb "$total"))"; done 3<"$WORK/installed.tsv"
  say "Eject the drive safely before unplugging it."
}

main "$@"
