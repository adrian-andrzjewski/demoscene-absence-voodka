; audio_thread_probe.asm - assembly-owned WASAPI render-thread harness.
;
; This gate deliberately writes silence. It proves the hardest platform
; lifetime boundary first: the worker initializes its own COM apartment,
; owns the WASAPI interfaces and event, services repeated render wakeups,
; observes a process stop event, and tears everything down before joining.
; The proven native PCM mixer is connected only after this substrate passes.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

%define CLSCTX_ALL                         0x17
%define COINIT_MULTITHREADED               0x0
%define ERENDER                            0
%define ECONSOLE                           0
%define AUDCLNT_STREAMFLAGS_EVENTCALLBACK  0x40000
%define AUDCLNT_BUFFERFLAGS_SILENT         0x2
%define WASAPI_BUFFER_100NS                600000
%define THREAD_WAIT_TIMEOUT_MS             1000
%define THREAD_MAX_FRAMES                  256
%define WAIT_OBJECT_0                      0
%define WAIT_TIMEOUT                       0x102
%define THREAD_PRIORITY_ABOVE_NORMAL       1

%define IMM_ENUM_GET_DEFAULT_ENDPOINT      4
%define IMM_DEVICE_ACTIVATE               3
%define IAudioClient_INITIALIZE            3
%define IAudioClient_GET_BUFFER_SIZE       4
%define IAudioClient_GET_CURRENT_PADDING   6
%define IAudioClient_IS_FORMAT_SUPPORTED  7
%define IAudioClient_START                10
%define IAudioClient_STOP                 11
%define IAudioClient_RESET                12
%define IAudioClient_SET_EVENT_HANDLE     13
%define IAudioClient_GET_SERVICE          14
%define IAudioRenderClient_GET_BUFFER      3
%define IAudioRenderClient_RELEASE_BUFFER  4
%define IUNKNOWN_RELEASE                  2

; AudioThreadAsmProbeReport: twenty-five uint32_t fields.
%define REPORT_THREAD_CREATED             0
%define REPORT_THREAD_PRIORITY            4
%define REPORT_THREAD_WAIT                8
%define REPORT_COM_HR                    12
%define REPORT_ENUM_HR                   16
%define REPORT_ENDPOINT_HR               20
%define REPORT_ACTIVATE_HR               24
%define REPORT_FORMAT_HR                 28
%define REPORT_INIT_HR                   32
%define REPORT_BUFFER_SIZE               36
%define REPORT_EVENT_CREATED             40
%define REPORT_SET_EVENT_HR              44
%define REPORT_SERVICE_HR                48
%define REPORT_START_HR                  52
%define REPORT_FIRST_WAIT                56
%define REPORT_PADDING_HR                60
%define REPORT_PADDING_FRAMES            64
%define REPORT_GET_BUFFER_HR             68
%define REPORT_RELEASE_HR                72
%define REPORT_STOP_HR                   76
%define REPORT_RESET_HR                  80
%define REPORT_EVENT_WAKEUPS             84
%define REPORT_FRAMES                    88
%define REPORT_TIMEOUTS                  92
%define REPORT_WORKER_EXIT               96
%define REPORT_DURATION_MS              100
%define REPORT_BYTES                    104

extern CoInitializeEx
extern CoUninitialize
extern CoCreateInstance
extern CoTaskMemFree
extern CreateEventW
extern SetEvent
extern WaitForMultipleObjects
extern WaitForSingleObject
extern CloseHandle
extern CreateThread
extern SetThreadPriority
extern Sleep

global asm_audio_thread_probe

section .bss
align 8
thread_enumerator:       resq 1
thread_device:           resq 1
thread_client:           resq 1
thread_render:           resq 1
thread_stop_event:       resq 1
thread_audio_event:      resq 1
thread_handle:           resq 1
thread_closest_format:   resq 1
thread_buffer_data:      resq 1
thread_wait_handles:     resq 2
thread_started:          resd 1
thread_com_initialized:  resd 1
thread_first_wait_seen:  resd 1
thread_thread_id:        resd 1

section .data
align 4

; CLSID_MMDeviceEnumerator = BCDE0395-E52F-467C-8E3D-C4579291692E.
thread_clsid_mmdevice:   db 0x95,0x03,0xDE,0xBC, 0x2F,0xE5, 0x7C,0x46
                         db 0x8E,0x3D,0xC4,0x57,0x92,0x91,0x69,0x2E

; IID_IMMDeviceEnumerator = A95664D2-9614-4F35-A746-DE8DB63617E6.
thread_iid_mmdevice_enum: db 0xD2,0x64,0x56,0xA9, 0x14,0x96, 0x35,0x4F
                          db 0xA7,0x46,0xDE,0x8D,0xB6,0x36,0x17,0xE6

