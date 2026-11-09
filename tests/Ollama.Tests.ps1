# Pester 5. Unit tests for src/lib/Ollama.ps1 (Invoke-WebRequest mocked) plus an optional integration test
# against a real Ollama binary.
#
# Integration test (tag 'Integration'): set
#   PNH_IT_ROOT   a PlugNHeal root with runtime/ollama (ollama.exe, or bin/ollama on Linux) and models/
#   PNH_IT_MODEL  an installed model tag with tool support, e.g. qwen3.5:2b-q4_K_M
# and run Invoke-Pester -Tag Integration. Without both variables it is skipped.

BeforeDiscovery {
    $onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
    $integration = [bool]($env:PNH_IT_ROOT -and $env:PNH_IT_MODEL)
}

BeforeAll {
    . $PSScriptRoot/../src/lib/Ollama.ps1
    Set-StrictMode -Version 2
    $onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
    $server = @{ BaseUrl = 'http://127.0.0.1:1'; Port = 1; ContextLength = 16384 }
    # Test files stay ASCII (Windows PowerShell 5.1 reads .ps1 without BOM as ANSI); umlauts come from char codes.
    $ae = [string][char]0x00E4; $ue = [string][char]0x00FC
    $greeting = 'Gr' + $ue + 'ezi, mein Drucker spinnt'

    function New-FakeResponse([string]$Json, [int]$Status = 200) {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Json)
        # Content is deliberately garbled: the code must decode the raw bytes itself.
        [pscustomobject]@{ StatusCode = $Status; Content = 'garbled'; RawContentStream = (New-Object System.IO.MemoryStream(, $bytes)) }
    }
    function New-HttpError([int]$Status, [string]$Body) {
        $ex = New-Object System.Exception ('Response status code does not indicate success: ' + $Status)
        $ex | Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{ StatusCode = $Status })
        $record = New-Object System.Management.Automation.ErrorRecord($ex, 'HttpError', [System.Management.Automation.ErrorCategory]::InvalidOperation, $null)
        $record.ErrorDetails = New-Object System.Management.Automation.ErrorDetails($Body)
        return $record
    }
    function Get-SentBody([object]$Body) { [System.Text.Encoding]::UTF8.GetString([byte[]]$Body) | ConvertFrom-Json }

    $tool = @{
        type     = 'function'
        function = @{
            name        = 'get_free_space'
            description = 'Returns the free space of a drive in GB.'
            parameters  = @{ type = 'object'; required = @('drive'); properties = @{ drive = @{ type = 'string'; description = 'Drive letter, e.g. C' } } }
        }
    }
}

Describe 'Get-PnhFreePort' {
    It 'returns a port that can be bound' {
        $port = Get-PnhFreePort
        $port | Should -BeGreaterThan 1023
        $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $port)
        { $l.Start() } | Should -Not -Throw
        $l.Stop()
    }
}

