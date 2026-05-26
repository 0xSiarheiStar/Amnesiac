#pragma once
#include <Windows.h>

// ---------------------------------------------------------------------------
// Bypass target descriptor
// ---------------------------------------------------------------------------
struct BypassTarget
{
    PVOID     addr;           // адрес функции
    ULONG_PTR retVal;         // значение RAX при раннем возврате
    int       outArgIdx;      // индекс в стеке для output-параметра (-1 = нет)
    ULONG_PTR outArgVal;      // значение, которое пишем в *stack[outArgIdx]
    int       outArgSize;     // размер записи: 4 = DWORD, 8 = ULONG_PTR (default 4)
};

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------
static constexpr int kMaxTargets = 8;

static BypassTarget           g_Targets[kMaxTargets] = {};
static int                    g_TargetCount = 0;
static PVOID                  g_VehHandle   = nullptr;
static thread_local bool      g_StepPending = false;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
static inline PVOID PageOf(PVOID addr)
{
    return reinterpret_cast<PVOID>(
        reinterpret_cast<ULONG_PTR>(addr) & ~static_cast<ULONG_PTR>(0xFFF));
}

static void ReprotectAll()
{
    for (int i = 0; i < g_TargetCount; ++i)
    {
        bool duplicate = false;
        for (int j = 0; j < i; ++j)
        {
            if (PageOf(g_Targets[j].addr) == PageOf(g_Targets[i].addr))
            {
                duplicate = true;
                break;
            }
        }
        if (!duplicate)
        {
            DWORD old = 0;
            VirtualProtect(g_Targets[i].addr, 1, PAGE_EXECUTE_READ | PAGE_GUARD, &old);
        }
    }
}

// ---------------------------------------------------------------------------
// Vectored Exception Handler
// ---------------------------------------------------------------------------
static LONG NTAPI VehHandler(PEXCEPTION_POINTERS ei)
{
    const DWORD code = ei->ExceptionRecord->ExceptionCode;
    PCONTEXT    ctx  = ei->ContextRecord;

    if (code == STATUS_GUARD_PAGE_VIOLATION)
    {
        PVOID fault = ei->ExceptionRecord->ExceptionAddress;

        for (int i = 0; i < g_TargetCount; ++i)
        {
            if (fault != g_Targets[i].addr)
                continue;

            const BypassTarget& t = g_Targets[i];
            auto* stack = reinterpret_cast<ULONG_PTR*>(ctx->Rsp);

            if (t.outArgIdx >= 0)
            {
                PVOID outPtr = reinterpret_cast<PVOID>(stack[t.outArgIdx]);
                if (outPtr)
                {
                    if (t.outArgSize <= 4)
                        *reinterpret_cast<DWORD*>(outPtr) = static_cast<DWORD>(t.outArgVal);
                    else
                        *reinterpret_cast<ULONG_PTR*>(outPtr) = t.outArgVal;
                }
            }

            ctx->Rip  = stack[0];
            ctx->Rsp += sizeof(ULONG_PTR);
            ctx->Rax  = t.retVal;

            ctx->EFlags |= 0x100; // TF
            g_StepPending = true;
            return EXCEPTION_CONTINUE_EXECUTION;
        }

        // Non-target function on guarded page — let it run, re-guard after one step
        ctx->EFlags |= 0x100;
        g_StepPending = true;
        return EXCEPTION_CONTINUE_EXECUTION;
    }

    if (code == STATUS_SINGLE_STEP && g_StepPending)
    {
        g_StepPending = false;
        ReprotectAll();
        return EXCEPTION_CONTINUE_EXECUTION;
    }

    return EXCEPTION_CONTINUE_SEARCH;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------
static BOOL AddBypassTarget(PVOID addr, ULONG_PTR retVal,
                             int outArgIdx = -1, ULONG_PTR outArgVal = 0,
                             int outArgSize = 4)
{
    if (g_TargetCount >= kMaxTargets)
        return FALSE;

    g_Targets[g_TargetCount++] = { addr, retVal, outArgIdx, outArgVal, outArgSize };
    return TRUE;
}

static BOOL InstallBypass()
{
    if (g_TargetCount == 0)
        return FALSE;

    g_VehHandle = AddVectoredExceptionHandler(1, VehHandler);
    if (!g_VehHandle)
        return FALSE;

    ReprotectAll();
    return TRUE;
}

static void UninstallBypass()
{
    if (!g_VehHandle) return;

    for (int i = 0; i < g_TargetCount; ++i)
    {
        DWORD old = 0;
        VirtualProtect(g_Targets[i].addr, 1, PAGE_EXECUTE_READ, &old);
    }

    RemoveVectoredExceptionHandler(g_VehHandle);
    g_VehHandle   = nullptr;
    g_TargetCount = 0;
}
