<#
.SYNOPSIS
    Start, stop and talk to the portable Ollama server of Plug'n'Heal.

.DESCRIPTION
    Dot-source this file; it loads Common.ps1 when needed. Nothing runs at dot-source time.

    Rules (ARCHITECTURE.md 5.4, docs/research/technik.md 1.3, 2.1, 2.4):
      * Environment only for the child process, never system-wide. Inherited OLLAMA_* variables (from an
        installed Ollama) are removed first.
      * 127.0.0.1 and a free port, never 11434 (an installed Ollama may run there).
      * PATH gets <runtime>\lib\ollama\vulkan in front on Windows: msvcp140/vcruntime140 are shipped only in
        the GPU sub folders (measured), the CPU backend needs them too.
      * HTTP: Invoke-WebRequest -UseBasicParsing (5.1 prompts otherwise since the 2025-12 update), body as
        UTF-8 bytes, response decoded from the raw bytes as UTF-8, ConvertTo-Json -Depth 20.
      * No function throws on HTTP errors; results carry Error / ErrorKind. Start-PnhOllama throws when the
        server cannot be started, because nothing else can work then.
#>

if (-not (Get-Command -Name Write-PnhLog -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Common.ps1')
}

function Get-PnhFreePort {
    <#
    .SYNOPSIS
        Returns a free TCP port on 127.0.0.1 (asks the OS for an ephemeral port).
    .OUTPUTS
        [int]
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return [int]$listener.LocalEndpoint.Port
    } finally {
        $listener.Stop()
    }
}

function Invoke-PnhHttp {
    <#
    .SYNOPSIS
        One HTTP request to the local Ollama server. Never throws.
    .DESCRIPTION
        Invoke-WebRequest -UseBasicParsing, explicit timeout, no proxy (PowerShell 7), JSON body sent as
        UTF-8 bytes, response decoded from RawContentStream as UTF-8 (5.1 would otherwise guess the charset).
        Returns @{Ok; StatusCode; Text; Error; ErrorKind('http'|'timeout'|'connection'); DurationMs}.
    .PARAMETER Method
        GET, POST or DELETE.
    .PARAMETER Uri
        Full URL.
    .PARAMETER Body
        JSON text (POST/DELETE).
    .PARAMETER TimeoutSeconds
        Request timeout, default 30.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [ValidateSet('GET', 'POST', 'DELETE')][string]$Method = 'GET',
        [Parameter(Mandatory = $true)][string]$Uri,
        [AllowNull()][string]$Body,
        [int]$TimeoutSeconds = 30
    )
    $ProgressPreference = 'SilentlyContinue'
    $params = @{
        Uri             = $Uri
        Method          = $Method
        UseBasicParsing = $true
        TimeoutSec      = $TimeoutSeconds
        ErrorAction     = 'Stop'
    }
    if ($PSVersionTable.PSVersion.Major -ge 6) { $params['NoProxy'] = $true }
    if ($Method -ne 'GET' -and $null -ne $Body) {
        $params['Body'] = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $params['ContentType'] = 'application/json; charset=utf-8'
    }
    $result = @{ Ok = $false; StatusCode = $null; Text = $null; Error = $null; ErrorKind = $null; DurationMs = 0 }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $resp = Invoke-WebRequest @params
        $result.StatusCode = [int](Get-PnhValue $resp 'StatusCode' 200)
        $stream = Get-PnhValue $resp 'RawContentStream'
        if ($stream -is [System.IO.MemoryStream]) {
            $result.Text = [System.Text.Encoding]::UTF8.GetString($stream.ToArray())
        } else {
            $content = Get-PnhValue $resp 'Content' ''
            if ($content -is [byte[]]) { $result.Text = [System.Text.Encoding]::UTF8.GetString($content) } else { $result.Text = [string]$content }
        }
        $result.Ok = $true
    } catch {
        $err = $_
        $ex = $err.Exception
        $response = $null
        try { $response = $ex.Response } catch { $response = $null }
        if ($null -ne $response) {
            try { $result.StatusCode = [int]$response.StatusCode } catch { $result.StatusCode = $null }
        }
        $bodyText = $null
        if ($null -ne $err.ErrorDetails -and $err.ErrorDetails.Message) {
            $bodyText = $err.ErrorDetails.Message
        } elseif ($response -is [System.Net.WebResponse]) {
            try {
                $reader = New-Object System.IO.StreamReader($response.GetResponseStream(), [System.Text.Encoding]::UTF8)
                $bodyText = $reader.ReadToEnd()
                $reader.Dispose()
            } catch { $bodyText = $null }
        }
        $message = $ex.Message
        if ($bodyText) {
            $message = $bodyText
            try {
                $parsed = ConvertFrom-Json -InputObject $bodyText
                $e = Get-PnhValue $parsed 'error'
                if ($e) { $message = [string]$e }
            } catch { $message = $bodyText }
        }
        $result.Error = $message
        if ($null -ne $result.StatusCode) {
            $result.ErrorKind = 'http'
        } elseif (($ex.Message + ' ' + [string]$ex.GetType().Name) -match 'time(d)?\s?out|Timeout|canceled|cancelled') {
            $result.ErrorKind = 'timeout'
        } else {
            $result.ErrorKind = 'connection'
        }
    }
    $result.DurationMs = [int]$sw.ElapsedMilliseconds
    return $result
}

