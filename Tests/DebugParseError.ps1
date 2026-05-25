$path = 'C:\users\localuser\Downloads\Amnesiac-main\Amnesiac-main\Amnesiac.ps1'
$errs = $null; $toks = $null
[System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$toks, [ref]$errs) | Out-Null
$e = $errs[0]
Write-Output ("First error: L" + $e.Extent.StartLineNumber + " C" + $e.Extent.StartColumnNumber + ": " + $e.Message)
Write-Output ("ErrorId: " + $e.ErrorId)
Write-Output ("Token text: '" + $e.Extent.Text + "'")

$lines = [System.IO.File]::ReadAllLines($path)
$lineIdx = $e.Extent.StartLineNumber - 1
Write-Output ("--- File bytes around error line ---")
for ($i = [Math]::Max(0, $lineIdx-5); $i -le [Math]::Min($lines.Length-1, $lineIdx+2); $i++) {
    $marker = if ($i -eq $lineIdx) { '>>>' } else { '   ' }
    $lineBytes = [System.Text.Encoding]::UTF8.GetBytes($lines[$i])
    $hexSnippet = ($lineBytes | Select-Object -First 20 | ForEach-Object { $_.ToString('X2') }) -join ' '
    Write-Output ($marker + " L" + ($i+1) + " [" + $lines[$i].Length + "]: '" + ($lines[$i].Substring(0, [Math]::Min(80, $lines[$i].Length))) + "'")
    Write-Output ("    Hex(first20): " + $hexSnippet)
}

# Also test: does ParseFile on a TEMP COPY with BOM differ?
Write-Output ""
Write-Output "--- Testing BOM variant ---"
$content = [System.IO.File]::ReadAllText($path)
$tmpPath = [System.IO.Path]::GetTempFileName() + ".ps1"
[System.IO.File]::WriteAllText($tmpPath, $content, [System.Text.Encoding]::UTF8)  # UTF-8 WITH BOM
$errs2 = $null; $toks2 = $null
[System.Management.Automation.Language.Parser]::ParseFile($tmpPath, [ref]$toks2, [ref]$errs2) | Out-Null
Write-Output ("ParseFile BOM copy errors: " + $errs2.Count)
Remove-Item $tmpPath -Force

# Also: what's the file encoding (first bytes)?
$rawBytes = [System.IO.File]::ReadAllBytes($path)
$firstBytes = ($rawBytes | Select-Object -First 5 | ForEach-Object { $_.ToString('X2') }) -join ' '
Write-Output ("File first 5 bytes: " + $firstBytes)
Write-Output ("File size: " + $rawBytes.Length + " bytes")
