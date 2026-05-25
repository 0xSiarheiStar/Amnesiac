
function Test-Pipe([string]$label, [string]$serverScript) {
    $pn = -join ((65..90+97..122) | Get-Random -Count 10 | % {[char]$_})
    $body = $serverScript -replace '__PN__', $pn
    $enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($body))
    $proc = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-ep','Bypass','-NoProfile','-enc',$enc -PassThru
    Start-Sleep -Milliseconds 600

    try {
        $c = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pn, 'InOut')
        $c.Connect(2000)
        if ($c.IsConnected) {
            $sr = New-Object System.IO.StreamReader($c)
            $line = $sr.ReadLine()
            $c.Dispose()
            Write-Host "  [PASS] $label - got: $line" -ForegroundColor Green
            return $true
        }
    } catch {
        Write-Host "  [FAIL] $label - $_" -ForegroundColor Red
    } finally {
        try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
    }
    return $false
}

Write-Output ""
Write-Output "=== Named Pipe Constructor Tests ==="
Write-Output ""

# A: 2-arg (bare)
Test-Pipe "2-arg bare" @'
$p=New-Object System.IO.Pipes.NamedPipeServerStream('__PN__','InOut')
$p.WaitForConnection()
$w=New-Object System.IO.StreamWriter($p); $w.WriteLine('A'); $w.Flush(); $p.Dispose()
'@

# B: 7-arg no security
Test-Pipe "7-arg no-security" @'
$p=New-Object System.IO.Pipes.NamedPipeServerStream('__PN__','InOut',1,'Byte','None',4096,4096)
$p.WaitForConnection()
$w=New-Object System.IO.StreamWriter($p); $w.WriteLine('B'); $w.Flush(); $p.Dispose()
'@

# C: 8-arg with Everyone SID PipeSecurity
Test-Pipe "8-arg PipeSecurity Everyone" @'
$sec=New-Object System.IO.Pipes.PipeSecurity
$sid=New-Object System.Security.Principal.SecurityIdentifier 'S-1-1-0'
$ar=New-Object System.IO.Pipes.PipeAccessRule($sid,'FullControl','Allow')
$sec.AddAccessRule($ar)
$p=New-Object System.IO.Pipes.NamedPipeServerStream('__PN__','InOut',1,'Byte','None',4096,4096,$sec)
$p.WaitForConnection()
$w=New-Object System.IO.StreamWriter($p); $w.WriteLine('C'); $w.Flush(); $p.Dispose()
'@

# D: 8-arg with ReadWrite (not FullControl)
Test-Pipe "8-arg PipeSecurity ReadWrite Everyone" @'
$sec=New-Object System.IO.Pipes.PipeSecurity
$sid=New-Object System.Security.Principal.SecurityIdentifier 'S-1-1-0'
$ar=New-Object System.IO.Pipes.PipeAccessRule($sid,'ReadWrite','Allow')
$sec.AddAccessRule($ar)
$p=New-Object System.IO.Pipes.NamedPipeServerStream('__PN__','InOut',1,'Byte','None',4096,4096,$sec)
$p.WaitForConnection()
$w=New-Object System.IO.StreamWriter($p); $w.WriteLine('D'); $w.Flush(); $p.Dispose()
'@

# E: 7-arg + SetAccessControl after creation
Test-Pipe "7-arg + SetAccessControl after" @'
$p=New-Object System.IO.Pipes.NamedPipeServerStream('__PN__','InOut',1,'Byte','None',4096,4096)
$sec=New-Object System.IO.Pipes.PipeSecurity
$sid=New-Object System.Security.Principal.SecurityIdentifier 'S-1-1-0'
$ar=New-Object System.IO.Pipes.PipeAccessRule($sid,'FullControl','Allow')
$sec.AddAccessRule($ar)
$p.SetAccessControl($sec)
$p.WaitForConnection()
$w=New-Object System.IO.StreamWriter($p); $w.WriteLine('E'); $w.Flush(); $p.Dispose()
'@

Write-Output ""
Write-Output "Done."
