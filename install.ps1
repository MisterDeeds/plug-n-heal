#Requires -Version 5.1
<#
.SYNOPSIS
    Plug'n'Heal one-line builder: downloads the current version from GitHub and builds the SSD.

.DESCRIPTION
    One line, nothing installed on the PC (the build goes to the SSD, the working files to a temp
    folder that is deleted when the build succeeds):

        irm https://raw.githubusercontent.com/MisterDeeds/plug-n-heal/main/install.ps1 | iex

    It asks for the SSD drive letter and builds the profile given in the PNH_PROFILE environment
    variable (default `full` = all seven models, about 82 GB of download). The SSD must already be
    formatted with exFAT (or NTFS); the helper never formats. To choose drive and profile without
    being asked:

        $env:PNH_DRIVE='E:'; $env:PNH_PROFILE='standard'
        irm https://raw.githubusercontent.com/MisterDeeds/plug-n-heal/main/install.ps1 | iex

    Works in Windows PowerShell 5.1 and PowerShell 7 (the builder itself needs Windows; on
    Linux/macOS use builder/build-drive.sh).

.PARAMETER Drive
    Letter of the SSD, for example `E:`. Falls back to the PNH_DRIVE environment variable. Without
    either, the helper lists the drives and asks.

.PARAMETER Profile
    `small`, `standard` or `full` (default). Falls back to the PNH_PROFILE environment variable.

.EXITCODES
    0 done, 1 failed (run the same line again to resume the downloads), 2 refused (wrong file
    system, not enough space, missing catalogue/pin files).
#>
param(
    [string]$Drive,
    [ValidateSet('', 'small', 'standard', 'full')][string]$Profile
)

if (-not $Drive) { $Drive = $env:PNH_DRIVE }
if (-not $Profile) { $Profile = $env:PNH_PROFILE }
if (-not $Profile) { $Profile = 'full' }

$ErrorActionPreference = 'Stop'
$repoZipUrl = $env:PNH_REPO_URL
if (-not $repoZipUrl) { $repoZipUrl = 'https://github.com/MisterDeeds/plug-n-heal/archive/refs/heads/main.zip' }
if ($PSVersionTable.PSVersion.Major -lt 6) { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 }

$temp = Join-Path $env:TEMP ('pnh-build-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
[void](New-Item -ItemType Directory -Path $temp -Force)
$rc = 0
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
    Write-Host ("Starting the builder: SSD {0}:/, profile {1}." -f $Drive, $Profile)
    Write-Host 'The build runs until the drive is ready. If it stops, run the same line again: it resumes where it left off.'
    # The builder runs in its own process (like BUILD.cmd does): an 'exit' inside a script that is
    # called in this session would close the whole console.
    $exe = 'powershell.exe'
    if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) { $exe = 'pwsh' }
    $proc = Start-Process -FilePath $exe -ArgumentList ('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File', $builder, '-NonInteractive', '-Drive', ($Drive + ':'), '-Profile', $Profile) -Wait -PassThru
    $rc = [int]$proc.ExitCode
}
catch {
    Write-Host ('Error: ' + $_.Exception.Message) -ForegroundColor Red
    $rc = 2
}

switch ($rc) {
    0 { Write-Host 'Done. The SSD is ready.' }
    1 { Write-Host 'The build did not finish (for example the connection dropped). Run the same line again to resume.' }
    2 { Write-Host 'The build was refused (for example the SSD is not exFAT/NTFS or is too small). Nothing was written to the SSD.' }
}
if ($rc -eq 0) {
    Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
else {
    Write-Host "Working files kept in: $temp"
}
exit $rc
