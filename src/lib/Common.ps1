<#
.SYNOPSIS
    Common helpers for Plug'n'Heal: paths, logging, i18n, hidden process start, JSON.

.DESCRIPTION
    Dot-source this file (". $PSScriptRoot\Common.ps1"). It only defines functions and initialises a few
    script-scoped variables when they do not exist yet, so dot-sourcing it twice is harmless.

    Compatible with Windows PowerShell 5.1 and PowerShell 7, safe under Set-StrictMode -Version 2.
    It never enables strict mode itself, because dot-sourcing would change the caller's scope.

    Root rule (Get-PnhRoot):
      * The folder that contains lib\ is the app folder:
          on the drive       X:\PlugNHeal\app\lib\Common.ps1   -> app = X:\PlugNHeal\app
          in the repository  <repo>\src\lib\Common.ps1          -> app = <repo>\src
      * The PlugNHeal root is always the parent of the app folder:
          on the drive       X:\PlugNHeal
          in the repository  <repo>   (runtime\, models\, home\, logs\ then live next to src\; keep them out of git)
      * $env:PNH_ROOT overrides the root (development and tests only). The app folder never moves: it is
        always where this file is.
      * Nothing is cached or stored: the drive letter can change between runs.
#>

# ---------------------------------------------------------------------------------------------------------------
# Script state (initialised once; re-dot-sourcing keeps existing values)
# ---------------------------------------------------------------------------------------------------------------
if (-not (Get-Variable -Name PnhRunFolder -Scope Script -ErrorAction SilentlyContinue)) {
    $script:PnhRunFolder = $null
}
if (-not (Get-Variable -Name PnhLogBuffer -Scope Script -ErrorAction SilentlyContinue)) {
    $script:PnhLogBuffer = New-Object System.Collections.ArrayList
}
if (-not (Get-Variable -Name PnhTextCache -Scope Script -ErrorAction SilentlyContinue)) {
    $script:PnhTextCache = @{}
}

# ---------------------------------------------------------------------------------------------------------------
# Small building blocks
# ---------------------------------------------------------------------------------------------------------------

function Test-PnhWindows {
    <#
    .SYNOPSIS
        Returns $true when running on Windows (Windows PowerShell 5.1 or PowerShell 7 on Windows).
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    # $IsWindows does not exist in 5.1; -or short-circuits before it is read (StrictMode safe).
    return [bool](($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows)
}

function Get-PnhValue {
    <#
    .SYNOPSIS
        Reads a key or property from a hashtable or object without failing under Set-StrictMode.
    .DESCRIPTION
        Under Set-StrictMode -Version 2 both "$obj.Missing" and "$hashtable.Missing" throw. This helper
        returns $Default instead. Works for IDictionary (hashtable, ordered) and any object with properties
        (PSCustomObject from ConvertFrom-Json, CIM instances, registry items).
        Like any PowerShell function it returns arrays through the pipeline: wrap list values in @(), and read
        byte[] values directly (they would arrive as object[]).
    .PARAMETER InputObject
        Hashtable or object to read from. $null returns $Default.
    .PARAMETER Name
        Key or property name.
    .PARAMETER Default
        Value returned when the key/property is missing.
    .EXAMPLE
        Get-PnhValue $hardware 'RamBytes' 0
    #>
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][AllowNull()][object]$InputObject,
        [Parameter(Mandatory = $true, Position = 1)][string]$Name,
        [Parameter(Position = 2)][AllowNull()][object]$Default = $null
    )
    if ($null -eq $InputObject) { return $Default }
    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $Default
    }
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $prop) { return $Default }
    try { return $prop.Value } catch { return $Default }
}

function Join-PnhPath {
    <#
    .SYNOPSIS
        Joins any number of path parts without touching the file system (works for paths on missing drives).
    .DESCRIPTION
        Join-Path in Windows PowerShell 5.1 accepts only two parts and needs an existing PSDrive. This uses
        [System.IO.Path]::Combine, which is pure string work.
    .EXAMPLE
        Join-PnhPath $root 'runtime' 'ollama'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)][string[]]$Part)
    return [System.IO.Path]::Combine([string[]]$Part)
}

