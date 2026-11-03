# 小米电脑管家修复脚本

针对 **小米电脑管家 6.0.0.39**（`C:\Program Files\MI\XiaomiPCManager\6.0.0.39`）在 Windows 上的两个实际故障，
都是靠日志定位根因后写的小脚本，**不修改任何厂商文件**（除了用 Windows 自带防火墙命令改防火墙规则）。

| 故障 | 表现 | 修法 | 需要管理员 |
|---|---|---|---|
| ① 防火墙规则缺失 | 每隔几分钟弹「互联功能需要添加防火墙规则才能正常工作」，点「修复」后消失又再弹 | `fix-miplayservice-fw.ps1` + `fix-miplayservice-fw2.ps1` | 是（UAC） |
| ② 手机看不到电脑 | 手机「投放到」/妙播列表里没有这台电脑；切网或休眠唤醒后必现 | `miplay-netwatch.ps1`（配合 `install-miplay-netwatch.ps1` 装成开机自启） | 否 |

> 脚本里的注释、日志都是中文；两个修复互相独立，可以只取其中一个。

---

## ① 「防火墙规则缺失」反复弹窗

### 现象
弹窗标题「防火墙规则缺失」，正文「互联功能需要添加防火墙规则才能正常工作」，按钮「取消 / 修复」。
点「修复」后 1 毫秒内返回成功，但**没有任何加规则的动作**，所以过一会儿又弹。

### 定位过程（诊断日志）
诊断日志 `C:\ProgramData\MI\AIoT\Log\smart_share_log.txt` 里每 1–8 分钟一条：

```
firewall_policy.cpp 127: [smart_share][firewall]rules abnormal,
  app path = C:\Program Files\MI\XiaomiPCManager\6.0.0.39\MiSmartShare\MiPlayCastService.exe,
  direction = 1, protocol = 17    direction = 2, protocol = 17
firewall_policy.cpp 286: start prompt timer
```

→ 被判定「异常」的只有 `MiPlayCastService.exe` 的 **UDP（protocol 17）入站 + 出站**。
该组件的自检逻辑（在 `MiSmartShare\MiSmartShareDLL.dll` 里）要求每个互联程序都有
**入站/出站 × TCP/UDP 四条 Allow 规则**；把它和注册表里另外 10 个 MI 程序的规则一比就看出差别：

```
HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\FirewallRules
```

| 程序 | 规则数 | Name 字段 | Description |
|---|---|---|---|
| 其余 10 个（MiScreenShare、MAFSvr、MiPCAudio、micont_service…） | 4 条 | 程序名 | 空 |
| **MiPlayCastService.exe** | **2 条（只有 In）** | **`MiplayCastService`**（大小写不对） | **非空**（`Allows … use all port.`） |

安装器只写了入站两条，缺出站两条 → 自检报「该协议两个方向都异常」。
而「修复」按钮走的 RPC（`smartshare.firewall.repair`）实际上什么都没做，于是死循环。

### 修复
```powershell
# 1) 把两条入站规则改名 + 清空描述，跟其它程序保持一致
pwsh -File .\fix-miplayservice-fw.ps1

# 2) 补出站 TCP/UDP 两条（用 netsh，New-NetFirewallRule 在部分环境会报参数集错误）
pwsh -File .\fix-miplayservice-fw2.ps1
```

两个脚本都会自己弹 UAC（`Start-Process -Verb RunAs`），并把执行前后的规则快照写到
`fix-result.log` / `fix-result2.log`（里面有原始两条规则字符串，用于回滚）。

修复后该程序 4 条规则齐全：入站/出站 × TCP/UDP，`Name=MiPlayCastService`，描述为空。

### 回滚
```powershell
pwsh -File .\restore-miplayservice-fw.ps1
```
删除两条出站规则，并把两条入站规则的名字/描述还原成厂商原样。

### 验证
修复后 `smart_share_log.txt` 不再出现 `rules abnormal`（实测：从每分钟一条变成完全消失）。

> ⚠️ 升级或重装同版本电脑管家后，安装器可能又会只写两条入站规则，提示会回来 —— 重跑一遍即可。

---

## ② 手机「投放到」列表里没有这台电脑

### 现象
电脑端「小米妙播 / 音频共享」服务（`MiPCAudio.exe`）明明在跑（任务管理器里在
「小米电脑管家互联业务进程」下），手机端却看不到这台电脑；插拔网线、Wi-Fi 连上/断开、
合盖休眠唤醒之后尤其容易发生。

### 根因
`MiPCAudio.exe` 启动时会调 `Milink::registerService` 向互联层（Lyra）注册音频投放服务，
但**网络拓扑变化后它不会重新注册**：注册信息仍指向已经消失的网卡/IP，
手机端自然就找不到这台电脑了。

判定方法：看妙播日志 `C:\ProgramData\MI\Miplay\AudioShare\mpa\miplay_MiPlay_<时间>.log`

```
# 正常：进程启动后不久应有这几行
MilinkServerImpl::OnProcessConnected
Milink::registerService success
register service success id : 00000003
register channel result:[0]

# 坏了：只有每 30 秒一条心跳，从来没有上面几行
ServerApp::Run ... mode:[SPEAKER] idm lived:[1]
```

手动验证：任务管理器里结束 `MiPCAudio.exe`，它会被父进程 `MiSmartShareHost.exe`
在 1–2 秒内重新拉起，日志里出现 `register service success id` 即代表手机端又能看到这台电脑。

