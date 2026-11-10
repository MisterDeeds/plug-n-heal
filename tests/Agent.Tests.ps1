# Pester 5 tests for src/lib/Agent.ps1 (contract: docs/ARCHITECTURE.md 5.7).
# All contract functions of the other libs are replaced by fakes; Invoke-PnhChat plays a scripted sequence of
# model answers. Runs on Windows PowerShell 5.1 and PowerShell 7.

BeforeAll {
    $repo = Split-Path -Parent $PSScriptRoot
    . (Join-Path (Join-Path (Join-Path $repo 'src') 'lib') 'Agent.ps1')

    # --- fakes for Common.ps1 ------------------------------------------------------------------------------
    function Write-PnhLog { param([string]$Message, [string]$Level = 'Info', $Data) $global:PnhFake.Log.Add(@{ Message = $Message; Level = $Level; Data = $Data }) }
    function Get-PnhLanguage { 'en' }
    function Get-PnhText { param([string]$Key, [object[]]$Arguments, [string]$Language) $Key }   # unknown -> built-in texts
    function Start-PnhHidden {
        param([string]$FilePath, [string]$ArgumentList, [int]$TimeoutSeconds)
        $global:PnhFake.ShellRuns.Add($ArgumentList)
        @{ ExitCode = 0; StdOut = 'Status: Running'; StdErr = ''; TimedOut = $false }
    }

    # --- fakes for Diagnose.ps1 ----------------------------------------------------------------------------
    function Invoke-PnhDiagnose {
        param([string[]]$Sections)
        $global:PnhFake.DiagnoseSections = $Sections
        $global:PnhFake.DiagnoseCalls++
        @{ Facts = $global:PnhFake.Facts; Flags = @($global:PnhFake.Flags); DurationMs = 5 }
    }
    function Invoke-PnhSuccessCheck {
        param([string]$Id)
        $global:PnhFake.CheckCalls++
        $on = [bool]$global:PnhFake.SpoolerRunning
        if ($global:PnhFake.CheckScript) { $on = [bool](& $global:PnhFake.CheckScript) }
        @{ Passed = $on; Details = @{ spooler = $on }; Summary = $(if ($on) { 'The print spooler runs.' } else { 'The print spooler is stopped.' }) }
    }

    # --- fakes for Toolbox.ps1 -----------------------------------------------------------------------------
    function Get-PnhActions { param([string]$Category) $global:PnhFake.Actions }
    function ConvertTo-PnhToolDefinitions {
        param($Actions, [string]$Language)
        foreach ($a in @($Actions)) {
            @{ type = 'function'; function = @{ name = ($a.id -replace '\.', '_'); description = $a.title.en; parameters = $a.params } }
        }
    }
    function Invoke-PnhAction {
        param([string]$Id, [hashtable]$Parameters, [string]$RunFolder, [scriptblock]$Confirm, [switch]$ForceConfirm)
        $global:PnhFake.ActionCalls.Add(@{ Id = $Id; Parameters = $Parameters; ForceConfirm = [bool]$ForceConfirm })
        $a = @($global:PnhFake.Actions | Where-Object { $_.id -eq $Id })[0]
        $base = @{ Id = $Id; Ok = $true; Verified = $true; Declined = $false; Output = ''; Error = $null; RolledBack = $false; NeedsReboot = $false }
        if ($a.confirm -or ($ForceConfirm -and $a.changes)) {   # same rule as Test-PnhConfirmRequired
            $yes = & $Confirm @{ Title = $a.title.en; Explain = 'test'; Risk = 'low'; Reboot = $false }
            if (-not $yes) { $base.Ok = $false; $base.Verified = $false; $base.Declined = $true; return $base }
        }
        switch ($Id) {
            'prn.restart_spooler' {
                if ($global:PnhFake.RepairWorks) { $global:PnhFake.SpoolerRunning = $true }
                $base.Verified = [bool]$global:PnhFake.RepairWorks
                $base.Output = 'Spooler restarted'
                if ($null -ne $global:PnhFake.FlagsAfterRestart) { $global:PnhFake.Flags = $global:PnhFake.FlagsAfterRestart }
                # The real toolbox sets Ok only when the action's own verify passed (Ok = Verified).
                if ($global:PnhFake.VerifyFails) { $base.Ok = $false; $base.Verified = $false; $base.Error = 'Verify failed: the service did not answer in time' }
            }
            'prn.set_online' { $global:PnhFake.PrinterOnline = $true; $base.Output = 'Printer set online' }
            'prn.status' { $base.Output = 'Spooler: Stopped' }
            'disk.clean_temp' { $base.Output = 'freed 1 GB' }
            'sec.detect_isolation' {
                if ($global:PnhFake.Isolated -is [bool]) { $base.Output = ('{"IsolationEvents":0,"Verdict":"X","IsolationSuspected":' + ([string]$global:PnhFake.Isolated).ToLowerInvariant() + '}') }
                else { $base.Output = 'Verdict : NOT_ONBOARDED' }
            }
        }
        return $base
    }
    function Test-PnhCommandDenied { param([string]$Command) return ($Command -match '(?i)\bformat\b|diskpart|bcdedit\s+/delete') }
    function New-PnhRestorePoint { param([string]$Description) $global:PnhFake.RestorePoints++; @{ Created = $false; Reason = 'test' } }

    # --- fakes for the toolbox files (categories.json, findings.json) --------------------------------------
    function Get-PnhAgentCategory {
        param([string]$Id)
        switch ($Id) {
            'printer' { [pscustomobject]@{ id = 'printer'; titleKey = 'cat.printer'; diagnose = @('printer', 'system'); success = 'check.printer'; actions = @('prn.*', 'sec.detect_isolation') } }
            'all' { [pscustomobject]@{ id = 'all'; titleKey = 'cat.all'; diagnose = @('system', 'printer', 'disk'); success = 'check.all'; actions = @('*') } }
            'other' { [pscustomobject]@{ id = 'other'; titleKey = 'cat.other'; diagnose = @('system'); success = 'check.other'; actions = @('prn.*', 'disk.*', 'sec.*') } }
        }
    }
    function Get-PnhAgentFindings {
        param([string]$Language)
        @{
            SPOOLER_STOPPED       = @{ Code = 'SPOOLER_STOPPED'; Meaning = 'The print spooler is stopped.'; Candidates = @('prn.restart_spooler'); Stop = ''; Blocks = @() }
            DISK_LOW              = @{ Code = 'DISK_LOW'; Meaning = 'Little free space.'; Candidates = @('disk.clean_temp'); Stop = ''; Blocks = @() }
            DISK_BAD              = @{ Code = 'DISK_BAD'; Meaning = 'A disk is failing.'; Candidates = @(); Stop = 'Back up your files first, I do not touch the disk.'; Blocks = @('disk.*', '@reboot') }
            MDE_ISOLATION_SUSPECT = @{ Code = 'MDE_ISOLATION_SUSPECT'; Meaning = 'Maybe isolated.'; Candidates = @('sec.detect_isolation'); Stop = 'Isolated by the company.'; Blocks = @('net.*') }
            MANAGED_DEVICE        = @{ Code = 'MANAGED_DEVICE'; Meaning = 'Company device.'; Candidates = @(); Stop = 'Managed by an IT department, ask them.'; Blocks = @('prn.*') }
            PRINTER_OFFLINE       = @{ Code = 'PRINTER_OFFLINE'; Meaning = 'The default printer is offline.'; Candidates = @('prn.set_online'); Stop = ''; Blocks = @() }
        }
    }

    # --- fake model ------------------------------------------------------------------------------------------
    function Invoke-PnhChat {
        param($Server, [string]$Model, [object[]]$Messages, [object[]]$Tools, [bool]$Think, [int]$NumCtx, [int]$TimeoutSeconds)
        $global:PnhFake.ChatCalls.Add(@{ Messages = @($Messages); Tools = @($Tools); Think = $Think; ThinkGiven = $PSBoundParameters.ContainsKey('Think'); NumCtx = $NumCtx; TimeoutSeconds = $TimeoutSeconds })
        if ($global:PnhFake.ChatMinutes) { $global:PnhFake.Now = $global:PnhFake.Now.AddMinutes($global:PnhFake.ChatMinutes) }
        if ($global:PnhFake.Script.Count -eq 0) { return @{ Content = ''; Thinking = ''; ToolCalls = @(); DurationMs = 1 } }
        return $global:PnhFake.Script.Dequeue()
    }
    function New-Call {
        param([string]$Name, $Arguments = @{}, [string]$Content = '')
        @{ Content = $Content; Thinking = ''; ToolCalls = @(@{ Id = 'call_1'; Name = $Name; Arguments = $Arguments }); DurationMs = 1 }
    }
    function New-Text { param([string]$Text) @{ Content = $Text; Thinking = ''; ToolCalls = @(); DurationMs = 1 } }
    function New-HttpError { @{ Content = ''; Thinking = ''; ToolCalls = @(); Error = 'HTTP 500: error parsing tool call'; ErrorKind = 'http' } }
    # The clock of the wall-clock limit: the fake model moves it forward by ChatMinutes per request.
    function Get-PnhAgentNow { if ($global:PnhFake -and $global:PnhFake.Now) { return $global:PnhFake.Now }; return [DateTime]::UtcNow }

    function Reset-Fake {
        param([string[]]$Flags = @('SPOOLER_STOPPED'))
        $global:PnhFake = @{
            Flags = $Flags; Facts = @{ printer = @{ Spooler = 'Stopped'; Printers = @('HP OfficeJet') } }
            SpoolerRunning = $false; RepairWorks = $true; Isolated = $false; PrinterOnline = $false
            CheckScript = $null; FlagsAfterRestart = $null; Now = $null; ChatMinutes = 0; CancelOnRound = 0; DiagnoseCalls = 0
            VerifyFails = $false; CancelOnAction = $false
            Script = (New-Object System.Collections.Queue)
            ChatCalls = (New-Object System.Collections.Generic.List[object])
            ActionCalls = (New-Object System.Collections.Generic.List[object])
            ShellRuns = (New-Object System.Collections.Generic.List[object])
            Events = (New-Object System.Collections.Generic.List[object])
            Log = (New-Object System.Collections.Generic.List[object])
            Confirms = (New-Object System.Collections.Generic.List[object])
            CheckCalls = 0; RestorePoints = 0; DiagnoseSections = $null
            Actions = @(
                [pscustomobject]@{ id = 'prn.restart_spooler'; title = @{ de = 'Druckwarteschlange neu starten'; en = 'Restart the print spooler' }; params = @{ type = 'object'; properties = @{}; required = @() }; changes = $true; confirm = $true }
                [pscustomobject]@{ id = 'prn.status'; title = @{ de = 'Druckerstatus ansehen'; en = 'Look at the printer status' }; params = @{ type = 'object'; properties = @{} }; changes = $false; confirm = $false }
                [pscustomobject]@{ id = 'disk.clean_temp'; title = @{ de = 'Temp leeren'; en = 'Empty temp folder' }; params = @{ type = 'object'; properties = @{ drive = @{ type = 'string'; pattern = '^[A-Z]$' }; days = @{ type = 'integer' } }; required = @('drive') }; changes = $true; confirm = $false }
                [pscustomobject]@{ id = 'sec.detect_isolation'; title = @{ de = 'Isolation pruefen'; en = 'Check for isolation' }; params = @{ type = 'object'; properties = @{} }; changes = $false; confirm = $false; stopWhen = @{ property = 'IsolationSuspected'; finding = 'MDE_ISOLATION_SUSPECT' } }
                [pscustomobject]@{ id = 'prn.set_online'; title = @{ de = 'Drucker online schalten'; en = 'Switch the printer online' }; params = @{ type = 'object'; properties = @{} }; changes = $true; confirm = $false }
            )
        }
        foreach ($s in $args) { $global:PnhFake.Script.Enqueue($s) }
    }
    function Add-Script { foreach ($s in $args) { $global:PnhFake.Script.Enqueue($s) } }

    function Invoke-TestAgent {
        param([hashtable]$Model = @{ tag = 'fake:1b'; think = $false; freeShell = $false; ctx = 4096 }, [bool]$Answer = $true,
            [int]$MaxRounds = 12, [int]$MaxMinutes = 30, [string]$Category = 'printer', [switch]$ReadOnly,
            [hashtable]$Server = @{ BaseUrl = 'http://fake' }, [string]$Language = 'en')
        $global:PnhFake.Answer = $Answer
        $folder = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $global:PnhFake.RunFolder = $folder
        Invoke-PnhAgent -Server $Server -ModelEntry $Model -Category $Category -UserText 'My printer does not print' `
            -RunFolder $folder -OnEvent {
                param($e)
                $global:PnhFake.Events.Add($e)
                if ($global:PnhFake.CancelOnRound -and $e.Type -eq 'thinking' -and $e.Round -ge $global:PnhFake.CancelOnRound) { throw 'PNH_CANCELLED' }
                if ($global:PnhFake.CancelOnAction -and $e.Type -eq 'action') { throw 'PNH_CANCELLED' }
            } `
            -Confirm { param($r) $global:PnhFake.Confirms.Add($r); $global:PnhFake.Answer } -MaxRounds $MaxRounds -MaxMinutes $MaxMinutes -Language $Language -ReadOnly:$ReadOnly
    }
    function Get-ToolMessages { param([int]$Request) , @($global:PnhFake.ChatCalls[$Request].Messages | Where-Object { $_.role -eq 'tool' }) }
    function Get-EventTypes { @($global:PnhFake.Events | ForEach-Object { $_.Type }) }
    function Get-AgentMessages { @($global:PnhFake.Events | Where-Object { $_.Type -eq 'message' -and $_.Source -eq 'agent' } | ForEach-Object { $_.Text }) }
    function Get-ToolNames { param([int]$Request) @($global:PnhFake.ChatCalls[$Request].Tools | ForEach-Object { $_.function.name }) }
}

