#Requires -Version 5.1
<#
.SYNOPSIS
    Pester 5 tests for START.cmd, Start.ps1, Ui.ps1 and the i18n files: everything that needs no display.

.DESCRIPTION
    WinForms is not exercised (it needs Windows with a desktop). Instead:
      * the i18n files are checked for completeness and consistency (de vs en, keys used by the scripts),
      * START.cmd is checked as text (command line, quoting, line endings),
      * Start.ps1 and Ui.ps1 are parsed, and their pure helper functions are loaded from the AST and tested,
      * the background job of Ui.ps1 runs for real in demo mode in its own runspace, including the
        confirmation hand-shake through the synchronized hashtable and cancelling.
    Runs on Windows PowerShell 5.1 and PowerShell 7 (also on Linux).
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'Pester 5 shares BeforeAll variables with the It blocks')]
param()

BeforeAll {
    $RepoRoot = Split-Path -Parent $PSScriptRoot
    $Src = Join-Path -Path $RepoRoot -ChildPath 'src'
    $StartCmdPath = Join-Path -Path $Src -ChildPath 'START.cmd'
    $StartPs1Path = Join-Path -Path $Src -ChildPath 'Start.ps1'
    $UiPs1Path = Join-Path -Path $Src -ChildPath 'Ui.ps1'
    $DePath = Join-Path -Path (Join-Path -Path $Src -ChildPath 'i18n') -ChildPath 'de.json'
    $EnPath = Join-Path -Path (Join-Path -Path $Src -ChildPath 'i18n') -ChildPath 'en.json'

    function Get-TestAst {
        param([Parameter(Mandatory = $true)][string]$Path)
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        return @{ Ast = $ast; Errors = @($errors); Tokens = @($tokens) }
    }

    function Get-TestFunctionText {
        # Top-level function definitions of a script, as text, so that tests can define them without running it.
        param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string[]]$Name)
        $ast = (Get-TestAst -Path $Path).Ast
        $found = @($ast.FindAll({
                    param($n)
                    $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $Name -contains $n.Name
                }, $false))
        $missing = @($Name | Where-Object { $found.Name -notcontains $_ })
        if ($missing.Count -gt 0) { throw ('Functions not found in ' + $Path + ': ' + ($missing -join ', ')) }
        return @($found | ForEach-Object { $_.Extent.Text })
    }

    function Get-TestAssignedValue {
        # Right-hand side AST of "$script:<Name> = ..." at the top level of a script.
        param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Variable)
        $ast = (Get-TestAst -Path $Path).Ast
        $assign = $ast.FindAll({
                param($n)
                $n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq $Variable
            }, $false) | Select-Object -First 1
        if (-not $assign) { throw ('Assignment not found: ' + $Variable) }
        return $assign.Right.Expression
    }

    function Read-TestJson {
        param([Parameter(Mandatory = $true)][string]$Path)
        $text = [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding($false, $true)))
        $obj = $text | ConvertFrom-Json
        $table = [ordered]@{}
        foreach ($p in $obj.PSObject.Properties) { $table[$p.Name] = $p.Value }
        return $table
    }

    function Get-TestPlaceholder {
        param([string]$Text)
        return @([regex]::Matches($Text, '\{\d+\}') | ForEach-Object { $_.Value } | Sort-Object -Unique)
    }

    $De = Read-TestJson -Path $DePath
    $En = Read-TestJson -Path $EnPath
}

