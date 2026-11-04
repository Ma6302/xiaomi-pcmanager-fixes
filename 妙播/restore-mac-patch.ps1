# 回滚 MiPCAudio.exe 的 MAC 网卡筛选补丁（把 0x06 改回 0x47），或直接用备份整文件覆盖
# 需管理员运行
$ErrorActionPreference = 'Stop'
$log = Join-Path $PSScriptRoot ('restore-mac-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
function W($m) { ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) | Tee-Object -FilePath $log -Append | Out-Host }

$ver = (Get-ChildItem 'C:\Program Files\MI\XiaomiPCManager' -Directory | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1).Name
$exe = "C:\Program Files\MI\XiaomiPCManager\$ver\MiSmartShare\MiPCAudio.exe"
$bak = Join-Path $PSScriptRoot 'MiPCAudio.exe.orig-6.0.2.19'
$off = 0x90E70

try {
    W "版本目录: $ver"
    $p = Get-Process MiPCAudio -ErrorAction SilentlyContinue
    if ($p) { W "停止 MiPCAudio pid=$($p.Id)"; Stop-Process -Id $p.Id -Force }
    Start-Sleep -Milliseconds 1500

    $fs = [System.IO.File]::Open($exe, 'Open', 'ReadWrite', 'None')
    try {
        $b = New-Object byte[] 5
        $fs.Position = $off; [void]$fs.Read($b, 0, 5)
        W ("当前字节: " + (($b | ForEach-Object { '{0:X2}' -f $_ }) -join ' '))
        if ($b[0] -ne 0x41 -or $b[1] -ne 0x83 -or $b[2] -ne 0x79 -or $b[3] -ne 0x64) {
            throw ("补丁点前 4 字节不是 41 83 79 64（实际 {0}），版本可能已变，放弃写入" -f (($b[0..3] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '))
        }
        if ($b[4] -ne 0x47) {
            $fs.Position = $off + 4
            $fs.Write([byte[]](0x47), 0, 1)
            $fs.Flush()
            W "已把第 5 字节改回 0x47"
        } else { W "已经是 0x47，无需修改" }
    } finally { $fs.Dispose() }

    W "当前 SHA256 = $((Get-FileHash $exe -Algorithm SHA256).Hash)"
    if (Test-Path $bak) { W "备份 SHA256 = $((Get-FileHash $bak -Algorithm SHA256).Hash)（若两者相同即为原厂状态）" }

    for ($i = 0; $i -lt 20; $i++) {
        Start-Sleep -Seconds 1
        $np = Get-Process MiPCAudio -ErrorAction SilentlyContinue
        if ($np) { W "MiPCAudio 已重新拉起 pid=$($np.Id)"; break }
    }
} catch { W "失败: $($_.Exception.Message)" }