Describe 'New-PnhOllamaEnvironment' {
    BeforeAll { $paths = @{ Models = 'X:\PlugNHeal\models'; Home = 'X:\PlugNHeal\home'; Runtime = 'X:\PlugNHeal\runtime\ollama' } }

    It 'sets the per-process variables from the contract' {
        $e = New-PnhOllamaEnvironment -Paths $paths -Port 51234 -ContextLength 32768
        $e.OLLAMA_MODELS | Should -Be 'X:\PlugNHeal\models'
        $e.OLLAMA_HOST | Should -Be '127.0.0.1:51234'
        $e.OLLAMA_NO_CLOUD | Should -Be '1'
        $e.OLLAMA_CONTEXT_LENGTH | Should -Be '32768'
        $e.OLLAMA_FLASH_ATTENTION | Should -Be '1'
        $e.OLLAMA_KV_CACHE_TYPE | Should -Be 'q8_0'
        $e.OLLAMA_NOPRUNE | Should -Be '1'
        $e.OLLAMA_MAX_LOADED_MODELS | Should -Be '1'
        $e.OLLAMA_NUM_PARALLEL | Should -Be '1'
        $e.USERPROFILE | Should -Be 'X:\PlugNHeal\home'
        $e.HOME | Should -Be 'X:\PlugNHeal\home'
    }
    It 'removes inherited OLLAMA_* variables' {
        $env:OLLAMA_PNH_TEST = 'inherited'
        try {
            $e = New-PnhOllamaEnvironment -Paths $paths -Port 1
            $e.ContainsKey('OLLAMA_PNH_TEST') | Should -BeTrue
            $e['OLLAMA_PNH_TEST'] | Should -BeNullOrEmpty
        } finally { $env:OLLAMA_PNH_TEST = $null }
    }
    It 'puts the vulkan folder in front of PATH on Windows only' {
        Mock Test-PnhWindows { $true }
        $e = New-PnhOllamaEnvironment -Paths $paths -Port 1
        $e.PATH | Should -BeLike '*vulkan;*'
        $e.PATH.IndexOf('vulkan') | Should -BeLessThan 40
        Mock Test-PnhWindows { $false }
        (New-PnhOllamaEnvironment -Paths $paths -Port 1).ContainsKey('PATH') | Should -BeFalse
    }
}

