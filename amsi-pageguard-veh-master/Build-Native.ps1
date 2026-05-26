# Build-Native.ps1 -- compile native patchless AMSI+ETW bypass binaries
# Run from within amsi-pageguard-veh-master directory.
# Requires VS Build Tools 2022 with C++ workload.
#
# Outputs:
#   amsi_bypass.dll         -- injectable bypass DLL (no CLR dependency)
#   amsi_bypass_test.exe    -- standalone test EXE (reflective .NET loader)
#   amnesiac_launcher.exe   -- full launcher: downloads + runs Amnesiac via PS Runspace
#   AmnesiacBridge.dll      -- C# Runspace host loaded by amnesiac_launcher.exe

$srcDir  = "C:\users\localuser\Downloads\Amnesiac-main\Amnesiac-main\amsi-pageguard-veh-master"
$cl      = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\14.44.35207\bin\Hostx64\x64\cl.exe"
$csc     = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\MSBuild\Current\Bin\Roslyn\csc.exe"
$vcInc   = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\14.44.35207\include"
$vcLib   = "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\14.44.35207\lib\x64"
$sdkInc  = "C:\Program Files (x86)\Windows Kits\10\Include\10.0.26100.0"
$sdkLib  = "C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\um\x64"
$ucrtLib = "C:\Program Files (x86)\Windows Kits\10\Lib\10.0.26100.0\ucrt\x64"
$sma     = "C:\Windows\WinSxS\msil_system.management.automation_31bf3856ad364e35_10.0.19041.6456_none_39f5a7dedd36ad7a\System.Management.Automation.dll"

# Set compiler search paths via env vars
$env:LIB     = "$vcLib;$sdkLib;$ucrtLib;$srcDir"
$env:INCLUDE = "$vcInc;$sdkInc\um;$sdkInc\shared;$sdkInc\ucrt"

Set-Location $srcDir

$ok = $true

Write-Host "[*] Building amsi_bypass.dll..."
& $cl /nologo /O2 /MT /W3 /LD /I $srcDir /Fe:amsi_bypass.dll dllmain.cpp `
    /link /SUBSYSTEM:WINDOWS /DLL
if ($LASTEXITCODE -ne 0) { Write-Host "[-] FAILED"; $ok = $false } else { Write-Host "[+] OK" }

Write-Host "[*] Building amsi_bypass_test.exe..."
& $cl /nologo /O2 /MT /W3 /EHsc /I $srcDir /Fe:amsi_bypass_test.exe main.cpp guids.cpp `
    /link /SUBSYSTEM:CONSOLE advapi32.lib ole32.lib oleaut32.lib crypt32.lib mscoree.lib
if ($LASTEXITCODE -ne 0) { Write-Host "[-] FAILED"; $ok = $false } else { Write-Host "[+] OK" }

Write-Host "[*] Building amnesiac_launcher.exe..."
& $cl /nologo /O2 /MT /W3 /EHsc /I $srcDir /Fe:amnesiac_launcher.exe launcher.cpp guids.cpp `
    /link /SUBSYSTEM:CONSOLE advapi32.lib ole32.lib oleaut32.lib winhttp.lib mscoree.lib
if ($LASTEXITCODE -ne 0) { Write-Host "[-] FAILED"; $ok = $false } else { Write-Host "[+] OK" }

Write-Host "[*] Building AmnesiacBridge.dll..."
& $csc /nologo /target:library /out:AmnesiacBridge.dll /platform:x64 /langversion:7.3 /r:"$sma" AmnesiacBridge.cs
if ($LASTEXITCODE -ne 0) { Write-Host "[-] FAILED"; $ok = $false } else { Write-Host "[+] OK" }

Remove-Item *.obj, *.exp, *.tlh, *.tli -ErrorAction SilentlyContinue

if ($ok) { Write-Host "`n[+] All targets built." } else { Write-Host "`n[-] Some targets failed." }