Describe 'i18n files' {
    It 'are UTF-8 JSON objects whose values are all non-empty strings' {
        foreach ($table in @($De, $En)) {
            $table.Count | Should -BeGreaterThan 50
            foreach ($k in $table.Keys) {
                $table[$k] | Should -BeOfType [string] -Because $k
                $table[$k].Trim() | Should -Not -BeNullOrEmpty -Because $k
            }
        }
    }

    It 'contain no duplicate keys' {
        foreach ($path in @($DePath, $EnPath)) {
            $keys = @([regex]::Matches([System.IO.File]::ReadAllText($path), '(?m)^\s*"([^"]+)"\s*:') | ForEach-Object { $_.Groups[1].Value })
            $dupes = @($keys | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
            $dupes | Should -BeNullOrEmpty -Because $path
        }
    }

    It 'de and en have identical key sets' {
        $onlyDe = @($De.Keys | Where-Object { -not $En.Contains($_) })
        $onlyEn = @($En.Keys | Where-Object { -not $De.Contains($_) })
        $onlyDe | Should -BeNullOrEmpty -Because 'these keys are missing in en.json'
        $onlyEn | Should -BeNullOrEmpty -Because 'these keys are missing in de.json'
    }

    It 'use flat dotted lower-case keys' {
        $bad = @($De.Keys | Where-Object { $_ -cnotmatch '^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$' })
        $bad | Should -BeNullOrEmpty
    }

    It 'have the same placeholders in de and en' {
        $bad = @($De.Keys | Where-Object { $En.Contains($_) -and ((Get-TestPlaceholder $De[$_]) -join ',') -ne ((Get-TestPlaceholder $En[$_]) -join ',') })
        $bad | Should -BeNullOrEmpty
    }

    It 'have no leading or trailing white space' {
        $bad = @()
        foreach ($table in @($De, $En)) { $bad += @($table.Keys | Where-Object { $table[$_] -ne $table[$_].Trim() }) }
        $bad | Should -BeNullOrEmpty
    }

    It 'German texts use Swiss spelling (no sharp s)' {
        $sharpS = [string][char]0x00DF
        $bad = @($De.Keys | Where-Object { $De[$_].Contains($sharpS) })
        $bad | Should -BeNullOrEmpty
    }

    It 'contain every key the window and the agent contract need' {
        $required = @(
            'app.name', 'app.window_title',
            'ui.welcome.title', 'ui.welcome.text', 'ui.welcome.start', 'ui.welcome.what', 'ui.about.title', 'ui.about.text',
            'ui.prepare.title', 'ui.prepare.hint', 'ui.elapsed', 'ui.step_of', 'ui.category.title', 'ui.category.text',
            'ui.other.title', 'ui.other.text', 'ui.other.example', 'ui.other.empty', 'ui.work.title', 'ui.work.hint',
            'ui.cancel.title', 'ui.cancel.text', 'ui.cancel.yes', 'ui.cancel.no', 'ui.readonly.banner',
            'step.hardware', 'step.model', 'step.start', 'step.diagnose', 'step.repair', 'step.verify',
            'cat.network', 'cat.slow', 'cat.disk', 'cat.printer', 'cat.sound', 'cat.update', 'cat.other', 'cat.all',
            'event.thinking', 'event.action', 'event.action_ok', 'event.action_failed', 'event.action_declined',
            'event.action_readonly', 'event.action_rolledback', 'event.action_reboot', 'event.error',
            'event.done.solved', 'event.done.unsolved',
            'confirm.heading', 'confirm.yes', 'confirm.no', 'confirm.reboot',
            'result.solved.title', 'result.unsolved.title', 'result.cancelled.title', 'result.reboot',
            'result.show_report', 'result.finish', 'result.report_path', 'result.actions.title', 'result.actions.none',
            'model.reason.gpu', 'model.reason.cpu', 'model.reason.preferred', 'model.reason.weak_hardware', 'model.reason.none_installed'
        )
        foreach ($s in @('waiting', 'running', 'done', 'problem', 'skipped')) { $required += 'step.state.' + $s }
        foreach ($r in @('low', 'medium', 'high', 'unknown')) { $required += 'confirm.risk.' + $r }
        foreach ($k in @('solved', 'unsolved', 'cancelled')) { $required += @(('result.' + $k + '.title'), ('result.' + $k + '.text')) }
        foreach ($e in @('language_mode', 'uac_refused', 'elevation_failed', 'not_admin', 'smode', 'ollama_start', 'no_model',
                'model_too_slow', 'computer_too_weak', 'damaged', 'already_running', 'unexpected', 'ui_start')) {
            $required += @(('error.' + $e + '.title'), ('error.' + $e + '.text'))
        }
        $missing = @($required | Where-Object { -not $De.Contains($_) })
        $missing | Should -BeNullOrEmpty
    }

    It 'contain every text key that Start.ps1 and Ui.ps1 spell out' {
        $pattern = '^(app|ui|step|cat|error|confirm|result|event|report|demo|model)\.[a-z0-9_.]*[a-z0-9_]$'
        $missing = @()
        foreach ($path in @($StartPs1Path, $UiPs1Path)) {
            $ast = (Get-TestAst -Path $path).Ast
            $strings = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) |
                    ForEach-Object { $_.Value } | Where-Object { $_ -cmatch $pattern } | Sort-Object -Unique)
            $strings.Count | Should -BeGreaterOrEqual 3 -Because $path
            foreach ($s in $strings) {
                # A key, or a base that is completed with .title/.text (error pages) or .detail (steps)
                $ok = $De.Contains($s) -or ($De.Contains($s + '.title') -and $De.Contains($s + '.text'))
                if (-not $ok) { $missing += ((Split-Path -Leaf $path) + ': ' + $s) }
            }
        }
        $missing | Should -BeNullOrEmpty
    }
}

Describe 'START.cmd' {
    BeforeAll {
        $bytes = [System.IO.File]::ReadAllBytes($StartCmdPath)
        $text = [System.Text.Encoding]::ASCII.GetString($bytes)
    }

    It 'is pure ASCII with CRLF line endings' {
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        $text | Should -Not -Match '(?<!\r)\n'
        $text.EndsWith("`r`n") | Should -BeTrue
    }

    It 'starts quietly and sets a friendly window title' {
        ($text -split "`r`n")[0] | Should -Be '@echo off'
        $text | Should -Match '(?m)^title Plug''n''Heal'
    }

    It 'calls Windows PowerShell 5.1 with the agreed command line for the drive layout' {
        $line = '"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0PlugNHeal\app\Start.ps1"'
        $text.Contains($line) | Should -BeTrue
    }

    It 'quotes every path built from %~dp0 (spaces in folder names)' {
        $unquoted = [regex]::Matches($text, '(?<!")%~dp0')
        $unquoted.Count | Should -Be 0
    }

    It 'does not enable delayed expansion (an exclamation mark in a path would break it)' {
        $text | Should -Not -Match '(?i)enabledelayedexpansion'
    }

    It 'treats exit codes 20 to 29 as already explained and otherwise explains and waits' {
        $text | Should -Match 'GEQ 20 if %PNH_RC% LEQ 29 goto end'
        $text | Should -Match '(?m)^pause'
        $text | Should -Match 'exit /b %PNH_RC%'
    }
}