Describe 'Invoke-PnhChat' {
    It 'sends a UTF-8 body with stream=false, temperature 0, num_ctx, think and the full tool schema' {
        Mock Invoke-WebRequest { New-FakeResponse '{"message":{"role":"assistant","content":"ok"},"done_reason":"stop"}' }
        $msgs = @(@{ role = 'user'; content = $greeting })
        $r = Invoke-PnhChat -Server $server -Model 'qwen3.5:2b-q4_K_M' -Messages $msgs -Tools @($tool) -Think $false
        $r.Error | Should -BeNullOrEmpty
        $r.Content | Should -Be 'ok'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $b = Get-SentBody $Body
            $raw = [byte[]]$Body
            $Method -eq 'POST' -and $Uri -eq 'http://127.0.0.1:1/api/chat' -and $UseBasicParsing -and
            $ContentType -eq 'application/json; charset=utf-8' -and
            $b.stream -eq $false -and $b.think -eq $false -and $b.options.temperature -eq 0 -and $b.options.num_ctx -eq 16384 -and
            @($b.messages).Count -eq 1 -and $b.messages[0].content -eq $greeting -and
            ([System.BitConverter]::ToString($raw) -match 'C3-BC') -and
            @($b.tools).Count -eq 1 -and $b.tools[0].function.parameters.properties.drive.description -eq 'Drive letter, e.g. C'
        }
    }

    It 'omits think when not given and uses -NumCtx and -Options' {
        Mock Invoke-WebRequest { New-FakeResponse '{"message":{"role":"assistant","content":"ok"}}' }
        $null = Invoke-PnhChat -Server $server -Model 'm' -Messages @(@{ role = 'user'; content = 'x' }) -NumCtx 4096 -Options @{ num_predict = 5 }
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $b = Get-SentBody $Body
            $null -eq $b.PSObject.Properties['think'] -and $b.options.num_ctx -eq 4096 -and $b.options.num_predict -eq 5 -and $null -eq $b.PSObject.Properties['tools']
        }
    }

    It 'decodes UTF-8 from the raw bytes and returns content, thinking and token counts' {
        Mock Invoke-WebRequest { New-FakeResponse ('{"message":{"role":"assistant","content":"Der Drucker l' + $ae + 'uft wieder.","thinking":"pr' + $ue + 'fen"},"prompt_eval_count":120,"eval_count":40,"eval_duration":2000000000,"done_reason":"stop"}') }
        $r = Invoke-PnhChat -Server $server -Model 'm' -Messages @(@{ role = 'user'; content = 'x' })
        $r.Content | Should -Be ('Der Drucker l' + $ae + 'uft wieder.')
        $r.Thinking | Should -Be ('pr' + $ue + 'fen')
        $r.PromptTokens | Should -Be 120
        $r.OutputTokens | Should -Be 40
        $r.TokensPerSecond | Should -Be 20
        $r.DoneReason | Should -Be 'stop'
        $r.Message | Should -BeOfType [hashtable]
        $r.Message.role | Should -Be 'assistant'
        , $r.ToolCalls | Should -BeOfType [object[]]
        $r.ToolCalls.Count | Should -Be 0
    }

    It 'parses tool calls with arguments as object' {
        Mock Invoke-WebRequest { New-FakeResponse '{"message":{"role":"assistant","content":"","tool_calls":[{"id":"call_ix1g1dkp","function":{"index":0,"name":"get_free_space","arguments":{"drive":"C:","options":{"deep":true},"list":["a"]}}}]}}' }
        $r = Invoke-PnhChat -Server $server -Model 'm' -Messages @(@{ role = 'user'; content = 'x' }) -Tools @($tool)
        $r.ToolCalls.Count | Should -Be 1
        $tc = $r.ToolCalls[0]
        $tc.Id | Should -Be 'call_ix1g1dkp'
        $tc.Name | Should -Be 'get_free_space'
        $tc.Arguments | Should -BeOfType [hashtable]
        $tc.Arguments.drive | Should -Be 'C:'
        $tc.Arguments.options | Should -BeOfType [hashtable]
        $tc.Arguments.options.deep | Should -BeTrue
        , $tc.Arguments.list | Should -BeOfType [object[]]
        $tc.ArgumentsError | Should -BeNullOrEmpty
        $r.Message.tool_calls[0].function.name | Should -Be 'get_free_space'
    }

    It 'parses arguments given as JSON string, double encoded string, invalid string; adds missing ids' {
        # (mock bodies do not see variables of the It block, so the JSON is built inside the mock)
        Mock Invoke-WebRequest {
            New-FakeResponse ('{"message":{"role":"assistant","content":"","tool_calls":[' +
                '{"function":{"name":"a","arguments":"{\"drive\":\"D\"}"}},' +
                '{"function":{"name":"b","arguments":"\"{\\\"drive\\\":\\\"E\\\"}\""}},' +
                '{"function":{"name":"c","arguments":"not json"}},' +
                '{"function":{"name":"d"}}]}}')
        }
        $r = Invoke-PnhChat -Server $server -Model 'm' -Messages @(@{ role = 'user'; content = 'x' })
        $r.ToolCalls.Count | Should -Be 4
        $r.ToolCalls[0].Arguments.drive | Should -Be 'D'
        $r.ToolCalls[0].Id | Should -Be 'call_0'
        $r.ToolCalls[1].Arguments.drive | Should -Be 'E'
        $r.ToolCalls[2].Arguments.Count | Should -Be 0
        $r.ToolCalls[2].ArgumentsError | Should -Not -BeNullOrEmpty
        $r.ToolCalls[3].Arguments | Should -BeOfType [hashtable]
        $r.ToolCalls[3].Arguments.Count | Should -Be 0
        $r.ToolCalls[3].Id | Should -Be 'call_3'
    }

    It 'moves a leaked think block from content to thinking' {
        Mock Invoke-WebRequest { New-FakeResponse '{"message":{"role":"assistant","content":"<think>\nnachdenken\n</think>\n\nAntwort"}}' }
        $r = Invoke-PnhChat -Server $server -Model 'm' -Messages @(@{ role = 'user'; content = 'x' })
        $r.Content | Should -Be 'Antwort'
        $r.Thinking | Should -Be 'nachdenken'
        (Split-PnhThinking -Content 'alt</think>neu').Content | Should -Be 'neu'
    }

    It 'returns HTTP 500 as Error with the server message instead of throwing' {
        Mock Invoke-WebRequest { throw (New-HttpError 500 '{"error":"failed to parse tool call"}') }
        $r = Invoke-PnhChat -Server $server -Model 'm' -Messages @(@{ role = 'user'; content = 'x' })
        $r.Error | Should -Be 'failed to parse tool call'
        $r.ErrorKind | Should -Be 'http'
        $r.StatusCode | Should -Be 500
        $r.ToolCalls.Count | Should -Be 0
    }

    It 'retries once without think when the model does not support thinking' {
        $script:calls = 0
        Mock Invoke-WebRequest {
            $script:calls++
            if ($script:calls -eq 1) { throw (New-HttpError 400 '{"error":"\"m\" does not support thinking"}') }
            New-FakeResponse '{"message":{"role":"assistant","content":"ok"}}'
        }
        $r = Invoke-PnhChat -Server $server -Model 'm' -Messages @(@{ role = 'user'; content = 'x' }) -Think $true
        $r.Error | Should -BeNullOrEmpty
        $r.Content | Should -Be 'ok'
        Should -Invoke Invoke-WebRequest -Times 2 -Exactly
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $null -eq (Get-SentBody $Body).PSObject.Properties['think'] }
    }

    It 'classifies timeouts and refused connections' {
        Mock Invoke-WebRequest { throw (New-Object System.Net.WebException 'The operation has timed out.') }
        (Invoke-PnhChat -Server $server -Model 'm' -Messages @(@{ role = 'user'; content = 'x' })).ErrorKind | Should -Be 'timeout'
        Mock Invoke-WebRequest { throw (New-Object System.Net.WebException 'Unable to connect to the remote server') }
        (Invoke-PnhChat -Server $server -Model 'm' -Messages @(@{ role = 'user'; content = 'x' })).ErrorKind | Should -Be 'connection'
    }

    It 'reports a non-JSON answer as parse error' {
        Mock Invoke-WebRequest { New-FakeResponse 'this is not json' }
        $r = Invoke-PnhChat -Server $server -Model 'm' -Messages @(@{ role = 'user'; content = 'x' })
        $r.ErrorKind | Should -Be 'parse'
    }
}

