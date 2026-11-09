# Pester 5. Unit tests for src/lib/Models.ps1 and the catalogue src/catalog/models.json.

BeforeDiscovery {
    $catalogFile = Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'src') 'catalog'
    $catalogModels = @((ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText((Join-Path $catalogFile 'models.json'), [System.Text.Encoding]::UTF8))).models)
}

BeforeAll {
    . $PSScriptRoot/../src/lib/Models.ps1
    Set-StrictMode -Version 2
    $catalog = Get-PnhModelCatalog
    $allTags = @($catalog.models | ForEach-Object { $_.tag })

    # Hardware as Get-PnhHardware returns it. VRAM in MiB as nvidia-smi reports it, RAM as Windows reports it.
    function New-Hw {
        param([double]$VramMiB = 0, [string]$Vendor = 'nvidia', [double]$RamGiB = 16, [bool]$Integrated = $false, [string]$Name = 'GPU')
        $gpus = @()
        if ($VramMiB -gt 0) {
            $gpus = @(@{ Name = $Name; Vendor = $Vendor; VramBytes = [uint64]($VramMiB * 1MB); Integrated = $Integrated; Driver = '1' })
        }
        $best = 0
        if ($VramMiB -gt 0 -and -not $Integrated -and ($Vendor -eq 'nvidia' -or $Vendor -eq 'amd')) { $best = [uint64]($VramMiB * 1MB) }
        return @{ Gpus = $gpus; BestDedicatedVramBytes = $best; RamBytes = [uint64]($RamGiB * 1GB); FreeRamBytes = [uint64]($RamGiB * 0.5GB) }
    }
}

Describe 'Catalogue src/catalog/models.json' {
    It 'has schema 1 and six models' {
        $catalog.schema | Should -Be 1
        @($catalog.models).Count | Should -Be 6
    }
    It 'has unique ids and tags' {
        @($catalog.models.id | Select-Object -Unique).Count | Should -Be @($catalog.models).Count
        @($allTags | Select-Object -Unique).Count | Should -Be $allTags.Count
    }
    It 'entry <id> has all contract fields with valid values' -ForEach @($catalogModels | ForEach-Object { @{ id = $_.id; m = $_ } }) {
        foreach ($f in 'id', 'tag', 'bytes', 'license', 'tier', 'minVramGB', 'minRamGB', 'ctx', 'think', 'freeShell', 'default', 'notes', 'gguf', 'modelMediaType') {
            $m.PSObject.Properties[$f] | Should -Not -BeNullOrEmpty -Because "field $f is required"
        }
        $m.tag | Should -Match '^[a-z0-9.\-]+:[A-Za-z0-9._\-]+$'
        $m.tag | Should -Not -Match ':latest$' -Because 'floating tags change their blobs'
        [double]$m.bytes | Should -BeGreaterThan 1e9
        $m.license | Should -Be 'Apache-2.0'
        $m.tier | Should -BeIn @(1, 2, 3, 4)
        [double]$m.minVramGB | Should -BeGreaterThan 0
        [double]$m.minRamGB | Should -BeGreaterThan 0
        $m.think | Should -BeOfType [bool]
        $m.freeShell | Should -BeOfType [bool]
        $m.default | Should -BeOfType [bool]
        $m.gguf | Should -BeTrue
        $m.modelMediaType | Should -Be 'application/vnd.ollama.image.model'
        if ($m.tier -le 2) { $m.ctx | Should -Be 16384 } else { $m.ctx | Should -Be 32768 }
        $m.freeShell | Should -Be ($m.tier -eq 4) -Because 'only tier 4 may propose free PowerShell'
        if ($m.tier -le 2) { $m.think | Should -BeFalse -Because 'thinking costs minutes on CPU' }
    }
    It 'has a size consistent with its parts' {
        foreach ($m in $catalog.models) {
            ([double]$m.modelBytes + [double]$m.projectorBytes) | Should -BeLessOrEqual ([double]$m.bytes)
            ([double]$m.bytes - [double]$m.modelBytes - [double]$m.projectorBytes) | Should -BeLessThan 100000
        }
    }
    It 'has the profiles small, standard and full with existing tags and correct byte sums' {
        foreach ($name in 'small', 'standard', 'full') {
            $p = $catalog.profiles.$name
            $p | Should -Not -BeNullOrEmpty
            $sum = 0.0
            foreach ($t in $p.models) {
                $allTags | Should -Contain $t
                $sum += [double](@($catalog.models | Where-Object { $_.tag -eq $t })[0].bytes)
            }
            [double]$p.bytes | Should -Be $sum
        }
        @($catalog.profiles.small.models) | Should -Be @($catalog.models | Where-Object { $_.tier -le 2 } | ForEach-Object { $_.tag })
        @($catalog.profiles.standard.models) | Should -Be @($catalog.models | Where-Object { $_.default } | ForEach-Object { $_.tag })
        @($catalog.profiles.full.models).Count | Should -Be @($catalog.models).Count
        [double]$catalog.profiles.small.bytes | Should -BeLessThan 6e9
        [double]$catalog.profiles.standard.bytes | Should -BeLessThan 32e9
        [double]$catalog.profiles.full.bytes | Should -BeLessThan 64e9
    }
    It 'serialises with ConvertTo-Json -Depth 10' {
        { ConvertTo-Json -InputObject $catalog -Depth 10 } | Should -Not -Throw
    }
}

