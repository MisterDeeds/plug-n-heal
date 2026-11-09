<#
.SYNOPSIS
    Plug'n'Heal action catalogue engine: load, offer, validate, confirm, back up, run, verify,
    roll back, restore point, deny-list.

.DESCRIPTION
    Contract: docs/ARCHITECTURE.md section 5.6. Catalogue format and safety rules: docs/TOOLBOX.md.

    Actions run in Windows PowerShell 5.1 (64-bit). This file only defines functions; nothing
    Windows-specific runs at load time, so it dot-sources in PowerShell 7 and on Linux (tests).

    Catalogue scripts run in the SAME runspace via [scriptblock]::Create and receive:
      $P            validated parameters (hashtable)
      $Backup       the action's own backup folder (<run>\backups\<stamp>-<nn>-<id>)
      $PnhRoot      drive root (X:\PlugNHeal)
      $PnhStart     [datetime] start of the action
      $PnhBuildDate [datetime] drive build date (clock plausibility)
      $PnhRunFolder the run folder
      $PnhLanguage  'de' or 'en'
    Timeouts: every external program started with Invoke-PnhNative is killed at the action's
    deadline; in-process cmdlets cannot be interrupted and are only reported when late.

    Encoding: UTF-8 with BOM.
#>

. (Join-Path (Join-Path (Split-Path -Path $PSScriptRoot -Parent) 'toolbox') 'helpers.ps1')

# ------------------------------------------------------------------ internal helpers

function Write-PnhToolboxLog {
    <#
    .SYNOPSIS
        Logs through Write-PnhLog (Common.ps1) when it is loaded, otherwise to the verbose stream.
    #>
    [CmdletBinding()]
    param([string]$Message, [ValidateSet('Info', 'Warn', 'Error')][string]$Level = 'Info', $Data)
    if (Get-Command -Name Write-PnhLog -CommandType Function -ErrorAction SilentlyContinue) {
        try {
            if ($null -ne $Data) { Write-PnhLog -Message $Message -Level $Level -Data $Data } else { Write-PnhLog -Message $Message -Level $Level }
            return
        } catch {
            Write-Verbose "Write-PnhLog failed: $($_.Exception.Message)"
        }
    }
    Write-Verbose "[$Level] $Message"
}

function Get-PnhToolboxLanguage {
    <#
    .SYNOPSIS
        'de' or 'en': explicit value, else Get-PnhLanguage (Common.ps1), else 'en'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Language)
    if ($Language -in @('de', 'en')) { return $Language }
    if (Get-Command -Name Get-PnhLanguage -CommandType Function -ErrorAction SilentlyContinue) {
        try {
            $l = Get-PnhLanguage
            if ($l -in @('de', 'en')) { return $l }
        } catch {
            Write-Verbose "Get-PnhLanguage failed: $($_.Exception.Message)"
        }
    }
    return 'en'
}

function Get-PnhMember {
    <#
    .SYNOPSIS
        Reads a member from a hashtable/dictionary or a PSCustomObject; $null if absent.
    #>
    [CmdletBinding()]
    param($Object, [Parameter(Mandatory = $true)][string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $null
    }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function ConvertTo-PnhPlainHashtable {
    <#
    .SYNOPSIS
        Converts a PSCustomObject (for example parsed JSON) or dictionary into a flat hashtable.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param($InputObject)
    $h = @{}
    if ($null -eq $InputObject) { return $h }
    if ($InputObject -is [System.Collections.IDictionary]) {
        foreach ($k in $InputObject.Keys) { $h[[string]$k] = $InputObject[$k] }
        return $h
    }
    foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = $p.Value }
    return $h
}

function Get-PnhLocalizedText {
    <#
    .SYNOPSIS
        Picks the language from a {de, en} object; falls back to en, then to the value itself.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param($Value, [string]$Language = 'en')
    if ($null -eq $Value) { return '' }
    if ($Value -is [string]) { return $Value }
    $t = Get-PnhMember -Object $Value -Name $Language
    if (-not $t) { $t = Get-PnhMember -Object $Value -Name 'en' }
    return [string]$t
}

function ConvertTo-PnhShortText {
    <#
    .SYNOPSIS
        Turns script output into a short single string (compact JSON for objects), max -Max chars.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param($InputObject, [int]$Max = 1500)
    if ($null -eq $InputObject) { return '' }
    $s = ''
    if ($InputObject -is [string]) {
        $s = $InputObject
    } else {
        try { $s = ConvertTo-Json -InputObject $InputObject -Depth 4 -Compress } catch { $s = "$InputObject" }
    }
    if ($s.Length -gt $Max) { $s = $s.Substring(0, $Max - 3) + '...' }
    return $s
}

$script:PnhCatalogCache = @{}

function Read-PnhCatalogFile {
    <#
    .SYNOPSIS
        Reads and caches one of the toolbox JSON files (actions.json, categories.json, findings.json).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name, [string]$Path, [switch]$Refresh)
    if (-not $Path) { $Path = Join-Path (Get-PnhToolboxDir) $Name }
    if (-not $script:PnhCatalogCache) { $script:PnhCatalogCache = @{} }
    if (-not $Refresh -and $script:PnhCatalogCache.ContainsKey($Path)) { return $script:PnhCatalogCache[$Path] }
    $doc = Read-PnhStateJson -Path $Path
    $script:PnhCatalogCache[$Path] = $doc
    return $doc
}

# ------------------------------------------------------------------ catalogue access

function Get-PnhActions {
    <#
    .SYNOPSIS
        Returns catalogue entries from toolbox\actions.json.
    .PARAMETER Category
        Only actions in the category's scope (the "actions" patterns in categories.json).
        'all' or an unknown category returns everything in scope of 'all'.
    .PARAMETER Path
        Alternative catalogue file (tests).
    .OUTPUTS
        PSCustomObjects with the schema described in docs/TOOLBOX.md.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Name fixed by the architecture contract.')]
    [CmdletBinding()]
    param([string]$Category, [string]$Path)
    $doc = Read-PnhCatalogFile -Name 'actions.json' -Path $Path
    $all = @($doc.actions)
    if (-not $Category) { return $all }
    $cat = Get-PnhCategoryCatalog | Where-Object { $_.id -eq $Category } | Select-Object -First 1
    if (-not $cat) { return @() }
    $patterns = @($cat.actions)
    return @($all | Where-Object { Test-PnhIdPattern -Id $_.id -Pattern $patterns })
}

function Get-PnhAction {
    <#
    .SYNOPSIS
        Returns one catalogue entry by id, or $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Id)
    return (@(Get-PnhActions) | Where-Object { $_.id -eq $Id } | Select-Object -First 1)
}

function Get-PnhCategoryCatalog {
    <#
    .SYNOPSIS
        Returns the categories from toolbox\categories.json.
    #>
    [CmdletBinding()]
    param([string]$Path)
    return @((Read-PnhCatalogFile -Name 'categories.json' -Path $Path).categories)
}

function Get-PnhFindingCatalog {
    <#
    .SYNOPSIS
        Returns the findings from toolbox\findings.json as hashtable code -> entry.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$Path)
    $h = @{}
    foreach ($f in @((Read-PnhCatalogFile -Name 'findings.json' -Path $Path).findings)) { $h[[string]$f.code] = $f }
    return $h
}

function Test-PnhIdPattern {
    <#
    .SYNOPSIS
        $true if the action id matches one of the patterns (wildcards, e.g. 'net.*').
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Id, [string[]]$Pattern)
    foreach ($p in @($Pattern)) { if ($p -and $Id -like $p) { return $true } }
    return $false
}

function Test-PnhConfirmRequired {
    <#
    .SYNOPSIS
        Confirmation rule: confirm = true OR risk medium/high OR reboot OR deletes.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)]$Action)
    return [bool]((Get-PnhMember $Action 'confirm') -eq $true -or
        (Get-PnhMember $Action 'risk') -in @('medium', 'high') -or
        (Get-PnhMember $Action 'reboot') -eq $true -or
        (Get-PnhMember $Action 'deletes') -eq $true)
}

function Test-PnhActionBlocked {
    <#
    .SYNOPSIS
        Returns the code of the first set finding whose "blocks" list covers this changing action,
        or $null. Block tokens: wildcard ids ('net.*'), '@reboot' (actions with a restart), '*'.
        Read-only actions are never blocked.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Action, [string[]]$Flags = @())
    if ((Get-PnhMember $Action 'changes') -ne $true) { return $null }
    $findings = Get-PnhFindingCatalog
    foreach ($flag in @($Flags)) {
        if (-not $flag -or -not $findings.ContainsKey($flag)) { continue }
        foreach ($b in @($findings[$flag].blocks)) {
            if (-not $b) { continue }
            if ($b -eq '@reboot') {
                if ((Get-PnhMember $Action 'reboot') -eq $true) { return $flag }
                continue
            }
            if ($Action.id -like $b) { return $flag }
        }
    }
    return $null
}

