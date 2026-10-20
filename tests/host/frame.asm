EXTERN host_unwind_probe:PROC

.code

frame_target PROC FRAME
	push rbx
	.pushreg rbx
	sub rsp, 0C0h
	.allocstack 0C0h
	mov [rsp + 0D8h], rsi
	.savereg rsi, 0D8h
	.endprolog
	mov [rsp + 0D0h], rcx
	mov rbx, rcx
	mov rsi, rcx
	call host_unwind_probe
	mov rax, [rsp + 0D0h]
	sub rax, rbx
	mov rsi, [rsp + 0D8h]
	add rsp, 0C0h
	pop rbx
	ret
frame_target ENDP

frame_twin PROC FRAME
	push rbx
	.pushreg rbx
	sub rsp, 0C0h
	.allocstack 0C0h
	mov [rsp + 0D8h], rsi
	.savereg rsi, 0D8h
	.endprolog
	mov [rsp + 0D0h], rcx
	mov rbx, rcx
	mov rsi, rcx
	call host_unwind_probe
	mov rax, [rsp + 0D0h]
	sub rax, rbx
	mov rsi, [rsp + 0D8h]
	add rsp, 0C0h
	pop rbx
	ret
frame_twin ENDP

frame_xmm_target PROC FRAME
	push rbx
	.pushreg rbx
	sub rsp, 0C0h
	.allocstack 0C0h
	movaps [rsp + 20h], xmm6
	.savexmm128 xmm6, 20h
	.endprolog
	mov [rsp + 0D0h], rcx
	mov rbx, rcx
	xorps xmm6, xmm6
	call host_unwind_probe
	mov rax, [rsp + 0D0h]
	sub rax, rbx
	movaps xmm6, [rsp + 20h]
	add rsp, 0C0h
	pop rbx
	ret
frame_xmm_target ENDP

frame_pointer_target PROC FRAME
	mov rax, rsp
	push rbp
	.pushreg rbp
	push rbx
	.pushreg rbx
	lea rbp, [rax - 200h]
	sub rsp, 218h
	.allocstack 218h
	.endprolog
	mov [rbp + 208h], rcx
	mov [rbp + 10h], rcx
	mov [rsp + 100h], rcx
	mov rbx, rcx
	call host_unwind_probe
	mov rax, [rbp + 208h]
	sub rax, [rbp + 10h]
	add rax, [rsp + 230h]
	sub rax, [rsp + 100h]
	add rsp, 218h
	pop rbx
	pop rbp
	ret
frame_pointer_target ENDP

frame_call PROC FRAME
	push rbx
	.pushreg rbx
	push rsi
	.pushreg rsi
	sub rsp, 38h
	.allocstack 38h
	movaps [rsp + 20h], xmm6
	.savexmm128 xmm6, 20h
	.endprolog
	mov rax, rcx
	mov rcx, rdx
	mov rbx, 2222h
	mov rsi, 1111h
	mov r9, 3333h
	movq xmm6, r9
	mov [rdx + 32], rsp
	lea r8, returned
	mov [rdx + 40], r8
	call rax
returned:
	movaps xmm6, [rsp + 20h]
	add rsp, 38h
	pop rsi
	pop rbx
	ret
frame_call ENDP

frame_hooked PROC FRAME
	mov rax, rsp
	push rbp
	.pushreg rbp
	push rbx
	.pushreg rbx
	lea rbp, [rax - 180h]
	sub rsp, 198h
	.allocstack 198h
	.endprolog
	mov [rbp + 188h], rcx
	mov rbx, rcx
	call host_unwind_probe
	mov rax, [rbp + 188h]
	sub rax, rbx
	add rsp, 198h
	pop rbx
	pop rbp
	ret
frame_hooked ENDP

prologue_target PROC
	push rbx
	push rsi
	push rdi
	nop
	mov eax, 1
	pop rdi
	pop rsi
	pop rbx
	ret
prologue_target ENDP

parked_target PROC
	push rbx
spin:
	cmp dword ptr [rcx], 0
	je spin
	pop rbx
	mov eax, 77
	ret
parked_target ENDP

park_frame PROC FRAME
	push rbx
	.pushreg rbx
	.endprolog
	mov eax, 1
	mov edx, 3
spin:
	cmp dword ptr [rcx], 0
	je spin
	pop rbx
	mov eax, 78
	ret
park_frame ENDP

park_grow PROC FRAME
	push rbx
	.pushreg rbx
	sub rsp, 0C0h
	.allocstack 0C0h
	.endprolog
spin:
	cmp dword ptr [rcx], 0
	je spin
	add rsp, 0C0h
	pop rbx
	mov eax, 79
	ret
park_grow ENDP

park_outer PROC FRAME
	sub rsp, 28h
	.allocstack 28h
	.endprolog
	mov eax, 1
	call park_inner
	add rsp, 28h
	ret
park_outer ENDP

park_inner PROC
spin:
	cmp dword ptr [rcx], 0
	je spin
	mov eax, 80
	ret
park_inner ENDP

fillcode SEGMENT ALIGN(4096) READ EXECUTE ALIAS(".text$zz") 'CODE'

filler_code PROC
	BYTE 1114112 DUP (0)
filler_code ENDP

mixed_code PROC
	BYTE 163840 DUP (0)
mixed_code ENDP

fillcode ENDS

END
