$ErrorActionPreference = 'SilentlyContinue'
Write-Output '=== adapters (IPv4) ==='
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '169.254*' -and $_.IPAddress -ne '127.0.0.1' } |
    Select-Object InterfaceAlias, IPAddress, PrefixLength, AddressState |
    Format-Table -AutoSize | Out-String -Width 100

Write-Output '=== adapter status ==='
Get-NetAdapter -Physical | Select-Object Name, InterfaceType, Status, LinkSpeed, MacAddress |
    Format-Table -AutoSize | Out-String -Width 100

Write-Output '=== wlan ==='
(netsh wlan show interfaces) | Select-String -Pattern 'Name|State|SSID|Signal' | ForEach-Object { $_.Line }

Write-Output '=== 8899 ==='
Get-NetTCPConnection -LocalPort 8899 -ErrorAction SilentlyContinue |
    Select-Object State, LocalAddress, RemoteAddress, RemotePort, OwningProcess |
    Format-Table -AutoSize | Out-String -Width 110

Write-Output '=== default routes ==='
Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Select-Object InterfaceAlias, NextHop, RouteMetric, InterfaceMetric |
    Format-Table -AutoSize | Out-String -Width 100

Write-Output '=== latest mpa log (tail 25) ==='
$log = Get-ChildItem 'C:\ProgramData\MI\Miplay\AudioShare\mpa\miplay_MiPlay_*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Output ('file: ' + $log.Name + '  ' + $log.Length + ' bytes')
Get-Content $log.FullName -Tail 25
