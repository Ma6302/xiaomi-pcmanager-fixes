using Microsoft.Win32;
using System.Diagnostics;
using System.IO;
using System.IO.MemoryMappedFiles;
using System.Runtime.InteropServices;
using System.Text;

namespace MiDrop.Core;

public class XiaomiPcManagerHelper
{
    private static readonly IReadOnlyList<string> PcManagerRegKeys = [
        // 5.x
        "{504d69c0-cb52-48df-b5b5-7161829fabc8}",

        // 4.x
        "{1bca9901-05c3-4d01-8ad4-78da2eac9b3f}",
        ];

    // 6.x 的官方右键互传入口（XiaomiPCManager2.Startup.LaunchOptions 里的定义）
    private const string ContextMenuDropFileArgument = "--contextmenu_dropfile";
    private const string ContextMenuPayloadPrefix = "payload:";
    private const string ContextMenuMappingPrefix = "mapping:";
    private const string ContextMenuMappingNamePrefix = "Local\\MiDropFileMappingObject_";

    // CreateProcess 命令行上限 32767，留出余量
    private const int MaxCommandLineLength = 30000;

    private const string ProductExecutableName = "XiaomiPcManager.exe";

    public static string GetInstallPath()
    {
        try
        {
            for (int i = 0; i < PcManagerRegKeys.Count; i++)
            {
                using (var subKey = Registry.ClassesRoot.OpenSubKey($"CLSID\\{PcManagerRegKeys[i]}\\InprocServer32"))
                {
                    if (subKey != null && subKey.GetValue(null) is string path && !string.IsNullOrEmpty(path))
                    {
                        var folder = Path.GetDirectoryName(path);
                        if (folder?.Contains("\\native-interconnect\\") is true)
                        {
                            while (!string.IsNullOrEmpty(folder))
                            {
                                if (File.Exists(Path.Combine(folder, "hyperConnect.exe"))) break;
                                folder = Path.GetDirectoryName(folder);
                            }
                        }
                        if (Directory.Exists(folder))
                        {
                            return folder;
                        }
                    }
                }
            }
        }
        catch { }

        return string.Empty;
    }

    public static string GetExecuteFile()
    {
        var installPath = GetInstallPath();
        if (!string.IsNullOrEmpty(installPath))
        {
            var filePath = Path.Combine(installPath, "hyperConnect.exe");
            if (File.Exists(filePath)) return filePath;

            filePath = Path.Combine(installPath, ProductExecutableName);
            if (File.Exists(filePath)) return filePath;

            filePath = Path.Combine(installPath, "MiPcContinuity.exe");
            if (File.Exists(filePath)) return filePath;

            // 6.x 布局：注册表指向 <版本目录>\MiSmartShare\MiDropShellExt.dll，
            // 宿主程序在上层目录 <版本目录>\XiaomiPcManager.exe
            var folder = installPath;
            for (int i = 0; i < 4 && !string.IsNullOrEmpty(folder); i++)
            {
                var parent = Path.GetDirectoryName(folder);
                if (string.IsNullOrEmpty(parent)) break;

                filePath = Path.Combine(parent, ProductExecutableName);
                if (File.Exists(filePath)) return filePath;

                folder = parent;
            }
        }
        return string.Empty;
    }

    public static string GetIconString()
    {
        var installPath = GetInstallPath();
        if (!string.IsNullOrEmpty(installPath))
        {
            var icoFilePath = Path.Combine(installPath, "Assets", "midrop_logo.ico");
            if (File.Exists(icoFilePath)) return icoFilePath;

            var exeFilePath = GetExecuteFile();
            if (File.Exists(exeFilePath)) return $"{exeFilePath},0";
        }

        return string.Empty;
    }

    public static Task<bool> LaunchAsync(CancellationToken cancellationToken)
    {
        return LaunchAsync(null, cancellationToken);
    }

    public static Task<bool> LaunchAsync(string? arguments, CancellationToken cancellationToken)
    {
        var messageWindow = FindMessageWindow();
        if (messageWindow != 0)
        {
            if (string.IsNullOrEmpty(arguments)) return Task.FromResult(true);
        }

        var executeFile = GetExecuteFile();
        if (!string.IsNullOrEmpty(executeFile))
        {
            return LaunchAsyncCore(executeFile, arguments, cancellationToken);
        }
        return Task.FromResult(false);
    }

    public static async Task<bool> SendCachedFilesAsync(string cacheKey, TimeSpan timeout)
    {
        var xiaomiFile = await FilesHelper.GetXiaomiFileAsync(cacheKey, default).ConfigureAwait(false);
        if (!string.IsNullOrEmpty(xiaomiFile))
        {
            return await SendFilesAsyncCore(xiaomiFile, timeout);
        }
        return false;
    }