AfterAll {
    Remove-Variable -Name PnhFake -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Invoke-PnhAgent loop' {
    It 'calls the right tool, runs the action, passes the check and finishes as Solved' {
        Reset-Fake
        Add-Script (New-Call 'prn_restart_spooler') (New-Call 'finish' @{ summary = 'I restarted the printer service. **Printing works again** 😀' })
        $r = Invoke-TestAgent
        $r.Solved | Should -BeTrue
        $r.StoppedReason | Should -Be 'solved'
        $r.Rounds | Should -Be 2
        (@($global:PnhFake.ActionCalls | ForEach-Object { $_.Id }) -join ',') | Should -Be 'prn.restart_spooler'
        ($global:PnhFake.DiagnoseSections -join ',') | Should -Be 'printer,system'
        $types = Get-EventTypes
        $types | Should -Contain 'action'
        $types | Should -Contain 'action-result'
        $types[-1] | Should -Be 'done'
        $tool = Get-ToolMessages 1
        $tool[0].tool_name | Should -Be 'prn_restart_spooler'
        $tool[0].content | Should -Match '"passed":true'
        $tool[0].content | Should -Match 'Call finish now'
        $r.Summary | Should -Match 'The problem is fixed'
        $r.Summary | Should -Match 'Restart the print spooler: worked'
        $r.Summary | Should -Match 'Printing works again'
        $r.Summary | Should -Not -Match '\*\*'
        $r.Summary | Should -Not -Match '😀'
        Test-Path (Join-Path $global:PnhFake.RunFolder 'summary.txt') | Should -BeTrue
        Test-Path (Join-Path $global:PnhFake.RunFolder 'diagnose.json') | Should -BeTrue
        @(Get-Content (Join-Path $global:PnhFake.RunFolder 'chat.jsonl')).Count | Should -Be 4
    }

    It 'offers only candidates of set flags, read-only diagnostics and the built-ins' {
        Reset-Fake
        Add-Script (New-Call 'finish' @{ summary = 'nothing' })
        $null = Invoke-TestAgent
        $names = @($global:PnhFake.ChatCalls[0].Tools | ForEach-Object { $_.function.name })
        ($names -join ',') | Should -Be 'prn_restart_spooler,prn_status,sec_detect_isolation,ask_user,finish'
        $global:PnhFake.ChatCalls[0].Messages[0].role | Should -Be 'system'
        $global:PnhFake.ChatCalls[0].Messages[1].content | Should -Match 'SPOOLER_STOPPED: The print spooler is stopped'
        $global:PnhFake.ChatCalls[0].Messages[1].content | Should -Match 'My printer does not print'
        $global:PnhFake.ChatCalls[0].ThinkGiven | Should -BeTrue
        $global:PnhFake.ChatCalls[0].Think | Should -BeFalse
    }

    It 'reports a declined action and does not claim success' {
        Reset-Fake
        Add-Script (New-Call 'prn_restart_spooler') (New-Call 'finish' @{ summary = 'Done, I fixed it.' })
        $r = Invoke-TestAgent -Answer $false
        $r.Solved | Should -BeFalse
        $r.StoppedReason | Should -Be 'finished'
        $global:PnhFake.Confirms.Count | Should -Be 1
        $r.Actions[0].Declined | Should -BeTrue
        (Get-ToolMessages 1)[0].content | Should -Match 'said no'
        $r.Summary | Should -Match 'not done, because you said no'
        $r.Summary | Should -Match 'guess \(not checked\): Done, I fixed it'
        $r.Summary | Should -Not -Match 'The problem is fixed'
        $r.Summary | Should -Not -Match 'I tried every repair' -Because 'the person refused the only repair'
        (Get-AgentMessages) | Should -Contain 'I keep going and check whether anything else could help.'
    }

    It 'is not Solved when the success check fails, even if the model says it fixed everything' {
        Reset-Fake
        $global:PnhFake.RepairWorks = $false
        Add-Script (New-Call 'prn_restart_spooler') (New-Call 'finish' @{ summary = 'I fixed everything, the printer works.' })
        $r = Invoke-TestAgent
        $r.Solved | Should -BeFalse
        $r.StoppedReason | Should -Be 'finished'
        $r.Check.Passed | Should -BeFalse
        (Get-ToolMessages 1)[0].content | Should -Match '"passed":false'
        $r.Summary | Should -Match 'could not completely fix'
        $r.Summary | Should -Not -Match 'The problem is fixed'
    }

    It 'does not run the same look twice without a change in between, and keeps going' {
        Reset-Fake
        Add-Script (New-Call 'prn_status') (New-Call 'prn_status') (New-Call 'prn_restart_spooler') (New-Call 'finish' @{ summary = 'x' })
        $r = Invoke-TestAgent
        $r.Solved | Should -BeTrue
        (@($global:PnhFake.ActionCalls | ForEach-Object { $_.Id }) -join ',') | Should -Be 'prn.status,prn.restart_spooler'
        $c = (Get-ToolMessages 2)[1].content
        $c | Should -Match 'Not run again: you already did this'
        $c | Should -Match 'Spooler: Stopped'
        $c | Should -Match 'Untried candidates: prn_restart_spooler'
    }

    It 'normalizes small-model arguments: "C:" for a drive letter, a number as string, wrong key case' {
        Reset-Fake -Flags @('DISK_LOW')
        Add-Script (New-Call 'disk.clean_temp' @{ Drive = 'C:'; days = '7' }) (New-Call 'finish' @{ summary = 'x' })
        $null = Invoke-TestAgent
        $p = $global:PnhFake.ActionCalls[0].Parameters
        $p.drive | Should -BeExactly 'C'
        $p.days | Should -Be 7
        $p.days.GetType().Name | Should -Be 'Int64'
    }

    It 'refuses arguments that do not fit and explains what is expected' {
        Reset-Fake -Flags @('DISK_LOW')
        Add-Script (New-Call 'disk_clean_temp' @{ days = 3 }) (New-Call 'finish' @{ summary = 'x' })
        $null = Invoke-TestAgent
        $global:PnhFake.ActionCalls.Count | Should -Be 0
        (Get-ToolMessages 1)[0].content | Should -Match "'drive' is missing"
    }

    It 'tells the model the valid names when it calls an unknown tool' {
        Reset-Fake
        Add-Script (New-Call 'fix_printer') (New-Call 'finish' @{ summary = 'x' })
        $null = Invoke-TestAgent
        $c = (Get-ToolMessages 1)[0].content
        $c | Should -Match 'There is no tool "fix_printer"'
        $c | Should -Match 'prn_restart_spooler'
    }

    It 'nudges a model that answers without a tool call; it then calls the candidate and the run is Solved' {
        Reset-Fake
        Add-Script (New-Text 'I think the printer is broken.') (New-Text '') (New-Call 'prn_restart_spooler') (New-Call 'finish' @{ summary = 'The printer service runs again.' })
        $r = Invoke-TestAgent
        $r.Solved | Should -BeTrue
        $r.StoppedReason | Should -Be 'solved'
        $r.Rounds | Should -Be 4
        foreach ($i in 1, 2) {
            $last = $global:PnhFake.ChatCalls[$i].Messages[-1]
            $last.role | Should -Be 'user'
            $last.content | Should -BeExactly 'The check still fails: The print spooler is stopped. Untried candidates: prn_restart_spooler. Call the most promising one now.'
        }
        $global:PnhFake.ChatCalls[1].Messages[-2].content | Should -Be 'I think the printer is broken.'
        (Get-AgentMessages) | Should -Contain 'I keep going. Next I try: Restart the print spooler'
        @($global:PnhFake.Log | Where-Object { $_.Message -eq 'Nudge' }).Count | Should -Be 2
        $r.Nudges | Should -Be 2
        $r.Summary | Should -Match 'Explanation: The printer service runs again'
    }

    It 'treats an HTTP error from Invoke-PnhChat as a turn without a tool call, not as a crash' {
        Reset-Fake
        Add-Script (New-HttpError) (New-Call 'prn_restart_spooler') (New-Call 'finish' @{ summary = 'ok' })
        $r = Invoke-TestAgent
        $r.Solved | Should -BeTrue
        $r.Rounds | Should -Be 3
    }

    It 'keeps going after invalid tool calls while candidates are left' {
        Reset-Fake
        Add-Script (New-Call 'a') (New-Call 'b') (New-Call 'c') (New-Call 'prn_restart_spooler') (New-Call 'finish' @{ summary = 'x' })
        $r = Invoke-TestAgent
        $r.Solved | Should -BeTrue
        $r.Rounds | Should -Be 5
        (Get-ToolMessages 1)[0].content | Should -Match 'Untried candidates: prn_restart_spooler'
    }

    It 'stops after three failed model requests in a row' {
        Reset-Fake
        Add-Script (New-HttpError) (New-HttpError) (New-HttpError) (New-Call 'prn_restart_spooler')
        $r = Invoke-TestAgent
        $r.StoppedReason | Should -Be 'errors'
        $global:PnhFake.ChatCalls.Count | Should -Be 3
        $global:PnhFake.ActionCalls.Count | Should -Be 0
    }

    It 'recovers a tool call that a small model wrote as text' {
        Reset-Fake
        Add-Script (New-Text '<tool_call>{"name": "prn_restart_spooler", "arguments": {}}</tool_call>') (New-Call 'finish' @{ summary = 'ok' })
        $r = Invoke-TestAgent
        $r.Solved | Should -BeTrue
        $global:PnhFake.ActionCalls[0].Id | Should -Be 'prn.restart_spooler'
    }

    It 'strips <think> blocks from text shown to the user' {
        Reset-Fake
        Add-Script (New-Call 'prn_status' @{} '<think>internal plan</think>Let me look at the printer.') (New-Call 'prn_restart_spooler') (New-Call 'finish' @{ summary = '</think>All checked.' })
        $r = Invoke-TestAgent
        $r.Rounds | Should -Be 3
        $msg = @($global:PnhFake.Events | Where-Object { $_.Type -eq 'message' -and $_.Source -eq 'model' })
        $msg[0].Text | Should -Be 'Let me look at the printer.'
        $r.Summary | Should -Match 'All checked\.'
        $r.Summary | Should -Not -Match 'think'
        $global:PnhFake.ChatCalls[1].Messages[2].content | Should -Not -Match 'internal plan'
    }

    It 'sends think:true for thinking models' {
        Reset-Fake
        Add-Script (New-Call 'finish' @{ summary = 'x' })
        $null = Invoke-TestAgent -Model @{ tag = 'big:27b'; think = $true; freeShell = $false; ctx = 32768 }
        $global:PnhFake.ChatCalls[0].Think | Should -BeTrue
        $global:PnhFake.ChatCalls[0].NumCtx | Should -Be 32768
    }

    It 'sends the num_ctx of the model entry, not the server default (a fallback keeps its own context)' {
        Reset-Fake
        Add-Script (New-Call 'finish' @{ summary = 'x' })
        $null = Invoke-TestAgent -Server @{ BaseUrl = 'http://fake'; ContextLength = 32768 } -Model @{ tag = 'mid:4b'; tier = 2; think = $false; freeShell = $false; ctx = 16384 }
        $global:PnhFake.ChatCalls[0].NumCtx | Should -Be 16384
        Reset-Fake
        Add-Script (New-Call 'finish' @{ summary = 'x' })
        $null = Invoke-TestAgent -Server @{ BaseUrl = 'http://fake'; ContextLength = 8192 } -Model @{ tag = 'adhoc:1b'; think = $false; freeShell = $false }
        $global:PnhFake.ChatCalls[0].NumCtx | Should -Be 8192 -Because 'without ctx in the entry the server default applies'
    }

    It 'stops at MaxRounds' {
        Reset-Fake
        Add-Script (New-Call 'prn_status') (New-Call 'ask_user' @{ question = 'Is the printer on?' }) (New-Call 'prn_status')
        $r = Invoke-TestAgent -MaxRounds 2
        $r.StoppedReason | Should -Be 'max-rounds'
        $r.Rounds | Should -Be 2
    }

    It 'asks the user a yes/no question through Confirm' {
        Reset-Fake
        Add-Script (New-Call 'ask_user' @{ question = 'Is the printer **switched on**?' }) (New-Call 'finish' @{ summary = 'x' })
        $null = Invoke-TestAgent -Answer $true
        $global:PnhFake.Confirms[0].Title | Should -Be 'Is the printer switched on?'
        (Get-ToolMessages 1)[0].content | Should -Match 'answered: yes'
    }

    It 'stops before asking the model when the isolation check is positive' {
        Reset-Fake -Flags @('MDE_ISOLATION_SUSPECT', 'SPOOLER_STOPPED')
        $global:PnhFake.Isolated = $true
        $r = Invoke-TestAgent
        $r.StoppedReason | Should -Be 'isolation'
        $r.Solved | Should -BeFalse
        $global:PnhFake.ChatCalls.Count | Should -Be 0
        $global:PnhFake.ActionCalls[0].Id | Should -Be 'sec.detect_isolation'
        $r.Summary | Should -Match 'IT department'
    }

    It 'continues when the isolation check is negative' {
        Reset-Fake -Flags @('MDE_ISOLATION_SUSPECT', 'SPOOLER_STOPPED')
        Add-Script (New-Call 'prn_restart_spooler') (New-Call 'finish' @{ summary = 'ok' })
        $r = Invoke-TestAgent
        $r.Solved | Should -BeTrue
    }

    It 'stops and explains when a stop finding blocks every repair for the problem' {
        Reset-Fake -Flags @('MANAGED_DEVICE', 'SPOOLER_STOPPED')
        $r = Invoke-TestAgent
        $r.StoppedReason | Should -Be 'stop-finding'
        $global:PnhFake.ChatCalls.Count | Should -Be 0
        $global:PnhFake.ActionCalls.Count | Should -Be 0
        $r.Summary | Should -Match 'Managed by an IT department'
    }

    It 'removes only the blocked repairs of a stop finding and tells the model why' {
        Reset-Fake -Flags @('DISK_BAD', 'DISK_LOW', 'SPOOLER_STOPPED')
        Add-Script (New-Call 'prn_restart_spooler') (New-Call 'finish' @{ summary = 'ok' })
        $r = Invoke-TestAgent
        $names = @($global:PnhFake.ChatCalls[0].Tools | ForEach-Object { $_.function.name })
        $names | Should -Not -Contain 'disk_clean_temp'
        $names | Should -Contain 'prn_restart_spooler'
        $global:PnhFake.ChatCalls[0].Messages[1].content | Should -Match 'Important, applies to every step: Back up your files first'
        $r.Solved | Should -BeTrue
        $r.Summary | Should -Match 'Note: Back up your files first'
    }

    It 'stops the loop when the model runs a probe whose stopWhen property is true' {
        Reset-Fake
        $global:PnhFake.Isolated = $true
        Add-Script (New-Call 'sec_detect_isolation') (New-Call 'prn_restart_spooler')
        $r = Invoke-TestAgent
        $r.StoppedReason | Should -Be 'isolation'
        $r.Solved | Should -BeFalse
        $global:PnhFake.ChatCalls.Count | Should -Be 1
        (Get-ToolMessages 1).Count | Should -Be 0
    }

    It 'keeps a stop finding in force when its probe gives no clear answer' {
        Reset-Fake -Flags @('MDE_ISOLATION_SUSPECT', 'SPOOLER_STOPPED')
        $global:PnhFake.Isolated = 'unknown'
        Add-Script (New-Call 'prn_restart_spooler') (New-Call 'finish' @{ summary = 'ok' })
        $r = Invoke-TestAgent
        $r.StoppedReason | Should -Be 'solved'
        $global:PnhFake.ChatCalls[0].Messages[1].content | Should -Match 'Isolated by the company'
    }

    It 'returns StoppedReason error for an unknown category and still writes the summary' {
        Reset-Fake
        $r = Invoke-TestAgent -Category 'nope'
        $r.StoppedReason | Should -Be 'error'
        $r.Solved | Should -BeFalse
        Get-EventTypes | Should -Contain 'error'
        Test-Path (Join-Path $global:PnhFake.RunFolder 'summary.txt') | Should -BeTrue
    }

    It 'skips a second change in the same answer (one change at a time)' {
        Reset-Fake -Flags @('SPOOLER_STOPPED', 'DISK_LOW')
        $global:PnhFake.RepairWorks = $false
        $two = @{ Content = ''; Thinking = ''; DurationMs = 1; ToolCalls = @(
                @{ Id = 'call_1'; Name = 'prn_restart_spooler'; Arguments = @{} },
                @{ Id = 'call_2'; Name = 'disk_clean_temp'; Arguments = @{ drive = 'C' } }) }
        Add-Script $two (New-Call 'finish' @{ summary = 'x' })
        $null = Invoke-TestAgent
        (@($global:PnhFake.ActionCalls | ForEach-Object { $_.Id }) -join ',') | Should -Be 'prn.restart_spooler'
        (Get-ToolMessages 1)[1].content | Should -Match 'only one change at a time'
    }
}

