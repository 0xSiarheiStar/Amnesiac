// mscoree.h — ICorRuntimeHost shim for Windows SDK 10.0.26100+ (dropped CLR hosting headers)
// GUIDs and vtable layout match the published Windows SDK specification exactly.
#pragma once
#include <unknwn.h>
#include <oleauto.h>

// Forward declarations
struct ICorConfiguration;
typedef PVOID HDOMAINENUM;

// ── ICorRuntimeHost ────────────────────────────────────────────────────────
// Vtable order must be exact: IUnknown (3) + 19 ICorRuntimeHost methods.
MIDL_INTERFACE("CB2F6723-AB3A-11d2-9C40-00C04FA30A3E")
ICorRuntimeHost : public IUnknown
{
    virtual HRESULT STDMETHODCALLTYPE CreateLogicalThreadState() = 0;
    virtual HRESULT STDMETHODCALLTYPE DeleteLogicalThreadState() = 0;
    virtual HRESULT STDMETHODCALLTYPE SwitchInLogicalThreadState(
        DWORD *pFiberCookie) = 0;
    virtual HRESULT STDMETHODCALLTYPE SwitchOutLogicalThreadState(
        DWORD **pFiberCookie) = 0;
    virtual HRESULT STDMETHODCALLTYPE LocksHeldByLogicalThread(
        DWORD *pCount) = 0;
    virtual HRESULT STDMETHODCALLTYPE MapFile(
        HANDLE hFile, HMODULE *hMapAddress) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetConfiguration(
        ICorConfiguration **pConfiguration) = 0;
    virtual HRESULT STDMETHODCALLTYPE Start() = 0;
    virtual HRESULT STDMETHODCALLTYPE Stop() = 0;
    virtual HRESULT STDMETHODCALLTYPE CreateDomain(
        LPCWSTR pwzFriendlyName, IUnknown *pIdentityArray,
        IUnknown **pAppDomain) = 0;
    virtual HRESULT STDMETHODCALLTYPE GetDefaultDomain(
        IUnknown **pAppDomain) = 0;
    virtual HRESULT STDMETHODCALLTYPE EnumDomains(
        HDOMAINENUM *hEnum) = 0;
    virtual HRESULT STDMETHODCALLTYPE NextDomain(
        HDOMAINENUM hEnum, IUnknown **pAppDomain) = 0;
    virtual HRESULT STDMETHODCALLTYPE CloseEnum(
        HDOMAINENUM hEnum) = 0;
    virtual HRESULT STDMETHODCALLTYPE CreateDomainEx(
        LPCWSTR pwzFriendlyName, IUnknown *pSetup,
        IUnknown *pEvidence, IUnknown **pAppDomain) = 0;
    virtual HRESULT STDMETHODCALLTYPE CreateDomainSetup(
        IUnknown **pAppDomainSetup) = 0;
    virtual HRESULT STDMETHODCALLTYPE CreateEvidence(
        IUnknown **pEvidence) = 0;
    virtual HRESULT STDMETHODCALLTYPE UnloadDomain(
        IUnknown *pAppDomain) = 0;
    virtual HRESULT STDMETHODCALLTYPE CurrentDomain(
        IUnknown **pAppDomain) = 0;
};

// ── GUIDs ──────────────────────────────────────────────────────────────────
EXTERN_C const CLSID CLSID_CorRuntimeHost;
EXTERN_C const IID   IID_ICorRuntimeHost;
