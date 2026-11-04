# MiDrop Helper 适配小米电脑管家 6.x（右键「使用小米互传发送」）

MiDrop Helper 是第三方开源项目 [cnbluefire/MiDropShellExtForWindows11](https://github.com/cnbluefire/MiDropShellExtForWindows11)
做的 Win11 现代右键菜单扩展（Microsoft Store 装的是 1.0.7.0 稀疏包），给你一个
「使用小米互传发送」的右键入口。

装上以后在 **小米电脑管家 6.x** 上点这个菜单**完全没有反应**（不弹窗、不报错、也不启动）。
本目录的做法是：**从源码改造 `MiDrop.Helper.exe`，再把改好的 exe 放回包里**。

- 改造后的源码只有 1 个文件、+187 / −6 行：`patch\XiaomiPcManagerHelper.cs`
- 编译好的成品：`MiDrop.Helper.patched-1.0.12.exe`（4,444,672 字节，单文件 NativeAOT）
- 部署/回滚脚本：`apply-midrop-helper.ps1`
- 出厂原件备份：`backup\MiDrop.Helper.exe.orig-1.0.7.0`（SHA256 `300AFB0B…246B8AA`，4,386,304 字节）

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

## 二、6.x 的官方协议（逆向得到）

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

## 三、改造内容（`patch\XiaomiPcManagerHelper.cs`）

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

## 四、构建

需要 .NET SDK（本机 10.0.111 即可）+ VS 2022 BuildTools（NativeAOT 要用它的链接器）。

```powershell
git clone https://github.com/cnbluefire/MiDropShellExtForWindows11
# 用本目录 patch\XiaomiPcManagerHelper.cs 覆盖 src\MiDrop.Core\XiaomiPcManagerHelper.cs
dotnet restore src\MiDrop.Helper\MiDrop.Helper.csproj -r win-x64
dotnet publish src\MiDrop.Helper\MiDrop.Helper.csproj -c Release -r win-x64 -o out
```

约 28 秒，得到单文件 `out\MiDrop.Helper.exe`（4,444,672 字节，未改版是 4,386,304）。
本目录的 `MiDrop.Helper.patched-1.0.12.exe` 就是这份产物
（SHA256 `6E0D54587871F8FDF482AC6C4D0A2C741297BCBE8BFF1FFF0E770C89795D9B90`）。

> 只编 `MiDrop.Helper`（含 `MiDrop.Core`），**不需要** `ShellExt`，也不需要重签整个 MSIX 包
> —— 上游的签名证书 `.pfx` 不在仓库里，整包是重签不了的。

---

## 五、部署

包里 `ShellExt.dll` 用 `PackageInstallLocation` 拼 helper 路径，**没有可配置项**，
所以改造版必须放回包目录（这也是唯一需要动厂商/商店文件的地方）：

```
C:\Program Files\WindowsApps\5f71dad9-3e77-4ada-9fad-12c2e761288f_1.0.7.0_x64__h7hff4v7bt4z0\MiDrop.Helper\MiDrop.Helper.exe
```

```powershell
# 安装（会弹 UAC）
pwsh -File .\apply-midrop-helper.ps1 -Source .\MiDrop.Helper.patched-1.0.12.exe

# 还原出厂的 1.0.7.0 原件
pwsh -File .\apply-midrop-helper.ps1 -Restore
```

脚本做的事：找包 → 备份原件到 `backup\` → `takeown /a` + 给管理员写权限 →
字节流覆盖 → SHA256 校验 → 撤掉临时授权 → 所有者改回 `NT SERVICE\TrustedInstaller`。
日志：`apply-midrop-helper.log`。

两个必须知道的坑：

1. **包里的文件带 EFS 加密属性**（`Archive, Encrypted`）。`Copy-Item` 往非 NTFS-EFS 目标复制
   会报「无法加密指定的文件」；必须用 `[IO.File]::ReadAllBytes/WriteAllBytes` 走字节流。
2. **改回所有者需要 `SeRestorePrivilege`**。`icacls /setowner` 在这里会静默失败（所有者停在
   `BUILTIN\Administrators`），得先 `AdjustTokenPrivileges` 打开特权再用 `Set-Acl` ——
   脚本里的 `apply-midrop-helper.ps1` 用的就是这个办法，跑完所有者是 `NT SERVICE\TrustedInstaller`。

> ⚠️ **商店更新 MiDrop Helper 会覆盖这个 exe**，更新后右键菜单又会变回「没反应」——重跑一次安装即可。
> 若哪天上游仓库自己适配了 6.x，直接用上游版本、删掉本目录即可。

---

## 六、已验证的事实

1. **协议层端到端**（未打包直接跑新 helper，缓存 key 里放 `README.md`）：
   - helper 侧：`started XiaomiPcManager.exe pid=20936` / `send via payload, files=66, argLen=175`
   - 产品日志：`Second instance context menu request, showing MiDrop window` →
     `Context menu selection parsed: count=1, first=…\README.md, source=second-instance` →
     `MiDropWindow - MiDrop window opened`，窗口里带着那个文件。
2. **放进包里之后仍然有效**（用 `Invoke-CommandInDesktopPackage` 以包身份 `AppId=App` 起
   已部署的 helper，载荷 `C:\Windows\System32\notepad.exe`）：
   产品日志出现 `Context menu selection parsed: count=1, first=...\notepad.exe` +
   `MiDrop window opened`；`MiDropViewModel - SetSelectedFiles: count=1`。两次都成功。
3. 写入后包内 exe 的 SHA256 与源码产物一致，ACL 与所有者已复原（`TrustedInstaller`）。

**还没验证的一步**：在资源管理器里真的右键文件点「使用小米互传发送」（需要人点一次鼠标）。
如果那一步没反应，先看 `%LOCALAPPDATA%\MiDropHelper\MiDropHelper.patch.log`：
有记录说明 helper 起来了（问题在产品侧），没记录说明 ShellExt 没把 helper 拉起来。

---

## 七、其它说明

- 不修改产品文件（`C:\Program Files\MI\XiaomiPCManager` 一个字节都没动）。
- 包里只替换了 `MiDrop.Helper\MiDrop.Helper.exe` 一个文件；`AppxSignature.p7x` /
  `AppxBlockMap.xml` 未变（Windows 只在安装/更新时校验它们，运行时不会重新校验，
  替换后 exe 能正常执行、能通过包身份运行，已实测）。
- 稀疏包本体（注册表 CLSID、右键菜单注册、`ShellExt.dll`）保持 1.0.7.0 原样。