Describe 'Persistence: the harness keeps going until the check passes or nothing is left' {
    It 'refuses a premature finish twice and accepts the third one as not solved' {
        Reset-Fake
        Add-Script (New-Call 'finish' @{ summary = 'I cannot help.' }) (New-Call 'finish' @{ summary = 'Really, I cannot help.' }) (New-Call 'finish' @{ summary = 'Nothing more to do.' })
        $r = Invoke-TestAgent
        $r.Solved | Should -BeFalse
        $r.StoppedReason | Should -Be 'finished'
        $global:PnhFake.ChatCalls.Count | Should -Be 3
        $global:PnhFake.ActionCalls.Count | Should -Be 0
        foreach ($i in 1, 2) {
            (Get-ToolMessages $i)[-1].content | Should -BeExactly 'Do not finish yet. The check still fails: The print spooler is stopped. Untried candidates: prn_restart_spooler. Call the most promising one now.'
        }
        @(Get-AgentMessages | Where-Object { $_ -match 'I keep going' }).Count | Should -Be 2
        $r.Summary | Should -Match 'could not completely fix'
        $r.Summary | Should -Match 'guess \(not checked\): Nothing more to do'
    }

    It 'never shows the words of a refused finish, or words from before a repair, as the explanation' {
        Reset-Fake
        Add-Script (New-Call 'finish' @{ summary = 'I cannot fix the printer.' }) (New-Text 'Maybe the printer is broken.') (New-Call 'prn_restart_spooler') (New-Text '')
        $r = Invoke-TestAgent
        $r.Solved | Should -BeTrue
        $r.Rounds | Should -Be 4
        $r.Summary | Should -Not -Match 'cannot fix'
        $r.Summary | Should -Not -Match 'Maybe the printer is broken'
        $r.Summary | Should -Not -Match 'Explanation'
        $r.Summary | Should -Match 'Restart the print spooler: worked'
    }

    It 'notes in the log when the model generated tokens but nothing arrived (a tool call the server dropped)' {
        Reset-Fake
        Add-Script @{ Content = ''; Thinking = ''; ToolCalls = @(); DurationMs = 1; OutputTokens = 74 } (New-Call 'prn_restart_spooler') (New-Call 'finish' @{ summary = 'ok' })
        $r = Invoke-TestAgent
        $r.Solved | Should -BeTrue
        $nudge = @($global:PnhFake.Log | Where-Object { $_.Message -eq 'Nudge' })[0]
        $nudge.Data.why | Should -Be 'empty answer (74 tokens generated, a tool call was probably lost)'
    }

    It 'accepts finish at once when every candidate was tried' {
        Reset-Fake
        $global:PnhFake.RepairWorks = $false
        Add-Script (New-Call 'prn_restart_spooler') (New-Call 'finish' @{ summary = 'The service does not start.' })
        $r = Invoke-TestAgent
        $r.StoppedReason | Should -Be 'finished'
        $global:PnhFake.ChatCalls.Count | Should -Be 2
        (Get-ToolMessages 1)[0].content | Should -Match 'Every candidate was tried'
        $r.Summary | Should -Match 'could not completely fix'
        $r.Summary | Should -Match 'Restart the print spooler: done, effect not confirmed'
        $r.Summary | Should -Match 'Check: The print spooler is stopped'
        $r.Summary | Should -Match 'I tried every repair that fits'
        $r.Summary | Should -Match 'guess \(not checked\): The service does not start'
        $r.Summary | Should -Match 'Show the report to someone who knows computers'
    }

    It 'does not offer or run a failed repair again and points to the next candidate' {
        Reset-Fake -Flags @('SPOOLER_STOPPED', 'PRINTER_OFFLINE')
        $global:PnhFake.RepairWorks = $false
        Add-Script (New-Call 'prn_restart_spooler') (New-Call 'prn_restart_spooler') (New-Call 'finish' @{ summary = 'x' }) (New-Call 'finish' @{ summary = 'x' }) (New-Call 'finish' @{ summary = 'x' })
        $r = Invoke-TestAgent
        (@($global:PnhFake.ActionCalls | ForEach-Object { $_.Id }) -join ',') | Should -Be 'prn.restart_spooler'
        Get-ToolNames 0 | Should -Contain 'prn_restart_spooler'
        Get-ToolNames 1 | Should -Not -Contain 'prn_restart_spooler'
        Get-ToolNames 1 | Should -Contain 'prn_set_online'
        (Get-ToolMessages 1)[0].content | Should -Match 'Success check: Failed\. The print spooler is stopped\. Untried candidates: prn_set_online\.'
        $c = (Get-ToolMessages 2)[1].content
        $c | Should -Match 'Not run again: prn_restart_spooler was already tried'
        $c | Should -Match 'Untried candidates: prn_set_online'
        (Get-ToolMessages 3)[-1].content | Should -Match 'Untried candidates: prn_set_online\.'
        $r.StoppedReason | Should -Be 'finished'
        $global:PnhFake.ChatCalls.Count | Should -Be 5
        $r.Tried.Count | Should -Be 1
        $r.Tried[0].Name | Should -Be 'prn_restart_spooler'
        $r.Tried[0].Outcome | Should -Match 'no effect'
        $r.Summary | Should -Not -Match 'I tried every repair' -Because 'one candidate was never run'
    }

    It 'tells the person what comes next after a repair that did not fix the problem' {
        Reset-Fake -Flags @('SPOOLER_STOPPED', 'PRINTER_OFFLINE')
        $global:PnhFake.CheckScript = { $global:PnhFake.SpoolerRunning -and $global:PnhFake.PrinterOnline }
        Add-Script (New-Call 'prn_restart_spooler') (New-Call 'prn_set_online') (New-Call 'finish' @{ summary = 'Both fixed.' })
        $r = Invoke-TestAgent
        $r.Solved | Should -BeTrue
        $r.Nudges | Should -Be 0
        $agent = @($global:PnhFake.Events | Where-Object { $_.Type -eq 'message' -and $_.Source -eq 'agent' } | ForEach-Object { $_.Text })
        ($agent -join ' | ') | Should -Be 'It does not work yet. I am examining the computer again. | I keep going. Next I try: Switch the printer online'
        $types = Get-EventTypes
        # order on the screen: the result of the first repair, the agent's sentence, then the next round
        $iResult = [array]::IndexOf($types, 'action-result')
        $iMessage = [array]::LastIndexOf($types, 'message')
        $iResult | Should -BeLessThan $iMessage
        $types[$iMessage + 1] | Should -Be 'thinking'
    }

    It 'runs the success check after every changing action, also one that reports a failure, and judges by that check' {
        Reset-Fake
        $global:PnhFake.VerifyFails = $true       # the service came up, but the action's own verify gave up too early
        Add-Script (New-Call 'prn_restart_spooler') (New-Call 'finish' @{ summary = 'The print service runs again.' })
        $r = Invoke-TestAgent
        $c = (Get-ToolMessages 1)[0].content
        $c | Should -Match '"ok":false'
        $c | Should -Match '"passed":true'
        $c | Should -Match 'Success check: Passed'
        $r.Solved | Should -BeTrue -Because 'the script decides, and the check after the change passed'
        $r.StoppedReason | Should -Be 'solved'
    }

    It 'a failed repair is checked, counts as the one change of that answer and is not offered again' {
        Reset-Fake -Flags @('SPOOLER_STOPPED', 'DISK_LOW')
        $global:PnhFake.VerifyFails = $true
        $global:PnhFake.RepairWorks = $false
        $two = @{ Content = ''; Thinking = ''; DurationMs = 1; ToolCalls = @(
                @{ Id = 'call_1'; Name = 'prn_restart_spooler'; Arguments = @{} },
                @{ Id = 'call_2'; Name = 'disk_clean_temp'; Arguments = @{ drive = 'C' } }) }
        Add-Script $two (New-Call 'disk_clean_temp' @{ drive = 'C' }) (New-Call 'finish' @{ summary = 'x' })
        $checksBefore = 1    # the check at the start
        $r = Invoke-TestAgent
        $t = Get-ToolMessages 1
        $t[0].content | Should -Match '"passed":false'
        $t[0].content | Should -Match 'Success check: Failed\. The print spooler is stopped\. Untried candidates: disk_clean_temp\.'
        $t[1].content | Should -Match 'only one change at a time'
        Get-ToolNames 1 | Should -Not -Contain 'prn_restart_spooler'
        (@($global:PnhFake.ActionCalls | ForEach-Object { $_.Id }) -join ',') | Should -Be 'prn.restart_spooler,disk.clean_temp'
        $global:PnhFake.CheckCalls | Should -Be ($checksBefore + 2) -Because 'one check after each of the two changes, none stale at the end'
        $r.Tried[0].Outcome | Should -Match '^failed: Verify failed'
        $r.Solved | Should -BeFalse
    }

    It 'runs the diagnosis again when a verified repair did not pass the check; the new finding brings a new candidate' {
        Reset-Fake -Flags @('SPOOLER_STOPPED')
        $global:PnhFake.CheckScript = { $global:PnhFake.SpoolerRunning -and $global:PnhFake.PrinterOnline }
        $global:PnhFake.FlagsAfterRestart = @('PRINTER_OFFLINE')
        Add-Script (New-Call 'prn_restart_spooler') (New-Call 'prn_set_online') (New-Call 'finish' @{ summary = 'Both fixed.' })
        $r = Invoke-TestAgent
        $r.Solved | Should -BeTrue
        $r.StoppedReason | Should -Be 'solved'
        $r.Rediagnoses | Should -Be 1
        (@($r.Tried | ForEach-Object { $_.Name }) -join ',') | Should -Be 'prn_restart_spooler,prn_set_online'
        $global:PnhFake.DiagnoseCalls | Should -Be 2
        ($global:PnhFake.DiagnoseSections -join ',') | Should -Be 'printer,system'
        Get-ToolNames 0 | Should -Not -Contain 'prn_set_online'
        Get-ToolNames 1 | Should -Contain 'prn_set_online'
        $c = (Get-ToolMessages 1)[0].content
        $c | Should -Match 'New findings: PRINTER_OFFLINE: The default printer is offline'
        $c | Should -Match 'No longer found: SPOOLER_STOPPED'
        $c | Should -Match 'Untried candidates: prn_set_online'
        (Get-AgentMessages) | Should -Contain 'It does not work yet. I am examining the computer again.'
        $r.Summary | Should -Match 'Restart the print spooler: worked'
        $r.Summary | Should -Match 'Switch the printer online: worked'
    }

    It 'measures a stop finding that shows up in the diagnosis re-run: isolation stops the run at once' {
        Reset-Fake
        $global:PnhFake.CheckScript = { $false }
        $global:PnhFake.FlagsAfterRestart = @('SPOOLER_STOPPED', 'MDE_ISOLATION_SUSPECT', 'PRINTER_OFFLINE')
        $global:PnhFake.Isolated = $true
        Add-Script (New-Call 'prn_restart_spooler') (New-Call 'prn_set_online')
        $r = Invoke-TestAgent
        $r.StoppedReason | Should -Be 'isolation'
        $r.Solved | Should -BeFalse
        (@($global:PnhFake.ActionCalls | ForEach-Object { $_.Id }) -join ',') | Should -Be 'prn.restart_spooler,sec.detect_isolation'
        $global:PnhFake.ChatCalls.Count | Should -Be 1
        $r.Summary | Should -Match 'IT department'
        $r.Summary | Should -Match 'Restart the print spooler: worked'
    }

    It 'puts a new stop finding of the diagnosis re-run in force: its repairs are gone and the model is told why' {
        Reset-Fake
        $global:PnhFake.CheckScript = { $false }
        $global:PnhFake.FlagsAfterRestart = @('MANAGED_DEVICE', 'PRINTER_OFFLINE')
        Add-Script (New-Call 'prn_restart_spooler') (New-Call 'prn_set_online') (New-Call 'finish' @{ summary = 'Ask your IT department.' })
        $r = Invoke-TestAgent
        (@($global:PnhFake.ActionCalls | ForEach-Object { $_.Id }) -join ',') | Should -Be 'prn.restart_spooler' -Because 'MANAGED_DEVICE blocks prn.*'
        Get-ToolNames 1 | Should -Not -Contain 'prn_set_online'
        (Get-ToolMessages 1)[0].content | Should -Match 'Important, applies to every step: Managed by an IT department'
        $r.StoppedReason | Should -Be 'finished'
        $global:PnhFake.ChatCalls.Count | Should -Be 3 -Because 'with a stop finding in force a finish is accepted at once'
        $r.Summary | Should -Match 'Note: Managed by an IT department'
    }

    It 'ends with exhausted when every candidate was tried and two turns bring nothing new' {
        Reset-Fake
        $global:PnhFake.RepairWorks = $false
        Add-Script (New-Call 'prn_restart_spooler') (New-Text 'Hmm.') (New-Text 'I do not know.')
        $r = Invoke-TestAgent
        $r.StoppedReason | Should -Be 'exhausted'
        $global:PnhFake.ChatCalls.Count | Should -Be 3
        $global:PnhFake.ChatCalls[2].Messages[-1].content | Should -Match 'Every candidate was tried'
        $r.Summary | Should -Match 'I tried every repair that fits'
    }

    It 'stops at the wall-clock limit and keeps each request inside it' {
        Reset-Fake
        $global:PnhFake.Now = [datetime]'2026-01-01T08:00:00'
        $global:PnhFake.ChatMinutes = 4
        Add-Script (New-Text 'a') (New-Text 'b') (New-Text 'c') (New-Text 'd')
        $r = Invoke-TestAgent -MaxMinutes 10
        $r.StoppedReason | Should -Be 'time-limit'
        $r.Rounds | Should -Be 3
        $global:PnhFake.ChatCalls[0].TimeoutSeconds | Should -Be 600
        $global:PnhFake.ChatCalls[2].TimeoutSeconds | Should -Be 120
        $r.Summary | Should -Match 'I stopped after 10 minutes'
    }

    It 'compacts a long conversation: system prompt, facts and a summary of what was tried' {
        Reset-Fake -Flags @('SPOOLER_STOPPED', 'PRINTER_OFFLINE')
        $global:PnhFake.RepairWorks = $false
        Add-Script (New-Call 'prn_restart_spooler') (New-Call 'prn_set_online') (New-Call 'finish' @{ summary = 'x' })
        $r = Invoke-TestAgent -Model @{ tag = 'tiny:1b'; think = $false; freeShell = $false; ctx = 1000 }
        $r.Compactions | Should -BeGreaterThan 0
        $m = $global:PnhFake.ChatCalls[1].Messages
        $m.Count | Should -Be 3
        $m[0].role | Should -Be 'system'
        $m[1].content | Should -Match 'HP OfficeJet'
        $m[1].content | Should -Match 'SPOOLER_STOPPED: The print spooler is stopped'
        $m[2].role | Should -Be 'user'
        $m[2].content | Should -Match 'Summary of the work so far'
        $m[2].content | Should -Match 'Tried: prn_restart_spooler \{\} -> ran, but its own check says it had no effect'
        $m[2].content | Should -Match 'Success check now: Failed\. The print spooler is stopped'
        $m[2].content | Should -Match 'Untried candidates: prn_set_online'
        @($global:PnhFake.Log | Where-Object { $_.Message -eq 'Conversation compacted' }).Count | Should -BeGreaterThan 0
        (Get-Content -Raw (Join-Path $global:PnhFake.RunFolder 'chat.jsonl')) | Should -Match '"type":"compaction"'
    }

    It 'does not compact a conversation that fits' {
        Reset-Fake
        Add-Script (New-Call 'prn_status') (New-Call 'prn_restart_spooler') (New-Call 'finish' @{ summary = 'x' })
        $null = Invoke-TestAgent -Model @{ tag = 'big:27b'; think = $false; freeShell = $false; ctx = 32768 }
        $global:PnhFake.ChatCalls[2].Messages.Count | Should -Be 6
        @($global:PnhFake.Log | Where-Object { $_.Message -eq 'Conversation compacted' }).Count | Should -Be 0
    }

    It 'stops when the person cancels' {
        Reset-Fake
        $global:PnhFake.CancelOnRound = 2
        Add-Script (New-Text 'thinking about it') (New-Call 'prn_restart_spooler')
        $r = Invoke-TestAgent
        $r.StoppedReason | Should -Be 'cancelled'
        $global:PnhFake.ChatCalls.Count | Should -Be 1
        $global:PnhFake.ActionCalls.Count | Should -Be 0
        $r.Summary | Should -Match 'You stopped the help'
    }

    It 'starts nothing any more when the cancel is noticed right before an action' {
        Reset-Fake
        $global:PnhFake.CancelOnAction = $true
        Add-Script (New-Call 'prn_restart_spooler') (New-Call 'finish' @{ summary = 'x' })
        $r = Invoke-TestAgent
        $r.StoppedReason | Should -Be 'cancelled'
        $global:PnhFake.ActionCalls.Count | Should -Be 0 -Because 'the repair must not run after the person cancelled'
        $global:PnhFake.Confirms.Count | Should -Be 0
        $global:PnhFake.ChatCalls.Count | Should -Be 1
        $r.Solved | Should -BeFalse
    }

    It 'gives the model a task that fits when there is no candidate repair' {
        Reset-Fake -Flags @()
        Add-Script (New-Call 'prn_status') (New-Call 'finish' @{ summary = 'The print service is stopped. Someone must look at it.' })
        $r = Invoke-TestAgent
        $u = $global:PnhFake.ChatCalls[0].Messages[1].content
        $u | Should -Match 'Candidate repairs: none\.'
        $u | Should -Match 'Task: there is no tested repair for this'
        $u | Should -Not -Match 'call its most promising candidate now'
        (Get-ToolMessages 1)[0].content | Should -Match 'Every candidate was tried'
        $r.StoppedReason | Should -Be 'finished'
        $r.Summary | Should -Match 'I did not change anything'
        $r.Summary | Should -Not -Match 'I tried every repair'
    }

    It 'read-only: a text answer is nudged once, the second one ends the run' {
        Reset-Fake
        Add-Script (New-Text 'Restarting the spooler would help.') (New-Text 'That is all.')
        $r = Invoke-TestAgent -ReadOnly
        $r.StoppedReason | Should -Be 'finished'
        $global:PnhFake.ChatCalls.Count | Should -Be 2
        $global:PnhFake.ChatCalls[1].Messages[-1].content | Should -Match 'When you have looked enough, call finish'
        $global:PnhFake.ActionCalls.Count | Should -Be 0
        (Get-AgentMessages) | Should -Contain 'I keep going and check whether anything else could help.' -Because 'every nudge tells the person that the work goes on'
        (Get-AgentMessages | Where-Object { $_ -match 'Next I try' }) | Should -BeNullOrEmpty -Because 'nothing is repaired in read-only mode'
    }
}

