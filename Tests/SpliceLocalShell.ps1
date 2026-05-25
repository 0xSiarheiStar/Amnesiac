$mainPath = 'C:\users\localuser\Downloads\Amnesiac-main\Amnesiac-main\Amnesiac.ps1'
$newPath  = 'C:\users\localuser\Downloads\Amnesiac-main\Amnesiac-main\Tests\NewLocalShell.ps1'

$mainLines = [System.IO.File]::ReadAllLines($mainPath, [System.Text.Encoding]::UTF8)
$newLines  = [System.IO.File]::ReadAllLines($newPath,  [System.Text.Encoding]::UTF8)

# Find Start-LocalShell boundaries
$startIdx = -1; $endIdx = -1
for ($i = 0; $i -lt $mainLines.Length; $i++) {
    if ($mainLines[$i] -match '^function Start-LocalShell') { $startIdx = $i }
    elseif ($startIdx -ge 0 -and $mainLines[$i] -match '^function ') { $endIdx = $i - 1; break }
}
if ($startIdx -lt 0 -or $endIdx -lt 0) { Write-Output 'ERROR: could not find function boundaries'; exit 1 }
Write-Output "Replacing lines $($startIdx+1)-$($endIdx+1) ($($endIdx-$startIdx+1) lines) with $($newLines.Length) lines from NewLocalShell.ps1"

$output = $mainLines[0..($startIdx-1)] + $newLines + $mainLines[($endIdx+1)..($mainLines.Length-1)]
[System.IO.File]::WriteAllText($mainPath, ($output -join "`r`n") + "`r`n", [System.Text.Encoding]::UTF8)
$bom = ([System.IO.File]::ReadAllBytes($mainPath)[0..2] | ForEach-Object { $_.ToString('X2') }) -join ' '
Write-Output "Done. Lines: $($output.Length)  BOM: $bom"

# Verify
$errs = $null; $toks = $null
[System.Management.Automation.Language.Parser]::ParseFile($mainPath, [ref]$toks, [ref]$errs) | Out-Null
Write-Output "ParseFile errors: $($errs.Count)"
