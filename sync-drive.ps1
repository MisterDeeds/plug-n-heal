<#
.SYNOPSIS
  Plug'n'Heal network rescue kit - create or update the kit on an external drive.

.DESCRIPTION
  One command on any Windows PC with internet (asks for the drive letter):

    irm -UseBasicParsing https://raw.githubusercontent.com/MisterDeeds/plug-n-heal/main/sync-drive.ps1 | iex

  With parameters:

    & ([scriptblock]::Create((irm -UseBasicParsing https://raw.githubusercontent.com/MisterDeeds/plug-n-heal/main/sync-drive.ps1))) -Drive E

  What it does:
    - always refreshes the small kit files (scripts, instructions) from the GitHub repository
    - keeps what is already on the drive: the Ollama runtime, the Codex CLI and the language model are only
      downloaded when they are missing or incomplete (interrupted downloads resume)
  Nothing outside <drive>:\AI (or an existing <drive>:\KI of an earlier version) is touched. Nothing is deleted.

.PARAMETER Drive   Drive letter of the external drive. Asked when omitted.
.PARAMETER Model   Ollama model tag. Default: the model already noted on the drive, else qwen3.8:27b.
.PARAMETER Effort  Reasoning effort for the model: low, medium or xhigh. Default: what the drive already notes, else xhigh.
.PARAMETER Notes   Optional facts about the fault for the agent (saved as work\NOTES.md on the drive).
.PARAMETER Ref     Branch, tag or commit of the repository to take the kit files from. Default: main.
.PARAMETER Root    Advanced: use this folder instead of <drive>:\AI.
.PARAMETER SkipSpeedTest  Do not measure the write speed of the drive.

  Checks before anything is downloaded: the drive is not FAT32, there is enough free space for everything that is
  still missing (otherwise it names smaller models that would fit), and how fast the drive writes (a slow USB stick
  or a USB 2 port makes the first download and every start of the model slow).
#>
param(
    [string]$Drive = '',
    [string]$Model = '',
    [string]$Notes = '',
    [string]$Ref = 'main',
    [string]$Repo = 'MisterDeeds/plug-n-heal',
    [string]$Root = '',
    [string]$Effort = '',
    [switch]$SkipSpeedTest
)

function Invoke-PnhKitSync {
    param([string]$Drive, [string]$Model, [string]$Notes, [string]$Ref, [string]$Repo, [string]$Root, [string]$Effort, [switch]$SkipSpeedTest)

    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

    # pinned third-party downloads (original sources, checked by size and SHA-256)
    $OllamaPkg = @{
        Version  = '0.40.15'
        Url      = 'https://github.com/ollama/ollama/releases/download/v0.40.15/ollama-windows-amd64.zip'
        Bytes    = [int64]1614941966
        Sha      = '9CA74A7AB66EC86870B1EECAC7DF160DF08DC4E3A291AB5D2D59BCF9310221C6'
        Unpacked = [int64]2263717391
    }
    $CodexPkg = @{
        Version  = '0.167.0'
        Url      = 'https://github.com/openai/codex/releases/download/rust-v0.167.0/codex-package-x86_64-pc-windows-msvc.tar.gz'
        Bytes    = [int64]201675464
        Sha      = '60567CA940BBAF6C10501805D9909D1328179231E2D47A0DEEC7A1368BB21641'
        Unpacked = [int64]900MB
    }
    $DefaultModel = 'qwen3.8:27b'
    $Port = 11435

    function Say([string]$Text, [string]$Color = 'Gray') { Write-Host $Text -ForegroundColor $Color }
    function Gb([double]$Bytes) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }

    function Split-ModelTag([string]$Tag) {
        $name = $Tag; $ver = 'latest'
        $i = $Tag.LastIndexOf(':')
        if ($i -gt 0) { $name = $Tag.Substring(0, $i); $ver = $Tag.Substring($i + 1) }
        if ($name -notmatch '/') { $name = 'library/' + $name }
        return @{ Name = $name; Version = $ver }
    }

    function Test-ModelComplete([string]$ModelsDir, [string]$Tag) {
        # returns the size in bytes when the manifest and every blob are on the drive, else $null
        $t = Split-ModelTag $Tag
        $mf = Join-Path $ModelsDir ('manifests\registry.ollama.ai\' + ($t.Name -replace '/', '\') + '\' + $t.Version)
        if (-not (Test-Path -LiteralPath $mf)) { return $null }
        try { $m = Get-Content -LiteralPath $mf -Raw | ConvertFrom-Json } catch { return $null }
        $total = [int64]0
        foreach ($l in (@($m.config) + @($m.layers))) {
            if ((-not $l) -or (-not $l.digest)) { continue }
            # after a pull Ollama adds a copy of the registry manifest as an extra layer; it is not needed
            if ([string]$l.mediaType -like '*distribution.manifest*') { continue }
            $blob = Join-Path $ModelsDir ('blobs\' + ([string]$l.digest -replace ':', '-'))
            if (-not (Test-Path -LiteralPath $blob)) { return $null }
            if ((Get-Item -LiteralPath $blob).Length -ne [int64]$l.size) { return $null }
            $total += [int64]$l.size
        }
        if ($total -le 0) { return $null }
        return $total
    }

    function Get-BigFile([string]$Url, [string]$Dest, [int64]$Bytes, [string]$Sha, [string]$What) {
        $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
        if (-not (Test-Path -LiteralPath $curl)) { throw 'curl.exe is missing (it needs Windows 10 version 1803 or newer).' }
        for ($try = 1; $try -le 30; $try++) {
            $have = [int64]0
            if (Test-Path -LiteralPath $Dest) { $have = (Get-Item -LiteralPath $Dest).Length }
            if ($have -eq $Bytes) { break }
            if ($have -gt $Bytes) { Remove-Item -LiteralPath $Dest -Force; $have = [int64]0 }
            if ($try -gt 1) {
                Say ('   interrupted, resuming at ' + (Gb $have) + ' (attempt ' + $try + ')') 'DarkYellow'
                Start-Sleep -Seconds ([math]::Min(30, 3 * $try))
            }
            # a new curl call follows the redirect again, so the signed download link is always fresh
            $null = Start-Process -FilePath $curl -ArgumentList @('-L', '--fail', '-C', '-', '-o', ('"' + $Dest + '"'), $Url) -Wait -PassThru
        }
        if ((-not (Test-Path -LiteralPath $Dest)) -or ((Get-Item -LiteralPath $Dest).Length -ne $Bytes)) {
            throw ($What + ': the download is incomplete. Run the command again, it resumes.')
        }
        if ((Get-FileHash -LiteralPath $Dest -Algorithm SHA256).Hash -ne $Sha) {
            Remove-Item -LiteralPath $Dest -Force
            throw ($What + ': the checksum is wrong, the file was removed. Run the command again.')
        }
    }

    function Invoke-ModelPull([int]$ApiPort, [string]$Tag) {
        # POST /api/pull streams one JSON object per line: status, digest, total, completed; at the end "success"
        $req = [System.Net.HttpWebRequest]::Create('http://127.0.0.1:' + $ApiPort + '/api/pull')
        $req.Method = 'POST'
        $req.ContentType = 'application/json'
        $req.Proxy = $null
        $req.Timeout = 60000
        $req.ReadWriteTimeout = 3600000
        $body = [System.Text.Encoding]::UTF8.GetBytes((@{ model = $Tag; stream = $true } | ConvertTo-Json -Compress))
        $rs = $req.GetRequestStream()
        $rs.Write($body, 0, $body.Length)
        $rs.Close()
        $resp = $req.GetResponse()
        $reader = New-Object System.IO.StreamReader($resp.GetResponseStream())
        $ok = $false
        $err = ''
        $sizes = @{}
        $last = [DateTime]::MinValue
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                if (-not $line.Trim()) { continue }
                try { $j = $line | ConvertFrom-Json } catch { continue }
                if ($j.error) { $err = [string]$j.error; break }
                if ([string]$j.status -eq 'success') { $ok = $true }
                if ($j.digest -and $j.total) { $sizes[[string]$j.digest] = @([double]$j.total, [double]$j.completed) }
                if (((Get-Date) - $last).TotalSeconds -ge 5) {
                    $last = Get-Date
                    $tot = 0.0; $done = 0.0
                    foreach ($v in $sizes.Values) { $tot += $v[0]; $done += $v[1] }
                    if ($tot -gt 0) { Say ('   {0:N1} of {1:N1} GB ({2:N0} %)  {3}' -f ($done / 1GB), ($tot / 1GB), (100 * $done / $tot), [string]$j.status) }
                    else { Say ('   ' + [string]$j.status) }
                }
            }
        } finally {
            $reader.Close()
            $resp.Close()
        }
        if ($err) { throw ('Downloading the model failed: ' + $err) }
        if (-not $ok) { throw 'Downloading the model was interrupted. Run the command again, it resumes.' }
    }

    function Get-DriveDescription([string]$DriveLetter) {
        # model name, bus (USB, NVMe, SATA) and media type; empty when Windows cannot tell (network or subst drives)
        try {
            $part = Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
            $disk = $part | Get-Disk -ErrorAction Stop
            $media = ''
            try {
                $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.DeviceId -eq [string]$disk.Number } | Select-Object -First 1
                if ($pd -and ([string]$pd.MediaType) -and ([string]$pd.MediaType -ne 'Unspecified')) { $media = ', ' + [string]$pd.MediaType }
            } catch { }
            return ('{0} (bus {1}{2}, {3:N0} GB)' -f ([string]$disk.FriendlyName).Trim(), [string]$disk.BusType, $media, ($disk.Size / 1GB))
        } catch { return '' }
    }

    function Measure-WriteSpeed([string]$Dir) {
        # writes up to 1 GB with write-through (no cache in between) and stops after about 15 seconds;
        # returns MB/s, or -1 when the test could not run. The test file is removed again.
        $file = Join-Path $Dir ('speedtest-' + [guid]::NewGuid().ToString('N') + '.tmp')
        $buf = New-Object byte[] (4MB)
        (New-Object System.Random 7).NextBytes($buf)
        $written = [int64]0
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $fs = New-Object System.IO.FileStream($file, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None, 4096, [System.IO.FileOptions]::WriteThrough)
            try {
                while (($written -lt 1GB) -and ($sw.Elapsed.TotalSeconds -lt 15)) {
                    $fs.Write($buf, 0, $buf.Length)
                    $written += $buf.Length
                }
                $fs.Flush($true)
            } finally { $fs.Close() }
            $sec = $sw.Elapsed.TotalSeconds
            if ($sec -le 0) { return -1 }
            return [math]::Round(($written / 1MB) / $sec)
        } catch {
            return -1
        } finally {
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
    }

    Say ''
    Say "Plug'n'Heal network rescue kit - sync" 'Cyan'

    # ---------- target ----------
    $sys = ([string]$env:SystemDrive).TrimEnd(':').ToUpper()
    if ($Root) {
        $rootPath = $Root.TrimEnd('\')
        $letter = $rootPath.Substring(0, 1).ToUpper()
    } else {
        if (-not $Drive) {
            $drives = @([System.IO.DriveInfo]::GetDrives() | Where-Object {
                    $_.IsReady -and ($_.DriveType -eq 'Fixed' -or $_.DriveType -eq 'Removable') -and ($_.Name.Substring(0, 1).ToUpper() -ne $sys) })
            if ($drives.Count -eq 0) { throw 'No external drive found. Plug in the SSD and run the command again.' }
            Say 'Drives:'
            foreach ($d in $drives) {
                $l = $d.Name.Substring(0, 1)
                $mark = ''
                if ((Test-Path -LiteralPath ($l + ':\AI')) -or (Test-Path -LiteralPath ($l + ':\KI'))) { $mark = '   <- kit found' }
                Say ('  {0}:  {1,-20} {2,6:N0} GB, {3,6:N0} GB free, {4}{5}' -f $l, $d.VolumeLabel, ($d.TotalSize / 1GB), ($d.AvailableFreeSpace / 1GB), $d.DriveFormat, $mark)
            }
            $Drive = Read-Host 'Drive letter of the SSD (for example E)'
        }
        $letter = ([string]$Drive).Trim().TrimEnd('\').TrimEnd(':').ToUpper()
        if ($letter -notmatch '^[A-Z]$') { throw ("'" + $Drive + "' is not a drive letter.") }
        if ($letter -eq $sys) { throw 'That is the Windows drive. Choose the external SSD.' }
        # a drive prepared with an earlier version keeps its KI folder
        $rootPath = $letter + ':\AI'
        if (Test-Path -LiteralPath ($letter + ':\KI')) { $rootPath = $letter + ':\KI' }
    }
    $di = New-Object System.IO.DriveInfo($letter)
    if (-not $di.IsReady) { throw ('Drive ' + $letter + ': is not ready.') }
    if ($di.DriveFormat -eq 'FAT32') {
        throw ('Drive ' + $letter + ': is formatted as FAT32, which cannot hold files larger than 4 GB. Format it as exFAT first (right-click the drive in Explorer, Format, file system exFAT). Formatting erases the drive.')
    }
    $work = Join-Path $rootPath 'work'
    New-Item -ItemType Directory -Force -Path $rootPath, $work | Out-Null
    Say ('Target: ' + $rootPath + '   (' + $di.DriveFormat + ', ' + (Gb $di.TotalSize) + ' in total, ' + (Gb $di.AvailableFreeSpace) + ' free)')
    $desc = Get-DriveDescription $letter
    if ($desc) { Say ('Drive:  ' + $desc) }

    $speed = -1
    if (-not $SkipSpeedTest) {
        Say ''
        Say 'Checking the drive speed (writes up to 1 GB, takes at most 15 seconds) ...' 'Cyan'
        $speed = Measure-WriteSpeed $work
        if ($speed -lt 0) { Say '   the speed test could not run - continuing anyway' 'DarkYellow' }
        elseif ($speed -ge 250) { Say ('   writes ' + $speed + ' MB/s - fast, good') 'Green' }
        elseif ($speed -ge 80) { Say ('   writes ' + $speed + ' MB/s - usable') 'Green' }
        else {
            Say ('   writes only ' + $speed + ' MB/s - slow. This is typical for a USB stick or a USB 2 port.') 'Yellow'
            Say '   It works, but the first download and every start of the model take much longer.' 'Yellow'
            Say '   Better: an external SSD on a blue USB 3 or a USB-C port.' 'Yellow'
        }
    }

    # ---------- what is already there ----------
    $kitFile = Join-Path $rootPath 'kit.json'
    $oldKit = $null
    if (Test-Path -LiteralPath $kitFile) { try { $oldKit = Get-Content -LiteralPath $kitFile -Raw | ConvertFrom-Json } catch { } }
    if ((-not $Model) -and $oldKit -and $oldKit.model) { $Model = [string]$oldKit.model }
    if (-not $Model) { $Model = $DefaultModel }
    if ((-not $Effort) -and $oldKit -and $oldKit.effort) { $Effort = [string]$oldKit.effort }
    if (-not $Effort) { $Effort = 'xhigh' }
    if (@('low', 'medium', 'xhigh') -notcontains $Effort) { throw ("'" + $Effort + "' is not a reasoning effort. Use low, medium or xhigh.") }
    $ollamaExe = Join-Path $rootPath 'ollama\ollama.exe'
    $codexExe = Join-Path $rootPath 'codex\bin\codex.exe'
    $modelsDir = Join-Path $rootPath 'models'
    $haveOllama = Test-Path -LiteralPath $ollamaExe
    $haveCodex = Test-Path -LiteralPath $codexExe
    $modelBytes = Test-ModelComplete $modelsDir $Model

    $need = [int64]0
    if (-not $haveOllama) { $need += $OllamaPkg.Bytes + $OllamaPkg.Unpacked }
    if (-not $haveCodex) { $need += $CodexPkg.Bytes + $CodexPkg.Unpacked }
    if (-not $modelBytes) {
        $modelNeed = [int64]0
        try {
            $t = Split-ModelTag $Model
            $mf = Invoke-RestMethod -UseBasicParsing -TimeoutSec 20 -Uri ('https://registry.ollama.ai/v2/' + $t.Name + '/manifests/' + $t.Version) -Headers @{ Accept = 'application/vnd.docker.distribution.manifest.v2+json' }
            if ($mf -is [string]) { $mf = $mf | ConvertFrom-Json }
            foreach ($l in (@($mf.config) + @($mf.layers))) { if ($l -and $l.size) { $modelNeed += [int64]$l.size } }
        } catch { $modelNeed = [int64]0 }
        if ($modelNeed -le 0) { throw ('The model ' + $Model + ' was not found in the Ollama library (or there is no internet connection).') }
        $haveBlobs = [int64]0
        $blobDir = Join-Path $modelsDir 'blobs'
        if (Test-Path -LiteralPath $blobDir) {
            $sum = (Get-ChildItem -LiteralPath $blobDir -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
            if ($sum) { $haveBlobs = [int64]$sum }
        }
        $need += [math]::Max([int64]0, ($modelNeed - $haveBlobs))
    }
    Say ''
    Say 'Checking what is missing and whether it fits ...' 'Cyan'
    $rows = @(
        @('Ollama runtime', $haveOllama, ($OllamaPkg.Bytes + $OllamaPkg.Unpacked)),
        @('Codex CLI', $haveCodex, ($CodexPkg.Bytes + $CodexPkg.Unpacked))
    )
    foreach ($r in $rows) {
        if ($r[1]) { Say ('   {0,-28} already on the drive' -f $r[0]) }
        else { Say ('   {0,-28} missing, needs {1} while downloading' -f $r[0], (Gb $r[2])) }
    }
    if ($modelBytes) { Say ('   {0,-28} already on the drive ({1})' -f ('Model ' + $Model), (Gb $modelBytes)) }
    else { Say ('   {0,-28} missing, needs {1}' -f ('Model ' + $Model), (Gb ($need - (@($rows | Where-Object { -not $_[1] } | ForEach-Object { $_[2] }) | Measure-Object -Sum).Sum))) }
    $needTotal = [int64]0
    if ($need -gt 0) { $needTotal = $need + 500MB }
    Say ('   free on the drive: {0}, needed: {1}' -f (Gb $di.AvailableFreeSpace), (Gb $needTotal))
    if (($need -gt 0) -and ($di.AvailableFreeSpace -lt $needTotal)) {
        Say ''
        Say ('Not enough free space on ' + $letter + ':.') 'Red'
        # smaller models that can call tools, measured sizes (Ollama library, November 2026)
        $smaller = @(
            @('qwen3.5:9b-q4_K_M', [int64]6550825550, 'graphics card with 8 GB or more'),
            @('qwen3.5:4b-q4_K_M', [int64]3324173934, 'graphics card with 5 GB or more, or a fast processor'),
            @('qwen3.5:2b-q4_K_M', [int64]1945781358, 'any PC, weakest results')
        )
        $base = $need
        if (-not $modelBytes) { $base = $need - [math]::Max([int64]0, ($modelNeed - $haveBlobs)) }
        $fits = @($smaller | Where-Object { ($base + $_[1] + 500MB) -le $di.AvailableFreeSpace })
        if ($fits.Count -gt 0) {
            Say 'A smaller model would fit. Run the command again with one of these (bigger = better repairs):' 'Yellow'
            foreach ($s in $fits) { Say ('   -Model {0}   ({1}, {2})' -f $s[0], (Gb $s[1]), $s[2]) 'Yellow' }
            Say ('   Example: & ([scriptblock]::Create((irm -UseBasicParsing https://raw.githubusercontent.com/' + $Repo + '/main/sync-drive.ps1))) -Drive ' + $letter + ' -Model ' + $fits[0][0]) 'Yellow'
        } else {
            Say 'Even the smallest model does not fit. Free up space on the drive or use a bigger one (64 GB or more).' 'Yellow'
        }
        throw ('Not enough free space on ' + $letter + ': ' + (Gb $di.AvailableFreeSpace) + ' free, ' + (Gb $needTotal) + ' needed.')
    }
    Say '   it fits' 'Green'
    if (($speed -gt 0) -and (-not $modelBytes)) {
        $mins = [math]::Ceiling((($need / 1MB) / $speed) / 60)
        Say ('   writing it to this drive takes at least about {0} minute(s); your internet speed may make it longer' -f $mins) 'DarkGray'
    }

    # ---------- 1. kit files from GitHub (always refreshed) ----------
    Say ''
    Say ('[1/4] Kit files from github.com/' + $Repo + ' (' + $Ref + ')') 'Cyan'
    $tmp = Join-Path $env:TEMP ('pnh-kit-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
        $zip = Join-Path $tmp 'repo.zip'
        Invoke-WebRequest -UseBasicParsing -Uri ('https://codeload.github.com/' + $Repo + '/zip/' + $Ref) -OutFile $zip
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $tmp 'x') -Force
        $top = Get-ChildItem -LiteralPath (Join-Path $tmp 'x') -Directory | Select-Object -First 1
        $kit = $null
        if ($top) { $kit = Join-Path $top.FullName 'kit' }
        if ((-not $kit) -or (-not (Test-Path -LiteralPath (Join-Path $kit 'agent.ps1')))) { throw 'The kit folder is missing in the download.' }
        $changed = 0; $same = 0
        $startCmd = $null
        foreach ($f in @(Get-ChildItem -LiteralPath $kit -Recurse -File)) {
            $rel = $f.FullName.Substring($kit.Length).TrimStart('\')
            if ($rel -eq 'README.md') { $rel = 'KIT-README.md' }
            $dst = Join-Path $rootPath $rel
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            if ($f.Extension -eq '.cmd') {
                # cmd.exe needs CRLF line ends
                $text = [System.Text.Encoding]::ASCII.GetString($bytes) -replace "`r?`n", "`r`n"
                $bytes = [System.Text.Encoding]::ASCII.GetBytes($text)
            }
            if ($rel -eq 'Start-Repair.cmd') { $startCmd = $bytes }
            $old = $null
            if (Test-Path -LiteralPath $dst) { $old = [System.IO.File]::ReadAllBytes($dst) }
            if ($old -and ([Convert]::ToBase64String($old) -eq [Convert]::ToBase64String($bytes))) { $same++; continue }
            $dir = Split-Path -Parent $dst
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            [System.IO.File]::WriteAllBytes($dst, $bytes)
            $changed++
        }
        # a drive of an earlier (German) version keeps its old start file name working
        $legacy = Join-Path $rootPath 'Reparatur-starten.cmd'
        if ($startCmd -and (Test-Path -LiteralPath $legacy)) { [System.IO.File]::WriteAllBytes($legacy, $startCmd) }
        Say ('   ' + ($changed + $same) + ' files: ' + $changed + ' updated, ' + $same + ' unchanged') 'Green'
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ---------- 2. Ollama runtime ----------
    Say ''
    Say '[2/4] Ollama runtime' 'Cyan'
    $ollamaState = 'kept'
    if ($haveOllama) { Say '   already on the drive - not downloaded again' 'Green' }
    else {
        Say ('   downloading version ' + $OllamaPkg.Version + ' (' + (Gb $OllamaPkg.Bytes) + ') in a separate window ...')
        $zip = Join-Path $rootPath 'ollama-download.zip'
        Get-BigFile $OllamaPkg.Url $zip $OllamaPkg.Bytes $OllamaPkg.Sha 'Ollama runtime'
        $dir = Join-Path $rootPath 'ollama'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Say '   unpacking ...'
        $null = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\tar.exe') -ArgumentList @('-xf', ('"' + $zip + '"'), '-C', ('"' + $dir + '"')) -Wait -PassThru -WindowStyle Hidden
        if (-not (Test-Path -LiteralPath $ollamaExe)) { throw 'Unpacking the Ollama runtime failed.' }
        Remove-Item -LiteralPath $zip -Force
        $ollamaState = $OllamaPkg.Version
        Say '   done' 'Green'
    }

    # ---------- 3. Codex CLI ----------
    Say ''
    Say '[3/4] Codex CLI (the agent program)' 'Cyan'
    $codexState = 'kept'
    if ($haveCodex) { Say '   already on the drive - not downloaded again' 'Green' }
    else {
        Say ('   downloading version ' + $CodexPkg.Version + ' (' + (Gb $CodexPkg.Bytes) + ') in a separate window ...')
        $tgz = Join-Path $rootPath 'codex-download.tar.gz'
        Get-BigFile $CodexPkg.Url $tgz $CodexPkg.Bytes $CodexPkg.Sha 'Codex CLI'
        $dir = Join-Path $rootPath 'codex'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Say '   unpacking ...'
        $null = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\tar.exe') -ArgumentList @('-xzf', ('"' + $tgz + '"'), '-C', ('"' + $dir + '"')) -Wait -PassThru -WindowStyle Hidden
        if (-not (Test-Path -LiteralPath $codexExe)) { throw 'Unpacking the Codex CLI failed.' }
        Remove-Item -LiteralPath $tgz -Force
        $codexState = $CodexPkg.Version
        Say '   done' 'Green'
    }

    # ---------- 4. language model ----------
    Say ''
    Say ('[4/4] Language model ' + $Model) 'Cyan'
    if ($modelBytes) { Say ('   already on the drive (' + (Gb $modelBytes) + ') - not downloaded again') 'Green' }
    else {
        $old = @{}
        foreach ($k in @('OLLAMA_MODELS', 'OLLAMA_HOST', 'OLLAMA_NOPRUNE')) { $old[$k] = [Environment]::GetEnvironmentVariable($k, 'Process') }
        $srv = $null
        try {
            $env:OLLAMA_MODELS = $modelsDir
            $env:OLLAMA_HOST = '127.0.0.1:' + $Port
            $env:OLLAMA_NOPRUNE = '1'
            $srvLog = Join-Path $work 'ollama-sync.log'
            $srv = Start-Process -FilePath $ollamaExe -ArgumentList 'serve' -WindowStyle Hidden -RedirectStandardError $srvLog -PassThru
            $ready = $false
            for ($i = 0; ($i -lt 60) -and (-not $ready); $i++) {
                Start-Sleep -Seconds 1
                try { Invoke-RestMethod -UseBasicParsing -TimeoutSec 2 -Uri ('http://127.0.0.1:' + $Port + '/api/tags') | Out-Null; $ready = $true } catch { }
            }
            if (-not $ready) { throw 'The Ollama runtime on the drive does not start on this PC.' }
            Say '   downloading (an interrupted download resumes when you run the command again) ...'
            try { Invoke-ModelPull $Port $Model }
            catch {
                Say ('   ' + $_.Exception.Message) 'Red'
                if (Test-Path -LiteralPath $srvLog) { Get-Content -LiteralPath $srvLog -Tail 12 -ErrorAction SilentlyContinue | ForEach-Object { Say ('   | ' + $_) 'DarkGray' } }
                throw
            }
        } finally {
            if ($srv) { Stop-Process -Id $srv.Id -Force -ErrorAction SilentlyContinue }
            foreach ($k in @($old.Keys)) { [Environment]::SetEnvironmentVariable($k, $old[$k], 'Process') }
        }
        $modelBytes = Test-ModelComplete $modelsDir $Model
        if (-not $modelBytes) { throw ('The model ' + $Model + ' is not complete yet. Run the command again, the download resumes.') }
        Say ('   done (' + (Gb $modelBytes) + ')') 'Green'
    }

    # ---------- finish ----------
    $info = [ordered]@{
        model    = $Model
        effort   = $Effort
        writeMBs = $speed
        ollama   = $ollamaState
        codex    = $codexState
        source   = ($Repo + '@' + $Ref)
        syncedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($kitFile, ($info | ConvertTo-Json), $utf8)
    if ($Notes -and $Notes.Trim()) { [System.IO.File]::WriteAllText((Join-Path $work 'NOTES.md'), $Notes.Trim(), $utf8) }

    # memory of an earlier version of the kit: carry the protocol over once
    $oldProto = Join-Path $rootPath 'arbeit\protokoll.md'
    $newProto = Join-Path $work 'protocol.md'
    if ((Test-Path -LiteralPath $oldProto) -and (-not (Test-Path -LiteralPath $newProto))) {
        Copy-Item -LiteralPath $oldProto -Destination $newProto
        Say ''
        Say '   The protocol of an earlier version was carried over (arbeit\protokoll.md -> work\protocol.md).'
    }
    if ((Test-Path -LiteralPath (Join-Path $rootPath 'arbeit')) -or (Test-Path -LiteralPath (Join-Path $rootPath 'werkzeuge'))) {
        Say '   The folders "arbeit" and "werkzeuge" of an earlier version are no longer used. They were left untouched.'
    }

    $name = Split-Path -Leaf $rootPath
    Say ''
    Say 'DONE. The drive is up to date.' 'Green'
    Say '  1. Eject the drive safely and plug it into the PC with the problem.'
    Say ('  2. Open the drive and double-click  ' + $name + '\Start-Repair.cmd  (answer the Windows question with Yes).')
    Say ''
}

Invoke-PnhKitSync -Drive $Drive -Model $Model -Notes $Notes -Ref $Ref -Repo $Repo -Root $Root -Effort $Effort -SkipSpeedTest:$SkipSpeedTest