### 修复：网络守护
把「重启 `MiPCAudio.exe`」自动化。守护每 15 秒比对一次网络签名（活动的 IPv4 列表），
出现以下情况就重启 `MiPCAudio.exe`，并校验新进程是否注册成功：

- 网络签名变化（插拔网线、Wi-Fi 连上/断开、IP 变更）
- 检测到休眠/唤醒（真实流逝时间远大于轮询间隔）
- 上次重启时的网络与当前不一致（重启那一刻链路还在抖动，注册可能落在已消失的网卡上）

```powershell
# 安装（不需要管理员）：写启动文件夹快捷方式 + 隐藏启动器，并立即启动一次
pwsh -File .\install-miplay-netwatch.ps1

# 卸载
pwsh -File .\install-miplay-netwatch.ps1 -Uninstall

# 手动立刻重启一次妙播服务
pwsh -File .\miplay-netwatch.ps1 -Oneshot

# 只看不动（预演，不改任何东西）
pwsh -File .\miplay-netwatch.ps1 -Oneshot -DryRun
```

特点：

- **不修改任何厂商文件**，电脑管家升级也不会失效
- 单实例互斥体（`Local\MiPlayNetWatch_<用户名>`），重复启动会自己退出
- 45 秒去抖，避免网络抖动时反复重启
- 有 fallback：父进程没把 `MiPCAudio.exe` 拉起来时只记日志，不动别的进程
- 日志写在脚本同目录 `miplay-netwatch.log`，超过 1 MB 自动轮转成 `.old`

### 实测记录（本机日志摘录）
```
[2026-11-03 10:25:16] watchdog 启动（登录时由启动项自动拉起）
[2026-11-03 10:25:18] 初始网络签名：以太网=192.168.5.171
[2026-11-03 11:38:47] 检测到休眠/唤醒（距上次轮询 2,168 秒）
[2026-11-03 11:38:47] 重启 MiPCAudio.exe pid=24412
[2026-11-03 11:38:48] 新 MiPCAudio.exe pid=11244
[2026-11-03 11:38:49] milink 注册校验：成功
```
```
[2026-11-03 00:41:14] 检测到网络变化：[以太网=192.168.5.171;WLAN=192.168.5.163] -> [WLAN=192.168.5.163]
[2026-11-03 00:41:14] 重启 MiPCAudio.exe pid=8704
[2026-11-03 00:41:15] 新 MiPCAudio.exe pid=26268
[2026-11-03 00:41:16] milink 注册校验：成功
```

修复后妙播可以走**有线**（不必像网上一些教程那样要求断开网线只用 Wi-Fi）：

```
TCP 192.168.5.171(以太网):8899 <- 192.168.5.170(手机):53612  Established
```

---

## 关于「改 MiPCAudio.exe 强制走有线」的补丁

网上流传一种做法（酷安等）：把 `MiPCAudio.exe` 里选择网卡时的
`IfType` 比较从 `0x47`（`IF_TYPE_IEEE80211`，Wi-Fi）改成 `0x06`
（`IF_TYPE_ETHERNET_CSMACD`，以太网）。

本仓库**没有**采用它，原因：

- 反汇编确认该判断在 6.0.0.39 里位于 `MiPCAudio.exe`
  VA `0x140091A70` / 文件偏移 `0x90E70`，字节 `41 83 79 64 47`
  （`cmp dword ptr [r9+0x64], 0x47`，`r9` 来自 `GetAdaptersAddresses` 的 `IP_ADAPTER_ADDRESSES`）
- 但实测 6.0.0.39 在有线网络下**本来就能正常投放**，上述故障的真因是「网络变化后不重新注册」，
  不是网卡类型筛选
- 打了这个补丁之后，只插网线不连 Wi-Fi 的场景能用，但**只剩 Wi-Fi 时反而会失效**
  （正好反过来的问题），而且会破坏文件签名、被升级覆盖

如果你确实需要它，`patchbytes-crop.png` 是对应位置的原始字节截图，可自行对照修改（风险自负）。

---

## 文件清单

| 文件 | 说明 |
|---|---|
| `fix-miplayservice-fw.ps1` | 改名 + 清空 `MiPlayCastService` 两条入站规则的 Name/Description |
| `fix-miplayservice-fw2.ps1` | 用 `netsh advfirewall` 补出站 TCP/UDP 两条规则 |
| `restore-miplayservice-fw.ps1` | 回滚防火墙改动 |
| `fix-result.log` / `fix-result2.log` | 两次执行的前后快照与原始规则字符串 |
| `miplay-netwatch.ps1` | 网络守护：网络变化 / 休眠唤醒 → 重启 `MiPCAudio.exe` 并校验注册 |
| `install-miplay-netwatch.ps1` | 安装/卸载启动项（`-Uninstall`） |
| `miplay-netwatch-launcher.vbs` | 隐藏窗口启动器（Unicode 保存，中文路径可用） |
| `patchbytes-crop.png` | 上述 exe 补丁位置的截图，仅供参考 |

---

## 注意

- 脚本按 **6.0.0.39** 的路径和行为编写（`C:\Program Files\MI\XiaomiPCManager\6.0.0.39\`），
  其它版本路径不同，需要改脚本里的常量；防火墙那部分只依赖进程名和路径，逻辑通用
- 防火墙脚本会修改系统防火墙规则，执行前请确认你接受这个改动，并可用 `restore-*.ps1` 回滚
- 全部脚本以 MIT 协议提供，按「现状」提供、无任何担保；出问题请先看日志再动手
