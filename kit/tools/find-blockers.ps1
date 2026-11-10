<#
  find-blockers.ps1 - read-only deep diagnosis: what blocks network traffic on this PC?
  Run as Administrator in Windows PowerShell 5.1. Changes nothing.
  Prints a SUMMARY first, then details. The full report is also saved as report-<time>.txt in -OutDir.
#>
param([string]$OutDir = '')
$ErrorActionPreference = 'Continue'
if (-not $OutDir) { $OutDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'work' }
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$report = Join-Path $OutDir ('report-' + $stamp + '.txt')
$tmp = Join-Path $env:TEMP ('pnh-wfp-' + $stamp)
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

$summary = New-Object System.Collections.Generic.List[string]
$detail = New-Object System.Collections.Generic.List[string]
function S([string]$t) { $summary.Add($t) }
function D([string]$t) { $detail.Add($t) }
function Cut([string]$t, [int]$n) { if ($null -eq $t) { return '' }; $t = ($t -replace '\s+', ' ').Trim(); if ($t.Length -gt $n) { return $t.Substring(0, $n) + '...' }; return $t }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
S ('Computer: {0} | Windows {1} | Admin: {2} | {3}' -f $env:COMPUTERNAME, [Environment]::OSVersion.Version, $isAdmin, (Get-Date -Format 'yyyy-MM-dd HH:mm'))

# ---------- 1. Microsoft Defender for Endpoint (device isolation cannot be lifted locally) ----------
D '===== 1. Microsoft Defender for Endpoint ====='
$mdeKey = 'HKLM:\SOFTWARE\Microsoft\Windows Advanced Threat Protection'
$st = Get-ItemProperty -Path ($mdeKey + '\Status') -ErrorAction SilentlyContinue
$onboarded = ($st -and $st.OnboardingState -eq 1)
$orgId = ''
if ($st) { $orgId = [string]$st.OrgId }
$sense = Get-Service -Name Sense -ErrorAction SilentlyContinue
$senseState = 'not installed'
if ($sense) { $senseState = [string]$sense.Status }
$regHint = $false
try { $regHint = [bool](Get-ItemProperty -Path $mdeKey -Name 'DisableEnterpriseAuthProxyValueToRestoreAfterIsolation' -ErrorAction Stop) } catch { }
$isoHits = @()
try {
    $isoHits = @(Get-WinEvent -LogName 'Microsoft-Windows-SENSE/Operational' -MaxEvents 3000 -ErrorAction Stop |
        Where-Object { ($_.Message -match 'isolat') -or (@($_.Properties | ForEach-Object { [string]$_.Value }) -match 'isolat') } |
        Select-Object -First 15)
} catch { D ('SENSE log not readable: ' + $_.Exception.Message) }
$verdict = 'NOT_ONBOARDED'
if ($onboarded) {
    if ($regHint -or $isoHits.Count -gt 0) { $verdict = 'ISOLATION_LIKELY' } else { $verdict = 'ISOLATION_POSSIBLE' }
} elseif ($regHint -or $isoHits.Count -gt 0) { $verdict = 'ISOLATION_LIKELY' }
S ('MDE verdict: {0} | onboarded={1} | OrgId={2} | Sense service={3} | registry hint={4} | isolation log entries={5}' -f $verdict, $onboarded, $orgId, $senseState, $regHint, $isoHits.Count)
if ($isoHits.Count -gt 0) {
    S ('!! Newest isolation entry {0}: {1}' -f $isoHits[0].TimeCreated, (Cut $isoHits[0].Message 160))
    foreach ($e in $isoHits) { D ('{0} | Id {1} | {2}' -f $e.TimeCreated, $e.Id, (Cut $e.Message 300)) }
}
try {
    $np = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = 1125, 1126 } -MaxEvents 20 -ErrorAction Stop)
    if ($np.Count) { S ('Defender Network Protection events (1125/1126): {0}, newest {1}' -f $np.Count, $np[0].TimeCreated); foreach ($e in $np) { D ('NP {0} | {1}' -f $e.TimeCreated, (Cut $e.Message 250)) } }
} catch { }

