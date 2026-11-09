<#
.SYNOPSIS
    Model catalogue and model selection for Plug'n'Heal.

.DESCRIPTION
    Dot-source this file; it loads Common.ps1 when needed. Nothing runs at dot-source time.

    Selection rule (ARCHITECTURE.md 5.3, docs/research/modelle.md 3), "GB" means GiB (PowerShell 1GB):
      * usable VRAM = largest dedicated NVIDIA/AMD VRAM - 1.5 GiB (desktop and reserve)
      * GPU path: the best-ranked installed model with minVramGB <= usable VRAM
        (and, for partial-offload models, gpuMinRamGB <= RAM)
      * CPU path (no usable GPU or nothing fits): the best-ranked installed model with tier <= 2 and
        minRamGB <= RAM - 4 GiB
      * nothing fits: the smallest installed model whose minRamGB <= RAM, reason 'model.reason.weak_hardware';
        when RAM is known and not even that exists: no model (Path 'too_weak'), the window says the computer
        does not have enough memory (error.computer_too_weak)
      * context length: Get-PnhModelContext (catalogue ctx, capped at 16384 on the CPU), for the chosen model
        and for every fallback (Candidates), so a step-down never keeps the context of the first model
      * rank ("largest") = minVramGB (most demanding first), then tier, then bytes. This prefers
        qwen3.8:27b over the MoE fast mode on 24 GB cards, the MoE over 9b-q8 on 16 GB cards with 30 GiB+ RAM,
        and 9b-q8 over 9b-q4 whenever it fits. The catalogue 'default' flag only marks the standard profile.
#>

if (-not (Get-Command -Name Write-PnhLog -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Common.ps1')
}

function Get-PnhModelCatalog {
    <#
    .SYNOPSIS
        Reads catalog\models.json and returns the parsed object (PSCustomObject with schema, profiles, models).
    .PARAMETER Path
        Catalogue file; defaults to <App>\catalog\models.json.
    .OUTPUTS
        PSCustomObject; throws when the file is missing or broken (the app cannot work without it).
    #>
    [CmdletBinding()]
    param([string]$Path)
    if (-not $Path) { $Path = Join-PnhPath (Get-PnhPaths).App 'catalog' 'models.json' }
    return (Read-PnhJsonFile -Path $Path -ErrorOnFailure)
}

function Test-PnhManifestBlobs {
    <#
    .SYNOPSIS
        Checks that every blob of an Ollama manifest exists under <Models>\blobs with the right size.
    .DESCRIPTION
        Size check only (fast); the builder verifies sha256. A half-copied drive therefore shows the model as
        missing instead of failing later inside Ollama.
        Layers of media type application/vnd.docker.distribution.manifest.v2+json are skipped: Ollama 0.40.15
        adds a copy of the registry manifest as an extra layer after a pull (measured); it is bookkeeping, not
        part of the model, and a drive filled from the registry directly does not have it.
    .OUTPUTS
        [bool]
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Checks several blobs')]
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$ManifestPath,
        [Parameter(Mandatory = $true)][string]$ModelsPath
    )
    $m = Read-PnhJsonFile -Path $ManifestPath
    if ($null -eq $m) { return $false }
    $items = @()
    $cfg = Get-PnhValue $m 'config'
    if ($null -ne $cfg) { $items += $cfg }
    $items += @(Get-PnhValue $m 'layers' @())
    if ($items.Count -eq 0) { return $false }
    foreach ($it in $items) {
        if ($null -eq $it) { continue }
        if ([string](Get-PnhValue $it 'mediaType' '') -like 'application/vnd.docker.distribution.manifest*') { continue }
        $digest = [string](Get-PnhValue $it 'digest' '')
        if (-not $digest) { return $false }
        $blob = Join-PnhPath $ModelsPath 'blobs' ($digest.Replace(':', '-'))
        if (-not [System.IO.File]::Exists($blob)) { return $false }
        $size = Get-PnhValue $it 'size'
        if ($null -ne $size -and (New-Object System.IO.FileInfo($blob)).Length -ne [int64]$size) { return $false }
    }
    return $true
}