Describe 'The English system prompt' {
    It 'is one English file with a {LANGUAGE} placeholder, short, and the only file in the prompts folder' {
        $dir = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'src') 'prompts'
        $text = [System.IO.File]::ReadAllText((Join-Path $dir 'system.md'), [System.Text.Encoding]::UTF8)
        $text | Should -Match '\{LANGUAGE\}'
        $text | Should -Match 'repair agent running ON this'
        @($text -split '\s+' | Where-Object { $_ }).Count | Should -BeLessOrEqual 450
        (@(Get-ChildItem -LiteralPath $dir -File | ForEach-Object { $_.Name }) -join ',') | Should -Be 'system.md' -Because 'there is one prompt for every language'
        [regex]::IsMatch($text, '[^\x00-\x7F]') | Should -BeFalse -Because 'the prompt is plain English ASCII'
    }

    It 'has a text in de.json and en.json for everything the agent says to the person' {
        $i18n = Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'src') 'i18n'
        $table = Get-PnhAgentTextTable
        foreach ($lang in 'de', 'en') {
            $json = [System.IO.File]::ReadAllText((Join-Path $i18n ($lang + '.json')), [System.Text.Encoding]::UTF8) | ConvertFrom-Json
            foreach ($key in @($table.Keys | Where-Object { $_ -notmatch '^(model|tool)\.' })) {
                $p = $json.PSObject.Properties[$key]
                ($null -ne $p) | Should -BeTrue -Because ('{0}.json needs the key {1}' -f $lang, $key)
                [string]$p.Value | Should -BeExactly $table[$key][$lang] -Because ('the built-in fallback of {0} ({1}) must say the same' -f $key, $lang)
            }
        }
        foreach ($key in 'agent.keepgoing', 'agent.keepgoing.last', 'agent.rediagnose', 'agent.summary.exhausted', 'agent.summary.timelimit', 'agent.summary.cancelled') {
            $table.ContainsKey($key) | Should -BeTrue -Because $key
        }
        # What goes to the model is English only.
        foreach ($key in @($table.Keys | Where-Object { $_ -match '^(model|tool)\.' })) { (@($table[$key].Keys) -join ',') | Should -Be 'en' -Because $key }
    }

    It 'fills the placeholder with the person''s language' {
        $de = Get-PnhAgentSystemPrompt -Language 'de'
        $de | Should -Not -Match '\{LANGUAGE\}'
        $de | Should -Match 'in German \(address the person formally with "Sie"\)'
        Get-PnhAgentSystemPrompt -Language 'en' | Should -Match 'in English:'
    }

    It 'talks English to the model also for a German run; texts for the person stay German' {
        Reset-Fake
        Add-Script (New-Text 'Der Drucker ist kaputt.') (New-Call 'prn_restart_spooler') (New-Call 'finish' @{ summary = 'Der Druckdienst laeuft wieder.' })
        $r = Invoke-TestAgent -Language 'de'
        $r.Solved | Should -BeTrue
        $first = $global:PnhFake.ChatCalls[0]
        $first.Messages[0].content | Should -Match 'in German'
        $first.Messages[1].content | Should -Match 'Task: fix the problem'
        $first.Messages[1].content | Should -Match 'Candidate repairs, most promising first: prn_restart_spooler'
        $finish = @($first.Tools | Where-Object { $_.function.name -eq 'finish' })[0]
        $finish.function.parameters.properties.summary.description | Should -Match 'in German'
        $global:PnhFake.ChatCalls[1].Messages[-1].content | Should -Match '^The check still fails'
        (Get-AgentMessages) | Should -Contain 'Ich mache weiter. Als Nächstes versuche ich: Druckwarteschlange neu starten'
        $r.Summary | Should -Match 'Geschafft'
    }
}

