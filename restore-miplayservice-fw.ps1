# 回滚：撤销 2026-11-03 00:06 对 MiPlayCastService 防火墙规则的改动
# 需以管理员身份运行（右键 → 以管理员身份运行，或 pwsh 里：Start-Process pwsh -Verb RunAs -ArgumentList '-File','<本文件>'）
# 备份的原始规则字符串见同目录 fix-result.log（BACKUP_REG 两行）

$ErrorActionPreference = 'Continue'
$outIds = '{036F63BF-1AA3-4A3B-B668-B0315CD5CE41}', '{5D83D86C-C965-4454-9C8F-02EB4FCA2699}'   # 本次新增的两条 Out 规则
$inIds  = '{8CB2A613-F795-4040-B7D2-8B477D096EC5}', '{C1E56137-C2BB-465C-9BB1-A593858B3DEB}'   # 原有两条 In 规则（被改名+清空描述）

foreach ($id in $outIds) {
    Remove-NetFirewallRule -Name $id -ErrorAction SilentlyContinue
    "removed $id"
}

# 把原有两条入站规则的名字/描述还原成厂商原始样子
Set-NetFirewallRule -Name $inIds[0] -NewDisplayName 'MiplayCastService' -Description 'Allows MiplayCastService TCP use all port.' -ErrorAction SilentlyContinue
Set-NetFirewallRule -Name $inIds[1] -NewDisplayName 'MiplayCastService' -Description 'Allows MiplayCastService UDP use all port.' -ErrorAction SilentlyContinue

Get-NetFirewallRule -DisplayName '*MiplayCast*' -ErrorAction SilentlyContinue | ForEach-Object {
    $pf = $_ | Get-NetFirewallPortFilter
    "FINAL name=$($_.Name) disp=$($_.DisplayName) dir=$($_.Direction) proto=$($pf.Protocol) desc=$($_.Description)"
}