# ---------- 2. Windows Filtering Platform: who blocks outbound traffic? ----------
D ''; D '===== 2. Windows Filtering Platform (WFP) blocking filters ====='
$providers = @{}
$filtersXml = Join-Path $tmp 'filters.xml'
if ($isAdmin) {
    & netsh.exe wfp show filters file="$filtersXml" | Out-Null
    & netsh.exe wfp show state file="$(Join-Path $tmp 'wfpstate.xml')" | Out-Null
}
if (Test-Path -LiteralPath $filtersXml) {
    try {
        [xml]$fx = Get-Content -LiteralPath $filtersXml -Raw
        $foreign = @()
        foreach ($p in @($fx.SelectNodes('/wfpdiag/providers/item'))) {
            $k = [string]$p.SelectSingleNode('providerKey').InnerText
            $n = ''; $de = ''; $sv = ''
            $x = $p.SelectSingleNode('displayData/name'); if ($x) { $n = [string]$x.InnerText }
            $x = $p.SelectSingleNode('displayData/description'); if ($x) { $de = [string]$x.InnerText }
            $x = $p.SelectSingleNode('serviceName'); if ($x) { $sv = [string]$x.InnerText }
            $label = '{0} "{1}" service={2} ({3})' -f $k, (Cut $n 50), $sv, (Cut $de 90)
            if ($k) { $providers[$k] = $label }
            D ('provider: ' + $label)
            if (($k -notlike 'FWPM_PROVIDER_*') -and (($n + ' ' + $de) -notmatch 'Microsoft|Windows')) { $foreign += $label }
        }
        if ($foreign.Count) { S ('!! WFP providers that are NOT from Microsoft/Windows: ' + ($foreign -join ' || ')) }
        else { S ('WFP providers registered: {0}, all from Microsoft/Windows' -f $providers.Count) }
        $items = @($fx.SelectNodes('/wfpdiag/filters/item'))
        $blocking = @()
        foreach ($it in $items) {
            $layer = ''; $atype = ''; $pk = ''; $fname = ''
            $x = $it.SelectSingleNode('layerKey'); if ($x) { $layer = [string]$x.InnerText }
            $x = $it.SelectSingleNode('action/type'); if ($x) { $atype = [string]$x.InnerText }
            $x = $it.SelectSingleNode('providerKey'); if ($x) { $pk = [string]$x.InnerText }
            $x = $it.SelectSingleNode('displayData/name'); if ($x) { $fname = [string]$x.InnerText }
            if ($atype -notmatch 'BLOCK|CALLOUT') { continue }
            if ($layer -notmatch 'OUTBOUND|ALE_AUTH_CONNECT|ALE_RESOURCE_ASSIGNMENT|ALE_FLOW_ESTABLISHED') { continue }
            $pn = '(no provider)'
            if ($pk) { if ($providers.ContainsKey($pk)) { $pn = $providers[$pk] } else { $pn = $pk } }
            $blocking += [pscustomobject]@{ Provider = $pn; Name = $fname; Layer = $layer; Action = $atype }
        }
        D ('Filters total: {0} | outbound BLOCK/CALLOUT filters: {1}' -f $items.Count, $blocking.Count)
        $groups = @($blocking | Group-Object Provider | Sort-Object Count -Descending)
        S ('WFP outbound BLOCK/CALLOUT filters: {0} of {1} filters. By provider (a normal Windows 11 PC has about 50, all from FWPM_PROVIDER_MPSSVC_*):' -f $blocking.Count, $items.Count)
        foreach ($g in $groups) {
            $names = @($g.Group | Group-Object Name | Sort-Object Count -Descending | Select-Object -First 4 | ForEach-Object { (Cut $_.Name 60) + ' x' + $_.Count })
            S ('   {0,4} x {1}  filters: [{2}]' -f $g.Count, (Cut $g.Name 150), ($names -join '; '))
        }
        foreach ($b in ($blocking | Select-Object -First 300)) { D ('{0} | {1} | {2} | {3}' -f (Cut $b.Provider 60), (Cut $b.Name 70), $b.Layer, $b.Action) }
    } catch { S ('WFP filters could not be parsed: ' + $_.Exception.Message) }
} else { S 'WFP filters: not available (needs Administrator)' }
S ('Raw WFP dumps for searching (filters.xml, wfpstate.xml): {0}' -f $tmp)

