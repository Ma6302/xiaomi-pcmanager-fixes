# 回滚 MiPCAudio.exe 的 MAC 网卡筛选补丁 —— 改名替换法（可在进程占用时工作）
#
# 为什么需要这一版：
#   直接 Open(exe, ReadWrite) 会因为 exe 正在被运行/被父进程 MiSmartShareHost 秒级重新拉起
#   而报 "being used by another process"。
#   办法：先 Stop 进程 → 立刻把 exe 改名（对运行中的 exe 也可行）→ 把备份复制回去 → 再让父进程拉起。
#
# 用法（需管理员）：
#   Start-Process pwsh -Verb RunAs -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','"<本脚本>"'
#
# 参数：
#   -BackupPath  原厂 exe 备份路径（默认脚本同目录 MiPCAudio.exe.orig-6.0.2.19）
$ErrorActionPreference = 'Stop'
$log = Join-Path $PSScriptRoot ('restore-mac-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
function W($m) { ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) | Tee-Object -FilePath $log -Append | Out-Host }

$ver = (Get-ChildItem 'C:\Program Files\MI\XiaomiPCManager' -Directory | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1).Name
$exe = "C:\Program Files\MI\XiaomiPCManager\$ver\MiSmartShare\MiPCAudio.exe"
$bak = Join-Path $PSScriptRoot 'MiPCAudio.exe.orig-6.0.2.19'
$expectBak = '435FDDA1A227C165369EB37DBE4AECE7A4FFC8F528046BA17973371A311B05D6'   # 原厂 6.0.2.19
$expectPatched = 'ED40509B063E0006FAE7064D0F4330F0937169A63E22549933746BB564A550E3' # 已打补丁

try {
    W "版本目录: $ver"
    if (-not (Test-Path $bak)) { throw "找不到原厂备份: $bak" }
    $bakHash = (Get-FileHash $bak -Algorithm SHA256).Hash
    W "备份 SHA256 = $bakHash"
    if ($bakHash -ne $expectBak) { throw "备份哈希不是原厂值（期望 $expectBak），放弃" }

    if (-not (Test-Path $exe)) { throw "目标 exe 不存在: $exe" }
    $curHash = (Get-FileHash $exe -Algorithm SHA256).Hash
    W "目标当前 SHA256 = $curHash"
    if ($curHash -eq $expectBak) { W "已经是原厂状态，无需修改"; return }
    if ($curHash -ne $expectPatched) { throw "目标既不是原厂也不是已知补丁版本（$curHash），放弃" }

    # 1) 停进程
    $p = Get-Process MiPCAudio -ErrorAction SilentlyContinue
    if ($p) { W "停止 MiPCAudio pid=$($p.Id)"; Stop-Process -Id $p.Id -Force; Start-Sleep -Milliseconds 300 }

    # 2) 改名（唯一允许在占用下做的操作）+ 复制备份回去
    $aside = "$exe.patched-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
    $ok = $false
    for ($i = 1; $i -le 5; $i++) {
        try { Rename-Item -LiteralPath $exe -NewName (Split-Path $aside -Leaf) -ErrorAction Stop; $ok = $true; break }
        catch { W "改名第 $i 次失败: $($_.Exception.Message)"; $q = Get-Process MiPCAudio -ErrorAction SilentlyContinue; if ($q) { Stop-Process -Id $q.Id -Force }; Start-Sleep -Milliseconds 600 }
    }
    if (-not $ok) { throw "改名失败，未做任何修改" }
    W "已改名为: $(Split-Path $aside -Leaf)"

    try {
        Copy-Item -LiteralPath $bak -Destination $exe -Force -ErrorAction Stop
        W "已复制原厂 exe 回原位"
    } catch {
        W "复制失败: $($_.Exception.Message) —— 回滚改名"
        if ((Test-Path $exe) -eq $false) { Rename-Item -LiteralPath $aside -NewName (Split-Path $exe -Leaf) }
        throw
    }

    if (-not (Test-Path $exe)) { throw "复制后目标不存在" }
    $newHash = (Get-FileHash $exe -Algorithm SHA256).Hash
    W "写入后 SHA256 = $newHash"
    if ($newHash -ne $expectBak) { throw "写入后哈希不符（$newHash），请人工检查" }

    # 3) 让父进程重新拉起（先杀掉可能已经起来的旧实例）
    $q = Get-Process MiPCAudio -ErrorAction SilentlyContinue
    if ($q) { W "停止仍在运行的旧实例 pid=$($q.Id)"; Stop-Process -Id $q.Id -Force }
    for ($i = 0; $i -lt 25; $i++) {
        Start-Sleep -Seconds 1
        $np = Get-Process MiPCAudio -ErrorAction SilentlyContinue
        if ($np) { W "MiPCAudio 已重新拉起 pid=$($np.Id)"; break }
    }
    W "完成：当前为原厂版本（未打补丁）"
} catch { W "失败: $($_.Exception.Message)" }