function Get-PnhOllamaVersion {
    <#
    .SYNOPSIS
        GET /api/version; returns the version string or $null.
    .PARAMETER Server
        Server object from Start-PnhOllama (or anything with BaseUrl).
    .PARAMETER BaseUrl
        Alternative to -Server, e.g. http://127.0.0.1:51234
    .PARAMETER TimeoutSeconds
        Default 5.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([object]$Server, [string]$BaseUrl, [int]$TimeoutSeconds = 5)
    if (-not $BaseUrl) { $BaseUrl = [string](Get-PnhValue $Server 'BaseUrl' '') }
    if (-not $BaseUrl) { return $null }
    $r = Invoke-PnhHttp -Method GET -Uri ($BaseUrl.TrimEnd('/') + '/api/version') -TimeoutSeconds $TimeoutSeconds
    if (-not $r.Ok) { return $null }
    try {
        $v = Get-PnhValue (ConvertFrom-Json -InputObject $r.Text) 'version'
        if ($v) { return [string]$v }
    } catch { Write-Verbose $_.Exception.Message }
    return $null
}

function New-PnhOllamaEnvironment {
    <#
    .SYNOPSIS
        Builds the per-process environment for "ollama serve".
    .DESCRIPTION
        Returns a hashtable for Start-PnhHidden -Environment. Inherited OLLAMA_* variables are set to $null
        (removed), then:
          OLLAMA_MODELS=<Models>  OLLAMA_HOST=127.0.0.1:<Port>  OLLAMA_NO_CLOUD=1
          OLLAMA_CONTEXT_LENGTH=<ContextLength>  OLLAMA_FLASH_ATTENTION=1  OLLAMA_KV_CACHE_TYPE=q8_0
          OLLAMA_KEEP_ALIVE=30m        model stays loaded while the user reads and confirms
          OLLAMA_MAX_LOADED_MODELS=1   stepping down never keeps the bigger model in VRAM
          OLLAMA_NUM_PARALLEL=1        KV cache is allocated once, not per parallel slot
          OLLAMA_NOPRUNE=1             never delete blobs on the drive at start-up
          USERPROFILE=HOME=<Home>      key pair and .ollama stay on the drive
          PATH=<Runtime>\lib\ollama\vulkan;<PATH>   (Windows only, VC++ runtime for the CPU backends)
    .PARAMETER Paths
        Get-PnhPaths result.
    .PARAMETER Port
        Port for OLLAMA_HOST.
    .PARAMETER ContextLength
        Default num_ctx of the server (default 16384).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Returns a hashtable only')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [Parameter(Mandatory = $true)][int]$Port,
        [int]$ContextLength = 16384
    )
    $envs = @{}
    foreach ($name in @([System.Environment]::GetEnvironmentVariables().Keys)) {
        if ([string]$name -like 'OLLAMA_*') { $envs[[string]$name] = $null }
    }
    $homeDir = [string](Get-PnhValue $Paths 'Home' '')
    $envs['OLLAMA_MODELS'] = [string](Get-PnhValue $Paths 'Models' '')
    $envs['OLLAMA_HOST'] = '127.0.0.1:' + $Port
    $envs['OLLAMA_NO_CLOUD'] = '1'
    $envs['OLLAMA_CONTEXT_LENGTH'] = [string]$ContextLength
    $envs['OLLAMA_FLASH_ATTENTION'] = '1'
    $envs['OLLAMA_KV_CACHE_TYPE'] = 'q8_0'
    $envs['OLLAMA_KEEP_ALIVE'] = '30m'
    $envs['OLLAMA_MAX_LOADED_MODELS'] = '1'
    $envs['OLLAMA_NUM_PARALLEL'] = '1'
    $envs['OLLAMA_NOPRUNE'] = '1'
    $envs['USERPROFILE'] = $homeDir
    $envs['HOME'] = $homeDir
    if (Test-PnhWindows) {
        $vulkan = Join-PnhPath ([string](Get-PnhValue $Paths 'Runtime' '')) 'lib' 'ollama' 'vulkan'
        $envs['PATH'] = $vulkan + ';' + [string]$env:PATH
    }
    return $envs
}

