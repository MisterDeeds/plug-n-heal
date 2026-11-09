<#
.SYNOPSIS
    Pester 5 tests for lib\Diagnose.ps1: finding rules (pure, from facts), the diagnosis flow with
    mocked collectors, success check verdicts and Invoke-PnhSuccessCheck with mocked probes.
    Live Windows runs are skipped elsewhere.
#>

BeforeDiscovery {
    $onWindows = ($PSVersionTable.PSEdition -ne 'Core') -or [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
    $ruleCases = @(
        @{ Flag = 'NOT_ADMIN'; Facts = @{ system = @{ meta = @{ admin = $false } } } }
        @{ Flag = 'ELEVATED_OTHER_USER'; Facts = @{ system = @{ meta = @{ admin = $true; other_user = $true } } } }
        @{ Flag = 'MANAGED_DEVICE'; Facts = @{ system = @{ os = @{ domain = $false; entra = $true; mdm = $false } } } }
        @{ Flag = 'PENDING_REBOOT'; Facts = @{ system = @{ os = @{ pending_reboot = @('CBS') } } } }
        @{ Flag = 'UPTIME_LONG'; Facts = @{ system = @{ os = @{ uptime_h = 200.5 } } } }
        @{ Flag = 'NET_SERVICE_STOPPED'; Facts = @{ system = @{ svc = @(@{ n = 'Dnscache'; st = 'Stopped' }) } } }
        @{ Flag = 'FIREWALL_SERVICE_STOPPED'; Facts = @{ system = @{ svc = @(@{ n = 'BFE'; st = 'Stopped' }) } } }
        @{ Flag = 'TIME_IMPLAUSIBLE'; Facts = @{ system = @{ time = @{ implausible = $true } } } }
        @{ Flag = 'W32TIME_NOSYNC'; Facts = @{ system = @{ time = @{ ntp_type = 'NoSync' } } } }
        @{ Flag = 'TEMP_PROFILE'; Facts = @{ system = @{ prof = @{ temp_profile = $false; bak_keys = @('S-1-5-21-1-2-3-1001.bak'); temp_ok = $true } } } }
        @{ Flag = 'TEMP_DIR_MISSING'; Facts = @{ system = @{ prof = @{ temp_ok = $false } } } }
        @{ Flag = 'RESTORE_OFF'; Facts = @{ system = @{ rp = @{ on = $false } } } }
        @{ Flag = 'DEVICE_ERRORS'; Facts = @{ system = @{ dev = @(@{ n = 'USB'; code = 43 }) } } }
        @{ Flag = 'APPX_BROKEN'; Facts = @{ system = @{ appx = @(@{ n = 'Microsoft.Photos'; st = 'Modified' }) } } }
        @{ Flag = 'C_FREE_CRITICAL'; Facts = @{ disk = @{ vol = @(@{ l = 'C'; sys = $true; tool = $false; size_gb = 100; free_gb = 1.5; health = 'Healthy'; op = 'OK' }) } } }
        @{ Flag = 'C_FREE_LOW'; Facts = @{ disk = @{ vol = @(@{ l = 'C'; sys = $true; tool = $false; size_gb = 100; free_gb = 8; health = 'Healthy'; op = 'OK' }) } } }
        @{ Flag = 'VOLUME_NOT_HEALTHY'; Facts = @{ disk = @{ vol = @(@{ l = 'D'; sys = $false; tool = $false; size_gb = 100; free_gb = 50; health = 'Warning'; op = 'OK' }) } } }
        @{ Flag = 'DISK_UNHEALTHY'; Facts = @{ disk = @{ phys = @(@{ name = 'SSD'; health = 'Warning' }) } } }
        @{ Flag = 'NO_ADAPTER_UP'; Facts = @{ network = @{ ad = @(@{ n = 'Ethernet'; st = 'Disconnected'; hw = $true; vpn = $false }) } } }
        @{ Flag = 'ADAPTER_DISABLED'; Facts = @{ network = @{ ad = @(@{ n = 'Ethernet'; st = 'Disabled'; hw = $true; vpn = $false }) } } }
        @{ Flag = 'APIPA_ADDRESS'; Facts = @{ network = @{ ad = @(@{ n = 'Ethernet'; st = 'Up'; hw = $true; vpn = $false; ip4 = @('169.254.10.2/16') }); gw = '1.1.1.1' } } }
        @{ Flag = 'NO_DEFAULT_GATEWAY'; Facts = @{ network = @{ ad = @(@{ n = 'Ethernet'; st = 'Up'; hw = $true; vpn = $false; ip4 = @('192.168.1.5/24') }); gw = $null } } }
        @{ Flag = 'MANUAL_DNS'; Facts = @{ network = @{ ad = @(@{ n = 'Ethernet'; st = 'Up'; hw = $true; vpn = $false; ip4 = @('192.168.1.5/24'); dns_manual = '8.8.8.8' }); gw = '192.168.1.1' } } }
        @{ Flag = 'VPN_ADAPTER'; Facts = @{ network = @{ ad = @(@{ n = 'WireGuard'; st = 'Disconnected'; hw = $false; vpn = $true }, @{ n = 'Ethernet'; st = 'Up'; vpn = $false }) } } }
        @{ Flag = 'LOOPBACK_FAILS'; Facts = @{ network = @{ test = @{ lo = 'GENERAL_FAILURE' } } } }
        @{ Flag = 'PING_GENERAL_FAILURE'; Facts = @{ network = @{ test = @{ lo = 'SUCCESS'; gw = 'GENERAL_FAILURE' } } } }
        @{ Flag = 'GW_UNREACHABLE'; Facts = @{ network = @{ test = @{ lo = 'SUCCESS'; gw = 'TIMED_OUT' } } } }
        @{ Flag = 'TCP_BLOCKED_LOCAL'; Facts = @{ network = @{ test = @{ lo = 'SUCCESS'; tcp = 'BLOCKED_LOCAL' } } } }
        @{ Flag = 'DNS_FAILS_NET_OK'; Facts = @{ network = @{ test = @{ lo = 'SUCCESS'; gw = 'SUCCESS'; ext = 'SUCCESS'; dns = 'TIMEOUT'; tcp = 'CONNECTED' } } } }
        @{ Flag = 'ONLY_DNS_WORKS'; Facts = @{ network = @{ test = @{ lo = 'SUCCESS'; gw = 'GENERAL_FAILURE'; ext = 'GENERAL_FAILURE'; dns = 'RESOLVED'; tcp = 'BLOCKED_LOCAL' } } } }
        @{ Flag = 'PROXY_USER_SET'; Facts = @{ network = @{ proxy = @{ user = 1; winhttp = 'DIRECT' } } } }
        @{ Flag = 'PROXY_WINHTTP_SET'; Facts = @{ network = @{ proxy = @{ user = 0; winhttp = 'PROXY' } } } }
        @{ Flag = 'HOSTS_MODIFIED'; Facts = @{ network = @{ hosts = 3 } } }
        @{ Flag = 'SPLIT_DEFAULT_ROUTE'; Facts = @{ network = @{ split = 2 } } }
        @{ Flag = 'NON_MS_LSP'; Facts = @{ network = @{ lsp = @('C:\x\vpnlsp.dll') } } }
        @{ Flag = 'NON_MS_NDIS_FILTER'; Facts = @{ network = @{ ndis = @('Some VPN Filter') } } }
        @{ Flag = 'WLAN_RADIO_OFF'; Facts = @{ network = @{ radio = @(@{ k = 'WiFi'; s = 'Off' }) } } }
        @{ Flag = 'WLANSVC_STOPPED'; Facts = @{ network = @{ wlansvc = 'Stopped'; ad = @(@{ n = 'WLAN'; st = 'Disconnected'; wifi = $true; vpn = $false }) } } }
        @{ Flag = 'FIREWALL_OFF'; Facts = @{ security = @{ fw = @(@{ p = 'Public'; on = 'False'; out = 'Allow' }) } } }
        @{ Flag = 'FIREWALL_OUTBOUND_BLOCK'; Facts = @{ security = @{ fw = @(@{ p = 'Public'; on = 'True'; out = 'Block' }) } } }
        @{ Flag = 'MDE_ONBOARDED'; Facts = @{ security = @{ mde = @{ onboarded = $true; iso_hint = $false } } } }
        @{ Flag = 'MDE_ISOLATION_SUSPECT'; Facts = @{ security = @{ mde = @{ onboarded = $true; iso_hint = $true } } } }
        @{ Flag = 'DEFENDER_RTP_OFF'; Facts = @{ security = @{ av = @{ mode = 'Normal'; rtp = $false; sig_age_d = 0; threats30d = 0; products = @('Windows Defender') } } } }
        @{ Flag = 'DEFENDER_SIG_OLD'; Facts = @{ security = @{ av = @{ mode = 'Normal'; rtp = $true; sig_age_d = 12; threats30d = 0; products = @('Windows Defender') } } } }
        @{ Flag = 'DEFENDER_THREATS'; Facts = @{ security = @{ av = @{ mode = 'Normal'; rtp = $true; sig_age_d = 0; threats30d = 2; products = @('Windows Defender') } } } }
        @{ Flag = 'NO_ACTIVE_AV'; Facts = @{ security = @{ av = @{ mode = ''; rtp = $null; products = @() } } } }
        @{ Flag = 'BITLOCKER_ON'; Facts = @{ security = @{ bl = @{ status = 'FullyEncrypted'; prot = 'On' } } } }
        @{ Flag = 'BITLOCKER_SUSPENDED'; Facts = @{ security = @{ bl = @{ status = 'FullyEncrypted'; prot = 'Off' } } } }
        @{ Flag = 'MANY_AUTOSTARTS'; Facts = @{ performance = @{ autostart = 22 } } }
        @{ Flag = 'SPOOLER_STOPPED'; Facts = @{ printer = @{ spooler = 'Stopped'; printers = @() } } }
        @{ Flag = 'PRINTER_OFFLINE'; Facts = @{ printer = @{ spooler = 'Running'; printers = @(@{ n = 'HP'; def = $true; offline = $true; stuck = 0 }) } } }
        @{ Flag = 'PRINT_JOBS_STUCK'; Facts = @{ printer = @{ spooler = 'Running'; printers = @(@{ n = 'HP'; def = $true; offline = $false; stuck = 2 }) } } }
        @{ Flag = 'AUDIO_SERVICE_STOPPED'; Facts = @{ audio = @{ svc = @(@{ n = 'Audiosrv'; st = 'Stopped' }) } } }
        @{ Flag = 'AUDIO_NO_ENDPOINT'; Facts = @{ audio = @{ svc = @(); endpoints = @(@{ n = 'Speakers'; st = 'Unknown' }) } } }
        @{ Flag = 'AUDIO_MUTED'; Facts = @{ audio = @{ mute = $true; vol_pct = 50 } } }
        @{ Flag = 'AUDIO_VOLUME_LOW'; Facts = @{ audio = @{ mute = $false; vol_pct = 2 } } }
        @{ Flag = 'WU_SERVICE_DISABLED'; Facts = @{ update = @{ svc = @(@{ n = 'wuauserv'; st = 'Stopped'; start = 'Disabled' }) } } }
        @{ Flag = 'WU_ERRORS'; Facts = @{ update = @{ fail_30d = 4 } } }
        @{ Flag = 'CRASHES'; Facts = @{ events = @{ known = @{ unexpected_shutdown = 1 } } } }
        @{ Flag = 'DISK_ERRORS_EVENTS'; Facts = @{ events = @{ known = @{ disk = 3 } } } }
        @{ Flag = 'WHEA_ERRORS'; Facts = @{ events = @{ known = @{ whea_fatal = 1 } } } }
        @{ Flag = 'DISPLAY_TDR'; Facts = @{ events = @{ known = @{ tdr = 2 } } } }
        @{ Flag = 'APP_CRASHES'; Facts = @{ events = @{ known = @{ app_crash = 9 } } } }
    )
}

BeforeAll {
    $libDir = Join-Path (Join-Path (Join-Path $PSScriptRoot '..') 'src') 'lib'
    . (Join-Path $libDir 'Toolbox.ps1')
    . (Join-Path $libDir 'Diagnose.ps1')
    $script:knownCodes = @((Get-PnhFindingCatalog).Keys)

    # The example situation from the research draft: ping "General failure", only DNS goes out,
    # device onboarded to Defender for Endpoint.
    $script:example = @{
        system      = @{
            meta = @{ admin = $true; other_user = $false }
            os   = @{ uptime_h = 12.9; pending_reboot = @(); domain = $false; entra = $false; mdm = $false; server = $false }
            time = @{ implausible = $false; ntp_type = 'NTP' }
            prof = @{ temp_profile = $false; bak_keys = @(); temp_ok = $true }
            rp   = @{ on = $false; last = $null }
            svc  = @(); dev = @(); appx = @()
        }
        network     = @{
            ad    = @(
                @{ n = 'Ethernet 3'; st = 'Up'; hw = $true; wifi = $false; vpn = $false; ip4 = @('192.168.1.20/24'); dns_manual = $null },
                @{ n = 'WLAN'; st = 'Disconnected'; hw = $true; wifi = $true; vpn = $false; ip4 = @(); dns_manual = $null })
            gw    = '192.168.1.1'
            test  = @{ lo = 'SUCCESS'; gw = 'GENERAL_FAILURE'; ext = 'GENERAL_FAILURE'; dns = 'RESOLVED'; tcp = 'BLOCKED_LOCAL' }
            proxy = @{ user = 0; server = $null; pac = $null; winhttp = 'DIRECT' }
            hosts = 0; vpn = @(); split = 0; nrpt = 0; lsp = @(); ndis = @()
            radio = @(@{ k = 'WiFi'; s = 'On' }, @{ k = 'Bluetooth'; s = 'On' }); wlansvc = 'Running'
        }
        security    = @{
            av  = @{ mode = 'Normal'; rtp = $true; sig_age_d = 0; threats30d = 0; products = @('Windows Defender') }
            fw  = @(@{ p = 'Domain'; on = 'True'; out = 'Allow' }, @{ p = 'Private'; on = 'True'; out = 'Allow' }, @{ p = 'Public'; on = 'True'; out = 'Allow' })
            mde = @{ onboarded = $true; sense = 'Running'; org = '00000000-0000-0000-0000-000000000000'; iso_hint = $false }
            bl  = @{ status = 'FullyEncrypted'; prot = 'On'; pct = 100; protectors = @('Tpm', 'RecoveryPassword') }
        }
        disk        = @{
            vol  = @(@{ l = 'C'; sys = $true; tool = $false; size_gb = 475.8; free_gb = 212.4; health = 'Healthy'; op = 'OK' },
                @{ l = 'E'; sys = $false; tool = $true; size_gb = 931.5; free_gb = 3; health = 'Healthy'; op = 'OK' })
            phys = @(@{ name = 'SAMSUNG'; health = 'Healthy' })
        }
        performance = @{ uptime_h = 12.9; autostart = 9 }
        printer     = @{ spooler = 'Running'; printers = @(@{ n = 'Microsoft Print to PDF'; def = $true; offline = $false; stuck = 0 }) }
        audio       = @{ svc = @(@{ n = 'Audiosrv'; st = 'Running' }); endpoints = @(@{ n = 'Speakers'; st = 'OK' }); vol_pct = 40; mute = $false }
        update      = @{ svc = @(@{ n = 'wuauserv'; st = 'Stopped'; start = 'Manual' }); fail_30d = 0 }
        display     = @{ adapters = @(@{ n = 'Intel'; cm_err = 0; basic = $false }) }
        events      = @{ days = 7; known = @{ unexpected_shutdown = 0; bugcheck = 0; disk = 0; ntfs = 0; tdr = 0; whea_fatal = 0; whea_corrected = 5; profile_temp = 0; app_crash = 1 } }
    }
}

Describe 'Get-PnhDiagnoseFlags' {
    It 'reproduces the findings of the draft example exactly' {
        $f = @(Get-PnhDiagnoseFlags -Facts $script:example) | Sort-Object
        $f | Should -Be (@('PING_GENERAL_FAILURE', 'TCP_BLOCKED_LOCAL', 'ONLY_DNS_WORKS', 'MDE_ONBOARDED', 'MDE_ISOLATION_SUSPECT', 'RESTORE_OFF', 'BITLOCKER_ON') | Sort-Object)
    }
    It 'works the same with parsed JSON (PSCustomObjects)' {
        $json = ConvertTo-Json -InputObject $script:example -Depth 10
        $f = @(Get-PnhDiagnoseFlags -Facts (ConvertFrom-Json -InputObject $json)) | Sort-Object
        $f | Should -Be (@(Get-PnhDiagnoseFlags -Facts $script:example) | Sort-Object)
    }
    It 'returns a flat string array' {
        $f = Get-PnhDiagnoseFlags -Facts $script:example
        , $f | Should -BeOfType [System.Array]
        foreach ($x in $f) { $x | Should -BeOfType [string] }
    }
    It 'missing facts produce no findings' {
        @(Get-PnhDiagnoseFlags -Facts @{}).Count | Should -Be 0
        @(Get-PnhDiagnoseFlags -Facts @{ system = @{}; network = @{ ad = @() }; audio = @{} }).Count | Should -Be 0
    }
    It '<Flag> is defined in findings.json' -ForEach $ruleCases {
        $script:knownCodes | Should -Contain $Flag
    }
    It 'sets <Flag>' -ForEach $ruleCases {
        @(Get-PnhDiagnoseFlags -Facts $Facts) | Should -Contain $Flag
    }
    It 'does not flag the rescue drive or a healthy system drive' {
        $f = @(Get-PnhDiagnoseFlags -Facts $script:example)
        $f | Should -Not -Contain 'C_FREE_LOW'
        $f | Should -Not -Contain 'C_FREE_CRITICAL'
    }
    It 'treats corrected hardware errors as noise and fatal ones as a finding' {
        @(Get-PnhDiagnoseFlags -Facts @{ events = @{ known = @{ whea_corrected = 50 } } }) | Should -Not -Contain 'WHEA_ERRORS'
    }
    It 'does not report RESTORE_OFF on Windows Server' {
        @(Get-PnhDiagnoseFlags -Facts @{ system = @{ os = @{ server = $true }; rp = @{ on = $false } } }) | Should -Not -Contain 'RESTORE_OFF'
    }
    It 'does not flag NO_ACTIVE_AV when another antivirus is active' {
        @(Get-PnhDiagnoseFlags -Facts @{ security = @{ av = @{ mode = 'Passive'; rtp = $false; products = @('ESET Security', 'Windows Defender') } } }) | Should -Not -Contain 'NO_ACTIVE_AV'
    }
}

Describe 'Test-PnhDiskSpaceLow' {
    It '<Free> GB free of <Size> GB is <Want>' -ForEach @(
        @{ Free = 1; Size = 500; Want = 'critical' }
        @{ Free = 5; Size = 500; Want = 'low' }
        @{ Free = 12; Size = 500; Want = 'low' }
        @{ Free = 60; Size = 1000; Want = 'ok' }
        @{ Free = 12; Size = 64; Want = 'ok' }
        @{ Free = 200; Size = 500; Want = 'ok' }
    ) {
        Test-PnhDiskSpaceLow -FreeBytes ($Free * 1GB) -SizeBytes ($Size * 1GB) | Should -Be $Want
    }
}

Describe 'Invoke-PnhDiagnose' {
    It 'always runs system first, returns facts, flags, duration and errors' {
        Mock Get-PnhSectionFacts { $script:example[$Name] }
        $d = Invoke-PnhDiagnose -Sections network, security
        @($d.Facts.Keys) | Should -Be @('system', 'network', 'security')
        $d.Flags | Should -Contain 'MDE_ISOLATION_SUSPECT'
        $d.DurationMs | Should -BeOfType [int]
        $d.PSObject.Properties.Name | Should -Contain 'Errors'
        Should -Invoke Get-PnhSectionFacts -Times 3 -Exactly
    }
    It 'runs all ten sections by default' {
        Mock Get-PnhSectionFacts { @{} }
        $d = Invoke-PnhDiagnose
        @($d.Facts.Keys).Count | Should -Be 10
    }
    It 'reports unknown sections instead of failing' {
        Mock Get-PnhSectionFacts { @{} }
        $d = Invoke-PnhDiagnose -Sections nonsense
        $d.Errors.Contains('section.nonsense') | Should -BeTrue
    }
    It 'a failing section is recorded and the others still run' {
        Mock Get-PnhSectionFacts { if ($Name -eq 'network') { throw 'broken' } else { $script:example[$Name] } }
        $d = Invoke-PnhDiagnose -Sections network, security
        $d.Errors['network'] | Should -Be 'broken'
        $d.Facts.Contains('security') | Should -BeTrue
    }
    It 'skips sections when the time budget is used up' {
        Mock Get-PnhSectionFacts { @{} }
        $d = Invoke-PnhDiagnose -Sections network -BudgetSeconds -1
        $d.Errors['network'] | Should -Match 'time budget'
    }
    It 'serializes to compact JSON' {
        Mock Get-PnhSectionFacts { $script:example[$Name] }
        $d = Invoke-PnhDiagnose
        $json = ConvertTo-Json -InputObject $d -Depth 10 -Compress
        $json.Length | Should -BeLessThan 12000
        (ConvertFrom-Json -InputObject $json).Flags | Should -Contain 'BITLOCKER_ON'
    }
    It 'Invoke-PnhProbe records errors and returns nothing' {
        $err = [ordered]@{}
        $r = Invoke-PnhProbe 'x.y' $err { throw 'nope' }
        $r | Should -BeNullOrEmpty
        $err['x.y'] | Should -Be 'nope'
        $r2 = Invoke-PnhProbe 'x.z' $err { Write-Error 'non-terminating'; 'after' }
        $r2 | Should -BeNullOrEmpty
        $err.Contains('x.z') | Should -BeTrue
    }
}

Describe 'Get-PnhCheckVerdict' {
    It 'network passes with router, TCP 443 and DNS' {
        (Get-PnhCheckVerdict -Name network -Data @{ GatewayPing = 'SUCCESS'; Tcp443 = 'CONNECTED'; Dns = 'RESOLVED' }).Passed | Should -BeTrue
    }
    It 'network passes when the router ignores ping but the internet works' {
        (Get-PnhCheckVerdict -Name network -Data @{ GatewayPing = 'TIMED_OUT'; Tcp443 = 'CONNECTED'; Dns = 'RESOLVED' }).Passed | Should -BeTrue
    }
    It 'network fails on <Case>' -ForEach @(
        @{ Case = 'general failure'; D = @{ GatewayPing = 'GENERAL_FAILURE'; Tcp443 = 'BLOCKED_LOCAL'; Dns = 'RESOLVED' } }
        @{ Case = 'no DNS'; D = @{ GatewayPing = 'SUCCESS'; Tcp443 = 'CONNECTED'; Dns = 'TIMEOUT' } }
        @{ Case = 'NXDOMAIN'; D = @{ GatewayPing = 'SUCCESS'; Tcp443 = 'CONNECTED'; Dns = 'NXDOMAIN' } }
        @{ Case = 'no internet'; D = @{ GatewayPing = 'SUCCESS'; Tcp443 = 'TIMEOUT'; Dns = 'RESOLVED' } }
        @{ Case = 'no gateway'; D = @{ GatewayPing = 'NO_GATEWAY'; Tcp443 = 'NET_UNREACHABLE'; Dns = 'FAILED' } }
    ) {
        $v = Get-PnhCheckVerdict -Name network -Data $D
        $v.Passed | Should -BeFalse
        $v.Summary | Should -Match 'Not working'
    }
    It 'printer: spooler running and no stuck job' {
        (Get-PnhCheckVerdict -Name printer -Data @{ SpoolerStatus = 'Running'; StuckJobs = 0 }).Passed | Should -BeTrue
        (Get-PnhCheckVerdict -Name printer -Data @{ SpoolerStatus = 'Running'; StuckJobs = 1 }).Passed | Should -BeFalse
        (Get-PnhCheckVerdict -Name printer -Data @{ SpoolerStatus = 'Stopped'; SpoolerStartType = 'Disabled'; StuckJobs = 0 }).Passed | Should -BeFalse
    }
    It 'disk: free space above the threshold' {
        (Get-PnhCheckVerdict -Name disk -Data @{ FreeBytes = 50GB; SizeBytes = 500GB }).Passed | Should -BeTrue
        (Get-PnhCheckVerdict -Name disk -Data @{ FreeBytes = 3GB; SizeBytes = 500GB }).Passed | Should -BeFalse
    }
    It 'sound: services, endpoint, not muted, volume' {
        $ok = @{ Services = @{ Audiosrv = 'Running'; AudioEndpointBuilder = 'Running' }; EndpointsOk = 1; Volume = 0.4; Mute = $false }
        (Get-PnhCheckVerdict -Name sound -Data $ok).Passed | Should -BeTrue
        $muted = $ok.Clone(); $muted.Mute = $true
        (Get-PnhCheckVerdict -Name sound -Data $muted).Passed | Should -BeFalse
        $unknown = $ok.Clone(); $unknown.Volume = $null; $unknown.Mute = $null
        (Get-PnhCheckVerdict -Name sound -Data $unknown).Passed | Should -BeTrue
        $stopped = $ok.Clone(); $stopped.Services = @{ Audiosrv = 'Stopped'; AudioEndpointBuilder = 'Running' }
        (Get-PnhCheckVerdict -Name sound -Data $stopped).Passed | Should -BeFalse
    }
    It 'update: services allowed, CryptSvc running, no pending restart' {
        $ok = @{ Services = @{ wuauserv = @{ Status = 'Stopped'; StartType = 'Manual' }; BITS = @{ Status = 'Stopped'; StartType = 'Manual' }; CryptSvc = @{ Status = 'Running'; StartType = 'Automatic' } }; PendingReboot = $false }
        (Get-PnhCheckVerdict -Name update -Data $ok).Passed | Should -BeTrue
        $pend = $ok.Clone(); $pend.PendingReboot = $true
        (Get-PnhCheckVerdict -Name update -Data $pend).Passed | Should -BeFalse
        $dis = $ok.Clone(); $dis.Services = @{ wuauserv = @{ Status = 'Stopped'; StartType = 'Disabled' }; BITS = @{ StartType = 'Manual' }; CryptSvc = @{ Status = 'Running' } }
        (Get-PnhCheckVerdict -Name update -Data $dis).Passed | Should -BeFalse
    }
    It 'display: real driver without problem code' {
        (Get-PnhCheckVerdict -Name display -Data @{ Adapters = @(@{ Name = 'Intel'; Problem = 0; Basic = $false }) }).Passed | Should -BeTrue
        (Get-PnhCheckVerdict -Name display -Data @{ Adapters = @(@{ Name = 'Basic'; Problem = 0; Basic = $true }) }).Passed | Should -BeFalse
        (Get-PnhCheckVerdict -Name display -Data @{ Adapters = @(@{ Name = 'Intel'; Problem = 43; Basic = $false }) }).Passed | Should -BeFalse
        (Get-PnhCheckVerdict -Name display -Data @{ Adapters = @() }).Passed | Should -BeFalse
    }
    It 'slow: restarted recently, nothing pending, enough space' {
        (Get-PnhCheckVerdict -Name slow -Data @{ UptimeHours = 5; PendingReboot = $false; FreeBytes = 100GB; SizeBytes = 500GB }).Passed | Should -BeTrue
        (Get-PnhCheckVerdict -Name slow -Data @{ UptimeHours = 500; PendingReboot = $false; FreeBytes = 100GB; SizeBytes = 500GB }).Passed | Should -BeFalse
    }
    It 'other: core services, temp folder, profile, Explorer' {
        (Get-PnhCheckVerdict -Name other -Data @{ StoppedServices = @(); TempOk = $true; TempProfile = $false; ExplorerRunning = $true }).Passed | Should -BeTrue
        (Get-PnhCheckVerdict -Name other -Data @{ StoppedServices = @('ProfSvc'); TempOk = $true; TempProfile = $false; ExplorerRunning = $true }).Passed | Should -BeFalse
    }
    It 'Passed is always a boolean' {
        (Get-PnhCheckVerdict -Name network -Data @{}).Passed | Should -BeOfType [bool]
        (Get-PnhCheckVerdict -Name other -Data @{}).Passed | Should -BeOfType [bool]
    }
}

Describe 'Invoke-PnhSuccessCheck' {
    BeforeAll {
        $script:good = @{
            network = @{ GatewayPing = 'SUCCESS'; Tcp443 = 'CONNECTED'; Dns = 'RESOLVED' }
            disk    = @{ FreeBytes = 100GB; SizeBytes = 500GB }
            update  = @{ Services = @{ wuauserv = @{ StartType = 'Manual' }; BITS = @{ StartType = 'Manual' }; CryptSvc = @{ Status = 'Running' } }; PendingReboot = $false }
            other   = @{ StoppedServices = @(); TempOk = $true; TempProfile = $false; ExplorerRunning = $true }
            printer = @{ SpoolerStatus = 'Stopped'; StuckJobs = 0 }
            sound   = @{ Services = @{ Audiosrv = 'Running'; AudioEndpointBuilder = 'Running' }; EndpointsOk = 1 }
            display = @{ Adapters = @(@{ Problem = 0; Basic = $false }) }
            slow    = @{ UptimeHours = 1; PendingReboot = $false; FreeBytes = 100GB; SizeBytes = 500GB }
        }
    }
    It 'unknown ids fail cleanly' {
        $r = Invoke-PnhSuccessCheck -Id 'check.nonsense'
        $r.Passed | Should -BeFalse
        $r.Summary | Should -Match 'Unknown'
    }
    It 'evaluates <_> from the probe data' -ForEach @('check.network', 'check.disk', 'check.update', 'check.other', 'check.printer', 'check.sound', 'check.display', 'check.slow') {
        Mock Test-PnhIsWindows { $true }
        Mock Get-PnhCheckProbe { $script:good[$Name] }
        $r = Invoke-PnhSuccessCheck -Id $_
        $r.Passed | Should -BeOfType [bool]
        $r.Summary | Should -Not -BeNullOrEmpty
    }
    It 'check.all passes when network, disk, update and core functions pass (printer only reported)' {
        Mock Test-PnhIsWindows { $true }
        Mock Get-PnhCheckProbe { $script:good[$Name] }
        $r = Invoke-PnhSuccessCheck -Id 'check.all'
        $r.Passed | Should -BeTrue
        $r.Details['printer'].Passed | Should -BeFalse
    }
    It 'check.all fails when the network fails' {
        Mock Test-PnhIsWindows { $true }
        Mock Get-PnhCheckProbe { if ($Name -eq 'network') { @{ GatewayPing = 'GENERAL_FAILURE'; Tcp443 = 'BLOCKED_LOCAL'; Dns = 'RESOLVED' } } else { $script:good[$Name] } }
        $r = Invoke-PnhSuccessCheck -Id 'check.all'
        $r.Passed | Should -BeFalse
        $r.Summary | Should -Match 'network'
    }
    It 'a probe that throws gives Passed = false, not an exception' {
        Mock Test-PnhIsWindows { $true }
        Mock Get-PnhCheckProbe { throw 'no WMI' }
        $r = Invoke-PnhSuccessCheck -Id 'check.printer'
        $r.Passed | Should -BeFalse
        $r.Summary | Should -Match 'no WMI'
    }
    It 'every check id referenced by categories.json exists' {
        foreach ($c in @(Get-PnhCategoryCatalog)) { Get-PnhSuccessCheckIds | Should -Contain $c.success }
    }
}

Describe 'Live Windows' {
    It 'Invoke-PnhDiagnose runs read-only in under 30 seconds (Windows only)' -Skip:(-not $onWindows) {
        $d = Invoke-PnhDiagnose
        $d.DurationMs | Should -BeLessThan 30000
        $d.Facts.system.os.build | Should -Not -BeNullOrEmpty
        foreach ($f in $d.Flags) { $script:knownCodes | Should -Contain $f }
    }
    It 'every success check returns a boolean on a real PC (Windows only)' -Skip:(-not $onWindows) {
        foreach ($id in Get-PnhSuccessCheckIds) { (Invoke-PnhSuccessCheck -Id $id).Passed | Should -BeOfType [bool] }
    }
}