function Get-PnhComputerName {
    <#
    .SYNOPSIS
        Returns the computer name ($env:COMPUTERNAME, else the .NET machine name).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($env:COMPUTERNAME) { return $env:COMPUTERNAME }
    return [System.Environment]::MachineName
}

# ---------------------------------------------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------------------------------------------

function Get-PnhRoot {
    <#
    .SYNOPSIS
        Returns the PlugNHeal root folder (X:\PlugNHeal on the drive, the repository root when run from src\).
    .DESCRIPTION
        Rule: lib\ -> its parent is the app folder -> the parent of the app folder is the root.
        $env:PNH_ROOT overrides the result (development and tests only). Never stored, always derived.
    .OUTPUTS
        [string]
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if ($env:PNH_ROOT) { return [string]$env:PNH_ROOT }
    $app = Split-Path -Parent $PSScriptRoot
    return (Split-Path -Parent $app)
}

function Get-PnhPaths {
    <#
    .SYNOPSIS
        Returns all well-known PlugNHeal paths as a hashtable.
    .DESCRIPTION
        Keys: Root, App, Runtime, OllamaExe, Models, Home, Logs, Licenses, DriveJson.
        App is always the folder containing lib\ (X:\PlugNHeal\app or <repo>\src).
        OllamaExe is Runtime\ollama.exe on Windows; elsewhere Runtime/bin/ollama (layout of the Linux
        tarball) when present, else Runtime/ollama. Nothing is created here.
    .OUTPUTS
        [hashtable]
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Name fixed by ARCHITECTURE.md')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    $root = Get-PnhRoot
    $app = Split-Path -Parent $PSScriptRoot
    $runtime = Join-PnhPath $root 'runtime' 'ollama'
    if (Test-PnhWindows) {
        $exe = Join-PnhPath $runtime 'ollama.exe'
    } else {
        $exe = Join-PnhPath $runtime 'bin' 'ollama'
        if (-not [System.IO.File]::Exists($exe)) { $exe = Join-PnhPath $runtime 'ollama' }
    }
    return @{
        Root      = $root
        App       = $app
        Runtime   = $runtime
        OllamaExe = $exe
        Models    = (Join-PnhPath $root 'models')
        Home      = (Join-PnhPath $root 'home')
        Logs      = (Join-PnhPath $root 'logs')
        Licenses  = (Join-PnhPath $root 'licenses')
        DriveJson = (Join-PnhPath $root 'drive.json')
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------------------------------------------

function Add-PnhFileText {
    <#
    .SYNOPSIS
        Appends text to a file as UTF-8 without BOM, retrying briefly when another thread holds the file.
    .OUTPUTS
        [bool] $true when written.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text
    )
    $enc = New-Object System.Text.UTF8Encoding($false)
    for ($i = 1; $i -le 5; $i++) {
        try {
            [System.IO.File]::AppendAllText($Path, $Text, $enc)
            return $true
        } catch {
            Start-Sleep -Milliseconds (25 * $i)
        }
    }
    return $false
}

function New-PnhRunFolder {
    <#
    .SYNOPSIS
        Creates logs\<COMPUTERNAME>-<yyyyMMdd-HHmmss>\ and makes it the current run folder.
    .DESCRIPTION
        Sets $script:PnhRunFolder, writes log entries buffered before the folder existed, returns the path.
        If the folder already exists (two runs in the same second) a suffix -2, -3, ... is added.
    .PARAMETER LogsPath
        Parent folder; defaults to (Get-PnhPaths).Logs.
    .OUTPUTS
        [string] full path of the new run folder.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates only a log folder')]
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$LogsPath)
    if (-not $LogsPath) { $LogsPath = (Get-PnhPaths).Logs }
    $name = Get-PnhComputerName
    foreach ($c in [System.IO.Path]::GetInvalidFileNameChars()) { $name = $name.Replace([string]$c, '_') }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $base = Join-PnhPath $LogsPath ($name + '-' + $stamp)
    $path = $base
    $n = 2
    while ([System.IO.Directory]::Exists($path)) {
        $path = $base + '-' + $n
        $n++
    }
    $null = [System.IO.Directory]::CreateDirectory($path)
    $script:PnhRunFolder = $path

    if ($script:PnhLogBuffer.Count -gt 0) {
        $logText = New-Object System.Text.StringBuilder
        $jsonText = New-Object System.Text.StringBuilder
        foreach ($e in $script:PnhLogBuffer) {
            $null = $logText.Append($e.Log)
            $null = $jsonText.Append($e.Json)
        }
        $null = Add-PnhFileText -Path (Join-PnhPath $path 'run.log') -Text $logText.ToString()
        $null = Add-PnhFileText -Path (Join-PnhPath $path 'run.jsonl') -Text $jsonText.ToString()
        $script:PnhLogBuffer.Clear()
    }
    return $path
}

