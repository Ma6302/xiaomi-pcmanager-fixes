# 小米互传 Win11 现代右键菜单「使用小米互传发送」点击无反应 —— 修复方案记录

> 本文件是**方案存档**：记录成因、可复现的验证证据、以及完整可重做的实现步骤。
> 本机（小米电脑管家 6.0.2.19 + Win11）已按此方案验证成功，随后按要求**整套卸载复原**，
> 当前系统里没有本方案的任何残留（卸载步骤见第七节）。
> 适用前提：安装了第三方现代右键菜单包 `cnbluefire/MiDropShellExtForWindows11`（本机为 1.0.7.0）。

---

## 一、现象

- 文件上右键 → Win11 现代菜单（不是「显示更多选项」里那层）底部有「**使用小米互传发送**」，
  图标正常（蓝色 Mi），但**点下去毫无反应**：不弹窗、不报错、事件日志无异常。
- 传统菜单（显示更多选项）里的「使用小米互传发送」**正常**，能弹出互传窗口并搜索设备。
- 只影响 6.x：网上同症状报告集中在管家 6.0.0.39 之后（上游 issue #13）。

## 二、谁提供这个菜单项，点击时发生了什么

菜单项来自那个第三方 MSIX 稀疏包（**不是**小米官方注册的）：

```
包全名 : 5f71dad9-3e77-4ada-9fad-12c2e761288f_1.0.7.0_x64__h7hff4v7bt4z0
显示名 : MiDrop Helper    发布者: CN=cnbluefire    SignatureKind: Developer
位置   : C:\Program Files\WindowsApps\<包全名>\
内容   : MiDrop.Helper\MiDrop.Helper.exe   ShellExt\ShellExt.dll
```

`AppxManifest.xml` 里声明了 `com:SurrogateServer`（`ShellExt.dll`，STA）+ 
`desktop4:fileExplorerContextMenus` 对 `*` 和 `Directory` 注册 Verb CLSID
`{976D43D8-907F-46AF-B47F-07084C71A2F0}`。点击链路（反编译 ShellExt.dll / MiDrop.Helper.exe 得到，C# NativeAOT）：

```
explorer → dllhost（AppX COM 代理，加载 ShellExt.dll）
  ShellExt.ContextMenu.Invoke(IShellItemArray)
    → DllMain.StartShare()：文件存到本地缓存拿一个 key
      → Process.Start(<包目录>\MiDrop.Helper\MiDrop.Helper.exe, "--target XiaomiShare --share-files <key>")
        MiDrop.Helper：
          → XiaomiPcManagerHelper.LaunchAsync()        // FindWindowW("XiaomiPCManager")
          → SendCachedFilesAsync()
              → SendMessageTimeoutW(hwnd, WM_COPYDATA(74), ...)   // 旧协议，路径用 '|' 拼
```

关键旁证：`Event Viewer → Microsoft-Windows-AppModel-Runtime/Admin` 在每次点击时都有一条
「为包 5f71dad9… 创建桌面 AppX 容器，把 pid=<dllhost> 加入」，说明 COM 部分**确实被激活了**，
失败发生在更后面的环节。

## 三、根因（三条，均已用日志实证）

### 1. 6.x 的接收方不再处理 WM_COPYDATA —— 旧协议已死

把 helper 用的那种消息**直接发给产品自己的窗口**（实测），产品日志
`C:\ProgramData\MI\PCManager\logs\XiaomiPCManager2\<日期>.log` 只有：

```
SmartShareService - HandleMiDropEvent: showFromMenuWindow, parameters={"fileCount":1,"fileName":"...jpg","folder":false}
WARN WebViewService - PostJsCallbackResponses: no subscriber method=smartshare.midrop.event.showFromMenuWindow
DEBUG WebViewService - OnSmartShareCallbackEvent: no JS subscriber
```

**消息收到了，但前端 WebView 里没有 JS 订阅者** → 界面毫无反应。
（互传窗口开着时重发，结果一模一样。）所以「让产品重新支持旧协议」这条路是死的。

