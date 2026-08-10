; audio_wasapi_probe.asm - direct Win64 WASAPI/COM feasibility probe.
;
; This is a validation boundary, not production playback yet.  The C++ host
; only receives the fixed-width report; COM initialization, endpoint
; activation, IAudioClient setup, event callback, render-buffer exercise, and
; teardown all happen here through Windows ABI calls and COM vtables.

BITS 64
DEFAULT REL

%include "win64_abi.inc"

%define CLSCTX_ALL                         0x17
%define COINIT_MULTITHREADED               0x0
%define ERENDER                            0
%define ECONSOLE                           0
%define AUDCLNT_STREAMFLAGS_EVENTCALLBACK  0x40000
%define AUDCLNT_BUFFERFLAGS_SILENT         0x2
%define WASAPI_BUFFER_100NS                600000 ; 60 ms
%define WASAPI_PROBE_TIMEOUT_MS            1000
%define WASAPI_PROBE_MAX_FRAMES            256

; IAudioClient / IAudioRenderClient vtable slots after IUnknown.
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

; WasapiAsmProbeReport: twenty-one uint32_t fields.
%define REPORT_COM_HR                     0
%define REPORT_ENUM_HR                    4
%define REPORT_ENDPOINT_HR                8
%define REPORT_ACTIVATE_HR               12
%define REPORT_FORMAT_HR                 16
%define REPORT_INIT_HR                   20
%define REPORT_BUFFER_SIZE               24
%define REPORT_EVENT_CREATED             28
%define REPORT_SET_EVENT_HR              32
%define REPORT_SERVICE_HR                36
%define REPORT_START_HR                  40
%define REPORT_WAIT_RESULT               44
%define REPORT_PADDING_HR                48
%define REPORT_PADDING_FRAMES            52
%define REPORT_GET_BUFFER_HR             56
%define REPORT_RELEASE_HR                60
%define REPORT_STOP_HR                   64
%define REPORT_RESET_HR                  68
%define REPORT_FORMAT_TAG                72
%define REPORT_SAMPLE_RATE               76
%define REPORT_CHANNELS                  80
%define REPORT_FRAMES                    84
%define REPORT_BYTES                     88

extern CoInitializeEx
extern CoUninitialize
extern CoCreateInstance
extern CoTaskMemFree
extern CreateEventW
extern WaitForSingleObject
extern CloseHandle

global asm_audio_wasapi_probe

section .bss
align 8
probe_enumerator:       resq 1
probe_device:           resq 1
probe_client:           resq 1
probe_render:           resq 1
probe_event:            resq 1
probe_closest_format:   resq 1
probe_buffer_data:      resq 1
probe_started:          resd 1
probe_com_initialized:  resd 1

section .data
align 4

; CLSID_MMDeviceEnumerator = BCDE0395-E52F-467C-8E3D-C4579291692E.
probe_clsid_mmdevice:   db 0x95,0x03,0xDE,0xBC, 0x2F,0xE5, 0x7C,0x46
                        db 0x8E,0x3D,0xC4,0x57,0x92,0x91,0x69,0x2E

; IID_IMMDeviceEnumerator = A95664D2-9614-4F35-A746-DE8DB63617E6.
probe_iid_mmdevice_enum: db 0xD2,0x64,0x56,0xA9, 0x14,0x96, 0x35,0x4F
                         db 0xA7,0x46,0xDE,0x8D,0xB6,0x36,0x17,0xE6

; IID_IAudioClient = 1CB9AD4C-DBFA-4C32-B178-C2F568A703B2.
probe_iid_audio_client: db 0x4C,0xAD,0xB9,0x1C, 0xFA,0xDB, 0x32,0x4C
                        db 0xB1,0x78,0xC2,0xF5,0x68,0xA7,0x03,0xB2

; IID_IAudioRenderClient = F294ACFC-3146-4483-A7BF-ADDCA7C260E2.
probe_iid_render_client: db 0xFC,0xAC,0x94,0xF2, 0x46,0x31, 0x83,0x44
                         db 0xA7,0xBF,0xAD,0xDC,0xA7,0xC2,0x60,0xE2

; WAVEFORMATEX: PCM, 44.1 kHz, stereo, signed 16-bit.
align 4
probe_pcm_format:
        dw 1                    ; WAVE_FORMAT_PCM
        dw 2                    ; nChannels
        dd 44100                ; nSamplesPerSec
        dd 176400               ; nAvgBytesPerSec
        dw 4                    ; nBlockAlign
        dw 16                   ; wBitsPerSample
        dw 0                    ; cbSize

