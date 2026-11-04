<#
.SYNOPSIS
    把改造版的 MiDrop Helper 组件（MiDrop.Helper.exe / ShellExt.dll）部署进已安装的
    "MiDrop Helper" MSIX 包（或从备份还原）。

.DESCRIPTION
    包里有两个文件需要换：
      1) MiDrop.Helper\MiDrop.Helper.exe —— 真正发文件的进程（用 PackageInstallLocation 拼路径，
         只能放回包目录）。
      2) ShellExt\ShellExt.dll          —— Win11 现代右键菜单的 COM 扩展（图标 + 点击入口）。
    本脚本对每个文件：备份原件 -> 接管所有权/授权 -> 覆盖 -> 哈希校验 -> 还原 ACL/所有者。

    需要管理员权限（会触发 UAC）。

.PARAMETER Source
    改造版 MiDrop.Helper.exe 的路径。

.PARAMETER ShellExtSource
    改造版 ShellExt.dll 的路径。

.PARAMETER Restore
    从 backup\ 里的原件备份还原（有多少备份就还原多少）。

.EXAMPLE
    pwsh -File .\apply-midrop-helper.ps1 -Source ..\..\MiDropPatchWork\out-patched\MiDrop.Helper.exe `
        -ShellExtSource ..\..\MiDropPatchWork\out-shellext\ShellExt.dll

.EXAMPLE
    pwsh -File .\apply-midrop-helper.ps1 -Restore
#>
param(
    [string]$Source,
    [string]$ShellExtSource,
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$backupDir = Join-Path $scriptDir 'backup'
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
        Write-Log "  所有者已改回 NT SERVICE\TrustedInstaller"
    }
    catch {
        Write-Log "  改所有者失败（不影响运行）: $($_.Exception.Message)"
    }
}

# 备份 -> 接管 -> 覆盖 -> 校验 -> 还原 ACL/所有者
function Deploy-File {
    param(
        [Parameter(Mandatory = $true)][string]$Target,      # 包内绝对路径
        [Parameter(Mandatory = $true)][string]$BackupFile,  # backup\ 下的备份路径
        [Parameter(Mandatory = $true)][byte[]]$Payload,
        [Parameter(Mandatory = $true)][string]$Label
    )

    Write-Log "[$Label] 目标: $Target"

    if (-not (Test-Path -LiteralPath $Target)) { throw "找不到 $Target" }

    # 1) 备份原文件（用字节流，避开 WindowsApps 里文件的 EFS 属性复制问题）
    if (-not (Test-Path -LiteralPath $BackupFile)) {
        [System.IO.File]::WriteAllBytes($BackupFile, [System.IO.File]::ReadAllBytes($Target))
        Write-Log "[$Label] 已备份原文件 -> $BackupFile"
    } else {
        Write-Log "[$Label] 备份已存在: $BackupFile"
    }

    # 2) 接管所有权 + 授予管理员写权限（仅针对这一个文件）
    & takeown.exe /f $Target /a | Out-Null
    & icacls.exe $Target /grant '*S-1-5-32-544:(F)' | Out-Null

    # 3) 覆盖
    [System.IO.File]::WriteAllBytes($Target, $Payload)
    Write-Log "[$Label] 已写入 $($Payload.Length) 字节"

    # 4) 校验
    $newHash = (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash
    $expectHash = ([BitConverter]::ToString([System.Security.Cryptography.SHA256]::Create().ComputeHash($Payload)) -replace '-', '')
    Write-Log "[$Label] 目标 SHA256 = $newHash"
    if ($newHash -ne $expectHash) { throw "[$Label] 写入校验失败：期望 $expectHash" }
    Write-Log "[$Label] 哈希校验通过"

    # 5) 还原显式授权与所有者
    & icacls.exe $Target /remove:g '*S-1-5-32-544' | Out-Null
    Restore-Owner -Path $Target
    Write-Log "[$Label] 当前所有者: $((Get-Acl -LiteralPath $Target).Owner)"
}

try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw '需要管理员权限，请用管理员身份运行本脚本。' }

    if (-not $Source -and -not $ShellExtSource -and -not $Restore) {
        throw '至少要指定 -Source / -ShellExtSource / -Restore 之一。'
    }

    $pkg = Get-AppxPackage | Where-Object { $_.PackageFullName -match '5f71dad9' } | Select-Object -First 1
    if (-not $pkg) { throw '未找到 MiDrop Helper 包（5f71dad9-...）。请先在商店/侧载安装 MiDrop Helper。' }

    Write-Log "包: $($pkg.PackageFullName)"
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

    $helperTarget = Join-Path $pkg.InstallLocation 'MiDrop.Helper\MiDrop.Helper.exe'
    $helperBackup = Join-Path $backupDir 'MiDrop.Helper.exe.orig-1.0.7.0'
    $shellTarget = Join-Path $pkg.InstallLocation 'ShellExt\ShellExt.dll'
    $shellBackup = Join-Path $backupDir 'ShellExt.dll.orig-1.0.7.0'

    if ($Restore) {
        if (-not (Test-Path -LiteralPath $helperBackup)) { throw "没有 helper 备份: $helperBackup" }
        Write-Log '还原模式：使用备份覆盖'
        Deploy-File -Target $helperTarget -BackupFile $helperBackup -Label 'MiDrop.Helper.exe' `
            -Payload ([System.IO.File]::ReadAllBytes($helperBackup))
        if (Test-Path -LiteralPath $shellBackup) {
            Deploy-File -Target $shellTarget -BackupFile $shellBackup -Label 'ShellExt.dll' `
                -Payload ([System.IO.File]::ReadAllBytes($shellBackup))
        } else {
            Write-Log '[ShellExt.dll] 没有备份，跳过还原'
        }
        Write-Log '完成'
        exit 0
    }

    if ($Source) {
        if (-not (Test-Path -LiteralPath $Source)) { throw "找不到源文件 $Source" }
        $helperPayload = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $Source))
        Write-Log "helper 源文件: $Source ($($helperPayload.Length) 字节)"
        Deploy-File -Target $helperTarget -BackupFile $helperBackup -Label 'MiDrop.Helper.exe' -Payload $helperPayload
    }

    if ($ShellExtSource) {
        if (-not (Test-Path -LiteralPath $ShellExtSource)) { throw "找不到源文件 $ShellExtSource" }
        $shellPayload = [System.IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $ShellExtSource))
        Write-Log "ShellExt 源文件: $ShellExtSource ($($shellPayload.Length) 字节)"
        Deploy-File -Target $shellTarget -BackupFile $shellBackup -Label 'ShellExt.dll' -Payload $shellPayload
    }

    Write-Log '完成'
    exit 0
}
catch {
    Write-Log "失败: $($_.Exception.Message)"
    exit 1
}
