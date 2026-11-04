<#
.SYNOPSIS
    把改造版 MiDrop.Helper.exe 部署进已安装的 "MiDrop Helper" MSIX 包（或从备份还原）。

.DESCRIPTION
    MiDrop Helper 的 ShellExt.dll 用 PackageInstallLocation 拼 helper 路径，
    因此改造版必须放回包目录 C:\Program Files\WindowsApps\<包>\MiDrop.Helper\MiDrop.Helper.exe。
    本脚本会：备份原文件 -> 接管该文件所有权 -> 覆盖 -> 恢复所有者/ACL。

    需要管理员权限（会触发 UAC）。

.PARAMETER Source
    改造版 MiDrop.Helper.exe 的路径。

.PARAMETER Restore
    从备份（backup\MiDrop.Helper.exe.orig）还原原版。

.EXAMPLE
    pwsh -File .\apply-midrop-helper.ps1 -Source ..\build\MiDrop.Helper.exe
#>
param(
    [string]$Source,
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$backupDir = Join-Path $scriptDir 'backup'
$backupFile = Join-Path $backupDir 'MiDrop.Helper.exe.orig-1.0.7.0'
$logPath = Join-Path $scriptDir 'apply-midrop-helper.log'

function Write-Log([string]$Message) {
    $line = "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $Message
    Write-Host $line
    Add-Content -Path $logPath -Value $line -Encoding UTF8
}

# 把所有者改回 TrustedInstaller 需要 SeRestorePrivilege；
# icacls /setowner 在这个文件上会静默失败（所有者停在 BUILTIN\Administrators），
# 所以这里自己开特权再 Set-Acl。
function Restore-Owner([string]$Path) {
    try {
        if (-not ('MidropPriv' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class MidropPriv {
    [StructLayout(LayoutKind.Sequential)] public struct LUID { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] public struct TOKEN_PRIVILEGES { public uint PrivilegeCount; public LUID Luid; public uint Attributes; }
    [DllImport("advapi32.dll", SetLastError = true)] public static extern bool OpenProcessToken(IntPtr h, uint acc, out IntPtr tok);
    [DllImport("advapi32.dll", SetLastError = true)] public static extern bool LookupPrivilegeValue(string sys, string name, out LUID luid);
    [DllImport("advapi32.dll", SetLastError = true)] public static extern bool AdjustTokenPrivileges(IntPtr tok, bool dis, ref TOKEN_PRIVILEGES tp, uint len, IntPtr prev, IntPtr ret);
    [DllImport("kernel32.dll")] public static extern IntPtr GetCurrentProcess();
    public static bool Enable(string name) {
        IntPtr tok;
        if (!OpenProcessToken(GetCurrentProcess(), 0x20 | 0x8, out tok)) return false;
        LUID luid;
        if (!LookupPrivilegeValue(null, name, out luid)) return false;
        TOKEN_PRIVILEGES tp = new TOKEN_PRIVILEGES();
        tp.PrivilegeCount = 1; tp.Luid = luid; tp.Attributes = 0x2;
        return AdjustTokenPrivileges(tok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
    }
}
'@
        }
        [void][MidropPriv]::Enable('SeRestorePrivilege')
        [void][MidropPriv]::Enable('SeTakeOwnershipPrivilege')
        $acl = Get-Acl -LiteralPath $Path
        $acl.SetOwner([System.Security.Principal.NTAccount]'NT SERVICE\TrustedInstaller')
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
        Write-Log '所有者已改回 NT SERVICE\TrustedInstaller'
    }
    catch {
        Write-Log "改所有者失败（不影响运行）: $($_.Exception.Message)"
    }
}

try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw '需要管理员权限，请用管理员身份运行本脚本。' }

    $pkg = Get-AppxPackage | Where-Object { $_.PackageFullName -match '5f71dad9' } | Select-Object -First 1
    if (-not $pkg) { throw '未找到 MiDrop Helper 包（5f71dad9-...）。请先在商店/侧载安装 MiDrop Helper。' }

    $targetDir = Join-Path $pkg.InstallLocation 'MiDrop.Helper'
    $target = Join-Path $targetDir 'MiDrop.Helper.exe'
    Write-Log "包: $($pkg.PackageFullName)"
    Write-Log "目标: $target"

    if (-not (Test-Path $target)) { throw "找不到 $target" }

    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

    # 1) 备份原文件（用字节流，避开 WindowsApps 里文件的 EFS 属性复制问题）
    if (-not (Test-Path $backupFile)) {
        [System.IO.File]::WriteAllBytes($backupFile, [System.IO.File]::ReadAllBytes($target))
        Write-Log "已备份原文件 -> $backupFile"
    } else {
        Write-Log "备份已存在: $backupFile"
    }

    if ($Restore) {
        $payload = [System.IO.File]::ReadAllBytes($backupFile)
        Write-Log '还原模式：使用备份覆盖'
    } else {
        if (-not $Source) { throw '请用 -Source 指定改造版 MiDrop.Helper.exe' }
        if (-not (Test-Path $Source)) { throw "找不到源文件 $Source" }
        $payload = [System.IO.File]::ReadAllBytes((Resolve-Path $Source))
        Write-Log "源文件: $Source ($($payload.Length) 字节)"
    }

    # 2) 接管所有权 + 授予管理员写权限（仅针对这一个文件）
    & takeown.exe /f $target /a | Out-Null
    & icacls.exe $target /grant '*S-1-5-32-544:(F)' | Out-Null

    # 3) 覆盖
    [System.IO.File]::WriteAllBytes($target, $payload)
    Write-Log "已写入 $($payload.Length) 字节"

    # 4) 校验
    $newHash = (Get-FileHash -Path $target -Algorithm SHA256).Hash
    $expectHash = ([BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($payload)) -replace '-', '')
    Write-Log "目标 SHA256 = $newHash"
    if ($newHash -ne $expectHash) { throw "写入校验失败：期望 $expectHash" }
    Write-Log '哈希校验通过'

    # 5) 还原显式授权与所有者
    & icacls.exe $target /remove:g '*S-1-5-32-544' | Out-Null
    Restore-Owner -Path $target
    Write-Log "当前所有者: $((Get-Acl $target).Owner)"

    Write-Log '完成'
    exit 0
}
catch {
    Write-Log "失败: $($_.Exception.Message)"
    exit 1
}