; IID_IAudioClient = 1CB9AD4C-DBFA-4C32-B178-C2F568A703B2.
thread_iid_audio_client: db 0x4C,0xAD,0xB9,0x1C, 0xFA,0xDB, 0x32,0x4C
                         db 0xB1,0x78,0xC2,0xF5,0x68,0xA7,0x03,0xB2

; IID_IAudioRenderClient = F294ACFC-3146-4483-A7BF-ADDCA7C260E2.
thread_iid_render_client: db 0xFC,0xAC,0x94,0xF2, 0x46,0x31, 0x83,0x44
                          db 0xA7,0xBF,0xAD,0xDC,0xA7,0xC2,0x60,0xE2

align 4
thread_pcm_format:
        dw 1                    ; WAVE_FORMAT_PCM
        dw 2                    ; stereo
        dd 44100
        dd 176400
        dw 4
        dw 16
        dw 0

section .text

; DWORD WINAPI audio_thread_probe_worker(LPVOID report).
audio_thread_probe_worker:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0x88

        mov     r12, rcx                    ; report pointer
        mov     r13d, 1                      ; worker failure until complete
        mov     dword [rel thread_started], 0
        mov     dword [rel thread_com_initialized], 0
        mov     dword [rel thread_first_wait_seen], 0

        ; Every COM call belongs to the worker's own MTA apartment.
        xor     ecx, ecx
        xor     edx, edx
        call    CoInitializeEx
        mov     dword [r12 + REPORT_COM_HR], eax
        test    eax, eax
        js      .worker_cleanup
        mov     dword [rel thread_com_initialized], 1

        ; Enumerate and activate the default render endpoint.
        lea     rcx, [rel thread_clsid_mmdevice]
        xor     edx, edx
        mov     r8d, CLSCTX_ALL
        lea     r9, [rel thread_iid_mmdevice_enum]
        lea     rax, [rel thread_enumerator]
        mov     [rsp + 0x20], rax
        call    CoCreateInstance
        mov     dword [r12 + REPORT_ENUM_HR], eax
        test    eax, eax
        js      .worker_cleanup

        mov     rcx, [rel thread_enumerator]
        xor     edx, edx                    ; eRender
        xor     r8d, r8d                    ; eConsole
        lea     r9, [rel thread_device]
        mov     rax, [rcx]
        call    qword [rax + IMM_ENUM_GET_DEFAULT_ENDPOINT * 8]
        mov     dword [r12 + REPORT_ENDPOINT_HR], eax
        test    eax, eax
        js      .worker_cleanup

        mov     rcx, [rel thread_device]
        lea     rdx, [rel thread_iid_audio_client]
        mov     r8d, CLSCTX_ALL
        xor     r9d, r9d
        lea     rax, [rel thread_client]
        mov     [rsp + 0x20], rax
        mov     rax, [rcx]
        call    qword [rax + IMM_DEVICE_ACTIVATE * 8]
        mov     dword [r12 + REPORT_ACTIVATE_HR], eax
        test    eax, eax
        js      .worker_cleanup

        ; Require the same exact PCM contract as the offline mixer gate.
        mov     qword [rel thread_closest_format], 0
        mov     rcx, [rel thread_client]
        xor     edx, edx
        lea     r8, [rel thread_pcm_format]
        lea     r9, [rel thread_closest_format]
        mov     rax, [rcx]
        call    qword [rax + IAudioClient_IS_FORMAT_SUPPORTED * 8]
        mov     dword [r12 + REPORT_FORMAT_HR], eax
        mov     ebx, eax
        mov     rcx, [rel thread_closest_format]
        test    rcx, rcx
        jz      .worker_format_done
        call    CoTaskMemFree
