#requires -Version 5.1
<#
 miplay-netwatch.ps1
 ---------------------------------------------------------------------------
 用途：小米电脑管家「妙播 / 音频共享」在网络切换后不会重新注册 milink 服务，
       导致手机端「投放到」列表里看不到这台电脑。本脚本监视网络变化，
       一旦活动网卡或 IP 发生变化，就重启 MiPCAudio.exe 让它重新注册。

 为什么是重启 MiPCAudio.exe：
   MiPCAudio.exe 由 MiSmartShareHost.exe 托管，杀掉后父进程会在 1~2 秒内
   自动拉起新实例；新实例启动时会执行 Milink::registerService，
   日志出现 "register service success id" 即代表手机端又能看到本机。

 参数：
   -Oneshot          只执行一次重启然后退出（手动触发用）
   -DryRun           仅记录日志，不结束任何进程
   -DebounceSeconds  两次重启之间的最小间隔，默认 45 秒
   -PollSeconds      轮询网络变化的间隔，默认 15 秒
   -LogPath          日志路径，默认脚本同目录 miplay-netwatch.log
   -NoIfType         不做「发现身份网卡类型」自动切换（默认开启，需要管理员权限）

  发现身份自动切换（需要提升权限运行）：
   电脑同时用 Lyra(MiPCAudio.exe) 与 IDM(idmruntime.dll) 两套机制发布音频目标，
   两套都按「IfType == 0x47(Wi-Fi)」挑网卡取 MAC，共三处。三处一致手机才会合并成
   一个设备；只要现在活跃的是有线网卡而三处还指向 Wi-Fi，取 MAC 会失败/分歧，
   手机里就会出现两条同名设备。所以本守护在重启 MiPCAudio 之前，会先按「当前
   活跃网卡」把三处统一成 0x06(有线) 或 0x47(无线)，然后再重启。

 示例：
   pwsh -File .\miplay-netwatch.ps1 -Oneshot
   pwsh -File .\miplay-netwatch.ps1            # 常驻守护
#>
[CmdletBinding()]
param(
    [switch]$Oneshot,
    [switch]$DryRun,
    [switch]$NoIfType,
    [int]$DebounceSeconds = 45,
    [int]$PollSeconds = 15,
    [string]$LogPath,
    [string]$IfTypeScript
)

if (-not $LogPath) { $LogPath = Join-Path -Path $PSScriptRoot -ChildPath 'miplay-netwatch.log' }
if (-not $IfTypeScript) { $IfTypeScript = Join-Path -Path $PSScriptRoot -ChildPath 'set-iftype-mode.ps1' }

$script:MpaLogDir = 'C:\ProgramData\MI\Miplay\AudioShare\mpa'

function Write-Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    try {
        if ((Test-Path -LiteralPath $LogPath) -and ((Get-Item -LiteralPath $LogPath).Length -gt 1MB)) {
            Move-Item -LiteralPath $LogPath -Destination ($LogPath + '.old') -Force -ErrorAction SilentlyContinue
        }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8 -ErrorAction SilentlyContinue
    } catch { }
}

function Get-NetSignature {
    # 取所有「非仅本地链路」的 IPv4（含 Deprecated：双网卡同网段时 Windows 会把次要网卡标记为
    # Deprecated，这类地址消失/出现同样意味着链路变了，需要重新注册 milink）
    $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -ne '127.0.0.1' -and
            $_.IPAddress -notlike '169.254.*' -and
            $_.AddressState -ne 'Tentative' -and
            $_.InterfaceAlias -notmatch 'Loopback|vEthernet|VirtualBox|VMware|TAP|OpenVPN|WireGuard'
        })
    if ($ips.Count -eq 0) { return '' }
    return (($ips | ForEach-Object { '{0}={1}' -f $_.InterfaceAlias, $_.IPAddress } | Sort-Object) -join ';')
}

function Test-MilinkRegistered {
    param([int]$WithinSeconds = 120)
    # 注意：mpa 日志按 2MB 轮转，重启瞬间可能刚生成了一个空的新文件，
    # 所以要在时间窗内的最近几个文件里找，而不是只看最新的那一个。
    $files = @(Get-ChildItem -LiteralPath $script:MpaLogDir -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge (Get-Date).AddSeconds(-$WithinSeconds) } |
        Sort-Object LastWriteTime -Descending | Select-Object -First 3)
    if ($files.Count -eq 0) { return $false }
    foreach ($f in $files) {
        if (Select-String -LiteralPath $f.FullName -Pattern 'register service success id' -Quiet -ErrorAction SilentlyContinue) { return $true }
    }
    return $false
}

