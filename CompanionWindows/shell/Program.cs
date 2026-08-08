namespace VisionVNC.Companion.Shell;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        BackendLauncher.Start();
        Application.Run(new MainForm());
    }
}
