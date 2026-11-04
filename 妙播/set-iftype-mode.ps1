#requires -Version 5.1
<#
  set-iftype-mode.ps1
  ---------------------------------------------------------------------------
  用途：把小米电脑管家「妙播 / 音频共享」的设备发现身份，在「无线」与「有线」
        两种模式之间切换。

  背景（结论来自 Higanoneko/MiPCManager_Patch 的逆分析与我们自己的实测）：
    电脑会同时通过两套机制把自己发布成音频目标：
      - Lyra / netbus（type8）      -> MiPCAudio.exe
      - IDM（type2）                -> idmruntime.dll
    两套的身份都取自「某张网卡的 MAC」，而挑选网卡的判断 IfType == 0x47(Wi-Fi)
    一共有三处。三处取到的网卡一致，手机才会把两套合并成一个设备；
    只要有一处分歧，手机列表里就会出现两条同名设备（一条能用、一条空转）。

  三处站点（本脚本自动定位，不写死偏移）：
    MiPCAudio.exe  41 83 79 64 ?? 75        (?? = 47/06)  Lyra 身份
    idmruntime.dll 41 83 7e 64 ?? 0F 85                  IDM「取 Wi-Fi 网卡 MAC」
    idmruntime.dll 83 7b 64 ?? 75                        IDM 另一条取 MAC 路径

  0x47 = IF_TYPE_IEEE80211（无线）   0x06 = IF_TYPE_ETHERNET_CSMACD（有线）
  原厂文件三处都是 0x47。

  参数：
    -Mode lan    三处都改 0x06（有线身份，纯有线环境用）
    -Mode wifi   三处都改 0x47（无线身份 = 原厂状态）
    -Mode status 只读取当前三处取值，不改任何字节（默认）
    -DryRun      只报告将要做什么，不写文件
    -VersionDir  指定版本目录（默认自动探测 C:\Program Files\MI\XiaomiPCManager 下最高版本）
    -LogPath     日志路径（默认脚本同目录 set-iftype-mode.log）

  需要管理员权限（写 Program Files）。运行中的 exe/dll 被占用时，自动改用
  「改名 -> 写新文件」的方式替换，遗留的 .swap-* 文件在下次运行时会尝试清理。
#>
[CmdletBinding()]
param(
    [ValidateSet('lan', 'wifi', 'status')]
    [string]$Mode = 'status',
    [switch]$DryRun,
    [switch]$Clean,
    [string]$VersionDir,
    [string]$LogPath
)

$ErrorActionPreference = 'Stop'

if (-not $LogPath) { $LogPath = Join-Path -Path $PSScriptRoot -ChildPath 'set-iftype-mode.log' }

$IFTYPE_WIFI = 0x47
$IFTYPE_ETH = 0x06

$Sites = @(
    [pscustomobject]@{ File = 'MiPCAudio.exe'; Label = 'MiPCAudio/Lyra'; Prefix = [byte[]](0x41, 0x83, 0x79, 0x64); Suffix = [byte[]](0x75) },
    [pscustomobject]@{ File = 'idmruntime.dll'; Label = 'IDM/getWifiAdapterMac'; Prefix = [byte[]](0x41, 0x83, 0x7e, 0x64); Suffix = [byte[]](0x0F, 0x85) },
    [pscustomobject]@{ File = 'idmruntime.dll'; Label = 'IDM/altMacPath'; Prefix = [byte[]](0x83, 0x7b, 0x64); Suffix = [byte[]](0x75) }
)

function Write-Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Host $line
    try {
        if ((Test-Path -LiteralPath $LogPath) -and ((Get-Item -LiteralPath $LogPath).Length -gt 512KB)) {
            Move-Item -LiteralPath $LogPath -Destination ($LogPath + '.old') -Force -ErrorAction SilentlyContinue
        }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8 -ErrorAction SilentlyContinue
    } catch { }
}

function Get-InstallVersionDir {
    if ($VersionDir) {
        if (-not (Test-Path -LiteralPath $VersionDir)) { throw "版本目录不存在：$VersionDir" }
        return $VersionDir
    }
    $root = 'C:\Program Files\MI\XiaomiPCManager'
    if (-not (Test-Path -LiteralPath $root)) { throw "找不到小米电脑管家安装目录：$root" }
    $dirs = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+(\.\d+){1,3}$' } |
        Sort-Object { [version]$_.Name } -Descending)
    if ($dirs.Count -eq 0) { throw "在 $root 下没有找到版本号目录" }
    return $dirs[0].FullName
}

