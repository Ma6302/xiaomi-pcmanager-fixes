# 给 MiPCAudio.exe 打 1 字节补丁：网卡筛选 IfType 0x47(Wi-Fi) -> 0x06(以太网)
# 目的：Wi-Fi 未连接/未启用时也能取到本机 MAC，从而让妙播的发现广播能启动。
# 需管理员运行。原文件备份：MiPCAudio.exe.orig-6.0.2.19（同目录）
$ErrorActionPreference = 'Stop'
$log = Join-Path $PSScriptRoot ('patch-mac-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
function W($m) {
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
    $line | Tee-Object -FilePath $log -Append | Out-Host
}

$ver = (Get-ChildItem 'C:\Program Files\MI\XiaomiPCManager' -Directory | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1).Name
$exe = "C:\Program Files\MI\XiaomiPCManager\$ver\MiSmartShare\MiPCAudio.exe"
$bak = Join-Path $PSScriptRoot 'MiPCAudio.exe.orig-6.0.2.19'
$off = 0x90E70

try {
    W "版本目录: $ver"
    W "目标: $exe"
    if (-not (Test-Path $exe)) { throw "找不到 MiPCAudio.exe" }
    if (-not (Test-Path $bak)) { throw "找不到备份 $bak" }

    $shaNow = (Get-FileHash $exe -Algorithm SHA256).Hash
    $shaBak = (Get-FileHash $bak -Algorithm SHA256).Hash
    W "当前文件 SHA256 = $shaNow"
    W "备份  文件 SHA256 = $shaBak"
    if ($shaNow -ne $shaBak) { W "注意：当前文件与备份不同（可能已打过补丁或官方更新过）" }

    # 停掉妙播进程，父进程 MiSmartShareHost 会自动再拉起
    $p = Get-Process MiPCAudio -ErrorAction SilentlyContinue
    if ($p) { W "停止 MiPCAudio pid=$($p.Id)"; Stop-Process -Id $p.Id -Force }
    Start-Sleep -Milliseconds 1500

    $fs = [System.IO.File]::Open($exe, 'Open', 'ReadWrite', 'None')
    try {
        $buf = New-Object byte[] 5
        $fs.Position = $off
        [void]$fs.Read($buf, 0, 5)
        W ("补丁点原始字节: " + (($buf | ForEach-Object { '{0:X2}' -f $_ }) -join ' '))
        $expect = [byte[]](0x41, 0x83, 0x79, 0x64, 0x47)
        if (-not ((0..4 | ForEach-Object { $buf[$_] -eq $expect[$_] }) -notcontains $false)) {
            throw "补丁点字节不符合预期，放弃修改"
        }
        $fs.Position = $off + 4
        $fs.Write([byte[]](0x06), 0, 1)
        $fs.Flush()
    } finally { $fs.Dispose() }

    $b = [System.IO.File]::ReadAllBytes($exe)
    W ("补丁后字节: " + (('{0:X2} {1:X2} {2:X2} {3:X2} {4:X2}' -f $b[$off], $b[$off + 1], $b[$off + 2], $b[$off + 3], $b[$off + 4])))
    W "新 SHA256 = $((Get-FileHash $exe -Algorithm SHA256).Hash)"

    # 等父进程重新拉起妙播
    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        $np = Get-Process MiPCAudio -ErrorAction SilentlyContinue
        if ($np) { W "MiPCAudio 已重新拉起 pid=$($np.Id)"; break }
    }
    Start-Sleep -Seconds 6
    $latest = Get-ChildItem 'C:\ProgramData\MI\Miplay\AudioShare\mpa\miplay_MiPlay_*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    W "最新妙播日志: $($latest.Name)"
    Get-Content $latest.FullName | Select-String 'register service success|get mac address failed|advertising result listener|register channel result' |
        Select-Object -Last 6 | ForEach-Object { W ("LOG " + $_.Line.Trim()) }
    W "完成"
} catch {
    W "失败: $($_.Exception.Message)"
}
