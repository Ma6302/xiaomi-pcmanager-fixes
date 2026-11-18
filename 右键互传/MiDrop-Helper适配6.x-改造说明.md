# MiDrop Helper 适配小米电脑管家 6.x（右键「使用小米互传发送」）

MiDrop Helper 是第三方开源项目 [cnbluefire/MiDropShellExtForWindows11](https://github.com/cnbluefire/MiDropShellExtForWindows11)
做的 Win11 现代右键菜单扩展（Microsoft Store 装的是 1.0.7.0 稀疏包），给你一个
「使用小米互传发送」的右键入口。

装上以后在 **小米电脑管家 6.x** 上有两个毛病：菜单项图标是**空白纸张**（应该是蓝色互传图标），
点它**完全没有反应**（不弹窗、不报错、也不启动）。

本目录的做法是：**从源码改造，再把改好的两个文件放回包里**——
`MiDrop.Helper.exe`（真正发文件的进程）和 `ShellExt.dll`（现代右键菜单的 COM 扩展，图标和点击都由它提供）。

- 改造后的源码只有 1 个文件、+186 / −5 行（`git diff --no-index` 对上游 1.0.12 的
  `src/MiDrop.Core/XiaomiPcManagerHelper.cs` 实测）：`patch\XiaomiPcManagerHelper.cs`
  （`ShellExt.dll` 用上游 1.0.12 的代码，不需要改 —— 见第二节原因）
- 编译好的成品：
  - `MiDrop.Helper.patched-1.0.12.exe`（4,444,672 字节，单文件 NativeAOT）
  - `ShellExt.patched-1.0.12.dll`（2,288,640 字节，NativeAOT，导出 `DllGetClassObject`/`DllCanUnloadNow`）
- 验证工具：`verify-shellext\`（不用资源管理器，直接把 DLL 加载起来读 `GetIcon()`，见第二节）
- 部署/回滚脚本：`apply-midrop-helper.ps1`（`-Source` / `-ShellExtSource` / `-Restore`）
- 出厂原件备份：`backup\MiDrop.Helper.exe.orig-1.0.7.0`（SHA256 `300AFB0B…246B8AA`，4,386,304 字节）、
  `backup\ShellExt.dll.orig-1.0.7.0`（SHA256 `5646F5AB…82B5605`，2,280,960 字节）

---

## 一、点击链路与三条根因

```
资源管理器右键
  └─ explorer → dllhost（AppX COM 代理）
      └─ ShellExt.dll!ContextMenu.Invoke
          └─ DllMain.StartShare("XiaomiShare", files)
              ├─ 文件清单写缓存：<LocalAppData>\MiDropHelper\ShareFiles\<guid>
              └─ Process.Start(<包目录>\MiDrop.Helper\MiDrop.Helper.exe,
                               "--target XiaomiShare --share-files <guid>")
                  └─ MiDrop.Helper.exe（就是本目录改造的那个）
                      ├─ 读缓存文件 → 拼路径
                      └─ 交给小米电脑管家
```

原版 helper 的最后一步在 6.x 上失效，原因是**三个**问题叠加：

1. **6.x 不再处理 WM_COPYDATA（消息 74）。** 原版是用
   `FindWindowW("XiaomiPCManager")` + `SendMessageTimeoutW(hwnd, 74, …)` 把文件列表丢给产品。
   6.x 收到后无人订阅，产品日志只留下：
   `WARN WebViewService - PostJsCallbackResponses: no subscriber method=smartshare.midrop.event.showFromMenuWindow`
2. **窗口类名被产品自己占了。** `XiaomiPCManager` 这个窗口类现在属于产品的
   `MiSmartShareHost.exe`，原版 helper 一找到它就认定「产品已启动」并直接返回，
   于是既不启动产品、也不发送 —— 表现就是**静默无反应**。
3. **找不到可执行文件。** 原版 `GetExecuteFile()` 在注册表 CLSID 指向的目录
   （6.x 是 `…\<版本>\MiSmartShare`）里找 `hyperConnect.exe` / `XiaomiPcManager.exe` / `MiPcContinuity.exe`，
   6.x 三个都不在那个目录里（`XiaomiPcManager.exe` 在上一级 `…\<版本>\`）。

---

## 二、`ShellExt.dll` 里的另外两个 6.x 不兼容点（图标 + 点击参数）

只换 `MiDrop.Helper.exe` 是不够的 —— 包里的 1.0.7 版 `ShellExt.dll` 自己也带着两处毛病。
不用靠猜：`verify-shellext\` 直接把 DLL `LoadLibrary` + `DllGetClassObject(976D43D8-…)` +
`IExplorerCommand::GetIcon()` 拿出来读（和资源管理器调用的是同一套入口）：

| | 出厂 1.0.7 | 改造后（上游 1.0.12） |
|---|---|---|
| `GetTitle()` | 使用小米互传发送 | 使用小米互传发送 |
| `GetIcon()` | `…\6.0.2.19\MiSmartShare\XiaomiPcManager.exe,-32512` → **文件不存在** | `…\6.0.2.19\MiSmartShare\Assets\midrop_logo.ico` → **存在（126,353 字节）** |
| 点下去启动 helper 的参数 | `--share-files <key>`（**不传 `--target`**） | `--target XiaomiShare --share-files <key>` |

```bat
:: 实测输出（改造版）
Title   = 使用小米互传发送
Icon    = C:\Program Files\MI\XiaomiPCManager\6.0.2.19\MiSmartShare\Assets\midrop_logo.ico
IconExistsOnDisk = True
:: 实测输出（出厂 1.0.7，同一段代码）
Icon    = C:\Program Files\MI\XiaomiPCManager\6.0.2.19\MiSmartShare\XiaomiPcManager.exe,-32512
IconExistsOnDisk = False
```

1. **白图标**：1.0.7 的 `ContextMenu` 构造函数里图标是硬编码的
   `Path.Combine(<注册表 CLSID 指向的目录>, "XiaomiPcManager.exe,-32512")`。
   6.x 把主程序挪到了上一层（`…\<版本>\XiaomiPcManager.exe`），这个路径不存在，
   资源管理器取不到图标 → 空白纸张占位图。
   1.0.12 改成 `XiaomiPcManagerHelper.GetIconString()`：优先取
   `<installPath>\Assets\midrop_logo.ico` —— 6.x 的 `MiSmartShare\Assets\midrop_logo.ico`
   正好就是官方 `MiDropShellExt.dll` 用的那一个（官方那条「显示更多选项」里的菜单项显示蓝色图标，
   走的就是同一个文件），所以两边图标一致。
2. **点了没反应**：1.0.7 的 `ContextMenu.Invoke` → `DllMain.SendToXiaomiPcManager(files)`，
   启动 helper 时**只传 `--share-files`**；而 1.0.12 的 `Program.cs` 只认
   `--target XiaomiShare` 这个分支，参数里没有 `--target` 时直接跳过（既不 Launch 也不 Send）
   —— 所以哪怕 helper 已经换成改造版，点击依然静默。
   1.0.12 的 `DllMain.StartShare(target, files)` 会用
   `--target XiaomiShare --share-files <key>` 启动 helper，这才接上。

**为什么可以只换一个 DLL、不动 manifest**：已装包的 `AppxManifest.xml` 里
`com:SurrogateServer` 声明的就是 Clsid `976D43D8-907F-46AF-B47F-07084C71A2F0`，
和 1.0.12 注册的那个是同一个；1.0.12 多出来的荣耀/华为两个 Clsid
（`3EE2A0FD-…` / `3FA37C0D-…`）只在 `HonorPCManagerHelper/HuaweiPCManagerHelper.GetInstallPath()`
目录存在时才注册，本机没有华为/荣耀管家，`catch{}` 后自动跳过，不会因为 manifest 没声明而加载失败。

---

## 三、6.x 的官方协议（逆向得到）

反编译 `C:\Program Files\MI\XiaomiPCManager\<版本>\XiaomiPCManager.dll`
（`ilspycmd -p`，626 个 .cs），关键在 `XiaomiPCManager2.Startup\LaunchOptions.cs`
和 `XiaomiPCManager2\App.xaml.cs`：

```csharp
ContextMenuDropFileArgument = "--contextmenu_dropfile";
ContextMenuPayloadValuePrefix = "payload:";   // base64(UTF-8(载荷))
ContextMenuMappingValuePrefix = "mapping:";   // 共享内存名
LegacyContextMenuMappingName  = "Local\\MiDropFileMappingObject";
ContextMenuMappingNamePrefix  = "Local\\MiDropFileMappingObject_";
```

- `--contextmenu_dropfile=<值>` 的取值：
  - `payload:<base64>` → 解 base64 得到明文载荷（推荐）
  - `mapping:<共享内存名>` → 从 named shared memory 读 UTF-16LE 串（必须以 `\0` 结尾）
  - 其它任意值 → **原样当明文载荷用**（也就是说直接传路径串也认）
  - `1` 或空 → 视为「无载荷」，只弹一个空的互传窗口
- 载荷格式（`App.xaml.cs::ParseMiDropSelectedFiles`，按 `|` 切分，
  以 `parent_dir:` 开头的段会被丢掉，其余段**原样当完整路径**）：

```
parent_dir:<第一个文件所在目录>|<绝对路径1>|<绝对路径2>|…
```

- 等价于官方自己拼的参数（`CreateContextMenuDropFilePayloadArgument`）：

```
XiaomiPcManager.exe --contextmenu_dropfile=payload:<base64(UTF-8("parent_dir:C:\dir|C:\dir\a.txt"))>
```

- 成功时产品日志（`C:\ProgramData\MI\PCManager\logs\XiaomiPCManager2\<日期>.log`）会依次出现：

```
Process second instance command line: count=1, exe=...\--contextmenu_dropfile=payload:...
Second instance context menu request, showing MiDrop window
Context menu selection parsed: count=1, first=...\notepad.exe, source=second-instance
MiDropViewModel - SetSelectedFiles: count=1, first=...\notepad.exe, ...
MiDropWindow - MiDrop window opened
```

（如果产品当时没在跑，则是冷启动分支 `Cold start context menu request, showing MiDrop window`。）

---

## 四、改造内容（`patch\XiaomiPcManagerHelper.cs`）

只有 `src/MiDrop.Core/XiaomiPcManagerHelper.cs` 一个文件，`Program.cs` / `FilesHelper.cs` 没动：

| # | 改动 | 作用 |
|---|---|---|
| 1 | `GetExecuteFile()` 在原三个候选之后，**最多上溯 4 层父目录**找 `XiaomiPcManager.exe` | 解决根因 ③，从 `…\<版本>\MiSmartShare` 找到 `…\<版本>\XiaomiPcManager.exe` |
| 2 | `SendFilesAsyncCore()` 改为 async，**优先走 `--contextmenu_dropfile=payload:`** | 解决根因 ①②，不再依赖 WM_COPYDATA 和窗口查找 |
| 2a | 命令行过长（`exe 路径 + 参数 > 30000`）时改走 **named shared memory** + `--contextmenu_dropfile=mapping:<名>` | 对应官方的长路径回退分支，名字形如 `Local\MiDropFileMappingObject_<guidN>`，写 UTF-16LE + `\0`，并保活等待对端读取 |
| 2b | 上面两条都失败才回落到原来的 **WM_COPYDATA(74)** 实现（原代码逐行保留） | 5.x 兼容，不回归 |
| 3 | `LaunchAsyncCore()` 加 15 秒 deadline | 产品没起来时不再无限等 |
| 4 | 新增 `Log()`：`<LocalAppData>\MiDropHelper\MiDropHelper.patch.log`（>256 KB 自动重建） | 排障用，方便确认走的是哪条分支 |

参数用 `ProcessStartInfo.ArgumentList` 传（不是拼字符串），空格/中文/括号路径都不会被拆坏。

---

## 五、构建

需要 .NET SDK（本机 10.0.111 即可）+ VS 2022 BuildTools（NativeAOT 要用它的链接器）。
上游取 `main`（version.txt = 1.0.12）：

```powershell
git clone https://github.com/cnbluefire/MiDropShellExtForWindows11
# 用本目录 patch\XiaomiPcManagerHelper.cs 覆盖 src\MiDrop.Core\XiaomiPcManagerHelper.cs

# ① 发文件的进程
dotnet restore src\MiDrop.Helper\MiDrop.Helper.csproj -r win-x64
dotnet publish src\MiDrop.Helper\MiDrop.Helper.csproj -c Release -r win-x64 -o out

# ② 右键菜单 COM 扩展（图标 + 点击入口）
dotnet restore src\ShellExt\ShellExt.csproj -r win-x64
dotnet publish src\ShellExt\ShellExt.csproj -c Release -r win-x64 -o out-shell
```

两次各约 30 秒，得到 `out\MiDrop.Helper.exe`（4,444,672 字节，未改版是 4,386,304）和
`out-shell\ShellExt.dll`（2,288,640 字节，未改版是 2,280,960）。本目录的
`MiDrop.Helper.patched-1.0.12.exe` / `ShellExt.patched-1.0.12.dll` 就是这两份产物：

- helper：SHA256 `6E0D54587871F8FDF482AC6C4D0A2C741297BCBE8BFF1FFF0E770C89795D9B90`
- ShellExt：SHA256 `061E496D2007359E8BEFC485E5C1D538083717E53E2D10730424501CCBE483E2`

> **不需要**重签整个 MSIX 包 —— 上游的签名证书 `.pfx` 不在仓库里，整包是重签不了的；
> 运行时 Windows 也不再校验 `AppxSignature.p7x` / `AppxBlockMap.xml`（已实测替换后的
> exe 能执行、DLL 能被 dllhost 加载）。

---

## 六、部署

包里 `ShellExt.dll` 用 `PackageInstallLocation` 拼 helper 路径，**没有可配置项**，
所以改造版必须放回包目录（这也是唯一需要动厂商/商店文件的地方），两个文件：

```
C:\Program Files\WindowsApps\5f71dad9-3e77-4ada-9fad-12c2e761288f_1.0.7.0_x64__h7hff4v7bt4z0\
    ├─ MiDrop.Helper\MiDrop.Helper.exe
    └─ ShellExt\ShellExt.dll
```

```powershell
# 安装（会弹 UAC）：两个文件一起换
pwsh -File .\apply-midrop-helper.ps1 -Source .\MiDrop.Helper.patched-1.0.12.exe `
    -ShellExtSource .\ShellExt.patched-1.0.12.dll

# 只换其中一个也可以（只给 -Source 或只给 -ShellExtSource）

# 还原出厂的 1.0.7.0 原件（有备份的都还原）
pwsh -File .\apply-midrop-helper.ps1 -Restore
```

装完**重启资源管理器**（或注销一次），让 dllhost 丢掉旧的 `ShellExt.dll` 并重建图标缓存：

```powershell
Stop-Process -Name explorer -Force; Start-Sleep 3; Start-Process explorer.exe
& "$env:SystemRoot\System32\ie4uinit.exe" -show
```

脚本做的事：找包 → 逐个文件备份原件到 `backup\` → `takeown /a` + 给管理员写权限 →
字节流覆盖 → SHA256 校验 → 撤掉临时授权 → 所有者改回 `NT SERVICE\TrustedInstaller`。
日志：`apply-midrop-helper.log`。

两个必须知道的坑：

1. **包里的文件带 EFS 加密属性**（`Archive, Encrypted`）。`Copy-Item` 往非 NTFS-EFS 目标复制
   会报「无法加密指定的文件」；必须用 `[IO.File]::ReadAllBytes/WriteAllBytes` 走字节流。
2. **改回所有者需要 `SeRestorePrivilege`**。`icacls /setowner` 在这里会静默失败（所有者停在
   `BUILTIN\Administrators`），得先 `AdjustTokenPrivileges` 打开特权再用 `Set-Acl` ——
   脚本里的 `apply-midrop-helper.ps1` 用的就是这个办法，跑完所有者是 `NT SERVICE\TrustedInstaller`。

> ⚠️ **商店/侧载更新 MiDrop Helper 会覆盖这两个文件**（包版本号一变，包目录也换新的），
> 更新后右键菜单又会变回「白图标 + 点了没反应」——重跑一次安装脚本即可
> （包里路径随版本号变化，脚本按 `Get-AppxPackage` 自动定位，不用改）。
> 若哪天上游仓库自己适配了 6.x，直接用上游版本、删掉本目录即可。

---

## 七、已验证的事实

1. **协议层端到端**（未打包直接跑新 helper，缓存 key 里放 `README.md`）：
   - helper 侧：`started XiaomiPcManager.exe pid=20936` / `send via payload, files=66, argLen=175`
   - 产品日志：`Second instance context menu request, showing MiDrop window` →
     `Context menu selection parsed: count=1, first=…\README.md, source=second-instance` →
     `MiDropWindow - MiDrop window opened`，窗口里带着那个文件。
2. **放进包里之后仍然有效**（用 `Invoke-CommandInDesktopPackage` 以包身份 `AppId=App` 起
   已部署的 helper，载荷 `C:\Windows\System32\notepad.exe`）：
   产品日志出现 `Context menu selection parsed: count=1, first=...\notepad.exe` +
   `MiDrop window opened`；`MiDropViewModel - SetSelectedFiles: count=1`。两次都成功。
3. **`ShellExt.dll` 图标/标题/状态**（`verify-shellext\`，见第二节的对照表）：
   改造版 `GetIcon()` 返回存在的 `midrop_logo.ico`，出厂版返回不存在的
   `XiaomiPcManager.exe,-32512`。
   （`GetState()` 在普通进程里返回 `0x2 ECS_HIDDEN`，因为拿不到
   `IContextMenuTypeAccessor`；在资源管理器里现代菜单下是 `ECS_ENABLED`。）
4. **真实点击（最终验收，2026-11-04 用户实测）**：两个文件都换掉并重启资源管理器后，
   右键文件的「使用小米互传发送」显示**蓝色互传图标**，点击能正常弹出互传窗口并带上选中的文件。
5. 写入后包内两个文件的 SHA256 都与源码产物一致，ACL 与所有者已复原（`TrustedInstaller`）。

排障路径（万一以后又坏）：`%LOCALAPPDATA%\MiDropHelper\MiDropHelper.patch.log`
有记录说明 helper 起来了（问题在产品侧）；没记录说明 `ShellExt.dll` 没把 helper 拉起来。
产品侧日志：`C:\ProgramData\MI\PCManager\logs\XiaomiPCManager2\<日期>.log`。

---

## 八、其它说明

- 不修改产品文件（`C:\Program Files\MI\XiaomiPCManager` 一个字节都没动）。
- 包里只替换了 `MiDrop.Helper\MiDrop.Helper.exe` 和 `ShellExt\ShellExt.dll` 两个文件；
  `AppxManifest.xml` / `AppxSignature.p7x` / `AppxBlockMap.xml` 未变（Windows 只在安装/更新时
  校验它们，运行时不会重新校验 —— 已实测替换后的 exe 能执行、DLL 能被 dllhost 加载并弹菜单）。
- 稀疏包本体（注册表 `HKLM\SOFTWARE\Classes\CLSID\{504d69c0-…}\InprocServer32` 指向的
  官方 `MiDropShellExt.dll`、以及「显示更多选项」里那条官方菜单）保持原样，不受影响。
- 改造后的二进制不再带上游的开发者签名 —— 本机为开发者模式侧载，Windows 不校验。
