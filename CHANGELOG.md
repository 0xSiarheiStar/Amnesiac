# Changelog — Amnesiac Red Team Edition

All changes are documented with the operational context that motivated them.
Format: `[LAYER] Change description — *why this matters operationally*`

---

## [Unreleased] — Stealth Overhaul

### Layer 2 (Partial) — Payload Format: `stealth`
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

## [Planned] — Layer 1: Disk Elimination

**Remove unconditional folder creation at startup**
- `C:\Users\Public\Documents\Amnesiac\` and eight subfolders currently created on every startup
- *Context: Creating a well-known directory tree on startup is an IOC. The directory name alone triggers detections in some environments. Default should be no artifacts on disk.*

**Add `diskmode` toggle command**
- `diskmode on` restores original behaviour; `diskmode off` is the new default
- *Context: Operators doing internal lab testing may want disk artifacts for debugging. `diskmode on` preserves that capability without making it the default.*

**Add `$global:AmnesiacArtifacts` in-memory store**
- Keylogger output, screenshots, clipboard data, TGT data buffered in operator memory
- *Context: Data captured on targets must return to the operator, but writing it to disk on the target or operator machine creates forensic evidence. In-memory buffering on operator side is the right default.*

**Add `artifacts` and `save` session commands**
- View and selectively persist captured data
- *Context: Operators need to access captured data without a blanket disk-write policy.*

**Gate `exe` payload format behind `diskmode`**
- Warn and block if operator tries to use `exe` format with `diskmode off`
- *Context: The exe format writes a compiled binary to disk. This is incompatible with the disk-free operational model and should require explicit opt-in.*

---

## [Planned] — Layer 4: Operational Guardrails

**Add `engagement` command and profile system**
- `nondomained` and `domained` profiles set context-appropriate defaults
- *Context: Non-domain-joined and assumed-breach scenarios have different requirements (default listener mode, PSK derivation, startup guidance). Manually configuring these each session is error-prone.*

**Add `runas /netonly` token detection**
- Detect Type-9 (NewCredentials) logon token at startup in `nondomained` mode
- *Context: Operating against a domain from a non-joined machine requires a Kerberos ticket in the token. If the operator forgot to use `runas /netonly`, all domain operations will silently fail. Early detection prevents wasted time.*

**Add `key` command for payload environment keying**
- Hostname, domain, username checks baked into payloads before gzip compression
- *Context: Accidental payload execution on the wrong machine wastes a callback opportunity, creates noise, and may alert the target organisation. Environment keying ensures the payload only executes on the intended target.*

**Add startup OPSEC status banner**
- Disk mode, engagement profile, token status, tool cache count, session markers, loader status
- *Context: Operators need to confirm their OPSEC configuration is correct before generating payloads. A single-screen summary at startup prevents configuration mistakes.*

**Add `psk` command for AES pipe encryption**
- Pre-shared key management for the AES-128 CBC pipe channel
- *Context: Named pipe data traverses SMB in plaintext unless SMB signing/sealing is enforced. A session-level AES encryption layer ensures command content is not visible to network monitoring even if SMB traffic is inspected.*

---

## [Planned] — Layer 2: Payload Extensions

**Add `launcher` command — alternative execution vectors**
- `ps` (default), `wmi`, `schtask`, `com` vectors change the parent process visible in EDR
- *Context: CS process tree analysis is one of its strongest detection mechanisms. `powershell.exe` spawned by `cmd.exe` or `sc.exe` is high-signal. Launching via WMI (`WmiPrvSE.exe` parent) or Task Scheduler (`svchost.exe` parent) significantly reduces the behavioral score.*

**Randomise `#END#` delimiter and pipe buffer size per session**
- `$global:EndMarker` = random 8-char string; `$global:BufferSize` = random from {512,1024,2048,4096}
- *Context: The fixed string `#END#` and 1028-byte buffer are fingerprints that network and memory scanners can use to identify Amnesiac sessions. Session-unique values eliminate this static indicator.*

**Add AES-128 CBC pipe channel encryption**
- Session key negotiated on first connect using a PSK
- *Context: Named pipe content (commands and outputs) is currently plaintext at the SMB layer. Network defenders with full-packet capture can read commands being issued. AES encryption ensures confidentiality of the C2 channel.*

