#Requires -Version 5.1
<#
.SYNOPSIS
    Plug'n'Heal one-line builder: downloads the current version from GitHub and builds the SSD.

.DESCRIPTION
    One line, nothing installed on the PC (the build goes to the SSD, the working files to a temp
    folder that is deleted when the build succeeds):

        irm https://raw.githubusercontent.com/MisterDeeds/plug-n-heal/main/install.ps1 | iex

    It asks for the SSD drive letter and puts everything on it:
      1. the Plug'n'Heal app with the profile given in PNH_PROFILE (default `full` = all seven
         models, about 82 GB of download), and then
      2. the network rescue kit (folder AI: Ollama runtime, Codex CLI and its language model,
         about 20 GB the first time) by running sync-drive.ps1 for the same drive.
    The SSD must already be formatted with exFAT (or NTFS); the helper never formats. Everything is
    resumable: run the same line again and it continues where it stopped. To choose without being
    asked:

        $env:PNH_DRIVE='E:'; $env:PNH_PROFILE='standard'; $env:PNH_KIT='no'
        irm https://raw.githubusercontent.com/MisterDeeds/plug-n-heal/main/install.ps1 | iex

    Works in Windows PowerShell 5.1 and PowerShell 7 (the builder itself needs Windows; on
    Linux/macOS use builder/build-drive.sh).

.PARAMETER Drive
    Letter of the SSD, for example `E:`. Falls back to the PNH_DRIVE environment variable. Without
    either, the helper lists the drives and asks.

.PARAMETER Profile
    `small`, `standard` or `full` (default). Falls back to the PNH_PROFILE environment variable.

.PARAMETER Kit
    `yes` (default) also sets up the network rescue kit after the app; `no` skips it. Falls back to
    the PNH_KIT environment variable (yes/no, 1/0, true/false).

.PARAMETER KitModel
    Ollama model tag for the rescue kit, for example `qwen3.5:9b` for a small SSD. Falls back to the
    PNH_KIT_MODEL environment variable. Default: what the drive already uses, else qwen3.8:27b.

.EXITCODES
    0 done, 1 failed (run the same line again to resume the downloads), 2 refused (wrong file
    system, not enough space, missing catalogue/pin files).
    Run as a file, the script ends with that exit code. Run with `irm ... | iex`, it only sets
    $LASTEXITCODE: an `exit` there would close the PowerShell window before the result can be read.
#>
param(
    [string]$Drive,
    [ValidateSet('', 'small', 'standard', 'full')][string]$Profile,
    [string]$Kit,
    [string]$KitModel
)

if (-not $Drive) { $Drive = $env:PNH_DRIVE }
if (-not $Profile) { $Profile = $env:PNH_PROFILE }
if (-not $Profile) { $Profile = 'full' }
if (-not $Kit) { $Kit = $env:PNH_KIT }
$kitOn = -not (@('no', 'n', '0', 'false', 'off') -contains ([string]$Kit).Trim().ToLowerInvariant())
if (-not $KitModel) { $KitModel = $env:PNH_KIT_MODEL }

$ErrorActionPreference = 'Stop'
$repoZipUrl = $env:PNH_REPO_URL
if (-not $repoZipUrl) { $repoZipUrl = 'https://github.com/MisterDeeds/plug-n-heal/archive/refs/heads/main.zip' }
if ($PSVersionTable.PSVersion.Major -lt 6) { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }

