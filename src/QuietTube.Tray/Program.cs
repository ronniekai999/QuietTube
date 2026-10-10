using System.Security.Cryptography;
using System.Text;
using QuietTube.Core;
using QuietTube.Tray;

namespace QuietTube;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        var instance = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(AppPaths.DataDirectory)))[..20];
        var mutexName = "Local\\QuietTube.Tray." + instance;
        var eventName = "Local\\QuietTube.Show." + instance;
        using var singleton = new Mutex(true, mutexName, out var created);
        if (!created)
        {
            try { using var existing = EventWaitHandle.OpenExisting(eventName); existing.Set(); }
            catch (WaitHandleCannotBeOpenedException) { }
            return;
        }
        ApplicationConfiguration.Initialize();
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.CatchException);
        Application.ThreadException += (_, e) => MessageBox.Show(e.Exception.Message, "QuietTube needs attention", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        using var showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, eventName);
        using var context = new TrayContext(showEvent, args.Contains("--background"));
        Application.Run(context);
        singleton.ReleaseMutex();
    }
}
