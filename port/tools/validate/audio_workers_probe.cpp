// audio_workers_probe.cpp - real Win32 thread lifecycle witness for NASM helpers.

#include <windows.h>

#include <cstdint>
#include <cstdio>

extern "C" uint32_t asm_audio_create_worker(
    HANDLE* slot, LPTHREAD_START_ROUTINE entry, void* argument);
extern "C" DWORD asm_audio_wait_worker(HANDLE handle, DWORD timeout);
extern "C" uint32_t asm_audio_close_worker(HANDLE* slot);

struct WorkerArgs {
    volatile LONG marker;
    DWORD delayMs;
};

static DWORD WINAPI worker(LPVOID raw) {
    auto* args = static_cast<WorkerArgs*>(raw);
    Sleep(args->delayMs);
    InterlockedExchange(&args->marker, 0x1234);
    return 7;
}

int main() {
    WorkerArgs args{0, 25};
    HANDLE handle = nullptr;
    if (asm_audio_create_worker(&handle, worker, &args) != 1 || !handle) {
        std::fprintf(stderr, "NASM CreateThread wrapper failed\n");
        return 1;
    }
    if (asm_audio_wait_worker(handle, 0) != WAIT_TIMEOUT) {
        std::fprintf(stderr, "expected a live worker before its delay\n");
        asm_audio_wait_worker(handle, INFINITE);
        asm_audio_close_worker(&handle);
        return 1;
    }
    if (asm_audio_wait_worker(handle, INFINITE) != WAIT_OBJECT_0 ||
        args.marker != 0x1234 || asm_audio_close_worker(&handle) != 1 ||
        handle != nullptr) {
        std::fprintf(stderr, "NASM worker wait/close contract failed\n");
        return 1;
    }
    if (asm_audio_close_worker(nullptr) != 1) {
        std::fprintf(stderr, "null worker slot cleanup failed\n");
        return 1;
    }
    return 0;
}
