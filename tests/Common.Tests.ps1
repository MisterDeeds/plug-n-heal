# Pester 5. Unit tests for src/lib/Common.ps1. Run on Windows PowerShell 5.1, PowerShell 7 on Windows and on Linux.

BeforeDiscovery {
    $onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
}

BeforeAll {
    . $PSScriptRoot/../src/lib/Common.ps1
    Set-StrictMode -Version 2
    $onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
    $repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    # Test files stay ASCII (Windows PowerShell 5.1 reads .ps1 without BOM as ANSI); umlauts come from char codes.
    $ae = [string][char]0x00E4; $oe = [string][char]0x00F6; $ue = [string][char]0x00FC
    $gruezi = 'Gr' + $ue + 'ezi'
}

Describe 'Test environment' {
    It 'runs under Set-StrictMode -Version 2' {
        { $null = $thisVariableDoesNotExist4711 } | Should -Throw
    }
}

Describe 'Get-PnhValue' {
    It 'reads hashtable keys and object properties, returns the default for missing ones' {
        Get-PnhValue @{ a = 1 } 'a' | Should -Be 1
        Get-PnhValue @{ a = 1 } 'b' 'x' | Should -Be 'x'
        Get-PnhValue ([pscustomobject]@{ a = 2 }) 'a' | Should -Be 2
        Get-PnhValue ([pscustomobject]@{ a = 2 }) 'b' | Should -BeNullOrEmpty
        Get-PnhValue $null 'a' 5 | Should -Be 5
    }
}