function Get-PnhCandidateActions {
    <#
    .SYNOPSIS
        What the agent may offer: candidates of the set flags (in finding order) plus the read-only
        diagnostics of the category. Experimental actions and actions blocked by a stop finding
        are left out.
    .OUTPUTS
        [pscustomobject]@{ Actions; Candidates; Diagnostics; Blocked (@{Id;Finding}); Stops (@{Code;Stop;Blocks}) }
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns a set.')]
    [CmdletBinding()]
    param([string[]]$Flags = @(), [string]$Category = 'all', [switch]$IncludeExperimental)
    $findings = Get-PnhFindingCatalog
    $all = @(Get-PnhActions)
    $scope = @(Get-PnhActions -Category $Category)
    if (-not $scope.Count) { $scope = $all }
    $scopeIds = @{}
    foreach ($a in $scope) { $scopeIds[$a.id] = $true }
    $byId = @{}
    foreach ($a in $all) { $byId[$a.id] = $a }
    $cands = New-Object System.Collections.Generic.List[object]
    $diags = New-Object System.Collections.Generic.List[object]
    $blocked = New-Object System.Collections.Generic.List[object]
    $stops = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($flag in @($Flags)) {
        if (-not $flag -or -not $findings.ContainsKey($flag)) { continue }
        $f = $findings[$flag]
        if ($f.stop -or @($f.blocks).Count) { $stops.Add([pscustomobject]@{ Code = $flag; Stop = $f.stop; Blocks = @($f.blocks) }) }
        foreach ($id in @($f.candidates)) {
            if ($seen.ContainsKey($id) -or -not $byId.ContainsKey($id)) { continue }
            $a = $byId[$id]
            if (-not $scopeIds.ContainsKey($id)) { continue }
            if ($a.experimental -and -not $IncludeExperimental) { continue }
            $by = Test-PnhActionBlocked -Action $a -Flags $Flags
            if ($by) { $blocked.Add([pscustomobject]@{ Id = $id; Finding = $by }); $seen[$id] = $true; continue }
            $cands.Add($a)
            $seen[$id] = $true
        }
    }
    foreach ($a in $scope) {
        if ($seen.ContainsKey($a.id) -or $a.changes -or $a.kind -ne 'diagnose') { continue }
        if ($a.experimental -and -not $IncludeExperimental) { continue }
        if ($Category -eq 'all' -and -not $a.core) { continue }
        $diags.Add($a)
        $seen[$a.id] = $true
    }
    return [pscustomobject]@{
        Actions     = @($cands.ToArray()) + @($diags.ToArray())
        Candidates  = $cands.ToArray()
        Diagnostics = $diags.ToArray()
        Blocked     = $blocked.ToArray()
        Stops       = $stops.ToArray()
    }
}

function Resolve-PnhToolName {
    <#
    .SYNOPSIS
        Maps a tool name returned by the model back to an action id. Accepts the id itself
        ('net.flush_dns') and common manglings ('net_flush_dns', 'functions.net.flush_dns').
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Name)
    $n = $Name.Trim()
    $n = $n -replace '^(functions?|tools?)[.:/]', ''
    $all = @(Get-PnhActions)
    $hit = $all | Where-Object { $_.id -eq $n } | Select-Object -First 1
    if ($hit) { return $hit.id }
    $key = ($n.ToLowerInvariant() -replace '[^a-z0-9]+', '_').Trim('_')
    $hit = $all | Where-Object { (($_.id.ToLowerInvariant() -replace '[^a-z0-9]+', '_').Trim('_')) -eq $key } | Select-Object -First 1
    if ($hit) { return $hit.id }
    return $null
}

# ------------------------------------------------------------------ parameters

function Get-PnhParamSpec {
    <#
    .SYNOPSIS
        Lists the parameters of an action: @{Name; Schema; Required}.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Action)
    $params = Get-PnhMember $Action 'params'
    $props = Get-PnhMember $params 'properties'
    $req = @(Get-PnhMember $params 'required')
    if ($null -eq $props) { return }
    $names = $(if ($props -is [System.Collections.IDictionary]) { @($props.Keys) } else { @($props.PSObject.Properties | ForEach-Object { $_.Name }) })
    foreach ($n in $names) {
        [pscustomobject]@{ Name = [string]$n; Schema = (Get-PnhMember $props $n); Required = ($req -contains $n) }
    }
}

function Test-PnhParameters {
    <#
    .SYNOPSIS
        Validates parameters against the action's JSON schema subset: type (string, integer, number,
        boolean), enum, pattern, required, maxLength, minimum, maximum, no unknown properties,
        no control characters in strings.
    .OUTPUTS
        [pscustomobject]@{ Valid; Errors (string[]); Values (normalized hashtable) }
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Validates a parameter set.')]
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Action, $Parameters)
    $errors = New-Object System.Collections.Generic.List[string]
    $values = @{}
    $given = ConvertTo-PnhPlainHashtable -InputObject $Parameters
    $spec = @(Get-PnhParamSpec -Action $Action)
    $known = @{}
    foreach ($s in $spec) { $known[$s.Name] = $s }
    foreach ($k in $given.Keys) {
        if (-not $known.ContainsKey($k)) { $errors.Add("unknown parameter '$k'") }
    }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    foreach ($s in $spec) {
        $name = $s.Name
        $sch = $s.Schema
        $has = $given.ContainsKey($name) -and $null -ne $given[$name] -and "$($given[$name])" -ne ''
        if (-not $has) {
            if ($s.Required) { $errors.Add("missing required parameter '$name'") }
            continue
        }
        $v = $given[$name]
        $type = [string](Get-PnhMember $sch 'type')
        $ok = $true
        switch ($type) {
            'string' {
                if ($v -is [string]) { }
                elseif ($v -is [bool] -or -not ($v -is [ValueType])) { $ok = $false }
                else { $v = [string]::Format($inv, '{0}', $v) }
            }
            'integer' {
                $n = $null
                if ($v -is [bool]) { $ok = $false }
                elseif ($v -is [int] -or $v -is [long] -or $v -is [int16] -or $v -is [byte] -or $v -is [uint32] -or $v -is [uint16]) { $n = [long]$v }
                elseif (($v -is [double] -or $v -is [decimal] -or $v -is [single]) -and [math]::Floor([double]$v) -eq [double]$v -and [math]::Abs([double]$v) -lt 1e15) { $n = [long]$v }
                elseif ($v -is [string] -and $v -match '^\s*-?\d{1,15}\s*$') { $n = [long]::Parse($v.Trim(), $inv) }
                else { $ok = $false }
                if ($ok) {
                    $min = Get-PnhMember $sch 'minimum'
                    $max = Get-PnhMember $sch 'maximum'
                    if ($null -ne $min -and $n -lt [long]$min) { $errors.Add("parameter '$name' is below $min"); continue }
                    if ($null -ne $max -and $n -gt [long]$max) { $errors.Add("parameter '$name' is above $max"); continue }
                    if ($n -ge [int]::MinValue -and $n -le [int]::MaxValue) { $v = [int]$n } else { $v = $n }
                }
            }
            'number' {
                if ($v -is [bool]) { $ok = $false }
                elseif ($v -is [ValueType]) { $v = [double]$v }
                elseif ($v -is [string] -and $v -match '^\s*-?\d+(\.\d+)?\s*$') { $v = [double]::Parse($v.Trim(), $inv) }
                else { $ok = $false }
            }
            'boolean' {
                if ($v -is [bool]) { }
                elseif ($v -is [string] -and $v.Trim() -in @('true', 'false')) { $v = ($v.Trim() -eq 'true') }
                else { $ok = $false }
            }
            default { $ok = $false }
        }
        if (-not $ok) { $errors.Add("parameter '$name' must be of type $type"); continue }
        if ($v -is [string]) {
            if ($v -match '[\x00-\x1f]') { $errors.Add("parameter '$name' contains control characters"); continue }
            $maxLen = Get-PnhMember $sch 'maxLength'
            if ($null -ne $maxLen -and $v.Length -gt [int]$maxLen) { $errors.Add("parameter '$name' is longer than $maxLen"); continue }
            $pattern = [string](Get-PnhMember $sch 'pattern')
            if ($pattern -and -not [regex]::IsMatch($v, $pattern)) { $errors.Add("parameter '$name' does not match the allowed pattern"); continue }
        }
        $enum = Get-PnhMember $sch 'enum'
        if ($null -ne $enum) {
            $match = @($enum | Where-Object { "$_" -eq "$v" }) | Select-Object -First 1
            if ($null -eq $match) { $errors.Add("parameter '$name' must be one of: " + (@($enum) -join ', ')); continue }
            $v = $match
        }
        $values[$name] = $v
    }
    return [pscustomobject]@{ Valid = ($errors.Count -eq 0); Errors = $errors.ToArray(); Values = $values }
}

