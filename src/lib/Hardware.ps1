<#
.SYNOPSIS
    Hardware detection for Plug'n'Heal: GPUs and VRAM, RAM, CPU, Windows edition, language mode, drive.

.DESCRIPTION
    Dot-source this file; it loads Common.ps1 when needed. Nothing runs at dot-source time.
    Everything is read-only and needs no admin rights. Every part degrades to $null/empty instead of
    throwing, also on Linux/macOS (CI parses and unit-tests this file there).

    VRAM (ARCHITECTURE.md 5.2, technik.md 5):
      1. Win32_VideoController lists the adapters (Name, PNPDeviceID, DriverVersion).
      2. VRAM comes from the display class registry key
         HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}\00xx,
         value HardwareInformation.qwMemorySize (QWORD), fallback HardwareInformation.MemorySize
         (DWORD/binary), matched by MatchingDeviceId as prefix of PNPDeviceID.
      3. nvidia-smi (System32, DriverStore\FileRepository\nv*\, NVSMI) overrides VRAM for NVIDIA.
      4. Win32_VideoController.AdapterRAM is never used alone (uint32, wrong above 4 GiB); it is only a
         last resort when it is below 4 GiB and nothing else is known.
#>

if (-not (Get-Command -Name Write-PnhLog -CommandType Function -ErrorAction SilentlyContinue)) {
    . (Join-Path $PSScriptRoot 'Common.ps1')
}

function Get-PnhCimInstanceSafe {
    <#
    .SYNOPSIS
        Get-CimInstance that returns nothing instead of failing (missing cmdlet on Linux, WMI broken).
    .PARAMETER ClassName
        WMI class, e.g. Win32_OperatingSystem.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ClassName)
    if (-not (Get-Command -Name Get-CimInstance -ErrorAction SilentlyContinue)) { return }
    try {
        Get-CimInstance -ClassName $ClassName -ErrorAction Stop
    } catch {
        Write-PnhLog -Level Warn -Message ('CIM query failed: ' + $ClassName + ': ' + $_.Exception.Message)
    }
}

function ConvertTo-PnhVramBytes {
    <#
    .SYNOPSIS
        Normalises a registry VRAM value (QWORD, DWORD, binary, MB) to bytes.
    .DESCRIPTION
        QWORD arrives as Int64, DWORD as Int32 (negative above 2 GiB), binary as little-endian byte[].
        Values below 1 MiB are taken as megabytes (Microsoft documents MemorySize in MB, drivers write bytes).
        Returns $null for empty, zero or nonsense values.
    .PARAMETER Value
        Raw registry value.
    .OUTPUTS
        [uint64] or $null
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Bytes is a unit')]
    [CmdletBinding()]
    param([Parameter(Position = 0)][AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    $number = $null
    if ($Value -is [System.Array] -and $Value -isnot [byte[]]) {
        # a byte[] that went through the pipeline arrives as object[]
        foreach ($b in $Value) { if ($b -isnot [byte]) { return $null } }
        $Value = [byte[]]$Value
    }
    if ($Value -is [byte[]]) {
        if ($Value.Length -eq 0) { return $null }
        [double]$sum = 0
        for ($i = [Math]::Min($Value.Length, 8) - 1; $i -ge 0; $i--) { $sum = $sum * 256 + [double]$Value[$i] }
        $number = $sum
    } elseif ($Value -is [int]) {
        $number = [double]$Value
        if ($number -lt 0) { $number += 4294967296 }
    } else {
        try { $number = [double]$Value } catch { return $null }
    }
    if ($number -le 0) { return $null }
    if ($number -lt 1048576) { $number = $number * 1048576 }
    return [uint64]$number
}

function Get-PnhGpuVendor {
    <#
    .SYNOPSIS
        Returns 'nvidia', 'amd', 'intel' or 'other' from the PCI vendor id (preferred) or the adapter name.
    .PARAMETER Name
        Adapter name.
    .PARAMETER PnpDeviceId
        PNPDeviceID, e.g. PCI\VEN_10DE&DEV_2684&...
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()][string]$Name, [AllowNull()][string]$PnpDeviceId)
    $id = [string]$PnpDeviceId
    $n = [string]$Name
    if ($id -match 'VEN_10DE') { return 'nvidia' }
    if ($id -match 'VEN_1002|VEN_1022') { return 'amd' }
    if ($id -match 'VEN_8086') { return 'intel' }
    if ($n -match 'NVIDIA|GeForce|Quadro|Tesla') { return 'nvidia' }
    if ($n -match '\bAMD\b|Radeon|FirePro') { return 'amd' }
    if ($n -match 'Intel') { return 'intel' }
    return 'other'
}