Describe 'Get-PnhRoot and Get-PnhPaths' {
    BeforeEach { $savedRoot = $env:PNH_ROOT; $env:PNH_ROOT = $null }
    AfterEach { $env:PNH_ROOT = $savedRoot }

    It 'derives the repository root from src/lib (parent of the app folder)' {
        (Get-PnhRoot).TrimEnd('\', '/') | Should -Be $repoRoot.TrimEnd('\', '/')
        $p = Get-PnhPaths
        $p.App | Should -Be (Join-Path $repoRoot 'src')
    }

    It 'returns every contract key and builds the paths below the root' {
        $env:PNH_ROOT = Join-Path $TestDrive 'PlugNHeal'
        $p = Get-PnhPaths
        foreach ($k in 'Root', 'App', 'Runtime', 'OllamaExe', 'Models', 'Home', 'Logs', 'Licenses', 'DriveJson') {
            $p.ContainsKey($k) | Should -BeTrue -Because "key $k is part of the contract"
        }
        $p.Root | Should -Be $env:PNH_ROOT
        $p.Models | Should -Be ([System.IO.Path]::Combine($env:PNH_ROOT, 'models'))
        $p.Runtime | Should -Be ([System.IO.Path]::Combine($env:PNH_ROOT, 'runtime', 'ollama'))
        $p.DriveJson | Should -Be ([System.IO.Path]::Combine($env:PNH_ROOT, 'drive.json'))
        $p.App | Should -Be (Join-Path $repoRoot 'src') -Because 'the app folder is always where the code is'
        if ($onWindows) { $p.OllamaExe | Should -BeLike '*ollama.exe' } else { $p.OllamaExe | Should -BeLike '*ollama' }
    }
}

Describe 'New-PnhRunFolder and Write-PnhLog' {
    It 'buffers entries before the run folder exists and writes UTF-8 without BOM to run.log and run.jsonl' {
        $script:PnhRunFolder = $null
        Write-PnhLog ('early entry ' + $ae + $oe + $ue)
        $logs = Join-Path $TestDrive 'logs'
        $folder = New-PnhRunFolder -LogsPath $logs
        $folder | Should -Exist
        (Split-Path -Leaf $folder) | Should -Match '^.+-\d{8}-\d{6}(-\d+)?$'

        Write-PnhLog $gruezi -Level Warn -Data @{ count = 1; list = @('x') }

        $logPath = Join-Path $folder 'run.log'
        $bytes = [System.IO.File]::ReadAllBytes($logPath)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse -Because 'no BOM'
        $text = $utf8.GetString($bytes)
        $text | Should -Match ('early entry ' + $ae + $oe + $ue)
        $text | Should -Match ('\[WARN \] ' + $gruezi)

        $lines = @([System.IO.File]::ReadAllLines((Join-Path $folder 'run.jsonl'), [System.Text.Encoding]::UTF8))
        $lines.Count | Should -Be 2
        $last = ConvertFrom-Json -InputObject $lines[1]
        $last.level | Should -Be 'warn'
        $last.msg | Should -Be $gruezi
        $last.data.count | Should -Be 1
        @($last.data.list).Count | Should -Be 1
        # PowerShell 7 turns ISO dates into DateTime on ConvertFrom-Json, so check the raw line
        $lines[1] | Should -Match '"ts":"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}[+-]\d{2}:\d{2}"'
    }

    It 'creates a new folder for a second run in the same second' {
        $logs = Join-Path $TestDrive 'logs2'
        $a = New-PnhRunFolder -LogsPath $logs
        $b = New-PnhRunFolder -LogsPath $logs
        $a | Should -Not -Be $b
        $b | Should -Exist
    }

    It 'does not throw for self-referencing data' {
        $null = New-PnhRunFolder -LogsPath (Join-Path $TestDrive 'logs3')
        $loop = @{ name = 'loop' }
        $loop['self'] = $loop
        { Write-PnhLog 'circular object' -Data $loop } | Should -Not -Throw
    }
}

Describe 'Get-PnhLanguage' {
    It 'returns de for a German UI culture' {
        Mock Get-UICulture { [pscustomobject]@{ TwoLetterISOLanguageName = 'de' } }
        Get-PnhLanguage | Should -Be 'de'
    }
    It 'returns en for any other UI culture' {
        Mock Get-UICulture { [pscustomobject]@{ TwoLetterISOLanguageName = 'fr' } }
        Get-PnhLanguage | Should -Be 'en'
    }
}

Describe 'Get-PnhText' {
    BeforeAll {
        $i18n = Join-Path $TestDrive 'i18n'
        $null = New-Item -ItemType Directory -Path $i18n -Force
        [System.IO.File]::WriteAllText((Join-Path $i18n 'de.json'), ('{ "hello": "' + $gruezi + ' {0}", "cat": { "network": "Internet" }, "bad": "x {0} {" }'), $utf8)
        [System.IO.File]::WriteAllText((Join-Path $i18n 'en.json'), '{ "hello": "Hello {0}", "only.en": "English only", "lines": ["a", "b"] }', (New-Object System.Text.UTF8Encoding($true)))
        Mock Get-PnhI18nDirectory { Join-Path $TestDrive 'i18n' }
    }
    BeforeEach { Reset-PnhTextCache }

    It 'formats arguments and keeps umlauts' {
        Get-PnhText 'hello' -Arguments 'Anna' -Language de | Should -Be ($gruezi + ' Anna')
    }
    It 'finds nested keys with dots' {
        Get-PnhText 'cat.network' -Language de | Should -Be 'Internet'
    }
    It 'falls back to English, then to the key' {
        Get-PnhText 'only.en' -Language de | Should -Be 'English only'
        Get-PnhText 'no.such.key' -Language de | Should -Be 'no.such.key'
    }
    It 'returns the unformatted text when formatting fails' {
        Get-PnhText 'bad' -Arguments 1 -Language de | Should -Be 'x {0} {'
    }
    It 'joins arrays with new lines (file with BOM)' {
        Get-PnhText 'lines' -Language en | Should -Be ('a' + [System.Environment]::NewLine + 'b')
    }
    It 'uses Get-PnhLanguage when no language is given' {
        Mock Get-UICulture { [pscustomobject]@{ TwoLetterISOLanguageName = 'de' } }
        Get-PnhText 'hello' -Arguments 'du' | Should -Be ($gruezi + ' du')
    }
    It 'returns the key when the files are missing' {
        Mock Get-PnhI18nDirectory { Join-Path $TestDrive 'nothing-here' }
        Reset-PnhTextCache
        Get-PnhText 'hello' -Language de | Should -Be 'hello'
    }
}

Describe 'Start-PnhHidden' {
    BeforeAll {
        if ($onWindows) {
            $shell = Join-Path $env:SystemRoot 'System32\cmd.exe'
            $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        } else {
            $shell = '/bin/sh'
        }
    }

    It 'returns exit code, stdout and stderr' {
        if ($onWindows) { $a = '/c "echo out& echo err 1>&2& exit /b 3"' } else { $a = '-c "echo out; echo err 1>&2; exit 3"' }
        $r = Start-PnhHidden -FilePath $shell -ArgumentList $a -TimeoutSeconds 30
        $r.Error | Should -BeNullOrEmpty
        $r.ExitCode | Should -Be 3
        $r.StdOut.Trim() | Should -Be 'out'
        $r.StdErr.Trim() | Should -Be 'err'
        $r.TimedOut | Should -BeFalse
        $r.Process | Should -Not -BeNullOrEmpty
    }

    It 'does not dead-lock on large output on both streams' {
        if ($onWindows) {
            $file = $psExe
            $a = '-NoProfile -Command "[Console]::Out.Write(''a'' * 300000); [Console]::Error.Write(''b'' * 300000)"'
        } else {
            $file = $shell
            $a = '-c "yes aaaaaaa | head -c 300000; yes bbbbbbb | head -c 300000 1>&2"'
        }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Start-PnhHidden -FilePath $file -ArgumentList $a -TimeoutSeconds 60
        $r.TimedOut | Should -BeFalse
        $r.StdOut.Length | Should -BeGreaterOrEqual 300000
        $r.StdErr.Length | Should -BeGreaterOrEqual 300000
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 30
    }

    It 'kills the process after the timeout' {
        if ($onWindows) { $file = $psExe; $a = '-NoProfile -Command "Start-Sleep -Seconds 30"' } else { $file = $shell; $a = '-c "sleep 30"' }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = Start-PnhHidden -FilePath $file -ArgumentList $a -TimeoutSeconds 1
        $r.TimedOut | Should -BeTrue
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 15
        $r.Process.HasExited | Should -BeTrue
    }

    It 'sets and removes environment variables for the child only' {
        $env:PNH_TEST_REMOVE = 'parent'
        try {
            if ($onWindows) { $a = '/c "echo [%PNH_TEST_SET%][%PNH_TEST_REMOVE%]"' } else { $a = '-c "echo [$PNH_TEST_SET][$PNH_TEST_REMOVE]"' }
            $r = Start-PnhHidden -FilePath $shell -ArgumentList $a -Environment @{ PNH_TEST_SET = 'eins'; PNH_TEST_REMOVE = $null } -TimeoutSeconds 30
            if ($onWindows) { $r.StdOut.Trim() | Should -Be '[eins][%PNH_TEST_REMOVE%]' } else { $r.StdOut.Trim() | Should -Be '[eins][]' }
            $env:PNH_TEST_SET | Should -BeNullOrEmpty
            $env:PNH_TEST_REMOVE | Should -Be 'parent'
        } finally {
            $env:PNH_TEST_REMOVE = $null
        }
    }

    It 'reports a missing program in Error instead of throwing' {
        $r = Start-PnhHidden -FilePath (Join-Path $TestDrive 'does-not-exist.exe') -TimeoutSeconds 5
        $r.Error | Should -Match 'Cannot start'
        $r.Process | Should -BeNullOrEmpty
        $r.ExitCode | Should -BeNullOrEmpty
    }

    It 'with -NoWait returns at once and copies stderr to a file' {
        $log = Join-Path $TestDrive 'nowait.log'
        if ($onWindows) { $a = '/c "echo to-stderr 1>&2"' } else { $a = '-c "echo to-stderr 1>&2"' }
        $h = Start-PnhHidden -FilePath $shell -ArgumentList $a -NoWait -StdErrPath $log
        $h.Error | Should -BeNullOrEmpty
        $h.Process.WaitForExit(10000) | Should -BeTrue
        Close-PnhHiddenOutput -Handle $h
        [System.IO.File]::ReadAllText($log) | Should -Match 'to-stderr'
    }
}

Describe 'JSON helpers' {
    It 'keeps one-element arrays as arrays and umlauts as text' {
        ConvertTo-PnhJson @(@{ a = $ae }) | Should -Be ('[{"a":"' + $ae + '"}]')
    }
    It 'escapes non-ASCII on request' {
        ConvertTo-PnhJson @{ t = $gruezi } -EscapeNonAscii | Should -Be ('{"t":"Gr' + [char]92 + 'u00fcezi"}')
    }
    It 'does not truncate nested objects up to depth 10' {
        $o = @{ l1 = @{ l2 = @{ l3 = @{ l4 = @{ l5 = @{ l6 = @{ l7 = 'deep' } } } } } } }
        ConvertTo-PnhJson $o | Should -Match '"l7":"deep"'
    }
    It 'converts JSON objects recursively into hashtables' {
        $h = ConvertTo-PnhHashtable (ConvertFrom-Json -InputObject '{"a":{"b":[1],"c":"x"},"n":null,"t":true}')
        $h | Should -BeOfType [hashtable]
        $h.a | Should -BeOfType [hashtable]
        , $h.a.b | Should -BeOfType [object[]]
        $h.a.b.Count | Should -Be 1
        $h.a.c | Should -Be 'x'
        $h.ContainsKey('n') | Should -BeTrue
        $h.t | Should -BeTrue
    }
    It 'reads UTF-8 JSON files with and without BOM' {
        $p1 = Join-Path $TestDrive 'nobom.json'
        $p2 = Join-Path $TestDrive 'bom.json'
        [System.IO.File]::WriteAllText($p1, ('{"t":"' + $gruezi + '"}'), $utf8)
        [System.IO.File]::WriteAllText($p2, ('{"t":"' + $gruezi + '"}'), (New-Object System.Text.UTF8Encoding($true)))
        (Read-PnhJsonFile -Path $p1).t | Should -Be $gruezi
        (Read-PnhJsonFile -Path $p2 -AsHashtable).t | Should -Be $gruezi
        Read-PnhJsonFile -Path (Join-Path $TestDrive 'missing.json') | Should -BeNullOrEmpty
        { Read-PnhJsonFile -Path (Join-Path $TestDrive 'missing.json') -ErrorOnFailure } | Should -Throw
    }
}

Describe 'Test-PnhAdmin and Test-PnhWindows' {
    It 'return booleans' {
        Test-PnhAdmin | Should -BeOfType [bool]
        Test-PnhWindows | Should -Be $onWindows
    }
}
