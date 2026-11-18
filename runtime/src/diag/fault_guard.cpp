// SPDX-License-Identifier: GPL-3.0-or-later
// nxrt/fault_guard.h: the one guarded call. No C++ object may live in this frame (SEH).
#include "nxrt/fault_guard.h"

#if defined(_MSC_VER)
#include <windows.h>   // SEH
#elif defined(_WIN32)
#include <csetjmp>
#include <windows.h>
#else
#include <windows.h>   // POSIX: the shim's windows.h, which declares nxos_guarded_call (src/os/nx_os.h)
#endif

namespace nxrt {

#if defined(_MSC_VER)
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
#elif defined(_WIN32)
namespace {
struct GuardState {
    bool active = false;
    FaultCatch what = FaultCatch::AccessViolation;
    std::jmp_buf env{};
};

thread_local GuardState g_guard;

LONG CALLBACK veh_handler(EXCEPTION_POINTERS* ep) {
    if (!g_guard.active) return EXCEPTION_CONTINUE_SEARCH;
    const DWORD code = ep->ExceptionRecord->ExceptionCode;
    // Let debug-print, thread-name, and C++ EH notifications pass through untouched.
    if (code == 0x40010006u || code == 0x4001000Au || code == 0x406D1388u ||
        code == 0xE06D7363u || code == 0x20474343u) {
        return EXCEPTION_CONTINUE_SEARCH;
    }
    if (g_guard.what == FaultCatch::Any || code == EXCEPTION_ACCESS_VIOLATION) {
        g_guard.active = false;
        std::longjmp(g_guard.env, 1);
    }
    return EXCEPTION_CONTINUE_SEARCH;
}

struct VehRegistrar {
    VehRegistrar() { AddVectoredExceptionHandler(1, veh_handler); }
} g_veh_registrar;
}  // namespace

bool fault_guarded_call(void (*fn)(void*), void* ctx, FaultCatch what) {
    GuardState prev = g_guard;
    g_guard.active = true;
    g_guard.what = what;
    if (setjmp(g_guard.env) == 0) {
        fn(ctx);
        g_guard = prev;
        return true;
    }
    g_guard = prev;
    return false;
}
#else
bool fault_guarded_call(void (*fn)(void*), void* ctx, FaultCatch) {
    return nxos_guarded_call(fn, ctx) != 0;   // a SIGSEGV/SIGBUS inside fn lands back here
}
#endif

}  // namespace nxrt
