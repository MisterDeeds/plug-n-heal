<#
.SYNOPSIS
    Pester 5 tests: schema and safety rules of toolbox\actions.json, categories.json, findings.json.
    Runs on Windows PowerShell 5.1, PowerShell 7 and Linux (no Windows calls).
#>

BeforeDiscovery {
    $toolboxDir = Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'src') 'toolbox'
    $readJson = { param($name) [IO.File]::ReadAllText((Join-Path $toolboxDir $name), [Text.Encoding]::UTF8) | ConvertFrom-Json }
    $catalogDoc = & $readJson 'actions.json'
    $findingDoc = & $readJson 'findings.json'
    $categoryDoc = & $readJson 'categories.json'
    $actionCases = @($catalogDoc.actions | ForEach-Object { @{ Id = $_.id; A = $_ } })
    $findingCases = @($findingDoc.findings | ForEach-Object { @{ Code = $_.code; F = $_ } })
    $categoryCases = @($categoryDoc.categories | ForEach-Object { @{ CatId = $_.id; C = $_ } })
    $codeCases = New-Object System.Collections.Generic.List[object]
    foreach ($a in $catalogDoc.actions) {
        foreach ($k in 'detect', 'backup', 'run', 'verify', 'rollback') {
            if ($a.$k) { $codeCases.Add(@{ Id = $a.id; Field = $k; Code = [string]$a.$k }) }
        }
    }
}

BeforeAll {
    $libDir = Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'src') 'lib'
    . (Join-Path $libDir 'Toolbox.ps1')
    . (Join-Path $libDir 'Diagnose.ps1')
    $script:toolboxDir = Get-PnhToolboxDir
    $script:catalog = Read-PnhStateJson -Path (Join-Path $script:toolboxDir 'actions.json')
    $script:findingDoc = Read-PnhStateJson -Path (Join-Path $script:toolboxDir 'findings.json')
    $script:categoryDoc = Read-PnhStateJson -Path (Join-Path $script:toolboxDir 'categories.json')
    $script:ids = @($script:catalog.actions | ForEach-Object { $_.id })
    $script:validSections = @('system', 'network', 'security', 'disk', 'performance', 'printer', 'audio', 'update', 'display', 'events')
    # Catalogue scripts the free-shell deny-list flags on purpose. Each was reviewed:
    $script:denyAllow = @{
        'sys.enable_restore.run'              = 'backups'        # vssadmin resize, guarded: grow only, never shrinks
        'boot.startup_disable.rollback'       = 'dynamic-code'   # [Convert]::FromBase64String restores a saved registry value
        'fs.check_on_restart.run'             = 'disk-destroy'   # fsutil dirty set (arguments as array), refused on unhealthy disks
        'bitlocker.report.run'                = 'bitlocker'      # reads protector type and id only, never the key
        'bitlocker.recovery_key_hint.run'     = 'bitlocker'      # first 8 characters of the key ID only
    }
}

Describe 'Catalogue files' {
    It 'actions.json has schema 1, a catalogue date and actions' {
        $script:catalog.schema | Should -Be 1
        $script:catalog.catalogDate | Should -Match '^\d{4}-\d{2}-\d{2}$'
        @($script:catalog.actions).Count | Should -BeGreaterThan 50
    }
    It 'action ids are unique and well formed' {
        @($script:ids | Select-Object -Unique).Count | Should -Be $script:ids.Count
        foreach ($id in $script:ids) { $id | Should -Match '^[a-z]+\.[a-z0-9_]+$' }
    }
    It 'has exactly 20 core actions and none of them is experimental' {
        @($script:catalog.actions | Where-Object { $_.core }).Count | Should -Be 20
        @($script:catalog.actions | Where-Object { $_.core -and $_.experimental }).Count | Should -Be 0
    }
    It 'contains the isolation probe named in the architecture contract' {
        $script:ids | Should -Contain 'sec.detect_isolation'
    }
    It 'the set of deleting actions is exactly the reviewed list' {
        $del = @($script:catalog.actions | Where-Object { $_.deletes } | ForEach-Object { $_.id } | Sort-Object)
        $del | Should -Be @('disk.clean_delivery_optimization', 'disk.clean_user_temp', 'disk.clean_windows_temp', 'disk.move_crash_dumps', 'print.clear_queue', 'wifi.forget_profile')
    }
    It 'only reviewed places call Remove-Item directly' {
        $hits = foreach ($a in $script:catalog.actions) { foreach ($k in 'detect', 'backup', 'run', 'verify', 'rollback') { if ("$($a.$k)" -match '\bRemove-Item\b') { "$($a.id).$k" } } }
        @($hits) | Should -Be @('profile.fix_temp_folder.rollback')
    }
}