function Start-PnhOllama {
    <#
    .SYNOPSIS
        Starts "ollama serve" from the drive without a window and waits until GET /api/version answers.
    .DESCRIPTION
        Returns @{BaseUrl; Port; Process; Version; ContextLength; Runtime; LogPath; Handle; StartedAt}.
        The server log (stderr) goes to <run folder>\ollama-server.log when a run folder exists
        (New-PnhRunFolder) or -LogFolder is given; it contains the "inference compute" lines that show which
        GPU Ollama really uses.
        Throws when ollama.exe is missing, the process exits early or /api/version does not answer within
        -StartTimeoutSeconds (the process is killed then).
    .PARAMETER Paths
        Get-PnhPaths result.
    .PARAMETER Port
        Fixed port; default: a free port.
    .PARAMETER ContextLength
        OLLAMA_CONTEXT_LENGTH and the default num_ctx of Invoke-PnhChat (default 16384; use the Ctx of
        Select-PnhModel). After a step-down the fallback's own context goes with every request
        (Test-PnhModelFit -NumCtx, Invoke-PnhAgent through ModelEntry.ctx), so the server is not restarted.
    .PARAMETER StartTimeoutSeconds
        Default 60.
    .PARAMETER ExtraEnvironment
        Additional variables, e.g. @{ OLLAMA_IGPU_ENABLE = '1' } or @{ OLLAMA_DEBUG = '1' }.
    .PARAMETER LogFolder
        Folder for ollama-server.log; default: the current run folder.
    .EXAMPLE
        $server = Start-PnhOllama -Paths (Get-PnhPaths) -ContextLength $sel.Ctx
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Name fixed by ARCHITECTURE.md')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][object]$Paths,
        [int]$Port,
        [int]$ContextLength = 16384,
        [int]$StartTimeoutSeconds = 60,
        [hashtable]$ExtraEnvironment,
        [string]$LogFolder
    )
    $exe = [string](Get-PnhValue $Paths 'OllamaExe' '')
    if (-not $exe -or -not [System.IO.File]::Exists($exe)) { throw ('Ollama executable not found: ' + $exe) }
    foreach ($key in @('Models', 'Home')) {
        $dir = [string](Get-PnhValue $Paths $key '')
        if ($dir -and -not [System.IO.Directory]::Exists($dir)) { $null = [System.IO.Directory]::CreateDirectory($dir) }
    }
    if ($Port -le 0) { $Port = Get-PnhFreePort }
    $envs = New-PnhOllamaEnvironment -Paths $Paths -Port $Port -ContextLength $ContextLength
    if ($ExtraEnvironment) { foreach ($k in @($ExtraEnvironment.Keys)) { $envs[[string]$k] = $ExtraEnvironment[$k] } }

    if (-not $LogFolder) { $LogFolder = $script:PnhRunFolder }
    $errLog = $null
    $outLog = $null
    if ($LogFolder -and [System.IO.Directory]::Exists($LogFolder)) {
        $errLog = Join-PnhPath $LogFolder 'ollama-server.log'
        $outLog = Join-PnhPath $LogFolder 'ollama-server.out.log'
    }
    $runtime = [string](Get-PnhValue $Paths 'Runtime' '')
    if (-not $runtime) { $runtime = Split-Path -Parent $exe }

    Write-PnhLog -Message 'Starting Ollama' -Data @{ Exe = $exe; Port = $Port; ContextLength = $ContextLength; Log = $errLog }
    $handle = Start-PnhHidden -FilePath $exe -ArgumentList 'serve' -Environment $envs -WorkingDirectory (Split-Path -Parent $exe) -NoWait -StdErrPath $errLog -StdOutPath $outLog
    if ($handle.Error) { throw $handle.Error }

    $baseUrl = 'http://127.0.0.1:' + $Port
    $version = $null
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $StartTimeoutSeconds) {
        if ($handle.Process.HasExited) { break }
        $version = Get-PnhOllamaVersion -BaseUrl $baseUrl -TimeoutSeconds 2
        if ($version) { break }
        Start-Sleep -Milliseconds 300
    }
    if (-not $version) {
        $exitInfo = 'running'
        if ($handle.Process.HasExited) { $exitInfo = 'exit code ' + $handle.Process.ExitCode }
        Stop-PnhProcessTree -Process $handle.Process
        Close-PnhHiddenOutput -Handle $handle
        $tail = ''
        if ($errLog -and [System.IO.File]::Exists($errLog)) {
            try {
                $lines = @([System.IO.File]::ReadAllLines($errLog, [System.Text.Encoding]::UTF8))
                $tail = ($lines | Select-Object -Last 15) -join "`n"
            } catch { $tail = '' }
        }
        Write-PnhLog -Level Error -Message 'Ollama did not start' -Data @{ State = $exitInfo; Seconds = [int]$sw.Elapsed.TotalSeconds; LogTail = $tail }
        throw ('Ollama did not answer on ' + $baseUrl + ' within ' + $StartTimeoutSeconds + ' s (' + $exitInfo + ').')
    }
    $server = @{
        BaseUrl       = $baseUrl
        Port          = $Port
        Process       = $handle.Process
        Version       = $version
        ContextLength = $ContextLength
        Runtime       = $runtime
        LogPath       = $errLog
        Handle        = $handle
        StartedAt     = (Get-Date).ToString('o')
    }
    Write-PnhLog -Message 'Ollama started' -Data @{ BaseUrl = $baseUrl; Version = $version; Pid = $handle.Process.Id; Ms = [int]$sw.ElapsedMilliseconds }
    return $server
}