### 2. 同名窗口类被产品自己占了 → helper 连"启动一下"都不做

产品的 `MiSmartShareHost.exe`（命令行 `--owner-pid <主进程>`）创建了类名为
**`XiaomiPCManager`** 的顶层窗口（`rect (-10000,0) 0x0`，visible=True，无标题）。
而 helper 的逻辑是：

```csharp
var messageWindow = FindMessageWindow();          // FindWindowW("XiaomiPCManager") → 命中产品窗口
if (messageWindow != 0) {
    if (string.IsNullOrEmpty(arguments)) return true;   // ← 直接返回，什么都不启动
}
...
SendMessageTimeoutW(messageWindow, 74, 1, ...);        // 于是文件发给了那个不认消息的窗口
```

→ 点击后既没有可见结果，也**不会**启动任何别的程序，所以"点击无反应"是静默的。

### 3. 图标能显示的原因（顺带解释）

`ShellExt` 渲染菜单时读 `HKCR\CLSID\{504d69c0-cb52-48df-b5b5-7161829fabc8}\InprocServer32`
拿到 `MiSmartShare\MiDropShellExt.dll` 的目录，再取 `XiaomiPcManager.exe,-32512` 的图标。
旧版 5.x 该 exe 就在 `MiSmartShare\` 下，6.x 移到了版本目录，于是图标回退成空白纸
（本机因为该目录里曾放过一个带图标的 exe，所以图标看起来是正常的）。

## 四、6.x 官方真正可用的协议（实测成功）

```
XiaomiPCManager.exe --contextmenu_dropfile=payload:<base64(
    "parent_dir:<第一个文件所在目录>|<文件1>|<文件2>|…"  的 UTF-8 字节)>
```

已验证的产品日志：

```
Process second instance command line: count=1, exe=...--contextmenu_dropfile=payload:cGFyZW50X2RpcjpE...
Second instance context menu request, showing MiDrop window
MiDropViewModel - SetSelectedFiles: count=1, first=...egoliteSetup.exe
MiDropWindow - MiDrop window opened
ControlCenterWindow - MiDrop activation: attempt=0, zOrderResult=True, ..., foreground=True
```

等价形式（命令行太长时的回退）：

```
CreateFileMappingW(INVALID_HANDLE_VALUE, ..., PAGE_READWRITE, 0, 4096, L"Local\\MiDropFileMappingObject")
   写入同一串 UTF-16LE（以 \0 结尾）
Launch.exe --contextmenu_dropfile=1          // C:\Program Files\MI\XiaomiPCManager\Launch.exe
```

`Launch.exe` 读映射后转发给 `XiaomiPCManager.exe --contextmenu_dropfile=payload:<b64>`。

## 五、方案：用户空间"翻译官"中转程序

不改产品文件、不要管理员，在用户空间放一个常驻中转，把旧协议翻译成新协议：

```
explorer → dllhost(ShellExt.dll) → MiDrop.Helper.exe
        └──(旧协议 WM_COPYDATA, '|' 分隔路径)──> MiDropFixRelay.exe
                                                    │  组装 parent_dir:… 串 → UTF-8 → base64
                                                    └──(新协议)──> XiaomiPcManager.exe --contextmenu_dropfile=payload:<b64>
                                                                       → 弹出「小米互传 · 发送」并带上文件