Describe 'Small models ask before every change (confirmAllChanges, tier 1)' {
    It '<Case>: a change without its own confirmation is asked first' -ForEach @(
        @{ Case = 'tier 1'; M = @{ tag = 'small:2b'; tier = 1; think = $false; freeShell = $false; ctx = 16384 } }
        @{ Case = 'confirmAllChanges = true'; M = @{ tag = 'mid:4b'; tier = 2; confirmAllChanges = $true; think = $false; freeShell = $false; ctx = 16384 } }
    ) {
        Reset-Fake -Flags @('DISK_LOW')
        Add-Script (New-Call 'disk_clean_temp' @{ drive = 'C' }) (New-Call 'finish' @{ summary = 'x' })
        $r = Invoke-TestAgent -Model $M
        $global:PnhFake.ActionCalls[0].Id | Should -Be 'disk.clean_temp'
        $global:PnhFake.ActionCalls[0].ForceConfirm | Should -BeTrue
        $global:PnhFake.Confirms.Count | Should -Be 1
        $r.Actions[0].Declined | Should -BeFalse
    }

    It 'a "No" leaves the change undone' {
        Reset-Fake -Flags @('DISK_LOW')
        Add-Script (New-Call 'disk_clean_temp' @{ drive = 'C' }) (New-Call 'finish' @{ summary = 'x' })
        $r = Invoke-TestAgent -Model @{ tag = 'small:2b'; tier = 1; think = $false; freeShell = $false; ctx = 16384 } -Answer $false
        $global:PnhFake.Confirms.Count | Should -Be 1
        $r.Actions[0].Declined | Should -BeTrue
        (Get-ToolMessages 1)[0].content | Should -Match 'said no'
    }

    It 'larger models keep the action''s own rule (a low-risk change is not asked)' {
        Reset-Fake -Flags @('DISK_LOW')
        Add-Script (New-Call 'disk_clean_temp' @{ drive = 'C' }) (New-Call 'finish' @{ summary = 'x' })
        $null = Invoke-TestAgent -Model @{ tag = 'mid:4b'; tier = 2; think = $false; freeShell = $false; ctx = 16384 }
        $global:PnhFake.ActionCalls[0].ForceConfirm | Should -BeFalse
        $global:PnhFake.Confirms.Count | Should -Be 0
    }

    It 'the real catalogue marks every tier-1 model with confirmAllChanges' {
        $catalogPath = Join-Path (Join-Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'src') 'catalog') 'models.json'
        $doc = [System.IO.File]::ReadAllText($catalogPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
        $tier1 = @($doc.models | Where-Object { $_.tier -eq 1 })
        $tier1.Count | Should -BeGreaterThan 0
        foreach ($m in $tier1) { $m.confirmAllChanges | Should -BeTrue -Because $m.id }
    }
}