function Get-PnhParameterChoices {
    <#
    .SYNOPSIS
        Runs the read-only detection that a parameter's "x-choices" names (the action's detect
        script, or another read-only action) and returns the allowed values per parameter.
    .OUTPUTS
        Hashtable parameter name -> string/int array. Parameters without x-choices are absent.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns a set.')]
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Action, [string]$RunFolder, [string]$Language)
    $result = @{}
    $groups = @{}
    foreach ($s in @(Get-PnhParamSpec -Action $Action)) {
        $ch = Get-PnhMember $s.Schema 'x-choices'
        if ($null -eq $ch) { continue }
        $from = [string](Get-PnhMember $ch 'from')
        if (-not $groups.ContainsKey($from)) { $groups[$from] = New-Object System.Collections.Generic.List[object] }
        $groups[$from].Add([pscustomobject]@{ Name = $s.Name; Property = [string](Get-PnhMember $ch 'property'); Filter = (Get-PnhMember $ch 'filter') })
    }
    foreach ($from in $groups.Keys) {
        $code = $null
        if ($from -eq 'detect') { $code = $Action.detect }
        else {
            $src = Get-PnhAction -Id $from
            if ($src -and -not $src.changes) { $code = $src.run }
        }
        if (-not $code) { throw "No detection script for parameter choices of $($Action.id) ($from)" }
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ('pnh-detect-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        try {
            $ctx = New-PnhScriptContext -Parameters @{} -Backup $tmp -RunFolder $RunFolder -Language $Language
            $raw = Invoke-PnhCatalogScript -Code $code -Context $ctx -TimeoutSeconds ([int]$Action.timeoutSeconds)
            $rows = @($raw)
        } finally {
            Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        }
        foreach ($g in $groups[$from]) {
            $vals = New-Object System.Collections.Generic.List[object]
            foreach ($row in $rows) {
                if ($null -eq $row) { continue }
                $keep = $true
                if ($g.Filter) {
                    foreach ($fp in (ConvertTo-PnhPlainHashtable -InputObject $g.Filter).GetEnumerator()) {
                        if ("$(Get-PnhMember $row $fp.Key)" -ne "$($fp.Value)") { $keep = $false }
                    }
                }
                if (-not $keep) { continue }
                foreach ($v in @(Get-PnhMember $row $g.Property)) {
                    if ($null -ne $v -and "$v" -ne '' -and -not ($vals | Where-Object { "$_" -eq "$v" })) { $vals.Add($v) }
                }
            }
            $result[$g.Name] = $vals.ToArray()
        }
    }
    return $result
}

# ------------------------------------------------------------------ tool definitions for Ollama

function Get-PnhToolDescription {
    <#
    .SYNOPSIS
        Short, plain tool description for small models: title, explanation, consequences.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)]$Action, [string]$Language = 'en')
    $title = Get-PnhLocalizedText -Value $Action.title -Language $Language
    $explain = Get-PnhLocalizedText -Value $Action.explain -Language $Language
    $d = $title.TrimEnd('.') + '. ' + $explain
    $extra = @()
    if (Test-PnhConfirmRequired -Action $Action) { $extra += $(if ($Language -eq 'de') { 'Fragt vorher nach.' } else { 'Asks the user first.' }) }
    if ($Action.reboot) { $extra += $(if ($Language -eq 'de') { 'Startet den Computer neu.' } else { 'Restarts the computer.' }) }
    if ($extra.Count) { $d = $d + ' ' + ($extra -join ' ') }
    if ($d.Length -gt 400) { $d = $d.Substring(0, 397) + '...' }
    return $d
}

function ConvertTo-PnhToolDefinitions {
    <#
    .SYNOPSIS
        Builds the Ollama "tools" array for catalogue actions.

    .DESCRIPTION
        One {type='function'; function={name; description; parameters}} per action. The tool name
        is the action id. Only parameters the model may set ("x-setBy": "model") are included.
        Left out entirely: experimental actions (unless -IncludeExperimental), actions that need a
        value only the user can give, and actions whose required choices came back empty (nothing
        to act on). Allowed values found by detection become "enum".

        Without -Choices the detection runs automatically on Windows (read-only, a few seconds);
        -NoChoices skips it. Items are written to the pipeline: wrap the call in @().

    .PARAMETER Choices
        Optional hashtable: action id -> (parameter name -> allowed values).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Name fixed by the architecture contract.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Actions,
        [ValidateSet('de', 'en')][string]$Language = 'en',
        [hashtable]$Choices,
        [switch]$NoChoices,
        [switch]$IncludeExperimental,
        [string]$RunFolder
    )
    foreach ($a in @($Actions)) {
        if ($null -eq $a) { continue }
        if ($a.experimental -and -not $IncludeExperimental) { continue }
        $spec = @(Get-PnhParamSpec -Action $a)
        $choiceMap = $null
        if ($Choices -and $Choices.ContainsKey($a.id)) {
            $choiceMap = ConvertTo-PnhPlainHashtable -InputObject $Choices[$a.id]
        } elseif (-not $NoChoices -and -not $Choices -and (Test-PnhIsWindows) -and
            @($spec | Where-Object { $null -ne (Get-PnhMember $_.Schema 'x-choices') -and (Get-PnhMember $_.Schema 'x-setBy') -eq 'model' }).Count) {
            try { $choiceMap = Get-PnhParameterChoices -Action $a -RunFolder $RunFolder -Language $Language }
            catch { Write-PnhToolboxLog -Message "Parameter detection failed for $($a.id): $($_.Exception.Message)" -Level Warn }
        }
        $props = [ordered]@{}
        $required = New-Object System.Collections.Generic.List[string]
        $skip = $false
        foreach ($s in $spec) {
            if ((Get-PnhMember $s.Schema 'x-setBy') -ne 'model') {
                if ($s.Required) { $skip = $true }
                continue
            }
            $prop = [ordered]@{
                type        = [string](Get-PnhMember $s.Schema 'type')
                description = (Get-PnhLocalizedText -Value (Get-PnhMember $s.Schema 'description') -Language $Language)
            }
            $enum = Get-PnhMember $s.Schema 'enum'
            if ($null -ne $enum) { $prop['enum'] = @($enum) }
            if ($choiceMap -and $choiceMap.ContainsKey($s.Name)) {
                $vals = @($choiceMap[$s.Name] | Where-Object { $null -ne $_ })
                if (-not $vals.Count -and $s.Required) { $skip = $true }
                if ($vals.Count) {
                    if ($null -ne $enum) { $vals = @($vals | Where-Object { @($enum) -contains $_ }) }
                    $prop['enum'] = @($vals)
                }
            }
            $props[$s.Name] = $prop
            if ($s.Required) { $required.Add($s.Name) }
        }
        if ($skip) { continue }
        [ordered]@{
            type     = 'function'
            function = [ordered]@{
                name        = [string]$a.id
                description = (Get-PnhToolDescription -Action $a -Language $Language)
                parameters  = [ordered]@{ type = 'object'; properties = $props; required = @($required.ToArray()) }
            }
        }
    }
}

# ------------------------------------------------------------------ restore point

$script:PnhRestorePointState = @{}