function Find-SiteOffset {
    param([byte[]]$Bytes, [byte[]]$Prefix, [byte[]]$Suffix, [string]$Label)
    $hits = New-Object System.Collections.ArrayList
    for ($i = 0; $i -le ($Bytes.Length - $Prefix.Length - $Suffix.Length - 1); $i++) {
        $ok = $true
        for ($j = 0; $j -lt $Prefix.Length; $j++) {
            if ($Bytes[$i + $j] -ne $Prefix[$j]) { $ok = $false; break }
        }
        if (-not $ok) { continue }
        $vi = $i + $Prefix.Length
        if (($Bytes[$vi] -ne $IFTYPE_WIFI) -and ($Bytes[$vi] -ne $IFTYPE_ETH)) { continue }
        $ok2 = $true
        for ($j = 0; $j -lt $Suffix.Length; $j++) {
            if ($Bytes[$vi + 1 + $j] -ne $Suffix[$j]) { $ok2 = $false; break }
        }
        if ($ok2) { [void]$hits.Add($vi) }
    }
    if ($hits.Count -ne 1) {
        throw ('站点定位失败 [{0}]：命中 {1} 处（期望 1 处）。这个版本的程序文件特征和脚本不符，已放弃改动。' -f $Label, $hits.Count)
    }
    return [int]$hits[0]
}

function Get-ModeName {
    param([byte]$Value)
    switch ($Value) {
        $IFTYPE_WIFI { return 'wifi' }
        $IFTYPE_ETH { return 'lan' }
        default { return ('unknown(0x{0:X2})' -f $Value) }
    }
}

function Resolve-TargetPath {
    param([string]$Dir, [string]$FileName)
    $direct = Join-Path $Dir $FileName
    if (Test-Path -LiteralPath $direct) { return $direct }
    $sub = Join-Path (Join-Path $Dir 'MiSmartShare') $FileName
    if (Test-Path -LiteralPath $sub) { return $sub }
    $found = @(Get-ChildItem -LiteralPath $Dir -Recurse -Filter $FileName -File -ErrorAction SilentlyContinue |
        Sort-Object Length -Descending | Select-Object -First 1)
    if ($found.Count -gt 0) { return $found[0].FullName }
    throw "找不到目标文件：$Dir\$FileName"
}

function Get-SiteStates {
    param([string]$Dir)
    $states = @()
    $cache = @{}
    foreach ($s in $Sites) {
        $path = Resolve-TargetPath -Dir $Dir -FileName $s.File
        if (-not $cache.ContainsKey($path)) { $cache[$path] = [IO.File]::ReadAllBytes($path) }
        $bytes = $cache[$path]
        $offset = Find-SiteOffset -Bytes $bytes -Prefix $s.Prefix -Suffix $s.Suffix -Label $s.Label
        $states += [pscustomobject]@{
            File   = $s.File
            Label  = $s.Label
            Path   = $path
            Offset = $offset
            Value  = $bytes[$offset]
            Mode   = (Get-ModeName -Value $bytes[$offset])
        }
    }
    return $states
}

function Remove-StaleArtifacts {
    param([string]$Dir)
    $dirs = @($Dir)
    $sub = Join-Path $Dir 'MiSmartShare'
    if (Test-Path -LiteralPath $sub) { $dirs += $sub }
    foreach ($d in $dirs) {
        foreach ($name in @('MiPCAudio.exe', 'idmruntime.dll')) {
            foreach ($pattern in @("$name.new", "$name.swap-*")) {
                Get-ChildItem -LiteralPath $d -Filter $pattern -File -ErrorAction SilentlyContinue | ForEach-Object {
                    try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop; Write-Log ('清理遗留文件：' + $_.Name) }
                    catch { Write-Log ('遗留文件暂无法删除（仍被占用）：' + $_.Name) }
                }
            }
        }
    }
}

function Save-FactoryBackup {
    param([string]$Path, [byte[]]$Bytes)
    $bak = $Path + '.orig.bak'
    if (Test-Path -LiteralPath $bak) { return }
    # 只有确认三处都还是原厂的 0x47 时才把当前文件当作出厂备份，避免备份到中间状态
    $isFactory = $true
    foreach ($s in $Sites) {
        if ($s.File -ne (Split-Path -Leaf $Path)) { continue }
        $off = Find-SiteOffset -Bytes $Bytes -Prefix $s.Prefix -Suffix $s.Suffix -Label $s.Label
        if ($Bytes[$off] -ne $IFTYPE_WIFI) { $isFactory = $false }
    }
    if (-not $isFactory) { Write-Log ('跳过出厂备份（当前不是原厂字节）：' + (Split-Path -Leaf $Path)); return }
    try {
        [IO.File]::WriteAllBytes($bak, $Bytes)
        Write-Log ('已保存出厂备份：' + (Split-Path -Leaf $bak))
    } catch { Write-Log ('保存出厂备份失败：' + $_.Exception.Message) }
}

