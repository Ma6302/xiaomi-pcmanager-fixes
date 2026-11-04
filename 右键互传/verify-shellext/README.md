# verify-shellext —— 不用资源管理器验证右键菜单扩展

把 `ShellExt.dll` 直接 `LoadLibrary` 起来，走和资源管理器同一套入口
（`DllGetClassObject` → `IClassFactory::CreateInstance(IExplorerCommand)`），
读回 `GetTitle()` / `GetIcon()` / `GetState()` / `GetFlags()`。
用来确认图标路径是否指向真实存在的文件、菜单标题是否正确 —— 不必真的右键一次。

## 用法

```powershell
cd 右键互传\verify-shellext

# 改造版
dotnet run -c Release -- ..\ShellExt.patched-1.0.12.dll

# 出厂 1.0.7（对照）
dotnet run -c Release -- ..\backup\ShellExt.dll.orig-1.0.7.0
```

## 典型输出

```
Title   = 使用小米互传发送
Icon    = C:\Program Files\MI\XiaomiPCManager\6.0.2.19\MiSmartShare\Assets\midrop_logo.ico
IconExistsOnDisk = True
State   = 0x2 (hr=0x00000000)  [0=ECS_ENABLED,1=DISABLED,2=HIDDEN]
Flags   = 0x0
```

## 说明

- **不要直接传 `C:\Program Files\WindowsApps\…\ShellExt\ShellExt.dll`**：Windows 拒绝把
  WindowsApps 里的 DLL 加载进「无包身份」的进程（`E_ACCESSDENIED`），所以要么用仓库里的副本，
  要么先拷贝出来。这也是为什么 `dllhost` 能以包代理身份加载它、而普通进程不行。
- `State` 在普通进程里恒为 `0x2 (ECS_HIDDEN)`：`GetState` 依赖资源管理器注入的
  `IContextMenuTypeAccessor`（判断是不是现代菜单），拿不到就返回 hidden。
  在资源管理器里现代菜单下是 `ECS_ENABLED`，所以这一项**不能**用本工具判断菜单是否可用。
- `ToolTip` 打印出 `NotImplementedException` 是正常的：上游 `ExplorerCommand` 基类没实现它，
  资源管理器也不会调用（会回退用 Title）。
- 需要 .NET SDK 10+（本机 10.0.111 已装）。