function Stop-PnhOllama {
    <#
    .SYNOPSIS
        Stops the Ollama server and its runner processes, closes the server log.
    .DESCRIPTION
        Kills the process tree, then any process still running from the runtime folder (llama-server
        runners can outlive the parent on Windows). Only executables inside our runtime folder are touched.
        Returns $true when the server process has exited.
    .PARAMETER Server
        Result of Start-PnhOllama.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Name fixed by ARCHITECTURE.md')]
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory = $true)][AllowNull()][object]$Server)
    if ($null -eq $Server) { return $true }
    $proc = Get-PnhValue $Server 'Process'
    Stop-PnhProcessTree -Process $proc
    $runtime = [string](Get-PnhValue $Server 'Runtime' '')
    if ($runtime -and $runtime.Length -ge 6 -and [System.IO.Directory]::Exists($runtime)) {
        $prefix = $runtime.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
        # Only Ollama's own executables, and only from our runtime folder.
        foreach ($p in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match '^(ollama|llama-server)' })) {
            $exePath = $null
            try { $exePath = $p.Path } catch { $exePath = $null }
            if ($exePath -and $exePath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                try { $p.Kill() } catch { Write-Verbose $_.Exception.Message }
            }
        }
    }
    Close-PnhHiddenOutput -Handle (Get-PnhValue $Server 'Handle')
    $exited = $true
    if ($null -ne $proc) { try { $exited = [bool]$proc.HasExited } catch { $exited = $true } }
    Write-PnhLog -Message 'Ollama stopped' -Data @{ Exited = $exited }
    return $exited
}

function Split-PnhThinking {
    <#
    .SYNOPSIS
        Moves a leading <think>...</think> block (or everything up to a lone </think>) from content to thinking.
    .DESCRIPTION
        Ollama separates thinking for Qwen3.5/3.6/3.8 (built-in parser). Older templates put it into the
        content (measured with qwen3:4b and think:false), so this is a safety net.
    .OUTPUTS
        @{Content; Thinking}
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowNull()][AllowEmptyString()][string]$Content)
    $c = [string]$Content
    if ($c -match '(?s)^\s*<think>(.*?)</think>\s*(.*)$') {
        return @{ Content = $Matches[2]; Thinking = $Matches[1].Trim() }
    }
    $idx = $c.LastIndexOf('</think>')
    if ($idx -ge 0) {
        return @{ Content = $c.Substring($idx + 8).TrimStart(); Thinking = $c.Substring(0, $idx).Replace('<think>', '').Trim() }
    }
    return @{ Content = $c; Thinking = '' }
}

