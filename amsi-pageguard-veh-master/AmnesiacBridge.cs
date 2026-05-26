// AmnesiacBridge — C# Runspace host loaded by amnesiac_launcher.exe via CLR.
// Receives PS script content as a string (already downloaded in native code),
// creates a full interactive PSHost, and runs the script + Amnesiac entry point.
// Target: net462 (runs on any Windows with .NET 4.6.2+)

using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Management.Automation.Runspaces;
using System.Security;

namespace AmnesiacBridge
{
    // ---------------------------------------------------------------------------
    // Raw UI — delegates everything to System.Console
    // ---------------------------------------------------------------------------
    sealed class ConsoleRawUI : PSHostRawUserInterface
    {
        public override ConsoleColor BackgroundColor
        {
            get => Console.BackgroundColor;
            set => Console.BackgroundColor = value;
        }
        public override ConsoleColor ForegroundColor
        {
            get => Console.ForegroundColor;
            set => Console.ForegroundColor = value;
        }
        public override Size BufferSize
        {
            get => new Size(Console.BufferWidth, Console.BufferHeight);
            set { try { Console.BufferWidth = value.Width; Console.BufferHeight = value.Height; } catch { } }
        }
        public override Size WindowSize
        {
            get => new Size(Console.WindowWidth, Console.WindowHeight);
            set { try { Console.WindowWidth = value.Width; Console.WindowHeight = value.Height; } catch { } }
        }
        public override Size MaxWindowSize      => new Size(Console.LargestWindowWidth, Console.LargestWindowHeight);
        public override Size MaxPhysicalWindowSize => MaxWindowSize;
        public override Coordinates WindowPosition
        {
            get => new Coordinates(Console.WindowLeft, Console.WindowTop);
            set { try { Console.SetWindowPosition(value.X, value.Y); } catch { } }
        }
        public override string WindowTitle
        {
            get => Console.Title;
            set => Console.Title = value;
        }
        public override Coordinates CursorPosition
        {
            get => new Coordinates(Console.CursorLeft, Console.CursorTop);
            set { try { Console.SetCursorPosition(value.X, value.Y); } catch { } }
        }
        public override int CursorSize
        {
            get => Console.CursorSize;
            set { try { Console.CursorSize = value; } catch { } }
        }
        public override bool KeyAvailable => Console.KeyAvailable;

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
    // User interface — delegates I/O to System.Console
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
            Console.ForegroundColor = fg;
            Console.BackgroundColor = bg;
            Console.Write(value);
            Console.ForegroundColor = prevFg;
            Console.BackgroundColor = prevBg;
        }

        public override void WriteLine()                => Console.WriteLine();
        public override void WriteLine(string value)    => Console.WriteLine(value);
        public override void WriteDebugLine(string msg) => Console.WriteLine("[DEBUG] " + msg);
        public override void WriteVerboseLine(string msg) { }
        public override void WriteWarningLine(string msg)
        {
            var prev = Console.ForegroundColor;
            Console.ForegroundColor = ConsoleColor.Yellow;
            Console.WriteLine("[WARNING] " + msg);
            Console.ForegroundColor = prev;
        }
        public override void WriteErrorLine(string value)
        {
            var prev = Console.ForegroundColor;
            Console.ForegroundColor = ConsoleColor.Red;
            Console.Error.WriteLine(value);
            Console.ForegroundColor = prev;
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
            Console.WriteLine(caption + " — " + message);
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
        private readonly Guid   _id  = Guid.NewGuid();
        private readonly ConsoleUI _ui = new ConsoleUI();

        public override string           Name            => "AmnesiacLauncher";
        public override Version          Version         => new Version(1, 0);
        public override Guid             InstanceId      => _id;
        public override PSHostUserInterface UI           => _ui;
        public override CultureInfo      CurrentCulture  => CultureInfo.CurrentCulture;
        public override CultureInfo      CurrentUICulture => CultureInfo.CurrentUICulture;
        public override void EnterNestedPrompt()    { }
        public override void ExitNestedPrompt()     { }
        public override void NotifyBeginApplication() { }
        public override void NotifyEndApplication() { }
        public override void SetShouldExit(int exitCode) => Environment.Exit(exitCode);
    }

    // ---------------------------------------------------------------------------
    // Public entry point — called from C++ via CLR hosting
    // ---------------------------------------------------------------------------
    public static class Launcher
    {
        // scriptContent: UTF-8 content of Amnesiac_ShellReady.ps1 as a string
        public static void Run(string scriptContent)
        {
            var host = new ConsoleHost();
            var iss  = InitialSessionState.CreateDefault();

            using (Runspace rs = RunspaceFactory.CreateRunspace(host, iss))
            {
                rs.Open();

                // Bypass execution policy without ExecutionPolicy property (PS5.1 compatible)
                using (PowerShell bypass = PowerShell.Create())
                {
                    bypass.Runspace = rs;
                    bypass.AddScript("Set-ExecutionPolicy -Scope Process -ExecutionPolicy Unrestricted -Force");
                    bypass.Invoke();
                }

                using (PowerShell ps = PowerShell.Create())
                {
                    ps.Runspace = rs;

                    // Load the script (defines Amnesiac function + globals)
                    ps.AddScript(scriptContent);
                    ps.Invoke();

                    if (ps.HadErrors)
                    {
                        foreach (var e in ps.Streams.Error)
                            Console.Error.WriteLine("[-] Script error: " + e);
                        return;
                    }

                    // Invoke entry point
                    ps.Commands.Clear();
                    ps.AddCommand("Amnesiac");
                    ps.Invoke();
                }
            }
        }
    }
}