function Get-PnhInstalledModels {
    <#
    .SYNOPSIS
        Lists the model tags present under <Models>\manifests (no running Ollama needed).
    .DESCRIPTION
        Authoritative source: manifests\<registry>\<namespace>\<name>\<tag> (exactly four levels). Ollama 0.40.15
        also writes manifests-v2\ and metadata\*.json at start; both are ignored. The extra manifest-copy layer
        that a pull adds is not checked (see Test-PnhManifestBlobs). registry.ollama.ai/library models are returned as
        "name:tag" (e.g. qwen3.5:4b-q4_K_M), other namespaces as "namespace/name:tag", other registries as
        "registry/namespace/name:tag". By default a tag is only listed when all its blobs exist with the
        right size (-NoVerify skips that). Returns one string per tag, sorted; wrap the call in @().
    .PARAMETER ModelsPath
        OLLAMA_MODELS folder; defaults to (Get-PnhPaths).Models.
    .PARAMETER NoVerify
        Do not check the blobs.
    .EXAMPLE
        $installed = @(Get-PnhInstalledModels)
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Name fixed by ARCHITECTURE.md')]
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$ModelsPath, [switch]$NoVerify)
    if (-not $ModelsPath) { $ModelsPath = (Get-PnhPaths).Models }
    $manifestRoot = Join-PnhPath $ModelsPath 'manifests'
    if (-not [System.IO.Directory]::Exists($manifestRoot)) { return }
    $found = New-Object System.Collections.ArrayList
    foreach ($file in [System.IO.Directory]::GetFiles($manifestRoot, '*', [System.IO.SearchOption]::AllDirectories)) {
        $rel = $file.Substring($manifestRoot.Length).TrimStart([char[]]@('\', '/'))
        $parts = @($rel -split '[\\/]')
        if ($parts.Count -ne 4) { continue }
        $registry = $parts[0]
        $namespace = $parts[1]
        $tagName = $parts[2] + ':' + $parts[3]
        if ($registry -ne 'registry.ollama.ai') { $tagName = $registry + '/' + $namespace + '/' + $tagName }
        elseif ($namespace -ne 'library') { $tagName = $namespace + '/' + $tagName }
        if (-not $NoVerify -and -not (Test-PnhManifestBlobs -ManifestPath $file -ModelsPath $ModelsPath)) {
            Write-PnhLog -Level Warn -Message ('Model incomplete, ignored: ' + $tagName)
            continue
        }
        $null = $found.Add($tagName)
    }
    $found | Sort-Object -Unique
}

function Get-PnhModelRank {
    <#
    .SYNOPSIS
        Sort key of a catalogue entry (higher = "larger"): minVramGB, then tier, then bytes.
    #>
    [CmdletBinding()]
    [OutputType([double])]
    param([Parameter(Mandatory = $true)][object]$Entry)
    $vram = [double](Get-PnhValue $Entry 'minVramGB' 0)
    $tier = [double](Get-PnhValue $Entry 'tier' 0)
    $bytes = [double](Get-PnhValue $Entry 'bytes' 0) / 1e10
    return ($vram * 1000) + ($tier * 10) + [Math]::Min($bytes, 9.99)
}

function New-PnhAdHocModelEntry {
    <#
    .SYNOPSIS
        Catalogue-like entry for an installed tag that is not in the catalogue (developer models, CI).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates an object only')]
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Tag)
    return [pscustomobject]@{
        id = $Tag; tag = $Tag; bytes = 0; license = 'unknown'; tier = 0; minVramGB = 0; minRamGB = 0
        ctx = 8192; think = $false; freeShell = $false; default = $false; notes = 'Not in the catalogue (preferred by caller).'
    }
}

function Get-PnhModelContext {
    <#
    .SYNOPSIS
        num_ctx for a model: its catalogue ctx, capped at 16384 when it runs on the CPU.
    .DESCRIPTION
        The one place that decides the context length. Select-PnhModel uses it for the chosen model and for
        every fallback (Candidates); Ui.ps1 and Run-Headless.ps1 pass the candidate's value per request
        (Test-PnhModelFit -NumCtx, Invoke-PnhAgent through ModelEntry.ctx), so stepping down never needs an
        Ollama restart. A missing or invalid ctx counts as 16384.
    .PARAMETER ModelEntry
        Catalogue entry (or ad-hoc entry).
    .PARAMETER UseGpu
        The model runs on the GPU path. Without it the context is capped at 16384 (RAM and minutes per round
        on the CPU).
    .OUTPUTS
        [int]
    .EXAMPLE
        Get-PnhModelContext -ModelEntry $entry -UseGpu:$sel.UseGpu
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory = $true)][object]$ModelEntry,
        [switch]$UseGpu
    )
    $ctx = 0
    $raw = Get-PnhValue $ModelEntry 'ctx'
    if ($null -ne $raw) {
        try { $ctx = [int]$raw } catch { $ctx = 0 }
    }
    if ($ctx -le 0) { $ctx = 16384 }
    if (-not $UseGpu -and $ctx -gt 16384) { $ctx = 16384 }
    return $ctx
}

