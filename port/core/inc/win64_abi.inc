; win64_abi.inc - MS x64 ABI contract for the Windows demo target.
;
; This file is intentionally declarative. It centralizes the rules shared by
; the production NASM platform and the separate C++ differential oracle.

%ifndef VOODKA_WIN64_ABI_INC
%define VOODKA_WIN64_ABI_INC

; Microsoft x64 calling convention.
%define WIN64_STACK_ALIGNMENT                 16
%define WIN64_SHADOW_SPACE_BYTES              0x20
%define WIN64_CALLER_ENTRY_RSP_MOD16          8
%define WIN64_CALL_RSP_MOD16                  0
%define WIN64_CALLER_STACK_ARG0               0x20
%define WIN64_CALLEE_STACK_ARG0               0x28

; Integer/pointer argument and return registers.
%define WIN64_ARG0                            rcx
%define WIN64_ARG1                            rdx
%define WIN64_ARG2                            r8
%define WIN64_ARG3                            r9
%define WIN64_RETURN                          rax

; Non-volatile general-purpose registers. RSP, RBP, RBX, RSI, RDI, and
; R12-R15 must be preserved by an assembly function across a bridge call.
; XMM6-XMM15 are also non-volatile when used by a future SIMD implementation.

; eos_dispatch saves RBP plus RBX, RSI, RDI, and R12-R15 (8 registers = 64
; bytes). At entry RSP%16 is 8; after those pushes it is 8 again. Reserving
; 0x28 bytes leaves RSP%16 == 0 at every call into a Windows service and supplies
; the mandatory 0x20-byte home area plus 8 bytes of local alignment space.
%define WIN64_EOS_DISPATCH_SAVED_BYTES       0x40
%define WIN64_EOS_DISPATCH_CALL_FRAME_BYTES  0x28

; COM/DirectX calls use the same ABI. RCX contains the interface pointer,
; followed by RDX/R8/R9 for method arguments; the caller still reserves the
; shadow space and must satisfy WIN64_CALL_RSP_MOD16 before CALL.
; At the caller's RSP before CALL, the fifth argument is [rsp+0x20]. After
; CALL pushes the return address, the callee observes it at [rsp+0x28].

; Public service signatures are documented beside their NASM implementations
; and validation ABIs. Keep fixed-width argument and return contracts there;
; do not introduce compiler-generated platform wrappers into VOODKA.exe.

%endif