function Test-PnhIntegratedGpu {
    <#
    .SYNOPSIS
        Heuristic: is this adapter an integrated GPU (shares system RAM)?
    .DESCRIPTION
        NVIDIA: never. Intel: integrated unless an Arc A/B-series or Arc Pro card. AMD: APU names
        ("Radeon(TM) Graphics", "Vega 8 Graphics", "780M", "8060S") are integrated, RX/Pro/FirePro/Instinct are
        dedicated, otherwise less than 2 GiB VRAM counts as integrated. 'other' (basic display, remote
        display, virtual adapters) is reported as not integrated; it is never used for models anyway.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][string]$Name, [string]$Vendor, [AllowNull()][object]$VramBytes)
    $n = [string]$Name
    switch ($Vendor) {
        'nvidia' { return $false }
        'intel' {
            if ($n -match 'Arc(\(TM\))?\s+(Pro\s+)?[AB]\d{2,3}' -or $n -match 'Arc(\(TM\))?\s+Pro' -or $n -match 'Iris Xe MAX|Data Center GPU') { return $false }
            return $true
        }
        'amd' {
            if ($n -match 'Vega \d+ Graphics|Radeon(\(TM\))?\s+Graphics|Radeon(\(TM\))?\s+\d{3,4}[MS]\b|\d{3,4}M Graphics') { return $true }
            if ($n -match '\bRX\b|Radeon(\(TM\))?\s+Pro|FirePro|Instinct|Radeon VII|\bW\d{4}\b') { return $false }
            if ($null -ne $VramBytes -and [double]$VramBytes -gt 0 -and [double]$VramBytes -lt 2147483648) { return $true }
            return $false
        }
        default { return $false }
    }
}