function Write-BytesReplacingFile {
    param([string]$Path, [byte[]]$Bytes)
    # 首选直接写（进程未占用时）
    try {
        $fs = [IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
        try { $fs.Write($Bytes, 0, $Bytes.Length) } finally { $fs.Dispose() }
        return 'direct'
    } catch {
        Write-Log ('直接写入被占用，改用改名替换：' + (Split-Path -Leaf $Path) + ' (' + $_.Exception.Message.Split([char]10)[0] + ')')
    }
    # 改名替换：运行中的 exe 可以改名，再把新文件放到原名
    $tmp = $Path + '.new'
    $swap = $Path + ('.swap-' + (Get-Date -Format 'yyyyMMddHHmmss'))
    [IO.File]::WriteAllBytes($tmp, $Bytes)
    try {
        Rename-Item -LiteralPath $Path -NewName (Split-Path -Leaf $swap) -ErrorAction Stop
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw ('改名失败，无法替换 ' + (Split-Path -Leaf $Path) + '：' + $_.Exception.Message)
    }
    try {
        Copy-Item -LiteralPath $tmp -Destination $Path -Force -ErrorAction Stop
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    } catch {
        # 失败回滚：把原文件改回原名
        try { Rename-Item -LiteralPath $swap -NewName (Split-Path -Leaf $Path) -ErrorAction Stop } catch { }
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw ('写入新文件失败，已回滚：' + $_.Exception.Message)
    }
    try { Remove-Item -LiteralPath $swap -Force -ErrorAction Stop } catch { Write-Log ('旧文件暂无法删除（进程仍占用，下次运行会清理）：' + (Split-Path -Leaf $swap)) }
    return 'rename'
}

# ---------------------------------------------------------------- main
try {
    $dir = Get-InstallVersionDir
    Write-Log ('版本目录：' + $dir)

    if ($Clean) {
        Remove-StaleArtifacts -Dir $dir
        Write-Log '清理完成。'
        exit 0
    }

    $states = Get-SiteStates -Dir $dir
    foreach ($s in $states) {
        Write-Log ('当前状态 {0,-14} {1,-22} offset=0x{2:X} value=0x{3:X2} ({4})' -f $s.File, $s.Label, $s.Offset, $s.Value, $s.Mode)
    }

    if ($Mode -eq 'status') {
        $modes = @($states | ForEach-Object { $_.Mode } | Sort-Object -Unique)
        if ($modes.Count -eq 1) { Write-Log ('结论：三处一致 -> ' + $modes[0]) }
        else { Write-Log ('结论：三处不一致 -> ' + ($modes -join ',') + '（这正是手机端出现两条同名设备的原因）') }
        exit 0
    }

    $target = if ($Mode -eq 'lan') { $IFTYPE_ETH } else { $IFTYPE_WIFI }
    $need = @($states | Where-Object { $_.Value -ne $target })
    if ($need.Count -eq 0) {
        Write-Log ('三处已是 {0} 模式，无需改动。' -f $Mode)
        exit 0
    }

    if ($DryRun) {
        Write-Log ('DRYRUN 将把 {0} 处站点改为 {1} 模式：{2}' -f $need.Count, $Mode, (($need | ForEach-Object { $_.File + '/' + $_.Label }) -join ', '))
        # 退出码约定：3 = 需要改动（供调用方判断），0 = 无需改动
        exit 3
    }

    Remove-StaleArtifacts -Dir $dir

    foreach ($group in ($states | Group-Object File)) {
        $path = $group.Group[0].Path
        $bytes = [IO.File]::ReadAllBytes($path)
        Save-FactoryBackup -Path $path -Bytes $bytes
        $changed = 0
        foreach ($st in $group.Group) {
            # 重新定位（同一文件可能刚被写过），并校验偏移一致
            $off = Find-SiteOffset -Bytes $bytes -Prefix (($Sites | Where-Object { $_.File -eq $st.File -and $_.Label -eq $st.Label }).Prefix) -Suffix (($Sites | Where-Object { $_.File -eq $st.File -and $_.Label -eq $st.Label }).Suffix) -Label $st.Label
            if ($off -ne $st.Offset) { Write-Log ('警告：偏移变化 0x{0:X} -> 0x{1:X}' -f $st.Offset, $off) }
            if ($bytes[$off] -ne $target) { $bytes[$off] = $target; $changed++ }
        }
        if ($changed -eq 0) { Write-Log ('已是目标模式，跳过：' + $group.Name); continue }
        $how = Write-BytesReplacingFile -Path $path -Bytes $bytes
        Write-Log ('已改写 {0}：{1} 处 -> {2} 模式（{3}）' -f $group.Name, $changed, $Mode, $how)
    }

    # 复核
    $after = Get-SiteStates -Dir $dir
    foreach ($s in $after) {
        Write-Log ('复核 {0,-14} {1,-22} value=0x{2:X2} ({3})' -f $s.File, $s.Label, $s.Value, $s.Mode)
    }
    $bad = @($after | Where-Object { $_.Value -ne $target })
    if ($bad.Count -gt 0) {
        Write-Log ('失败：仍有 {0} 处没有变成目标模式' -f $bad.Count)
        exit 2
    }
    Write-Log ('完成：三处已统一为 {0} 模式。' -f $Mode)
    exit 0
} catch {
    Write-Log ('错误：' + $_.Exception.Message)
    exit 1
}