---

## [Planned] — Layer 2b: AmnesiacLoader C# Assembly

**Add `AmnesiacLoader/` C# project**
- `Loader.cs`, `CallStack.cs`, `SleepMask.cs`, `Build.ps1`, `AmnesiacLoader.csproj`
- *Context: Pure PowerShell cannot implement indirect syscalls or call stack spoofing — these require compiled code that executes at the binary level. A C# assembly loaded reflectively provides this without a disk write.*

**Embed compiled DLL as `$AmnesiacLoaderB64` constant**
- Assembly loaded via `[Reflection.Assembly]::Load()` — never written to disk
- *Context: If the assembly were written to disk as a DLL, it would be scanned on write and create a forensic artifact. Embedding as a base64 constant in the PS script and loading from memory bypasses both.*

**Indirect syscall injection (`AmnesiacLoader.Injector`)**
- SSN resolution via EAT walking on ntdll; VEH redirection to ntdll stubs
- Replaces `VirtualAllocEx`/`WriteProcessMemory`/`CreateRemoteThread` in `Migrate` and `PInject`
- *Context: CS monitors specific Win32 API call patterns at the kernel level. Indirect syscalls bypass userland hooks and produce call chains that look like legitimate ntdll operations.*

**Call stack spoofing (`AmnesiacLoader.CallStack`)**
- Synthetic ROP frames inserted before syscall dispatch
- *Context: CS telemetry records the call stack at injection events. A call stack originating from PS internals is high-signal. Spoofed frames showing `ntdll→kernelbase→kernel32` origin reduces the behavioral score.*

**Sleep masking (`AmnesiacLoader.SleepMask`)**
- AES-encrypt implant memory during `Sleep()`; `PAGE_NOACCESS` during dormancy; decrypt on wake
- *Context: CS performs memory scanning for known shellcode patterns. If the implant's memory is encrypted and marked non-accessible during sleep, the scanner finds nothing. This is critical for long-dwell operations.*

**Update `Migrate` and `PInject` commands to use AmnesiacLoader**
- Same operator interface; cleaner injection path under the hood
- *Context: The existing PInject.ps1 uses standard Win32 injection APIs that are heavily monitored. Replacing with the AmnesiacLoader path gives operators the same workflow with significantly better evasion.*

---

## [Planned] — Layer 3: In-Memory Tool Delivery

**Add `$global:ToolCache` hashtable and `Initialize-ToolCache` function**
- Populated at startup from embedded blobs, local `Tools\`, and operator HTTP server
- *Context: The current model downloads tool scripts from GitHub to the target's disk on demand. This creates both a disk IOC and anomalous outbound traffic from servers to github.com — a near-certain EDR alert.*

**Embed Core tier tools as gzip+base64 constants in Amnesiac.ps1**
- SimpleAMSI, NETAMSI, Token-Impersonation, Invoke-SMBRemoting, Invoke-WMIRemoting, Find-LocalAdminAccess
- *Context: These six tools are used in virtually every engagement. Embedding them guarantees availability with zero network dependency and ensures no GitHub traffic even if the local Tools\ folder is absent.*

**Add `Send-Module` function — in-pipe tool delivery**
- Streams tool source from operator cache over named pipe; target executes via `[scriptblock]::Create()`
- *Context: The target never fetches anything from the network and never writes anything to disk. The entire tool execution happens in target memory, fed from the operator's local cache.*

**Change `$global:ServerURL` default to operator HTTP server**
- Default: `http://<operator-IP>:8080` (File-Server.ps1) instead of GitHub
- *Context: Even with the in-pipe delivery model, some tools may need to fall back to HTTP. The fallback should be the operator's controlled server, not a public GitHub URL that creates obvious IOCs.*

**Add GitHub call blocking when `diskmode` is off**
- Intercept `githubusercontent.com` calls; substitute from cache; warn if not cached
- *Context: Prevents accidental GitHub downloads during engagements. The block is a safety net — operators who forget to pre-cache a tool get a clear actionable error instead of an EDR alert.*

**Add `modules` command**
- `modules`, `modules reload`, `modules status`
- *Context: Operators need visibility into which tools are available before needing them mid-engagement.*
