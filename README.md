# 小米电脑管家修复脚本

针对 **小米电脑管家 6.0.0.39 / 6.0.2.19**（`C:\Program Files\MI\XiaomiPCManager\<版本>`）在 Windows 上的三个实际故障，
都是靠日志定位根因后写的小脚本，**不修改任何厂商文件**（除了用 Windows 自带防火墙命令改防火墙规则）。

| 故障 | 表现 | 修法 | 需要管理员 |
|---|---|---|---|
| ① 防火墙规则缺失 | 每隔几分钟弹「互联功能需要添加防火墙规则才能正常工作」，点「修复」后消失又再弹 | `fix-miplayservice-fw.ps1` + `fix-miplayservice-fw2.ps1` | 是（UAC） |
| ② 手机看不到电脑 / 列表里出现两条同名设备 | 手机「投放到」/妙播列表里没有这台电脑；切网或休眠唤醒后必现；纯有线环境还会出现两条同名电脑，一条能用、一条空转 | `miplay-netwatch.ps1`（网络变化后重启妙播）+ `set-iftype-mode.ps1`（三处 `IfType` 身份统一，守护会自动调用） | 装守护要（计划任务，最高权限） |
| ③ 右键「使用小米互传发送」白图标 / 点了没反应 | 装了 MiDrop Helper 后，菜单项是空白纸张图标，点它毫无反应（6.x 上） | 改造 `MiDrop.Helper.exe` + `ShellExt.dll` 并替换进 MSIX 包，见 [`右键互传\`](右键互传/MiDrop-Helper适配6.x-改造说明.md) | 是（UAC） |

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

### 根因之二：两套发布机制 + 三处 `IfType`（2026-11 补全）

上面那条是「完全不显示」。**纯有线**（Wi-Fi 断开）环境下还有第二种表现：手机列表里出现
**两条同名电脑**，一条点进去正常播放、另一条转圈几十秒后自动跳回前一条。

原因是电脑同时用**两套机制**把自己发布成音频目标，两套身份都取自「某张网卡的 MAC」：

| 机制 | 承载进程 | 身份来源 |
|---|---|---|
| Lyra / netbus（`type8`） | `MiPCAudio.exe` | `MiSmartShare\MiPCAudio.exe` 里挑网卡的分支 |
| IDM（`type2`） | `idmruntime.dll`（随进程加载） | `MiSmartShare\idmruntime.dll` 里两处挑网卡的分支 |

挑选网卡的判断是 `IfType == 0x47`（`IF_TYPE_IEEE80211`，Wi-Fi），**一共三处**：

```
MiPCAudio.exe   41 83 79 64 ?? 75       ; cmp dword [r9+0x64], 0x47 ; 75 = jne
idmruntime.dll  41 83 7e 64 ?? 0F 85    ; cmp dword [rsi+0x64], 0x47 ; 0F 85 = jne
idmruntime.dll  83 7b 64 ?? 75          ; cmp dword [rbx+0x64], 0x47
```

（`??` = `0x47` 无线 / `0x06` 以太网；原厂三处都是 `0x47`。站点位置由脚本按
「前缀 + 字节 + 后缀」自动定位，**不写死偏移**，所以升级换版本也能用。）

三处必须**一致**：只要有一处分歧，两套机制算出的身份就不同，手机就会把它当成两台设备。
网上流传的酷安补丁只改第一处 → 必然出现「两条同名设备」。
反面也成立：把三处都改成 `0x06` 后，**Wi-Fi 断开时**身份稳定、两条合并为一条；
但若某天只有 Wi-Fi 没有网线，三处都会找不到「以太网类型」的网卡，又会回到广播失败。

`config.ini` 这条路走不通：exe 里支持的键只有 `mirror.smooth.disable` /
`mirror.smooth.level` / `mirror.delay.test` / `mirror.mpt.disable` / `mirror.mpt.dbg` /
`delayTest`，**没有** `deviceID` / 网卡覆盖项（妙播自己的 `InitParam.deviceID` 一直是空的，
所以手机只能拿 MAC 当 key —— 这也是换身份就会多一条记录的根因）。

### 修复：网络守护（自动切身份）

守护每 15 秒比对一次网络签名（活动的 IPv4 列表 + 活跃介质），出现以下任一情况就：
**按当前活跃介质把三处 `IfType` 字节统一 → 重启 `MiPCAudio.exe` → 校验 milink 注册**。

- 网络签名变化（插拔网线、Wi-Fi 连上/断开、IP 变更）
- 检测到休眠/唤醒（真实流逝时间远大于轮询间隔）
- 上次重启时的网络与当前不一致（注册可能落在已消失的网卡上）
- **活跃介质（有线 / 无线）与文件里三处 `IfType` 不一致**

```powershell
# 安装（会弹 UAC，注册计划任务 MiPlayNetWatch，最高权限、登录时启动、窗口隐藏）
pwsh -File .\妙播\install-miplay-netwatch.ps1

# 卸载（删计划任务；文件里的 IfType 字节不会自动改回，见下一行）
pwsh -File .\妙播\install-miplay-netwatch.ps1 -Uninstall
pwsh -File .\妙播\set-iftype-mode.ps1 -Mode wifi     # 还原原厂无线身份

# 手动立刻重启一次妙播服务（先按当前介质同步身份）
pwsh -File .\妙播\miplay-netwatch.ps1 -Oneshot

# 只看不动（预演，不改任何东西）
pwsh -File .\妙播\miplay-netwatch.ps1 -Oneshot -DryRun

# 只查/只切身份，不碰守护
pwsh -File .\妙播\set-iftype-mode.ps1 -Mode status
pwsh -File .\妙播\set-iftype-mode.ps1 -Mode lan -DryRun
```

特点：

- 单实例互斥体（`Local\MiPlayNetWatch_<用户名>`），`-Oneshot` 也会让路给常驻实例
- 45 秒去抖，避免网络抖动时反复重启
- 改字节用「改名 → 复制」法（运行中的 exe 独占写会失败），失败会自动回滚
- 重启后会检查新进程的启动时间是否晚于改字节时间，早于就再杀一次
  （否则父进程可能在改字节之前就把新实例拉起来，加载的仍是旧字节）
- 日志写在脚本同目录 `miplay-netwatch.log`，超过 1 MB 自动轮转成 `.old`
- 未提权运行时自动降级为「只重启、不改字节」（日志里会写明）

> ⚠️ 这一项**会修改厂商文件**（`MiSmartShare\MiPCAudio.exe` 1 字节 +
> `MiSmartShare\idmruntime.dll` 2 字节），文件签名因此失效，电脑管家升级/修复后会被覆盖，
> 需要重跑一次；`set-iftype-mode.ps1 -Mode wifi` 可随时还原成原厂字节。

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

身份联动切换的实测记录（2026-11-04，纯有线环境）：

```
[15:30:09] 当前活跃介质：lan
[15:30:12] 发现身份与活跃介质不一致，按 lan 模式纠正并重启妙播
[15:30:24] 已改写 idmruntime.dll：2 处 -> lan 模式（rename）
[15:30:25] 已改写 MiPCAudio.exe：1 处 -> lan 模式（rename）
[15:30:27] 复核 三处 value=0x06 (lan)  完成：三处已统一为 lan 模式
[15:30:29] milink 注册校验：成功
```

改前妙播日志里每次启动都有 `DiscoveryLyraImpl: [startAdvertising:387]get mac address failed`
且没有 `advertising result listener`；三处统一并重启后变成：

```
I DiscoveryLyraImpl: [IAdvertisingResultListenerImpl::OnResult:497]advertising result listener code:0
I DiscoveryLyraImpl::registerChannel:451 register channel result:[0]
register service success id : 00000000
```

修复后妙播可以走**有线**（不必像网上一些教程那样要求断开网线只用 Wi-Fi）：

```
TCP 192.168.5.171(以太网):8899 <- 192.168.5.170(手机):53612  Established
```

---

## ③ 右键「使用小米互传发送」白图标 / 点了没反应（MiDrop Helper）

第三方开源工具 **MiDrop Helper**（商店版 1.0.7.0）给资源管理器加了「使用小米互传发送」的
Win11 现代右键菜单。在 6.x 上它有两个毛病，而且**分属两个不同的文件**：

1. **图标是空白纸张**：出厂 `ShellExt.dll` 把图标硬编码成「注册表 CLSID 目录 +
   `XiaomiPcManager.exe,-32512`」，6.x 把主程序挪到了上一层，这个路径根本不存在。
2. **点了什么都没发生**：出厂 `ShellExt.dll` 启动 helper 时只传 `--share-files`、**不传 `--target`**，
   新版 helper 只认 `--target XiaomiShare`，于是既不启动产品也不发送；
   哪怕 helper 换成改造版也一样 —— 这是「只换 exe 仍然没反应」的原因。

另外 helper 自身还有三条 6.x 不兼容（不处理 `WM_COPYDATA(74)`、窗口类名被产品占用、
找不到可执行文件），对应改成 6.x 官方的
`--contextmenu_dropfile=payload:<base64("parent_dir:<dir>|<文件…>")>` 协议。

本仓库的做法：从上游源码改造 `XiaomiPcManagerHelper.cs`（+187/−6 行）+ 用上游 1.0.12 的
`ShellExt.dll`，编译两个 NativeAOT 成品，再用脚本替换进 MSIX 包（包里的 `ShellExt.dll` 用
`PackageInstallLocation` 拼 helper 路径，绕不开）。

```powershell
# 安装（弹 UAC；两个文件都换；先备份原件到 右键互传\backup\）
pwsh -File .\右键互传\apply-midrop-helper.ps1 `
    -Source .\右键互传\MiDrop.Helper.patched-1.0.12.exe `
    -ShellExtSource .\右键互传\ShellExt.patched-1.0.12.dll

# 装完重启资源管理器让 dllhost/图标缓存刷新
Stop-Process -Name explorer -Force; Start-Sleep 3; Start-Process explorer.exe

# 还原出厂原件
pwsh -File .\右键互传\apply-midrop-helper.ps1 -Restore
```

完整链路、逆向出来的协议、`ShellExt.dll` 的两处不兼容及其验证工具（`右键互传\verify-shellext\`，
不用右键、直接把 DLL 加载起来读 `GetIcon()`）、构建步骤、EFS/所有者两个坑和验证日志都在
[`右键互传\MiDrop-Helper适配6.x-改造说明.md`](右键互传/MiDrop-Helper适配6.x-改造说明.md)。

> ⚠️ 这一项**确实修改了商店包里的文件**（替换 `MiDrop.Helper\MiDrop.Helper.exe` 和
> `ShellExt\ShellExt.dll` 两个文件），与上面两项「不动厂商文件」的原则不同；
> 商店更新 MiDrop Helper 后会覆盖，需要重跑一次。
> 产品本体（`C:\Program Files\MI\XiaomiPCManager`）依然一个字节都没动。

---

## 关于「改 MiPCAudio.exe 强制走有线」的补丁

网上流传一种做法（酷安等）：把 `MiPCAudio.exe` 里选择网卡时的 `IfType` 比较从 `0x47`
（`IF_TYPE_IEEE80211`，Wi-Fi）改成 `0x06`（`IF_TYPE_ETHERNET_CSMACD`，以太网）。

**只改这一处是错的**，它会让手机里多出一条同名设备（见上面「根因之二」）：

- 该判断在 6.0.2.19 的 `MiPCAudio.exe` 里位于文件偏移 `0x90E70`
  （VA `0x140091A70`，字节 `41 83 79 64 47`，`cmp dword ptr [r9+0x64], 0x47`，
  `r9` 来自 `GetAdaptersAddresses` 的 `IP_ADAPTER_ADDRESSES`）
- 但同一份身份判断在 `idmruntime.dll` 里还有**两处**，只改 `MiPCAudio.exe` 就会让
  Lyra 与 IDM 两套发布机制算出不同的身份 → 手机显示两条
- 实测：单改一处时手机确实能看到电脑并能播放，但列表里恒为两条；把三处统一后才回到一条

本仓库把它做成了可逆的三处联动切换（见 `妙播\set-iftype-mode.ps1`，由守护自动调用）：
`-Mode lan` 三处写 `0x06`、`-Mode wifi` 三处写 `0x47`（原厂状态）、`-Mode status` 只读。
`妙播\patchbytes-crop.png` 是对应位置的原始字节截图，供手动核对。

---

## 文件清单

| 文件 | 说明 |
|---|---|
| `fix-miplayservice-fw.ps1` | 改名 + 清空 `MiPlayCastService` 两条入站规则的 Name/Description（路径写死 6.0.0.39） |
| `fix-miplayservice-fw2.ps1` | 用 `netsh advfirewall` 补出站 TCP/UDP 两条规则（路径写死 6.0.0.39） |
| `fix-miplayservice-fw-auto.ps1` | **版本无关版**：自动探测 `C:\Program Files\MI\XiaomiPCManager` 下最高版本目录，规范化 + 补齐四条规则，幂等 |
| `restore-miplayservice-fw.ps1` | 回滚防火墙改动 |
| `fix-result.log` / `fix-result2.log` | 两次执行的前后快照与原始规则字符串 |
| `妙播\miplay-netwatch.ps1` | 网络守护：网络变化 / 休眠唤醒 / 介质与身份不一致 → 重启 `MiPCAudio.exe` 并校验注册 |
| `妙播\install-miplay-netwatch.ps1` | 安装/卸载计划任务 `MiPlayNetWatch`（`-Uninstall`），需 UAC；安装时会自动清掉旧版留下的启动项快捷方式与 `miplay-netwatch-launcher.vbs` |
| `妙播\set-iftype-mode.ps1` | 三处 `IfType` 联动切换：`-Mode lan` / `wifi` / `status`，支持 `-DryRun` / `-Clean` |
| `妙播\apply-mac-patch.ps1` / `apply-mac-patch2.ps1` | 早期「只改一处」补丁脚本（**已废弃**，仅保留过程证据） |
| `妙播\restore-mac-patch.ps1` / `restore-mac-patch2.ps1` | 早期回滚脚本（`-patch2` 用改名替换法，可参考） |
| `妙播\hide-mipcaudio.ps1` / `unhide-mipcaudio.ps1` | 诊断用：把 `MiPCAudio.exe` 改名藏起来 / 改回，用来确认「手机上的条目到底由谁产生」 |
| `妙播\stop-cast-service.ps1` / `start-cast-service.ps1` | 诊断用：临时停/起 `MiPlayCastService`（SYSTEM 服务，需 UAC） |
| `妙播\check-net-state.ps1` | 一眼看网络：网卡 / IPv4 / Wi-Fi 状态 / 8899 连接 |
| `妙播\dup-watch.ps1` | 诊断用：记录手机上与本机的 TCP 连接变化 + 妙播新会话 |
| `妙播\patchbytes-crop.png` | exe 补丁位置的原始字节截图，供手动核对 |
| `右键互传\MiDrop-Helper适配6.x-改造说明.md` | ③ 的完整说明：链路、逆向协议、ShellExt 两处不兼容、构建、部署、验证 |
| `右键互传\patch\XiaomiPcManagerHelper.cs` | 改造后的源码（唯一改动的源文件，+187/−6 行） |
| `右键互传\MiDrop.Helper.patched-1.0.12.exe` | 编译好的单文件 AOT 成品（4,444,672 字节） |
| `右键互传\ShellExt.patched-1.0.12.dll` | 编译好的右键菜单扩展 AOT DLL（2,288,640 字节，图标 + 传 `--target`） |
| `右键互传\verify-shellext\` | 验证工具：加载 `ShellExt.dll` 直接读 `GetIcon()`，不用真的右键 |
| `右键互传\apply-midrop-helper.ps1` | 装/卸（`-Restore`）进 MSIX 包的脚本，需管理员；支持 `-Source` / `-ShellExtSource` |
| `右键互传\backup\*.orig-1.0.7.0` | 出厂 1.0.7.0 两个原件备份（安装时自动生成，不入库） |
| `右键互传\小米互传Win11现代右键菜单点击无反应-修复方案.md` | 早期排查记录（含三条根因与日志证据） |
| `NOTICE.md` | 第三方组件与许可证声明（MiDrop Helper 的上游版权、涉及哪些文件、哪些东西不在本仓库） |

---

## 第三方组件与许可证

本仓库**原创**的脚本与文档是 MIT（[`LICENSE`](LICENSE)，Copyright (c) 2026 Ma6302）；
但 ③ 右键互传用到的
[**MiDrop Helper**](https://github.com/cnbluefire/MiDropShellExtForWindows11)
是 **cnbluefire** 的 MIT 项目（我们基于 1.0.12 改造并重新编译），其版权声明、许可证全文、
以及本仓库里到底哪些文件属于它的衍生件，统一登记在 [`NOTICE.md`](NOTICE.md)。

- 本仓库**不包含**任何小米官方二进制（`MiPCAudio.exe`、`idmruntime.dll`、出厂版 `MiDrop.Helper.exe` /
  `ShellExt.dll`）；脚本只在你本机对已安装的文件打补丁，原件由脚本运行时备份
- [Higanoneko/MiPCManager_Patch](https://github.com/Higanoneko/MiPCManager_Patch) 是 **GPL-3.0**，
  本仓库不含其代码，只在对比不同做法时引用链接

---

## 注意

- 防火墙那四个脚本里，`fix-miplayservice-fw.ps1` / `fix-miplayservice-fw2.ps1` 的路径写死
  **6.0.0.39**；换版本请用 `fix-miplayservice-fw-auto.ps1`（自动探测最新版本目录）。
  `妙播\` 下的脚本都不写死版本，运行时自动定位 `C:\Program Files\MI\XiaomiPCManager\<最高版本>`
- **6.0.2.19 已由官方修掉防火墙那个 bug**（安装器自己写全了 4 条规则），升级到这个版本后
  不需要再跑防火墙修复脚本；但妙播那两条问题在 6.0.2.19 上依然存在
- 防火墙脚本会修改系统防火墙规则，执行前请确认你接受这个改动，并可用 `restore-*.ps1` 回滚
- 妙播守护会改 `MiPCAudio.exe`（1 字节）+ `idmruntime.dll`（2 字节）以统一发现身份，
  可用 `set-iftype-mode.ps1 -Mode wifi` 还原；守护未提权运行时会自动跳过改字节
- 本仓库原创脚本以 MIT 协议提供（第三方组件的版权与许可见 `NOTICE.md`），
  按「现状」提供、无任何担保；出问题请先看日志再动手
- 本文的结论来自本机 6.0.0.39 / 6.0.2.19 的实测日志与反汇编，网上同类方案
  （酷安单字节补丁、[Higanoneko/MiPCManager_Patch](https://github.com/Higanoneko/MiPCManager_Patch)）
  的差异与取舍已在各节里写明
- ⏳ **时效说明（2026-11 复核）**：`Higanoneko/MiPCManager_Patch` 已发布 **2.0.9（2026-11-06）**，
  提交说明为「Adapt MiPCManager 6.0 / Remove Experimental Feature」，CLI 现为
  `status` / `apply` / `revert`，并另有 `audio apply --mode lan|wifi` 切换音频流转模式。
  本文写作时对照的是它的旧版本，因此「只改一处 `IfType` → 手机上出现两条同名设备」
  这条结论**只对旧版本成立**；新版是否也改成三处联动、或换了别的实现，尚未复核。
  若你打算用它的方案，请以它仓库的最新说明为准。它 README 里给出的重复设备绕法是：
  在手机端把该电脑「移除 / 忘记」后重新配对