function ConvertFrom-PnhToolCalls {
    <#
    .SYNOPSIS
        Normalises message.tool_calls into @(@{Id; Name; Arguments(hashtable); ArgumentsError; Index}).
    .DESCRIPTION
        Ollama's native API sends arguments as an object, OpenAI-style paths and some models as a JSON string
        (sometimes double encoded). Arguments is always a hashtable; when it cannot be parsed it is @{} and
        ArgumentsError says why. Missing ids become call_<n>.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Converts a list')]
    [CmdletBinding()]
    param([AllowNull()][object]$ToolCalls)
    $list = New-Object System.Collections.ArrayList
    if ($null -eq $ToolCalls) { return , ($list.ToArray()) }
    $n = 0
    foreach ($tc in @($ToolCalls)) {
        if ($null -eq $tc) { continue }
        $fn = Get-PnhValue $tc 'function'
        $name = [string](Get-PnhValue $fn 'name' '')
        $raw = Get-PnhValue $fn 'arguments'
        $arguments = @{}
        $argError = $null
        for ($pass = 0; $pass -lt 2 -and $raw -is [string]; $pass++) {
            if (-not $raw.Trim()) { $raw = $null; break }
            try { $raw = ConvertFrom-Json -InputObject $raw } catch { $argError = 'arguments are not valid JSON'; $raw = $null }
        }
        if ($raw -is [string]) { $argError = 'arguments are not a JSON object'; $raw = $null }
        if ($null -ne $raw) {
            $converted = ConvertTo-PnhHashtable $raw
            if ($converted -is [hashtable]) { $arguments = $converted } else { $argError = 'arguments are not a JSON object' }
        }
        $id = [string](Get-PnhValue $tc 'id' '')
        if (-not $id) { $id = 'call_' + $n }
        $index = Get-PnhValue $fn 'index' $n
        $null = $list.Add(@{ Id = $id; Name = $name; Arguments = $arguments; ArgumentsError = $argError; Index = $index })
        $n++
    }
    return , ($list.ToArray())
}

