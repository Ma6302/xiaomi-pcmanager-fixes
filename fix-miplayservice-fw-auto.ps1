<#
  小米电脑管家「防火墙规则缺失」自动修复（版本无关 / 幂等）

  背景：电脑管家 6.0.0.39 的安装器给 MiPlayCastService.exe 只写了 2 条入站规则，
        而自检要求 入站/出站 x TCP/UDP 四条，且「修复」按钮空转 → 提示无限循环。
        详见 README.md。

  用法：
    pwsh -File .\fix-miplayservice-fw-auto.ps1
    （脚本检测到自己不是管理员时会自己弹 UAC 重新启动）

  与 fix-miplayservice-fw.ps1 / fix2.ps1 的区别：
    - 自动探测 C:\Program Files\MI\XiaomiPCManager\ 下版本号最高的目录，升级后不用改脚本
    - 幂等：已存在的规则不会重复添加
    - 日志写到脚本同目录 fix-auto-<时间戳>.log
#>

$ErrorActionPreference = 'Continue'

# ---------- 自提权 ----------
$isAdmin = ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole('Administrators')
if (-not $isAdmin) {
    Write-Host '需要管理员权限，正在请求 UAC …'
    $args0 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"")
    Start-Process -FilePath (Get-Process -Id $PID).Path -ArgumentList $args0 -Verb RunAs
    return
}

$scriptDir = Split-Path -Parent $PSCommandPath
$log = Join-Path $scriptDir ('fix-auto-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
function L($m) {
    $line = '{0} {1}' -f (Get-Date -Format 'HH:mm:ss'), $m
    Add-Content -LiteralPath $log -Value $line -Encoding utf8
    Write-Host $line
}

L '=== 小米电脑管家防火墙规则自动修复 ==='

# ---------- 1) 探测当前版本与目标程序 ----------
$root = Join-Path $env:ProgramFiles 'MI\XiaomiPCManager'
if (-not (Test-Path -LiteralPath $root)) { L "找不到安装目录：$root"; return }

$verDir = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^\d+(\.\d+){1,3}$' } |
    Sort-Object { [version]$_.Name } -Descending |
    Select-Object -First 1
if (-not $verDir) { L "安装目录下没有版本文件夹：$root"; return }

$exe = Join-Path $verDir.FullName 'MiSmartShare\MiPlayCastService.exe'
L "版本目录：$($verDir.Name)"
L "目标程序：$exe"
if (-not (Test-Path -LiteralPath $exe)) { L '目标程序不存在，退出（该版本可能换了安装结构）'; return }

# ---------- 2) 现状 ----------
function Get-Rules {
    Get-NetFirewallRule -DisplayName '*MiplayCast*' -ErrorAction SilentlyContinue | ForEach-Object {
        $af = $_ | Get-NetFirewallApplicationFilter
        $pf = $_ | Get-NetFirewallPortFilter
        [pscustomobject]@{
            Name        = $_.Name
            DisplayName = $_.DisplayName
            Direction   = $_.Direction
            Protocol    = $pf.Protocol
            Program     = $af.Program
            Enabled     = $_.Enabled
            Action      = $_.Action
            Profile     = $_.Profile
            Description = $_.Description
        }
    }
}

$before = @(Get-Rules)
L "--- 修复前（共 $($before.Count) 条） ---"
foreach ($r in $before) {
    L ("BEFORE {0} dir={1} proto={2} prof={3} en={4} act={5} desc='{6}' prog={7}" -f $r.Name, $r.Direction, $r.Protocol, $r.Profile, $r.Enabled, $r.Action, $r.Description, $r.Program)
}

# ---------- 3) 规范化：名字对齐、描述清空、确保 Allow/Enabled ----------
foreach ($r in $before) {
    try {
        Set-NetFirewallRule -Name $r.Name -NewDisplayName 'MiPlayCastService' -Enabled True -Action Allow -Profile Any -ErrorAction Stop
        Set-NetFirewallRule -Name $r.Name -Description '' -ErrorAction Stop
        L "normalized $($r.Name)"
    } catch { L "normalize $($r.Name) 失败：$($_.Exception.Message)" }
}

# ---------- 4) 按需补齐 入站/出站 x TCP/UDP ----------
foreach ($dir in @('in', 'out')) {
    foreach ($proto in @('tcp', 'udp')) {
        $have = @(Get-Rules | Where-Object {
                $_.Program -eq $exe -and $_.Direction -eq $(if ($dir -eq 'in') { 'Inbound' } else { 'Outbound' }) -and
                $_.Protocol -eq $proto.ToUpper()
            })
        if ($have.Count -gt 0) { L "SKIP $dir/$proto 已存在（$($have[0].Name)）"; continue }
        $out = & netsh advfirewall firewall add rule name=MiPlayCastService dir=$dir action=allow program="$exe" enable=yes profile=any protocol=$proto 2>&1
        L "ADD $dir/$proto => $($out -join ' ')"
    }
}

# ---------- 5) 复核 ----------
$after = @(Get-Rules)
L "--- 修复后（共 $($after.Count) 条） ---"
foreach ($r in $after) {
    L ("FINAL {0} dir={1} proto={2} prof={3} en={4} act={5} desc='{6}' prog={7}" -f $r.Name, $r.Direction, $r.Protocol, $r.Profile, $r.Enabled, $r.Action, $r.Description, $r.Program)
}
$ok = @(Get-Rules | Where-Object { $_.Program -eq $exe })
$need = 4
L "当前版本目标程序规则数：$($ok.Count)（期望 $need 条：In/Out x TCP/UDP）"
if ($ok.Count -ge $need) { L '结论：四条规则齐全，提示应该会消失' } else { L '结论：规则仍不足，请把本日志发出来排查' }
L "日志：$log"
L '=== 结束 ==='

if ($Host.Name -eq 'ConsoleHost') { Read-Host '按回车关闭' | Out-Null }