# ---------- 3. Third-party network filter drivers bound to adapters (NDIS lightweight filters) ----------
D ''; D '===== 3. Adapter bindings that are not from Microsoft ====='
try {
    $b3 = @(Get-NetAdapterBinding -IncludeHidden -AllBindings -ErrorAction Stop | Where-Object { $_.Enabled -and $_.ComponentID -notlike 'ms_*' })
    $u = @($b3 | Group-Object ComponentID, DisplayName | ForEach-Object { $_.Name + ' (' + $_.Count + ' adapters)' })
    if ($u.Count) { S ('Non-Microsoft adapter bindings (enabled): ' + ($u -join ' | ')) } else { S 'Non-Microsoft adapter bindings: none' }
    foreach ($x in $b3) { D ('{0} | {1} | {2}' -f $x.Name, $x.ComponentID, $x.DisplayName) }
} catch { D ('Get-NetAdapterBinding failed: ' + $_.Exception.Message) }
D '--- netcfg -s n (installed network components) ---'
try { (& netcfg.exe -s n 2>&1) | ForEach-Object { D ([string]$_) } } catch { }

# ---------- 4. Running drivers not signed by Microsoft (WFP callout drivers live here) ----------
D ''; D '===== 4. Running kernel drivers not signed by Microsoft ====='
$nonMs = @()
try {
    foreach ($drv in @(Get-CimInstance Win32_SystemDriver -Filter "State='Running'" -ErrorAction Stop)) {
        $path = [string]$drv.PathName
        if (-not $path) { continue }
        $path = $path -replace '^\\\?\?\\', '' -replace '^\\SystemRoot', $env:SystemRoot
        if ($path -match '^System32\\') { $path = Join-Path $env:SystemRoot $path }
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $sig = Get-AuthenticodeSignature -LiteralPath $path -ErrorAction SilentlyContinue
        $signer = ''
        if ($sig -and $sig.SignerCertificate) { $signer = $sig.SignerCertificate.Subject }
        if ($signer -notmatch 'Microsoft') { $nonMs += [pscustomobject]@{ Name = $drv.Name; Display = $drv.DisplayName; Path = $path; Signer = $signer } }
    }
} catch { D ('Driver scan failed: ' + $_.Exception.Message) }
S ('Running non-Microsoft drivers: {0} -> {1}' -f $nonMs.Count, (($nonMs | ForEach-Object { $_.Name }) -join ', '))
foreach ($n in $nonMs) { D ('{0} | {1} | {2} | {3}' -f $n.Name, (Cut $n.Display 50), $n.Path, (Cut $n.Signer 80)) }

# ---------- 5. Windows Firewall, IPsec, Winsock, proxy, hosts ----------
D ''; D '===== 5. Firewall, IPsec, Winsock, proxy, hosts ====='
try {
    $prof = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop)
    S ('Firewall profiles (active): ' + (($prof | ForEach-Object { '{0}: enabled={1} in={2} out={3}' -f $_.Name, $_.Enabled, $_.DefaultInboundAction, $_.DefaultOutboundAction }) -join ' | '))
    $ob = @(Get-NetFirewallRule -PolicyStore ActiveStore -Enabled True -Direction Outbound -Action Block -ErrorAction SilentlyContinue)
    S ('Enabled outbound BLOCK firewall rules: {0}' -f $ob.Count)
    foreach ($x in ($ob | Select-Object -First 30)) { D ('out-block rule: {0} | {1}' -f $x.DisplayName, $x.PolicyStoreSourceType) }
} catch { D ('Firewall query failed: ' + $_.Exception.Message) }
try {
    $ips = @(Get-NetIPsecRule -PolicyStore ActiveStore -ErrorAction Stop)
    S ('Active IPsec rules: {0}' -f $ips.Count)
    foreach ($x in $ips) { D ('ipsec: {0} | {1} | in={2} out={3}' -f $x.DisplayName, $x.Mode, $x.InboundSecurity, $x.OutboundSecurity) }
} catch { D ('IPsec query failed: ' + $_.Exception.Message) }
try {
    $cat = (& netsh.exe winsock show catalog) -join "`n"
    $paths = @([regex]::Matches($cat, '(?im)^\s*Provider Path:\s*(.+)$') | ForEach-Object { $_.Groups[1].Value.Trim() })
    if ($paths.Count -eq 0) { $paths = @([regex]::Matches($cat, '(?im)^\s*Anbieterpfad:\s*(.+)$') | ForEach-Object { $_.Groups[1].Value.Trim() }) }
    $odd = @($paths | Where-Object { $_ -notmatch 'mswsock\.dll|rsvpsp\.dll|wshqos|NLAapi|napinsp|pnrpnsp|wshbth|winrnr|nlaapi' } | Sort-Object -Unique)
    S ('Winsock catalog entries: {0}, unusual providers: {1}' -f $paths.Count, ($odd -join ', '))
} catch { }
try { D ('WinHTTP proxy: ' + ((& netsh.exe winhttp show proxy) -join ' ')) } catch { }
try {
    $ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop
    D ('User proxy: enabled={0} server={1} autoconfig={2}' -f $ie.ProxyEnable, $ie.ProxyServer, $ie.AutoConfigURL)
} catch { }
try {
    $h = @(Get-Content "$env:SystemRoot\System32\drivers\etc\hosts" -ErrorAction Stop | Where-Object { $_ -match '^\s*[^#\s]' })
    D ('hosts entries: ' + $h.Count); foreach ($x in $h) { D ('  hosts: ' + $x) }
} catch { }

