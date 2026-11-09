#Requires -Version 5.1
# Pester 5 tests for builder/Build-Drive.ps1 (pure functions and the curl retry loop with a mocked process).
# Run:  Invoke-Pester -Path tests/Builder.Tests.ps1
# Works on Windows PowerShell 5.1 and PowerShell 7 (also on Linux: nothing here starts curl, tar or Ollama).

BeforeAll {
    $script:BuilderScript = [System.IO.Path]::Combine($PSScriptRoot, '..', 'builder', 'Build-Drive.ps1')
    . $script:BuilderScript
    Set-PnhBuildLanguage -Language 'en'

    function script:New-TestCatalog {
        param([string]$Path, [switch]$NoProfiles, [switch]$ObjectProfiles)
        $doc = [ordered]@{
            schema = 1
            models = @(
                [ordered]@{ id = 'tiny'; tag = 'qwen3:0.6b'; bytes = 522653767; tier = 1 },
                [ordered]@{ id = 'mid'; tag = 'qwen3.5:4b-q4_K_M'; bytes = 3320000000; tier = 2 },
                [ordered]@{ id = 'big'; tag = 'qwen3.8:27b-q4_K_M'; bytes = 17740000000; tier = 5 }
            )
        }
        if (-not $NoProfiles) {
            $doc.profiles = [ordered]@{ small = @('tiny'); standard = @('tiny', 'mid', 'qwen3:0.6b'); full = @('tiny', 'mid', 'big') }
        }
        if ($ObjectProfiles) {
            # shape used by src/catalog/models.json: { "small": { "description": ..., "models": [tags], "bytes": n } }
            $doc.profiles = [ordered]@{
                small    = [ordered]@{ description = 'x'; models = @('qwen3:0.6b'); bytes = 1 }
                standard = [ordered]@{ description = 'x'; models = @('qwen3:0.6b', 'qwen3.5:4b-q4_K_M'); bytes = 1 }
                full     = [ordered]@{ description = 'x'; models = @('qwen3:0.6b', 'qwen3.5:4b-q4_K_M', 'big'); bytes = 1 }
            }
        }
        [System.IO.File]::WriteAllText($Path, ($doc | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
        return $Path
    }

    function script:New-TestManifest {
        param([int64[]]$LayerSizes, [string]$Seed = 'a')
        $i = 0
        $layers = foreach ($s in $LayerSizes) {
            $i++
            [pscustomobject]@{ mediaType = $(if ($i -eq 2) { 'application/vnd.ollama.image.license' } else { 'application/vnd.ollama.image.model' }); digest = ('sha256:' + ($Seed * 63) + $i); size = $s }
        }
        return [pscustomobject]@{
            schemaVersion = 2
            config        = [pscustomobject]@{ mediaType = 'application/vnd.docker.container.image.v1+json'; digest = ('sha256:' + ($Seed * 63) + '0'); size = 100 }
            layers        = @($layers)
        }
    }
}

Describe 'Script file' {
    It 'parses without errors' {
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:BuilderScript, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }
    It 'has a UTF-8 BOM when it contains non-ASCII text (Windows PowerShell 5.1 reads BOM-less files as ANSI)' {
        $bytes = [System.IO.File]::ReadAllBytes($script:BuilderScript)
        $nonAscii = @($bytes | Where-Object { $_ -gt 127 }).Count
        if ($nonAscii -gt 0) { ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) | Should -BeTrue }
    }
    It 'does not run the builder when dot-sourced' {
        Get-Command Invoke-PnhBuild -CommandType Function | Should -Not -BeNullOrEmpty
    }
    It 'pins Ollama 0.40.15 in versions.json' {
        $v = Read-PnhVersions -Path ([System.IO.Path]::Combine($PSScriptRoot, '..', 'builder', 'versions.json'))
        $v.ollama.version | Should -Be '0.40.15'
        $v.ollama.asset | Should -Be 'ollama-windows-amd64.zip'
        [int64]$v.ollama.size | Should -Be 1614941966
        $v.ollama.sha256 | Should -Be '9ca74a7ab66ec86870b1eecac7df160df08dc4e3a291ab5d2d59bcf9310221c6'
        $v.ollama.url | Should -Be 'https://github.com/ollama/ollama/releases/download/v0.40.15/ollama-windows-amd64.zip'
    }
    It 'README template contains every placeholder' {
        $t = [System.IO.File]::ReadAllText([System.IO.Path]::Combine($PSScriptRoot, '..', 'builder', 'README.txt.template'))
        foreach ($k in 'BUILT_AT', 'BUILDER', 'OLLAMA_VERSION', 'PROFILE', 'MODELS') { $t | Should -Match ([regex]::Escape('{{' + $k + '}}')) }
    }
}

Describe 'Drive root and path building' {
    It 'normalises drive letters: <In> -> <Out>' -TestCases @(
        @{ In = 'e'; Out = 'E:\' }, @{ In = 'E:'; Out = 'E:\' }, @{ In = 'e:\'; Out = 'E:\' }, @{ In = ' F: '; Out = 'F:\' }
    ) {
        ConvertTo-PnhDriveRoot -Drive $In | Should -Be $Out
    }
    It 'builds every path of the drive layout under <drive>\PlugNHeal' {
        $root = $TestDrive
        $p = Get-PnhBuildPaths -DriveRoot $root
        $c = { param([string[]]$a) [System.IO.Path]::Combine($a) }
        $p.Root | Should -Be (& $c @($root, 'PlugNHeal'))
        $p.App | Should -Be (& $c @($root, 'PlugNHeal', 'app'))
        $p.OllamaDir | Should -Be (& $c @($root, 'PlugNHeal', 'runtime', 'ollama'))
        $p.OllamaExe | Should -Be (& $c @($root, 'PlugNHeal', 'runtime', 'ollama', 'ollama.exe'))
        $p.VulkanDir | Should -Be (& $c @($root, 'PlugNHeal', 'runtime', 'ollama', 'lib', 'ollama', 'vulkan'))
        $p.Models | Should -Be (& $c @($root, 'PlugNHeal', 'models'))
        $p.Home | Should -Be (& $c @($root, 'PlugNHeal', 'home'))
        $p.Licenses | Should -Be (& $c @($root, 'PlugNHeal', 'licenses'))
        $p.DriveJson | Should -Be (& $c @($root, 'PlugNHeal', 'drive.json'))
        $p.StartCmd | Should -Be (& $c @($root, 'START.cmd'))
        $p.Readme | Should -Be (& $c @($root, 'README.txt'))
    }
    It 'allows only PlugNHeal, START.cmd and README.txt' {
        $p = Get-PnhBuildPaths -DriveRoot $TestDrive
        Test-PnhPathAllowed -Path $p.Root -Paths $p | Should -BeTrue
        Test-PnhPathAllowed -Path ([System.IO.Path]::Combine($p.Models, 'blobs', 'x')) -Paths $p | Should -BeTrue
        Test-PnhPathAllowed -Path $p.StartCmd -Paths $p | Should -BeTrue
        Test-PnhPathAllowed -Path $p.Readme -Paths $p | Should -BeTrue
        Test-PnhPathAllowed -Path ([System.IO.Path]::Combine($TestDrive, 'Photos', 'a.jpg')) -Paths $p | Should -BeFalse
        Test-PnhPathAllowed -Path ([System.IO.Path]::Combine($TestDrive, 'PlugNHealX')) -Paths $p | Should -BeFalse
        Test-PnhPathAllowed -Path ([System.IO.Path]::Combine($p.Root, '..', 'other.txt')) -Paths $p | Should -BeFalse
        Test-PnhPathAllowed -Path ([System.IO.Path]::Combine($TestDrive, 'start.cmd.bak')) -Paths $p | Should -BeFalse
        { Assert-PnhPathAllowed -Path ([System.IO.Path]::Combine($TestDrive, 'x.txt')) -Paths $p } | Should -Throw
    }
    It 'builds manifest and blob paths like Ollama' {
        $m = [System.IO.Path]::Combine('M', 'manifests', 'registry.ollama.ai', 'library', 'qwen3.5', '2b-q4_K_M')
        Get-PnhManifestPath -ModelsDir 'M' -Tag 'qwen3.5:2b-q4_K_M' | Should -Be $m
        Get-PnhManifestPath -ModelsDir 'M' -Tag 'someone/model' | Should -Be ([System.IO.Path]::Combine('M', 'manifests', 'registry.ollama.ai', 'someone', 'model', 'latest'))
        $hex = 'ab' * 32
        Get-PnhBlobPath -ModelsDir 'M' -Digest "sha256:$hex" | Should -Be ([System.IO.Path]::Combine('M', 'blobs', "sha256-$hex"))
        { Get-PnhBlobPath -ModelsDir 'M' -Digest 'sha256:xyz' } | Should -Throw
        Get-PnhSafeTagName -Tag 'qwen3:0.6b' | Should -Be 'qwen3_0.6b'
    }
    It 'splits model tags: <Tag>' -TestCases @(
        @{ Tag = 'qwen3:0.6b'; Ns = 'library'; Name = 'qwen3'; T = '0.6b' },
        @{ Tag = 'qwen3.8:27b-q4_K_M'; Ns = 'library'; Name = 'qwen3.8'; T = '27b-q4_K_M' },
        @{ Tag = 'lfm3'; Ns = 'library'; Name = 'lfm3'; T = 'latest' },
        @{ Tag = 'user/model:v1'; Ns = 'user'; Name = 'model'; T = 'v1' }
    ) {
        $s = Split-PnhModelTag -Tag $Tag
        $s.Namespace | Should -Be $Ns; $s.Name | Should -Be $Name; $s.Tag | Should -Be $T
    }
    It 'rejects unsupported model names' {
        { Split-PnhModelTag -Tag 'hf.co/a/b:c' } | Should -Throw
        { Split-PnhModelTag -Tag 'bad name:x' } | Should -Throw
        { Split-PnhModelTag -Tag 'qwen3:../x' } | Should -Throw
    }
    It 'builds the per-process Ollama environment' {
        $p = Get-PnhBuildPaths -DriveRoot $TestDrive
        $e = Get-PnhOllamaEnvironment -Paths $p -Port 51234 -CurrentPath 'C:\Windows\system32'
        $e.OLLAMA_MODELS | Should -Be $p.Models
        $e.OLLAMA_HOST | Should -Be '127.0.0.1:51234'
        $e.OLLAMA_NOPRUNE | Should -Be '1'
        $e.USERPROFILE | Should -Be $p.Home
        $e.HOME | Should -Be $p.Home
        $e.PATH | Should -Be ('{0};{1};C:\Windows\system32' -f $p.VulkanDir, $p.OllamaDir)
    }
}

Describe 'File system check (FAT32 is refused, never formatted)' {
    It '<Fs> -> ok=<Ok>, reason=<Reason>' -TestCases @(
        @{ Fs = 'exFAT'; Ok = $true; Reason = 'ok' }, @{ Fs = 'NTFS'; Ok = $true; Reason = 'ok' },
        @{ Fs = 'ntfs'; Ok = $true; Reason = 'ok' }, @{ Fs = 'FAT32'; Ok = $false; Reason = 'fat' },
        @{ Fs = 'fat32'; Ok = $false; Reason = 'fat' }, @{ Fs = 'FAT'; Ok = $false; Reason = 'fat' },
        @{ Fs = 'vfat'; Ok = $false; Reason = 'fat' }, @{ Fs = 'ReFS'; Ok = $false; Reason = 'fs' },
        @{ Fs = ''; Ok = $false; Reason = 'fs' }
    ) {
        $r = Test-PnhFileSystem -FileSystem $Fs
        $r.Ok | Should -Be $Ok
        $r.Reason | Should -Be $Reason
    }
    It 'recognises the Windows drive' {
        Test-PnhSystemDrive -DriveRoot 'C:\' -SystemDrive 'C:' | Should -BeTrue
        Test-PnhSystemDrive -DriveRoot 'c:' -SystemDrive 'C:' | Should -BeTrue
        Test-PnhSystemDrive -DriveRoot 'E:\' -SystemDrive 'C:' | Should -BeFalse
    }
    It 'explains exFAT formatting without offering to format' {
        $t = Get-PnhBuildText 'fat.text' @('FAT32')
        $t | Should -Match 'exFAT'
        $t | Should -Match 'never formats'
    }
    Context 'Invoke-PnhBuild on a FAT32 drive' {
        BeforeAll {
            $script:fakeRepo = Join-Path $TestDrive 'repo'
            $script:fakeDrive = Join-Path $TestDrive 'drive'
            [void](New-Item -ItemType Directory -Force -Path ([System.IO.Path]::Combine($fakeRepo, 'src', 'catalog')), $fakeDrive)
            Set-Content -LiteralPath ([System.IO.Path]::Combine($fakeRepo, 'src', 'START.cmd')) -Value '@echo off'
            New-TestCatalog -Path ([System.IO.Path]::Combine($fakeRepo, 'src', 'catalog', 'models.json')) | Out-Null
            Set-Content -LiteralPath ([System.IO.Path]::Combine($fakeDrive, 'holiday.jpg')) -Value 'keep me'
        }
        It 'refuses with code fat and leaves the drive untouched' {
            Mock Get-PnhDriveInfo { [pscustomobject]@{ Root = $DriveRoot; FileSystem = 'FAT32'; FreeBytes = 100GB; SizeBytes = 128GB; Label = 'X'; DriveType = 'Removable' } }
            Mock Get-PnhRegistryManifest { throw 'must not be called' }
            $err = $null
            try { Invoke-PnhBuild -DriveRoot $fakeDrive -ProfileName 'small' -RepoRoot $fakeRepo } catch { $err = $_ }
            $err | Should -Not -BeNullOrEmpty
            Get-PnhErrorCode $err | Should -Be 'fat'
            Get-PnhExitCode (Get-PnhErrorCode $err) | Should -Be 2
            @(Get-ChildItem -LiteralPath $fakeDrive -Force).Name | Should -Be @('holiday.jpg')
            Should -Invoke Get-PnhRegistryManifest -Times 0
        }
        It 'refuses when the profile does not fit, before downloading anything' {
            Mock Get-PnhDriveInfo { [pscustomobject]@{ Root = $DriveRoot; FileSystem = 'exFAT'; FreeBytes = 1GB; SizeBytes = 16GB; Label = 'X'; DriveType = 'Removable' } }
            Mock Get-PnhRegistryManifest { [pscustomobject]@{ Raw = '{}'; Manifest = (New-TestManifest -LayerSizes @(522653567, 100)); Url = 'x' } }
            Mock Invoke-PnhDownload { throw 'must not be called' }
            $err = $null
            try { Invoke-PnhBuild -DriveRoot $fakeDrive -ProfileName 'small' -RepoRoot $fakeRepo } catch { $err = $_ }
            Get-PnhErrorCode $err | Should -Be 'space'
            Should -Invoke Invoke-PnhDownload -Times 0
        }
        It 'refuses a model whose registry size differs from the catalogue by more than 1 %' {
            Mock Get-PnhDriveInfo { [pscustomobject]@{ Root = $DriveRoot; FileSystem = 'exFAT'; FreeBytes = 500GB; SizeBytes = 1TB; Label = 'X'; DriveType = 'Fixed' } }
            Mock Get-PnhRegistryManifest { [pscustomobject]@{ Raw = '{}'; Manifest = (New-TestManifest -LayerSizes @(600000000, 100)); Url = 'x' } }
            $err = $null
            try { Invoke-PnhBuild -DriveRoot $fakeDrive -ProfileName 'small' -RepoRoot $fakeRepo } catch { $err = $_ }
            Get-PnhErrorCode $err | Should -Be 'sizeMismatch'
        }
    }
}

Describe 'Model catalogue and profiles' {
    BeforeAll { $script:cat = Read-PnhBuildCatalog -Path (New-TestCatalog -Path (Join-Path $TestDrive 'models.json')) }
    It 'fails with a clear message when models.json is missing' {
        $missing = [System.IO.Path]::Combine($TestDrive, 'nope', 'models.json')
        $err = $null
        try { Read-PnhBuildCatalog -Path $missing } catch { $err = $_ }
        Get-PnhErrorCode $err | Should -Be 'catalog'
        Get-PnhErrorText $err | Should -Match ([regex]::Escape($missing))
    }
    It 'fails when the profiles object is missing' {
        $p = New-TestCatalog -Path (Join-Path $TestDrive 'noprof.json') -NoProfiles
        $err = $null
        try { Read-PnhBuildCatalog -Path $p } catch { $err = $_ }
        Get-PnhErrorCode $err | Should -Be 'catalog'
        Get-PnhErrorText $err | Should -Match 'profiles'
    }
    It 'fails on broken JSON' {
        $p = Join-Path $TestDrive 'broken.json'
        Set-Content -LiteralPath $p -Value '{ "models": [ '
        { Read-PnhBuildCatalog -Path $p } | Should -Throw
    }
    It 'resolves profile <Name> to <Tags>' -TestCases @(
        @{ Name = 'small'; Tags = @('qwen3:0.6b') },
        @{ Name = 'standard'; Tags = @('qwen3:0.6b', 'qwen3.5:4b-q4_K_M') },
        @{ Name = 'full'; Tags = @('qwen3:0.6b', 'qwen3.5:4b-q4_K_M', 'qwen3.8:27b-q4_K_M') }
    ) {
        @(Resolve-PnhBuildProfile -Catalog $cat -Name $Name | ForEach-Object { $_.tag }) | Should -Be $Tags
    }
    It 'reads profiles given as objects with a models list of tags (<Name>)' -TestCases @(
        @{ Name = 'small'; Count = 1 }, @{ Name = 'standard'; Count = 2 }, @{ Name = 'full'; Count = 3 }
    ) {
        $oc = Read-PnhBuildCatalog -Path (New-TestCatalog -Path (Join-Path $TestDrive 'objprof.json') -ObjectProfiles)
        @(Resolve-PnhBuildProfile -Catalog $oc -Name $Name).Count | Should -Be $Count
    }
    It 'reads the real src/catalog/models.json when it exists' {
        $real = [System.IO.Path]::Combine($PSScriptRoot, '..', 'src', 'catalog', 'models.json')
        if (-not (Test-Path -LiteralPath $real)) { Set-ItResult -Skipped -Because 'src/catalog/models.json not present'; return }
        $rc = Read-PnhBuildCatalog -Path $real
        foreach ($n in 'small', 'standard', 'full') { @(Resolve-PnhBuildProfile -Catalog $rc -Name $n).Count | Should -BeGreaterThan 0 }
        (Get-PnhProfileBytes -Catalog $rc -Name 'small') | Should -BeLessThan (Get-PnhProfileBytes -Catalog $rc -Name 'full')
    }
    It 'refuses unknown profiles and unknown model ids' {
        $err = $null
        try { Resolve-PnhBuildProfile -Catalog $cat -Name 'huge' } catch { $err = $_ }
        Get-PnhErrorCode $err | Should -Be 'profile'
        $bad = $cat | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $bad.profiles.small = @('ghost')
        $err = $null
        try { Resolve-PnhBuildProfile -Catalog $bad -Name 'small' } catch { $err = $_ }
        Get-PnhErrorText $err | Should -Match 'ghost'
    }
    It 'adds up profile sizes (each tag once)' {
        Get-PnhProfileBytes -Catalog $cat -Name 'small' | Should -Be 522653767
        Get-PnhProfileBytes -Catalog $cat -Name 'standard' | Should -Be (522653767 + 3320000000)
        Get-PnhProfileBytes -Catalog $cat -Name 'full' | Should -Be (522653767 + 3320000000 + 17740000000)
    }
    It 'suggests a drive size: <Bytes> -> <Gb> GB' -TestCases @(
        @{ Bytes = 5e9; Gb = 16 }, @{ Bytes = 30e9; Gb = 64 }, @{ Bytes = 62e9; Gb = 128 }, @{ Bytes = 119e9; Gb = 128 }, @{ Bytes = 120e9; Gb = 256 }
    ) {
        Get-PnhSuggestedDriveGB -Bytes ([int64]$Bytes) | Should -Be $Gb
    }
}

Describe 'Sizes and space' {
    It 'sums config and layers of a manifest' {
        $m = New-TestManifest -LayerSizes @(1000, 20, 3)
        Get-PnhManifestBytes -Manifest $m | Should -Be 1123
        @(Get-PnhManifestEntries -Manifest $m).Count | Should -Be 4
    }
    It 'accepts catalogue sizes within 1 %: expected <E>, actual <A> -> <R>' -TestCases @(
        @{ E = 1000000; A = 1000000; R = $true }, @{ E = 1000000; A = 1010000; R = $true }, @{ E = 1000000; A = 990000; R = $true },
        @{ E = 1000000; A = 1010001; R = $false }, @{ E = 1000000; A = 989999; R = $false }, @{ E = 0; A = 5; R = $true }
    ) {
        Test-PnhSizeMatch -Expected $E -Actual $A -TolerancePercent 1 | Should -Be $R
    }
    It 'counts what is missing, deduplicated by digest' {
        $blobs = @(
            [pscustomobject]@{ Digest = 'sha256:a'; Size = 1000; Complete = $false; PartialBytes = 0 },
            [pscustomobject]@{ Digest = 'sha256:a'; Size = 1000; Complete = $false; PartialBytes = 0 },
            [pscustomobject]@{ Digest = 'sha256:b'; Size = 500; Complete = $true; PartialBytes = 0 },
            [pscustomobject]@{ Digest = 'sha256:c'; Size = 300; Complete = $false; PartialBytes = 300 }
        )
        $n = Measure-PnhBuildNeed -RuntimeInstalled $false -ZipSize 100 -ZipHave 40 -ExtractedBytes 250 -Blobs $blobs -ReserveBytes 7
        $n.DownloadBytes | Should -Be (60 + 1000 + 300)
        $n.DiskBytes | Should -Be (60 + 250 + 1000 + 0 + 7)
        $n2 = Measure-PnhBuildNeed -RuntimeInstalled $true -ZipSize 100 -ZipHave 0 -ExtractedBytes 250 -Blobs @() -ReserveBytes 7
        $n2.DownloadBytes | Should -Be 0
        $n2.DiskBytes | Should -Be 7
    }
    It 'formats bytes as GB with one decimal' {
        Format-PnhBytes 522653767 | Should -Be '0.5 GB'
        Format-PnhBytes 17740000000 | Should -Be '17.7 GB'
    }
}

Describe 'Remaining time in plain words' {
    It '<S> s -> <Text>' -TestCases @(
        @{ S = $null; Text = 'estimating the time left' }, @{ S = 30; Text = 'less than a minute left' },
        @{ S = 60; Text = 'about 1 minute left' }, @{ S = 61; Text = 'about 2 minutes left' },
        @{ S = 3599; Text = 'about 60 minutes left' }, @{ S = 5400; Text = 'about 1 hour and 30 minutes left' },
        @{ S = 7200; Text = 'about 2 hours left' }, @{ S = 9000; Text = 'about 2 hours and 30 minutes left' }
    ) {
        Format-PnhDuration $S | Should -Be $Text
    }
    It 'speaks German' {
        Set-PnhBuildLanguage -Language 'de'
        try {
            Format-PnhDuration 600 | Should -Be 'noch etwa 10 Minuten'
            Format-PnhDuration 3900 | Should -Be 'noch etwa 65 Minuten'
            Format-PnhDuration 9000 | Should -Be 'noch etwa 2 Stunden und 30 Minuten'
            Format-PnhProgressText -Done 2100000000 -Total 5200000000 -RemainingSeconds 360 | Should -Be '2.1 GB von 5.2 GB geladen, noch etwa 6 Minuten'
        } finally { Set-PnhBuildLanguage -Language 'en' }
    }
    It 'estimates from a moving window and ignores resumed bytes' {
        $st = New-PnhProgress -TotalBytes 1000
        $t0 = [datetime]'2026-11-09T10:00:00Z'
        $st.Resumed = 400   # a resumed blob reports 400 bytes at once: not speed
        Add-PnhProgressSample -State $st -Time $t0 -Done 400
        Get-PnhRemainingSeconds -State $st | Should -BeNullOrEmpty
        Add-PnhProgressSample -State $st -Time $t0.AddSeconds(10) -Done 500
        Get-PnhRemainingSeconds -State $st | Should -Be 50   # 10 B/s, 500 B left
        Add-PnhProgressSample -State $st -Time $t0.AddSeconds(100) -Done 1000
        Get-PnhRemainingSeconds -State $st | Should -Be 0
    }
}

Describe 'README.txt and drive.json' {
    It 'fills the template with CRLF line ends and one final line break' {
        $models = @([pscustomobject]@{ id = 'tiny'; tag = 'qwen3:0.6b'; bytes = 522653767 }, [pscustomobject]@{ id = 'mid'; tag = 'qwen3.5:4b-q4_K_M'; bytes = 3320000000 })
        $r = Format-PnhReadme -Template "A {{PROFILE}}`nB {{OLLAMA_VERSION}}`n{{MODELS}}`nEnd`n" -Values @{ PROFILE = 'small'; OLLAMA_VERSION = '0.40.15' } -Models $models
        $r | Should -Be "A small`r`nB 0.40.15`r`n  - qwen3:0.6b  (0.5 GB)`r`n  - qwen3.5:4b-q4_K_M  (3.3 GB)`r`nEnd`r`n"
    }
    It 'writes drive.json in the documented shape' {
        $j = ConvertTo-PnhDriveJson -BuiltAt '2026-11-09T22:09:20Z' -Builder 'plug-n-heal 0.1.0' -Ollama '0.40.15' -ProfileName 'small' -Models @([pscustomobject]@{ id = 'qwen3-0.6b'; tag = 'qwen3:0.6b'; bytes = 522653767 })
        $expected = "{`n  `"builtAt`": `"2026-11-09T22:09:20Z`",`n  `"builder`": `"plug-n-heal 0.1.0`",`n  `"ollama`": `"0.40.15`",`n  `"profile`": `"small`",`n  `"models`": [`n    {`n      `"id`": `"qwen3-0.6b`",`n      `"tag`": `"qwen3:0.6b`",`n      `"bytes`": 522653767`n    }`n  ]`n}`n"
        $j | Should -Be $expected
        $o = $j | ConvertFrom-Json
        $o.models[0].bytes | Should -Be 522653767
        (ConvertTo-PnhDriveJson -BuiltAt 'x' -Builder 'b' -Ollama 'o' -ProfileName 'p' -Models @()) | ConvertFrom-Json | ForEach-Object { @($_.models).Count } | Should -Be 0
    }
}

Describe 'Model state on the drive' {
    BeforeAll {
        $script:md = Join-Path $TestDrive 'models'
        $script:man = New-TestManifest -LayerSizes @(10, 5) -Seed 'c'
        foreach ($e in Get-PnhManifestEntries -Manifest $man) {
            $bp = Get-PnhBlobPath -ModelsDir $md -Digest $e.Digest
            [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $bp))
            [System.IO.File]::WriteAllBytes($bp, (New-Object byte[] $e.Size))
        }
        $mp = Get-PnhManifestPath -ModelsDir $md -Tag 'qwen3:0.6b'
        [void](New-Item -ItemType Directory -Force -Path (Split-Path -Parent $mp))
        [System.IO.File]::WriteAllText($mp, ($man | ConvertTo-Json -Depth 5 -Compress))
    }
    It 'is complete when every blob has the size of its manifest entry' {
        $st = Test-PnhModelComplete -ModelsDir $md -Tag 'qwen3:0.6b' -Expected $man
        $st.Complete | Should -BeTrue
        $st.Bytes | Should -Be 115
    }
    It 'is incomplete when the registry has another manifest' {
        (Test-PnhModelComplete -ModelsDir $md -Tag 'qwen3:0.6b' -Expected (New-TestManifest -LayerSizes @(10, 5) -Seed 'd')).Complete | Should -BeFalse
    }
    It 'is incomplete when a blob is short' {
        $e = @(Get-PnhManifestEntries -Manifest $man)[1]
        $bp = Get-PnhBlobPath -ModelsDir $md -Digest $e.Digest
        [System.IO.File]::WriteAllBytes($bp, (New-Object byte[] 3))
        try {
            $st = Test-PnhModelComplete -ModelsDir $md -Tag 'qwen3:0.6b'
            $st.Complete | Should -BeFalse
            $st.Reason | Should -Match ([regex]::Escape($e.Digest))
        } finally { [System.IO.File]::WriteAllBytes($bp, (New-Object byte[] $e.Size)) }
    }
    It 'treats the manifest Ollama writes (with a copy of the registry manifest as extra layer) as the same model' {
        $local = $man | ConvertTo-Json -Depth 5 | ConvertFrom-Json
        $copy = [pscustomobject]@{ mediaType = 'application/vnd.docker.distribution.manifest.v2+json'; digest = ('sha256:' + ('e' * 64)); size = 858 }
        $local.layers = @($local.layers) + $copy
        Get-PnhManifestKey $local | Should -Be (Get-PnhManifestKey $man)
        Get-PnhManifestBytes $local | Should -Be (Get-PnhManifestBytes $man)
        Test-PnhManifestCopyEntry ([pscustomobject]@{ MediaType = 'application/vnd.ollama.image.model' }) | Should -BeFalse
    }
    It 'is incomplete without a manifest' {
        (Test-PnhModelComplete -ModelsDir $md -Tag 'qwen3:1.7b').Complete | Should -BeFalse
    }
}

Describe 'Copying src\ to the drive' {
    It 'mirrors src into app, copies START.cmd to the root and touches nothing else' {
        $repo = Join-Path $TestDrive 'r2'
        $drive = Join-Path $TestDrive 'd2'
        $src = Join-Path $repo 'src'
        [void](New-Item -ItemType Directory -Force -Path (Join-Path $src 'lib'), $drive)
        Set-Content -LiteralPath (Join-Path $src 'START.cmd') -Value '@echo off'
        Set-Content -LiteralPath (Join-Path (Join-Path $src 'lib') 'Common.ps1') -Value '# new'
        Set-Content -LiteralPath (Join-Path $drive 'mine.txt') -Value 'user file'
        $p = Get-PnhBuildPaths -DriveRoot $drive
        [void](New-Item -ItemType Directory -Force -Path (Join-Path $p.App 'old'))
        Set-Content -LiteralPath (Join-Path (Join-Path $p.App 'old') 'Stale.ps1') -Value '# stale'
        Copy-PnhApp -Paths $p -SourceDir $src
        Test-Path -LiteralPath (Join-Path (Join-Path $p.App 'lib') 'Common.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $p.App 'START.cmd') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $p.App 'old') | Should -BeFalse
        Test-Path -LiteralPath $p.StartCmd | Should -BeTrue
        Get-Content -LiteralPath (Join-Path $drive 'mine.txt') | Should -Be 'user file'
        @(Get-ChildItem -LiteralPath $drive -Force | ForEach-Object { $_.Name } | Sort-Object) | Should -Be @('mine.txt', 'PlugNHeal', 'START.cmd')
    }
    It 'refuses a src without START.cmd' {
        $src = Join-Path $TestDrive 'emptysrc'
        [void](New-Item -ItemType Directory -Force -Path $src)
        $err = $null
        try { Copy-PnhApp -Paths (Get-PnhBuildPaths -DriveRoot (Join-Path $TestDrive 'd3')) -SourceDir $src } catch { $err = $_ }
        Get-PnhErrorCode $err | Should -Be 'src'
    }
    It 'refuses to write outside the allowed paths' {
        $p = Get-PnhBuildPaths -DriveRoot (Join-Path $TestDrive 'd4')
        { Write-PnhTextFile -Path ([System.IO.Path]::Combine($TestDrive, 'd4', 'evil.txt')) -Text 'x' -Paths $p } | Should -Throw
    }
}

Describe 'curl retry loop (Invoke-PnhDownload, process mocked)' {
    BeforeAll {
        $script:content = [byte[]](1..100)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $script:contentSha = (($sha.ComputeHash($script:content) | ForEach-Object { $_.ToString('x2') }) -join '')
        $script:destination = Join-Path $TestDrive 'ollama.zip'
    }
    BeforeEach {
        Remove-Item -LiteralPath $script:destination -Force -ErrorAction SilentlyContinue
        # each fake curl run appends the next chunk and exits with the scripted code
        $script:fake = @{ Calls = 0; Plan = @(); Args = New-Object System.Collections.Generic.List[string] }
        Mock Start-Sleep { }
        Mock Start-PnhBuildProcess {
            $script:fake.Calls++
            $script:fake.Args.Add($ArgumentList)
            $step = $script:fake.Plan[$script:fake.Calls - 1]
            if ($step.Bytes -gt 0) {
                $have = 0
                if (Test-Path -LiteralPath $script:destination) { $have = (Get-Item -LiteralPath $script:destination).Length }
                $chunk = $script:content[$have..($have + $step.Bytes - 1)]
                $fs = [System.IO.File]::Open($script:destination, 'Append')
                try { $fs.Write($chunk, 0, $chunk.Length) } finally { $fs.Close() }
            }
            [pscustomobject]@{ Process = [pscustomobject]@{ HasExited = $true; ExitCode = $step.Exit }; StdOutTask = $null; StdErrTask = $null }
        }
    }
    It 'resumes after failed attempts until the file is complete, then checks sha256' {
        $script:fake.Plan = @(@{ Bytes = 40; Exit = 18 }, @{ Bytes = 30; Exit = 56 }, @{ Bytes = 30; Exit = 0 })
        $seen = New-Object System.Collections.Generic.List[int64]
        Invoke-PnhDownload -Url 'https://example.invalid/o.zip' -Destination $script:destination -ExpectedSize 100 -Sha256 $script:contentSha -CurlPath 'curl' -OnProgress { param($len) $seen.Add($len) }
        $script:fake.Calls | Should -Be 3
        (Get-Item -LiteralPath $script:destination).Length | Should -Be 100
        $script:fake.Args[0] | Should -Match '-L --fail -C - '
        $script:fake.Args[0] | Should -Match ([regex]::Escape('-o "' + $script:destination + '" "https://example.invalid/o.zip"'))
        Should -Invoke Start-Sleep -Times 1 -ParameterFilter { $Seconds -eq 5 }
        Should -Invoke Start-Sleep -Times 1 -ParameterFilter { $Seconds -eq 10 }
        $seen | Should -Contain 40
        $seen | Should -Contain 100
    }
    It 'does not start curl when the file is already complete' {
        [System.IO.File]::WriteAllBytes($script:destination, $script:content)
        Invoke-PnhDownload -Url 'https://example.invalid/o.zip' -Destination $script:destination -ExpectedSize 100 -Sha256 $script:contentSha -CurlPath 'curl'
        $script:fake.Calls | Should -Be 0
    }
    It 'drops --ssl-revoke-best-effort when an old curl.exe does not know it (exit 2)' {
        $script:fake.Plan = @(@{ Bytes = 0; Exit = 2 }, @{ Bytes = 100; Exit = 0 })
        Invoke-PnhDownload -Url 'https://example.invalid/o.zip' -Destination $script:destination -ExpectedSize 100 -Sha256 $script:contentSha -CurlPath 'curl'
        $script:fake.Calls | Should -Be 2
        $script:fake.Args[0] | Should -Match 'ssl-revoke-best-effort'
        $script:fake.Args[1] | Should -Not -Match 'ssl-revoke-best-effort'
    }
    It 'starts the file over when the server refuses the range (exit 33)' {
        [System.IO.File]::WriteAllBytes($script:destination, [byte[]](9, 9, 9))
        $script:fake.Plan = @(@{ Bytes = 0; Exit = 33 }, @{ Bytes = 100; Exit = 0 })
        Invoke-PnhDownload -Url 'https://example.invalid/o.zip' -Destination $script:destination -ExpectedSize 100 -Sha256 $script:contentSha -CurlPath 'curl'
        [System.IO.File]::ReadAllBytes($script:destination)[0] | Should -Be 1
    }
    It 'gives up after MaxAttempts with code download' {
        $script:fake.Plan = @(@{ Bytes = 1; Exit = 28 }, @{ Bytes = 1; Exit = 28 }, @{ Bytes = 1; Exit = 28 })
        $err = $null
        try { Invoke-PnhDownload -Url 'https://example.invalid/o.zip' -Destination $script:destination -ExpectedSize 100 -CurlPath 'curl' -MaxAttempts 3 } catch { $err = $_ }
        Get-PnhErrorCode $err | Should -Be 'download'
        $script:fake.Calls | Should -Be 3
        (Get-Item -LiteralPath $script:destination).Length | Should -Be 3   # partial data stays for the next run
    }
    It 'downloads once more after a sha256 mismatch, then fails with code hash' {
        $script:fake.Plan = @(@{ Bytes = 100; Exit = 0 }, @{ Bytes = 100; Exit = 0 })
        $err = $null
        try { Invoke-PnhDownload -Url 'https://example.invalid/o.zip' -Destination $script:destination -ExpectedSize 100 -Sha256 ('0' * 64) -CurlPath 'curl' } catch { $err = $_ }
        Get-PnhErrorCode $err | Should -Be 'hash'
        $script:fake.Calls | Should -Be 2
        Test-Path -LiteralPath $script:destination | Should -BeFalse
    }
    It 'stops when cancelled' {
        $script:fake.Plan = @(@{ Bytes = 10; Exit = 0 })
        $script:PnhCancel = @{ Requested = $true }
        try {
            $err = $null
            try { Invoke-PnhDownload -Url 'https://example.invalid/o.zip' -Destination $script:destination -ExpectedSize 100 -CurlPath 'curl' } catch { $err = $_ }
            Get-PnhErrorCode $err | Should -Be 'cancelled'
            Get-PnhExitCode 'cancelled' | Should -Be 3
            $script:fake.Calls | Should -Be 0
        } finally { $script:PnhCancel = $null }
    }
}

Describe 'Errors and exit codes' {
    It 'keeps the error code through nested calls' {
        $err = $null
        try { & { & { throw (New-PnhBuildError -Code 'space' -Message 'too small') } } } catch { $err = $_ }
        Get-PnhErrorCode $err | Should -Be 'space'
        Get-PnhErrorText $err | Should -Be 'too small'
    }
    It 'maps <Code> to exit code <Exit>' -TestCases @(
        @{ Code = 'fat'; Exit = 2 }, @{ Code = 'space'; Exit = 2 }, @{ Code = 'catalog'; Exit = 2 },
        @{ Code = 'cancelled'; Exit = 3 }, @{ Code = 'download'; Exit = 1 }, @{ Code = 'error'; Exit = 1 }
    ) {
        Get-PnhExitCode $Code | Should -Be $Exit
    }
    It 'builds curl arguments for a resumable, silent, fail-on-HTTP-error download' {
        $a = New-PnhCurlArguments -Url 'https://x/y.zip' -Destination 'E:\PlugNHeal\downloads\y.zip' -RevokeBestEffort
        $a | Should -Be '-L --fail -C - -sS --connect-timeout 30 --speed-limit 1024 --speed-time 60 --ssl-revoke-best-effort -o "E:\PlugNHeal\downloads\y.zip" "https://x/y.zip"'
    }
}