    public static Task<bool> SendFilesAsync(string[] files, TimeSpan timeout)
    {
        var xiaomiFile = CreateXiaomiFile(files);
        if (!string.IsNullOrEmpty(xiaomiFile))
        {
            return SendFilesAsyncCore(xiaomiFile, timeout);
        }

        return Task.FromResult(false);
    }

    private static Task<bool> LaunchAsyncCore(string executeFile, string? arguments, CancellationToken cancellationToken)
    {
        var psi = new ProcessStartInfo(executeFile, arguments ?? "")
        {
            UseShellExecute = true
        };

        var tcs = new TaskCompletionSource<bool>();

        var registration = cancellationToken.Register(() =>
        {
            tcs.TrySetCanceled(cancellationToken);
        });

        var thread = new Thread(() =>
        {
            try
            {
                var process = Process.Start(executeFile);
                var deadline = DateTime.UtcNow + TimeSpan.FromSeconds(15);
                while (!cancellationToken.IsCancellationRequested && !process.HasExited)
                {
                    var messageWindow = FindMessageWindow();
                    if (messageWindow != 0)
                    {
                        tcs.TrySetResult(true);
                        break;
                    }
                    if (DateTime.UtcNow > deadline)
                    {
                        tcs.TrySetResult(true);
                        break;
                    }

                    Thread.Sleep(500);
                }
            }
            catch { }
            registration.Dispose();
            tcs.TrySetResult(false);
        });
        thread.IsBackground = true;
        thread.Start();

        return tcs.Task;
    }


    internal static async Task<bool> SendFilesAsyncCore(string xiaomiFile, TimeSpan timeout)
    {
        if (string.IsNullOrEmpty(xiaomiFile)) return false;

        try
        {
            // 6.x：走官方命令行协议 --contextmenu_dropfile
            var executeFile = GetExecuteFile();
            if (!string.IsNullOrEmpty(executeFile))
            {
                var payload = BuildContextMenuPayload(xiaomiFile);
                if (!string.IsNullOrEmpty(payload))
                {
                    var argument = ContextMenuDropFileArgument
                        + "=" + ContextMenuPayloadPrefix
                        + Convert.ToBase64String(Encoding.UTF8.GetBytes(payload));

                    if (executeFile.Length + argument.Length + 4 <= MaxCommandLineLength)
                    {
                        if (StartWithArgument(executeFile, argument))
                        {
                            Log($"send via payload, files={payload.Length}, argLen={argument.Length}");
                            return true;
                        }
                    }
                    else
                    {
                        Log($"payload too long for command line, argLen={argument.Length}, fallback to mapping");
                    }

                    if (await SendViaSharedMemoryAsync(executeFile, payload, timeout).ConfigureAwait(false))
                    {
                        return true;
                    }
                }
            }

            // 5.x 兜底：WM_COPYDATA
            return await SendViaCopyDataAsync(xiaomiFile, timeout).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            Log("SendFilesAsyncCore failed: " + ex.Message);
            return false;
        }
    }

    /// <summary>
    /// 构造 6.x 官方载荷：parent_dir:&lt;首个文件所在目录&gt;|&lt;文件1&gt;|&lt;文件2&gt;...
    /// </summary>
    internal static string BuildContextMenuPayload(string xiaomiFile)
    {
        var files = xiaomiFile.Split('|', StringSplitOptions.RemoveEmptyEntries)
            .Where(static c => !string.IsNullOrWhiteSpace(c))
            .ToArray();

        if (files.Length == 0) return string.Empty;

        var sb = new StringBuilder();
        var parentDir = Path.GetDirectoryName(files[0]);
        if (!string.IsNullOrEmpty(parentDir))
        {
            sb.Append("parent_dir:").Append(parentDir);
        }

        for (int i = 0; i < files.Length; i++)
        {
            if (sb.Length > 0) sb.Append('|');
            sb.Append(files[i]);
        }

        return sb.ToString();
    }

    private static bool StartWithArgument(string executeFile, string argument)
    {
        try
        {
            var psi = new ProcessStartInfo(executeFile)
            {
                UseShellExecute = false,
                WorkingDirectory = Path.GetDirectoryName(executeFile) ?? string.Empty,
            };
            psi.ArgumentList.Add(argument);

            using var process = Process.Start(psi);
            Log($"started {Path.GetFileName(executeFile)} pid={process?.Id}");
            return process != null;
        }
        catch (Exception ex)
        {
            Log("StartWithArgument failed: " + ex.Message);
            return false;
        }
    }

