# Changelog — Amnesiac Red Team Edition

All changes are documented with the operational context that motivated them.
Format: `[LAYER] Change description — *why this matters operationally*`

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

## [Planned] — Future Work

**Fix `load loader` delivery redundancy**
- Current implementation sends chunks then also sends full base64 directly — duplicate delivery path
- Should be simplified to single `Send-Module` call only

**Port all changes to `Amnesiac_ShellReady.ps1`**
- Shell-compatible version hasn't received any of the above changes
- Deferred until all layers are stable

**Extend Pester test coverage**
- Current 28 tests cover PS-level helpers only
- Add tests for: `load loader` command behavior, `Migrate ps` handlers, `Send-Module` framing, AmnesiacLoader build verification (compile check)

**Multi-frame call stack spoofing**
- `CallStack.SpoofFrames()` is a stub — current implementation inserts only one fake frame
- Extend to 3-5 frames for a more convincing ntdll→kernelbase→kernel32 chain