Describe 'Read-only mode and the categories all/other' {
    It 'read-only: skips changes without asking, keeps looking, and lists what would help' {
        Reset-Fake
        Add-Script (New-Call 'prn_status') (New-Call 'prn_restart_spooler') (New-Call 'finish' @{ summary = 'Restarting the print service would help.' })
        $r = Invoke-TestAgent -ReadOnly
        $global:PnhFake.Confirms.Count | Should -Be 0
        (@($global:PnhFake.ActionCalls | ForEach-Object { $_.Id }) -join ',') | Should -Be 'prn.status'
        $r.Solved | Should -BeFalse
        $r.ReadOnly | Should -BeTrue
        ($r.WouldHelp -join ',') | Should -Be 'Restart the print spooler'
        $r.Actions[-1].Skipped | Should -BeTrue
        @($global:PnhFake.Events | Where-Object { $_.Type -eq 'message' -and $_.Text -match 'no permission to repair: Restart the print spooler' }).Count | Should -Be 1
        @($global:PnhFake.ChatCalls[0].Tools | ForEach-Object { $_.function.name }) | Should -Not -Contain 'ask_user'
        $global:PnhFake.ChatCalls[0].Messages[1].content | Should -Match 'Read-only mode'
        $global:PnhFake.ChatCalls[0].Messages[1].content | Should -Match 'Task: find out what would help'
        $global:PnhFake.ChatCalls[0].Messages[1].content | Should -Not -Match 'Task: fix the problem'
        (Get-ToolMessages 2)[1].content | Should -Match 'Not done, read-only mode'
        $r.Summary | Should -Match 'Without your permission I could only look'
        $r.Summary | Should -Match "This would probably help:`n- Restart the print spooler"
        (Get-Content -Raw (Join-Path $global:PnhFake.RunFolder 'summary.txt')) | Should -Match 'had no permission to repair'
    }

    It 'read-only: lists the offered repairs when the model chose none' {
        Reset-Fake
        Add-Script (New-Call 'finish' @{ summary = 'x' })
        $r = Invoke-TestAgent -ReadOnly
        $r.Summary | Should -Match "This would probably help:`n- Restart the print spooler"
    }

    It 'read-only: a changing free command is skipped, not confirmed' {
        Reset-Fake
        Add-Script (New-Call 'run_powershell' @{ command = 'Restart-Service -Name Spooler'; why = 'Restart the printer service' }) (New-Call 'finish' @{ summary = 'x' })
        $r = Invoke-TestAgent -Model @{ tag = 'big:27b'; think = $false; freeShell = $true; ctx = 32768 } -ReadOnly
        $global:PnhFake.Confirms.Count | Should -Be 0
        $global:PnhFake.ShellRuns.Count | Should -Be 0
        ($r.WouldHelp -join ',') | Should -Be 'Restart the printer service'
    }

    It 'all: full diagnosis, findings ordered by importance, only candidates as tools' {
        Reset-Fake -Flags @('SPOOLER_STOPPED', 'DISK_LOW', 'DISK_BAD')
        Add-Script (New-Call 'finish' @{ summary = 'x' })
        $null = Invoke-TestAgent -Category 'all'
        $global:PnhFake.DiagnoseSections | Should -BeNullOrEmpty
        $u = $global:PnhFake.ChatCalls[0].Messages[1].content
        $u.IndexOf('DISK_BAD') | Should -BeLessThan $u.IndexOf('SPOOLER_STOPPED')
        $u | Should -Match 'Work through the findings in order'
        (@($global:PnhFake.ChatCalls[0].Tools | ForEach-Object { $_.function.name }) -join ',') | Should -Be 'prn_restart_spooler,ask_user,finish'
    }

    It 'other: full diagnosis, the user''s words, only candidates of the findings, no free PowerShell' {
        Reset-Fake -Flags @('SPOOLER_STOPPED')
        Add-Script (New-Call 'finish' @{ summary = 'x' })
        $null = Invoke-TestAgent -Category 'other' -Model @{ tag = 'big:27b'; think = $false; freeShell = $true; ctx = 32768 }
        $global:PnhFake.DiagnoseSections | Should -BeNullOrEmpty
        $global:PnhFake.ChatCalls[0].Messages[1].content | Should -Match 'My printer does not print'
        (@($global:PnhFake.ChatCalls[0].Tools | ForEach-Object { $_.function.name }) -join ',') | Should -Be 'prn_restart_spooler,ask_user,finish'
    }

    It 'gives small models (tier 1) at most 12 action tools' {
        Reset-Fake
        $many = @(1..20 | ForEach-Object { [pscustomobject]@{ id = ('prn.look{0}' -f $_); title = @{ de = 'x'; en = 'x' }; params = @{ type = 'object'; properties = @{} }; changes = $false; confirm = $false } })
        $global:PnhFake.Actions = @($global:PnhFake.Actions) + $many
        Add-Script (New-Call 'finish' @{ summary = 'x' })
        $null = Invoke-TestAgent -Model @{ tag = 'small:2b'; tier = 1; think = $false; freeShell = $false; ctx = 16384 }
        @($global:PnhFake.ChatCalls[0].Tools).Count | Should -Be 14
    }
}