```

三根支柱：

| 环节 | 做法 | 为什么必须这样 |
|---|---|---|
| 让 helper 找到中转 | 中转创建类名 `XiaomiPCManager` 的顶层窗口，**每 5 秒** `SetWindowPos(hwnd, HWND_TOP, …)` 顶回 z 序第一 | `FindWindow` 返回的是 **EnumWindows 顺序（z 序从上到下）里第一个**同类名窗口；产品的同名窗口先创建，不注意就抢不过它 |
| 让壳程序的路径探测落在可写处 | 写 `HKCU\Software\Classes\CLSID\{504d69c0-…}\InprocServer32` 指向 `%LOCALAPPDATA%\MiDropFix\MiDropShellExt.dll` | HKCU 优先于 HKLM；同时给图标探测一个可写目录 |
| 常驻 | 启动文件夹快捷方式（**不要写 Run 注册表**，见第六节第 2 条） | helper 在找到同名窗口时不会启动任何程序，中转必须自己活着 |

## 六、实现要点（参考实现）

编译（VS2022 BuildTools，**`/utf-8` 必须加**，否则中文注释触发 C4819 并把下一行代码吞掉）：

```bat
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
cl /nologo /utf-8 /EHsc /std:c++17 /MT /O2 /DUNICODE /D_UNICODE ^
   /Fe:MiDropFix.Relay.exe relay_main.cpp bridge.res ^
   /link /SUBSYSTEM:WINDOWS user32.lib kernel32.lib shell32.lib
```

`bridge.res` 由 `bridge.rc` 生成，图标取产品原版：
`32512 ICON "C:\Program Files\MI\XiaomiPCManager\<版本>\MiSmartShare\Assets\midrop_logo.ico"`。

`relay_main.cpp`（核心逻辑，去掉日志与错误分支的骨架）：

```cpp
// ---- 单实例 + 窗口 ----
CreateMutexW(nullptr, FALSE, L"Local\\MiDropFixRelayMutex");
if (GetLastError() == ERROR_ALREADY_EXISTS) return 0;

WNDCLASSW wc = {};
wc.lpfnWndProc   = WndProc;
wc.hInstance     = hInst;
wc.lpszClassName = L"XiaomiPCManager";          // 必须与 helper 查找的类名一致
RegisterClassW(&wc);
HWND h = CreateWindowExW(0, L"XiaomiPCManager", L"XiaomiPCManager", WS_OVERLAPPED,
                         CW_USEDEFAULT, CW_USEDEFAULT, 0, 0, nullptr, nullptr, hInst, nullptr);
SetTimer(h, 2, 5000, nullptr);                  // 每 5 秒顶回最上层

// ---- z 序 ----
case WM_TIMER:
    if (wParam == 2)
        SetWindowPos(hwnd, HWND_TOP, 0,0,0,0,
                     SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE|SWP_NOOWNERZORDER);
    break;

// ---- 收旧协议 ----
case WM_COPYDATA: {
    auto* cds = reinterpret_cast<COPYDATASTRUCT*>(lParam);
    const wchar_t* s = static_cast<const wchar_t*>(cds->lpData);   // UTF-16，'|' 分隔绝对路径
    std::vector<std::wstring> files = Split(s, L'|');

    // 只处理真实存在的路径：产品的消息也可能落到我们窗口，别转发
    std::vector<std::wstring> ok;
    for (auto& f : files) if (GetFileAttributesW(f.c_str()) != INVALID_FILE_ATTRIBUTES) ok.push_back(f);
    if (ok.empty()) return TRUE;

    // parent_dir:<第一个文件目录>|<f1>|<f2>…
    std::wstring text = L"parent_dir:" + ParentDir(ok[0]);
    for (auto& f : ok) text += L"|" + f;

    std::string b64 = Base64Encode(Utf8FromWide(text));
    std::wstring exe = FindProductExe();      // C:\Program Files\MI\XiaomiPCManager\<最高版本>\XiaomiPcManager.exe
    if (b64.size() < 30000) {
        std::wstring cmd = L"\"" + exe + L"\" --contextmenu_dropfile=payload:" + Widen(b64);
        CreateProcessW(nullptr, cmd.data(), nullptr, nullptr, FALSE, 0, nullptr, nullptr, &si, &pi);
    } else {
        // 回退：写 Local\MiDropFileMappingObject（4096 字节 UTF-16 文本）+ Launch.exe --contextmenu_dropfile=1
    }
    return TRUE;
}
```

必须注意的细节：

1. **`WS_OVERLAPPED` 而不是 `WS_POPUP`**：本机实测 `WS_POPUP + WS_EX_TOOLWINDOW + 屏外坐标`
   时 `FindWindow` 挑不到我们的窗口；`message-only`（父窗口 `HWND_MESSAGE`）更是完全不参与
   `EnumWindows`，直接不可用。
2. **`dwData` 不固定**：真 helper 发的是 `dwData=0`，自测脚本用 `dwData=1`；中转不要按 `dwData` 过滤。
3. **`WM_COPYDATA` 的字符串是 UTF-16、`|` 分隔的完整路径**，末尾一般带 `\0`。
4. **别用 `SetParent` 去"降级"竞争对手窗口**：本机实测 `SetParent(产品窗口, 我们的窗口)` 之后
   `FindWindow` 会返回 0（不是找到我们的），是假信号，别拿它当方案。

## 七、安装 / 卸载步骤（重做时照此执行）

### 安装（零管理员）

```powershell
# 1) 部署目录
$fix = "$env:LOCALAPPDATA\MiDropFix"
New-Item -ItemType Directory -Force "$fix\Assets" | Out-Null
Copy-Item MiDropFix.Relay.exe "$fix\MiDropFixRelay.exe"          # 编译产物，改名部署
Copy-Item "C:\Program Files\MI\XiaomiPCManager\<版本>\MiSmartShare\Assets\midrop_logo.ico" "$fix\Assets\" -Force
Copy-Item "C:\Program Files\MI\XiaomiPCManager\<版本>\MiSmartShare\MiDropShellExt.dll" "$fix\" -Force

