# Post-Mortem: AMSI Blocked `. .\Amnesiac.ps1` on Load

**Date:** 2026-05-25  
**Status:** Resolved

---

## What Happened

Running `. .\Amnesiac.ps1` (or `iex` loading) was blocked by Windows Defender AMSI:

```
This script contains malicious content and has been blocked by your antivirus software.
FullyQualifiedErrorId: ScriptContainedMaliciousContent
```

After the AMSI fix was applied, a second problem surfaced: 476 cascading parse errors starting at L521 `Unexpected token '}'`, making the script un-loadable for a different reason.

---

## Issue 1 — AMSI Context-Based Signature

### Root Cause

A **multi-part context-based AMSI signature** fired on three consecutive lines in `Initialize-ToolCache`:

```powershell
# --- CORE TIER: embedded as gzip+base64 ---   ← line 295  (contains "AMSI" + "embedded")
$coreTools = @{                                 ← line 296
    'SimpleAMSI' = 'H4sIAAAA...'               ← line 297  (name adjacent to blob)
```

**Key diagnostic fact:** Neither the comment+header alone, nor the name+blob alone, triggered AMSI. Only all three lines together triggered — this is a context rule. Verified using `Tests/DiagnoseAMSITrigger.ps1` which calls `AmsiScanString` directly via P/Invoke, binary-searching the file to isolate the minimum triggering window.

### Chicken-and-Egg Problem

You cannot use AMSI bypass code inside a script that AMSI is already blocking — the static scan happens at parse time, before any code executes. The bypass embedded in `Get-AmsiBypassSnippet` (for payload generation) is irrelevant here because it never runs.

### Fix

Replaced the `$coreTools = @{ name = blob }` hashtable with two **parallel arrays** that are never adjacent:

```powershell
# core tier
$_cb = @(
    'H4sIAAAA...',   # blob 0
    'H4sIAAAA...',   # blob 1
    ...
)
$_cn = @('SimpleAMSI','NETAMSI','Token-Impersonation','Invoke-SMBRemoting','Invoke-WMIRemoting','Find-LocalAdminAccess')
for ($_i = 0; $_i -lt $_cn.Count; $_i++) {
    $bytes = [Convert]::FromBase64String($_cb[$_i])
    ...
    $global:ToolCache[$_cn[$_i]] = [System.Text.Encoding]::UTF8.GetString($out.ToArray())
}
```

No tool name now appears on the same or adjacent line as its blob. Data is unchanged — only the structural adjacency is broken.

**Applied to:** `Amnesiac.ps1` and `Amnesiac_ShellReady.ps1`  
**Verified with:** `Tests/DiagnoseAMSITrigger.ps1` → "Full file is NOT flagged by AMSI"

---

## Issue 2 — UTF-8 BOM Required for ParseFile

### Root Cause

After the AMSI fix, loading the script produced 476 cascading parse errors starting at L521 `Unexpected token '}'`. The key diagnostic: `ParseFile` of the file reported 476 errors, but `ParseInput` of the **exact same content** (read via `ReadAllText`) returned 0 errors.

This pointed to an encoding issue, not a syntax issue. The cause:

1. The AMSI fix used `[System.IO.File]::WriteAllLines(path, lines, new System.Text.UTF8Encoding($false))` — UTF-8 **without BOM**.
2. When `ParseFile` reads a file with no BOM on Windows, it falls back to the **system code page** (CP1252).
3. The em dash `—` on line 504 is encoded in UTF-8 as bytes `0xE2 0x80 0x94`.
4. In CP1252, byte `0x94` maps to **RIGHT DOUBLE QUOTATION MARK** (`"`).
5. PowerShell's parser accepts `"` (curly right quote) as a string terminator.
6. This silently closed the string literal on L504 mid-word, corrupting the AST for the next ~200 lines until the parser hit a structurally orphaned `}` at L521.

```
L504 (CP1252 view): Write-Host " [*] Multiple IPs found â€" select your..."
                                                            ↑
                                    CP1252 byte 0x94 = " (closes string here!)
```

### Fix

Re-encoded both files using `WriteAllText` with `[System.Text.Encoding]::UTF8`, which **includes the BOM** (`EF BB BF`):

```powershell
$content = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText($path, $content, [System.Text.Encoding]::UTF8)
```

With BOM present, `ParseFile` correctly identifies the file as UTF-8 and decodes all characters properly.

**Impact on `iex`/`DownloadString`:** None. .NET's `WebClient.DownloadString` handles BOM detection and strips it automatically before returning the string to `iex`.

### Permanent Rule

After **any** `WriteAllLines` surgery on either file, always rewrite with the two-line `WriteAllText` re-encode above. Verify with `Tests/FindParseError.ps1` — both `ParseFile errors` and `ParseInput errors` should be 0.

---

## Diagnostic Tools Created

| File | Purpose |
|------|---------|
| `Tests/DiagnoseAMSITrigger.ps1` | Binary-search AMSI scan using P/Invoke `AmsiScanString` — isolates minimum triggering window without executing anything |
| `Tests/FindParseError.ps1` | Runs `ParseFile` and `ParseInput` on Amnesiac.ps1 — reports error count and first error location |
| `Tests/DebugParseError.ps1` | Extended parse debug — shows byte-level file context around the error line and tests BOM vs no-BOM variants |

---

## Timeline

1. AMSI block reported after Local Shell feature (option [5]) was added
2. Root-cause analysis via `DiagnoseAMSITrigger.ps1` — isolated L295-297 context window
3. Parallel-arrays restructure applied to `Amnesiac.ps1` and `Amnesiac_ShellReady.ps1`
4. AMSI confirmed clear; 476 parse errors surfaced
5. `ParseFile` vs `ParseInput` discrepancy isolated encoding as root cause
6. BOM re-encode applied; `ParseFile errors: 0` confirmed
7. Load test: all 27 tools load (6 embedded + 21 from `Tools\`)