Describe 'run_powershell for freeShell models' {
    BeforeAll {
        $script:BigModel = @{ tag = 'big:27b'; think = $false; freeShell = $true; ctx = 32768 }
    }

    It 'is offered only to freeShell models' {
        Reset-Fake
        Add-Script (New-Call 'finish' @{ summary = 'x' })
        $null = Invoke-TestAgent -Model $script:BigModel
        @($global:PnhFake.ChatCalls[0].Tools | ForEach-Object { $_.function.name }) | Should -Contain 'run_powershell'
    }

    It 'blocks a deny-listed command without asking and without running it' {
        Reset-Fake
        Add-Script (New-Call 'run_powershell' @{ command = 'format C: /q'; why = 'Make room' }) (New-Call 'finish' @{ summary = 'x' })
        $r = Invoke-TestAgent -Model $script:BigModel
        $global:PnhFake.ShellRuns.Count | Should -Be 0
        $global:PnhFake.Confirms.Count | Should -Be 0
        $r.Actions[0].Blocked | Should -BeTrue
        (Get-ToolMessages 1)[0].content | Should -Match 'forbidden'
        $r.Summary | Should -Match 'not allowed for safety reasons'
    }

    It 'runs a read-only command directly' {
        Reset-Fake
        Add-Script (New-Call 'run_powershell' @{ command = 'Get-Service -Name Spooler | Select-Object Status'; why = 'Look at the printer service' }) (New-Call 'finish' @{ summary = 'x' })
        $null = Invoke-TestAgent -Model $script:BigModel
        $global:PnhFake.ShellRuns.Count | Should -Be 1
        $global:PnhFake.Confirms.Count | Should -Be 0
        (Get-ToolMessages 1)[0].content | Should -Match 'Status: Running'
    }

    It 'asks before a changing command and does not run it after a No' {
        Reset-Fake
        Add-Script (New-Call 'run_powershell' @{ command = 'Restart-Service -Name Spooler'; why = 'Restart the printer service' }) (New-Call 'finish' @{ summary = 'x' })
        $r = Invoke-TestAgent -Model $script:BigModel -Answer $false
        $global:PnhFake.Confirms.Count | Should -Be 1
        $global:PnhFake.Confirms[0].Explain | Should -Match 'Restart-Service -Name Spooler'
        $global:PnhFake.ShellRuns.Count | Should -Be 0
        $r.Actions[0].Declined | Should -BeTrue
    }

    It 'allows only read-only commands while a stop finding is in force' {
        Reset-Fake -Flags @('DISK_BAD', 'SPOOLER_STOPPED')
        Add-Script (New-Call 'run_powershell' @{ command = 'Restart-Service -Name Spooler'; why = 'Restart' }) (New-Call 'finish' @{ summary = 'x' })
        $r = Invoke-TestAgent -Model $script:BigModel -Answer $true
        $global:PnhFake.Confirms.Count | Should -Be 0
        $global:PnhFake.ShellRuns.Count | Should -Be 0
        $r.Actions[0].Blocked | Should -BeTrue
    }

    It 'runs a changing command after a Yes, with a restore point and a success check' {
        Reset-Fake
        Add-Script (New-Call 'run_powershell' @{ command = 'Restart-Service -Name Spooler'; why = 'Restart the printer service' }) (New-Call 'finish' @{ summary = 'x' })
        $null = Invoke-TestAgent -Model $script:BigModel -Answer $true
        $global:PnhFake.ShellRuns.Count | Should -Be 1
        $global:PnhFake.RestorePoints | Should -Be 1
        $global:PnhFake.CheckCalls | Should -BeGreaterThan 1
    }
}