.worker_format_done:
        test    ebx, ebx                    ; exact S_OK only
        jnz     .worker_cleanup

        mov     rcx, [rel thread_client]
        xor     edx, edx
        mov     r8d, AUDCLNT_STREAMFLAGS_EVENTCALLBACK
        mov     r9d, WASAPI_BUFFER_100NS
        mov     qword [rsp + 0x20], 0
        lea     rax, [rel thread_pcm_format]
        mov     [rsp + 0x28], rax
        mov     qword [rsp + 0x30], 0
        mov     rax, [rcx]
        call    qword [rax + IAudioClient_INITIALIZE * 8]
        mov     dword [r12 + REPORT_INIT_HR], eax
        test    eax, eax
        js      .worker_cleanup

        mov     rcx, [rel thread_client]
        lea     rdx, [r12 + REPORT_BUFFER_SIZE]
        mov     rax, [rcx]
        call    qword [rax + IAudioClient_GET_BUFFER_SIZE * 8]
        test    eax, eax
        js      .worker_cleanup

        mov     rcx, [rel thread_client]
        lea     rdx, [rel thread_iid_render_client]
        lea     r8, [rel thread_render]
        mov     rax, [rcx]
        call    qword [rax + IAudioClient_GET_SERVICE * 8]
        mov     dword [r12 + REPORT_SERVICE_HR], eax
        test    eax, eax
        js      .worker_cleanup

        ; The worker owns the callback event for its entire lifetime.
        xor     ecx, ecx
        xor     edx, edx                    ; auto-reset
        xor     r8d, r8d
        xor     r9d, r9d
        call    CreateEventW
        mov     [rel thread_audio_event], rax
        test    rax, rax
        jz      .worker_cleanup
        mov     dword [r12 + REPORT_EVENT_CREATED], 1
        mov     [rel thread_wait_handles + 8], rax

        mov     rcx, [rel thread_client]
        mov     rdx, [rel thread_audio_event]
        mov     rax, [rcx]
        call    qword [rax + IAudioClient_SET_EVENT_HANDLE * 8]
        mov     dword [r12 + REPORT_SET_EVENT_HR], eax
        test    eax, eax
        js      .worker_cleanup

        mov     rcx, [rel thread_client]
        mov     rax, [rcx]
        call    qword [rax + IAudioClient_START * 8]
        mov     dword [r12 + REPORT_START_HR], eax
        test    eax, eax
        js      .worker_cleanup
        mov     dword [rel thread_started], 1

.worker_wait:
        mov     ecx, 2
        lea     rdx, [rel thread_wait_handles]
        xor     r8d, r8d                    ; wait-any
        mov     r9d, THREAD_WAIT_TIMEOUT_MS
        call    WaitForMultipleObjects
        cmp     dword [rel thread_first_wait_seen], 0
        jne     .wait_seen
        mov     dword [r12 + REPORT_FIRST_WAIT], eax
        mov     dword [rel thread_first_wait_seen], 1
.wait_seen:
        cmp     eax, WAIT_OBJECT_0           ; process stop event
        je      .worker_success
        cmp     eax, WAIT_OBJECT_0 + 1       ; audio callback event
        je      .audio_wakeup
        cmp     eax, WAIT_TIMEOUT
        je      .audio_timeout
        jmp     .worker_cleanup

.audio_timeout:
        inc     dword [r12 + REPORT_TIMEOUTS]
        jmp     .worker_wait

.audio_wakeup:
        ; GetCurrentPadding reports how much of the endpoint is occupied.
        mov     rcx, [rel thread_client]
        lea     rdx, [r12 + REPORT_PADDING_FRAMES]
        mov     rax, [rcx]
        call    qword [rax + IAudioClient_GET_CURRENT_PADDING * 8]
        mov     dword [r12 + REPORT_PADDING_HR], eax
        test    eax, eax
        js      .worker_cleanup

        mov     eax, dword [r12 + REPORT_BUFFER_SIZE]
        sub     eax, dword [r12 + REPORT_PADDING_FRAMES]
        jbe     .worker_wait
        cmp     eax, THREAD_MAX_FRAMES
        jbe     .chunk_selected
        mov     eax, THREAD_MAX_FRAMES
.chunk_selected:
        mov     r14d, eax

        mov     rcx, [rel thread_render]
        mov     edx, r14d
        lea     r8, [rel thread_buffer_data]
        mov     rax, [rcx]
        call    qword [rax + IAudioRenderClient_GET_BUFFER * 8]
        mov     dword [r12 + REPORT_GET_BUFFER_HR], eax
        test    eax, eax
        js      .worker_cleanup

        mov     rcx, [rel thread_render]
        mov     edx, r14d
        mov     r8d, AUDCLNT_BUFFERFLAGS_SILENT
        mov     rax, [rcx]
        call    qword [rax + IAudioRenderClient_RELEASE_BUFFER * 8]
        mov     dword [r12 + REPORT_RELEASE_HR], eax
        test    eax, eax
        js      .worker_cleanup
        inc     dword [r12 + REPORT_EVENT_WAKEUPS]
        add     dword [r12 + REPORT_FRAMES], r14d
        jmp     .worker_wait

.worker_success:
        xor     r13d, r13d

.worker_cleanup:
        cmp     dword [rel thread_started], 0
        je      .worker_no_stop
        mov     rcx, [rel thread_client]
        test    rcx, rcx
        jz      .worker_no_stop
        mov     rax, [rcx]
        call    qword [rax + IAudioClient_STOP * 8]
        mov     dword [r12 + REPORT_STOP_HR], eax
        test    eax, eax
        jns     .worker_stop_ok
        mov     r13d, 1