Describe 'Start.ps1 and Ui.ps1 as scripts' {
    It '<Name> parses without errors' -ForEach @(@{ Name = 'Start.ps1' }, @{ Name = 'Ui.ps1' }) {
        $parsed = Get-TestAst -Path (Join-Path -Path $Src -ChildPath $Name)
        ($parsed.Errors | ForEach-Object { $_.ToString() }) | Should -BeNullOrEmpty
    }

    It '<Name> is ASCII only (Windows PowerShell 5.1 reads files without BOM as ANSI)' -ForEach @(@{ Name = 'Start.ps1' }, @{ Name = 'Ui.ps1' }) {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path -Path $Src -ChildPath $Name))
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'Ui.ps1 has the documented parameters' {
        $params = (Get-TestAst -Path $UiPs1Path).Ast.ParamBlock.Parameters.Name.VariablePath.UserPath
        foreach ($p in @('Demo', 'DemoFailure', 'ReadOnly', 'ReadOnlyReason', 'RunFolder')) { $params | Should -Contain $p }
    }

    It 'Start.ps1 has the documented parameters' {
        $params = (Get-TestAst -Path $StartPs1Path).Ast.ParamBlock.Parameters.Name.VariablePath.UserPath
        foreach ($p in @('ReadOnly', 'ReadOnlyReason', 'Elevated', 'RunFolder', 'Demo')) { $params | Should -Contain $p }
    }

    It 'Start.ps1 and Ui.ps1 accept the same read-only reasons, and each has an explanation' {
        $sets = foreach ($path in @($StartPs1Path, $UiPs1Path)) {
            $param = (Get-TestAst -Path $path).Ast.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'ReadOnlyReason' }
            $attr = $param.Attributes | Where-Object { $_.TypeName.Name -eq 'ValidateSet' }
            (@($attr.PositionalArguments.Value) | Sort-Object) -join ','
        }
        $sets[0] | Should -Be $sets[1]
        foreach ($r in ($sets[0] -split ',')) {
            $De.Contains('error.' + $r + '.title') | Should -BeTrue -Because $r
            $De.Contains('error.' + $r + '.text') | Should -BeTrue -Because $r
        }
    }

    It 'Start.ps1 checks the language mode before it loads any library' {
        $statements = @((Get-TestAst -Path $StartPs1Path).Ast.EndBlock.Statements)
        $langIndex = -1
        $loadIndex = -1
        for ($i = 0; $i -lt $statements.Count; $i++) {
            $t = $statements[$i].Extent.Text
            if ($langIndex -lt 0 -and $statements[$i] -is [System.Management.Automation.Language.IfStatementAst] -and $t -match 'FullLanguage') { $langIndex = $i }
            if ($loadIndex -lt 0 -and $t -match '\. \$commonPath') { $loadIndex = $i }
        }
        $langIndex | Should -BeGreaterOrEqual 0
        $loadIndex | Should -BeGreaterThan $langIndex
    }

    It 'Start.ps1 checks S mode first and explains it with error.smode (exit code 23)' {
        $statements = @((Get-TestAst -Path $StartPs1Path).Ast.EndBlock.Statements)
        $smodeIndex = -1
        $langIndex = -1
        for ($i = 0; $i -lt $statements.Count; $i++) {
            if ($statements[$i] -isnot [System.Management.Automation.Language.IfStatementAst]) { continue }
            $t = $statements[$i].Extent.Text
            if ($smodeIndex -lt 0 -and $statements[$i].Clauses[0].Item1.Extent.Text -match 'Test-StartSMode') { $smodeIndex = $i }
            if ($langIndex -lt 0 -and $t -match 'FullLanguage') { $langIndex = $i }
        }
        $smodeIndex | Should -BeGreaterOrEqual 0
        $smodeIndex | Should -BeLessThan $langIndex
        $body = $statements[$smodeIndex].Extent.Text
        $body | Should -Match "-Key 'error\.smode'"
        $body | Should -Match 'exit 23'
        $De.Contains('error.smode.title') | Should -BeTrue
    }

    It 'Start.ps1 keeps the ConstrainedLanguage path free of .NET types' {
        $ast = (Get-TestAst -Path $StartPs1Path).Ast
        $clmFunctions = @('Get-StartLanguage', 'Get-StartText', 'Write-StartLog', 'Initialize-StartFallbackLog', 'Test-StartSMode')
        $offenders = @()
        foreach ($f in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $clmFunctions -contains $n.Name }, $false)) {
            $offenders += @($f.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeExpressionAst] }, $true) | ForEach-Object { $f.Name + ': ' + $_.Extent.Text })
            $offenders += @($f.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and @('Add-Type', 'New-Object') -contains $n.GetCommandName() }, $true) | ForEach-Object { $f.Name + ': ' + $_.Extent.Text })
        }
        # Statements executed before the language-mode check run in ConstrainedLanguage too (definitions do not run).
        foreach ($s in $ast.EndBlock.Statements) {
            if ($s -is [System.Management.Automation.Language.IfStatementAst] -and $s.Extent.Text -match 'FullLanguage') { break }
            if ($s -is [System.Management.Automation.Language.FunctionDefinitionAst]) { continue }
            $offenders += @($s.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeExpressionAst] }, $true) | ForEach-Object { 'top: ' + $_.Extent.Text })
        }
        $offenders | Should -BeNullOrEmpty
    }

    It 'Start.ps1 asks for rights once with RunAs and starts the window without a console in STA' {
        $text = [System.IO.File]::ReadAllText($StartPs1Path)
        $text | Should -Match '-Verb RunAs'
        $text | Should -Match 'NativeErrorCode -eq 1223'
        $text | Should -Match '\$psi\.UseShellExecute = \$false'
        $text | Should -Match '\$psi\.CreateNoWindow = \$true'
        $text | Should -Match "'-STA'"
        $text | Should -Match "'-ReadOnly'"
    }

    It 'Ui.ps1 uses one background runspace, a ConcurrentQueue and a 200 ms Windows.Forms.Timer' {
        $text = [System.IO.File]::ReadAllText($UiPs1Path)
        $text | Should -Match 'System\.Collections\.Concurrent\.ConcurrentQueue\[object\]'
        $text | Should -Match '\[hashtable\]::Synchronized'
        $text | Should -Match 'New-Object System\.Windows\.Forms\.Timer'
        $text | Should -Match '\.Interval = 200'
        ([regex]::Matches($text, 'CreateRunspace\(')).Count | Should -Be 1
    }

    It 'Ui.ps1 handles every agent event type of ARCHITECTURE.md 5.7' {
        $ast = (Get-TestAst -Path $UiPs1Path).Ast
        $receive = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Receive-UiEvent' }, $false) | Select-Object -First 1
        $switch = $receive.FindAll({ param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst] }, $true) | Select-Object -First 1
        $handled = @($switch.Clauses | ForEach-Object { $_.Item1.Value })
        foreach ($t in @('step-start', 'step-done', 'thinking', 'action', 'action-result', 'message', 'done', 'error', 'confirm')) {
            $handled | Should -Contain $t
        }
    }
}