function Write-PnhLog {
    <#
    .SYNOPSIS
        Appends one entry to run.log (readable) and run.jsonl (one JSON object per line) in the run folder.
    .DESCRIPTION
        Both files are UTF-8 without BOM. Before New-PnhRunFolder was called, entries are kept in memory
        (at most 2000) and written when the folder is created. Never throws: logging must not break a run.
        Also writes the message to the verbose stream (visible with -Verbose / $VerbosePreference).
        run.jsonl fields: ts (ISO 8601 with offset), level (info|warn|error), msg, data (optional).
    .PARAMETER Message
        Short message, English, no secrets.
    .PARAMETER Level
        Info (default), Warn or Error.
    .PARAMETER Data
        Optional object, serialised with ConvertTo-Json -Depth 10 (run.log gets a shortened copy).
    .EXAMPLE
        Write-PnhLog 'Ollama started' -Data @{ Port = 51234 }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)][AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Warn', 'Error')][string]$Level = 'Info',
        [AllowNull()][object]$Data
    )
    try {
        $now = Get-Date
        $hasData = $PSBoundParameters.ContainsKey('Data')
        $entry = [ordered]@{
            ts    = $now.ToString('yyyy-MM-ddTHH:mm:ss.fffzzz')
            level = $Level.ToLowerInvariant()
            msg   = $Message
        }
        $dataJson = $null
        if ($hasData) {
            try {
                $dataJson = ConvertTo-Json -InputObject $Data -Depth 10 -Compress -WarningAction SilentlyContinue
                $entry['data'] = $Data
            } catch {
                $entry['data'] = [string]$Data
                $dataJson = ConvertTo-Json -InputObject ([string]$Data) -Compress
            }
        }
        try {
            $jsonLine = (ConvertTo-Json -InputObject $entry -Depth 10 -Compress -WarningAction SilentlyContinue) + "`n"
        } catch {
            $entry.Remove('data')
            $jsonLine = (ConvertTo-Json -InputObject $entry -Compress) + "`n"
        }
        $logLine = '{0} [{1}] {2}' -f $now.ToString('yyyy-MM-dd HH:mm:ss.fff'), $Level.ToUpperInvariant().PadRight(5), $Message
        if ($dataJson) {
            if ($dataJson.Length -gt 2000) { $dataJson = $dataJson.Substring(0, 2000) + '...' }
            $logLine += ' | ' + $dataJson
        }
        $logLine += [System.Environment]::NewLine

        Write-Verbose ('[{0}] {1}' -f $Level, $Message)

        if ($script:PnhRunFolder -and [System.IO.Directory]::Exists($script:PnhRunFolder)) {
            $null = Add-PnhFileText -Path (Join-PnhPath $script:PnhRunFolder 'run.log') -Text $logLine
            $null = Add-PnhFileText -Path (Join-PnhPath $script:PnhRunFolder 'run.jsonl') -Text $jsonLine
        } elseif ($script:PnhLogBuffer.Count -lt 2000) {
            $null = $script:PnhLogBuffer.Add(@{ Log = $logLine; Json = $jsonLine })
        }
    } catch {
        Write-Verbose ('Write-PnhLog failed: ' + $_.Exception.Message)
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Language and texts
# ---------------------------------------------------------------------------------------------------------------

function Get-PnhLanguage {
    <#
    .SYNOPSIS
        Returns 'de' when the Windows display language is German, else 'en'.
    .OUTPUTS
        [string] 'de' or 'en'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    try {
        $culture = Get-UICulture
        if ($culture -and $culture.TwoLetterISOLanguageName -eq 'de') { return 'de' }
    } catch {
        Write-Verbose ('Get-UICulture failed: ' + $_.Exception.Message)
    }
    return 'en'
}

function Get-PnhI18nDirectory {
    <#
    .SYNOPSIS
        Returns the folder holding the i18n JSON files (<App>\i18n).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    return (Join-PnhPath (Split-Path -Parent $PSScriptRoot) 'i18n')
}

function Reset-PnhTextCache {
    <#
    .SYNOPSIS
        Forgets the loaded i18n tables (next Get-PnhText reads the files again).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'In-memory cache only')]
    [CmdletBinding()]
    param()
    $script:PnhTextCache = @{}
}

