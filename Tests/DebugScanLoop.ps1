Set-Location 'C:\users\localuser\Downloads\Amnesiac-main\Amnesiac-main'
. .\Amnesiac.ps1

$global:MultipleSessions    = [System.Collections.Generic.List[psobject]]::new()
$global:AllOurTargets       = @()
$global:AllUserDefinedTargets = $null
$global:Message             = $null
$global:EndMarker           = 'ENDMARK99'
$global:BufferSize          = 4096
$global:MultiPipeName       = 'TestPipeXYZ'

Write-Output "=== Test 1: Scan-WaitingTargets with no server, target=10.3.10.157 ==="
$global:AllUserDefinedTargets = @('10.3.10.157')
try {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Scan-WaitingTargets
    $sw.Stop()
    Write-Host "  [OK] Returned in $($sw.ElapsedMilliseconds)ms. Sessions: $($global:MultipleSessions.Count)" -ForegroundColor Green
} catch {
    Write-Host "  [EXCEPTION] $($_.Exception.GetType().Name): $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  At: $($_.InvocationInfo.PositionMessage)" -ForegroundColor Red
}

Write-Output ""
Write-Output "=== Test 2: Scan-WaitingTargets with no server, target=. (localhost) ==="
$global:AllUserDefinedTargets = @('.')
try {
    $sw2 = [System.Diagnostics.Stopwatch]::StartNew()
    Scan-WaitingTargets
    $sw2.Stop()
    Write-Host "  [OK] Returned in $($sw2.ElapsedMilliseconds)ms. Sessions: $($global:MultipleSessions.Count)" -ForegroundColor Green
} catch {
    Write-Host "  [EXCEPTION] $($_.Exception.GetType().Name): $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  At: $($_.InvocationInfo.PositionMessage)" -ForegroundColor Red
}

Write-Output ""
Write-Output "=== Test 3: KeyAvailable in while loop (simulates scan loop) ==="
try {
    $iterations = 0
    while ($true) {
        $iterations++
        if ($Host.UI.RawUI.KeyAvailable) {
            $k = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
            Write-Output "  Key: char=$([int]$k.Character) vk=$($k.VirtualKeyCode)"
            if ($k.Character -in 'q','Q') { break }
        }
        if ($iterations -ge 3) { break }
        Start-Sleep -Milliseconds 100
    }
    Write-Host "  [OK] KeyAvailable loop ran $iterations iterations" -ForegroundColor Green
} catch {
    Write-Host "  [EXCEPTION] $($_.Exception.GetType().Name): $($_.Exception.Message)" -ForegroundColor Red
}

Write-Output ""
Write-Output "Done."