.worker_stop_ok:
        mov     rcx, [rel thread_client]
        mov     rax, [rcx]
        call    qword [rax + IAudioClient_RESET * 8]
        mov     dword [r12 + REPORT_RESET_HR], eax
        test    eax, eax
        jns     .worker_no_stop
        mov     r13d, 1
.worker_no_stop:
        mov     rcx, [rel thread_render]
        test    rcx, rcx
        jz      .worker_no_render
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.worker_no_render:
        mov     rcx, [rel thread_client]
        test    rcx, rcx
        jz      .worker_no_client
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.worker_no_client:
        mov     rcx, [rel thread_device]
        test    rcx, rcx
        jz      .worker_no_device
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.worker_no_device:
        mov     rcx, [rel thread_enumerator]
        test    rcx, rcx
        jz      .worker_no_enum
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.worker_no_enum:
        mov     rcx, [rel thread_audio_event]
        test    rcx, rcx
        jz      .worker_no_audio_event
        call    CloseHandle
.worker_no_audio_event:
        cmp     dword [rel thread_com_initialized], 0
        je      .worker_no_com
        call    CoUninitialize
.worker_no_com:
        mov     dword [r12 + REPORT_WORKER_EXIT], r13d
        mov     eax, r13d
        add     rsp, 0x88
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret

; uint32_t asm_audio_thread_probe(uint32_t durationMs,
;                                 AudioThreadAsmProbeReport* report)
asm_audio_thread_probe:
        push    rbp
        mov     rbp, rsp
        push    rbx
        push    rsi
        push    rdi
        push    r12
        push    r13
        push    r14
        push    r15
        sub     rsp, 0x88

        mov     esi, ecx                    ; duration
        mov     r12, rdx                    ; report pointer
        mov     r13d, 1

        mov     rdi, r12
        xor     eax, eax
        mov     ecx, REPORT_BYTES / 4
        rep stosd
        mov     dword [r12 + REPORT_DURATION_MS], esi

        ; Manual-reset stop event is shared only with the worker.
        xor     ecx, ecx
        mov     edx, 1
        xor     r8d, r8d
        xor     r9d, r9d
        call    CreateEventW
        mov     [rel thread_stop_event], rax
        test    rax, rax
        jz      .main_cleanup
        mov     [rel thread_wait_handles], rax

        ; CreateThread(NULL, 0, worker, report, 0, &threadId).
        xor     ecx, ecx
        xor     edx, edx
        lea     r8, [rel audio_thread_probe_worker]
        mov     r9, r12
        mov     qword [rsp + 0x20], 0
        lea     rax, [rel thread_thread_id]
        mov     [rsp + 0x28], rax
        call    CreateThread
        mov     [rel thread_handle], rax
        test    rax, rax
        jz      .main_cleanup
        mov     dword [r12 + REPORT_THREAD_CREATED], 1

        mov     rcx, [rel thread_handle]
        mov     edx, THREAD_PRIORITY_ABOVE_NORMAL
        call    SetThreadPriority
        mov     dword [r12 + REPORT_THREAD_PRIORITY], eax

        mov     ecx, esi
        call    Sleep

        mov     rcx, [rel thread_stop_event]
        call    SetEvent

        mov     rcx, [rel thread_handle]
        mov     edx, 0xFFFFFFFF              ; INFINITE
        call    WaitForSingleObject
        mov     dword [r12 + REPORT_THREAD_WAIT], eax
        test    eax, eax
        jnz     .main_cleanup

        xor     r13d, r13d

.main_cleanup:
        mov     rcx, [rel thread_handle]
        test    rcx, rcx
        jz      .main_no_thread
        call    CloseHandle
.main_no_thread:
        mov     rcx, [rel thread_stop_event]
        test    rcx, rcx
        jz      .main_no_stop_event
        call    CloseHandle
.main_no_stop_event:
        mov     qword [rel thread_handle], 0
        mov     qword [rel thread_stop_event], 0
        mov     qword [rel thread_audio_event], 0
        mov     qword [rel thread_render], 0
        mov     qword [rel thread_client], 0
        mov     qword [rel thread_device], 0
        mov     qword [rel thread_enumerator], 0
        mov     qword [rel thread_closest_format], 0
        mov     qword [rel thread_buffer_data], 0
        mov     dword [rel thread_started], 0
        mov     dword [rel thread_com_initialized], 0
        mov     dword [rel thread_first_wait_seen], 0

        mov     eax, r13d
        add     rsp, 0x88
        pop     r15
        pop     r14
        pop     r13
        pop     r12
        pop     rdi
        pop     rsi
        pop     rbx
        pop     rbp
        ret
