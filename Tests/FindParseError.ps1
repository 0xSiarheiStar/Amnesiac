$path = 'C:\users\localuser\Downloads\Amnesiac-main\Amnesiac-main\Amnesiac.ps1'

# Test 1: ParseFile (may trigger AMSI file scanner)
$errs1 = $null; $toks1 = $null
[System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$toks1, [ref]$errs1) | Out-Null
Write-Output ("ParseFile errors: " + $errs1.Count)
if ($errs1.Count -gt 0) {
    $e = $errs1[0]; Write-Output ("  First: L" + $e.Extent.StartLineNumber + "C" + $e.Extent.StartColumnNumber + ": " + $e.Message)
}

# Test 2: ParseInput with same content (AMSI string scanner - may differ)
$content = [System.IO.File]::ReadAllText($path)
$errs2 = $null; $toks2 = $null
[System.Management.Automation.Language.Parser]::ParseInput($content, [ref]$toks2, [ref]$errs2) | Out-Null
Write-Output ("ParseInput errors: " + $errs2.Count)
if ($errs2.Count -gt 0) {
    $e = $errs2[0]; Write-Output ("  First: L" + $e.Extent.StartLineNumber + "C" + $e.Extent.StartColumnNumber + ": " + $e.Message)
}
