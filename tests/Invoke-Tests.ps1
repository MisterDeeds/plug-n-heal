#Requires -Version 5.1
<#
.SYNOPSIS
    Runs the Pester 5 tests of Plug'n'Heal with one consistent configuration (local runs and CI).

.DESCRIPTION
    The single entry point for the unit tests. Works in Windows PowerShell 5.1 and PowerShell 7 (Windows and Linux).

      * Runs tests\*.Tests.ps1 (or -Path) with Pester 5.5 or newer (but below 6).
      * Writes two result files into -OutputDirectory (default <repo>\TestResults):
          <Name>.nunit.xml   NUnit 2.5 format
          <Name>.junit.xml   JUnit format
      * On GitHub Actions ($env:GITHUB_STEP_SUMMARY is set) it appends a short Markdown summary to the job page;
        Pester itself marks failed tests as annotations (Output.CIFormat = Auto).
      * Exit code = failed tests + failed blocks + failed containers (the same count Pester uses), capped at 255
        because Linux only keeps the lowest 8 bits of an exit code (256 failures would otherwise read as 0).
        255 also means "the run itself could not start" (for example Pester missing).

    Install Pester once:
        Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck -MinimumVersion 5.5 -MaximumVersion 5.99

.PARAMETER Path
    Test files or folders. Default: every *.Tests.ps1 directly in the tests folder.
.PARAMETER Tag
    Run only tests with one of these tags.
.PARAMETER ExcludeTag
    Skip tests with one of these tags.
.PARAMETER OutputDirectory
    Folder for the result files. Default: <repo>\TestResults.
.PARAMETER Name
    Base name of the result files and title of the summary. Default: pester-<edition><major>.<minor>-<os>.
.PARAMETER Output
    Pester console verbosity: None, Normal (default), Detailed, Diagnostic.
.PARAMETER NoResultFiles
    Do not write the XML result files.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-Tests.ps1
.EXAMPLE
    pwsh -NoProfile -File tests/Invoke-Tests.ps1 -Path tests/Builder.Tests.ps1 -Output Detailed
#>
[CmdletBinding()]
param(
    [string[]]$Path,
    [string[]]$Tag,
    [string[]]$ExcludeTag,
    [string]$OutputDirectory,
    [string]$Name,
    [ValidateSet('None', 'Normal', 'Detailed', 'Diagnostic')]
    [string]$Output = 'Normal',
    [switch]$NoResultFiles
)

$ErrorActionPreference = 'Stop'
$testsDir = $PSScriptRoot
$repoRoot = Split-Path -Parent $testsDir

function Get-PnhTestOsName {
    # $IsWindows/$IsLinux do not exist in Windows PowerShell 5.1; read them only on PowerShell 6+.
    if ($PSVersionTable.PSVersion.Major -lt 6) { return 'windows' }
    if (Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue) { return 'windows' }
    if (Get-Variable -Name IsMacOS -ValueOnly -ErrorAction SilentlyContinue) { return 'macos' }
    return 'linux'
}

function Get-PnhTestExitCode {
    param([Parameter(Mandatory = $true)]$Run)
    $count = [int]$Run.FailedCount + [int]$Run.FailedBlocksCount + [int]$Run.FailedContainersCount
    return [Math]::Min(255, [Math]::Max(0, $count))
}

function Get-PnhTestSummaryMarkdown {
    param([Parameter(Mandatory = $true)]$Run, [Parameter(Mandatory = $true)][string]$Title, [string[]]$Files)
    $lines = New-Object System.Collections.Generic.List[string]
    $state = if ((Get-PnhTestExitCode -Run $Run) -eq 0) { 'passed' } else { 'FAILED' }
    $lines.Add(('### Pester {0}: {1}' -f $Title, $state))
    $lines.Add('')
    $lines.Add(('PowerShell {0} ({1}), Pester {2}, {3}' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, $Run.Version, (Get-PnhTestOsName)))
    $lines.Add('')
    $lines.Add('| Total | Passed | Failed | Skipped | Not run | Failed blocks | Failed files | Duration |')
    $lines.Add('|---:|---:|---:|---:|---:|---:|---:|---:|')
    $lines.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7:N1} s |' -f $Run.TotalCount, $Run.PassedCount, $Run.FailedCount, $Run.SkippedCount, $Run.NotRunCount, $Run.FailedBlocksCount, $Run.FailedContainersCount, $Run.Duration.TotalSeconds))
    $failed = @($Run.Failed)
    if ($failed.Count -gt 0) {
        $lines.Add('')
        $lines.Add('Failed tests (first 50):')
        $lines.Add('')
        foreach ($t in @($failed | Select-Object -First 50)) {
            $msg = ''
            if ($t.ErrorRecord -and @($t.ErrorRecord).Count -gt 0) { $msg = [string]@($t.ErrorRecord)[0].Exception.Message }
            $msg = ($msg -replace '\s+', ' ').Trim()
            if ($msg.Length -gt 200) { $msg = $msg.Substring(0, 200) + '...' }
            $lines.Add(('- `{0}`: {1}' -f $t.ExpandedPath, $msg.Replace('|', '/')))
        }
    }
    foreach ($b in @($Run.FailedBlocks | Select-Object -First 20)) { $lines.Add(('- block `{0}` failed' -f $b.ExpandedPath)) }
    foreach ($c in @($Run.FailedContainers | Select-Object -First 20)) { $lines.Add(('- file `{0}` failed to run' -f $c.Item)) }
    if ($Files) {
        $lines.Add('')
        $lines.Add('Result files: ' + (($Files | ForEach-Object { '`' + (Split-Path -Leaf $_) + '`' }) -join ', '))
    }
    $lines.Add('')
    return ($lines -join "`n")
}