$temp = Join-Path $env:TEMP ('pnh-build-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void](New-Item -ItemType Directory -Path $temp -Force)
$rc = 0
$kitRc = $null   # 'irm | iex' runs in the caller's scope: no leftover from an earlier run
try {
    Write-Host "Downloading Plug'n'Heal from GitHub ($repoZipUrl) ..."
    $zip = Join-Path $temp 'plug-n-heal.zip'
    Invoke-WebRequest -Uri $repoZipUrl -OutFile $zip -UseBasicParsing
    $src = Join-Path $temp 'repo'
    Expand-Archive -LiteralPath $zip -DestinationPath $src -Force
    $root = @(Get-ChildItem -LiteralPath $src -Directory)[0]
    $builder = Join-Path $root.FullName 'builder/Build-Drive.ps1'
    if (-not (Test-Path -LiteralPath $builder)) { throw "Builder not found in the ZIP: $builder" }

    if (-not $Drive) {
        $candidates = @(Get-PSDrive -PSProvider FileSystem | Where-Object { $null -ne $_.Free } | Sort-Object Free)
        Write-Host ''
        Write-Host 'Which SSD should be prepared? (it must be exFAT or NTFS; the helper never formats)'
        foreach ($d in $candidates) {
            Write-Host ('   {0}    {1,10:N1} GB free    {2}' -f $d.Name, ($d.Free / 1GB), $d.ProviderDisplayName)
        }
        do { $Drive = (Read-Host 'Drive letter').Trim().TrimEnd(':') } while (-not $Drive)
    }
    $Drive = $Drive.TrimEnd(':')

    Write-Host ''
    Write-Host ("Starting the builder: SSD {0}:/, profile {1}{2}." -f $Drive, $Profile, $(if ($kitOn) { ', then the network rescue kit' } else { '' }))
    Write-Host 'The build runs until the drive is ready. If it stops, run the same line again: it resumes where it left off.'
    # The builder runs in its own process (like BUILD.cmd does): an 'exit' inside a script that is
    # called in this session would close the whole console. Start-Process joins the arguments with
    # spaces and does not quote them, so paths are quoted here (user names with spaces in TEMP).
    $exe = 'powershell.exe'
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { $exe = 'pwsh' }
    $proc = Start-Process -FilePath $exe -ArgumentList ('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File', ('"' + $builder + '"'), '-NonInteractive', '-Drive', ($Drive + ':'), '-Profile', $Profile) -Wait -PassThru
    $rc = [int]$proc.ExitCode

    if ($rc -eq 0 -and $kitOn) {
        # Network rescue kit on the same drive: sync-drive.ps1 from the same download, in this console.
        $sync = Join-Path $root.FullName 'sync-drive.ps1'
        if (-not (Test-Path -LiteralPath $sync)) { throw "sync-drive.ps1 not found in the ZIP: $sync" }
        Write-Host ''
        Write-Host ("The app is on the SSD. Now the network rescue kit on {0}: (Ollama, Codex CLI and the language model)." -f $Drive)
        $kitArgs = @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"' + $sync + '"'), '-Drive', $Drive)
        if ($KitModel) { $kitArgs += @('-Model', $KitModel) }
        $kitProc = Start-Process -FilePath $exe -ArgumentList $kitArgs -Wait -PassThru -NoNewWindow
        $kitRc = [int]$kitProc.ExitCode
    }
}
catch {
    Write-Host ('Error: ' + $_.Exception.Message) -ForegroundColor Red
    $rc = 2
}

$kitFailed = $kitOn -and ($rc -eq 0) -and ($null -ne $kitRc) -and ($kitRc -ne 0)
if ($kitFailed) {
    Write-Host 'The app is ready, but the network rescue kit did not finish (see the message above).' -ForegroundColor Yellow
    Write-Host 'Run the same line again (it checks the app and resumes the kit), or only the kit:'
    Write-Host '   irm -UseBasicParsing https://raw.githubusercontent.com/MisterDeeds/plug-n-heal/main/sync-drive.ps1 | iex'
    $rc = 1
}
else {
    switch ($rc) {
        0 {
            if ($kitOn) { Write-Host 'Done. Everything is on the SSD: the Plug''n''Heal app (START.cmd) and the network rescue kit (path shown above).' -ForegroundColor Green }
            else { Write-Host 'Done. The SSD is ready.' -ForegroundColor Green }
        }
        1 { Write-Host 'The build did not finish (for example the connection dropped). Run the same line again to resume.' }
        2 { Write-Host 'The build was refused (for example the SSD is not exFAT/NTFS or is too small). Nothing was written to the SSD.' }
    }
}
if ($rc -eq 0) {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
else {
    Write-Host "Working files kept in: $temp"
}
# Run as a file (BUILD.cmd, CI): exit code. Run with 'irm ... | iex': no exit, it would close the window.
if ($PSCommandPath) { exit $rc }
$global:LASTEXITCODE = $rc
