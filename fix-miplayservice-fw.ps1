$ErrorActionPreference = 'Continue'
$log = 'D:\Download\小米电脑管家提示修复\fix-result.log'
function L($m) { Add-Content -Path $log -Value ("{0} {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) -Encoding utf8 }

L "=== start ==="
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole('Administrators')
} catch { $isAdmin = $false }
L "elevated=$isAdmin"

$exe = 'C:\Program Files\MI\XiaomiPCManager\6.0.0.39\MiSmartShare\MiPlayCastService.exe'
L "exe exists: $(Test-Path -LiteralPath $exe)"

# --- 1) backup raw registry rule strings ---
try {
    $k = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules'
    (Get-ItemProperty $k).PSObject.Properties |
        Where-Object { $_.Name -match '^\{' -and $_.Value -match 'MiPlayCast' } |
        ForEach-Object { L ("BACKUP_REG $($_.Name) $($_.Value)") }
} catch { L ("backup reg failed: " + $_.Exception.Message) }

# --- 2) backup COM snapshot ---
try {
    Get-NetFirewallRule -DisplayName '*MiplayCast*' -ErrorAction SilentlyContinue | ForEach-Object {
        $af = $_ | Get-NetFirewallApplicationFilter
        $pf = $_ | Get-NetFirewallPortFilter
        L ("BEFORE name=$($_.Name) disp=$($_.DisplayName) dir=$($_.Direction) act=$($_.Action) en=$($_.Enabled) prof=$($_.Profile) proto=$($pf.Protocol) prog=$($af.Program) desc=$($_.Description)")
    }
} catch { L ("backup com failed: " + $_.Exception.Message) }

# --- 3) normalize existing rules: exact display name, clear description ---
try {
    Get-NetFirewallRule -DisplayName '*MiplayCast*' -ErrorAction SilentlyContinue | ForEach-Object {
        $id = $_.Name
        try {
            Set-NetFirewallRule -Name $id -NewDisplayName 'MiPlayCastService' -Enabled True -Action Allow -Profile Any -ErrorAction Stop
            L "renamed $id -> MiPlayCastService"
        } catch { L ("rename $id failed: " + $_.Exception.Message) }
        try {
            Set-NetFirewallRule -Name $id -Description '' -ErrorAction Stop
            L "cleared description $id"
        } catch { L ("clear desc $id failed: " + $_.Exception.Message) }
    }
} catch { L ("normalize failed: " + $_.Exception.Message) }

# --- 4) add missing outbound rules (keep parity with the other 10 MI apps) ---
foreach ($proto in @('TCP', 'UDP')) {
    try {
        $hit = Get-NetFirewallRule -DisplayName 'MiPlayCastService' -Direction Out -ErrorAction SilentlyContinue | Where-Object {
            $af = $_ | Get-NetFirewallApplicationFilter
            $pf = $_ | Get-NetFirewallPortFilter
            $af.Program -eq $exe -and $pf.Protocol -eq $proto
        }
        if ($hit) {
            L "out $proto already present"
        } else {
            New-NetFirewallRule -DisplayName 'MiPlayCastService' -Direction Out -Program $exe -Protocol $proto -Action Allow -Profile Any -Enabled True -ErrorAction Stop | Out-Null
            L "added out $proto"
        }
    } catch { L ("add out $proto failed: " + $_.Exception.Message) }
}

# --- 5) final report ---
try {
    Get-NetFirewallRule -DisplayName '*MiplayCast*' -ErrorAction SilentlyContinue | ForEach-Object {
        $af = $_ | Get-NetFirewallApplicationFilter
        $pf = $_ | Get-NetFirewallPortFilter
        L ("FINAL name=$($_.Name) disp=$($_.DisplayName) dir=$($_.Direction) act=$($_.Action) en=$($_.Enabled) prof=$($_.Profile) proto=$($pf.Protocol) prog=$($af.Program) desc=$($_.Description)")
    }
} catch { L ("final report failed: " + $_.Exception.Message) }

L "=== done ==="
