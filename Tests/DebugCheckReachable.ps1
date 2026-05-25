Set-Location 'C:\users\localuser\Downloads\Amnesiac-main\Amnesiac-main'
. .\Amnesiac.ps1

Write-Output "Calling CheckReachableHosts..."
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $r = CheckReachableHosts
    $sw.Stop()
    $cnt = if ($r) { @($r).Count } else { 0 }
    Write-Output "Returned in $($sw.ElapsedMilliseconds)ms. Count: $cnt"
    if ($r) { @($r) | Select-Object -First 5 | ForEach-Object { Write-Output "  -> $_" } }
} catch {
    $sw.Stop()
    Write-Output "THREW after $($sw.ElapsedMilliseconds)ms"
    Write-Output "Error: $($_.Exception.GetType().Name): $($_.Exception.Message)"
}
