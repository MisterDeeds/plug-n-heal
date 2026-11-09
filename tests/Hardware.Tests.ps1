# Pester 5. Unit tests for src/lib/Hardware.ps1. WMI, registry and nvidia-smi are mocked, so the tests run on
# Windows PowerShell 5.1, PowerShell 7 and on Linux.

BeforeDiscovery {
    $onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
}

BeforeAll {
    . $PSScriptRoot/../src/lib/Hardware.ps1
    Set-StrictMode -Version 2
    $onWindows = ($PSVersionTable.PSVersion.Major -lt 6) -or $IsWindows
    # Pester can only mock commands that exist; Get-CimInstance is missing on Linux.
    $script:addedCimStub = $false
    if (-not (Get-Command -Name Get-CimInstance -ErrorAction SilentlyContinue)) {
        function global:Get-CimInstance { [CmdletBinding()] param([string]$ClassName) }
        $script:addedCimStub = $true
    }

    function New-FakeController([string]$Name, [string]$Pnp, [object]$AdapterRam, [string]$Driver = '32.0.15.8157') {
        [pscustomobject]@{ Name = $Name; PNPDeviceID = $Pnp; AdapterRAM = $AdapterRam; DriverVersion = $Driver }
    }
}

AfterAll {
    if ($script:addedCimStub) { Remove-Item -Path Function:\Get-CimInstance -ErrorAction SilentlyContinue }
}

Describe 'ConvertTo-PnhVramBytes' {
    It 'reads QWORD, negative DWORD, little-endian binary and megabyte values' {
        ConvertTo-PnhVramBytes ([long]25769803776) | Should -Be ([uint64]25769803776)
        ConvertTo-PnhVramBytes ([int]-2147483648) | Should -Be ([uint64]2147483648)
        ConvertTo-PnhVramBytes ([System.BitConverter]::GetBytes([uint64]8589934592)) | Should -Be ([uint64]8589934592)
        ConvertTo-PnhVramBytes ([byte[]]@(0, 0, 0, 0x80)) | Should -Be ([uint64]2147483648)
        ConvertTo-PnhVramBytes 4096 | Should -Be ([uint64]4294967296)
    }
    It 'returns $null for empty or nonsense values' {
        ConvertTo-PnhVramBytes $null | Should -BeNullOrEmpty
        ConvertTo-PnhVramBytes 0 | Should -BeNullOrEmpty
        ConvertTo-PnhVramBytes 'abc' | Should -BeNullOrEmpty
        ConvertTo-PnhVramBytes ([byte[]]@()) | Should -BeNullOrEmpty
    }
}

Describe 'Get-PnhGpuVendor' {
    It 'uses the PCI vendor id first, then the name' {
        Get-PnhGpuVendor -Name 'x' -PnpDeviceId 'PCI\VEN_10DE&DEV_2684&SUBSYS_1' | Should -Be 'nvidia'
        Get-PnhGpuVendor -Name 'x' -PnpDeviceId 'PCI\VEN_1002&DEV_744C' | Should -Be 'amd'
        Get-PnhGpuVendor -Name 'x' -PnpDeviceId 'PCI\VEN_8086&DEV_A780' | Should -Be 'intel'
        Get-PnhGpuVendor -Name 'AMD Radeon RX 7900 XTX' -PnpDeviceId '' | Should -Be 'amd'
        Get-PnhGpuVendor -Name 'Microsoft Basic Display Adapter' -PnpDeviceId 'ROOT\BasicDisplay' | Should -Be 'other'
    }
}

Describe 'Test-PnhIntegratedGpu' {
    It 'classifies <Name> as integrated=<Expected>' -ForEach @(
        @{ Name = 'NVIDIA GeForce RTX 4070'; Vendor = 'nvidia'; Vram = 12GB; Expected = $false }
        @{ Name = 'Intel(R) UHD Graphics 770'; Vendor = 'intel'; Vram = 128MB; Expected = $true }
        @{ Name = 'Intel(R) Arc(TM) Graphics'; Vendor = 'intel'; Vram = 128MB; Expected = $true }
        @{ Name = 'Intel(R) Arc(TM) A770 Graphics'; Vendor = 'intel'; Vram = 16GB; Expected = $false }
        @{ Name = 'Intel(R) Arc(TM) B580 Graphics'; Vendor = 'intel'; Vram = 12GB; Expected = $false }
        @{ Name = 'AMD Radeon(TM) Graphics'; Vendor = 'amd'; Vram = 512MB; Expected = $true }
        @{ Name = 'AMD Radeon(TM) 780M'; Vendor = 'amd'; Vram = 4GB; Expected = $true }
        @{ Name = 'AMD Radeon(TM) RX Vega 11 Graphics'; Vendor = 'amd'; Vram = 2GB; Expected = $true }
        @{ Name = 'AMD Radeon RX 7800 XT'; Vendor = 'amd'; Vram = 16GB; Expected = $false }
        @{ Name = 'AMD Radeon Something'; Vendor = 'amd'; Vram = 1GB; Expected = $true }
        @{ Name = 'Microsoft Basic Display Adapter'; Vendor = 'other'; Vram = $null; Expected = $false }
    ) {
        Test-PnhIntegratedGpu -Name $Name -Vendor $Vendor -VramBytes $Vram | Should -Be $Expected
    }
}

