$ErrorActionPreference = 'Continue'
$log = 'D:\Download\小米电脑管家提示修复\fix-result2.log'
function L($m) { Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding utf8 }

$exe = 'C:\Program Files\MI\XiaomiPCManager\6.0.0.39\MiSmartShare\MiPlayCastService.exe'
L "=== start add-out ==="
foreach ($proto in @('tcp', 'udp')) {
    $out = & netsh advfirewall firewall add rule name=MiPlayCastService dir=out action=allow program="$exe" enable=yes profile=any protocol=$proto 2>&1
    L "netsh out $proto => $out"
}
L "--- show ---"
$show = & netsh advfirewall firewall show rule name=MiPlayCastService verbose 2>&1
$show | ForEach-Object { L $_ }
L "=== done ==="