function Invoke-PnhRestorePointCreation {
    <#
    .SYNOPSIS
        Tries to create one restore point (CIM, works in PowerShell 5.1 and 7). Never throws.
    .OUTPUTS
        [pscustomobject]@{ Created; Reason; Detail; Sequence; Time }
        Reason: created | not-windows | not-admin | server-os | frequency-limit |
                system-protection-disabled | not-created | error
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Description)
    $r = [ordered]@{ Created = $false; Reason = ''; Detail = ''; Sequence = $null; Time = $null }
    try {
        if (-not (Test-PnhIsWindows)) { $r.Reason = 'not-windows'; $r.Detail = 'Restore points exist only on Windows.'; return [pscustomobject]$r }
        if (-not (Test-PnhElevated)) { $r.Reason = 'not-admin'; $r.Detail = 'Creating a restore point needs administrator rights.'; return [pscustomobject]$r }
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        if ([int]$os.ProductType -ne 1) { $r.Reason = 'server-os'; $r.Detail = 'Windows Server has no System Restore.'; return [pscustomobject]$r }
        $before = @(Get-PnhRestorePointList | Sort-Object Sequence -Descending | Select-Object -First 1)
        if ($before.Count -and $before[0].Created -gt (Get-Date).AddHours(-24)) {
            $r.Reason = 'frequency-limit'
            $r.Detail = 'Windows allows one restore point per 24 hours; the existing point from ' + $before[0].Created.ToString('s') + ' is used.'
            $r.Sequence = $before[0].Sequence
            $r.Time = $before[0].Created.ToString('s')
            return [pscustomobject]$r
        }
        if (-not (Test-PnhSystemProtection)) { $r.Reason = 'system-protection-disabled'; $r.Detail = 'System Protection is off for the system drive.'; return [pscustomobject]$r }
        $desc = $Description
        if ($desc.Length -gt 60) { $desc = $desc.Substring(0, 60) }
        $res = Invoke-CimMethod -Namespace 'root/default' -ClassName SystemRestore -MethodName CreateRestorePoint -Arguments @{ Description = $desc; RestorePointType = [uint32]12; EventType = [uint32]100 } -ErrorAction Stop
        $rv = [int]$res.ReturnValue
        if ($rv -eq 1058) { $r.Reason = 'system-protection-disabled'; $r.Detail = 'The System Restore service is disabled (1058).'; return [pscustomobject]$r }
        if ($rv -ne 0) { $r.Reason = 'error'; $r.Detail = "CreateRestorePoint returned $rv."; return [pscustomobject]$r }
        $after = @(Get-PnhRestorePointList | Sort-Object Sequence -Descending | Select-Object -First 1)
        if ($after.Count -and (-not $before.Count -or $after[0].Sequence -gt $before[0].Sequence)) {
            $r.Created = $true
            $r.Reason = 'created'
            $r.Sequence = $after[0].Sequence
            $r.Time = $after[0].Created.ToString('s')
        } else {
            $r.Reason = 'not-created'
            $r.Detail = 'Windows accepted the request but no new restore point appeared (frequency limit or no space).'
        }
    } catch {
        $r.Reason = 'error'
        $r.Detail = $_.Exception.Message
    }
    return [pscustomobject]$r
}

function New-PnhRestorePoint {
    <#
    .SYNOPSIS
        Creates a restore point once per run (the first call per run folder decides; later calls
        return the cached result). Logs "skipped" with the reason when no point is created,
        e.g. on Windows Server, within the 24-hour frequency limit or with System Protection off.
    .PARAMETER RunFolder
        Key for "once per run"; defaults to $script:PnhRunFolder (Common.ps1) or a process-wide key.
    .PARAMETER Force
        Ignore the cached result and try again.
    .OUTPUTS
        [pscustomobject]@{ Created; Reason; Detail; Sequence; Time }
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creating a restore point is the safety net itself.')]
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$Description, [string]$RunFolder, [switch]$Force)
    $key = $RunFolder
    if (-not $key) { $key = [string]$script:PnhRunFolder }
    if (-not $key) { $key = '(process)' }
    if (-not $script:PnhRestorePointState) { $script:PnhRestorePointState = @{} }
    if (-not $Force -and $script:PnhRestorePointState.ContainsKey($key)) { return $script:PnhRestorePointState[$key] }
    $res = Invoke-PnhRestorePointCreation -Description $Description
    $script:PnhRestorePointState[$key] = $res
    if ($res.Created) {
        Write-PnhToolboxLog -Message "Restore point created (sequence $($res.Sequence))" -Data $res
    } else {
        Write-PnhToolboxLog -Message "Restore point skipped: $($res.Reason). $($res.Detail)" -Level Warn -Data $res
    }
    return $res
}

# ------------------------------------------------------------------ running catalogue scripts

function New-PnhScriptContext {
    <#
    .SYNOPSIS
        Builds the variable set handed to catalogue scripts ($P, $Backup, $PnhRoot, ...).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds data in memory only.')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([hashtable]$Parameters = @{}, [string]$Backup, [string]$RunFolder, [string]$Language, [datetime]$Start = (Get-Date))
    return @{
        P         = $Parameters
        Backup    = $Backup
        Root      = (Get-PnhDriveRoot)
        Start     = $Start
        BuildDate = (Get-PnhBuildDate)
        RunFolder = $RunFolder
        Language  = (Get-PnhToolboxLanguage -Language $Language)
    }
}

function Invoke-PnhCatalogScript {
    <#
    .SYNOPSIS
        Runs one catalogue script in the current runspace via [scriptblock]::Create with
        $ErrorActionPreference = 'Stop' and the action deadline for external programs.
    .OUTPUTS
        Object array with everything the script wrote to the pipeline.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Code,
        [Parameter(Mandatory = $true)][hashtable]$Context,
        [int]$TimeoutSeconds = 60
    )
    $pnhHeader = 'param($P, $Backup, $PnhRoot, $PnhStart, $PnhBuildDate, $PnhRunFolder, $PnhLanguage)' + "`n" + '$ErrorActionPreference = ''Stop''' + "`n"
    $pnhBlock = [scriptblock]::Create($pnhHeader + $Code)
    $pnhPrevious = $script:PnhActionDeadline
    $script:PnhActionDeadline = (Get-Date).AddSeconds([math]::Max(5, $TimeoutSeconds))
    try {
        $pnhOut = @(& $pnhBlock $Context.P $Context.Backup $Context.Root $Context.Start $Context.BuildDate $Context.RunFolder $Context.Language)
    } finally {
        $script:PnhActionDeadline = $pnhPrevious
    }
    return , $pnhOut
}

function New-PnhActionFolder {
    <#
    .SYNOPSIS
        Creates <RunFolder>\backups\<yyyyMMdd-HHmmss>-<nn>-<id> and returns its path.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates our own backup folder.')]
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true)][string]$RunFolder, [Parameter(Mandatory = $true)][string]$Id)
    $base = Join-Path $RunFolder 'backups'
    New-Item -ItemType Directory -Path $base -Force | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $n = 1
    do {
        $dir = Join-Path $base ('{0}-{1:00}-{2}' -f $stamp, $n, $Id)
        $n++
    } while (Test-Path -LiteralPath $dir)
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

function Invoke-PnhActionRollback {
    <#
    .SYNOPSIS
        Runs an action's rollback script with the stored parameters and backup folder.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Action, [Parameter(Mandatory = $true)][hashtable]$Context)
    if (-not $Action.rollback) { throw ('No rollback: ' + [string]$Action.rollbackNote) }
    return , (Invoke-PnhCatalogScript -Code $Action.rollback -Context $Context -TimeoutSeconds ([int]$Action.timeoutSeconds))
}

# ------------------------------------------------------------------ the action runner