Describe 'ConvertFrom-PnhNvidiaSmiCsv' {
    It 'parses MiB values and tolerates [N/A]' {
        $rows = @(ConvertFrom-PnhNvidiaSmiCsv -Text "NVIDIA GeForce RTX 4090, 24564, 23000, 581.57`r`nNVIDIA GeForce RTX 3060, 12288, [N/A], 581.57`r`n")
        $rows.Count | Should -Be 2
        $rows[0].Name | Should -Be 'NVIDIA GeForce RTX 4090'
        $rows[0].VramBytes | Should -Be ([uint64](24564 * 1MB))
        $rows[0].FreeVramBytes | Should -Be ([uint64](23000 * 1MB))
        $rows[0].Driver | Should -Be '581.57'
        $rows[1].FreeVramBytes | Should -BeNullOrEmpty
    }
    It 'returns nothing for empty output' {
        @(ConvertFrom-PnhNvidiaSmiCsv -Text '').Count | Should -Be 0
    }
}

Describe 'Get-PnhDisplayClassEntries' {
    It 'reads qwMemorySize, falls back to MemorySize and skips non-numbered keys' {
        Mock Get-ChildItem {
            [pscustomobject]@{ PSChildName = '0000'; PSPath = 'fake::0000' }
            [pscustomobject]@{ PSChildName = '0001'; PSPath = 'fake::0001' }
            [pscustomobject]@{ PSChildName = 'Properties'; PSPath = 'fake::Properties' }
        } -ParameterFilter { $LiteralPath -like 'HKLM:*' }
        Mock Get-ItemProperty {
            [pscustomobject]@{ MatchingDeviceId = 'pci\ven_10de&dev_2786'; DriverDesc = 'NVIDIA GeForce RTX 4070'; 'HardwareInformation.qwMemorySize' = [long]12884901888 }
        } -ParameterFilter { $LiteralPath -eq 'fake::0000' }
        Mock Get-ItemProperty {
            [pscustomobject]@{ MatchingDeviceId = 'pci\ven_8086&dev_a780'; DriverDesc = 'Intel(R) UHD Graphics 770'; 'HardwareInformation.MemorySize' = [byte[]]@(0, 0, 0, 0x80) }
        } -ParameterFilter { $LiteralPath -eq 'fake::0001' }

        $entries = @(Get-PnhDisplayClassEntries)
        $entries.Count | Should -Be 2
        $entries[0].VramBytes | Should -Be ([uint64]12884901888)
        $entries[0].MatchingDeviceId | Should -Be 'pci\ven_10de&dev_2786'
        $entries[1].VramBytes | Should -Be ([uint64]2147483648)
    }
}

