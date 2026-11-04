# Temporarily hide MiPCAudio.exe so the audio service cannot start (diagnostic only)
# Rename first (allowed even while the image is mapped), then kill the process.
$ErrorActionPreference = 'Continue'
$log = Join-Path $PSScriptRoot 'hide-mipcaudio.log'
function W($m) { ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) | Tee-Object -FilePath $log -Append | Out-Host }

$ver = (Get-ChildItem 'C:\Program Files\MI\XiaomiPCManager' -Directory | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1).Name
$dir = "C:\Program Files\MI\XiaomiPCManager\$ver\MiSmartShare"
$exe = Join-Path $dir 'MiPCAudio.exe'
$hold = Join-Path $dir 'MiPCAudio.exe.hiddenhold'

W "ver=$ver"
if (Test-Path $hold) { W "hold file already exists, abort"; return }
if (-not (Test-Path $exe)) { W "exe missing, abort"; return }

try {
    Rename-Item -LiteralPath $exe -NewName 'MiPCAudio.exe.hiddenhold' -ErrorAction Stop
    W "renamed to hiddenhold"
} catch {
    W ("rename failed: " + $_.Exception.Message)
    return
}

for ($i = 0; $i -lt 6; $i++) {
    $p = Get-Process MiPCAudio -ErrorAction SilentlyContinue
    if ($p) { Stop-Process -Id $p.Id -Force; W "killed pid=$($p.Id)" }
    Start-Sleep -Seconds 1
}
$still = Get-Process MiPCAudio -ErrorAction SilentlyContinue
if ($still) { W "STILL RUNNING pid=$($still.Id)" } else { W "no MiPCAudio process now" }
$t = Test-Path $exe
W "exe present again? $t"