Describe 'Get-PnhModelContext' {
    It '<Case>' -ForEach @(
        @{ Case = 'GPU: catalogue ctx'; Entry = @{ ctx = 32768 }; Gpu = $true; Expect = 32768 }
        @{ Case = 'CPU: capped at 16384'; Entry = @{ ctx = 32768 }; Gpu = $false; Expect = 16384 }
        @{ Case = 'CPU: smaller ctx stays'; Entry = @{ ctx = 8192 }; Gpu = $false; Expect = 8192 }
        @{ Case = 'missing ctx counts as 16384'; Entry = @{ tag = 'x' }; Gpu = $true; Expect = 16384 }
        @{ Case = 'invalid ctx counts as 16384'; Entry = @{ ctx = 'lots' }; Gpu = $true; Expect = 16384 }
    ) {
        Get-PnhModelContext -ModelEntry $Entry -UseGpu:$Gpu | Should -Be $Expect
    }
    It 'works with catalogue entries (PSCustomObject)' {
        $big = @($catalog.models | Where-Object { $_.tag -eq 'qwen3.8:27b-q4_K_M' })[0]
        Get-PnhModelContext -ModelEntry $big -UseGpu | Should -Be 32768
        Get-PnhModelContext -ModelEntry $big | Should -Be 16384
    }
}