; ---------------------------------------------------------------------------
; uint32_t asm_audio_wasapi_probe(WasapiAsmProbeReport* report)
;
; The function saves eight nonvolatile registers.  At entry RSP%16==8; after
; the pushes it is 8 again, and sub rsp,0x88 reaches RSP%16==0 while leaving
; the required shadow space and stack argument slots available.
; ---------------------------------------------------------------------------
section .text
asm_audio_wasapi_probe:
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
        mov     r13d, 1                      ; failure until every gate passes

        lea     rdi, [rel probe_enumerator]
        xor     eax, eax
        mov     ecx, 7                      ; five qwords plus two flag words
        rep stosq
        mov     dword [rel probe_started], 0
        mov     dword [rel probe_com_initialized], 0

        mov     rdi, r12
        xor     eax, eax
        mov     ecx, REPORT_BYTES / 4
        rep stosd
        mov     dword [r12 + REPORT_FORMAT_TAG], 1
        mov     dword [r12 + REPORT_SAMPLE_RATE], 44100
        mov     dword [r12 + REPORT_CHANNELS], 2

        ; CoInitializeEx(NULL, COINIT_MULTITHREADED).
        xor     ecx, ecx
        xor     edx, edx
        call    CoInitializeEx
        mov     dword [r12 + REPORT_COM_HR], eax
        test    eax, eax
        js      .cleanup
        mov     dword [rel probe_com_initialized], 1

        ; CoCreateInstance(CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL,
        ;                  IID_IMMDeviceEnumerator, &enumerator).
        lea     rcx, [rel probe_clsid_mmdevice]
        xor     edx, edx
        mov     r8d, CLSCTX_ALL
        lea     r9, [rel probe_iid_mmdevice_enum]
        lea     rax, [rel probe_enumerator]
        mov     [rsp + 0x20], rax
        call    CoCreateInstance
        mov     dword [r12 + REPORT_ENUM_HR], eax
        test    eax, eax
        js      .cleanup

        ; IMMDeviceEnumerator::GetDefaultAudioEndpoint(eRender, eConsole,
        ;                                               &device).
        mov     rcx, [rel probe_enumerator]
        xor     edx, edx
        xor     r8d, r8d
        lea     r9, [rel probe_device]
        mov     rax, [rcx]
        call    qword [rax + IMM_ENUM_GET_DEFAULT_ENDPOINT * 8]
        mov     dword [r12 + REPORT_ENDPOINT_HR], eax
        test    eax, eax
        js      .cleanup

        ; IMMDevice::Activate(IID_IAudioClient, CLSCTX_ALL, NULL, &client).
        mov     rcx, [rel probe_device]
        lea     rdx, [rel probe_iid_audio_client]
        mov     r8d, CLSCTX_ALL
        xor     r9d, r9d
        lea     rax, [rel probe_client]
        mov     [rsp + 0x20], rax
        mov     rax, [rcx]
        call    qword [rax + IMM_DEVICE_ACTIVATE * 8]
        mov     dword [r12 + REPORT_ACTIVATE_HR], eax
        test    eax, eax
        js      .cleanup

        ; IAudioClient::IsFormatSupported(shared, &pcm, &closest).
        mov     qword [rel probe_closest_format], 0
        mov     rcx, [rel probe_client]
        xor     edx, edx                    ; AUDCLNT_SHAREMODE_SHARED
        lea     r8, [rel probe_pcm_format]
        lea     r9, [rel probe_closest_format]
        mov     rax, [rcx]
        call    qword [rax + IAudioClient_IS_FORMAT_SUPPORTED * 8]
        mov     dword [r12 + REPORT_FORMAT_HR], eax
        mov     ebx, eax
        mov     rcx, [rel probe_closest_format]
        test    rcx, rcx
        jz      .format_no_closest
        call    CoTaskMemFree