Describe 'Get-PnhLoadedModels and Test-PnhModelFit' {
    BeforeAll {
        $chatJson = '{"message":{"role":"assistant","content":"1, 2, 3"},"prompt_eval_count":30,"prompt_eval_duration":500000000,"eval_count":48,"eval_duration":4000000000,"load_duration":2500000000}'
        $psJson = '{"models":[{"name":"qwen3.5:4b-q4_K_M","model":"qwen3.5:4b-q4_K_M","size":4000,"size_vram":3000,"context_length":16384,"expires_at":"2026-11-09T23:00:00Z"},{"name":"other:1b","model":"other:1b","size":10,"size_vram":0}]}'
    }

    It 'parses /api/ps' {
        Mock Invoke-WebRequest { New-FakeResponse $psJson } -ParameterFilter { $Uri -like '*/api/ps' }
        $m = @(Get-PnhLoadedModels -Server $server)
        $m.Count | Should -Be 2
        $m[0].Name | Should -Be 'qwen3.5:4b-q4_K_M'
        $m[0].Size | Should -Be 4000
        $m[0].SizeVram | Should -Be 3000
        $m[0].ContextLength | Should -Be 16384
        $m[1].SizeVram | Should -Be 0
    }

    It 'measures GPU share and tokens per second' {
        Mock Invoke-WebRequest { New-FakeResponse $chatJson } -ParameterFilter { $Uri -like '*/api/chat' }
        Mock Invoke-WebRequest { New-FakeResponse $psJson } -ParameterFilter { $Uri -like '*/api/ps' }
        $fit = Test-PnhModelFit -Server $server -Model 'qwen3.5:4b-q4_K_M'
        $fit.OnGpuPercent | Should -Be 75
        $fit.TokensPerSecond | Should -Be 12
        $fit.PromptTokensPerSecond | Should -Be 60
        $fit.LoadMs | Should -Be 2500
        $fit.Ok | Should -BeTrue
        $fit.Reason | Should -Be 'ok'
        Should -Invoke Invoke-WebRequest -ParameterFilter { $Uri -like '*/api/chat' -and (Get-SentBody $Body).think -eq $false -and (Get-SentBody $Body).options.num_predict -eq 48 -and (Get-SentBody $Body).options.num_ctx -eq 16384 }
    }

    It 'fails with reason gpu_share, slow or not_loaded' {
        Mock Invoke-WebRequest { New-FakeResponse $chatJson } -ParameterFilter { $Uri -like '*/api/chat' }
        Mock Invoke-WebRequest { New-FakeResponse $psJson } -ParameterFilter { $Uri -like '*/api/ps' }
        (Test-PnhModelFit -Server $server -Model 'qwen3.5:4b-q4_K_M' -MinGpuPercent 100).Reason | Should -Be 'gpu_share'
        (Test-PnhModelFit -Server $server -Model 'qwen3.5:4b-q4_K_M' -MinTokensPerSecond 20).Reason | Should -Be 'slow'
        $missing = Test-PnhModelFit -Server $server -Model 'qwen3.5:9b-q4_K_M'
        $missing.Reason | Should -Be 'not_loaded'
        $missing.Ok | Should -BeFalse
    }

    It 'uses the tier thresholds: <Case>' -ForEach @(
        @{ Case = 'CPU tier 2: speed only'; Entry = @{ tier = 2 }; Gpu = $false; Ok = $true; Reason = 'ok'; MinTps = 5; MinGpu = 0 }
        @{ Case = 'tier 2 on the GPU: speed only (CPU tier)'; Entry = @{ tier = 2 }; Gpu = $true; Ok = $true; Reason = 'ok'; MinTps = 5; MinGpu = 0 }
        @{ Case = 'tier 3 on the GPU: 75 % is not enough'; Entry = @{ tier = 3 }; Gpu = $true; Ok = $false; Reason = 'gpu_share'; MinTps = 10; MinGpu = 90 }
        @{ Case = 'tier 4 on the GPU: 12 tokens/s is too slow'; Entry = @{ tier = 4 }; Gpu = $true; Ok = $false; Reason = 'slow'; MinTps = 15; MinGpu = 90 }
        @{ Case = 'tier 3 partialOffload: no GPU share needed'; Entry = @{ tier = 3; partialOffload = $true }; Gpu = $true; Ok = $true; Reason = 'ok'; MinTps = 10; MinGpu = 0 }
        @{ Case = 'tier 3 on the CPU path: no GPU share needed'; Entry = @{ tier = 3 }; Gpu = $false; Ok = $true; Reason = 'ok'; MinTps = 10; MinGpu = 0 }
        @{ Case = 'no entry (ad-hoc): 5 tokens/s'; Entry = $null; Gpu = $true; Ok = $true; Reason = 'ok'; MinTps = 5; MinGpu = 0 }
    ) {
        Mock Invoke-WebRequest { New-FakeResponse $chatJson } -ParameterFilter { $Uri -like '*/api/chat' }
        Mock Invoke-WebRequest { New-FakeResponse $psJson } -ParameterFilter { $Uri -like '*/api/ps' }
        $fit = Test-PnhModelFit -Server $server -Model 'qwen3.5:4b-q4_K_M' -ModelEntry $Entry -UseGpu:$Gpu
        $fit.Ok | Should -Be $Ok
        $fit.Reason | Should -Be $Reason
        $fit.MinTokensPerSecond | Should -Be $MinTps
        $fit.MinGpuPercent | Should -Be $MinGpu
    }

    It 'loads the model with the -NumCtx of the candidate' {
        Mock Invoke-WebRequest { New-FakeResponse $chatJson } -ParameterFilter { $Uri -like '*/api/chat' }
        Mock Invoke-WebRequest { New-FakeResponse $psJson } -ParameterFilter { $Uri -like '*/api/ps' }
        $null = Test-PnhModelFit -Server $server -Model 'qwen3.5:4b-q4_K_M' -ModelEntry @{ tier = 4 } -UseGpu -NumCtx 32768
        Should -Invoke Invoke-WebRequest -ParameterFilter { $Uri -like '*/api/chat' -and (Get-SentBody $Body).options.num_ctx -eq 32768 }
    }

    It 'explicit thresholds override the tier values' {
        Mock Invoke-WebRequest { New-FakeResponse $chatJson } -ParameterFilter { $Uri -like '*/api/chat' }
        Mock Invoke-WebRequest { New-FakeResponse $psJson } -ParameterFilter { $Uri -like '*/api/ps' }
        $fit = Test-PnhModelFit -Server $server -Model 'qwen3.5:4b-q4_K_M' -ModelEntry @{ tier = 4 } -UseGpu -MinTokensPerSecond 10 -MinGpuPercent 70
        $fit.Ok | Should -BeTrue
    }

    It 'reports a failed generation' {
        Mock Invoke-WebRequest { throw (New-HttpError 500 '{"error":"model requires more system memory"}') }
        $fit = Test-PnhModelFit -Server $server -Model 'qwen3.5:4b-q4_K_M'
        $fit.Ok | Should -BeFalse
        $fit.Reason | Should -Be 'error'
        $fit.Error | Should -Match 'more system memory'
    }
}