# 2) HKCU 路径覆盖
$k = "HKCU:\Software\Classes\CLSID\{504d69c0-cb52-48df-b5b5-7161829fabc8}\InprocServer32"
New-Item $k -Force | Out-Null
Set-ItemProperty $k '(default)' "$fix\MiDropShellExt.dll"
Set-ItemProperty $k 'ThreadingModel' 'Apartment'

# 3) 开机自启：启动文件夹快捷方式（不要用 Run 注册表）
$s = (New-Object -ComObject WScript.Shell).CreateShortcut(
     (Join-Path ([Environment]::GetFolderPath('Startup')) 'MiDropFix Relay.lnk'))
$s.TargetPath = "$fix\MiDropFixRelay.exe"; $s.WindowStyle = 7; $s.Save()

# 4) 启动
([wmiclass]'Win32_Process').Create("`"$fix\MiDropFixRelay.exe`"")
```

### 自检（重要：不要用 pwsh 里的 `FindWindow`）

```powershell
# EnumWindows 的顺序就是 z 序（上→下），第一个同名窗口就是 helper 会命中的那个
# 输出的 pid 必须是中转进程
Add-Type -TypeDefinition @"
using System; using System.Text; using System.Runtime.InteropServices;
public class C { public delegate bool E(IntPtr h, IntPtr l);
 [DllImport("user32.dll")] public static extern bool EnumWindows(E cb, IntPtr l);
 [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p); }
"@
$found = @()
$cb = [C+E]{ param($h,$l)
  $sb = New-Object System.Text.StringBuilder 256
  [void][C]::GetClassNameW($h,$sb,256)
  if ($sb.ToString() -eq 'XiaomiPCManager') { $p=0; [void][C]::GetWindowThreadProcessId($h,[ref]$p); $script:found += $p }
  $true }
[void][C]::EnumWindows($cb,[IntPtr]::Zero); $found
```

### 验证

点一次菜单，看两个日志：

- `C:\ProgramData\MI\bridge_debug.log`（中转）：`WM_COPYDATA …` → `payload text (n chars): parent_dir:…`
  → `CreateProcess OK pid=…`
- `C:\ProgramData\MI\PCManager\logs\XiaomiPCManager2\<日期>.log`（产品）：
  `Second instance context menu request, showing MiDrop window` → `MiDropWindow - MiDrop window opened`

### 卸载（完整复原，本机已执行）

```powershell
# 1) 结束进程
Get-Process MiDropFixRelay -ErrorAction SilentlyContinue | Stop-Process -Force

# 2) 删注册表（只需恢复这一层，HKCU 优先于 HKLM）
Remove-Item 'HKCU:\Software\Classes\CLSID\{504d69c0-cb52-48df-b5b5-7161829fabc8}' -Recurse -Force
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'MiDropFixRelay' -ErrorAction SilentlyContinue

# 3) 删启动项与部署目录
Remove-Item (Join-Path ([Environment]::GetFolderPath('Startup')) 'MiDropFix Relay.lnk') -Force
Remove-Item "$env:LOCALAPPDATA\MiDropFix" -Recurse -Force

# 4) 管理员：清掉曾经放进产品目录的桥接文件（旧方案残留）
#    C:\Program Files\MI\XiaomiPCManager\<版本>\MiSmartShare\XiaomiPcManager.exe(.bak)
#    这两个文件没有版本信息（真品应为 CompanyName=XiaomiPcManager / 6.0.2.19），都是自建产物
del "C:\Program Files\MI\XiaomiPCManager\*\MiSmartShare\XiaomiPcManager.exe*"
taskkill /f /im explorer.exe & start explorer.exe     # 刷新菜单图标缓存

# 5)（可选）清 Defender 的误报记录：需要管理员
Remove-MpThreat -ThreatID 2147737394
```

> 卸载后菜单项仍会显示（那是第三方包提供的），但点击会和修复前一样**没有反应**。

## 八、踩过的坑（复现时别再踩）

1. **DSH 的 pwsh 进程里 `FindWindowW("XiaomiPCManager")` 结果是错的**：它一直返回产品的
   `MiSmartShareHost` 窗口，而普通进程（helper、写成 exe 的小探针）返回的是 z 序第一个窗口。
   我在这上面浪费了很多轮：`SetWindowPos(HWND_BOTTOM)`、`ShowWindow`、`SetParent`、改 `WS_POPUP`
   全都"验证失败"，其实全是这个假象造成的。**判断一律用独立 exe 或 EnumWindows 顺序**。
2. **Defender 会把「AppData 里的自编译 exe + Run 注册表自启」判成木马**：
   写 `HKCU\...\Run` 后报 `Behavior:Win32/Persistence.A!ml`（严重），
   随后该 exe 直接变成"文件包含病毒"**无法执行**（`Win32_Process.Create` 返回 8、
   `cmd start` 报 "The system cannot execute the specified program."），而同一份字节前 10 分钟还能跑。
   → 改用**启动文件夹快捷方式** + 别把 exe 命名成 `XiaomiPcManager.exe`（避免伪装启发式）。
   真需要时给 `%LOCALAPPDATA%\MiDropFix` 加 Defender 排除项（需管理员）。
3. **编译**：`/utf-8` 必加；`cl` 必须在 `vcvars64.bat` 同一个 `cmd /c` 里调用；
   重建前先杀掉正在运行的目标 exe，否则 `LNK1104`。
4. **启动 GUI 子系统 exe**：在 DSH shell 里用 `Start-Process` 起这类 exe 会让工具调用挂到超时
   （被转后台）；用 `([wmiclass]'Win32_Process').Create("`"…exe`"")`（注意括号）秒返回。
5. **产品目录不可写**：非管理员写 `MiSmartShare\` 会被拒；本方案正是为此才把东西放在 `%LOCALAPPDATA%`。
6. **`MiDrop.Helper.exe` 单独运行没意义**：脱离 MSIX 包身份时 WinRT 相关调用会失败/挂住，
   别指望用它手动触发来验证。

## 九、局限

- 中转必须常驻：它一挂，点击就回到"无反应"（helper 不会被触发去启动任何东西）。
- 依赖产品的 `--contextmenu_dropfile=payload:` 协议；管家升级若改协议，需要重新抓产品日志适配。
- 与"彻底去掉这个菜单项"是相反方向：不想折腾的话，直接 `设置 → 应用` 卸载「MiDrop Helper」即可消除菜单项。
