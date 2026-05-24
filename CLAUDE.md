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
Operator machine is **not joined to the target domain**. The operator has full local admin on their own machine and has domain credentials for the target environment. Amnesiac runs with no EDR constraints on the operator side.

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
- Operator machine is NOT monitored — no AMSI/EDR constraints on loading Amnesiac itself
- Full local admin — can write files, start listeners, run `serve`, etc.
- `diskmode` defaults to OFF to protect targets, but can be enabled on operator side safely
- All target-side operations remain in-memory

### Scenario 2 — Low-Privilege Assumed Breach (Domain-Joined, EDR-Protected)
Operator has obtained a **low-privilege shell on a domain-joined machine** that is running Windows Defender and a corporate EDR (e.g., CrowdStrike Falcon). The operator needs to run Amnesiac on THIS compromised machine to enumerate, exploit, and move laterally — not from their own clean machine.

**Key characteristics:**
- Amnesiac.ps1 itself must not be detected when loaded — AMSI scans the entire script before execution
- Script Block Logging (event 4104) would expose every command typed
- Low-privilege: cannot write to system paths, cannot install services, limited WMI access
- EDR behavioral rules monitor process creation, pipe usage, reflective loading
- Must use `Amnesiac_ShellReady.ps1` (no ANSI colour codes that may trigger signatures)
- `diskmode` MUST remain OFF — any disk write may be scanned

**⚠️ KNOWN GAP — Self-protection loader not yet implemented:**
Amnesiac.ps1 has no self-bypass. AMSI scans the file before any code runs, so a bypass inside the file cannot protect itself. A separate small loader/bypass stub is required to:
1. Bypass AMSI in the current PS process
2. Disable ETW/SBL
3. Then dot-source Amnesiac_ShellReady.ps1

This is planned but not yet implemented. See: `docs/superpowers/specs/` for future spec.

Current workaround: load from an already-AMSI-patched PS session, or use a pre-existing AMSI bypass technique before dot-sourcing.

Set engagement profile:
```
engagement domained
```

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
| **Scenario 2 self-protection loader** | High | No AMSI/ETW/SBL bypass for loading Amnesiac.ps1 itself on a defender-protected machine. Requires a separate small loader stub that bypasses AMSI in the PS process before dot-sourcing Amnesiac_ShellReady.ps1. |
| **Tool cache fallback chain** | Medium | `serve` still downloads from GitHub to disk (disk write dependency). `Send-Module` does not auto-fetch missing tools from operator HTTP or GitHub. Tiers 3 and 4 are documented but not wired. |
| **`serve` diskmode conflict** | Medium | The `serve` command writes files to `Scripts\` folder, which is blocked when `diskmode off`. Should host from `Tools\` in-memory instead of downloading to disk first. |

---

## Contribution Notes

- All changes target `Amnesiac.ps1` only unless adding new source files
- Test each layer independently before combining
- Run against GOAD lab with CrowdStrike enabled to validate evasion
- Document every change in `CHANGELOG.md` with the operational context for the change
- The `stealth` payload format must be regenerated (re-toggle) after any protocol change — the gzip blob is built at generation time with the current session's `$global:EndMarker` and `$global:BufferSize`