function Get-PnhDisplayClassEntries {
    <#
    .SYNOPSIS
        Reads the display adapter class keys from the registry: MatchingDeviceId, DriverDesc and VRAM.
    .OUTPUTS
        Hashtables @{Key; MatchingDeviceId; DriverDesc; VramBytes}. Nothing on non-Windows.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns several entries')]
    [CmdletBinding()]
    param()
    $cls = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    $keys = @()
    try {
        $keys = @(Get-ChildItem -LiteralPath $cls -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' })
    } catch {
        return
    }
    foreach ($k in $keys) {
        $p = $null
        try { $p = Get-ItemProperty -LiteralPath $k.PSPath -ErrorAction SilentlyContinue } catch { $p = $null }
        if ($null -eq $p) { continue }
        $vram = $null
        foreach ($valueName in @('HardwareInformation.qwMemorySize', 'HardwareInformation.MemorySize')) {
            # read the property directly: returning a byte[] through a function would unroll it
            $prop = $p.PSObject.Properties[$valueName]
            if ($null -eq $prop) { continue }
            $vram = ConvertTo-PnhVramBytes -Value $prop.Value
            if ($null -ne $vram) { break }
        }
        @{
            Key              = [string]$k.PSChildName
            MatchingDeviceId = [string](Get-PnhValue $p 'MatchingDeviceId' '')
            DriverDesc       = [string](Get-PnhValue $p 'DriverDesc' '')
            VramBytes        = $vram
        }
    }
}

function Find-PnhNvidiaSmi {
    <#
    .SYNOPSIS
        Returns the path of nvidia-smi if present, else $null.
    .DESCRIPTION
        Windows: %SystemRoot%\System32, %SystemRoot%\System32\DriverStore\FileRepository\nv*\ (DCH drivers,
        newest first), %ProgramFiles%\NVIDIA Corporation\NVSMI. Elsewhere: PATH.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    if (Test-PnhWindows) {
        $sysRoot = $env:SystemRoot
        if (-not $sysRoot) { $sysRoot = 'C:\Windows' }
        $candidate = Join-PnhPath $sysRoot 'System32' 'nvidia-smi.exe'
        if ([System.IO.File]::Exists($candidate)) { return $candidate }
        $pattern = Join-PnhPath $sysRoot 'System32' 'DriverStore' 'FileRepository' 'nv*' 'nvidia-smi.exe'
        $found = @(Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | Sort-Object -Property LastWriteTime -Descending)
        if ($found.Count -gt 0) { return $found[0].FullName }
        if ($env:ProgramFiles) {
            $candidate = Join-PnhPath $env:ProgramFiles 'NVIDIA Corporation' 'NVSMI' 'nvidia-smi.exe'
            if ([System.IO.File]::Exists($candidate)) { return $candidate }
        }
        return $null
    }
    $cmd = @(Get-Command -Name 'nvidia-smi' -CommandType Application -ErrorAction SilentlyContinue)
    if ($cmd.Count -gt 0) { return $cmd[0].Path }
    return $null
}

function ConvertFrom-PnhNvidiaSmiCsv {
    <#
    .SYNOPSIS
        Parses "nvidia-smi --query-gpu=name,memory.total,memory.free,driver_version --format=csv,noheader,nounits".
    .PARAMETER Text
        Raw stdout.
    .OUTPUTS
        Hashtables @{Name; VramBytes; FreeVramBytes; Driver} (memory columns are MiB).
    #>
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Text)
    if (-not $Text) { return }
    foreach ($line in ($Text -split "`r?`n")) {
        if (-not $line.Trim()) { continue }
        $f = @($line.Split(',') | ForEach-Object { $_.Trim() })
        if ($f.Count -lt 4) { continue }
        $total = $null
        $free = $null
        $mib = 0.0
        if ([double]::TryParse($f[1], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$mib)) { $total = [uint64]($mib * 1048576) }
        if ([double]::TryParse($f[2], [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$mib)) { $free = [uint64]($mib * 1048576) }
        @{ Name = $f[0]; VramBytes = $total; FreeVramBytes = $free; Driver = $f[3] }
    }
}

function Get-PnhNvidiaSmiGpus {
    <#
    .SYNOPSIS
        Runs nvidia-smi (hidden, 15 s timeout) and returns its GPUs; nothing when it is missing or fails.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Returns several entries')]
    [CmdletBinding()]
    param()
    $smi = Find-PnhNvidiaSmi
    if (-not $smi) { return }
    $r = Start-PnhHidden -FilePath $smi -ArgumentList '--query-gpu=name,memory.total,memory.free,driver_version --format=csv,noheader,nounits' -TimeoutSeconds 15
    if ($r.Error -or $r.TimedOut -or $r.ExitCode -ne 0) {
        Write-PnhLog -Level Warn -Message 'nvidia-smi failed' -Data @{ Path = $smi; ExitCode = $r.ExitCode; TimedOut = $r.TimedOut; Error = $r.Error; StdErr = $r.StdErr }
        return
    }
    ConvertFrom-PnhNvidiaSmiCsv -Text $r.StdOut
}

function Get-PnhGpuList {
    <#
    .SYNOPSIS
        Returns all display adapters as hashtables @{Name; Vendor; VramBytes; Integrated; Driver; PnpDeviceId;
        VramSource; FreeVramBytes} (one pipeline item per adapter; wrap the call in @()).
    .DESCRIPTION
        VramSource is 'nvidia-smi', 'registry', 'adapterram' or $null. Driver is the nvidia-smi driver version
        (e.g. 581.57) for NVIDIA when available, else Win32_VideoController.DriverVersion.
    #>
    [CmdletBinding()]
    param()
    $gpus = New-Object System.Collections.ArrayList
    $controllers = @(Get-PnhCimInstanceSafe -ClassName Win32_VideoController)
    $classEntries = @()
    if ($controllers.Count -gt 0) { $classEntries = @(Get-PnhDisplayClassEntries) }

    foreach ($vc in $controllers) {
        if ($null -eq $vc) { continue }
        $name = [string](Get-PnhValue $vc 'Name' '')
        $pnp = [string](Get-PnhValue $vc 'PNPDeviceID' '')
        $vendor = Get-PnhGpuVendor -Name $name -PnpDeviceId $pnp
        $vram = $null
        $source = $null
        $matched = @($classEntries | Where-Object { $_.MatchingDeviceId -and $pnp.StartsWith($_.MatchingDeviceId, [System.StringComparison]::OrdinalIgnoreCase) })
        $preferred = @($matched | Where-Object { $_.DriverDesc -eq $name -and $null -ne $_.VramBytes }) + @($matched | Where-Object { $null -ne $_.VramBytes })
        if ($preferred.Count -gt 0) {
            $vram = $preferred[0].VramBytes
            $source = 'registry'
        } else {
            $adapterRam = Get-PnhValue $vc 'AdapterRAM'
            if ($null -ne $adapterRam) {
                $ar = [double]$adapterRam
                # uint32: cards above 4 GiB report about 4 GiB (0xFFF00000), so only trust clearly smaller values
                if ($ar -gt 0 -and $ar -lt 4026531840) { $vram = [uint64]$ar; $source = 'adapterram' }
            }
        }
        $null = $gpus.Add(@{
                Name          = $name
                Vendor        = $vendor
                VramBytes     = $vram
                FreeVramBytes = $null
                Integrated    = $false
                Driver        = [string](Get-PnhValue $vc 'DriverVersion' '')
                PnpDeviceId   = $pnp
                VramSource    = $source
            })
    }

    # nvidia-smi overrides VRAM for NVIDIA cards; GPUs it knows but WMI does not (Linux) are added.
    $smiRows = @(Get-PnhNvidiaSmiGpus)
    if ($smiRows.Count -gt 0) {
        $used = @{}
        foreach ($g in @($gpus | Where-Object { $_.Vendor -eq 'nvidia' })) {
            $idx = -1
            for ($i = 0; $i -lt $smiRows.Count; $i++) {
                if (-not $used.ContainsKey($i) -and $smiRows[$i].Name -eq $g.Name) { $idx = $i; break }
            }
            if ($idx -lt 0) {
                for ($i = 0; $i -lt $smiRows.Count; $i++) { if (-not $used.ContainsKey($i)) { $idx = $i; break } }
            }
            if ($idx -lt 0) { continue }
            $used[$idx] = $true
            $row = $smiRows[$idx]
            if ($row.VramBytes) { $g.VramBytes = $row.VramBytes; $g.VramSource = 'nvidia-smi' }
            $g.FreeVramBytes = $row.FreeVramBytes
            if ($row.Driver) { $g.Driver = $row.Driver }
        }
        for ($i = 0; $i -lt $smiRows.Count; $i++) {
            if ($used.ContainsKey($i)) { continue }
            $row = $smiRows[$i]
            $null = $gpus.Add(@{
                    Name = $row.Name; Vendor = 'nvidia'; VramBytes = $row.VramBytes; FreeVramBytes = $row.FreeVramBytes
                    Integrated = $false; Driver = $row.Driver; PnpDeviceId = $null; VramSource = 'nvidia-smi'
                })
        }
    }

    foreach ($g in $gpus) {
        $g.Integrated = Test-PnhIntegratedGpu -Name $g.Name -Vendor $g.Vendor -VramBytes $g.VramBytes
    }
    return $gpus.ToArray()
}

function Get-PnhAvx2 {
    <#
    .SYNOPSIS
        Returns $true/$false for AVX2 support, $null when unknown.
    .DESCRIPTION
        Windows: kernel32 IsProcessorFeaturePresent(40) through Add-Type (only in FullLanguage mode). Before
        Windows 10 2004 a $false may mean "unknown". Linux: /proc/cpuinfo flags. Information only: Ollama
        picks its CPU backend itself.
    #>
    [CmdletBinding()]
    param()
    if (Test-PnhWindows) {
        if ([string]$ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') { return $null }
        try {
            $type = 'PlugNHeal.NativeCpu' -as [type]
            if ($null -eq $type) {
                Add-Type -Namespace 'PlugNHeal' -Name 'NativeCpu' -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(uint ProcessorFeature);' -ErrorAction Stop
                $type = 'PlugNHeal.NativeCpu' -as [type]
            }
            return [bool]$type::IsProcessorFeaturePresent(40)
        } catch {
            Write-PnhLog -Level Warn -Message ('AVX2 check failed: ' + $_.Exception.Message)
            return $null
        }
    }
    try {
        if ([System.IO.File]::Exists('/proc/cpuinfo')) {
            foreach ($line in [System.IO.File]::ReadAllLines('/proc/cpuinfo')) {
                if ($line -match '^flags\s*:') { return [bool]($line -match '\savx2(\s|$)') }
            }
        }
    } catch {
        Write-Verbose $_.Exception.Message
    }
    return $null
}

function Get-PnhSMode {
    <#
    .SYNOPSIS
        Returns $true when Windows runs in S mode (HKLM\SYSTEM\CurrentControlSet\Control\CI\Policy,
        SkuPolicyRequired = 1), $false otherwise, $null when not on Windows.
    #>
    [CmdletBinding()]
    param()
    if (-not (Test-PnhWindows)) { return $null }
    try {
        $p = Get-ItemProperty -LiteralPath 'HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy' -ErrorAction Stop
        $v = Get-PnhValue $p 'SkuPolicyRequired'
        return [bool]($null -ne $v -and [int]$v -eq 1)
    } catch {
        return $false
    }
}

function Get-PnhOsInfo {
    <#
    .SYNOPSIS
        Returns @{Caption; Version; Build; Edition; SMode; DisplayVersion; Ubr}.
    .PARAMETER OperatingSystem
        Win32_OperatingSystem instance (queried when omitted).
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$OperatingSystem)
    $info = @{ Caption = $null; Version = $null; Build = $null; Edition = $null; SMode = $null; DisplayVersion = $null; Ubr = $null }
    if (Test-PnhWindows) {
        if ($null -eq $OperatingSystem) { $OperatingSystem = @(Get-PnhCimInstanceSafe -ClassName Win32_OperatingSystem) | Select-Object -First 1 }
        if ($null -ne $OperatingSystem) {
            $info.Caption = [string](Get-PnhValue $OperatingSystem 'Caption')
            $info.Version = [string](Get-PnhValue $OperatingSystem 'Version')
            $b = Get-PnhValue $OperatingSystem 'BuildNumber'
            if ($b) { $info.Build = [int]$b }
        }
        try {
            $cv = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
            $info.Edition = [string](Get-PnhValue $cv 'EditionID')
            $dv = Get-PnhValue $cv 'DisplayVersion'
            if (-not $dv) { $dv = Get-PnhValue $cv 'ReleaseId' }
            $info.DisplayVersion = [string]$dv
            $ubr = Get-PnhValue $cv 'UBR'
            if ($null -ne $ubr) { $info.Ubr = [int]$ubr }
            if (-not $info.Build) {
                $cb = Get-PnhValue $cv 'CurrentBuildNumber'
                if ($cb) { $info.Build = [int]$cb }
            }
        } catch {
            Write-Verbose $_.Exception.Message
        }
        $info.SMode = Get-PnhSMode
        if (-not $info.Version) { $info.Version = [System.Environment]::OSVersion.Version.ToString() }
        return $info
    }
    $info.Version = [System.Environment]::OSVersion.Version.ToString()
    $info.Caption = [System.Environment]::OSVersion.VersionString
    try {
        if ([System.IO.File]::Exists('/etc/os-release')) {
            foreach ($line in [System.IO.File]::ReadAllLines('/etc/os-release')) {
                if ($line -match '^PRETTY_NAME="?([^"]*)"?') { $info.Caption = $Matches[1] }
            }
        }
    } catch {
        Write-Verbose $_.Exception.Message
    }
    return $info
}

function Get-PnhMemoryInfo {
    <#
    .SYNOPSIS
        Returns @{RamBytes; FreeRamBytes}. Windows: Win32_ComputerSystem.TotalPhysicalMemory (bytes) and
        Win32_OperatingSystem.FreePhysicalMemory (KB). Linux: /proc/meminfo (MemTotal, MemAvailable).
    .PARAMETER OperatingSystem
        Win32_OperatingSystem instance (queried when omitted).
    .PARAMETER ComputerSystem
        Win32_ComputerSystem instance (queried when omitted).
    #>
    [CmdletBinding()]
    param([AllowNull()][object]$OperatingSystem, [AllowNull()][object]$ComputerSystem)
    $info = @{ RamBytes = $null; FreeRamBytes = $null }
    if (Test-PnhWindows) {
        if ($null -eq $ComputerSystem) { $ComputerSystem = @(Get-PnhCimInstanceSafe -ClassName Win32_ComputerSystem) | Select-Object -First 1 }
        if ($null -eq $OperatingSystem) { $OperatingSystem = @(Get-PnhCimInstanceSafe -ClassName Win32_OperatingSystem) | Select-Object -First 1 }
        $total = Get-PnhValue $ComputerSystem 'TotalPhysicalMemory'
        if ($total) { $info.RamBytes = [uint64]$total }
        if (-not $info.RamBytes) {
            $visible = Get-PnhValue $OperatingSystem 'TotalVisibleMemorySize'
            if ($visible) { $info.RamBytes = [uint64]$visible * 1024 }
        }
        $free = Get-PnhValue $OperatingSystem 'FreePhysicalMemory'
        if ($null -ne $free) { $info.FreeRamBytes = [uint64]$free * 1024 }
        return $info
    }
    try {
        if ([System.IO.File]::Exists('/proc/meminfo')) {
            foreach ($line in [System.IO.File]::ReadAllLines('/proc/meminfo')) {
                if ($line -match '^MemTotal:\s+(\d+)\s*kB') { $info.RamBytes = [uint64]$Matches[1] * 1024 }
                elseif ($line -match '^MemAvailable:\s+(\d+)\s*kB') { $info.FreeRamBytes = [uint64]$Matches[1] * 1024 }
            }
        }
    } catch {
        Write-Verbose $_.Exception.Message
    }
    return $info
}

function Get-PnhCpuInfo {
    <#
    .SYNOPSIS
        Returns @{CpuName; Cores; LogicalCpus} (sums over all sockets).
    #>
    [CmdletBinding()]
    param()
    $info = @{ CpuName = $null; Cores = $null; LogicalCpus = [System.Environment]::ProcessorCount }
    $cpus = @(Get-PnhCimInstanceSafe -ClassName Win32_Processor)
    if ($cpus.Count -gt 0) {
        $names = @($cpus | ForEach-Object { ([string](Get-PnhValue $_ 'Name' '')).Trim() } | Where-Object { $_ } | Select-Object -Unique)
        if ($names.Count -gt 0) { $info.CpuName = $names -join ' / ' }
        $cores = 0
        $logical = 0
        foreach ($c in $cpus) {
            $cores += [int](Get-PnhValue $c 'NumberOfCores' 0)
            $logical += [int](Get-PnhValue $c 'NumberOfLogicalProcessors' 0)
        }
        if ($cores -gt 0) { $info.Cores = $cores }
        if ($logical -gt 0) { $info.LogicalCpus = $logical }
        return $info
    }
    try {
        if ([System.IO.File]::Exists('/proc/cpuinfo')) {
            $pairs = @{}
            $phys = '0'
            foreach ($line in [System.IO.File]::ReadAllLines('/proc/cpuinfo')) {
                if (-not $info.CpuName -and $line -match '^model name\s*:\s*(.+)$') { $info.CpuName = $Matches[1].Trim() }
                elseif ($line -match '^physical id\s*:\s*(\d+)') { $phys = $Matches[1] }
                elseif ($line -match '^core id\s*:\s*(\d+)') { $pairs[$phys + ':' + $Matches[1]] = $true }
            }
            if ($pairs.Count -gt 0) { $info.Cores = $pairs.Count }
        }
    } catch {
        Write-Verbose $_.Exception.Message
    }
    return $info
}

function Get-PnhDriveInfo {
    <#
    .SYNOPSIS
        Returns @{Letter; FileSystem; FreeBytes; TotalBytes; Label} for the drive that holds -Path.
    .DESCRIPTION
        Letter is the bare drive letter ('E') on Windows and the mount point elsewhere. Uses
        System.IO.DriveInfo (longest matching mount point wins), no WMI, works without admin rights.
    .PARAMETER Path
        Any path on the drive; defaults to Get-PnhRoot.
    #>
    [CmdletBinding()]
    param([string]$Path)
    $info = @{ Letter = $null; FileSystem = $null; FreeBytes = $null; TotalBytes = $null; Label = $null }
    if (-not $Path) { $Path = Get-PnhRoot }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
        $onWindows = Test-PnhWindows
        if ($onWindows) { $cmp = [System.StringComparison]::OrdinalIgnoreCase } else { $cmp = [System.StringComparison]::Ordinal }
        $best = $null
        foreach ($d in [System.IO.DriveInfo]::GetDrives()) {
            $n = $d.Name
            $hit = $full.StartsWith($n, $cmp) -and (
                $n.EndsWith('\') -or $n.EndsWith('/') -or $full.Length -eq $n.Length -or
                $full[$n.Length] -eq [char]'/' -or $full[$n.Length] -eq [char]'\')
            if ($hit -and ($null -eq $best -or $n.Length -gt $best.Name.Length)) { $best = $d }
        }
        if ($null -eq $best) { return $info }
        if ($onWindows) { $info.Letter = $best.Name.Substring(0, 1).ToUpperInvariant() } else { $info.Letter = $best.Name }
        try { $info.FileSystem = $best.DriveFormat } catch { Write-Verbose $_.Exception.Message }
        try { $info.FreeBytes = [uint64]$best.AvailableFreeSpace } catch { Write-Verbose $_.Exception.Message }
        try { $info.TotalBytes = [uint64]$best.TotalSize } catch { Write-Verbose $_.Exception.Message }
        try { $info.Label = $best.VolumeLabel } catch { Write-Verbose $_.Exception.Message }
    } catch {
        Write-PnhLog -Level Warn -Message ('Drive info failed: ' + $_.Exception.Message)
    }
    return $info
}

function Get-PnhHardware {
    <#
    .SYNOPSIS
        Collects the hardware facts used for model selection and the report.
    .DESCRIPTION
        Returns
          @{ Gpus = @(@{Name; Vendor; VramBytes; Integrated; Driver; PnpDeviceId; VramSource; FreeVramBytes})
             BestDedicatedVramBytes  largest VRAM of a dedicated NVIDIA/AMD GPU, 0 when there is none
             RamBytes; FreeRamBytes; CpuName; Cores; LogicalCpus; Avx2 (bool or $null)
             Os = @{Caption; Version; Build; Edition; SMode; DisplayVersion; Ubr}
             LanguageMode; IsAdmin
             Drive = @{Letter; FileSystem; FreeBytes; TotalBytes; Label} }
        Read-only, no admin rights needed, typically 1-3 s (first Add-Type for AVX2 costs about 1 s).
        Never throws; unknown values are $null.
    .PARAMETER Path
        Path whose drive is reported (default: the PlugNHeal root).
    .EXAMPLE
        $hw = Get-PnhHardware; '{0:N1} GiB VRAM' -f ($hw.BestDedicatedVramBytes / 1GB)
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string]$Path)
    $os = $null
    $cs = $null
    if (Test-PnhWindows) {
        $os = @(Get-PnhCimInstanceSafe -ClassName Win32_OperatingSystem) | Select-Object -First 1
        $cs = @(Get-PnhCimInstanceSafe -ClassName Win32_ComputerSystem) | Select-Object -First 1
    }
    $gpus = @()
    try { $gpus = @(Get-PnhGpuList) } catch { Write-PnhLog -Level Warn -Message ('GPU detection failed: ' + $_.Exception.Message) }
    $best = [uint64]0
    foreach ($g in $gpus) {
        if (($g.Vendor -eq 'nvidia' -or $g.Vendor -eq 'amd') -and -not $g.Integrated -and $null -ne $g.VramBytes -and [uint64]$g.VramBytes -gt $best) {
            $best = [uint64]$g.VramBytes
        }
    }
    $mem = Get-PnhMemoryInfo -OperatingSystem $os -ComputerSystem $cs
    $cpu = Get-PnhCpuInfo
    $isAdmin = $null
    try { $isAdmin = Test-PnhAdmin } catch { $isAdmin = $null }
    $hw = @{
        Gpus                   = $gpus
        BestDedicatedVramBytes = $best
        RamBytes               = $mem.RamBytes
        FreeRamBytes           = $mem.FreeRamBytes
        CpuName                = $cpu.CpuName
        Cores                  = $cpu.Cores
        LogicalCpus            = $cpu.LogicalCpus
        Avx2                   = (Get-PnhAvx2)
        Os                     = (Get-PnhOsInfo -OperatingSystem $os)
        LanguageMode           = [string]$ExecutionContext.SessionState.LanguageMode
        IsAdmin                = $isAdmin
        Drive                  = (Get-PnhDriveInfo -Path $Path)
    }
    Write-PnhLog -Message 'Hardware detected' -Data $hw
    return $hw
}