function Invoke-PnhChat {
    <#
    .SYNOPSIS
        POST /api/chat (stream=false, temperature 0) and returns the parsed answer.
    .DESCRIPTION
        Returns @{Content; Thinking; ToolCalls=@(@{Id; Name; Arguments(hashtable); ArgumentsError; Index});
        Raw; DurationMs; Message; PromptTokens; OutputTokens; TokensPerSecond; DoneReason; Error; ErrorKind;
        StatusCode}.
          * Message is the assistant message as hashtable, ready to be appended to -Messages for the next round
            (Ollama needs it before the role=tool results).
          * Raw is the parsed response object.
          * HTTP 500 / empty answers are not thrown: Error is set (ErrorKind 'http', 'timeout', 'connection'
            or 'parse') and the agent can treat it as a format error and retry.
          * When the model rejects -Think ("does not support thinking"), the call is repeated once without it.
          * A <think> block that leaked into the content is moved to Thinking.
    .PARAMETER Server
        Result of Start-PnhOllama (BaseUrl, ContextLength).
    .PARAMETER Model
        Model tag.
    .PARAMETER Messages
        Array of @{role; content; ...} (tool results: @{role='tool'; tool_name=...; tool_call_id=...; content=...}).
    .PARAMETER Tools
        Ollama tools array (@{type='function'; function=@{name; description; parameters}}).
    .PARAMETER Think
        Sent as "think" only when given.
    .PARAMETER NumCtx
        options.num_ctx; default: Server.ContextLength (keeps the loaded model, a different num_ctx reloads it).
    .PARAMETER TimeoutSeconds
        Default 600 (CPU rounds and the first model load from the SSD can take minutes).
    .PARAMETER Options
        More Ollama options (num_predict, num_gpu, ...); merged over the defaults.
    .EXAMPLE
        $r = Invoke-PnhChat -Server $server -Model 'qwen3.5:4b-q4_K_M' -Messages $msgs -Tools $tools -Think $false
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][object]$Server,
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Messages,
        [AllowNull()][object[]]$Tools,
        [bool]$Think,
        [int]$NumCtx,
        [int]$TimeoutSeconds = 600,
        [hashtable]$Options
    )
    $baseUrl = ([string](Get-PnhValue $Server 'BaseUrl' '')).TrimEnd('/')
    $opts = @{ temperature = 0 }
    if ($NumCtx -le 0) {
        $serverCtx = Get-PnhValue $Server 'ContextLength'
        if ($serverCtx) { $NumCtx = [int]$serverCtx }
    }
    if ($NumCtx -gt 0) { $opts['num_ctx'] = $NumCtx }
    if ($Options) { foreach ($k in @($Options.Keys)) { $opts[[string]$k] = $Options[$k] } }

    $body = [ordered]@{
        model    = $Model
        messages = @($Messages)
        stream   = $false
        options  = $opts
    }
    if ($null -ne $Tools -and @($Tools).Count -gt 0) { $body['tools'] = @($Tools) }
    $sendThink = $PSBoundParameters.ContainsKey('Think')
    if ($sendThink) { $body['think'] = $Think }

    $out = @{
        Content = ''; Thinking = ''; ToolCalls = @(); Raw = $null; DurationMs = 0; Message = $null
        PromptTokens = $null; OutputTokens = $null; TokensPerSecond = $null; DoneReason = $null
        Error = $null; ErrorKind = $null; StatusCode = $null
    }
    $r = $null
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        $json = ConvertTo-Json -InputObject $body -Depth 20 -Compress
        $r = Invoke-PnhHttp -Method POST -Uri ($baseUrl + '/api/chat') -Body $json -TimeoutSeconds $TimeoutSeconds
        if (-not $r.Ok -and $sendThink -and $r.ErrorKind -eq 'http' -and [string]$r.Error -match 'think') {
            Write-PnhLog -Level Warn -Message ('Model rejected think, retrying without: ' + $r.Error)
            $body.Remove('think')
            $sendThink = $false
            continue
        }
        break
    }
    $out.DurationMs = $r.DurationMs
    $out.StatusCode = $r.StatusCode
    if (-not $r.Ok) {
        $out.Error = $r.Error
        $out.ErrorKind = $r.ErrorKind
        Write-PnhLog -Level Warn -Message 'Chat request failed' -Data @{ Model = $Model; StatusCode = $r.StatusCode; Kind = $r.ErrorKind; Error = $r.Error; Ms = $r.DurationMs }
        return $out
    }
    $obj = $null
    try { $obj = ConvertFrom-Json -InputObject $r.Text } catch { $obj = $null }
    if ($null -eq $obj) {
        $out.Error = 'Answer is not valid JSON'
        $out.ErrorKind = 'parse'
        Write-PnhLog -Level Warn -Message 'Chat answer is not JSON' -Data @{ Model = $Model; Text = ([string]$r.Text).Substring(0, [Math]::Min(500, ([string]$r.Text).Length)) }
        return $out
    }
    $out.Raw = $obj
    $apiError = Get-PnhValue $obj 'error'
    if ($apiError) {
        $out.Error = [string]$apiError
        $out.ErrorKind = 'http'
    }
    $msg = Get-PnhValue $obj 'message'
    $split = Split-PnhThinking -Content ([string](Get-PnhValue $msg 'content' ''))
    $out.Content = $split.Content
    $thinking = [string](Get-PnhValue $msg 'thinking' '')
    if ($split.Thinking) {
        if ($thinking) { $thinking = $thinking + "`n" + $split.Thinking } else { $thinking = $split.Thinking }
    }
    $out.Thinking = $thinking
    $out.ToolCalls = ConvertFrom-PnhToolCalls -ToolCalls (Get-PnhValue $msg 'tool_calls')
    $message = ConvertTo-PnhHashtable $msg
    if ($message -isnot [hashtable]) { $message = @{ role = 'assistant'; content = $out.Content } }
    $out.Message = $message
    $out.DoneReason = Get-PnhValue $obj 'done_reason'
    $out.PromptTokens = Get-PnhValue $obj 'prompt_eval_count'
    $out.OutputTokens = Get-PnhValue $obj 'eval_count'
    $evalNs = Get-PnhValue $obj 'eval_duration'
    if ($null -ne $out.OutputTokens -and $null -ne $evalNs -and [double]$evalNs -gt 0) {
        $out.TokensPerSecond = [Math]::Round([double]$out.OutputTokens / ([double]$evalNs / 1e9), 2)
    }
    Write-PnhLog -Message 'Chat answer' -Data @{
        Model = $Model; Ms = $out.DurationMs; PromptTokens = $out.PromptTokens; OutputTokens = $out.OutputTokens
        TokensPerSecond = $out.TokensPerSecond; ToolCalls = @($out.ToolCalls | ForEach-Object { $_.Name }); DoneReason = $out.DoneReason
    }
    return $out
}

function Get-PnhLoadedModels {
    <#
    .SYNOPSIS
        GET /api/ps -> one @{Name; Model; Size; SizeVram; ContextLength; ExpiresAt} per loaded model.
    .DESCRIPTION
        SizeVram 0 means "100% CPU", SizeVram = Size means "100% GPU". Returns nothing on errors; wrap the call
        in @().
    .PARAMETER Server
        Result of Start-PnhOllama.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Name fixed by ARCHITECTURE.md')]
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][object]$Server)
    $baseUrl = ([string](Get-PnhValue $Server 'BaseUrl' '')).TrimEnd('/')
    $r = Invoke-PnhHttp -Method GET -Uri ($baseUrl + '/api/ps') -TimeoutSeconds 10
    if (-not $r.Ok) {
        Write-PnhLog -Level Warn -Message 'GET /api/ps failed' -Data @{ Error = $r.Error }
        return
    }
    $obj = $null
    try { $obj = ConvertFrom-Json -InputObject $r.Text } catch { return }
    foreach ($m in @(Get-PnhValue $obj 'models' @())) {
        if ($null -eq $m) { continue }
        $size = Get-PnhValue $m 'size' 0
        $vram = Get-PnhValue $m 'size_vram' 0
        @{
            Name          = [string](Get-PnhValue $m 'name' '')
            Model         = [string](Get-PnhValue $m 'model' '')
            Size          = [int64]$size
            SizeVram      = [int64]$vram
            ContextLength = Get-PnhValue $m 'context_length'
            ExpiresAt     = Get-PnhValue $m 'expires_at'
        }
    }
}