.format_no_closest:
        test    ebx, ebx                    ; only exact S_OK is accepted
        jnz     .cleanup

        ; IAudioClient::Initialize(shared, EVENTCALLBACK, 60 ms, 0,
        ;                           &pcm_format, NULL).
        mov     rcx, [rel probe_client]
        xor     edx, edx
        mov     r8d, AUDCLNT_STREAMFLAGS_EVENTCALLBACK
        mov     r9d, WASAPI_BUFFER_100NS
        mov     qword [rsp + 0x20], 0
        lea     rax, [rel probe_pcm_format]
        mov     [rsp + 0x28], rax
        mov     qword [rsp + 0x30], 0
        mov     rax, [rcx]
        call    qword [rax + IAudioClient_INITIALIZE * 8]
        mov     dword [r12 + REPORT_INIT_HR], eax
        test    eax, eax
        js      .cleanup

        ; GetBufferSize(&bufferFrames).
        mov     rcx, [rel probe_client]
        lea     rdx, [r12 + REPORT_BUFFER_SIZE]
        mov     rax, [rcx]
        call    qword [rax + IAudioClient_GET_BUFFER_SIZE * 8]
        test    eax, eax
        js      .cleanup

        ; GetService(IID_IAudioRenderClient, &renderClient).
        mov     rcx, [rel probe_client]
        lea     rdx, [rel probe_iid_render_client]
        lea     r8, [rel probe_render]
        mov     rax, [rcx]
        call    qword [rax + IAudioClient_GET_SERVICE * 8]
        mov     dword [r12 + REPORT_SERVICE_HR], eax
        test    eax, eax
        js      .cleanup

        ; CreateEventW(NULL, auto-reset, nonsignaled, NULL).
        xor     ecx, ecx
        xor     edx, edx
        xor     r8d, r8d
        xor     r9d, r9d
        call    CreateEventW
        mov     [rel probe_event], rax
        test    rax, rax
        jz      .cleanup
        mov     dword [r12 + REPORT_EVENT_CREATED], 1

        ; SetEventHandle(event).
        mov     rcx, [rel probe_client]
        mov     rdx, [rel probe_event]
        mov     rax, [rcx]
        call    qword [rax + IAudioClient_SET_EVENT_HANDLE * 8]
        mov     dword [r12 + REPORT_SET_EVENT_HR], eax
        test    eax, eax
        js      .cleanup

        ; Start().
        mov     rcx, [rel probe_client]
        mov     rax, [rcx]
        call    qword [rax + IAudioClient_START * 8]
        mov     dword [r12 + REPORT_START_HR], eax
        test    eax, eax
        js      .cleanup
        mov     dword [rel probe_started], 1

        ; The event callback must fire once the shared buffer needs service.
        mov     rcx, [rel probe_event]
        mov     edx, WASAPI_PROBE_TIMEOUT_MS
        call    WaitForSingleObject
        mov     dword [r12 + REPORT_WAIT_RESULT], eax
        test    eax, eax                    ; WAIT_OBJECT_0
        jnz     .cleanup

        ; GetCurrentPadding(&paddingFrames).
        mov     rcx, [rel probe_client]
        lea     rdx, [r12 + REPORT_PADDING_FRAMES]
        mov     rax, [rcx]
        call    qword [rax + IAudioClient_GET_CURRENT_PADDING * 8]
        mov     dword [r12 + REPORT_PADDING_HR], eax
        test    eax, eax
        js      .cleanup

        ; Exercise the render client with a silent chunk.  The chunk is at
        ; most half the endpoint buffer and no larger than 256 frames.
        mov     eax, dword [r12 + REPORT_BUFFER_SIZE]
        shr     eax, 1
        test    eax, eax
        jnz     .frames_nonzero
        mov     eax, 1
.frames_nonzero:
        cmp     eax, WASAPI_PROBE_MAX_FRAMES
        jbe     .frames_selected
        mov     eax, WASAPI_PROBE_MAX_FRAMES
.frames_selected:
        mov     r14d, eax
        mov     dword [r12 + REPORT_FRAMES], eax

        mov     rcx, [rel probe_render]
        mov     edx, r14d
        lea     r8, [rel probe_buffer_data]
        mov     rax, [rcx]
        call    qword [rax + IAudioRenderClient_GET_BUFFER * 8]
        mov     dword [r12 + REPORT_GET_BUFFER_HR], eax
        test    eax, eax
        js      .cleanup

        mov     rcx, [rel probe_render]
        mov     edx, r14d
        mov     r8d, AUDCLNT_BUFFERFLAGS_SILENT
        mov     rax, [rcx]
        call    qword [rax + IAudioRenderClient_RELEASE_BUFFER * 8]
        mov     dword [r12 + REPORT_RELEASE_HR], eax
        test    eax, eax
        js      .cleanup

        xor     r13d, r13d                  ; complete probe succeeded

.cleanup:
        ; Stop and reset before releasing the render service/client.
        cmp     dword [rel probe_started], 0
        je      .no_stop
        mov     rcx, [rel probe_client]
        test    rcx, rcx
        jz      .no_stop
        mov     rax, [rcx]
        call    qword [rax + IAudioClient_STOP * 8]
        mov     dword [r12 + REPORT_STOP_HR], eax
        test    eax, eax
        jns     .stop_ok
        mov     r13d, 1
.stop_ok:
        mov     rcx, [rel probe_client]
        mov     rax, [rcx]
        call    qword [rax + IAudioClient_RESET * 8]
        mov     dword [r12 + REPORT_RESET_HR], eax
        test    eax, eax
        jns     .no_stop
        mov     r13d, 1
.no_stop:
        mov     rcx, [rel probe_render]
        test    rcx, rcx
        jz      .no_render
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.no_render:
        mov     rcx, [rel probe_client]
        test    rcx, rcx
        jz      .no_client
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.no_client:
        mov     rcx, [rel probe_device]
        test    rcx, rcx
        jz      .no_device
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.no_device:
        mov     rcx, [rel probe_enumerator]
        test    rcx, rcx
        jz      .no_enumerator
        mov     rax, [rcx]
        call    qword [rax + IUNKNOWN_RELEASE * 8]
.no_enumerator:
        mov     rcx, [rel probe_event]
        test    rcx, rcx
        jz      .no_event
        call    CloseHandle
.no_event:
        mov     qword [rel probe_render], 0
        mov     qword [rel probe_client], 0
        mov     qword [rel probe_device], 0
        mov     qword [rel probe_enumerator], 0
        mov     qword [rel probe_event], 0
        mov     qword [rel probe_closest_format], 0
        mov     qword [rel probe_buffer_data], 0
        mov     dword [rel probe_started], 0

        cmp     dword [rel probe_com_initialized], 0
        je      .no_com
        call    CoUninitialize
.no_com:
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