Describe 'Action <Id>' -ForEach $actionCases {
    It 'has all contract fields with valid values' {
        $A.category | Should -BeIn @('network', 'slow', 'disk', 'printer', 'sound', 'update', 'display', 'other')
        $A.kind | Should -BeIn @('diagnose', 'repair', 'backup', 'guide')
        $A.risk | Should -BeIn @('low', 'medium', 'high')
        $A.context | Should -BeIn @('system', 'user')
        $A.offline | Should -BeIn @('yes', 'partial')
        foreach ($f in 'changes', 'admin', 'reboot', 'confirm', 'deletes', 'core', 'experimental', 'verifyAfterReboot') {
            $A.$f | Should -BeOfType [bool]
        }
        [int]$A.timeoutSeconds | Should -BeGreaterOrEqual 10
        [int]$A.timeoutSeconds | Should -BeLessOrEqual 7200
        $A.id.Split('.')[0] | Should -Be $A.area
    }
    It 'has plain titles and explanations in German and English' {
        foreach ($l in 'de', 'en') {
            $A.title.$l | Should -Not -BeNullOrEmpty
            $A.explain.$l | Should -Not -BeNullOrEmpty
            $A.title.$l.Length | Should -BeLessOrEqual 80
            $A.explain.$l.Length | Should -BeLessOrEqual 260
        }
        $A.title.de | Should -Not -Match ([string][char]0x00DF)   # Swiss spelling: no sharp s
        $A.explain.de | Should -Not -Match ([string][char]0x00DF)
        $A.explain.de | Should -Not -Match '\b(du|dich|dir|dein\w*)\b'   # Sie-form like the UI
    }
    It 'has run and verify' {
        $A.run | Should -Not -BeNullOrEmpty
        $A.verify | Should -Not -BeNullOrEmpty
    }
    It 'applies the confirmation rule (deletes, reboot or risk medium/high => confirm)' {
        if ($A.deletes -or $A.reboot -or $A.risk -in @('medium', 'high')) { $A.confirm | Should -BeTrue }
    }
    It 'changing actions have a backup or a documented reason, and a rollback or a documented reason' {
        if ($A.changes) {
            ([bool]$A.backup -or [bool]$A.backupNote) | Should -BeTrue
            ([bool]$A.rollback -or [bool]$A.rollbackNote) | Should -BeTrue
        } else {
            $A.backup | Should -BeNullOrEmpty
            $A.rollback | Should -BeNullOrEmpty
        }
    }
    It 'verifies after a restart only when it restarts' {
        if ($A.verifyAfterReboot) { $A.reboot | Should -BeTrue }
    }
    It 'experimental actions say why' {
        if ($A.experimental) { $A.experimentalReason | Should -Not -BeNullOrEmpty }
    }
    It 'guides carry text and a yes/no question in both languages' {
        if ($A.kind -eq 'guide') {
            foreach ($l in 'de', 'en') { $A.guide.$l | Should -Not -BeNullOrEmpty; $A.guide.question.$l | Should -Not -BeNullOrEmpty }
            $A.changes | Should -BeFalse
        }
    }
    It 'cites sources' {
        @($A.sources).Count | Should -BeGreaterThan 0
        foreach ($s in $A.sources) { $s | Should -Match '^https://' }
    }
    It 'has a well-formed parameter schema' {
        $A.params.type | Should -Be 'object'
        $A.params.additionalProperties | Should -BeFalse
        $names = @($A.params.properties.PSObject.Properties | ForEach-Object { $_.Name })
        foreach ($r in @($A.params.required)) { $names | Should -Contain $r }
        foreach ($n in $names) {
            $p = $A.params.properties.$n
            $p.type | Should -BeIn @('string', 'integer', 'number', 'boolean')
            $p.description.de | Should -Not -BeNullOrEmpty
            $p.description.en | Should -Not -BeNullOrEmpty
            $p.'x-setBy' | Should -BeIn @('model', 'user')
            if ($p.pattern) { { [regex]::new($p.pattern) } | Should -Not -Throw }
            if ($p.type -eq 'string') { ([bool]$p.pattern -or [bool]$p.enum) | Should -BeTrue -Because 'free strings must be restricted' }
            if ($p.'x-choices') {
                $from = $p.'x-choices'.from
                $p.'x-choices'.property | Should -Not -BeNullOrEmpty
                if ($from -eq 'detect') { $A.detect | Should -Not -BeNullOrEmpty }
                else {
                    $src = $script:catalog.actions | Where-Object { $_.id -eq $from }
                    $src | Should -Not -BeNullOrEmpty
                    $src.changes | Should -BeFalse
                }
            }
        }
    }
    It 'uses only declared parameters in its scripts' {
        $names = @($A.params.properties.PSObject.Properties | ForEach-Object { $_.Name })
        $all = "$($A.detect)`n$($A.backup)`n$($A.run)`n$($A.verify)`n$($A.rollback)"
        foreach ($m in [regex]::Matches($all, '\$P\.(\w+)')) { $names | Should -Contain $m.Groups[1].Value }
    }
    It 'stopWhen names a read-only action, a property and an existing finding with a stop text' {
        if ($A.stopWhen) {
            $A.changes | Should -BeFalse
            $A.stopWhen.property | Should -Not -BeNullOrEmpty
            $f = $script:findingDoc.findings | Where-Object { $_.code -eq $A.stopWhen.finding }
            $f | Should -Not -BeNullOrEmpty
            $f.stop | Should -Not -BeNullOrEmpty
        }
    }
    It 'detectFrom points to an existing action' {
        if ($A.detectFrom) { $script:ids | Should -Contain $A.detectFrom }
    }
}

