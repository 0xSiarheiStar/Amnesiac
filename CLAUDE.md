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

### Scenario 1 — Non-Domain-Joined Operator
Operator machine is not joined to the target domain. Launch Amnesiac from a domain-credentialed session:

```powershell
runas /netonly /user:DOMAIN\username powershell.exe
# In the new PS window:
. .\Amnesiac.ps1; Amnesiac -Detached -IP <operator-IP>
```

Set engagement profile:
```
engagement nondomained
```

Amnesiac will detect the network logon token automatically and confirm domain credential availability.

### Scenario 2 — Domain-Joined Operator (Assumed Breach)
Operator machine is domain-joined. Launch normally:

```powershell
. .\Amnesiac.ps1; Amnesiac
```

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

## Tool Cache

Tools are loaded in three priority tiers:

| Tier | Location | Contents |
|------|----------|---------|
| Core (embedded) | Inside Amnesiac.ps1 as gzip+base64 | SimpleAMSI, NETAMSI, Token-Impersonation, Invoke-SMBRemoting, Invoke-WMIRemoting, Find-LocalAdminAccess |
| Standard (local) | `Tools\` directory | All other PS modules |
| Heavy (operator HTTP) | `http://<operator-IP>:8080` via `serve` | Suntour, Ferrari, ppl, RDPKeylog.exe |

No tool ever downloads from GitHub during a live session.

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

## Contribution Notes

- All changes target `Amnesiac.ps1` only unless adding new source files
- Test each layer independently before combining
- Run against GOAD lab with CrowdStrike enabled to validate evasion
- Document every change in `CHANGELOG.md` with the operational context for the change
- The `stealth` payload format must be regenerated (re-toggle) after any protocol change — the gzip blob is built at generation time with the current session's `$global:EndMarker` and `$global:BufferSize`