function Get-PnhTextTable {
    <#
    .SYNOPSIS
        Loads <App>\i18n\<lang>.json into a flat hashtable (nested objects become dotted keys). Cached.
    .DESCRIPTION
        Accepts flat files ({"cat.network": "Internet"}) and nested files ({"cat": {"network": "Internet"}}).
        A missing or broken file yields an empty table (and one log entry); it never throws.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory = $true)][string]$Language)
    if ($script:PnhTextCache.ContainsKey($Language)) { return $script:PnhTextCache[$Language] }
    $table = @{}
    $file = Join-PnhPath (Get-PnhI18nDirectory) ($Language + '.json')
    if ([System.IO.File]::Exists($file)) {
        try {
            $obj = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8))
            $stack = New-Object System.Collections.Stack
            $stack.Push(@('', $obj))
            while ($stack.Count -gt 0) {
                $item = $stack.Pop()
                $prefix = $item[0]
                foreach ($p in $item[1].PSObject.Properties) {
                    $key = $p.Name
                    if ($prefix) { $key = $prefix + '.' + $p.Name }
                    if ($p.Value -is [System.Management.Automation.PSCustomObject]) {
                        $stack.Push(@($key, $p.Value))
                    } elseif ($null -ne $p.Value) {
                        if (-not $table.ContainsKey($key)) { $table[$key] = $p.Value }
                    }
                }
            }
        } catch {
            Write-PnhLog -Level Warn -Message ('Cannot read i18n file ' + $file + ': ' + $_.Exception.Message)
        }
    } else {
        Write-PnhLog -Level Warn -Message ('i18n file missing: ' + $file)
    }
    $script:PnhTextCache[$Language] = $table
    return $table
}

function Get-PnhText {
    <#
    .SYNOPSIS
        Returns the user-visible text for a key in the current language.
    .DESCRIPTION
        Lookup order: <lang>.json, then en.json, then the key itself. Flat and nested JSON files both work
        ("a.b" finds {"a.b": ...} and {"a": {"b": ...}}). Arrays are joined with new lines.
        With -Arguments the text is formatted like "-f" ({0}, {1} ...); a format error returns the
        unformatted text.
    .PARAMETER Key
        Text key, e.g. 'cat.network'.
    .PARAMETER Arguments
        Values for {0}, {1}, ...
    .PARAMETER Language
        'de' or 'en'; defaults to Get-PnhLanguage.
    .EXAMPLE
        Get-PnhText 'model.reason.gpu' -Arguments 'qwen3.5:9b-q4_K_M'
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)][string]$Key,
        [Parameter(Position = 1)][AllowNull()][object[]]$Arguments,
        [ValidateSet('de', 'en')][string]$Language
    )
    if (-not $Language) { $Language = Get-PnhLanguage }
    $text = $null
    foreach ($lang in @($Language, 'en')) {
        $table = Get-PnhTextTable -Language $lang
        if ($table.ContainsKey($Key)) { $text = $table[$Key]; break }
    }
    if ($null -eq $text) { return $Key }
    if ($text -is [System.Array]) { $text = ($text | ForEach-Object { [string]$_ }) -join [System.Environment]::NewLine }
    $text = [string]$text
    if ($null -ne $Arguments -and $Arguments.Count -gt 0) {
        try { $text = $text -f $Arguments } catch { Write-Verbose ('Format failed for ' + $Key) }
    }
    return $text
}

# ---------------------------------------------------------------------------------------------------------------
# Processes
# ---------------------------------------------------------------------------------------------------------------