    /// <summary>
    /// 命令行过长时，把载荷写进 named shared memory，再用 --contextmenu_dropfile=mapping:&lt;name&gt; 唤起。
    /// </summary>
    private static async Task<bool> SendViaSharedMemoryAsync(string executeFile, string payload, TimeSpan timeout)
    {
        var mappingName = ContextMenuMappingNamePrefix + Guid.NewGuid().ToString("N");

        try
        {
            using var memoryMappedFile = MemoryMappedFile.CreateNew(mappingName, (payload.Length + 1) * 2);
            using (var accessor = memoryMappedFile.CreateViewAccessor())
            {
                var bytes = Encoding.Unicode.GetBytes(payload + "\0");
                accessor.WriteArray(0, bytes, 0, bytes.Length);
            }

            var argument = ContextMenuDropFileArgument + "=" + ContextMenuMappingPrefix + mappingName;
            if (!StartWithArgument(executeFile, argument)) return false;

            Log($"send via mapping {mappingName}, payload={payload.Length}");

            var wait = timeout <= TimeSpan.Zero || timeout > TimeSpan.FromSeconds(20)
                ? TimeSpan.FromSeconds(20)
                : timeout;

            // 保持 mapping 存活，直到对端读完
            await Task.Delay(wait).ConfigureAwait(false);
            return true;
        }
        catch (Exception ex)
        {
            Log("SendViaSharedMemoryAsync failed: " + ex.Message);
            return false;
        }
    }

    private static Task<bool> SendViaCopyDataAsync(string xiaomiFile, TimeSpan timeout)
    {
        var messageWindow = FindMessageWindow();
        if (messageWindow == 0) return Task.FromResult(false);

        var tcs = new TaskCompletionSource<bool>();

        var thread = new Thread(() =>
        {
            try
            {
                tcs.TrySetResult(SendFilesCore(messageWindow, xiaomiFile, timeout));
            }
            catch { }
            tcs.TrySetResult(false);

            unsafe static bool SendFilesCore(nint messageWindow, string xiaomiFiles, TimeSpan timeout)
            {
                fixed (char* ptr = xiaomiFiles)
                {
                    var s = default(COPYDATASTRUCT);
                    s.dwData = 0;
                    s.cbData = (xiaomiFiles.Length) * 2;
                    s.lpData = (nint)ptr;

                    var timeout2 = unchecked((uint)timeout.TotalMilliseconds);
                    if (timeout2 > 15 * 1000) timeout2 = 15 * 1000;
                    if (timeout2 < 0) timeout2 = 0;

                    var res = SendMessageTimeoutW(messageWindow, 74, (IntPtr)1, (nint)(&s), 0, timeout2, out var lpdwResult);
                    return res != 0;
                }
            }
        });
        thread.IsBackground = true;
        thread.Start();

        return tcs.Task;
    }

    internal static string CreateXiaomiFile(string[] files)
    {
        var sb = new StringBuilder();
        for (int i = 0; i < files.Length; i++)
        {
            var path = files[i];

            if (!string.IsNullOrEmpty(path)
                && Path.IsPathRooted(path))
            {
                if (sb.Length > 0) sb.Append('|');
                sb.Append(path);
            }
        }

        return sb.ToString();
    }

    /// <summary>
    /// 诊断日志，落在 &lt;LocalApplicationData&gt;\MiDropHelper\MiDropHelper.patch.log
    /// </summary>
    private static void Log(string message)
    {
        try
        {
            var folder = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "MiDropHelper");
            Directory.CreateDirectory(folder);

            var logPath = Path.Combine(folder, "MiDropHelper.patch.log");
            var info = new FileInfo(logPath);
            if (info.Exists && info.Length > 256 * 1024) File.Delete(logPath);

            File.AppendAllText(logPath, $"[{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff}] {message}{Environment.NewLine}");
        }
        catch { }
    }

    private unsafe static nint FindMessageWindow()
    {
        const string WindowClassName1 = "XiaomiPCManager";
        const string WindowClassName2 = "MiPcContinuity";

        fixed (char* pClassName = WindowClassName1)
        {
            var hwnd = FindWindowW(pClassName, null);
            if (hwnd > 0) return hwnd;
        }
        fixed (char* pClassName = WindowClassName2)
        {
            var hwnd = FindWindowW(pClassName, null);
            if (hwnd > 0) return hwnd;
        }
        return 0;
    }

    [DllImport("user32.dll")]
    private static unsafe extern nint SendMessageW(nint hWnd, int Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static unsafe extern int SendMessageTimeoutW(nint hWnd, int Msg, IntPtr wParam, IntPtr lParam, uint fuFlags, uint uTimeout, out nint lpdwResult);

    [DllImport("user32.dll")]
    private static unsafe extern nint FindWindowW(char* lpClassName, char* lpWindowName);

    private struct COPYDATASTRUCT
    {
        public nint dwData;

        public int cbData;

        public nint lpData;
    }

}
