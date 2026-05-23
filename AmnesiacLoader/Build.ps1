# AmnesiacLoader Build Script
# Compiles AmnesiacLoader.dll, base64-encodes it, and updates
# the $AmnesiacLoaderB64 constant in Amnesiac.ps1.
#
# Requirements: .NET SDK 6.0+ installed
# Usage: cd AmnesiacLoader; .\Build.ps1

param(
    [string]$AmnesiacPath = "..\Amnesiac.ps1"
)

$ErrorActionPreference = "Stop"

Write-Host "[*] Building AmnesiacLoader..." -ForegroundColor Cyan

# Build in Release mode
$buildResult = dotnet build AmnesiacLoader.csproj -c Release --nologo 2>&1
if($LASTEXITCODE -ne 0){
    Write-Host "[-] Build failed:" -ForegroundColor Red
    Write-Host $buildResult
    exit 1
}

# Locate output DLL
$dllPath = Get-ChildItem -Path "bin\Release\net462\" -Filter "AmnesiacLoader.dll" -Recurse | Select-Object -First 1 -ExpandProperty FullName
if(-not $dllPath){
    Write-Host "[-] Could not find AmnesiacLoader.dll in build output" -ForegroundColor Red
    exit 1
}

# Base64 encode
$bytes  = [System.IO.File]::ReadAllBytes($dllPath)
$b64    = [Convert]::ToBase64String($bytes)
$sha256 = (Get-FileHash $dllPath -Algorithm SHA256).Hash

Write-Host "[+] Built: $dllPath" -ForegroundColor Green
Write-Host "[+] Size:  $($bytes.Length) bytes" -ForegroundColor Green
Write-Host "[+] SHA256: $sha256" -ForegroundColor Green
Write-Host "[+] Base64 length: $($b64.Length) chars" -ForegroundColor Green

# Update Amnesiac.ps1
$amnesiacContent = Get-Content $AmnesiacPath -Raw

$pattern     = '\$AmnesiacLoaderB64\s*=\s*"[^"]*"'
$replacement = "`$AmnesiacLoaderB64 = `"$b64`""

if($amnesiacContent -match $pattern){
    $updated = $amnesiacContent -replace $pattern, $replacement
    Set-Content -Path $AmnesiacPath -Value $updated -NoNewline
    Write-Host "[+] Updated `$AmnesiacLoaderB64 in $AmnesiacPath" -ForegroundColor Green
} else {
    Write-Host "[!] Could not find `$AmnesiacLoaderB64 placeholder in $AmnesiacPath" -ForegroundColor Yellow
    Write-Host "    Add the following line near the top of Amnesiac.ps1:" -ForegroundColor Yellow
    Write-Host "    `$AmnesiacLoaderB64 = `"$($b64.Substring(0,64))...`"" -ForegroundColor Yellow
}

Write-Host ""
Write-Host "[+] Build complete. SHA256: $sha256" -ForegroundColor Green