Describe 'Get-PnhFitThreshold' {
    It 'tier <Tier>, GPU <Gpu>, partial offload <Partial> -> <Tps> tokens/s, <GpuPct> % on the GPU' -ForEach @(
        @{ Tier = 0; Gpu = $true; Partial = $false; Tps = 5; GpuPct = 0 }
        @{ Tier = 1; Gpu = $false; Partial = $false; Tps = 5; GpuPct = 0 }
        @{ Tier = 1; Gpu = $true; Partial = $false; Tps = 5; GpuPct = 0 }
        @{ Tier = 2; Gpu = $true; Partial = $false; Tps = 5; GpuPct = 0 }
        @{ Tier = 3; Gpu = $true; Partial = $false; Tps = 10; GpuPct = 90 }
        @{ Tier = 3; Gpu = $false; Partial = $false; Tps = 10; GpuPct = 0 }
        @{ Tier = 4; Gpu = $true; Partial = $false; Tps = 15; GpuPct = 90 }
        @{ Tier = 4; Gpu = $true; Partial = $true; Tps = 15; GpuPct = 0 }
    ) {
        $t = Get-PnhFitThreshold -Tier $Tier -UseGpu:$Gpu -PartialOffload:$Partial
        $t.MinTokensPerSecond | Should -Be $Tps
        $t.MinGpuPercent | Should -Be $GpuPct
    }
}

