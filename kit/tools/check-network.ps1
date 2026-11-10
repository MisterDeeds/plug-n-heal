<#
  check-network.ps1 - read-only network check for the repair agent.
  Exit code 0 = the network works: a TCP connection to the internet succeeds and DNS resolves a name.
  Exit code 1 = the network does not work.
  Prints one JSON object with all measurements and a HINT that names the likely family of causes.
  Windows PowerShell 5.1. Changes nothing.
#>
$ErrorActionPreference = 'Continue'
$r = [ordered]@{}
$r.time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

function Get-ErrorText($err) {
    $e = $err.Exception
    $code = ''
    while ($e) {
        if ($e -is [System.Net.Sockets.SocketException]) { $code = 'socket ' + [string]$e.SocketErrorCode }
        elseif (($e -is [System.ComponentModel.Win32Exception]) -and (-not $code)) { $code = 'win32 ' + [string]$e.NativeErrorCode }
        if (-not $e.InnerException) { break }
        $e = $e.InnerException
    }
    if ($code) { return 'ERROR (' + $code + '): ' + $e.Message }
    return 'ERROR: ' + $e.Message
}

function Test-Ping([string]$ip) {
    try {
        $p = New-Object System.Net.NetworkInformation.Ping
        $x = $p.Send($ip, 2000)
        return [string]$x.Status
    } catch {
        return (Get-ErrorText $_)
    }
}

function Test-Tcp([string]$ip, [int]$port) {
    $t = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $t.BeginConnect($ip, $port, $null, $null)
        $done = $iar.AsyncWaitHandle.WaitOne(3000)
        if ($done -and $t.Connected) { return 'Connected' }
        if ($done) {
            try { $t.EndConnect($iar) } catch { return (Get-ErrorText $_) }
        }
        return 'Timeout'
    } catch {
        return (Get-ErrorText $_)
    } finally {
        $t.Close()
    }
}

$route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric, InterfaceMetric | Select-Object -First 1
$gw = $null
if ($route) { $gw = [string]$route.NextHop; $r.gateway_interface = [string]$route.InterfaceAlias }
$r.gateway = $gw

if ($gw) { $r.ping_gateway = Test-Ping $gw } else { $r.ping_gateway = 'no default gateway' }
$r.ping_1_1_1_1 = Test-Ping '1.1.1.1'
$r.tcp_1_1_1_1_443 = Test-Tcp '1.1.1.1' 443
$r.tcp_8_8_8_8_443 = Test-Tcp '8.8.8.8' 443
try {
    $addr = [System.Net.Dns]::GetHostAddresses('www.microsoft.com')
    $r.dns_www_microsoft_com = 'OK ' + $addr[0].IPAddressToString
} catch {
    $r.dns_www_microsoft_com = Get-ErrorText $_
}

$r.adapters_up = @(Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' } |
    ForEach-Object { '{0} | {1} | {2}' -f $_.Name, $_.InterfaceDescription, $_.LinkSpeed })
$r.ipv4_addresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
    ForEach-Object { '{0} | {1}/{2} | state {3} | {4}' -f $_.InterfaceAlias, $_.IPAddress, $_.PrefixLength, $_.AddressState, $_.PrefixOrigin })

$tcpOk = ($r.tcp_1_1_1_1_443 -eq 'Connected') -or ($r.tcp_8_8_8_8_443 -eq 'Connected')
$dnsOk = ([string]$r.dns_www_microsoft_com -like 'OK*')
$passed = $tcpOk -and $dnsOk

$hint = ''
if (-not $passed) {
    $sendRefused = ([string]$r.ping_gateway -like 'ERROR*') -or ([string]$r.ping_1_1_1_1 -like 'ERROR*') -or ([string]$r.tcp_1_1_1_1_443 -like 'ERROR*')
    if (@($r.adapters_up).Count -eq 0) {
        $hint = 'No network adapter is up: adapter disabled, cable unplugged, Wi-Fi not connected or driver missing.'
    } elseif (-not $gw) {
        $hint = 'No default gateway: no adapter has a working IP configuration (DHCP failed or wrong static address).'
    } elseif ($sendRefused) {
        $hint = 'Windows itself refuses to send (immediate error, not a timeout). Something inside Windows drops the traffic: a filter of security software (WFP), device isolation, a VPN kill switch, IPsec policy or a broken network stack. Cables, Wi-Fi and the router are not the cause.'
    } elseif ([string]$r.ping_gateway -ne 'Success' -and -not $tcpOk) {
        $hint = 'Packets leave but nothing answers, not even the gateway: wrong IP configuration, cable or Wi-Fi, switch or router. Note: some routers never answer ping.'
    } elseif ($tcpOk -and -not $dnsOk) {
        $hint = 'Internet connections work but names are not resolved: DNS server settings or a DNS filter.'
    } else {
        $hint = 'The local network answers but the internet does not: router, provider, proxy settings or an outbound filter.'
    }
}
$r.HINT = $hint
$r.PASSED = $passed
if ($passed) { $r.RESULT = 'NETWORK WORKS' } else { $r.RESULT = 'NETWORK BROKEN' }

$r | ConvertTo-Json -Depth 4
if ($passed) { exit 0 } else { exit 1 }