function Test-IsElevated {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-ActiveIfTypeMode {
    # 返回 'lan' / 'wifi' / $null：按「当前真正有可用 IPv4 的物理网卡」决定发现身份该指向哪种介质
    $ips = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.IPAddress -ne '127.0.0.1' -and
            $_.IPAddress -notlike '169.254.*' -and
            $_.AddressState -ne 'Tentative'
        })
    if ($ips.Count -eq 0) { return $null }
    $adapters = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
    $lanUp = $false
    $wifiUp = $false
    foreach ($a in $adapters) {
        $it = 0
        try { $it = [int]$a.InterfaceType } catch { $it = 0 }
        $hasIp = @($ips | Where-Object { $_.InterfaceIndex -eq $a.ifIndex }).Count -gt 0
        if (-not $hasIp) { continue }
        if ($it -eq 6) { $lanUp = $true }
        elseif ($it -eq 71) { $wifiUp = $true }
    }
    # 有线优先：有线可用时身份走有线，Wi-Fi 只当备份（同网段时也避免两套机制分歧）
    if ($lanUp) { return 'lan' }
    if ($wifiUp) { return 'wifi' }
    return $null
}

function Invoke-IfTypeMode {
    param([string]$Mode)
    if ($NoIfType) { return $true }
    if (-not $script:CanPatch) {
        Write-Log '未以管理员身份运行，跳过发现身份网卡类型切换（可用管理员重装守护解决）'
        return $false
    }
    if (-not (Test-Path -LiteralPath $IfTypeScript)) {
        Write-Log ('找不到切换脚本：' + $IfTypeScript)
        return $false
    }
    try {
        $out = & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $IfTypeScript -Mode $Mode 2>&1
        $code = $LASTEXITCODE
        foreach ($line in @($out)) {
            if ("$line".Trim()) { Write-Log ('  iftype| ' + "$line") }
        }
        if ($code -eq 0) { Write-Log ('发现身份已切换/确认：' + $Mode); return $true }
        Write-Log ('发现身份切换失败（exit=' + $code + '），继续重启流程')
        return $false
    } catch {
        Write-Log ('发现身份切换异常：' + $_.Exception.Message)
        return $false
    }
}

function Test-IfTypePending {
    param([string]$Mode)
    # 退出码 3 = 需要改动
    if ($NoIfType -or -not $script:CanPatch -or -not (Test-Path -LiteralPath $IfTypeScript)) { return $false }
    try {
        & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $IfTypeScript -Mode $Mode -DryRun *> $null
        return ($LASTEXITCODE -eq 3)
    } catch { return $false }
}

function Restart-MiPCAudio {
    param([string]$IfTypeMode)
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='MiPCAudio.exe'" -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) {
        Write-Log 'MiPCAudio.exe 未运行（电脑管家可能已退出），跳过'
        return $false
    }
    $before = @($procs | ForEach-Object { $_.ProcessId })
    if ($DryRun) {
        Write-Log ('DRYRUN 将重启 MiPCAudio.exe pid=' + ($before -join ','))
        if ($IfTypeMode) { Write-Log ('DRYRUN 将先把发现身份切换为 ' + $IfTypeMode) }
        return $true
    }
    Write-Log ('重启 MiPCAudio.exe pid=' + ($before -join ','))
    foreach ($p in $procs) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop }
        catch { Write-Log ('结束进程失败：' + $_.Exception.Message) }
    }
    # 进程退出后 exe/dll 解锁，这时改字节最稳；父进程通常 1~2 秒后才拉起新实例
    $patchTime = $null
    if ($IfTypeMode) {
        $deadline = (Get-Date).AddSeconds(5)
        while ((Get-Date) -lt $deadline) {
            if (@(Get-CimInstance Win32_Process -Filter "Name='MiPCAudio.exe'" -ErrorAction SilentlyContinue).Count -eq 0) { break }
            Start-Sleep -Milliseconds 200
        }
        [void](Invoke-IfTypeMode -Mode $IfTypeMode)
        $patchTime = Get-Date
    }
    $deadline = (Get-Date).AddSeconds(30)
    $newpid = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 700
        $np = @(Get-CimInstance Win32_Process -Filter "Name='MiPCAudio.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $before -notcontains $_.ProcessId })
        if ($np.Count -eq 0) { continue }
        # 关键：父进程可能在改字节完成之前就把实例拉起来了，那种实例加载的还是旧字节，
        # 必须再重启一次，否则这次的「切换」等于没生效。
        if ($patchTime -and $np[0].CreationDate -and ($np[0].CreationDate -lt $patchTime)) {
            Write-Log ('新实例 pid={0} 启动于切换之前，重新拉起一次以加载新字节' -f $np[0].ProcessId)
            foreach ($q in $np) { try { Stop-Process -Id $q.ProcessId -Force -ErrorAction Stop } catch { } }
            Start-Sleep -Milliseconds 500
            continue
        }
        $newpid = $np[0].ProcessId
        break
    }
    if (-not $newpid) {
        Write-Log '警告：30 秒内没有出现新的 MiPCAudio.exe（父进程未拉起），请手动重开小米电脑管家'
        return $false
    }
    Write-Log ('新 MiPCAudio.exe pid=' + $newpid)
    $deadline = (Get-Date).AddSeconds(25)
    $ok = $false
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 800
        if (Test-MilinkRegistered -WithinSeconds 60) { $ok = $true; break }
    }
    Write-Log ('milink 注册校验：' + $(if ($ok) { '成功' } else { '未检测到 register service success' }))
    return $true
}