function Stop-PnhProcessTree {
    <#
    .SYNOPSIS
        Kills a process and its children. Never throws.
    .DESCRIPTION
        PowerShell 7 uses Process.Kill($true). Windows PowerShell 5.1 (.NET Framework) has no tree kill, so
        taskkill.exe /T /F is used; Process.Kill() is the last resort.
    .PARAMETER Process
        System.Diagnostics.Process object.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Only our own child processes')]
    [CmdletBinding()]
    param([AllowNull()][System.Diagnostics.Process]$Process)
    if ($null -eq $Process) { return }
    try { if ($Process.HasExited) { return } } catch { return }
    $treeKill = $Process.GetType().GetMethod('Kill', [type[]]@([bool]))
    if ($null -ne $treeKill) {
        try { $Process.Kill($true); $null = $Process.WaitForExit(5000); return } catch { Write-Verbose $_.Exception.Message }
    }
    if (Test-PnhWindows) {
        $sysRoot = $env:SystemRoot
        if (-not $sysRoot) { $sysRoot = 'C:\Windows' }
        $taskkill = Join-PnhPath $sysRoot 'System32' 'taskkill.exe'
        if ([System.IO.File]::Exists($taskkill)) {
            try {
                $psi = New-Object System.Diagnostics.ProcessStartInfo
                $psi.FileName = $taskkill
                $psi.Arguments = '/PID ' + $Process.Id + ' /T /F'
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $tk = [System.Diagnostics.Process]::Start($psi)
                $null = $tk.WaitForExit(15000)
            } catch { Write-Verbose $_.Exception.Message }
        }
    }
    try { if (-not $Process.HasExited) { $Process.Kill() } } catch { Write-Verbose $_.Exception.Message }
    try { $null = $Process.WaitForExit(5000) } catch { Write-Verbose $_.Exception.Message }
}

