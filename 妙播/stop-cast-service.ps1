# Stop MiPlayCastService (experiment) - ASCII only on purpose
$ErrorActionPreference = 'Stop'
$log = Join-Path $PSScriptRoot 'stop-cast-service.log'
try {
    $before = (Get-Service MiPlayCastService).Status
    Stop-Service -Name MiPlayCastService -Force -ErrorAction Stop
    Start-Sleep -Seconds 2
    $after = (Get-Service MiPlayCastService).Status
    "BEFORE=$before AFTER=$after" | Out-File -FilePath $log -Encoding UTF8
} catch {
    "ERR: " + $_.Exception.Message | Out-File -FilePath $log -Encoding UTF8
}