# ---- 单实例保护：同名互斥体，避免重复启动多个守护 ----
$mutexName = 'Local\MiPlayNetWatch_' + $env:USERNAME
$script:WatchMutex = New-Object System.Threading.Mutex($false, $mutexName)
$gotMutex = $false
try { $gotMutex = $script:WatchMutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $gotMutex = $true }
if (-not $gotMutex) {
    # -Oneshot 以前会绕过互斥体：多个 oneshot 并发时会各自 Stop-Process 全部 MiPCAudio，
    # 互相竞争拉起，所以这里也一律让路（要强制跑请先停掉常驻守护）。
    Write-Log '已有另一个守护实例在运行（含 -Oneshot 调用），本实例退出'
    return
}

Write-Log ('watchdog 启动：poll={0}s debounce={1}s dryrun={2} oneshot={3}' -f $PollSeconds, $DebounceSeconds, [bool]$DryRun, [bool]$Oneshot)

$script:CanPatch = Test-IsElevated
$ifTypeState = if ($NoIfType) { '关闭(-NoIfType)' } elseif ($script:CanPatch) { '开启' } else { '关闭(未提升权限)' }
Write-Log ('发现身份网卡自动切换：' + $ifTypeState)

# 顺带清理上一次改名替换留下的 MiPCAudio.exe.swap-* / idmruntime.dll.swap-*（旧镜像此时多半已解锁）
if ($script:CanPatch -and -not $NoIfType -and (Test-Path -LiteralPath $IfTypeScript)) {
    try { & (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $IfTypeScript -Clean *> $null } catch { }
}

if ($Oneshot) {
    if (Test-MilinkRegistered -WithinSeconds 3600) { Write-Log '当前已有注册记录，仍按手动请求执行重启' }
    $m = Get-ActiveIfTypeMode
    [void](Restart-MiPCAudio -IfTypeMode $m)
    Write-Log 'oneshot 结束'
    return
}

$lastSig = Get-NetSignature
$sigAtRestart = $lastSig
$lastRestart = [datetime]::MinValue
$lastTick = Get-Date
Write-Log ('初始网络签名：' + $(if ($lastSig) { $lastSig } else { '(无可用 IPv4)' }))
$lastIfType = Get-ActiveIfTypeMode
Write-Log ('当前活跃介质：' + $(if ($lastIfType) { $lastIfType } else { '(未识别)' }))

# 启动时如果发现身份与活跃介质不一致（典型：只有有线，三处却指向 Wi-Fi），一次性纠正
if ($lastIfType -and (Test-IfTypePending -Mode $lastIfType)) {
    Write-Log ('发现身份与活跃介质不一致，按 ' + $lastIfType + ' 模式纠正并重启妙播')
    if (Restart-MiPCAudio -IfTypeMode $lastIfType) { $lastRestart = Get-Date; $sigAtRestart = (Get-NetSignature) }
}

while ($true) {
    Start-Sleep -Seconds $PollSeconds
    $now = Get-Date
    # 睡眠/休眠唤醒检测：真实流逝时间远大于轮询间隔 → 说明刚唤醒，网络栈可能已失效
    $elapsed = ($now - $lastTick).TotalSeconds
    $slept = $elapsed -gt ($PollSeconds + 60)
    $lastTick = $now
    $sig = Get-NetSignature
    if ($slept) { Write-Log ('检测到休眠/唤醒（距上次轮询 {0:N0} 秒）' -f $elapsed) }
    $changed = ($sig -ne $lastSig)
    if ($changed) { Write-Log ('检测到网络变化：[' + $lastSig + '] -> [' + $sig + ']') }
    $lastSig = $sig
    if (-not $sig) { Write-Log '当前没有可用 IPv4，等待网络恢复'; continue }
    $mode = Get-ActiveIfTypeMode
    $modeChanged = ($mode -and $mode -ne $lastIfType)
    if ($modeChanged) { Write-Log ('活跃介质变化：' + $(if ($lastIfType) { $lastIfType } else { '(未识别)' }) + ' -> ' + $mode) }
    # 需要重启的四种情况：网络刚变 / 刚唤醒 / 上次重启时的网络与现在不一致（重启时链路还在抖动，注册可能落在已消失的网卡上）/ 活跃介质变了
    $needRestart = $changed -or $slept -or ($sig -ne $sigAtRestart) -or $modeChanged
    if (-not $needRestart) { continue }
    if (((Get-Date) - $lastRestart).TotalSeconds -lt $DebounceSeconds) {
        Write-Log ('距上次重启不足 {0} 秒，去抖跳过（下次轮询会再检查）' -f $DebounceSeconds)
        continue
    }
    if (Restart-MiPCAudio -IfTypeMode $mode) {
        $lastRestart = Get-Date
        $sigAtRestart = $sig
        if ($mode) { $lastIfType = $mode }
    }
}