function Get-PnhFitThreshold {
    <#
    .SYNOPSIS
        Pass marks of Test-PnhModelFit for one model: @{MinTokensPerSecond; MinGpuPercent}.
    .DESCRIPTION
        Generation speed (tokens per second, think off, measured over -NumPredict tokens), by catalogue tier:
          tier 1-2 (and tier 0 = ad-hoc models)   5  a 300-token round takes about a minute (CPU tiers)
          tier 3                                 10  9B models without thinking, meant for the GPU
          tier 4                                 15  thinking models: one round has several hundred tokens
        GPU share (size_vram / size from /api/ps), only for GPU tiers (3-4) that were chosen for the GPU
        (Select-PnhModel UseGpu) and are not partialOffload models: at least 90 %. Below that Ollama has moved
        layers to the CPU (VRAM used by something else, or the minVramGB estimate is too low), which costs
        far more speed than the short test shows. CPU tiers (1-2) and partialOffload models are judged by
        speed only; on the CPU path the GPU share is never checked.
    .PARAMETER Tier
        Catalogue tier (0 for ad-hoc models).
    .PARAMETER UseGpu
        The model was chosen for the GPU.
    .PARAMETER PartialOffload
        Running partly on the CPU is intended (catalogue field partialOffload).
    .OUTPUTS
        [hashtable]
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([int]$Tier, [switch]$UseGpu, [switch]$PartialOffload)
    $minTps = 5.0
    if ($Tier -eq 3) { $minTps = 10.0 } elseif ($Tier -ge 4) { $minTps = 15.0 }
    $minGpu = 0
    if ($UseGpu -and $Tier -ge 3 -and -not $PartialOffload) { $minGpu = 90 }
    return @{ MinTokensPerSecond = $minTps; MinGpuPercent = $minGpu }
}