function Start-PnhHidden {
    <#
    .SYNOPSIS
        Starts a program without any window, optionally waits for it and returns exit code and output.
    .DESCRIPTION
        Uses System.Diagnostics.ProcessStartInfo with UseShellExecute=$false and CreateNoWindow=$true (the
        documented CREATE_NO_WINDOW path; -WindowStyle Hidden does not work with Windows Terminal).

        Wait mode (default): stdout and stderr are redirected and read asynchronously (ReadToEndAsync), so a
        chatty program cannot dead-lock on a full pipe. After -TimeoutSeconds the process tree is killed.
        Returns @{ExitCode; StdOut; StdErr; TimedOut; Process; Error}.

        -NoWait: returns at once with @{Process; Error; StdOutPath; StdErrPath; ...}. Output is only
        redirected when -StdOutPath / -StdErrPath are given; it is then copied to those files by
        Stream.CopyToAsync (no PowerShell callbacks on worker threads, no memory growth). Call
        Close-PnhHiddenOutput after the process ended to flush and close the files.

        Never throws: if the program cannot be started, Error holds the message and Process is $null.
    .PARAMETER FilePath
        Full path of the program (use full paths: in 5.1 "curl" is an alias).
    .PARAMETER ArgumentList
        One command-line string, quoted as the program expects.
    .PARAMETER Environment
        Variables for the child only. A $null value removes an inherited variable.
    .PARAMETER WorkingDirectory
        Working directory of the child.
    .PARAMETER TimeoutSeconds
        Wait mode only. 0 or less waits forever. Default 300.
    .PARAMETER NoWait
        Do not wait (servers).
    .PARAMETER StdOutPath
        -NoWait only: file that receives stdout (appended, raw bytes).
    .PARAMETER StdErrPath
        -NoWait only: file that receives stderr (appended, raw bytes).
    .PARAMETER Encoding
        Wait mode: encoding used to decode stdout/stderr. Default: the .NET default (console code page),
        which is right for Windows console tools such as ipconfig. Pass [Text.Encoding]::UTF8 for UTF-8 tools.
    .EXAMPLE
        $r = Start-PnhHidden -FilePath "$env:SystemRoot\System32\ipconfig.exe" -ArgumentList '/all' -TimeoutSeconds 30
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Name fixed by ARCHITECTURE.md')]
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [AllowEmptyString()][string]$ArgumentList = '',
        [hashtable]$Environment,
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds = 300,
        [switch]$NoWait,
        [string]$StdOutPath,
        [string]$StdErrPath,
        [System.Text.Encoding]$Encoding
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = $ArgumentList
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }
    if ($Environment) {
        foreach ($k in @($Environment.Keys)) {
            $v = $Environment[$k]
            if ($null -eq $v) {
                if ($psi.EnvironmentVariables.ContainsKey([string]$k)) { $psi.EnvironmentVariables.Remove([string]$k) }
            } else {
                $psi.EnvironmentVariables[[string]$k] = [string]$v
            }
        }
    }
    if ($NoWait) {
        $psi.RedirectStandardOutput = [bool]$StdOutPath
        $psi.RedirectStandardError = [bool]$StdErrPath
    } else {
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        if ($Encoding) {
            $psi.StandardOutputEncoding = $Encoding
            $psi.StandardErrorEncoding = $Encoding
        }
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    try {
        $null = $proc.Start()
    } catch {
        $msg = 'Cannot start ' + $FilePath + ': ' + $_.Exception.Message
        if ($NoWait) { return @{ Process = $null; Error = $msg; StdOutPath = $StdOutPath; StdErrPath = $StdErrPath; Copies = @() } }
        return @{ ExitCode = $null; StdOut = ''; StdErr = ''; TimedOut = $false; Process = $null; Error = $msg }
    }

    if ($NoWait) {
        $copies = New-Object System.Collections.ArrayList
        $pairs = @(@($StdOutPath, 'out'), @($StdErrPath, 'err'))
        foreach ($pair in $pairs) {
            if (-not $pair[0]) { continue }
            try {
                # bufferSize 1 = unbuffered, so the log can be read while the program runs
                $fs = New-Object System.IO.FileStream($pair[0], [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite, 1)
                if ($pair[1] -eq 'out') { $src = $proc.StandardOutput.BaseStream } else { $src = $proc.StandardError.BaseStream }
                $task = $src.CopyToAsync($fs)
                $null = $copies.Add(@{ Stream = $fs; Task = $task })
            } catch {
                Write-Verbose ('Cannot redirect output to ' + $pair[0] + ': ' + $_.Exception.Message)
            }
        }
        return @{ Process = $proc; Error = $null; StdOutPath = $StdOutPath; StdErrPath = $StdErrPath; Copies = $copies.ToArray() }
    }

    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    $timedOut = $false
    if ($TimeoutSeconds -gt 0) {
        $ms = [int][Math]::Min([double]$TimeoutSeconds * 1000, [double][int]::MaxValue)
        if (-not $proc.WaitForExit($ms)) {
            $timedOut = $true
            Stop-PnhProcessTree -Process $proc
        }
    } else {
        $proc.WaitForExit()
    }
    # Children that inherited the pipe can keep it open; never wait longer than 5 s for the rest.
    $stdout = ''
    $stderr = ''
    try { if ($outTask.Wait(5000)) { $stdout = $outTask.Result } } catch { Write-Verbose $_.Exception.Message }
    try { if ($errTask.Wait(5000)) { $stderr = $errTask.Result } } catch { Write-Verbose $_.Exception.Message }
    $exitCode = $null
    try { if ($proc.HasExited) { $exitCode = $proc.ExitCode } } catch { Write-Verbose $_.Exception.Message }
    return @{ ExitCode = $exitCode; StdOut = $stdout; StdErr = $stderr; TimedOut = $timedOut; Process = $proc; Error = $null }
}

function Close-PnhHiddenOutput {
    <#
    .SYNOPSIS
        Flushes and closes the output files of a Start-PnhHidden -NoWait handle.
    .PARAMETER Handle
        Result of Start-PnhHidden -NoWait.
    .PARAMETER WaitMilliseconds
        How long to wait for the copy tasks to reach the end of the stream (default 3000).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$Handle,
        [int]$WaitMilliseconds = 3000
    )
    foreach ($c in @(Get-PnhValue $Handle 'Copies' @())) {
        if ($null -eq $c) { continue }
        try { $null = $c.Task.Wait($WaitMilliseconds) } catch { Write-Verbose $_.Exception.Message }
        try { $c.Stream.Flush(); $c.Stream.Dispose() } catch { Write-Verbose $_.Exception.Message }
    }
}

# ---------------------------------------------------------------------------------------------------------------
# JSON
# ---------------------------------------------------------------------------------------------------------------

