$ErrorActionPreference = 'Stop'
$log = Join-Path $PSScriptRoot 'start-cast-service.log'
try {
    Start-Service -Name MiPlayCastService -ErrorAction Stop
    Start-Sleep -Seconds 2
    "STATUS=" + (Get-Service MiPlayCastService).Status | Out-File -FilePath $log -Encoding UTF8
} catch {
    "ERR: " + $_.Exception.Message | Out-File -FilePath $log -Encoding UTF8
}