Describe 'Start-PnhOllama failures' {
    It 'throws when the executable is missing' {
        $paths = @{ OllamaExe = (Join-Path $TestDrive 'nope.exe'); Models = (Join-Path $TestDrive 'm'); Home = (Join-Path $TestDrive 'h'); Runtime = $TestDrive }
        { Start-PnhOllama -Paths $paths } | Should -Throw '*not found*'
    }
    It 'throws quickly when the process exits at once' {
        if ($onWindows) { $exe = Join-Path $env:SystemRoot 'System32\whoami.exe' } else { $exe = '/bin/false' }
        $paths = @{ OllamaExe = $exe; Models = (Join-Path $TestDrive 'm'); Home = (Join-Path $TestDrive 'h'); Runtime = (Join-Path $TestDrive 'rt') }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        { Start-PnhOllama -Paths $paths -StartTimeoutSeconds 20 -LogFolder $TestDrive } | Should -Throw '*did not answer*'
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 10
    }
}

Describe 'Integration with a real Ollama' -Tag 'Integration' -Skip:(-not $integration) {
    BeforeAll {
        . $PSScriptRoot/../src/lib/Models.ps1
        $savedRoot = $env:PNH_ROOT
        $env:PNH_ROOT = $env:PNH_IT_ROOT
        $paths = Get-PnhPaths
        $null = New-PnhRunFolder
        $real = Start-PnhOllama -Paths $paths -ContextLength 8192
    }
    AfterAll {
        $started = Get-Variable -Name real -ValueOnly -ErrorAction SilentlyContinue
        if ($started) { $null = Stop-PnhOllama -Server $started }
        $env:PNH_ROOT = $savedRoot
    }

    It 'answers /api/version and lists the model on disk' {
        $real.Version | Should -Match '^\d+\.\d+'
        @(Get-PnhInstalledModels) | Should -Contain $env:PNH_IT_MODEL
    }
    It 'loads the model and measures it' {
        $fit = Test-PnhModelFit -Server $real -Model $env:PNH_IT_MODEL -MinTokensPerSecond 1
        $fit.Error | Should -BeNullOrEmpty
        $fit.TokensPerSecond | Should -BeGreaterThan 0
        $fit.SizeBytes | Should -BeGreaterThan 0
        @(Get-PnhLoadedModels -Server $real).Count | Should -Be 1
    }
    It 'gets a parsed tool call (think off)' {
        $msgs = @(
            @{ role = 'system'; content = 'Du bist ein Windows-Helfer. Benutze die Werkzeuge, um Probleme zu pruefen.' }
            @{ role = 'user'; content = 'Mein Computer sagt, die Festplatte C: sei voll. Pruefe bitte den freien Speicher auf C:.' }
        )
        $r = Invoke-PnhChat -Server $real -Model $env:PNH_IT_MODEL -Messages $msgs -Tools @($tool) -Think $false -TimeoutSeconds 300
        $r.Error | Should -BeNullOrEmpty
        $r.ToolCalls.Count | Should -BeGreaterThan 0
        $r.ToolCalls[0].Name | Should -Be 'get_free_space'
        $r.ToolCalls[0].Arguments | Should -BeOfType [hashtable]
        [string]$r.ToolCalls[0].Arguments.drive | Should -Match '^C'
        $r.Thinking | Should -BeNullOrEmpty
        Write-PnhLog 'IT tool call' -Data $r.ToolCalls

        # second round: tool result back, expect a plain answer
        $msgs += $r.Message
        $msgs += @{ role = 'tool'; tool_name = 'get_free_space'; tool_call_id = $r.ToolCalls[0].Id; content = '{"drive":"C","free_gb":0.8,"total_gb":237}' }
        $r2 = Invoke-PnhChat -Server $real -Model $env:PNH_IT_MODEL -Messages $msgs -Tools @($tool) -Think $false -TimeoutSeconds 300
        $r2.Error | Should -BeNullOrEmpty
        $r2.Content | Should -Match '0[.,]8'
        Write-PnhLog 'IT answer' -Data @{ Content = $r2.Content; Ms = $r2.DurationMs; Tps = $r2.TokensPerSecond }
    }
    It 'separates thinking from content with think on' {
        $msgs = @(@{ role = 'user'; content = ('Pr' + $ue + 'fe bitte den freien Speicher auf Laufwerk C:.') })
        $r = Invoke-PnhChat -Server $real -Model $env:PNH_IT_MODEL -Messages $msgs -Tools @($tool) -Think $true -TimeoutSeconds 600
        $r.Error | Should -BeNullOrEmpty
        $r.Content | Should -Not -Match '</?think>'
        Write-PnhLog 'IT think on' -Data @{ ThinkingChars = $r.Thinking.Length; ToolCalls = @($r.ToolCalls | ForEach-Object { $_.Name }); Ms = $r.DurationMs; OutputTokens = $r.OutputTokens }
    }
    It 'stops the server and its runners' {
        Stop-PnhOllama -Server $real | Should -BeTrue
        Get-PnhOllamaVersion -Server $real -TimeoutSeconds 2 | Should -BeNullOrEmpty
    }
}