function ConvertTo-PnhJson {
    <#
    .SYNOPSIS
        ConvertTo-Json -Depth 10 -Compress with the same result on 5.1 and 7.
    .DESCRIPTION
        Uses -InputObject (no pipeline unrolling, so a one-element array stays an array). The result is a
        .NET string; write it with UTF-8 (Add-PnhFileText) or send it as UTF-8 bytes.
        -EscapeNonAscii writes every non-ASCII character as \uXXXX, so the text survives any code page.
    .PARAMETER InputObject
        Object to serialise.
    .PARAMETER Depth
        Default 10 (the 5.1 default of 2 silently truncates).
    .PARAMETER EscapeNonAscii
        Escape characters above U+007F.
    .EXAMPLE
        ConvertTo-PnhJson @{ text = 'Hello' }
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true, Position = 0)][AllowNull()][object]$InputObject,
        [int]$Depth = 10,
        [switch]$EscapeNonAscii
    )
    $json = ConvertTo-Json -InputObject $InputObject -Depth $Depth -Compress -WarningAction SilentlyContinue
    if ($EscapeNonAscii -and $json) {
        $sb = New-Object System.Text.StringBuilder ($json.Length + 16)
        foreach ($ch in $json.ToCharArray()) {
            if ([int]$ch -gt 127) { $null = $sb.AppendFormat('\u{0:x4}', [int]$ch) } else { $null = $sb.Append($ch) }
        }
        $json = $sb.ToString()
    }
    return $json
}

function ConvertTo-PnhHashtable {
    <#
    .SYNOPSIS
        Converts PSCustomObjects (e.g. from ConvertFrom-Json) recursively into hashtables.
    .DESCRIPTION
        Replacement for ConvertFrom-Json -AsHashtable, which Windows PowerShell 5.1 lacks. Objects become
        hashtables, lists become object[] (a one-element list stays an array), scalars stay as they are.
    .PARAMETER InputObject
        Object, array or scalar.
    .EXAMPLE
        $h = ConvertTo-PnhHashtable (ConvertFrom-Json '{"a":{"b":[1]}}')
    #>
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowNull()][object]$InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [string] -or $InputObject -is [System.ValueType]) { return $InputObject }
    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in @($InputObject.Keys)) { $h[[string]$k] = ConvertTo-PnhHashtable $InputObject[$k] }
        return $h
    }
    if ($InputObject -is [System.Collections.IEnumerable]) {
        $list = New-Object System.Collections.ArrayList
        foreach ($item in $InputObject) { $null = $list.Add((ConvertTo-PnhHashtable $item)) }
        return , ($list.ToArray())
    }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-PnhHashtable $p.Value }
        return $h
    }
    return $InputObject
}

function Read-PnhJsonFile {
    <#
    .SYNOPSIS
        Reads a UTF-8 JSON file (with or without BOM) and returns the parsed object, or $null.
    .DESCRIPTION
        Get-Content in 5.1 reads files without BOM as ANSI, which garbles umlauts; this uses .NET with UTF-8.
        Errors are logged, not thrown, unless -ErrorOnFailure is given.
    .PARAMETER Path
        File path.
    .PARAMETER AsHashtable
        Return hashtables instead of PSCustomObjects.
    .PARAMETER ErrorOnFailure
        Throw instead of returning $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [switch]$AsHashtable,
        [switch]$ErrorOnFailure
    )
    try {
        $obj = ConvertFrom-Json -InputObject ([System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8))
        if ($AsHashtable) { return ConvertTo-PnhHashtable $obj }
        return $obj
    } catch {
        $msg = 'Cannot read JSON file ' + $Path + ': ' + $_.Exception.Message
        if ($ErrorOnFailure) { throw $msg }
        Write-PnhLog -Level Warn -Message $msg
        return $null
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Rights
# ---------------------------------------------------------------------------------------------------------------

function Test-PnhAdmin {
    <#
    .SYNOPSIS
        Returns $true when the current process runs elevated (Windows) or as root (elsewhere).
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    if (Test-PnhWindows) {
        try {
            $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
            $principal = New-Object System.Security.Principal.WindowsPrincipal($id)
            return [bool]$principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        } catch {
            return $false
        }
    }
    return ([System.Environment]::UserName -eq 'root')
}