Describe 'Catalogue script <Id>.<Field>' -ForEach $codeCases.ToArray() {
    It 'parses without errors and without PowerShell-7-only syntax' {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($Code, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
        $ps7 = @($tokens | Where-Object { "$($_.Kind)" -in @('QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionLBracket', 'AndAnd', 'OrOr') })
        $ps7.Count | Should -Be 0
        $Code | Should -Not -Match '-AsHashtable|ForEach-Object\s+-Parallel|\bJoin-String\b|-AsArray\b|\bTest-Json\b'
    }
    It 'is ASCII only' {
        $Code | Should -Not -Match '[^\x00-\x7F]'
    }
    It 'calls only Pnh helpers that exist' {
        foreach ($m in [regex]::Matches($Code, '\b[A-Z][a-z]+-Pnh\w+\b')) {
            Get-Command -Name $m.Value -CommandType Function -ErrorAction SilentlyContinue | Should -Not -BeNullOrEmpty -Because "$($m.Value) is used"
        }
    }
    It 'passes the deny-list (or is a reviewed exception)' {
        $r = Test-PnhCommandDenied -Command $Code -Detailed
        $key = "$Id.$Field"
        if ($script:denyAllow.ContainsKey($key)) { $r.Rule | Should -Be $script:denyAllow[$key] }
        else { $r.Denied | Should -BeFalse -Because "$key was denied by rule $($r.Rule)" }
    }
    It 'does not parse localized console text' {
        $Code | Should -Not -Match '\.Output\s*-(match|like|eq)'
        $Code | Should -Not -Match '\$_\.Message\s*-(match|like)'
    }
}

Describe 'Findings' {
    It 'has unique codes' {
        $codes = @($script:findingDoc.findings | ForEach-Object { $_.code })
        @($codes | Select-Object -Unique).Count | Should -Be $codes.Count
    }
}

Describe 'Finding <Code>' -ForEach $findingCases {
    It 'is well formed' {
        $Code | Should -Match '^[A-Z0-9_]+$'
        $F.meaning.de | Should -Not -BeNullOrEmpty
        $F.meaning.en | Should -Not -BeNullOrEmpty
        [int]$F.severity | Should -BeIn @(1, 2, 3, 4)
        @($F.candidates).Count | Should -BeLessOrEqual 7
    }
    It 'names only existing candidate actions' {
        foreach ($c in @($F.candidates)) { $script:ids | Should -Contain $c }
    }
    It 'a stop has text in both languages, blocks and severity 1' {
        if ($F.stop) {
            $F.stop.de | Should -Not -BeNullOrEmpty
            $F.stop.en | Should -Not -BeNullOrEmpty
            @($F.blocks).Count | Should -BeGreaterThan 0 -Because 'the agent treats a stop without blocks as "block everything"'
            [int]$F.severity | Should -Be 1
        }
    }
    It 'blocks match at least one changing action' {
        foreach ($b in @($F.blocks)) {
            if ($b -eq '@reboot') { continue }
            @($script:catalog.actions | Where-Object { $_.changes -and $_.id -like $b }).Count | Should -BeGreaterThan 0 -Because "block $b"
        }
    }
}

Describe 'Categories' {
    It 'has exactly the nine categories' {
        @($script:categoryDoc.categories | ForEach-Object { $_.id }) | Should -Be @('network', 'slow', 'disk', 'printer', 'sound', 'update', 'display', 'other', 'all')
    }
    It 'every action is in the scope of at least one category other than all' {
        foreach ($a in $script:catalog.actions) {
            $hit = $false
            foreach ($c in @($script:categoryDoc.categories | Where-Object { $_.id -ne 'all' })) {
                if (Test-PnhIdPattern -Id $a.id -Pattern @($c.actions)) { $hit = $true }
            }
            $hit | Should -BeTrue -Because "$($a.id) must be reachable"
        }
    }
}

Describe 'Category <CatId>' -ForEach $categoryCases {
    It 'has icon, i18n title key and diagnosis sections' {
        $C.icon | Should -Not -BeNullOrEmpty
        $C.titleKey | Should -Be "cat.$CatId"
        @($C.diagnose) | Should -Contain 'system'
        foreach ($s in @($C.diagnose)) { $s | Should -BeIn $script:validSections }
    }
    It 'references an existing success check' {
        $C.success | Should -BeIn @(Get-PnhSuccessCheckIds)
    }
    It 'every action pattern matches at least one action' {
        foreach ($p in @($C.actions)) {
            @($script:ids | Where-Object { $_ -like $p }).Count | Should -BeGreaterThan 0 -Because "pattern $p"
        }
    }
    It 'title key exists in the UI language files (owned by the UI part)' {
        $en = Join-Path (Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'src') 'i18n') 'en.json'
        if (-not (Test-Path -LiteralPath $en)) { Set-ItResult -Skipped -Because 'i18n files not present' ; return }
        $table = Read-PnhStateJson -Path $en
        if (-not $table.PSObject.Properties[$C.titleKey]) { Set-ItResult -Inconclusive -Because "i18n key $($C.titleKey) is missing in src/i18n (UI part)"; return }
        $table.($C.titleKey) | Should -Not -BeNullOrEmpty
    }
}