function Select-PnhModel {
    <#
    .SYNOPSIS
        Chooses the model for this PC from the installed catalogue models.
    .DESCRIPTION
        Returns @{Model=<catalogue entry or $null>; Reason=<i18n key>; Ctx=<int>; UseGpu=<bool>;
        Fallbacks=@(<entries>); Candidates=@(@{Model; Tag; UseGpu; Ctx}); UsableVramGB; RamGB;
        Path='gpu'|'cpu'|'preferred'|'weak'|'too_weak'|'none'}.

        Reasons (i18n keys): model.reason.gpu, model.reason.cpu, model.reason.preferred,
        model.reason.weak_hardware, model.reason.none_installed.
        Model is $null for Path 'none' (nothing installed) and 'too_weak' (RAM is known and smaller than the
        minRamGB of every installed model; the window shows error.computer_too_weak).

        Fallbacks are the lower-ranked installed catalogue models that also fit this PC, best first (if none
        fit, the smallest one), for stepping down after Test-PnhModelFit.
        Candidates is the step-down list ready to use: the chosen model first, then every fallback, each with
        its own UseGpu (GPU rule of this PC) and Ctx (Get-PnhModelContext). Candidates[i].Model is a copy of
        the catalogue entry whose ctx is already that value: pass it to Test-PnhModelFit (-ModelEntry,
        -NumCtx, -UseGpu) and to Invoke-PnhAgent as is.
        Ctx is the catalogue ctx, capped at 16384 when the model will run on the CPU.
    .PARAMETER Hardware
        Result of Get-PnhHardware (hashtable or the same shape as PSCustomObject).
    .PARAMETER Installed
        Installed tags; defaults to Get-PnhInstalledModels.
    .PARAMETER Prefer
        Tag to use when installed, even if the rule would pick another one (experts, Run-Headless -Model).
        An installed tag that is not in the catalogue gets an ad-hoc entry (tier 0, ctx 8192, think off).
    .PARAMETER Catalog
        Parsed catalogue; defaults to Get-PnhModelCatalog.
    .EXAMPLE
        $sel = Select-PnhModel -Hardware (Get-PnhHardware)
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][object]$Hardware,
        [AllowNull()][AllowEmptyCollection()][string[]]$Installed,
        [string]$Prefer,
        [object]$Catalog
    )
    if ($null -eq $Catalog) { $Catalog = Get-PnhModelCatalog }
    if (-not $PSBoundParameters.ContainsKey('Installed')) { $Installed = @(Get-PnhInstalledModels) }
    $installedSet = @{}
    foreach ($t in @($Installed)) { if ($t) { $installedSet[$t.ToLowerInvariant()] = $true } }

    $all = @(Get-PnhValue $Catalog 'models' @())
    $candidates = @($all | Where-Object { $null -ne $_ -and $installedSet.ContainsKey(([string](Get-PnhValue $_ 'tag' '')).ToLowerInvariant()) })
    $ranked = @($candidates | Sort-Object -Property @{ Expression = { Get-PnhModelRank -Entry $_ }; Descending = $true })

    # Usable GPU: dedicated NVIDIA/AMD only (Intel and integrated GPUs are treated as CPU until measured).
    $vramBytes = [double]0
    $gpus = @(Get-PnhValue $Hardware 'Gpus' @())
    foreach ($g in $gpus) {
        if ($null -eq $g) { continue }
        $vendor = [string](Get-PnhValue $g 'Vendor' '')
        $v = Get-PnhValue $g 'VramBytes'
        if (($vendor -eq 'nvidia' -or $vendor -eq 'amd') -and -not [bool](Get-PnhValue $g 'Integrated' $false) -and $null -ne $v -and [double]$v -gt $vramBytes) {
            $vramBytes = [double]$v
        }
    }
    if ($gpus.Count -eq 0) {
        $best = Get-PnhValue $Hardware 'BestDedicatedVramBytes'
        if ($null -ne $best) { $vramBytes = [double]$best }
    }
    $usableVram = 0.0
    if ($vramBytes -gt 0) { $usableVram = [Math]::Round($vramBytes / 1GB - 1.5, 2) }
    $ram = Get-PnhValue $Hardware 'RamBytes'
    $ramGB = 0.0
    if ($null -ne $ram) { $ramGB = [Math]::Round([double]$ram / 1GB, 2) }

    $fitsGpu = {
        param($e)
        if ($usableVram -le 0) { return $false }
        if ([double](Get-PnhValue $e 'minVramGB' 999) -gt $usableVram) { return $false }
        $needRam = Get-PnhValue $e 'gpuMinRamGB'
        if ($null -ne $needRam -and [double]$needRam -gt $ramGB) { return $false }
        return $true
    }
    $fitsCpu = {
        param($e)
        return ([int](Get-PnhValue $e 'tier' 99) -le 2 -and [double](Get-PnhValue $e 'minRamGB' 999) -le ($ramGB - 4))
    }

    $model = $null
    $reason = 'model.reason.none_installed'
    $path = 'none'
    $useGpu = $false

    if ($Prefer) {
        $p = @($candidates | Where-Object { ([string](Get-PnhValue $_ 'tag' '')) -eq $Prefer })
        if ($p.Count -gt 0) {
            $model = $p[0]
        } elseif ($installedSet.ContainsKey($Prefer.ToLowerInvariant())) {
            $model = New-PnhAdHocModelEntry -Tag $Prefer
        }
        if ($null -ne $model) {
            $reason = 'model.reason.preferred'
            $path = 'preferred'
            $useGpu = [bool](& $fitsGpu $model)
        } else {
            Write-PnhLog -Level Warn -Message ('Preferred model not installed: ' + $Prefer)
        }
    }
    if ($null -eq $model) {
        foreach ($e in $ranked) { if (& $fitsGpu $e) { $model = $e; $reason = 'model.reason.gpu'; $path = 'gpu'; $useGpu = $true; break } }
    }
    if ($null -eq $model) {
        foreach ($e in $ranked) { if (& $fitsCpu $e) { $model = $e; $reason = 'model.reason.cpu'; $path = 'cpu'; break } }
    }
    if ($null -eq $model -and $ranked.Count -gt 0) {
        # Nothing fits the rules: the smallest model that can be loaded at all (minRamGB <= RAM, without the
        # 4 GiB reserve of the CPU rule). Unknown RAM (detection failed) cannot rule anything out.
        $bySize = @($ranked | Sort-Object -Property @{ Expression = { [double](Get-PnhValue $_ 'bytes' 0) } })
        if ($ramGB -gt 0) { $bySize = @($bySize | Where-Object { [double](Get-PnhValue $_ 'minRamGB' 0) -le $ramGB }) }
        $reason = 'model.reason.weak_hardware'
        if ($bySize.Count -gt 0) {
            $model = $bySize[0]
            $path = 'weak'
        } else {
            $path = 'too_weak'
            Write-PnhLog -Level Warn -Message ('No installed model fits into ' + $ramGB + ' GiB RAM')
        }
    }

    $ctx = 0
    $fallbacks = @()
    $candidateList = New-Object System.Collections.ArrayList
    if ($null -ne $model) {
        $ctx = Get-PnhModelContext -ModelEntry $model -UseGpu:$useGpu
        $chosenRank = Get-PnhModelRank -Entry $model
        $chosenTag = [string](Get-PnhValue $model 'tag' '')
        $smaller = @($ranked | Where-Object { [string](Get-PnhValue $_ 'tag' '') -ne $chosenTag -and (Get-PnhModelRank -Entry $_) -lt $chosenRank })
        $fallbacks = @($smaller | Where-Object { (& $fitsGpu $_) -or (& $fitsCpu $_) })
        if ($fallbacks.Count -eq 0 -and $smaller.Count -gt 0) {
            $fallbacks = @($smaller | Sort-Object -Property @{ Expression = { [double](Get-PnhValue $_ 'bytes' 0) } } | Select-Object -First 1)
        }
        $newCandidate = {
            param($Entry, [bool]$Gpu)
            $c = Get-PnhModelContext -ModelEntry $Entry -UseGpu:$Gpu
            $copy = [ordered]@{}
            if ($Entry -is [System.Collections.IDictionary]) {
                foreach ($k in @($Entry.Keys)) { $copy[[string]$k] = $Entry[$k] }
            } else {
                foreach ($prop in $Entry.PSObject.Properties) { $copy[$prop.Name] = $prop.Value }
            }
            $copy['ctx'] = $c
            return @{ Model = [pscustomobject]$copy; Tag = [string](Get-PnhValue $Entry 'tag' ''); UseGpu = $Gpu; Ctx = $c }
        }
        $null = $candidateList.Add((& $newCandidate $model $useGpu))
        foreach ($fb in $fallbacks) { $null = $candidateList.Add((& $newCandidate $fb ([bool](& $fitsGpu $fb)))) }
    }

    $result = @{
        Model        = $model
        Reason       = $reason
        Ctx          = $ctx
        UseGpu       = $useGpu
        Fallbacks    = $fallbacks
        Candidates   = @($candidateList.ToArray())
        UsableVramGB = $usableVram
        RamGB        = $ramGB
        Path         = $path
    }
    $logTag = $null
    if ($null -ne $model) { $logTag = Get-PnhValue $model 'tag' }
    Write-PnhLog -Message 'Model selected' -Data @{
        Tag = $logTag; Reason = $reason; Path = $path; Ctx = $ctx; UseGpu = $useGpu; UsableVramGB = $usableVram; RamGB = $ramGB
        Installed = @($Installed)
        Fallbacks = @($candidateList | Select-Object -Skip 1 | ForEach-Object { '{0} (gpu={1}, ctx={2})' -f $_.Tag, $_.UseGpu, $_.Ctx })
    }
    return $result
}