Describe 'Test-PnhAgentReadOnlyCommand' {
    It '<Command> -> read-only <ReadOnly>' -TestCases @(
        @{ Command = 'Get-Service spooler | Select-Object Status'; ReadOnly = $true }
        @{ Command = 'Get-Service | Where-Object { $_.Status -eq "Running" } | Format-Table Name'; ReadOnly = $true }
        @{ Command = 'ipconfig /all'; ReadOnly = $true }
        @{ Command = 'ipconfig /flushdns'; ReadOnly = $false }
        @{ Command = 'netsh wlan show interfaces'; ReadOnly = $true }
        @{ Command = 'netsh wlan show profiles name=Home key=clear'; ReadOnly = $false }
        @{ Command = 'netsh winsock reset'; ReadOnly = $false }
        @{ Command = 'nslookup example.org'; ReadOnly = $true }
        @{ Command = 'sc.exe query spooler'; ReadOnly = $true }
        @{ Command = 'sc stop spooler'; ReadOnly = $false }
        @{ Command = 'Stop-Service spooler'; ReadOnly = $false }
        @{ Command = 'Get-Process | Stop-Process'; ReadOnly = $false }
        @{ Command = 'Format-Volume -DriveLetter D'; ReadOnly = $false }
        @{ Command = 'Test-ComputerSecureChannel -Repair'; ReadOnly = $false }
        @{ Command = 'Get-ChildItem C:\ > C:\out.txt'; ReadOnly = $false }
        @{ Command = 'Get-ChildItem C:\ > $null'; ReadOnly = $true }
        @{ Command = "[System.IO.File]::Delete('C:\x.txt')"; ReadOnly = $false }
        @{ Command = '& $cmd'; ReadOnly = $false }
        @{ Command = '. .\evil.ps1'; ReadOnly = $false }
        @{ Command = '${C:\temp\a.txt} = "x"'; ReadOnly = $false }
        @{ Command = 'Get-ChildItem | ForEach-Object { Remove-Item $_ }'; ReadOnly = $false }
        @{ Command = 'Get-Credential'; ReadOnly = $false }
        @{ Command = 'reg query HKLM\SOFTWARE\Microsoft'; ReadOnly = $true }
        @{ Command = 'reg delete HKLM\SOFTWARE\X /f'; ReadOnly = $false }
    ) {
        (Test-PnhAgentReadOnlyCommand -Command $Command).ReadOnly | Should -Be $ReadOnly
    }

    It 'reports parse errors instead of running broken commands' {
        (Test-PnhAgentReadOnlyCommand -Command 'Get-Item (').ParseError | Should -Not -BeNullOrEmpty
    }
}

Describe 'ConvertTo-PnhAgentPlainText' {
    It 'removes a complete think block' { ConvertTo-PnhAgentPlainText '<think>a b c</think>Hello' | Should -Be 'Hello' }
    It 'removes text before a leaked closing tag' { ConvertTo-PnhAgentPlainText "reasoning`nmore</think>`nHello" | Should -Be 'Hello' }
    It 'removes an unterminated think block' { ConvertTo-PnhAgentPlainText 'Hello <think>still thinking' | Should -Be 'Hello' }
    It 'removes Markdown and emoji' {
        ConvertTo-PnhAgentPlainText ('## Result' + "`n" + '- **Printer** is *fine* ✅ 😀' + "`n" + '- `code`') | Should -Be "Result`nPrinter is fine`ncode"
    }
    It 'cuts long text at a word' { (ConvertTo-PnhAgentPlainText ('word ' * 100) -MaxLength 50).Length | Should -BeLessOrEqual 54 }
}

Describe 'ConvertTo-PnhAgentArguments' {
    BeforeAll {
        $script:Schema = @{ type = 'object'; required = @('drive')
            properties = @{ drive = @{ type = 'string'; pattern = '^[A-Z]$' }; days = @{ type = 'integer' }; force = @{ type = 'boolean' }; mode = @{ type = 'string'; enum = @('Quick', 'Full') } } }
    }
    It 'turns "c:\" into "C"' { (ConvertTo-PnhAgentArguments @{ drive = 'c:\' } $script:Schema).Arguments.drive | Should -BeExactly 'C' }
    It 'parses numbers and booleans given as strings' {
        $r = ConvertTo-PnhAgentArguments @{ drive = 'D'; days = ' 14 '; force = 'ja' } $script:Schema
        $r.Problems.Count | Should -Be 0
        $r.Arguments.days | Should -Be 14
        $r.Arguments.force | Should -BeTrue
    }
    It 'maps enum values case-insensitively' { (ConvertTo-PnhAgentArguments @{ drive = 'C'; mode = 'full' } $script:Schema).Arguments.mode | Should -BeExactly 'Full' }
    It 'reports values outside the enum' { (ConvertTo-PnhAgentArguments @{ drive = 'C'; mode = 'deep' } $script:Schema).Problems[0] | Should -Match 'one of: Quick, Full' }
    It 'reports a missing required value' { (ConvertTo-PnhAgentArguments @{ days = 1 } $script:Schema).Problems | Should -Contain "'drive' is missing" }
    It 'maps a single unknown key onto a single missing required value' { (ConvertTo-PnhAgentArguments @{ laufwerk = 'E:' } $script:Schema).Arguments.drive | Should -Be 'E' }
    It 'accepts arguments as a JSON string' { (ConvertTo-PnhAgentArguments '{"drive":"C:"}' $script:Schema).Arguments.drive | Should -Be 'C' }
    It 'rejects arguments that are not an object' { (ConvertTo-PnhAgentArguments 'C:' $script:Schema).Problems[0] | Should -Match 'not a JSON object' }
    It 'drops values for a schema without properties' { (ConvertTo-PnhAgentArguments @{ x = 1 } @{ type = 'object'; properties = @{} }).Arguments.Count | Should -Be 0 }
}

Describe 'ConvertTo-PnhAgentTrimmedJson' {
    It 'keeps a large diagnosis under the limit and still valid JSON' {
        $big = @{ events = @(1..500 | ForEach-Object { @{ Id = $_; Message = ('x' * 300) } }); disk = @{ C = @{ FreeGB = 1.2 } } }
        $j = ConvertTo-PnhAgentTrimmedJson -InputObject $big -MaxChars 6000
        $j.Length | Should -BeLessOrEqual 6000
        { $j | ConvertFrom-Json } | Should -Not -Throw
        $j | Should -Match 'FreeGB'
    }
}
