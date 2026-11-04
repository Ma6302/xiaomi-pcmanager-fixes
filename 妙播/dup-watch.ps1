# 临时诊断：6 分钟内记录手机(192.168.5.170)与本机的所有 TCP 连接变化 + 妙播新会话
param([int]$Minutes = 6, [string]$Out = 'D:\Download\小米电脑管家提示修复\妙播\dup-watch.log')
$ErrorActionPreference = 'SilentlyContinue'
$phone = '192.168.5.170'
$end = (Get-Date).AddMinutes($Minutes)
function W($m) { ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $m) | Add-Content -LiteralPath $Out -Encoding UTF8 }
W "=== 开始监视 $Minutes 分钟，目标 $phone ==="
$seen = @{}
$lastMpa = $null
while ((Get-Date) -lt $end) {
    $tcp = Get-NetTCPConnection | Where-Object { $_.RemoteAddress -eq $phone }
    foreach ($c in $tcp) {
        $k = '{0}-{1}-{2}' -f $c.LocalPort, $c.RemotePort, $c.State
        if (-not $seen.ContainsKey($k)) {
            $seen[$k] = 1
            W ("新连接 {0} -> {1}:{2}  state={3}  pid={4}" -f $c.LocalAddress + ':' + $c.LocalPort, $phone, $c.RemotePort, $c.State, $c.OwningProcess)
        }
    }
    $latest = Get-ChildItem 'C:\ProgramData\MI\Miplay\AudioShare\mpa\miplay_MiPlay_*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($latest -and $latest.FullName -ne $lastMpa) { W "妙播当前日志: $($latest.Name)"; $lastMpa = $latest.FullName }
    if ($latest) {
        $new = Get-Content $latest.FullName -Tail 40 | Select-String -Pattern 'onAccept|SafetyAuth|register service|advertising result|connect fail|Connect fail|error|Error' | Select-Object -Last 1
        if ($new) { $line = $new.Line.Trim(); if ($line -ne $script:lastLine) { W "LOG: $line"; $script:lastLine = $line } }
    }
    Start-Sleep -Milliseconds 900
}
W "=== 监视结束 ==="
