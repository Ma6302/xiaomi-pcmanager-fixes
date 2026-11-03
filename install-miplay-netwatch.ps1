#requires -Version 5.1
<#
 install-miplay-netwatch.ps1
 ---------------------------------------------------------------------------
 把 miplay-netwatch.ps1 装成「登录后自动在后台运行」的守护进程。

 做法（不需要管理员权限）：在启动文件夹里放一个隐藏启动器，
 登录 Windows 后自动以无窗口方式跑 pwsh -File miplay-netwatch.ps1。

 参数：
   -Uninstall   卸载（删除启动项与启动器）

 用法：
   pwsh -File .\install-miplay-netwatch.ps1
   pwsh -File .\install-miplay-netwatch.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$Uninstall,
    [string]$WatchScript = (Join-Path -Path $PSScriptRoot -ChildPath 'miplay-netwatch.ps1')
)

$ErrorActionPreference = 'Stop'
$startupDir = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startupDir '小米妙播网络守护.lnk'
$launcherPath = Join-Path $PSScriptRoot 'miplay-netwatch-launcher.vbs'

function Get-NetwatchProcess {
    # 只认「以 -File 方式运行 miplay-netwatch.ps1」的进程，避免误命中命令行里只是包含该文件名的其它 shell
    @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' or Name='powershell.exe'" | Where-Object {
        if ($_.ProcessId -eq $PID -or -not $_.CommandLine) { return $false }
        $m = [regex]::Match($_.CommandLine, '-File\s+(?:"([^"]+)"|''([^'']+)''|(\S+))')
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

if ($Uninstall) {
    if (Test-Path -LiteralPath $shortcutPath) { Remove-Item -LiteralPath $shortcutPath -Force; "已删除启动项：$shortcutPath" }
    if (Test-Path -LiteralPath $launcherPath) { Remove-Item -LiteralPath $launcherPath -Force; "已删除启动器：$launcherPath" }
    $running = Get-NetwatchProcess
    foreach ($p in $running) { try { Stop-Process -Id $p.ProcessId -Force; "已结束守护进程 pid=$($p.ProcessId)" } catch { } }
    '卸载完成。'
    return
}

if (-not (Test-Path -LiteralPath $WatchScript)) { throw "找不到守护脚本：$WatchScript" }

$pwsh = Find-Pwsh
$psArgs = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$WatchScript`""
# 启动器里要执行的完整命令行（注意 VBS 字符串内所有双引号都要写成两个）
$cmdLine = '"' + $pwsh + '" -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $WatchScript + '"'
$vbsCmd = $cmdLine.Replace('"', '""')

# 1) 生成隐藏启动器（VBS 以窗口模式 0 启动，不闪黑框；必须用 Unicode 存盘，否则中文路径会变问号）
$vbs = @"
Set sh = CreateObject("WScript.Shell")
sh.Run "$vbsCmd", 0, False
"@
Set-Content -LiteralPath $launcherPath -Value $vbs -Encoding Unicode
"已生成启动器：$launcherPath"

# 2) 在启动文件夹放快捷方式
$wsh = New-Object -ComObject WScript.Shell
$lnk = $wsh.CreateShortcut($shortcutPath)
$lnk.TargetPath = "$env:SystemRoot\System32\wscript.exe"
$lnk.Arguments = '"' + $launcherPath + '"'
$lnk.WorkingDirectory = $PSScriptRoot
$lnk.WindowStyle = 7
$lnk.Description = '小米妙播/音频共享：网络切换后自动重启 MiPCAudio 以重新注册 milink'
$lnk.Save()
"已创建启动项：$shortcutPath"

# 3) 立即启动一次（若已有守护在跑则跳过）
$already = Get-NetwatchProcess
if ($already.Count -gt 0) {
    "守护进程已在运行 pid=$($already[0].ProcessId)，不再重复启动"
} else {
    Start-Process -FilePath $pwsh -ArgumentList $psArgs -WindowStyle Hidden
    Start-Sleep -Seconds 2
    $now = Get-NetwatchProcess
    if ($now.Count -gt 0) { "守护进程已启动 pid=$($now[0].ProcessId)" } else { '警告：守护进程似乎没有起来，请手动运行看报错' }
}

"日志文件：$(Join-Path $PSScriptRoot 'miplay-netwatch.log')"
'安装完成。以后网络切换（插拔网线 / Wi-Fi 连上断开）会自动重启妙播子进程。'