function Test-PnhModelFit {
    <#
    .SYNOPSIS
        Loads the model with a tiny prompt and measures GPU share and generation speed.
    .DESCRIPTION
        Sends one short chat (think off, temperature 0, num_predict -NumPredict, same num_ctx as the agent
        will use), then reads /api/ps. Returns
          @{OnGpuPercent; TokensPerSecond; Ok; Reason; PromptTokensPerSecond; LoadMs; DurationMs;
            SizeBytes; SizeVramBytes; ContextLength; MinTokensPerSecond; MinGpuPercent; Error}
        Ok = no error, TokensPerSecond >= MinTokensPerSecond and OnGpuPercent >= MinGpuPercent.
        Reason: 'ok', 'error', 'not_loaded', 'slow' or 'gpu_share'.
        Thresholds come from Get-PnhFitThreshold (tier and partialOffload of -ModelEntry, -UseGpu): GPU tiers
        chosen for the GPU need at least 90 % on the GPU and 10 (tier 3) or 15 (tier 4) tokens/s; CPU tiers
        need 5 tokens/s. -MinTokensPerSecond and -MinGpuPercent override them.
    .PARAMETER Server
        Result of Start-PnhOllama.
    .PARAMETER Model
        Model tag.
    .PARAMETER ModelEntry
        Catalogue entry of the model (tier, partialOffload); without it tier 0 rules apply (5 tokens/s).
    .PARAMETER UseGpu
        Select-PnhModel chose the model for the GPU (Candidates[i].UseGpu).
    .PARAMETER NumCtx
        Default: Server.ContextLength. Pass the candidate's Ctx, so that the test loads the model exactly as
        the agent will use it.
    .PARAMETER MinTokensPerSecond
        Overrides the tier minimum.
    .PARAMETER MinGpuPercent
        Overrides the GPU share minimum.
    .PARAMETER NumPredict
        Tokens to generate for the measurement, default 48.
    .PARAMETER TimeoutSeconds
        Default 300 (includes loading the model from the SSD).
    .EXAMPLE
        $c = $sel.Candidates[0]
        $fit = Test-PnhModelFit -Server $server -Model $c.Tag -ModelEntry $c.Model -UseGpu:$c.UseGpu -NumCtx $c.Ctx
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][object]$Server,
        [Parameter(Mandatory = $true)][string]$Model,
        [object]$ModelEntry,
        [switch]$UseGpu,
        [int]$NumCtx,
        [double]$MinTokensPerSecond,
        [int]$MinGpuPercent,
        [int]$NumPredict = 48,
        [int]$TimeoutSeconds = 300
    )
    $tier = 0
    $tierRaw = Get-PnhValue $ModelEntry 'tier'
    if ($null -ne $tierRaw) {
        try { $tier = [int]$tierRaw } catch { $tier = 0 }
    }
    $limits = Get-PnhFitThreshold -Tier $tier -UseGpu:$UseGpu -PartialOffload:((Get-PnhValue $ModelEntry 'partialOffload') -eq $true)
    if (-not $PSBoundParameters.ContainsKey('MinTokensPerSecond')) { $MinTokensPerSecond = [double]$limits.MinTokensPerSecond }
    if (-not $PSBoundParameters.ContainsKey('MinGpuPercent')) { $MinGpuPercent = [int]$limits.MinGpuPercent }
    $result = @{
        OnGpuPercent = 0; TokensPerSecond = 0.0; Ok = $false; Reason = 'error'; PromptTokensPerSecond = $null
        LoadMs = $null; DurationMs = 0; SizeBytes = $null; SizeVramBytes = $null; ContextLength = $null; Error = $null
        MinTokensPerSecond = $MinTokensPerSecond; MinGpuPercent = $MinGpuPercent
    }
    $messages = @(@{ role = 'user'; content = 'Count from 1 to 60, separated by commas. Write only the numbers.' })
    $chatArgs = @{
        Server         = $Server
        Model          = $Model
        Messages       = $messages
        Think          = $false
        Options        = @{ num_predict = $NumPredict }
        TimeoutSeconds = $TimeoutSeconds
    }
    if ($NumCtx -gt 0) { $chatArgs['NumCtx'] = $NumCtx }
    $chat = Invoke-PnhChat @chatArgs
    $result.DurationMs = $chat.DurationMs
    if ($chat.Error) {
        $result.Error = $chat.Error
        Write-PnhLog -Level Warn -Message 'Model fit test failed' -Data @{ Model = $Model; Error = $chat.Error }
        return $result
    }
    $raw = $chat.Raw
    if ($null -ne $chat.TokensPerSecond) { $result.TokensPerSecond = [double]$chat.TokensPerSecond }
    $pc = Get-PnhValue $raw 'prompt_eval_count'
    $pd = Get-PnhValue $raw 'prompt_eval_duration'
    if ($null -ne $pc -and $null -ne $pd -and [double]$pd -gt 0) { $result.PromptTokensPerSecond = [Math]::Round([double]$pc / ([double]$pd / 1e9), 2) }
    $ld = Get-PnhValue $raw 'load_duration'
    if ($null -ne $ld) { $result.LoadMs = [int]([double]$ld / 1e6) }

    $wanted = @($Model.ToLowerInvariant())
    if ($Model -notmatch ':') { $wanted += ($Model.ToLowerInvariant() + ':latest') }
    $loaded = @(Get-PnhLoadedModels -Server $Server | Where-Object { $wanted -contains $_.Name.ToLowerInvariant() -or $wanted -contains $_.Model.ToLowerInvariant() })
    if ($loaded.Count -eq 0) {
        $result.Reason = 'not_loaded'
        $result.Error = 'Model not listed by /api/ps after the test generation'
    } else {
        $m = $loaded[0]
        $result.SizeBytes = $m.Size
        $result.SizeVramBytes = $m.SizeVram
        $result.ContextLength = $m.ContextLength
        if ($m.Size -gt 0) { $result.OnGpuPercent = [int][Math]::Round(100.0 * [double]$m.SizeVram / [double]$m.Size) }
        if ($result.TokensPerSecond -lt $MinTokensPerSecond) {
            $result.Reason = 'slow'
        } elseif ($result.OnGpuPercent -lt $MinGpuPercent) {
            $result.Reason = 'gpu_share'
        } else {
            $result.Reason = 'ok'
            $result.Ok = $true
        }
    }
    Write-PnhLog -Message 'Model fit measured' -Data @{
        Model = $Model; Ok = $result.Ok; Reason = $result.Reason; OnGpuPercent = $result.OnGpuPercent
        TokensPerSecond = $result.TokensPerSecond; PromptTokensPerSecond = $result.PromptTokensPerSecond; LoadMs = $result.LoadMs
        UseGpu = [bool]$UseGpu; Tier = $tier; NumCtx = $NumCtx; MinTokensPerSecond = $MinTokensPerSecond; MinGpuPercent = $MinGpuPercent
    }
    return $result
}
