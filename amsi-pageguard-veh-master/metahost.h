// metahost.h — CLR hosting interfaces (minimal shim for Windows SDK 10.0.26100+)
// GUIDs and vtable layout match the published Windows SDK specification exactly.
#pragma once
#include <unknwn.h>
#include "mscoree.h"

// ── Callback typedefs for ICLRMetaHost::RequestRuntimeLoadedNotification ──
typedef HRESULT (__stdcall *CallbackThreadSetFn)();
typedef HRESULT (__stdcall *CallbackThreadUnsetFn)();
struct ICLRRuntimeInfo;
typedef void (__stdcall *RuntimeLoadedCallbackFnPtr)(
    ICLRRuntimeInfo            *pRuntimeInfo,
    CallbackThreadSetFn         pfnCallbackThreadSet,
    CallbackThreadUnsetFn       pfnCallbackThreadUnset);

// ── ICLRRuntimeInfo ────────────────────────────────────────────────────────
MIDL_INTERFACE("BD39D1D2-BA2F-486a-89B0-B4B0CB466891")
ICLRRuntimeInfo : public IUnknown
{
    virtual HRESULT STDMETHODCALLTYPE GetVersionString(
        LPWSTR pwzBuffer, DWORD *pcchBuffer) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetRuntimeDirectory(
        LPWSTR pwzBuffer, DWORD *pcchBuffer) = 0;
    virtual HRESULT STDMETHODCALLTYPE IsLoaded(
        HANDLE hndProcess, BOOL *pbLoaded) = 0;
    virtual HRESULT STDMETHODCALLTYPE LoadErrorString(
        UINT iResourceID, LPWSTR pwzBuffer, DWORD *pcchBuffer, LONG iLocaleID) = 0;
    virtual HRESULT STDMETHODCALLTYPE LoadLibrary(
        LPCWSTR pwzDllName, HMODULE *phndModule) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetProcAddress(
        LPCSTR pszProcName, LPVOID *ppProc) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetInterface(
        REFCLSID rclsid, REFIID riid, LPVOID *ppUnk) = 0;
    virtual HRESULT STDMETHODCALLTYPE IsLoadable(
        BOOL *pbLoadable) = 0;
    virtual HRESULT STDMETHODCALLTYPE SetDefaultStartupFlags(
        DWORD dwStartupFlags, LPCWSTR pwzHostConfigFile) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetDefaultStartupFlags(
        DWORD *pdwStartupFlags, LPWSTR pwzHostConfigFile, DWORD *pcchHostConfigFile) = 0;
    virtual HRESULT STDMETHODCALLTYPE BindAsLegacyV2Runtime() = 0;
    virtual HRESULT STDMETHODCALLTYPE IsStarted(
        BOOL *pbStarted, DWORD *pdwStartupFlags) = 0;
};

// ── ICLRMetaHost ───────────────────────────────────────────────────────────
MIDL_INTERFACE("D332DB9E-B9B3-4125-8207-A14884F53216")
ICLRMetaHost : public IUnknown
{
    virtual HRESULT STDMETHODCALLTYPE GetRuntime(
        LPCWSTR pwzVersion, REFIID riid, LPVOID *ppRuntime) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetVersionFromFile(
        LPCWSTR pwzFilePath, LPWSTR pwzBuffer, DWORD *pcchBuffer) = 0;
    virtual HRESULT STDMETHODCALLTYPE EnumerateInstalledRuntimes(
        IEnumUnknown **ppEnumerator) = 0;
    virtual HRESULT STDMETHODCALLTYPE EnumerateLoadedRuntimes(
        HANDLE hndProcess, IEnumUnknown **ppEnumerator) = 0;
    virtual HRESULT STDMETHODCALLTYPE RequestRuntimeLoadedNotification(
        RuntimeLoadedCallbackFnPtr pCallbackFunction) = 0;
    virtual HRESULT STDMETHODCALLTYPE QueryLegacyV2RuntimeBinding(
        REFIID riid, LPVOID *ppUnknown) = 0;
    virtual HRESULT STDMETHODCALLTYPE ExitProcess(INT32 iExitCode) = 0;
};

// ── GUIDs ──────────────────────────────────────────────────────────────────
EXTERN_C const CLSID CLSID_CLRMetaHost;
EXTERN_C const IID   IID_ICLRMetaHost;
EXTERN_C const IID   IID_ICLRRuntimeInfo;

// ── CLRCreateInstance ──────────────────────────────────────────────────────
STDAPI CLRCreateInstance(REFCLSID clsid, REFIID riid, LPVOID *ppInterface);
