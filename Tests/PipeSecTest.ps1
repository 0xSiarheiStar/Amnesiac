
$SID = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
Write-Output "Testing SID: $SID"

$pn = 'PipeSecTest' + (Get-Random -Max 9999)

$serverScript = @"
`$sec=New-Object System.IO.Pipes.PipeSecurity
`$sid=New-Object System.Security.Principal.SecurityIdentifier '$SID'
`$ar=New-Object System.IO.Pipes.PipeAccessRule(`$sid,'FullControl','Allow')
`$sec.AddAccessRule(`$ar)
`$p=New-Object System.IO.Pipes.NamedPipeServerStream('$pn','InOut',1,'Byte','None',4096,4096,`$sec)
`$p.WaitForConnection()
`$r=New-Object System.IO.StreamReader(`$p)
`$w=New-Object System.IO.StreamWriter(`$p)
`$w.WriteLine('ok')
`$w.Flush()
`$p.Dispose()
"@

$enc = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($serverScript))
$proc = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-ep','Bypass','-NoProfile','-enc',$enc -PassThru
Start-Sleep -Milliseconds 800

Write-Output "Server PID: $($proc.Id), alive: $(-not $proc.HasExited)"
Write-Output "Pipe visible: $(Test-Path "\\.\pipe\$pn")"

try {
    $c = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pn, 'InOut')
    $c.Connect(3000)
    if ($c.IsConnected) {
        $r2 = New-Object System.IO.StreamReader($c)
        $line = $r2.ReadLine()
        $c.Dispose()
        Write-Output "PipeSecurity connect: SUCCESS (got: $line)"
    }
} catch {
    Write-Output "PipeSecurity connect: FAILED - $_"
} finally {
    try { if (-not $proc.HasExited) { $proc.Kill() } } catch {}
}

# Now test with Everyone SID
Write-Output ""
Write-Output "--- Test with Everyone (S-1-1-0) SID ---"
$pn2 = 'PipeSecTest2_' + (Get-Random -Max 9999)

$serverScript2 = @"
`$sec=New-Object System.IO.Pipes.PipeSecurity
`$sid=New-Object System.Security.Principal.SecurityIdentifier 'S-1-1-0'
`$ar=New-Object System.IO.Pipes.PipeAccessRule(`$sid,'FullControl','Allow')
`$sec.AddAccessRule(`$ar)
`$p=New-Object System.IO.Pipes.NamedPipeServerStream('$pn2','InOut',1,'Byte','None',4096,4096,`$sec)
`$p.WaitForConnection()
`$r=New-Object System.IO.StreamReader(`$p)
`$w=New-Object System.IO.StreamWriter(`$p)
`$w.WriteLine('ok2')
`$w.Flush()
`$p.Dispose()
"@

$enc2 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($serverScript2))
$proc2 = Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-ep','Bypass','-NoProfile','-enc',$enc2 -PassThru
Start-Sleep -Milliseconds 800

Write-Output "Server PID: $($proc2.Id), alive: $(-not $proc2.HasExited)"
Write-Output "Pipe visible: $(Test-Path "\\.\pipe\$pn2")"

try {
    $c2 = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pn2, 'InOut')
    $c2.Connect(3000)
    if ($c2.IsConnected) {
        $r3 = New-Object System.IO.StreamReader($c2)
        $line2 = $r3.ReadLine()
        $c2.Dispose()
        Write-Output "Everyone-SID connect: SUCCESS (got: $line2)"
    }
} catch {
    Write-Output "Everyone-SID connect: FAILED - $_"
} finally {
    try { if (-not $proc2.HasExited) { $proc2.Kill() } } catch {}
}