function Invoke-PnhAction {
    <#
    .SYNOPSIS
        Runs one catalogue action safely.

    .DESCRIPTION
        Order: find -> experimental check -> validate parameters -> stop-finding blocks -> admin and
        user-context checks -> parameter values must come from detection -> confirmation
        (confirm / risk >= medium / reboot / deletes; no -Confirm block means "declined") ->
        restore point before the first changing action of the run -> backup (failure = stop,
        nothing changed) -> run with timeout -> verify (a script decides, exactly $true) ->
        result. If the run itself fails, the rollback runs automatically.

    .PARAMETER Confirm
        Scriptblock that receives @{Id; Title; Explain; Risk; Reboot; Deletes; Parameters} and
        returns $true (go) or anything else (declined).
    .PARAMETER Flags
        Optional finding codes of the diagnosis; their "blocks" are enforced here as well.
    .PARAMETER AllowExperimental
        Experimental actions are refused without this switch.
    .PARAMETER Action
        Catalogue entry to use instead of looking up -Id (tests, previews).

    .OUTPUTS
        [pscustomobject]@{ Id; Ok; Verified; Declined; Output; Error; RolledBack; NeedsReboot;
                           Data; Stop; Title; Changes; Parameters; BackupPath; RestorePoint; DurationMs }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        $Parameters,
        [Parameter(Mandatory = $true)][string]$RunFolder,
        [scriptblock]$Confirm,
        [string]$Language,
        [string[]]$Flags = @(),
        [switch]$AllowExperimental,
        [switch]$SkipChoiceCheck,
        $Action
    )
    $started = Get-Date
    $lang = Get-PnhToolboxLanguage -Language $Language
    $res = [ordered]@{
        Id = $Id; Ok = $false; Verified = $false; Declined = $false; Output = ''; Error = $null
        RolledBack = $false; NeedsReboot = $false; Data = $null; Stop = $null; Title = ''; Changes = $false
        Parameters = @{}; BackupPath = $null; RestorePoint = $null; DurationMs = 0
    }
    $finish = {
        $res.DurationMs = [int]((Get-Date) - $started).TotalMilliseconds
        $o = [pscustomobject]$res
        if ($res.BackupPath -and (Test-Path -LiteralPath $res.BackupPath)) {
            try {
                $copy = [ordered]@{}
                foreach ($k in $res.Keys) { if ($k -ne 'Data') { $copy[$k] = $res[$k] } }
                $copy['DataShort'] = ConvertTo-PnhShortText -InputObject $res.Data -Max 4000
                Write-PnhStateJson -InputObject ([pscustomobject]$copy) -Path (Join-Path $res.BackupPath 'result.json')
            } catch {
                Write-Verbose "result.json: $($_.Exception.Message)"
            }
        }
        $level = $(if ($res.Ok -or $res.Declined) { 'Info' } else { 'Warn' })
        Write-PnhToolboxLog -Message ("Action {0}: ok={1} verified={2} declined={3}" -f $Id, $res.Ok, $res.Verified, $res.Declined) -Level $level -Data @{
            id = $Id; ok = $res.Ok; verified = $res.Verified; declined = $res.Declined; error = $res.Error
            rolledBack = $res.RolledBack; needsReboot = $res.NeedsReboot; backup = $res.BackupPath; ms = $res.DurationMs
            output = (ConvertTo-PnhShortText -InputObject $res.Output -Max 500)
        }
        return $o
    }

    if (-not $Action) { $Action = Get-PnhAction -Id $Id }
    if (-not $Action) { $res.Error = "Unknown action: $Id"; return (& $finish) }
    $res.Title = Get-PnhLocalizedText -Value $Action.title -Language $lang
    $res.Changes = [bool]$Action.changes

    if ($Action.experimental -and -not $AllowExperimental) {
        $res.Error = 'This action is experimental and is not run automatically.'
        return (& $finish)
    }
    $check = Test-PnhParameters -Action $Action -Parameters $Parameters
    if (-not $check.Valid) { $res.Error = 'Invalid parameters: ' + ($check.Errors -join '; '); return (& $finish) }
    $values = $check.Values
    $res.Parameters = $values

    $blockedBy = Test-PnhActionBlocked -Action $Action -Flags $Flags
    if ($blockedBy) { $res.Error = "Blocked by finding $blockedBy."; return (& $finish) }
    if ($Action.admin -and -not (Test-PnhElevated)) { $res.Error = 'This action needs administrator rights.'; return (& $finish) }
    if ($Action.changes -and $Action.context -eq 'user' -and (($Flags -contains 'ELEVATED_OTHER_USER') -or (Test-PnhOtherUserElevation))) {
        $res.Error = 'This action changes settings of the signed-in user, but Plug''n''Heal runs under another account.'
        return (& $finish)
    }

    if (-not $SkipChoiceCheck -and $values.Count) {
        $needs = @(Get-PnhParamSpec -Action $Action | Where-Object { $values.ContainsKey($_.Name) -and $null -ne (Get-PnhMember $_.Schema 'x-choices') })
        if ($needs.Count) {
            try {
                $choices = Get-PnhParameterChoices -Action $Action -RunFolder $RunFolder -Language $lang
            } catch {
                $res.Error = 'Could not check the parameters against detection: ' + $_.Exception.Message
                return (& $finish)
            }
            foreach ($s in $needs) {
                if (-not $choices.ContainsKey($s.Name)) { continue }
                $v = $values[$s.Name]
                $hit = @($choices[$s.Name] | Where-Object { "$_" -eq "$v" })
                if (-not $hit.Count) {
                    $res.Error = "The value for '$($s.Name)' was not found by detection: $v"
                    return (& $finish)
                }
            }
        }
    }

    if (Test-PnhConfirmRequired -Action $Action) {
        $request = @{
            Id         = $Action.id
            Title      = $res.Title
            Explain    = (Get-PnhLocalizedText -Value $Action.explain -Language $lang)
            Risk       = [string]$Action.risk
            Reboot     = [bool]$Action.reboot
            Deletes    = [bool]$Action.deletes
            Parameters = $values
        }
        $answer = $false
        if ($Confirm) {
            try { $answer = & $Confirm $request } catch { Write-PnhToolboxLog -Message "Confirm callback failed: $($_.Exception.Message)" -Level Warn; $answer = $false }
        }
        if (@($answer)[-1] -ne $true) {
            $res.Declined = $true
            return (& $finish)
        }
    }

    if ($Action.changes -and -not $Action.skipRestorePoint) {
        $res.RestorePoint = New-PnhRestorePoint -Description ("Plug'n'Heal: " + $Action.id) -RunFolder $RunFolder
    }

    $codeAll = '' + $Action.backup + $Action.run + $Action.verify + $Action.rollback
    if ($Action.changes -or $codeAll -match '\$Backup\b') { $res.BackupPath = New-PnhActionFolder -RunFolder $RunFolder -Id $Action.id }
    $ctx = New-PnhScriptContext -Parameters $values -Backup $res.BackupPath -RunFolder $RunFolder -Language $lang -Start $started
    $timeout = [int]$Action.timeoutSeconds
    if ($timeout -le 0) { $timeout = 60 }
    if ($res.BackupPath) {
        try {
            Write-PnhStateJson -InputObject ([pscustomobject]@{ Id = $Action.id; Parameters = $values; Start = $started.ToString('o'); RunFolder = $RunFolder }) -Path (Join-Path $res.BackupPath 'request.json')
        } catch {
            $res.Error = 'Could not write to the backup folder: ' + $_.Exception.Message
            return (& $finish)
        }
    }

    if ($Action.backup) {
        try {
            [void](Invoke-PnhCatalogScript -Code $Action.backup -Context $ctx -TimeoutSeconds $timeout)
        } catch {
            $res.Error = 'Backup failed, nothing was changed: ' + $_.Exception.Message
            return (& $finish)
        }
    }

    $out = $null
    try {
        $out = Invoke-PnhCatalogScript -Code $Action.run -Context $ctx -TimeoutSeconds $timeout
    } catch {
        $res.Error = 'Run failed: ' + $_.Exception.Message
        if ($Action.changes -and $Action.rollback) {
            try {
                [void](Invoke-PnhActionRollback -Action $Action -Context $ctx)
                $res.RolledBack = $true
            } catch {
                $res.Error += ' Rollback failed: ' + $_.Exception.Message
            }
        }
        return (& $finish)
    }
    $elapsed = ((Get-Date) - $started).TotalSeconds
    if ($elapsed -gt $timeout) { Write-PnhToolboxLog -Message "Action $($Action.id) took $([int]$elapsed) s (limit $timeout s)" -Level Warn }

    $items = @($out)
    if ($items.Count -eq 1) { $res.Data = $items[0] } elseif ($items.Count -gt 1) { $res.Data = $items }
    $res.Output = ConvertTo-PnhShortText -InputObject $res.Data -Max 1500

    if ($Action.guide) {
        $text = Get-PnhLocalizedText -Value $Action.guide -Language $lang
        foreach ($m in [regex]::Matches($text, '\{(\w+)\}')) {
            $val = Get-PnhMember -Object $res.Data -Name $m.Groups[1].Value
            if ($null -ne $val) { $text = $text.Replace($m.Value, [string]$val) }
        }
        $res.Data = [pscustomobject]@{ Guide = $text; Question = (Get-PnhLocalizedText -Value $Action.guide.question -Language $lang); Values = $res.Data }
        $res.Output = $text
    }

    if ($Action.stopWhen) {
        $flag = Get-PnhMember -Object @($items)[0] -Name ([string]$Action.stopWhen.property)
        if ($flag -eq $true) {
            $code = [string]$Action.stopWhen.finding
            $f = (Get-PnhFindingCatalog)[$code]
            $res.Stop = [pscustomobject]@{ Finding = $code; Text = $(if ($f) { Get-PnhLocalizedText -Value $f.stop -Language $lang } else { '' }) }
        }
    }

    if ($Action.verifyAfterReboot) {
        $res.NeedsReboot = $true
        $res.Ok = $true
        $res.Verified = $false
        return (& $finish)
    }
    try {
        $vRaw = Invoke-PnhCatalogScript -Code $Action.verify -Context $ctx -TimeoutSeconds ([math]::Max(60, $timeout))
        $v = @($vRaw)
        $last = $(if ($v.Count) { $v[-1] } else { $null })
        $res.Verified = (($last -is [bool]) -and $last)
        if (-not ($last -is [bool])) { Write-PnhToolboxLog -Message "Verify of $($Action.id) did not return a boolean" -Level Warn }
    } catch {
        $res.Verified = $false
        $res.Error = 'Verify failed: ' + $_.Exception.Message
    }
    $res.Ok = [bool]$res.Verified
    if ($Action.reboot) { $res.NeedsReboot = $true }
    return (& $finish)
}