# --- Pester 5.5+ (Windows PowerShell 5.1 ships Pester 3.4, which must not be picked up) --------------------------------
try {
    Import-Module -Name Pester -MinimumVersion 5.5.0 -MaximumVersion 5.99.99 -ErrorAction Stop
} catch {
    [Console]::Error.WriteLine('Pester 5.5 or newer (below 6) is not installed: ' + $_.Exception.Message)
    [Console]::Error.WriteLine('Install it with: Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck -MinimumVersion 5.5 -MaximumVersion 5.99')
    exit 255
}
$pester = Get-Module -Name Pester | Sort-Object Version -Descending | Select-Object -First 1

# --- What to run --------------------------------------------------------------------------------------------------------
if (-not $Path -or $Path.Count -eq 0) {
    $Path = @(Get-ChildItem -LiteralPath $testsDir -Filter '*.Tests.ps1' -File | Sort-Object Name | ForEach-Object { $_.FullName })
}
if ($Path.Count -eq 0) {
    [Console]::Error.WriteLine('No *.Tests.ps1 files found in ' + $testsDir)
    exit 255
}
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $repoRoot 'TestResults' }
if (-not $Name) {
    $Name = 'pester-{0}{1}.{2}-{3}' -f $PSVersionTable.PSEdition.ToLowerInvariant(), $PSVersionTable.PSVersion.Major, $PSVersionTable.PSVersion.Minor, (Get-PnhTestOsName)
}
$Name = $Name -replace '[^A-Za-z0-9._-]', '_'

$config = New-PesterConfiguration
$config.Run.Path = [string[]]$Path
$config.Run.PassThru = $true
$config.Run.Exit = $false
$config.Run.Throw = $false
$config.Output.Verbosity = $Output
$config.Output.CIFormat = 'Auto'
$config.Should.ErrorAction = 'Stop'
if ($Tag) { $config.Filter.Tag = [string[]]$Tag }
if ($ExcludeTag) { $config.Filter.ExcludeTag = [string[]]$ExcludeTag }

$nunitPath = $null
$junitPath = $null
if (-not $NoResultFiles) {
    if (-not (Test-Path -LiteralPath $OutputDirectory)) { [void](New-Item -ItemType Directory -Path $OutputDirectory -Force) }
    $OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).ProviderPath
    $nunitPath = Join-Path $OutputDirectory ($Name + '.nunit.xml')
    $junitPath = Join-Path $OutputDirectory ($Name + '.junit.xml')
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputFormat = 'NUnitXml'
    $config.TestResult.OutputPath = $nunitPath
    $config.TestResult.TestSuiteName = $Name
}

Write-Output ('Pester {0} on PowerShell {1} ({2}, {3}); {4} file(s); results: {5}' -f $pester.Version, $PSVersionTable.PSVersion, $PSVersionTable.PSEdition, (Get-PnhTestOsName), $Path.Count, $(if ($NoResultFiles) { 'none' } else { $OutputDirectory }))

$run = $null
try {
    $run = Invoke-Pester -Configuration $config
} catch {
    [Console]::Error.WriteLine('Invoke-Pester failed: ' + $_.Exception.Message)
    exit 255
}
if ($null -eq $run) {
    [Console]::Error.WriteLine('Invoke-Pester returned no result.')
    exit 255
}

$files = @()
if (-not $NoResultFiles) {
    try {
        Export-JUnitReport -Result $run -Path $junitPath
    } catch {
        [Console]::Error.WriteLine('Could not write the JUnit report: ' + $_.Exception.Message)
    }
    $files = @($nunitPath, $junitPath | Where-Object { Test-Path -LiteralPath $_ })
}

$code = Get-PnhTestExitCode -Run $run
Write-Output ('Total {0}, passed {1}, failed {2}, skipped {3}, not run {4}, failed blocks {5}, failed files {6} -> exit {7}' -f $run.TotalCount, $run.PassedCount, $run.FailedCount, $run.SkippedCount, $run.NotRunCount, $run.FailedBlocksCount, $run.FailedContainersCount, $code)

if ($env:GITHUB_STEP_SUMMARY) {
    try {
        $md = Get-PnhTestSummaryMarkdown -Run $run -Title $Name -Files $files
        [System.IO.File]::AppendAllText($env:GITHUB_STEP_SUMMARY, $md + "`n", (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        [Console]::Error.WriteLine('Could not write the step summary: ' + $_.Exception.Message)
    }
}

exit $code
