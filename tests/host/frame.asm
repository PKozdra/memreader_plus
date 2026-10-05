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

END