Describe 'Start.ps1 helpers' {
    BeforeAll {
        foreach ($f in (Get-TestFunctionText -Path $StartPs1Path -Name @('ConvertTo-StartArgument', 'Get-StartLanguage', 'Get-StartText', 'Write-StartLog', 'Test-StartSMode'))) {
            . ([scriptblock]::Create($f))
        }
        $script:AppDir = $Src
        $script:FullLanguage = $true
        $script:StartLogFile = $null

        function ConvertFrom-TestCommandLine {
            # The CommandLineToArgvW rules, to check that quoted arguments arrive unchanged.
            param([string]$Line)
            $args2 = New-Object System.Collections.Generic.List[string]
            $current = New-Object System.Text.StringBuilder
            $inQuotes = $false
            $hasToken = $false
            $i = 0
            while ($i -lt $Line.Length) {
                $c = $Line[$i]
                if ($c -eq '\') {
                    $n = 0
                    while ($i -lt $Line.Length -and $Line[$i] -eq '\') { $n++; $i++ }
                    if ($i -lt $Line.Length -and $Line[$i] -eq '"') {
                        $null = $current.Append('\' * [Math]::Floor($n / 2))
                        if ($n % 2 -eq 1) { $null = $current.Append('"'); $i++ }
                    } else {
                        $null = $current.Append('\' * $n)
                    }
                    $hasToken = $true
                    continue
                }
                if ($c -eq '"') { $inQuotes = -not $inQuotes; $hasToken = $true; $i++; continue }
                if (-not $inQuotes -and ($c -eq ' ' -or $c -eq "`t")) {
                    if ($hasToken) { $args2.Add($current.ToString()); $null = $current.Clear(); $hasToken = $false }
                    $i++
                    continue
                }
                $null = $current.Append($c)
                $hasToken = $true
                $i++
            }
            if ($hasToken) { $args2.Add($current.ToString()) }
            return , $args2.ToArray()
        }
    }

    It 'leaves simple arguments alone' {
        ConvertTo-StartArgument -Value 'C:\PlugNHeal\app\Ui.ps1' | Should -Be 'C:\PlugNHeal\app\Ui.ps1'
        ConvertTo-StartArgument -Value '-ReadOnly' | Should -Be '-ReadOnly'
    }

    It 'quotes <Value> so that it arrives unchanged' -ForEach @(
        @{ Value = 'E:\My Drive\PlugNHeal\app\Ui.ps1' }
        @{ Value = 'E:\Neuer Ordner\' }
        @{ Value = 'E:\a "quoted" name\x' }
        @{ Value = 'E:\back\\slashes \"mixed\' }
        @{ Value = '' }
        @{ Value = 'tab	inside' }
    ) {
        $quoted = ConvertTo-StartArgument -Value $Value
        $parsed = ConvertFrom-TestCommandLine -Line ('-File ' + $quoted + ' -ReadOnly')
        $parsed.Count | Should -Be 3
        $parsed[1] | Should -BeExactly $Value
        $parsed[2] | Should -Be '-ReadOnly'
    }

    It 'Test-StartSMode reads SkuPolicyRequired: <Case>' -ForEach @(
        @{ Case = '1 = S mode'; Value = 1; Expect = $true }
        @{ Case = '0 = no S mode'; Value = 0; Expect = $false }
        @{ Case = 'value missing = no S mode'; Value = $null; Expect = $false }
    ) {
        if ($null -eq $Value) { Mock Get-ItemProperty { throw 'Property SkuPolicyRequired does not exist' } }
        else { Mock Get-ItemProperty { [pscustomobject]@{ SkuPolicyRequired = $Value } } }
        Test-StartSMode | Should -Be $Expect
        Should -Invoke Get-ItemProperty -Times 1 -Exactly -ParameterFilter { $LiteralPath -eq 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' }
    }

    It 'reads texts straight from the i18n files when Common.ps1 is not loaded' {
        $lang = Get-StartLanguage
        $expected = $En['error.language_mode.title']
        if ($lang -eq 'de') { $expected = $De['error.language_mode.title'] }
        Get-StartText -Key 'error.language_mode.title' | Should -BeExactly $expected
    }

    It 'falls back to the given text, then to the key' {
        Get-StartText -Key 'does.not.exist' -Fallback 'Hello' | Should -Be 'Hello'
        Get-StartText -Key 'does.not.exist' | Should -Be 'does.not.exist'
    }

    It 'never throws when logging is impossible' {
        { Write-StartLog -Message 'test' -Level Warn } | Should -Not -Throw
    }
}

Describe 'Ui.ps1 helpers' {
    BeforeAll {
        # The fallback library of Ui.ps1 stands in for Common.ps1 (and gets tested along the way).
        $script:PnhFallbackAppDir = $Src
        $fallback = (Get-TestAssignedValue -Path $UiPs1Path -Variable '$script:UiFallbackLib').Value
        . ([scriptblock]::Create($fallback))
        $names = @('Get-UiText', 'Test-UiText', 'Write-UiLog', 'Format-UiElapsed', 'Get-UiRiskKey', 'Get-UiStepGlyph',
            'Get-UiCategoryList', 'Get-UiResultKind', 'Get-UiStoppedKey', 'Get-UiActionLine', 'Format-UiSummary')
        foreach ($f in (Get-TestFunctionText -Path $UiPs1Path -Name $names)) { . ([scriptblock]::Create($f)) }
        $Lang = Get-PnhLanguage
        $T = $En
        if ($Lang -eq 'de') { $T = $De }
    }

    It 'Get-UiText returns the text, formats arguments and falls back to the key' {
        Get-UiText -Key 'ui.welcome.start' | Should -BeExactly $T['ui.welcome.start']
        Get-UiText -Key 'ui.step_of' -Arguments @(2, 3) | Should -BeExactly ($T['ui.step_of'] -f 2, 3)
        Get-UiText -Key 'no.such.key' | Should -Be 'no.such.key'
        Test-UiText 'cat.network' | Should -BeTrue
        Test-UiText 'cat.nothing' | Should -BeFalse
    }

    It 'Format-UiElapsed shows <Seconds> s as <Expected>' -ForEach @(
        @{ Seconds = 0; Expected = '0:00' }
        @{ Seconds = 9.9; Expected = '0:09' }
        @{ Seconds = 65; Expected = '1:05' }
        @{ Seconds = 3725; Expected = '1:02:05' }
        @{ Seconds = -3; Expected = '0:00' }
    ) {
        Format-UiElapsed -Seconds $Seconds | Should -Be $Expected
    }

    It 'Get-UiRiskKey maps <Risk> to <Key>' -ForEach @(
        @{ Risk = 'low'; Key = 'confirm.risk.low' }
        @{ Risk = 'MEDIUM'; Key = 'confirm.risk.medium' }
        @{ Risk = ' high '; Key = 'confirm.risk.high' }
        @{ Risk = 'extreme'; Key = 'confirm.risk.unknown' }
        @{ Risk = $null; Key = 'confirm.risk.unknown' }
    ) {
        Get-UiRiskKey -Risk $Risk | Should -Be $Key
        $De.Contains($Key) | Should -BeTrue
    }

    It 'Get-UiStepGlyph uses the agreed symbols and a four-frame spinner' {
        [int][char](Get-UiStepGlyph -State 'waiting') | Should -Be 0x25CB
        [int][char](Get-UiStepGlyph -State 'done') | Should -Be 0x2713
        [int][char](Get-UiStepGlyph -State 'problem') | Should -Be 0x26A0
        [int][char](Get-UiStepGlyph -State 'skipped') | Should -Be 0x2013
        $frames = @(0..7 | ForEach-Object { Get-UiStepGlyph -State 'running' -Frame $_ })
        @($frames | Sort-Object -Unique).Count | Should -Be 4
        $frames[0] | Should -Be $frames[4]
    }

    It 'Get-UiCategoryList without categories.json offers check-everything first, the six categories, then something else' {
        $list = @(Get-UiCategoryList -Path (Join-Path -Path $TestDrive -ChildPath 'missing.json') -HasText ${function:Test-UiText})
        ($list.Id -join ',') | Should -Be 'all,network,slow,disk,printer,sound,update,other'
        $list[0].Kind | Should -Be 'wide'
        foreach ($c in $list) {
            $c.Icon | Should -Not -BeNullOrEmpty
            $De.Contains($c.TitleKey) | Should -BeTrue -Because $c.Id
        }
    }

    It 'Get-UiCategoryList follows categories.json, keeps its icons and skips categories without text' {
        $file = Join-Path -Path $TestDrive -ChildPath 'categories.json'
        # 'imaginary' has no i18n text on purpose (independent of the real language files).
        $json = '{ "categories": [ {"id":"printer","icon":"P","titleKey":"cat.printer"}, {"id":"imaginary","titleKey":"cat.imaginary"},' +
        ' {"id":"network"}, {"id":"all","icon":"A","titleKey":"cat.all"}, {"id":"network"} ] }'
        [System.IO.File]::WriteAllText($file, $json)
        $list = @(Get-UiCategoryList -Path $file -HasText ${function:Test-UiText})
        ($list.Id -join ',') | Should -Be 'all,printer,network,other'
        $list[0].Icon | Should -Be 'A'
        $list[1].Icon | Should -Be 'P'
        $list[2].Icon | Should -Be ([char]::ConvertFromUtf32(0x1F310))
    }

    It 'Get-UiCategoryList falls back to the built-in list when categories.json is broken' {
        $file = Join-Path -Path $TestDrive -ChildPath 'broken.json'
        [System.IO.File]::WriteAllText($file, '{ not json')
        @(Get-UiCategoryList -Path $file).Count | Should -Be 8
    }

    It 'Get-UiResultKind distinguishes solved, unsolved and cancelled' {
        Get-UiResultKind -Result @{ Solved = $true } | Should -Be 'solved'
        Get-UiResultKind -Result @{ Solved = $false } | Should -Be 'unsolved'
        Get-UiResultKind -Result $null | Should -Be 'unsolved'
        Get-UiResultKind -Result @{ Solved = $true } -Cancelled | Should -Be 'cancelled'
    }

    It 'Get-UiStoppedKey maps <Reason> to <Key>' -ForEach @(
        @{ Reason = 'isolated'; Key = 'result.stopped.isolated' }
        @{ Reason = 'MaxRounds'; Key = 'result.stopped.max_rounds' }
        @{ Reason = 'max-rounds'; Key = 'result.stopped.max_rounds' }
        @{ Reason = 'no progress'; Key = 'result.stopped.no_progress' }
        @{ Reason = 'finished'; Key = $null }
        @{ Reason = ''; Key = $null }
        @{ Reason = $null; Key = $null }
    ) {
        Get-UiStoppedKey -Reason $Reason -HasText ${function:Test-UiText} | Should -Be $Key
    }

    It 'Get-UiActionLine picks the right sentence for <Case>' -ForEach @(
        @{ Case = 'success'; Result = @{ Id = 'a'; Ok = $true; Verified = $true }; Key = 'event.action_ok'; ReadOnly = $false }
        @{ Case = 'no verify value'; Result = @{ Id = 'a'; Ok = $true }; Key = 'event.action_ok'; ReadOnly = $false }
        @{ Case = 'verify failed'; Result = @{ Id = 'a'; Ok = $true; Verified = $false }; Key = 'event.action_failed'; ReadOnly = $false }
        @{ Case = 'error'; Result = @{ Id = 'a'; Ok = $false }; Key = 'event.action_failed'; ReadOnly = $false }
        @{ Case = 'declined'; Result = @{ Id = 'a'; Ok = $false; Declined = $true }; Key = 'event.action_declined'; ReadOnly = $false }
        @{ Case = 'read-only'; Result = @{ Id = 'a'; Ok = $false; Declined = $true }; Key = 'event.action_readonly'; ReadOnly = $true }
        @{ Case = 'rolled back'; Result = @{ Id = 'a'; Ok = $false; RolledBack = $true }; Key = 'event.action_rolledback'; ReadOnly = $false }
        @{ Case = 'reboot'; Result = @{ Id = 'a'; Ok = $true; Verified = $true; NeedsReboot = $true }; Key = 'event.action_reboot'; ReadOnly = $false }
    ) {
        $line = Get-UiActionLine -Result $Result -Titles @{ a = 'Flush DNS' } -ReadOnly:$ReadOnly
        $line.Key | Should -Be $Key
        $line.Title | Should -Be 'Flush DNS'
        $line.Text | Should -BeExactly ($T[$Key] -f 'Flush DNS')
    }

    It 'Get-UiActionLine falls back to the action id as title' {
        (Get-UiActionLine -Result @{ Id = 'print.restart_spooler'; Ok = $true }).Title | Should -Be 'print.restart_spooler'
    }

    It 'Format-UiSummary writes a short CRLF report with result, actions and log folder' {
        $text = Format-UiSummary -ResultTitle 'RESULT' -ResultText 'TEXT' -CategoryTitle 'CAT' -UserText 'MY WORDS' -Summary "line1`nline2" `
            -ActionLines @('did one', 'did two') -NeedsReboot -ReadOnly -LogFolder 'E:\PlugNHeal\logs\PC-1' -Computer 'PC' -Date ([datetime]'2026-11-09 21:30')
        $text | Should -Match ([regex]::Escape($T['report.title']))
        $text | Should -Match '2026-11-09 21:30'
        $text | Should -Match 'RESULT'
        $text | Should -Match 'MY WORDS'
        $text | Should -Match '- did one\r\n- did two'
        $text | Should -Match ([regex]::Escape($T['report.reboot']))
        $text | Should -Match ([regex]::Escape($T['report.readonly']))
        $text | Should -Match ([regex]::Escape('E:\PlugNHeal\logs\PC-1'))
        $text.EndsWith("`r`n") | Should -BeTrue
    }

    It 'Format-UiSummary says so when nothing had to be changed' {
        $text = Format-UiSummary -ResultTitle 'R' -ActionLines @() -Computer ''
        $text | Should -Match ([regex]::Escape('- ' + $T['result.actions.none']))
    }
}

Describe 'Background job of Ui.ps1 (demo mode, real runspace, no WinForms)' {
    BeforeAll {
        $JobScript = (Get-TestAssignedValue -Path $UiPs1Path -Variable '$script:JobScript').ScriptBlock.GetScriptBlock()
        $FallbackLib = (Get-TestAssignedValue -Path $UiPs1Path -Variable '$script:UiFallbackLib').Value
        foreach ($f in (Get-TestFunctionText -Path $UiPs1Path -Name @('Build-UiJob'))) { . ([scriptblock]::Create($f)) }

        # An app folder with texts only: the job must work with the fallback library (no lib\ folder).
        $AppDir = Join-Path -Path $TestDrive -ChildPath 'app'
        $null = New-Item -ItemType Directory -Path (Join-Path -Path $AppDir -ChildPath 'i18n') -Force
        Copy-Item -Path $DePath, $EnPath -Destination (Join-Path -Path $AppDir -ChildPath 'i18n')
        $RunDir = Join-Path -Path $TestDrive -ChildPath 'run'
        $null = New-Item -ItemType Directory -Path $RunDir -Force

        $Runspace = [runspacefactory]::CreateRunspace()
        $Runspace.Open()

        function Build-TestJob {
            param([string]$Kind, [string]$DemoFailure = 'none', [bool]$Demo = $true, [hashtable]$Extra = @{}, [object]$Sync)
            $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
            if (-not $Sync) { $Sync = [hashtable]::Synchronized(@{ Cancel = $false; Server = $null; ModelEntry = $null }) }
            $params = @{
                Kind = $Kind; AppDir = $AppDir; RunFolder = $RunDir; Queue = $queue; Sync = $Sync; Demo = $Demo
                DemoFailure = $DemoFailure; DemoDelay = 0.01; FallbackLib = $FallbackLib; ReadOnly = $false; Language = 'en'
            }
            foreach ($k in $Extra.Keys) { $params[$k] = $Extra[$k] }
            $ps = Build-UiJob -Runspace $Runspace -Script $JobScript -Parameters $params
            return @{ PS = $ps; Queue = $queue; Sync = $Sync }
        }

        function Read-TestQueue {
            param($Queue)
            $items = New-Object System.Collections.ArrayList
            $item = $null
            while ($Queue.TryDequeue([ref]$item)) { $null = $items.Add($item) }
            return , $items.ToArray()
        }

        function Invoke-TestAgent {
            # Runs the agent job in the background and answers confirmations like the UI timer does.
            param([bool]$Answer = $true, [switch]$CancelEarly)
            $sync = [hashtable]::Synchronized(@{ Cancel = $false; Server = @{ BaseUrl = 'demo' }; ModelEntry = @{ tag = 'demo:2b' } })
            $job = Build-TestJob -Kind 'agent' -Sync $sync -Extra @{ Category = 'network'; UserText = '' }
            $handle = $job.PS.BeginInvoke()
            $events = New-Object System.Collections.ArrayList
            $deadline = (Get-Date).AddSeconds(30)
            $finished = $null
            while (-not $finished -and (Get-Date) -lt $deadline) {
                $item = $null
                while ($job.Queue.TryDequeue([ref]$item)) {
                    $null = $events.Add($item)
                    if ($CancelEarly -and $events.Count -eq 1) { $sync.Cancel = $true }
                    if ($item.Type -eq 'confirm') { $sync[('answer.' + $item.Id)] = $Answer }
                    if ($item.Type -eq 'finished' -or $item.Type -eq 'fatal') { $finished = $item }
                }
                Start-Sleep -Milliseconds 20
            }
            $null = $job.PS.EndInvoke($handle)
            $job.PS.Dispose()
            return @{ Events = $events.ToArray(); Final = $finished; Sync = $sync }
        }
    }

    AfterAll {
        if ($Runspace) { $Runspace.Dispose() }
    }

    It 'prepare: reports the three steps in order and ends with prepared' {
        $job = Build-TestJob -Kind 'prepare'
        $null = $job.PS.Invoke()
        $job.PS.Dispose()
        $events = Read-TestQueue -Queue $job.Queue
        $steps = @($events | Where-Object { $_.Type -eq 'prep-step' } | ForEach-Object { $_.Key + ':' + $_.State })
        ($steps -join ' ') | Should -Be 'step.hardware:running step.hardware:done step.model:running step.model:done step.start:running step.start:done'
        $events[-1].Type | Should -Be 'prepared'
        $events[-1].Model | Should -Be 'qwen3.5:2b-q4_K_M'
        ($events | Where-Object { $_.Key -eq 'step.model' -and $_.State -eq 'done' }).ReasonKey | Should -Be 'model.reason.cpu'
        $job.Sync.Server | Should -Not -BeNullOrEmpty
        $job.Sync.ModelEntry.tag | Should -Be 'qwen3.5:2b-q4_K_M'
    }

    It 'prepare: <DemoFailure> ends on the friendly page <Key> and leaves no server behind' -ForEach @(
        @{ DemoFailure = 'nomodel'; Key = 'error.no_model' }
        @{ DemoFailure = 'weak'; Key = 'error.computer_too_weak' }
        @{ DemoFailure = 'ollama'; Key = 'error.ollama_start' }
        @{ DemoFailure = 'slow'; Key = 'error.model_too_slow' }
        @{ DemoFailure = 'crash'; Key = 'error.unexpected' }
    ) {
        $job = Build-TestJob -Kind 'prepare' -DemoFailure $DemoFailure
        $null = $job.PS.Invoke()
        $job.PS.Dispose()
        $events = Read-TestQueue -Queue $job.Queue
        $events[-1].Type | Should -Be 'fatal'
        $events[-1].Key | Should -Be $Key
        $events[-2].State | Should -Be 'problem'
        $job.Sync.Server | Should -BeNullOrEmpty
        $De.Contains($Key + '.title') | Should -BeTrue
        [System.IO.File]::ReadAllText((Join-Path -Path $RunDir -ChildPath 'run.log')) | Should -Match 'Preparation failed'
    }

    It 'prepare (real Models.ps1, fake hardware and Ollama): a step-down tests and hands over the fallback with its own context' {
        $app2 = Join-Path -Path (Join-Path -Path $TestDrive -ChildPath 'PlugNHeal') -ChildPath 'app'
        $lib2 = Join-Path -Path $app2 -ChildPath 'lib'
        foreach ($d in @($lib2, (Join-Path -Path $app2 -ChildPath 'catalog'), (Join-Path -Path $app2 -ChildPath 'i18n'))) { $null = New-Item -ItemType Directory -Path $d -Force }
        Copy-Item -Path (Join-Path -Path (Join-Path -Path $Src -ChildPath 'lib') -ChildPath 'Common.ps1') -Destination $lib2
        Copy-Item -Path (Join-Path -Path (Join-Path -Path $Src -ChildPath 'lib') -ChildPath 'Models.ps1') -Destination $lib2
        Copy-Item -Path (Join-Path -Path (Join-Path -Path $Src -ChildPath 'catalog') -ChildPath 'models.json') -Destination (Join-Path -Path $app2 -ChildPath 'catalog')
        Copy-Item -Path $DePath, $EnPath -Destination (Join-Path -Path $app2 -ChildPath 'i18n')
        # 24 GB card: qwen3.8:27b on the GPU with 32k first; the fake fit test lets only the 4B pass.
        Set-Content -LiteralPath (Join-Path -Path $lib2 -ChildPath 'Hardware.ps1') -Value @'
function Get-PnhHardware {
    @{ Gpus = @(@{ Name = 'GPU'; Vendor = 'nvidia'; VramBytes = [uint64](24564 * 1MB); Integrated = $false; Driver = '1' })
       BestDedicatedVramBytes = [uint64](24564 * 1MB); RamBytes = [uint64](31.8 * 1GB); FreeRamBytes = [uint64](8GB) }
}
'@
        Set-Content -LiteralPath (Join-Path -Path $lib2 -ChildPath 'Ollama.ps1') -Value @'
function Get-PnhInstalledModels { 'qwen3.8:27b-q4_K_M'; 'qwen3.5:4b-q4_K_M' }
function Start-PnhOllama { param([object]$Paths, [int]$Port, [int]$ContextLength) $PnhUiSync['StartCtx'] = $ContextLength; @{ BaseUrl = 'http://fake'; ContextLength = $ContextLength } }
function Stop-PnhOllama { param([object]$Server) }
function Test-PnhModelFit {
    param([object]$Server, [string]$Model, [object]$ModelEntry, [switch]$UseGpu, [int]$NumCtx)
    $PnhUiSync['Fits'] = @($PnhUiSync['Fits']) + @(('{0}|{1}|{2}|{3}' -f $Model, $NumCtx, [bool]$UseGpu, $ModelEntry.ctx))
    @{ Ok = ($Model -eq 'qwen3.5:4b-q4_K_M'); OnGpuPercent = 100; TokensPerSecond = 40 }
}
'@
        foreach ($n in @('Diagnose', 'Toolbox', 'Agent')) { Set-Content -LiteralPath (Join-Path -Path $lib2 -ChildPath ($n + '.ps1')) -Value '# not needed for prepare' }
        $sync = [hashtable]::Synchronized(@{ Cancel = $false; Server = $null; ModelEntry = $null; Fits = @() })
        $job = Build-TestJob -Kind 'prepare' -Demo $false -Sync $sync -Extra @{ AppDir = $app2 }
        $null = $job.PS.Invoke()
        $job.PS.Dispose()
        $events = Read-TestQueue -Queue $job.Queue
        $events[-1].Type | Should -Be 'prepared'
        $events[-1].Model | Should -Be 'qwen3.5:4b-q4_K_M'
        $sync.StartCtx | Should -Be 32768
        @($sync.Fits) | Should -Be @('qwen3.8:27b-q4_K_M|32768|True|32768', 'qwen3.5:4b-q4_K_M|16384|True|16384')
        $sync.ModelEntry.tag | Should -Be 'qwen3.5:4b-q4_K_M'
        $sync.ModelEntry.ctx | Should -Be 16384 -Because 'the agent sends the num_ctx of the entry, not the 32k the server started with'
    }

    It 'prepare: a cancel request ends with cancelled, not with an error' {
        $job = Build-TestJob -Kind 'prepare'
        $job.Sync.Cancel = $true
        $null = $job.PS.Invoke()
        $job.PS.Dispose()
        $events = Read-TestQueue -Queue $job.Queue
        $events[-1].Type | Should -Be 'cancelled'
        @($events | Where-Object { $_.Type -eq 'fatal' }).Count | Should -Be 0
    }

    It 'agent: forwards the contract events, waits for the confirmation and returns the result' {
        $run = Invoke-TestAgent -Answer $true
        $run.Final.Type | Should -Be 'finished'
        $types = @($run.Events | ForEach-Object { $_.Type } | Sort-Object -Unique)
        foreach ($t in @('step-start', 'step-done', 'thinking', 'action', 'action-result', 'message', 'done', 'confirm')) { $types | Should -Contain $t }
        $confirm = $run.Events | Where-Object { $_.Type -eq 'confirm' } | Select-Object -First 1
        $confirm.Request.Risk | Should -Be 'medium'
        $confirm.Request.Title | Should -Not -BeNullOrEmpty
        $run.Final.Cancelled | Should -BeFalse
        $run.Final.Result.Solved | Should -BeTrue
        @($run.Final.Result.Actions).Count | Should -Be 2
        @($run.Final.Result.Actions)[1].Ok | Should -BeTrue
        @($run.Sync.Keys | Where-Object { $_ -like 'answer.*' }).Count | Should -Be 0 -Because 'answers are consumed'
    }

    It 'agent: a "No" in the dialog is passed to the action as declined' {
        $run = Invoke-TestAgent -Answer $false
        @($run.Final.Result.Actions)[1].Declined | Should -BeTrue
        @($run.Final.Result.Actions)[1].Ok | Should -BeFalse
    }

    It 'agent: cancelling stops at the next event and reports cancelled' {
        $run = Invoke-TestAgent -CancelEarly
        $run.Final.Type | Should -Be 'finished'
        $run.Final.Cancelled | Should -BeTrue
        $run.Final.Result | Should -BeNullOrEmpty
        @($run.Events | Where-Object { $_.Type -eq 'action' }).Count | Should -Be 0
    }

    It 'without its libraries (no demo) the job reports a damaged drive' {
        $job = Build-TestJob -Kind 'prepare' -Demo $false
        $null = $job.PS.Invoke()
        $job.PS.Dispose()
        $events = Read-TestQueue -Queue $job.Queue
        $events.Count | Should -Be 1
        $events[0].Type | Should -Be 'fatal'
        $events[0].Key | Should -Be 'error.damaged'
    }
}
