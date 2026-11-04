using System;
using System.Runtime.InteropServices;

// 目的：不依赖资源管理器，直接加载包内 ShellExt.dll，调用 DllGetClassObject 拿到
// IExplorerCommand，读回 GetIcon()/GetTitle()，验证「图标路径 + 菜单标题」是否正确。

internal static class Program
{
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private unsafe delegate int DllGetClassObjectFn(Guid* clsid, Guid* riid, IntPtr* ppv);

    [ComImport, Guid("00000001-0000-0000-C000-000000000046"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IClassFactory
    {
        void CreateInstance([MarshalAs(UnmanagedType.IUnknown)] object pUnkOuter, ref Guid riid,
            [MarshalAs(UnmanagedType.IUnknown)] out object ppv);
        void LockServer(bool fLock);
    }

    [ComImport, Guid("a08ce4d0-fa25-44ab-b57c-c7b1c323e0b9"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IExplorerCommand
    {
        [return: MarshalAs(UnmanagedType.LPWStr)] string GetTitle(IntPtr psiItemArray);
        [return: MarshalAs(UnmanagedType.LPWStr)] string GetIcon(IntPtr psiItemArray);
        [return: MarshalAs(UnmanagedType.LPWStr)] string GetToolTip(IntPtr psiItemArray);
        [return: MarshalAs(UnmanagedType.LPWStr)] string GetCanonicalName();
        int GetState(IntPtr psiItemArray, [MarshalAs(UnmanagedType.Bool)] bool fOkToBeSlow, out uint pCmdState);
        void Invoke(IntPtr psiItemArray, IntPtr pbc);
        uint GetFlags();
        IntPtr EnumSubCommands();
    }

    private static string Try(Func<string> f)
    {
        try { return f() ?? "<null>"; }
        catch (Exception ex) { return "EXC: " + ex.GetType().Name + ": " + ex.Message; }
    }

    private static unsafe int Main(string[] args)
    {
        string dll = args.Length > 0
            ? args[0]
            : @"C:\Program Files\WindowsApps\5f71dad9-3e77-4ada-9fad-12c2e761288f_1.0.7.0_x64__h7hff4v7bt4z0\ShellExt\ShellExt.dll";

        Console.WriteLine($"dll: {dll}");
        IntPtr h = NativeLibrary.Load(dll);
        Console.WriteLine($"LoadLibrary ok, handle=0x{h.ToInt64():X}");

        IntPtr fn = NativeLibrary.GetExport(h, "DllGetClassObject");
        var getClassObject = (DllGetClassObjectFn)Marshal.GetDelegateForFunctionPointer(fn, typeof(DllGetClassObjectFn));

        Guid clsid = new Guid("976D43D8-907F-46AF-B47F-07084C71A2F0");
        Guid iidFactory = new Guid("00000001-0000-0000-C000-000000000046");
        IntPtr ppv = IntPtr.Zero;

        int hr = getClassObject(&clsid, &iidFactory, &ppv);
        Console.WriteLine($"DllGetClassObject(IClassFactory) hr=0x{hr:X8} ppv=0x{ppv.ToInt64():X}");
        if (hr != 0 || ppv == IntPtr.Zero) return 2;

        var factory = (IClassFactory)Marshal.GetObjectForIUnknown(ppv);
        Guid iidCmd = new Guid("a08ce4d0-fa25-44ab-b57c-c7b1c323e0b9");
        factory.CreateInstance(null, ref iidCmd, out object obj);
        var cmd = (IExplorerCommand)obj;

        string title = Try(() => cmd.GetTitle(IntPtr.Zero));
        string icon = Try(() => cmd.GetIcon(IntPtr.Zero));
        string tooltip = Try(() => cmd.GetToolTip(IntPtr.Zero));
        string stateText = Try(() =>
        {
            uint state;
            int hrState = cmd.GetState(IntPtr.Zero, true, out state);
            return $"0x{state:X} (hr=0x{hrState:X8})  [0=ECS_ENABLED,1=DISABLED,2=HIDDEN]";
        });
        string flags = Try(() => $"0x{cmd.GetFlags():X}");

        Console.WriteLine($"Title   = {title}");
        Console.WriteLine($"Icon    = {icon}");
        Console.WriteLine($"ToolTip = {tooltip}");
        Console.WriteLine($"State   = {stateText}");
        Console.WriteLine($"Flags   = {flags}");
        if (!string.IsNullOrEmpty(icon) && !icon.StartsWith("EXC:", StringComparison.Ordinal))
        {
            Console.WriteLine($"IconExistsOnDisk = {System.IO.File.Exists(icon.Split(',')[0])}");
        }
        return 0;
    }
}
