# Restore MiPCAudio.exe after hide-mipcaudio.ps1
$ErrorActionPreference = 'Continue'
$log = Join-Path $PSScriptRoot 'unhide-mipcaudio.log'
function W($m) { ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) | Tee-Object -FilePath $log -Append | Out-Host }

$ver = (Get-ChildItem 'C:\Program Files\MI\XiaomiPCManager' -Directory | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1).Name
$dir = "C:\Program Files\MI\XiaomiPCManager\$ver\MiSmartShare"
$exe = Join-Path $dir 'MiPCAudio.exe'
$hold = Join-Path $dir 'MiPCAudio.exe.hiddenhold'

if (-not (Test-Path $hold)) { W "no hold file - nothing to restore"; }
else {
    try {
        if (Test-Path $exe) { W "exe already exists; check manually"; }
        else { Rename-Item -LiteralPath $hold -NewName 'MiPCAudio.exe' -ErrorAction Stop; W "restored exe" }
    } catch { W ("restore failed: " + $_.Exception.Message) }
}

for ($i = 0; $i -lt 30; $i++) {
    Start-Sleep -Seconds 1
    $p = Get-Process MiPCAudio -ErrorAction SilentlyContinue
    if ($p) { W "MiPCAudio running pid=$($p.Id)"; break }
}
$p2 = Get-Process MiPCAudio -ErrorAction SilentlyContinue
if (-not $p2) { W "still not running - start XiaomiPCManager or log off/on to relaunch" }