Describe 'Get-PnhGpuList and Get-PnhHardware with mocked WMI' {
    BeforeAll {
        Mock Get-CimInstance {
            New-FakeController -Name 'Intel(R) UHD Graphics 770' -Pnp 'PCI\VEN_8086&DEV_A780&SUBSYS_1\3&11583659&0&10' -AdapterRam 1073741824
            New-FakeController -Name 'NVIDIA GeForce RTX 4070' -Pnp 'PCI\VEN_10DE&DEV_2786&SUBSYS_1\4&2AB3&0&0008' -AdapterRam 4293918720
        } -ParameterFilter { $ClassName -eq 'Win32_VideoController' }
        Mock Get-CimInstance {
            [pscustomobject]@{ Name = '13th Gen Intel(R) Core(TM) i7-13700'; NumberOfCores = 16; NumberOfLogicalProcessors = 24 }
        } -ParameterFilter { $ClassName -eq 'Win32_Processor' }
        Mock Get-PnhDisplayClassEntries {
            @{ Key = '0000'; MatchingDeviceId = 'pci\ven_10de&dev_2786'; DriverDesc = 'NVIDIA GeForce RTX 4070'; VramBytes = [uint64]12884901888 }
        }
    }

    It 'takes VRAM from nvidia-smi over the registry and AdapterRAM only below 4 GiB' {
        Mock Get-PnhNvidiaSmiGpus { @{ Name = 'NVIDIA GeForce RTX 4070'; VramBytes = [uint64](12282 * 1MB); FreeVramBytes = [uint64](11000 * 1MB); Driver = '581.57' } }
        $gpus = @(Get-PnhGpuList)
        $gpus.Count | Should -Be 2
        $intel = $gpus | Where-Object { $_.Vendor -eq 'intel' }
        $nv = $gpus | Where-Object { $_.Vendor -eq 'nvidia' }
        $intel.Integrated | Should -BeTrue
        $intel.VramSource | Should -Be 'adapterram'
        $nv.VramBytes | Should -Be ([uint64](12282 * 1MB))
        $nv.VramSource | Should -Be 'nvidia-smi'
        $nv.Driver | Should -Be '581.57'
        $nv.Integrated | Should -BeFalse
    }

    It 'falls back to the registry when nvidia-smi is missing' {
        Mock Get-PnhNvidiaSmiGpus { }
        $nv = @(Get-PnhGpuList) | Where-Object { $_.Vendor -eq 'nvidia' }
        $nv.VramBytes | Should -Be ([uint64]12884901888)
        $nv.VramSource | Should -Be 'registry'
        $nv.Driver | Should -Be '32.0.15.8157'
    }

    It 'never trusts AdapterRAM near 4 GiB' {
        Mock Get-PnhNvidiaSmiGpus { }
        Mock Get-PnhDisplayClassEntries { }
        $nv = @(Get-PnhGpuList) | Where-Object { $_.Vendor -eq 'nvidia' }
        $nv.VramBytes | Should -BeNullOrEmpty
    }

    It 'returns every contract key and the best dedicated NVIDIA/AMD VRAM' {
        Mock Get-PnhNvidiaSmiGpus { }
        $hw = Get-PnhHardware -Path $TestDrive
        foreach ($k in 'Gpus', 'BestDedicatedVramBytes', 'RamBytes', 'FreeRamBytes', 'CpuName', 'Cores', 'LogicalCpus', 'Avx2', 'Os', 'LanguageMode', 'IsAdmin', 'Drive') {
            $hw.ContainsKey($k) | Should -BeTrue -Because "key $k is part of the contract"
        }
        foreach ($k in 'Caption', 'Version', 'Build', 'Edition', 'SMode') { $hw.Os.ContainsKey($k) | Should -BeTrue }
        foreach ($k in 'Letter', 'FileSystem', 'FreeBytes', 'Label') { $hw.Drive.ContainsKey($k) | Should -BeTrue }
        foreach ($g in $hw.Gpus) {
            foreach ($k in 'Name', 'Vendor', 'VramBytes', 'Integrated', 'Driver') { $g.ContainsKey($k) | Should -BeTrue }
        }
        $hw.BestDedicatedVramBytes | Should -Be ([uint64]12884901888)
        $hw.CpuName | Should -Be '13th Gen Intel(R) Core(TM) i7-13700'
        $hw.Cores | Should -Be 16
        $hw.LogicalCpus | Should -Be 24
        $hw.LanguageMode | Should -Be 'FullLanguage'
        { ConvertTo-Json -InputObject $hw -Depth 10 } | Should -Not -Throw
    }

    It 'reports 0 when only integrated GPUs exist' {
        Mock Get-CimInstance {
            New-FakeController -Name 'AMD Radeon(TM) Graphics' -Pnp 'PCI\VEN_1002&DEV_15BF' -AdapterRam 536870912
        } -ParameterFilter { $ClassName -eq 'Win32_VideoController' }
        Mock Get-PnhNvidiaSmiGpus { }
        Mock Get-PnhDisplayClassEntries { }
        $hw = Get-PnhHardware -Path $TestDrive
        $hw.BestDedicatedVramBytes | Should -Be 0
        $hw.Gpus[0].Integrated | Should -BeTrue
    }
}

Describe 'Without mocks on this machine' {
    It 'Get-PnhHardware does not throw and finds RAM, CPUs and the drive' {
        $hw = Get-PnhHardware -Path $TestDrive
        $hw.RamBytes | Should -BeGreaterThan 0
        $hw.LogicalCpus | Should -BeGreaterThan 0
        $hw.Drive.FreeBytes | Should -BeGreaterThan 0
        $null -eq $hw.Avx2 -or $hw.Avx2 -is [bool] | Should -BeTrue
    }
    It 'Get-PnhDriveInfo returns the drive letter on Windows' -Skip:(-not $onWindows) {
        (Get-PnhDriveInfo -Path $env:SystemRoot).Letter | Should -Match '^[A-Z]$'
    }
    It 'Get-PnhSMode returns a boolean on Windows' -Skip:(-not $onWindows) {
        Get-PnhSMode | Should -BeOfType [bool]
    }
}