function Undo-PnhAction {
    <#
    .SYNOPSIS
        Runs the rollback of a finished action from its stored backup folder.
    .PARAMETER Result
        The result object of Invoke-PnhAction (or its result.json): needs Id and BackupPath.
    .OUTPUTS
        [pscustomobject]@{ Id; Ok; Error; Output }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Result, [string]$Language)
    $id = [string](Get-PnhMember $Result 'Id')
    $out = [ordered]@{ Id = $id; Ok = $false; Error = $null; Output = '' }
    $a = $(if ($id) { Get-PnhAction -Id $id } else { $null })
    if (-not $a) { $out.Error = "Unknown action: $id"; return [pscustomobject]$out }
    if (-not $a.rollback) { $out.Error = 'No rollback for this action. ' + [string]$a.rollbackNote; return [pscustomobject]$out }
    $backup = [string](Get-PnhMember $Result 'BackupPath')
    if (-not $backup -or -not (Test-Path -LiteralPath $backup)) { $out.Error = 'The backup folder of this action was not found.'; return [pscustomobject]$out }
    $req = $null
    $reqFile = Join-Path $backup 'request.json'
    if (Test-Path -LiteralPath $reqFile) { $req = Read-PnhStateJson -Path $reqFile }
    $params = ConvertTo-PnhPlainHashtable -InputObject (Get-PnhMember $Result 'Parameters')
    if (-not $params.Count -and $req) { $params = ConvertTo-PnhPlainHashtable -InputObject $req.Parameters }
    $start = Get-Date
    if ($req -and $req.Start) { $start = [datetime]::Parse([string]$req.Start, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
    $runFolder = $(if ($req -and $req.RunFolder) { [string]$req.RunFolder } else { Split-Path -Path (Split-Path -Path $backup -Parent) -Parent })
    $ctx = New-PnhScriptContext -Parameters $params -Backup $backup -RunFolder $runFolder -Language $Language -Start $start
    try {
        $o = Invoke-PnhActionRollback -Action $a -Context $ctx
        $out.Ok = $true
        $out.Output = ConvertTo-PnhShortText -InputObject $(if (@($o).Count -eq 1) { @($o)[0] } else { $o }) -Max 1500
    } catch {
        $out.Error = 'Rollback failed: ' + $_.Exception.Message
    }
    try { Write-PnhStateJson -InputObject ([pscustomobject]$out) -Path (Join-Path $backup 'undo.json') } catch { Write-Verbose "undo.json: $($_.Exception.Message)" }
    Write-PnhToolboxLog -Message "Undo $($id): ok=$($out.Ok)" -Level $(if ($out.Ok) { 'Info' } else { 'Warn' }) -Data $out
    return [pscustomobject]$out
}

# ------------------------------------------------------------------ deny-list for free PowerShell

$script:PnhWriteVerbRx = '(set-itemproperty|new-itemproperty|new-item|remove-item|remove-itemproperty|rename-item|rename-itemproperty|clear-item|clear-itemproperty|copy-item|move-item|\bsp\b|\bni\b|\bri\b|\brp\b|\brni\b|\brnp\b|\breg(\.exe)?\s+(add|delete|import|copy|restore|load)\b|\bregedit|\bregini|set-content|add-content|out-file|\.setvalue\(|\.deletevalue\(|\.deletesubkey|\.createsubkey|invoke-cimmethod|set-ciminstance|\bwmic\b)'
$script:PnhDeleteVerbRx = '(remove-item|remove-itemproperty|\bri\b|\brp\b|\bdel\b|\berase\b|\brd\b|\brm\b|\brmdir\b|\breg(\.exe)?\s+delete\b|clear-item|clear-itemproperty|\.deletesubkey|\.deletevalue|\.deletesubkeytree)'

$script:PnhDenyRules = @(
    @{ Rule = 'dynamic-code'; Reason = 'Hidden or generated code cannot be checked (Invoke-Expression, encoded commands, Add-Type, scriptblock creation).'
        Rx = @('\b(iex|invoke-expression)\b', '\[scriptblock\]::create', '\$executioncontext\.invokecommand', '\.invokescript\(', 'frombase64string', '\s-(e|ec|en|enc|enco|encod|encode|encoded|encodedc\w*)\s+[a-z0-9+/=]{20,}', '\badd-type\b', '\[powershell\]::create', 'system\.management\.automation\.powershell') }
    @{ Rule = 'defender'; Reason = 'Microsoft Defender must not be disabled, weakened or given exclusions.'
        Rx = @('\b(add|remove)-mppreference\b', 'set-mppreference\b[^;|\n]*(exclusion|-disable\w*\s*:?\s*(\$true|1|true)\b|\s(disabled|auditmode)(\s|$|;)|-(puaprotection|mapsreporting|submitsamplesconsent|enablecontrolledfolderaccess|enablenetworkprotection|cloudblocklevel|signaturedisableupdate\w*|disableautoexclusions|\w+threatdefaultaction|threatiddefaultaction\w*))', 'mpcmdrun(\.exe)?\b[^;|\n]*-(removedefinitions|disableservice)', '(uninstall-windowsfeature|remove-windowsfeature|disable-windowsoptionalfeature|/disable-feature)[^;|\n]*defender') }
    @{ Rule = 'security-service'; Reason = 'Security services (Defender, firewall, Defender for Endpoint, Security Center) must not be stopped or disabled.'
        Rx = @('(stop-service|\bspsv\b|set-service|suspend-service|remove-service|\bsc(\.exe)?\s+(stop|config|delete|pause|failure)\b|\bnet1?(\.exe)?\s+stop\b|taskkill|stop-process|\bkill\b|\bspps\b|wmic\s+service)[^;|\n]*\b(windefend|wdnissvc|wdnisdrv|wdfilter|wdboot|sense|mssense|sensecncproxy|msmpeng|nissrv|mpssvc|bfe|wscsvc|securityhealthservice|securityhealthsystray|sgrmbroker|mdcoresvc|webthreatdefsvc|webthreatdefusersvc|mpsdrv|mpdefendercoreservice)\b') }
    @{ Rule = 'firewall'; Reason = 'The firewall must not be reset, switched off, opened or have rules removed.'
        Rx = @('netsh(\.exe)?\s+(advfirewall|firewall)\b[^;|\n]*\b(reset|import)\b', 'netsh(\.exe)?\s+advfirewall\s+set\s+\S+\s+state\s+off', 'netsh(\.exe)?\s+firewall\s+set\s+opmode\s+(mode=)?disable', 'netsh(\.exe)?\s+advfirewall\s+set\s+\S+\s+firewallpolicy\s+\S*allowinbound', 'netsh(\.exe)?\s+(advfirewall\s+firewall|firewall)\s+(add|delete|set)\b', 'set-netfirewallprofile\b[^;|\n]*-enabled\s*:?\s*(\$false|false|0)\b', 'set-netfirewallprofile\b[^;|\n]*-default(inbound|outbound)action\s*:?\s*allow', '\b(remove|disable)-netfirewallrule\b', '\bnew-netfirewallrule\b[^;|\n]*-action\s*:?\s*allow', '\bset-netfirewallrule\b[^;|\n]*(-enabled\s*:?\s*(\$false|false|0)|-action\s*:?\s*allow)', '\bset-netfirewallsetting\b', '\bremove-netfirewall\w*') }
    @{ Rule = 'bitlocker'; Reason = 'BitLocker must not be changed, and its recovery key must never be read or shown.'
        Rx = @('\b(disable|suspend|enable|unlock|lock|resume|clear)-bitlocker\w*', '\b(add|remove|backup|backuptoaad)-bitlockerkeyprotector\b', 'manage-bde(\.exe)?(?![\w.])(?!\s+-status\b)', '\bget-bitlockervolume\b', 'recoverypassword|recoverykey|keyprotector', 'win32_encryptablevolume', '\brepair-bde\b', '\bbdehdcfg\b') }
    @{ Rule = 'isolation'; Reason = 'Network filters and device isolation (Defender for Endpoint, security drivers) must not be touched.'
        Rx = @('\bdisable-netadapterbinding\b', '\bset-netadapterbinding\b[^;|\n]*-enabled\s*:?\s*(\$false|false|0)', '\bnetcfg(\.exe)?\b[^;|\n]*\s-u\b', '\bfltmc(\.exe)?\s+(unload|detach)\b', '\bnetsh(\.exe)?\s+wfp\s+(set|add|delete)\b') }
    @{ Rule = 'disk-destroy'; Reason = 'Formatting, partitioning, boot configuration and wiping are never allowed.'
        Rx = @('(^|[\s;&|(])format(\.com|\.exe)?\s+[a-z]:', '\bformat-volume\b', '\bdiskpart\b', '\b(clear-disk|initialize-disk|remove-partition|resize-partition|set-partition|new-partition|remove-physicaldisk|reset-physicaldisk|remove-virtualdisk|remove-storagepool|set-disk)\b', '\bbcdedit(\.exe)?(?![\w.])(?!\s+/enum\b)', '\b(bcdboot|bootrec|bootsect)\b', '\bcipher(\.exe)?\b[^;|\n]*\s/w\b', '\bsdelete(64)?\b', '\bchkdsk(\.exe)?\b[^;|\n]*\s/(r|b|x)\b', '\bfsutil(\.exe)?\s+(?!(dirty\s+(query|set)|fsinfo|volume\s+diskfree|8dot3name\s+query)\b)') }
    @{ Rule = 'backups'; Reason = 'Restore points, shadow copies and backups must not be deleted or shrunk.'
        Rx = @('\bvssadmin(\.exe)?\s+(delete|resize)\b', '\bwmic(\.exe)?\s+shadowcopy\s+delete', 'win32_shadowcopy[^;\n]*(remove-ciminstance|remove-wmiobject|\.delete\()', '(remove-ciminstance|remove-wmiobject)[^;\n]*win32_shadowcopy', '\bwbadmin(\.exe)?\s+delete\b', '\bdisable-computerrestore\b') }
    @{ Rule = 'user-data'; Reason = 'User data, profiles, apps and logs must not be deleted.'
        Rx = @('\bclear-recyclebin\b', 'win32_userprofile[^;\n]*(remove-ciminstance|remove-wmiobject|\.delete\()', '(remove-ciminstance|remove-wmiobject)[^;\n]*win32_userprofile', '\bdelprof2?\b', '\b(reset|remove)-appxpackage\b', '\bremove-appxprovisionedpackage\b', '\bwevtutil(\.exe)?\s+(cl|clear-log)\b', '\b(clear|remove)-eventlog\b', '\bauditpol(\.exe)?\s+/(clear|remove)\b', '\brobocopy(\.exe)?\b[^;|\n]*\s/(mir|purge|move|mov)\b', '\[(system\.)?io\.(file|directory)\]::delete', '\.delete\(\s*(\$true)?\s*\)') }
    @{ Rule = 'accounts'; Reason = 'Accounts, passwords and group memberships are not changed.'
        Rx = @('\bnet1?(\.exe)?\s+(user|localgroup|accounts)\b[^;|\n]*(/add|/del|/delete|/active|/passwordreq|/passwordchg|/expires|/times)', '\bnet1?(\.exe)?\s+user\s+[^/\s]\S*\s+[^/\s]', '\b(new|set|remove|disable|enable|rename)-localuser\b', '\b(add|remove)-localgroupmember\b', '\b(new|remove|rename|set)-localgroup\b') }
    @{ Rule = 'policy'; Reason = 'Execution policy, App Control and AppLocker are not changed.'
        Rx = @('\bset-executionpolicy\b(?![^;|\n]*-scope\s+process\b)', '\bset-applockerpolicy\b', '\bcitool(\.exe)?\b') }
)

$script:PnhDenyComboRules = @(
    @{ Rule = 'defender'; Reason = 'Settings of Defender, SmartScreen, Defender for Endpoint, the firewall or UAC must not be written.'
        Verb = 'write'; Rx = '(windows defender|windows advanced threat protection|\\sense\b|smartscreen|\\windefend|\\wdfilter|\\wdboot|\\wdnisdrv|\\mpssvc|\\bfe\b|\\wscsvc|\\securityhealthservice|tamperprotection|disableantispyware|disableantivirus|disablerealtimemonitoring\s*(=|/d|-value)|\\policies\\microsoft\\windowsfirewall|firewallpolicy|enablelua|consentpromptbehavior|promptonsecuredesktop|filteradministratortoken)' }
    @{ Rule = 'credential-protection'; Reason = 'LSA and Credential Guard settings must not be written.'
        Verb = 'write'; Rx = '(\\control\\lsa\b|\\deviceguard\b|runasppl|lsacfgflags|credentialguard)' }
    @{ Rule = 'registry-system'; Reason = 'Registry deletes under HKLM\SYSTEM (and SAM/SECURITY) are never allowed.'
        Verb = 'delete'; Rx = '(hklm:?\\(system|sam|security)\b|hkey_local_machine\\(system|sam|security)\b|registry::hklm\\(system|sam|security)\b|localmachine\.opensubkey\(\s*(system|sam|security)\b)' }
)

function Test-PnhTempPathText {
    <#
    .SYNOPSIS
        $true if a path argument (as written in a command) clearly lies in a temp folder:
        $env:TEMP, $env:TMP, [IO.Path]::GetTempPath(), C:\Windows\Temp, %LOCALAPPDATA%\Temp,
        C:\Users\<name>\AppData\Local\Temp. Paths with '..' are never temp paths.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([string]$Text)
    if (-not $Text) { return $false }
    $t = ($Text -replace '[`"'']', '').Trim().ToLowerInvariant() -replace '/', '\'
    if ($t.StartsWith('(') -and $t.EndsWith(')')) { $t = $t.Substring(1, $t.Length - 2).Trim() }
    $t = $t.Replace('([system.io.path]::gettemppath())', '[io.path]::gettemppath()').Replace('([io.path]::gettemppath())', '[io.path]::gettemppath()')
    # GetTempPath() ends with a backslash, so '+' after it appends inside the temp folder.
    $t = $t -replace '(gettemppath\(\))\s*\+\s*', '$1\'
    if ($t -match '^join-path\s+(-path\s+)?(\S+)\s+(-childpath\s+)?(.+)$') { $t = $Matches[2].TrimEnd('\') + '\' + $Matches[4].Trim() }
    if ($t -match '\.\.') { return $false }
    $rx = '^(\$env:(temp|tmp)|%temp%|%tmp%|\$\{env:(temp|tmp)\}|\[(system\.)?io\.path\]::gettemppath\(\)|[a-z]:\\windows\\temp|\$env:(systemroot|windir)\\temp|%(systemroot|windir)%\\temp|[a-z]:\\users\\[^\\]+\\appdata\\local\\temp|\$env:localappdata\\temp|%localappdata%\\temp|\$env:userprofile\\appdata\\local\\temp)(\\|$)'
    return [bool]($t -match $rx)
}

function Get-PnhDeleteFinding {
    <#
    .SYNOPSIS
        AST check of delete commands (Remove-Item and aliases, Clear-Content, cmd del/rd):
        returns a reason string when a path is not clearly a temp path, else $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)]$Ast, [string]$Normalized, [string]$Flat)
    $deleteNames = @('remove-item', 'rm', 'del', 'erase', 'rd', 'rmdir', 'ri', 'clear-content', 'clc')
    $listNames = @('get-childitem', 'gci', 'ls', 'dir', 'get-item', 'gi')
    $valueParams = @('include', 'exclude', 'filter', 'erroraction', 'ea', 'stream', 'credential', 'warningaction', 'informationaction', 'errorvariable', 'outvariable')
    $found = 0
    $cmdFound = 0
    $cmds = $Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($c in $cmds) {
        $name = $c.GetCommandName()
        if (-not $name) { continue }
        $name = $name.ToLowerInvariant()
        if ($name -in @('cmd', 'cmd.exe')) {
            $rest = (@($c.CommandElements | Select-Object -Skip 1 | ForEach-Object { $_.Extent.Text }) -join ' ').ToLowerInvariant()
            if ($rest -match '\b(del|erase|rd|rmdir|format)\b(.*)$') {
                $cmdFound++
                $paths = @($Matches[2] -split '\s+' | Where-Object { $_ -and -not $_.StartsWith('/') -and $_ -notin @('&', '&&', '|') })
                if (-not $paths.Count) { return 'cmd delete without a path' }
                foreach ($p in $paths) { if (-not (Test-PnhTempPathText -Text $p)) { return "cmd delete outside temp folders: $p" } }
            }
            continue
        }
        if ($name -notin $deleteNames) { continue }
        if ($name -in @('remove-item', 'rm', 'ri')) { $found++ }
        $paths = New-Object System.Collections.Generic.List[string]
        $els = @($c.CommandElements)
        $i = 1
        while ($i -lt $els.Count) {
            $e = $els[$i]
            if ($e -is [System.Management.Automation.Language.CommandParameterAst]) {
                $pn = $e.ParameterName.ToLowerInvariant()
                if ($pn -in @('path', 'literalpath', 'lp', 'pspath')) {
                    if ($e.Argument) { $paths.Add($e.Argument.Extent.Text) }
                    elseif ($i + 1 -lt $els.Count) { $paths.Add($els[$i + 1].Extent.Text); $i++ }
                } elseif ($pn -in $valueParams -and -not $e.Argument) {
                    $i++
                }
            } else {
                $paths.Add($e.Extent.Text)
            }
            $i++
        }
        if (-not $paths.Count) {
            $pipe = $c.Parent
            $src = $null
            if ($pipe -is [System.Management.Automation.Language.PipelineAst] -and $pipe.PipelineElements.Count -gt 1 -and $pipe.PipelineElements[0] -ne $c) {
                $src = $pipe.PipelineElements[0]
            }
            if ($src -is [System.Management.Automation.Language.CommandAst] -and $src.GetCommandName() -and $src.GetCommandName().ToLowerInvariant() -in $listNames) {
                $srcPaths = @($src.CommandElements | Select-Object -Skip 1 | Where-Object { -not ($_ -is [System.Management.Automation.Language.CommandParameterAst]) } | ForEach-Object { $_.Extent.Text })
                if (-not $srcPaths.Count) { return 'delete of piped items without a temp path' }
                foreach ($p in $srcPaths) { if (-not (Test-PnhTempPathText -Text $p)) { return "delete outside temp folders: $p" } }
                continue
            }
            return 'delete without an explicit temp path'
        }
        foreach ($p in $paths) { if (-not (Test-PnhTempPathText -Text $p)) { return "delete outside temp folders: $p" } }
    }
    $textCount = ([regex]::Matches($Normalized, '\bremove-item\b')).Count
    if ($textCount -gt $found) { return 'delete command inside a string or nested command' }
    $cmdText = ([regex]::Matches($Flat, '\bcmd(\.exe)?\s+/[ck]\b[^;|\n]*\b(del|erase|rd|rmdir)\b')).Count
    if ($cmdText -gt $cmdFound) { return 'cmd delete inside a string or nested command' }
    return $null
}

