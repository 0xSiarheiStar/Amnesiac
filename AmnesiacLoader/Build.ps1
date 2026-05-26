# AmnesiacLoader Build Script — uses csc.exe (no dotnet SDK required)
# Usage: cd AmnesiacLoader; .\Build.ps1
param(
    [string]$AmnesiacPath = "..\Amnesiac.ps1"
)
$ErrorActionPreference = "Stop"

$csc    = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$binDir = Join-Path $PSScriptRoot "bin"
if (-not (Test-Path $binDir)) { New-Item -Path $binDir -ItemType Directory | Out-Null }

$outDll = Join-Path $binDir "AmnesiacLoader.dll"
$refs   = @("/r:System.dll", "/r:System.Core.dll")
$sources = @("Loader.cs","Bypass.cs","CallStack.cs","SleepMask.cs","Stomper.cs","UnmanagedPS.cs","NativeLoader.cs") |
           ForEach-Object { Join-Path $PSScriptRoot $_ }

Write-Host "[*] Building AmnesiacLoader with csc.exe..." -ForegroundColor Cyan

$cscArgs = @("/target:library", "/out:$outDll", "/unsafe", "/optimize+", "/debug-") + $refs + $sources
$result  = & $csc @cscArgs 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Host "[-] Build failed:" -ForegroundColor Red
    $result | ForEach-Object { Write-Host $_ }
    exit 1
}

$bytes  = [System.IO.File]::ReadAllBytes($outDll)
$b64    = [Convert]::ToBase64String($bytes)
$sha256 = (Get-FileHash $outDll -Algorithm SHA256).Hash

Write-Host "[+] Built: $outDll  ($($bytes.Length) bytes)" -ForegroundColor Green
Write-Host "[+] SHA256: $sha256" -ForegroundColor Green
Write-Host "[+] Base64 length: $($b64.Length) chars" -ForegroundColor Green

$content = [System.IO.File]::ReadAllText($AmnesiacPath, [System.Text.Encoding]::UTF8)
$pattern = '\$AmnesiacLoaderB64\s*=\s*"[^"]*"'
if ($content -match $pattern) {
    $updated = [System.Text.RegularExpressions.Regex]::Replace($content, $pattern, "`$AmnesiacLoaderB64 = `"$b64`"")
    # Preserve UTF-8 with BOM so PowerShell reads special characters correctly
    $utf8Bom = New-Object System.Text.UTF8Encoding $true
    [System.IO.File]::WriteAllText($AmnesiacPath, $updated, $utf8Bom)
    Write-Host "[+] Updated `$AmnesiacLoaderB64 in $AmnesiacPath" -ForegroundColor Green
} else {
    Write-Host "[!] `$AmnesiacLoaderB64 not found in $AmnesiacPath" -ForegroundColor Yellow
    Write-Host "    Add: `$AmnesiacLoaderB64 = `"`"  near the top of Amnesiac.ps1, then re-run." -ForegroundColor Yellow
}
Write-Host "[+] Done." -ForegroundColor Green