# ---------- 6. Security, VPN and network software that is installed ----------
D ''; D '===== 6. Installed software (security, VPN, network, remote) ====='
$rx = 'vpn|firewall|security|antivir|anti-vir|endpoint|sophos|eset|kaspersky|bitdefender|norton|avast|avg |mcafee|malwarebytes|trend micro|f-secure|panda|comodo|zonealarm|glasswire|simplewall|tinywall|portmaster|safing|zscaler|netskope|cisco|anyconnect|globalprotect|forti|check ?point|nordvpn|proton|mullvad|expressvpn|surfshark|windscribe|wireguard|openvpn|tailscale|zerotier|hamachi|npcap|winpcap|wireshark|killer|smartbyte|nahimic|vmware|virtualbox|docker|rustdesk|anydesk|teamviewer|parsec|tactical|mesh ?agent|netlimiter|adguard|peerblock'
$apps = @()
foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*') {
    $apps += @(Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName })
}
$since = (Get-Date).AddDays(-3).ToString('yyyyMMdd')
$hit = @($apps | Where-Object { $_.DisplayName -match $rx } | Sort-Object DisplayName -Unique)
$new = @($apps | Where-Object { $_.InstallDate -and ([string]$_.InstallDate) -ge $since } | Sort-Object InstallDate -Descending)
S ('Security/VPN/network/remote software: ' + (($hit | ForEach-Object { $_.DisplayName + ' ' + $_.DisplayVersion }) -join ' | '))
S ('Installed or updated in the last 3 days: ' + (($new | ForEach-Object { $_.DisplayName + ' (' + $_.InstallDate + ')' }) -join ' | '))
foreach ($a in $hit) { D ('{0} {1} | {2} | uninstall: {3}' -f $a.DisplayName, $a.DisplayVersion, $a.Publisher, (Cut $a.UninstallString 160)) }

# ---------- 7. What changed since yesterday? ----------
D ''; D '===== 7. Changes since yesterday (services, drivers, updates, installs) ====='
$from = (Get-Date).Date.AddDays(-1)
$ev = @()
try { $ev += @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $from; ProviderName = 'Service Control Manager'; Id = 7045 } -ErrorAction SilentlyContinue) } catch { }
try { $ev += @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $from; ProviderName = 'Microsoft-Windows-WindowsUpdateClient'; Id = 19, 20, 43 } -ErrorAction SilentlyContinue) } catch { }
try { $ev += @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $from; ProviderName = 'Microsoft-Windows-Kernel-PnP'; Id = 400, 410, 430 } -ErrorAction SilentlyContinue | Select-Object -First 40) } catch { }
try { $ev += @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $from; ProviderName = 'MsiInstaller'; Id = 1033, 1034, 11707, 11724 } -ErrorAction SilentlyContinue) } catch { }
try { $ev += @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $from; Level = 1, 2 } -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -match 'Tcpip|NDIS|NetBT|Dhcp|DNS|BFE|mpssvc|WFP|e1d|e2f|i40|ice|Netwtw|rt640|Killer' } | Select-Object -First 40) } catch { }
$ev = @($ev | Sort-Object TimeCreated)
S ('Change events since yesterday: {0} (see section 7)' -f $ev.Count)
foreach ($e in $ev) { D ('{0} | {1} | {2} | {3}' -f $e.TimeCreated.ToString('dd.MM. HH:mm:ss'), $e.ProviderName, $e.Id, (Cut $e.Message 200)) }

# ---------- output ----------
$text = @('===== SUMMARY =====') + $summary + @('', '===== DETAILS =====') + $detail
[System.IO.File]::WriteAllLines($report, [string[]]$text, (New-Object System.Text.UTF8Encoding($false)))
$summary | ForEach-Object { $_ }
''
'Full report: ' + $report
'(Read it with: Get-Content -LiteralPath ''' + $report + ''' | Select-Object -First 200)'
