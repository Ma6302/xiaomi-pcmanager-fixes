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

 示例：
   pwsh -File .\miplay-netwatch.ps1 -Oneshot
   pwsh -File .\miplay-netwatch.ps1            # 常驻守护
#>
[CmdletBinding()]
param(
    [switch]$Oneshot,
    [switch]$DryRun,
    [int]$DebounceSeconds = 45,
    [int]$PollSeconds = 15,
    [string]$LogPath
)

if (-not $LogPath) { $LogPath = Join-Path -Path $PSScriptRoot -ChildPath 'miplay-netwatch.log' }

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
    $f = Get-ChildItem -LiteralPath $script:MpaLogDir -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $f) { return $false }
    if ($f.LastWriteTime -lt (Get-Date).AddSeconds(-$WithinSeconds)) { return $false }
    return [bool](Select-String -LiteralPath $f.FullName -Pattern 'register service success id' -Quiet -ErrorAction SilentlyContinue)
}

function Restart-MiPCAudio {
    $procs = @(Get-CimInstance Win32_Process -Filter "Name='MiPCAudio.exe'" -ErrorAction SilentlyContinue)
    if ($procs.Count -eq 0) {
        Write-Log 'MiPCAudio.exe 未运行（电脑管家可能已退出），跳过'
        return $false
    }
    $before = @($procs | ForEach-Object { $_.ProcessId })
    if ($DryRun) {
        Write-Log ('DRYRUN 将重启 MiPCAudio.exe pid=' + ($before -join ','))
        return $true
    }
    Write-Log ('重启 MiPCAudio.exe pid=' + ($before -join ','))
    foreach ($p in $procs) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop }
        catch { Write-Log ('结束进程失败：' + $_.Exception.Message) }
    }
    $deadline = (Get-Date).AddSeconds(30)
    $newpid = $null
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 700
        $np = @(Get-CimInstance Win32_Process -Filter "Name='MiPCAudio.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $before -notcontains $_.ProcessId })
        if ($np.Count -gt 0) { $newpid = $np[0].ProcessId; break }
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
if (-not $gotMutex -and -not $Oneshot) {
    Write-Log '已有另一个守护实例在运行，本实例退出'
    return
}

Write-Log ('watchdog 启动：poll={0}s debounce={1}s dryrun={2} oneshot={3}' -f $PollSeconds, $DebounceSeconds, [bool]$DryRun, [bool]$Oneshot)

if ($Oneshot) {
    if (Test-MilinkRegistered -WithinSeconds 3600) { Write-Log '当前已有注册记录，仍按手动请求执行重启' }
    [void](Restart-MiPCAudio)
    Write-Log 'oneshot 结束'
    return
}

$lastSig = Get-NetSignature
$sigAtRestart = $lastSig
$lastRestart = [datetime]::MinValue
$lastTick = Get-Date
Write-Log ('初始网络签名：' + $(if ($lastSig) { $lastSig } else { '(无可用 IPv4)' }))

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
    # 需要重启的三种情况：网络刚变 / 刚唤醒 / 上次重启时的网络与现在不一致（重启时链路还在抖动，注册可能落在已消失的网卡上）
    $needRestart = $changed -or $slept -or ($sig -ne $sigAtRestart)
    if (-not $needRestart) { continue }
    if (((Get-Date) - $lastRestart).TotalSeconds -lt $DebounceSeconds) {
        Write-Log ('距上次重启不足 {0} 秒，去抖跳过（下次轮询会再检查）' -f $DebounceSeconds)
        continue
    }
    if (Restart-MiPCAudio) { $lastRestart = Get-Date; $sigAtRestart = $sig }
}
