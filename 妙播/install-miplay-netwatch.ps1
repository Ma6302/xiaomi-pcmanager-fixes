#requires -Version 5.1
<#
  install-miplay-netwatch.ps1
  ---------------------------------------------------------------------------
  把 miplay-netwatch.ps1 装成「登录后自动在后台以管理员权限运行」的守护进程。

  为什么要管理员权限：
    守护除了重启 MiPCAudio.exe，还会在切换网络时改写
    C:\Program Files\MI\XiaomiPCManager\<版本>\MiSmartShare\ 下
    MiPCAudio.exe 与 idmruntime.dll 里的三处 IfType 字节（发现身份走有线还是无线）。
    这一步必须提权，所以用「计划任务 + 最高权限」而不是启动文件夹里的普通启动项。

  参数：
   -Uninstall   卸载：删除计划任务、旧启动项/启动器，并结束守护进程
   -NoIfType    安装时给守护加 -NoIfType（只做重启，不改程序文件）
   -TaskName    计划任务名，默认 MiPlayNetWatch

  用法：
   pwsh -File .\install-miplay-netwatch.ps1
   pwsh -File .\install-miplay-netwatch.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [switch]$NoIfType,
    [string]$TaskName = 'MiPlayNetWatch',
    [string]$WatchScript = (Join-Path -Path $PSScriptRoot -ChildPath 'miplay-netwatch.ps1')
)

$ErrorActionPreference = 'Stop'
$startupDir = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupDir '小米妙播网络守护.lnk'
$launcherPath = Join-Path $PSScriptRoot 'miplay-netwatch-launcher.vbs'

function Test-IsElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-NetwatchProcess {
    # 只认「以 -File 方式运行 miplay-netwatch.ps1」的进程，避免误命中命令行里只是包含该文件名的其它 shell
    @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' or Name='powershell.exe'" | Where-Object {
        if ($_.ProcessId -eq $PID -or -not $_.CommandLine) { return $false }
        $m = [regex]::Match($_.CommandLine, '-File\s+(?:"([^"]+)"|''([^'']+)''|(.+))\s*$')
        if (-not $m.Success) { return $false }
        $arg = $m.Groups[1].Value
        if (-not $arg) { $arg = $m.Groups[2].Value }
        if (-not $arg) { $arg = $m.Groups[3].Value }
        return ([IO.Path]::GetFileName($arg) -ieq 'miplay-netwatch.ps1')
    })
}

function Find-Pwsh {
    $c = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $fallback = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $fallback) { return $fallback }
    throw '找不到 pwsh.exe 或 powershell.exe'
}

# ---- 卸载 ----
if ($Uninstall) {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        try { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false; "已删除计划任务：$TaskName" }
        catch { "删除计划任务失败：$($_.Exception.Message)" }
    }
    if (Test-Path -LiteralPath $shortcutPath) { Remove-Item -LiteralPath $shortcutPath -Force; "已删除旧启动项：$shortcutPath" }
    if (Test-Path -LiteralPath $launcherPath) { Remove-Item -LiteralPath $launcherPath -Force; "已删除旧启动器：$launcherPath" }
    foreach ($p in (Get-NetwatchProcess)) {
        try { Stop-Process -Id $p.ProcessId -Force; "已结束守护进程 pid=$($p.ProcessId)" } catch { }
    }
    '卸载完成。注意：程序文件里的 IfType 字节不会被自动改回原厂，如需还原请运行 set-iftype-mode.ps1 -Mode wifi。'
    return
}

if (-not (Test-Path -LiteralPath $WatchScript)) { throw "找不到守护脚本：$WatchScript" }

# ---- 需要管理员：自我提权 ----
if (-not (Test-IsElevated)) {
    "需要管理员权限（守护要改写 Program Files 下的程序文件），正在请求提权……"
    # 提权后的进程在另一个窗口，输出抓不到，所以让它把全过程 tee 到日志文件
    $runLog = Join-Path $PSScriptRoot 'install-elevated.log'
    $inner = '& ''' + $PSCommandPath + ''' -TaskName ''' + $TaskName + ''''
    if ($NoIfType) { $inner += ' -NoIfType' }
    $cmd = $inner + ' *>&1 | Tee-Object -FilePath ''' + $runLog + ''''
    $p = Start-Process -FilePath (Find-Pwsh) -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $cmd) -Verb RunAs -PassThru
    $p.WaitForExit()
    "提权进程已退出（exit=$($p.ExitCode)），日志：$runLog"
    if (Test-Path -LiteralPath $runLog) { Get-Content -LiteralPath $runLog }
    return
}

$pwsh = Find-Pwsh

# 1) 结束旧守护（可能是启动文件夹拉起的非提权实例）
foreach ($p in (Get-NetwatchProcess)) {
    try { Stop-Process -Id $p.ProcessId -Force; "已结束旧守护进程 pid=$($p.ProcessId)" } catch { }
}

# 2) 清掉旧的启动文件夹入口，避免出现两个实例（一个提权、一个不提权）
if (Test-Path -LiteralPath $shortcutPath) { Remove-Item -LiteralPath $shortcutPath -Force; "已移除旧启动项：$shortcutPath" }
if (Test-Path -LiteralPath $launcherPath) { Remove-Item -LiteralPath $launcherPath -Force; "已移除旧启动器（改用计划任务）" }

# 3) 注册计划任务（登录触发，最高权限）
$actionArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $WatchScript + '"'
if ($NoIfType) { $actionArgs += ' -NoIfType' }
$action = New-ScheduledTaskAction -Execute $pwsh -Argument $actionArgs -WorkingDirectory $PSScriptRoot
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$settings.Hidden = $true
$settings.DisallowStartIfOnBatteries = $false

$existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    "已删除同名旧计划任务：$TaskName"
}
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description '小米妙播/音频共享：网络切换后统一切换发现身份网卡类型并重启 MiPCAudio 以重新注册 milink' | Out-Null
"已注册计划任务：$TaskName（登录时自动以最高权限启动）"

# 4) 立刻启动一次
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 3
$now = Get-NetwatchProcess
if ($now.Count -gt 0) {
    "守护进程已启动 pid=$($now[0].ProcessId)"
} else {
    '警告：守护进程似乎没有起来，请运行 schtasks /query /tn MiPlayNetWatch /v /fo list 检查'
}

"日志文件：$(Join-Path $PSScriptRoot 'miplay-netwatch.log')"
"发现身份切换日志：$(Join-Path $PSScriptRoot 'set-iftype-mode.log')"
'安装完成。以后插拔网线 / Wi-Fi 连上断开，守护会先把三处 IfType 统一到当前活跃介质，再重启妙播。'
