# 给 MiPCAudio.exe 打 1 字节补丁（改名法，避开运行中文件锁）
# 网卡筛选 IfType 0x47(Wi-Fi) -> 0x06(以太网)：Wi-Fi 未连接时也能取到本机 MAC
# 需管理员运行。原文件备份：MiPCAudio.exe.orig-6.0.2.19
$ErrorActionPreference = 'Stop'
$log = Join-Path $PSScriptRoot ('patch-mac-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
function W($m) { ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) | Tee-Object -FilePath $log -Append | Out-Host }

$ver = (Get-ChildItem 'C:\Program Files\MI\XiaomiPCManager' -Directory | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1).Name
$dir = "C:\Program Files\MI\XiaomiPCManager\$ver\MiSmartShare"
$exe = Join-Path $dir 'MiPCAudio.exe'
$off = 0x90E70

try {
    W "版本目录: $ver"
    $tmp = Join-Path $env:TEMP 'MiPCAudio.patched.exe'
    Copy-Item $exe $tmp -Force

    # 在副本上打补丁
    $fs = [System.IO.File]::Open($tmp, 'Open', 'ReadWrite', 'None')
    try {
        $b = New-Object byte[] 5
        $fs.Position = $off; [void]$fs.Read($b, 0, 5)
        W ("补丁点字节: " + (($b | ForEach-Object { '{0:X2}' -f $_ }) -join ' '))
        if ($b[0] -ne 0x41 -or $b[1] -ne 0x83 -or $b[2] -ne 0x79 -or $b[3] -ne 0x64) { throw "字节不符合预期，放弃" }
        if ($b[4] -eq 0x06) { W "副本已经是 0x06，直接替换" }
        else {
            $fs.Position = $off + 4
            $fs.Write([byte[]](0x06), 0, 1)
            $fs.Flush()
            W "副本已改 0x47 -> 0x06"
        }
    } finally { $fs.Dispose() }
    W "补丁副本 SHA256 = $((Get-FileHash $tmp -Algorithm SHA256).Hash)"

    # 把原文件改名（运行中也可改名），再把补丁副本放回去
    $side = Join-Path $dir 'MiPCAudio.exe.orig'
    if (Test-Path $side) { Remove-Item $side -Force }
    try {
        Rename-Item -LiteralPath $exe -NewName 'MiPCAudio.exe.orig' -ErrorAction Stop
        W "原文件已改名为 MiPCAudio.exe.orig"
        Copy-Item $tmp -Destination $exe -Force
        W "补丁文件已就位"
    } catch {
        W "改名法失败（$($_.Exception.Message)），改用结束进程+重试"
        Get-Process MiPCAudio -ErrorAction SilentlyContinue | Stop-Process -Force
        Start-Sleep -Milliseconds 800
        $ok = $false
        for ($i = 0; $i -lt 20; $i++) {
            try { Copy-Item $tmp -Destination $exe -Force -ErrorAction Stop; $ok = $true; break }
            catch { Get-Process MiPCAudio -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Milliseconds 200 }
        }
        if (-not $ok) {
            # 回滚：改名已经生效，必须把原文件放回去，否则目录里只剩 MiPCAudio.exe.orig 而没有 exe
            try {
                if ((Test-Path $side) -and -not (Test-Path $exe)) {
                    Copy-Item $side -Destination $exe -Force
                    W "已从 MiPCAudio.exe.orig 回滚原文件（未打补丁）"
                }
            } catch { W "回滚失败，请手动把 MiPCAudio.exe.orig 改名为 MiPCAudio.exe：$($_.Exception.Message)" }
            throw "无法替换文件（已尝试回滚）"
        }
        W "已通过强制替换写入补丁"
    }
    if (-not (Test-Path $exe)) { throw "替换后找不到 MiPCAudio.exe，请检查目录" }
    W "当前 SHA256 = $((Get-FileHash $exe -Algorithm SHA256).Hash)"

    # 重启妙播进程，加载补丁后的 exe
    Get-Process MiPCAudio -ErrorAction SilentlyContinue | ForEach-Object { W "停止 MiPCAudio pid=$($_.Id)"; Stop-Process -Id $_.Id -Force }
    for ($i = 0; $i -lt 25; $i++) {
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