function Test-PnhCommandDenied {
    <#
    .SYNOPSIS
        Hard deny-list for PowerShell commands proposed by a model. Returns $true when the command
        must never run (whatever the user answers).

    .DESCRIPTION
        Blocks: disabling or bypassing Defender (incl. exclusions, tamper/SmartScreen/UAC keys),
        stopping security services, firewall reset/off/open/rule removal, any BitLocker change and
        any read of recovery keys, network-filter and isolation tampering, format/diskpart/
        partitioning, bcdedit (except /enum), cipher /w, deleting restore points/shadow copies/
        backups, deleting user data, profiles, apps or event logs, Remove-Item (and aliases, cmd
        del/rd) outside temp folders, registry deletes under HKLM\SYSTEM, account changes,
        execution-policy/App Control changes, and hidden code (Invoke-Expression, encoded
        commands, Add-Type, dynamic invocation). Unparsable commands are denied.

        The check is conservative and text based plus AST based; it is a last line of defence,
        not a sandbox. Read-only vs. changing commands are decided elsewhere (Agent.ps1).

    .PARAMETER Detailed
        Return [pscustomobject]@{ Denied; Rule; Reason } instead of [bool].

    .EXAMPLE
        Test-PnhCommandDenied -Command 'netsh advfirewall reset'   # -> $true
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Command, [switch]$Detailed)
    $verdict = { param($d, $rule, $reason) if ($Detailed) { return [pscustomobject]@{ Denied = $d; Rule = $rule; Reason = $reason } } return [bool]$d }
    if ([string]::IsNullOrWhiteSpace($Command)) { return (& $verdict $false $null $null) }

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($Command, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count) { return (& $verdict $true 'unparsable' 'The command cannot be parsed, so it cannot be checked.') }

    $n1 = (($Command -replace '[`^]', '') -replace '["'']', '').ToLowerInvariant()
    $n1 = ($n1 -replace '\s+', ' ').Trim()
    $n2 = $n1 -replace '\s*\+\s*', ''
    # Variant without call plumbing: 'Start-Process netsh -ArgumentList @(advfirewall, reset)' -> 'start-process netsh advfirewall reset'
    $n3 = $n1 -replace '-(argumentlist|args|filepath|nonewwindow|passthru|wait)\b', ' ' -replace '-(windowstyle|verb)\s+\S+', ' ' -replace '[@(){},]', ' '
    $n3 = ($n3 -replace '\s+', ' ').Trim()
    $texts = @($n1, $n2, $n3)

    foreach ($rule in $script:PnhDenyRules) {
        foreach ($rx in $rule.Rx) {
            foreach ($t in $texts) {
                if ($t -match $rx) { return (& $verdict $true $rule.Rule $rule.Reason) }
            }
        }
    }
    foreach ($rule in $script:PnhDenyComboRules) {
        $verbRx = $(if ($rule.Verb -eq 'delete') { $script:PnhDeleteVerbRx } else { $script:PnhWriteVerbRx })
        foreach ($t in $texts) {
            if (($t -match $verbRx) -and ($t -match $rule.Rx)) { return (& $verdict $true $rule.Rule $rule.Reason) }
        }
    }

    # AST: dynamic invocation (& $x, & ('a'+'b')) cannot be checked.
    $cmds = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)
    foreach ($c in $cmds) {
        if ($c.InvocationOperator -in @([System.Management.Automation.Language.TokenKind]::Ampersand, [System.Management.Automation.Language.TokenKind]::Dot)) {
            $first = $c.CommandElements[0]
            $okFirst = ($first -is [System.Management.Automation.Language.StringConstantExpressionAst]) -or
            ($first -is [System.Management.Automation.Language.ScriptBlockExpressionAst]) -or
            (($first -is [System.Management.Automation.Language.ExpandableStringExpressionAst]) -and ($first.Extent.Text -notmatch '\$\('))
            if (-not $okFirst) { return (& $verdict $true 'dynamic-code' 'Commands built at run time cannot be checked.') }
        }
        # Set-MpPreference may only switch protection ON: every parameter -Disable*:$false / 0.
        $name = $c.GetCommandName()
        if ($name -and $name.ToLowerInvariant() -eq 'set-mppreference') {
            $els = @($c.CommandElements)
            for ($i = 1; $i -lt $els.Count; $i++) {
                $e = $els[$i]
                if (-not ($e -is [System.Management.Automation.Language.CommandParameterAst])) { continue }
                $pn = $e.ParameterName.ToLowerInvariant()
                $val = $null
                if ($e.Argument) { $val = $e.Argument.Extent.Text } elseif ($i + 1 -lt $els.Count -and -not ($els[$i + 1] -is [System.Management.Automation.Language.CommandParameterAst])) { $val = $els[$i + 1].Extent.Text; $i++ }
                $okParam = ($pn -like 'disable*') -and ("$val".ToLowerInvariant() -in @('$false', '0', 'false'))
                if (-not $okParam -and $pn -notin @('erroraction', 'ea', 'force')) {
                    return (& $verdict $true 'defender' 'Microsoft Defender must not be disabled, weakened or given exclusions.')
                }
            }
        }
    }
    $del = Get-PnhDeleteFinding -Ast $ast -Normalized $n1 -Flat $n3
    if ($del) { return (& $verdict $true 'delete' ('Deleting is only allowed in temp folders (' + $del + ').')) }
    return (& $verdict $false $null $null)
}
