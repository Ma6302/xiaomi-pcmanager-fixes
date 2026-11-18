# 第三方组件与许可证声明

本仓库中由 Ma6302 原创的脚本与文档以 **MIT** 协议发布，版权声明见 [`LICENSE`](LICENSE)。
下列第三方作品以「原样」或「改造后」的形式随本仓库一起分发，其版权归原作者所有，
并继续适用各自的许可证。分发、修改或再发布本仓库时，请一并保留本文件。

---

## cnbluefire/MiDropShellExtForWindows11

- 上游地址：<https://github.com/cnbluefire/MiDropShellExtForWindows11>
- 本仓库基于的版本：**1.0.12**（commit `efa8195`，2026-08-13）
- 许可证：**MIT**，Copyright (c) 2024 cnbluefire

本仓库中涉及的文件：

| 文件 | 与上游的关系 |
|---|---|
| `右键互传/patch/XiaomiPcManagerHelper.cs` | 基于上游 `src/MiDrop.Core/XiaomiPcManagerHelper.cs` 改造（增加 6.x 支持、保留 5.x 兜底），**非原样**，仍按 MIT 分发 |
| `右键互传/MiDrop.Helper.patched-1.0.12.exe` | 用上面这份改造后的源码 NativeAOT 编译的产物 |
| `右键互传/ShellExt.patched-1.0.12.dll` | 上游 `src/ShellExt` **原样**编译的产物，本仓库未改动其源码 |

上游 MIT 许可证全文：

```
MIT License

Copyright (c) 2024 cnbluefire

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 小米官方文件：不随本仓库分发

`MiPCAudio.exe`、`idmruntime.dll`、`MiDrop.Helper.exe`、`ShellExt.dll`（出厂版）等均属小米
（Xiaomi）的安装包内容，**本仓库不包含、也不再分发**这些原厂二进制。仓库里的脚本只在你
本机对**已安装**的文件打补丁，原件由脚本在运行时备份（`妙播/*.orig*`、`右键互传/backup/`）。
如需获得这些文件，请从官方安装包/商店包中取回。

---

## 其他社区方案：仅引用链接

- `Higanoneko/MiPCManager_Patch` — <https://github.com/Higanoneko/MiPCManager_Patch>
  该项目为 **GPL-3.0**。本仓库**不包含**它的任何代码，正文只在对比「`IfType` 单处补丁」做法时
  引用其公开链接；若要使用或再分发其代码，请遵守 GPL-3.0。
- 网上流传的「酷安单字节补丁」为匿名帖文描述的做法，本仓库未拷贝其任何代码。
