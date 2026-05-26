@echo off
:: Сборка через MSVC (x64) — автоматически находит Visual Studio

:: Найти vcvars64.bat через vswhere
set VSWHERE="%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"

if not exist %VSWHERE% (
    echo [-] vswhere.exe not found. Visual Studio не установлена?
    pause & exit /b 1
)

for /f "usebackq tokens=*" %%i in (
    `%VSWHERE% -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`
) do set VS_PATH=%%i

if "%VS_PATH%"=="" (
    echo [-] Visual Studio с C++ компонентами не найдена
    pause & exit /b 1
)

set VCVARS="%VS_PATH%\VC\Auxiliary\Build\vcvars64.bat"
if not exist %VCVARS% (
    echo [-] vcvars64.bat не найден: %VCVARS%
    pause & exit /b 1
)

echo [*] Инициализация окружения MSVC x64...
call %VCVARS% >nul 2>&1

echo [*] Building EXE...
cl /nologo /O2 /MT /W3 ^
   /Fe:amsi_bypass_test.exe ^
   main.cpp ^
   /link /SUBSYSTEM:CONSOLE advapi32.lib ole32.lib oleaut32.lib crypt32.lib mscoree.lib

if %ERRORLEVEL% == 0 (
    echo [+] OK: amsi_bypass_test.exe
) else (
    echo [-] EXE build failed
)

echo.
echo [*] Building DLL...
cl /nologo /O2 /MT /W3 /LD ^
   /Fe:amsi_bypass.dll ^
   dllmain.cpp ^
   /link /SUBSYSTEM:WINDOWS /DLL

if %ERRORLEVEL% == 0 (
    echo [+] OK: amsi_bypass.dll
) else (
    echo [-] DLL build failed
)

echo.
echo [*] Building AmnesiacBridge.dll (C# Runspace host)...
for /f "usebackq delims=" %%i in (
    `where /r %WINDIR%\Microsoft.NET\Framework64 csc.exe 2^>nul`
) do set CSC=%%i
if "%CSC%"=="" (
    echo [-] csc.exe not found — skipping AmnesiacBridge
    goto :skip_bridge
)
set SMA_DLL=
for /f "usebackq delims=" %%i in (
    `dir /s /b "%WINDIR%\assembly\GAC_MSIL\System.Management.Automation\*\System.Management.Automation.dll" 2^>nul`
) do set SMA_DLL=%%i
if "%SMA_DLL%"=="" (
    echo [-] System.Management.Automation.dll not found in GAC
    goto :skip_bridge
)
"%CSC%" /nologo /target:library /out:AmnesiacBridge.dll /platform:x64 ^
    /r:"%SMA_DLL%" ^
    AmnesiacBridge.cs
if %ERRORLEVEL% == 0 (
    echo [+] OK: AmnesiacBridge.dll
) else (
    echo [-] AmnesiacBridge build failed
)
:skip_bridge

echo.
echo [*] Building amnesiac_launcher.exe...
cl /nologo /O2 /MT /W3 /EHsc ^
   /Fe:amnesiac_launcher.exe ^
   launcher.cpp ^
   /link /SUBSYSTEM:CONSOLE ^
   advapi32.lib ole32.lib oleaut32.lib winhttp.lib mscoree.lib

if %ERRORLEVEL% == 0 (
    echo [+] OK: amnesiac_launcher.exe
) else (
    echo [-] Launcher build failed
)

del *.obj 2>nul
pause