Describe 'Get-PnhInstalledModels' {
    BeforeAll {
        $models = Join-Path $TestDrive 'models'
        $blobs = Join-Path $models 'blobs'
        $null = New-Item -ItemType Directory -Path $blobs -Force
        function New-FakeModel([string]$Registry, [string]$Namespace, [string]$Name, [string]$Tag, [int[]]$Sizes, [switch]$MissingBlob) {
            $layers = @()
            $i = 0
            foreach ($size in $Sizes) {
                $hex = ('{0}{1}{2}{3}' -f $Name, $Tag, $i, 'x').GetHashCode().ToString('x8') * 8
                $digest = 'sha256:' + $hex
                if (-not ($MissingBlob -and $i -eq 0)) {
                    [System.IO.File]::WriteAllBytes((Join-Path $blobs ('sha256-' + $hex)), (New-Object byte[] $size))
                }
                $layers += @{ mediaType = 'application/vnd.ollama.image.model'; digest = $digest; size = $size }
                $i++
            }
            $dir = Join-Path (Join-Path (Join-Path (Join-Path $models 'manifests') $Registry) $Namespace) $Name
            $null = New-Item -ItemType Directory -Path $dir -Force
            $manifest = @{ schemaVersion = 2; config = $layers[-1]; layers = @($layers[0..($layers.Count - 2)]) }
            [System.IO.File]::WriteAllText((Join-Path $dir $Tag), (ConvertTo-Json -InputObject $manifest -Depth 5))
        }
        New-FakeModel 'registry.ollama.ai' 'library' 'qwen3.5' '4b-q4_K_M' @(10, 3)
        New-FakeModel 'registry.ollama.ai' 'library' 'qwen3.5' '2b-q4_K_M' @(7, 2) -MissingBlob
        New-FakeModel 'registry.ollama.ai' 'someone' 'tool-model' 'v1' @(5, 1)
        New-FakeModel 'hf.co' 'org' 'model' 'Q4' @(4, 1)

        # What Ollama 0.40.15 adds (measured): manifests-v2\ and metadata\*.json, and after a pull an extra layer
        # with a copy of the registry manifest. A model must count without that blob, and the extra folders must
        # not produce entries.
        $pulledDir = Join-Path $models 'manifests/registry.ollama.ai/library/qwen3.8'
        $null = New-Item -ItemType Directory -Path $pulledDir -Force
        $hexA = 'a' * 64
        $hexB = 'b' * 64
        [System.IO.File]::WriteAllBytes((Join-Path $blobs ('sha256-' + $hexA)), (New-Object byte[] 6))
        [System.IO.File]::WriteAllBytes((Join-Path $blobs ('sha256-' + $hexB)), (New-Object byte[] 2))
        $pulled = @{
            schemaVersion = 2; mediaType = 'application/vnd.docker.distribution.manifest.v2+json'
            config = @{ mediaType = 'application/vnd.docker.container.image.v1+json'; digest = ('sha256:' + $hexB); size = 2 }
            layers = @(
                @{ mediaType = 'application/vnd.ollama.image.model'; digest = ('sha256:' + $hexA); size = 6 }
                @{ mediaType = 'application/vnd.docker.distribution.manifest.v2+json'; digest = ('sha256:' + ('c' * 64)); size = 1088 }
            )
        }
        [System.IO.File]::WriteAllText((Join-Path $pulledDir '27b-q4_K_M'), (ConvertTo-Json -InputObject $pulled -Depth 5))
        $v2Dir = Join-Path $models 'manifests-v2/registry.ollama.ai/library/ghost'
        $null = New-Item -ItemType Directory -Path $v2Dir -Force
        [System.IO.File]::WriteAllText((Join-Path $v2Dir 'v2only'), '{}')
        $null = New-Item -ItemType Directory -Path (Join-Path $models 'metadata') -Force
        [System.IO.File]::WriteAllText((Join-Path $models 'metadata/x.json'), '{}')
    }

    It 'lists complete models as name:tag and ignores incomplete ones' {
        $found = @(Get-PnhInstalledModels -ModelsPath $models)
        $found | Should -Contain 'qwen3.5:4b-q4_K_M'
        $found | Should -Contain 'someone/tool-model:v1'
        $found | Should -Contain 'hf.co/org/model:Q4'
        $found | Should -Not -Contain 'qwen3.5:2b-q4_K_M'
        $found | Should -Contain 'qwen3.8:27b-q4_K_M' -Because 'the manifest-copy layer of a pull is not part of the model'
        $found | Should -Not -Contain 'ghost:v2only' -Because 'manifests-v2 is not the authoritative source'
        $found.Count | Should -Be 4
    }
    It 'lists incomplete models with -NoVerify' {
        @(Get-PnhInstalledModels -ModelsPath $models -NoVerify) | Should -Contain 'qwen3.5:2b-q4_K_M'
    }
    It 'detects a blob with the wrong size' {
        $m = Get-Content -Raw -LiteralPath (Join-Path $models 'manifests/registry.ollama.ai/library/qwen3.5/4b-q4_K_M') | ConvertFrom-Json
        $blob = Join-Path $blobs ($m.layers[0].digest.Replace(':', '-'))
        [System.IO.File]::WriteAllBytes($blob, (New-Object byte[] 1))
        @(Get-PnhInstalledModels -ModelsPath $models) | Should -Not -Contain 'qwen3.5:4b-q4_K_M'
    }
    It 'returns nothing when the folder does not exist' {
        @(Get-PnhInstalledModels -ModelsPath (Join-Path $TestDrive 'none')).Count | Should -Be 0
    }
}

