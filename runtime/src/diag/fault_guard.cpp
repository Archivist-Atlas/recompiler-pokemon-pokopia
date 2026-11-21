// SPDX-License-Identifier: GPL-3.0-or-later
// nxrt/fault_guard.h: the one guarded call. No C++ object may live in this frame (SEH).
#include "nxrt/fault_guard.h"

#include <windows.h>   // POSIX: the shim's windows.h, which declares nxos_guarded_call (src/os/nx_os.h)
#if defined(__MINGW32__)
#include <csetjmp>
#endif

namespace nxrt {

#if defined(_WIN32) && !defined(__MINGW32__)
namespace {
int filter(unsigned long code, FaultCatch what) {
    if (what == FaultCatch::Any || code == EXCEPTION_ACCESS_VIOLATION) return EXCEPTION_EXECUTE_HANDLER;
    return EXCEPTION_CONTINUE_SEARCH;
}
}  // namespace

bool fault_guarded_call(void (*fn)(void*), void* ctx, FaultCatch what) {
    __try {
        fn(ctx);
        return true;
    } __except (filter(GetExceptionCode(), what)) {
        return false;
    }
}
#elif defined(__MINGW32__)
namespace {
struct GuardState {
    jmp_buf env;
    FaultCatch what;
    bool active;
};
thread_local GuardState* tl_guard = nullptr;

LONG CALLBACK veh_handler(PEXCEPTION_POINTERS ep) {
    GuardState* g = tl_guard;
    if (!g || !g->active || !ep || !ep->ExceptionRecord) return EXCEPTION_CONTINUE_SEARCH;
    const DWORD code = ep->ExceptionRecord->ExceptionCode;
    if (g->what == FaultCatch::Any || code == EXCEPTION_ACCESS_VIOLATION) {
        g->active = false;
        longjmp(g->env, 1);
    }
    return EXCEPTION_CONTINUE_SEARCH;
}
}  // namespace

bool fault_guarded_call(void (*fn)(void*), void* ctx, FaultCatch what) {
    GuardState state{};
    state.what = what;
    state.active = true;
    GuardState* prev = tl_guard;
    tl_guard = &state;
    PVOID h = AddVectoredExceptionHandler(1, veh_handler);
    bool ok = true;
    if (setjmp(state.env) == 0) {
        fn(ctx);
    } else {
        ok = false;
    }
    state.active = false;
    if (h) RemoveVectoredExceptionHandler(h);
    tl_guard = prev;
    return ok;
}
#else
bool fault_guarded_call(void (*fn)(void*), void* ctx, FaultCatch) {
    return nxos_guarded_call(fn, ctx) != 0;   // a SIGSEGV/SIGBUS inside fn lands back here
}
#endif

}  // namespace nxrt