Describe 'Select-PnhModel' {
    It '<Case>' -ForEach @(
        @{ Case = 'RTX 4090 24 GB, 32 GB RAM -> qwen3.8:27b'; Vram = 24564; Vendor = 'nvidia'; Ram = 31.8; Expect = 'qwen3.8:27b-q4_K_M'; Gpu = $true; Ctx = 32768; Reason = 'model.reason.gpu' }
        @{ Case = 'RTX 5090 32 GB -> qwen3.8:27b'; Vram = 32607; Vendor = 'nvidia'; Ram = 63.8; Expect = 'qwen3.8:27b-q4_K_M'; Gpu = $true; Ctx = 32768; Reason = 'model.reason.gpu' }
        @{ Case = '16 GB card, 32 GB RAM -> MoE fast mode'; Vram = 16376; Vendor = 'nvidia'; Ram = 31.8; Expect = 'qwen3.6:35b-a3b-mtp-q4_K_M'; Gpu = $true; Ctx = 32768; Reason = 'model.reason.gpu' }
        @{ Case = '16 GB card, 16 GB RAM -> 9b Q8'; Vram = 16376; Vendor = 'nvidia'; Ram = 15.8; Expect = 'qwen3.5:9b-q8_0'; Gpu = $true; Ctx = 32768; Reason = 'model.reason.gpu' }
        @{ Case = '12 GB card -> 9b Q4'; Vram = 12288; Vendor = 'nvidia'; Ram = 31.8; Expect = 'qwen3.5:9b-q4_K_M'; Gpu = $true; Ctx = 32768; Reason = 'model.reason.gpu' }
        @{ Case = '8 GB card -> 4b'; Vram = 8188; Vendor = 'nvidia'; Ram = 15.8; Expect = 'qwen3.5:4b-q4_K_M'; Gpu = $true; Ctx = 16384; Reason = 'model.reason.gpu' }
        @{ Case = '6 GB card -> 4b'; Vram = 6144; Vendor = 'nvidia'; Ram = 15.8; Expect = 'qwen3.5:4b-q4_K_M'; Gpu = $true; Ctx = 16384; Reason = 'model.reason.gpu' }
        @{ Case = '4 GB card -> 2b on GPU'; Vram = 4096; Vendor = 'nvidia'; Ram = 7.8; Expect = 'qwen3.5:2b-q4_K_M'; Gpu = $true; Ctx = 16384; Reason = 'model.reason.gpu' }
        @{ Case = '2 GB card, 16 GB RAM -> 4b on CPU'; Vram = 2048; Vendor = 'nvidia'; Ram = 15.8; Expect = 'qwen3.5:4b-q4_K_M'; Gpu = $false; Ctx = 16384; Reason = 'model.reason.cpu' }
        @{ Case = 'no GPU, 64 GB RAM -> 4b (no dense model above tier 2 on CPU)'; Vram = 0; Vendor = 'nvidia'; Ram = 63.8; Expect = 'qwen3.5:4b-q4_K_M'; Gpu = $false; Ctx = 16384; Reason = 'model.reason.cpu' }
        @{ Case = 'no GPU, 8 GB RAM -> 2b'; Vram = 0; Vendor = 'nvidia'; Ram = 7.8; Expect = 'qwen3.5:2b-q4_K_M'; Gpu = $false; Ctx = 16384; Reason = 'model.reason.cpu' }
        @{ Case = 'no GPU, 4 GB RAM -> smallest, weak hardware'; Vram = 0; Vendor = 'nvidia'; Ram = 3.8; Expect = 'qwen3.5:2b-q4_K_M'; Gpu = $false; Ctx = 16384; Reason = 'model.reason.weak_hardware' }
        @{ Case = 'AMD RX 7900 XTX 24 GB -> qwen3.8:27b'; Vram = 24560; Vendor = 'amd'; Ram = 31.8; Expect = 'qwen3.8:27b-q4_K_M'; Gpu = $true; Ctx = 32768; Reason = 'model.reason.gpu' }
        @{ Case = 'Intel Arc 16 GB treated as CPU'; Vram = 16384; Vendor = 'intel'; Ram = 31.8; Expect = 'qwen3.5:4b-q4_K_M'; Gpu = $false; Ctx = 16384; Reason = 'model.reason.cpu' }
    ) {
        $hw = New-Hw -VramMiB $Vram -Vendor $Vendor -RamGiB $Ram
        $sel = Select-PnhModel -Hardware $hw -Installed $allTags -Catalog $catalog
        $sel.Model.tag | Should -Be $Expect
        $sel.UseGpu | Should -Be $Gpu
        $sel.Ctx | Should -Be $Ctx
        $sel.Reason | Should -Be $Reason
        foreach ($k in 'Model', 'Reason', 'Ctx', 'UseGpu', 'Fallbacks') { $sel.ContainsKey($k) | Should -BeTrue }
    }

    It 'ignores an integrated AMD GPU even with a large UMA frame buffer' {
        $hw = New-Hw -VramMiB 16384 -Vendor 'amd' -RamGiB 31.8 -Integrated $true
        $sel = Select-PnhModel -Hardware $hw -Installed $allTags -Catalog $catalog
        $sel.UseGpu | Should -BeFalse
        $sel.Model.tag | Should -Be 'qwen3.5:4b-q4_K_M'
    }

    It 'uses only what is installed (standard profile on a 16 GB card)' {
        $hw = New-Hw -VramMiB 16376 -RamGiB 31.8
        $sel = Select-PnhModel -Hardware $hw -Installed @($catalog.profiles.standard.models) -Catalog $catalog
        $sel.Model.tag | Should -Be 'qwen3.5:9b-q4_K_M'
    }

    It 'lists fitting lower-ranked models as fallbacks, best first' {
        $hw = New-Hw -VramMiB 24564 -RamGiB 31.8
        $sel = Select-PnhModel -Hardware $hw -Installed $allTags -Catalog $catalog
        @($sel.Fallbacks | ForEach-Object { $_.tag }) | Should -Be @('qwen3.6:35b-a3b-mtp-q4_K_M', 'qwen3.5:9b-q8_0', 'qwen3.5:9b-q4_K_M', 'qwen3.5:4b-q4_K_M', 'qwen3.5:2b-q4_K_M')
    }

    It 'falls back on CPU only to models that fit the CPU rule' {
        $hw = New-Hw -VramMiB 0 -RamGiB 15.8
        $sel = Select-PnhModel -Hardware $hw -Installed $allTags -Catalog $catalog
        @($sel.Fallbacks | ForEach-Object { $_.tag }) | Should -Be @('qwen3.5:2b-q4_K_M')
    }

    It 'returns no model and reason none_installed when nothing is installed' {
        $sel = Select-PnhModel -Hardware (New-Hw -VramMiB 24564) -Installed @() -Catalog $catalog
        $sel.Model | Should -BeNullOrEmpty
        $sel.Reason | Should -Be 'model.reason.none_installed'
        @($sel.Fallbacks).Count | Should -Be 0
    }

    It 'honours -Prefer for an installed catalogue model' {
        $sel = Select-PnhModel -Hardware (New-Hw -VramMiB 24564 -RamGiB 31.8) -Installed $allTags -Prefer 'qwen3.5:2b-q4_K_M' -Catalog $catalog
        $sel.Model.tag | Should -Be 'qwen3.5:2b-q4_K_M'
        $sel.Reason | Should -Be 'model.reason.preferred'
        $sel.UseGpu | Should -BeTrue
    }

    It 'caps the context at 16384 when a preferred big model must run on the CPU' {
        $sel = Select-PnhModel -Hardware (New-Hw -VramMiB 0 -RamGiB 63.8) -Installed $allTags -Prefer 'qwen3.5:9b-q4_K_M' -Catalog $catalog
        $sel.UseGpu | Should -BeFalse
        $sel.Ctx | Should -Be 16384
    }

    It 'builds an ad-hoc entry for an installed tag outside the catalogue' {
        $sel = Select-PnhModel -Hardware (New-Hw -VramMiB 0 -RamGiB 7.8) -Installed @('qwen3:0.6b') -Prefer 'qwen3:0.6b' -Catalog $catalog
        $sel.Model.tag | Should -Be 'qwen3:0.6b'
        $sel.Ctx | Should -Be 8192
        $sel.Model.think | Should -BeFalse
    }

    It 'ignores -Prefer when the tag is not installed' {
        $sel = Select-PnhModel -Hardware (New-Hw -VramMiB 8188) -Installed $allTags -Prefer 'nope:1b' -Catalog $catalog
        $sel.Model.tag | Should -Be 'qwen3.5:4b-q4_K_M'
    }

    It 'accepts hardware as PSCustomObject (deserialised JSON) and without Gpus' {
        $json = ConvertTo-Json -InputObject (New-Hw -VramMiB 12288 -RamGiB 31.8) -Depth 5
        $sel = Select-PnhModel -Hardware (ConvertFrom-Json -InputObject $json) -Installed $allTags -Catalog $catalog
        $sel.Model.tag | Should -Be 'qwen3.5:9b-q4_K_M'
        $sel2 = Select-PnhModel -Hardware @{ BestDedicatedVramBytes = [uint64](12288 * 1MB); RamBytes = [uint64](16 * 1GB) } -Installed $allTags -Catalog $catalog
        $sel2.Model.tag | Should -Be 'qwen3.5:9b-q4_K_M'
    }

    It 'gives every candidate its own placement and context: a 24 GB card steps down from 32k to 16k' {
        $sel = Select-PnhModel -Hardware (New-Hw -VramMiB 24564 -RamGiB 31.8) -Installed $allTags -Catalog $catalog
        $c = @($sel.Candidates)
        $c.Count | Should -Be 6
        @($c | ForEach-Object { $_.Model.tag }) | Should -Be @('qwen3.8:27b-q4_K_M', 'qwen3.6:35b-a3b-mtp-q4_K_M', 'qwen3.5:9b-q8_0', 'qwen3.5:9b-q4_K_M', 'qwen3.5:4b-q4_K_M', 'qwen3.5:2b-q4_K_M')
        @($c | ForEach-Object { $_.Ctx }) | Should -Be @(32768, 32768, 32768, 32768, 16384, 16384)
        @($c | ForEach-Object { $_.UseGpu }) | Should -Be @($true, $true, $true, $true, $true, $true)
        foreach ($x in $c) {
            $x.Model.ctx | Should -Be $x.Ctx -Because 'the entry handed to the agent carries the context it was tested with'
            $x.Tag | Should -Be $x.Model.tag
        }
        $c[0].Ctx | Should -Be $sel.Ctx
        $c[0].UseGpu | Should -Be $sel.UseGpu
    }

    It 'caps the context of CPU candidates and does not change the catalogue' {
        $sel = Select-PnhModel -Hardware (New-Hw -VramMiB 0 -RamGiB 63.8) -Installed $allTags -Prefer 'qwen3.5:9b-q4_K_M' -Catalog $catalog
        $c = @($sel.Candidates)
        @($c | ForEach-Object { $_.Model.tag }) | Should -Be @('qwen3.5:9b-q4_K_M', 'qwen3.5:4b-q4_K_M', 'qwen3.5:2b-q4_K_M')
        @($c | ForEach-Object { $_.Ctx }) | Should -Be @(16384, 16384, 16384)
        @($c | ForEach-Object { $_.UseGpu }) | Should -Be @($false, $false, $false)
        $c[0].Model.ctx | Should -Be 16384
        @($catalog.models | Where-Object { $_.tag -eq 'qwen3.5:9b-q4_K_M' })[0].ctx | Should -Be 32768
        $c[0].Model.think | Should -BeFalse
        $c[0].Model.tier | Should -Be 3
    }

    It 'returns no model (too_weak) when the RAM is below what every installed model needs' {
        $sel = Select-PnhModel -Hardware (New-Hw -VramMiB 0 -RamGiB 2.8) -Installed $allTags -Catalog $catalog
        $sel.Model | Should -BeNullOrEmpty
        $sel.Path | Should -Be 'too_weak'
        $sel.Reason | Should -Be 'model.reason.weak_hardware'
        @($sel.Candidates).Count | Should -Be 0
        @($sel.Fallbacks).Count | Should -Be 0
    }

    It 'still tries the smallest model when the RAM is unknown' {
        $sel = Select-PnhModel -Hardware @{ Gpus = @(); BestDedicatedVramBytes = 0; RamBytes = 0 } -Installed $allTags -Catalog $catalog
        $sel.Model.tag | Should -Be 'qwen3.5:2b-q4_K_M'
        $sel.Path | Should -Be 'weak'
    }

    It 'reads the installed models from disk when -Installed is not given' {
        Mock Get-PnhInstalledModels { 'qwen3.5:2b-q4_K_M' }
        $sel = Select-PnhModel -Hardware (New-Hw -VramMiB 24564) -Catalog $catalog
        $sel.Model.tag | Should -Be 'qwen3.5:2b-q4_K_M'
    }
}
