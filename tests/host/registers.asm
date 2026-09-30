FLOAT_SLOT_SIZE equ 16
SLOT_SIZE equ 8
SAVED_FLOATS equ 6
REGISTERS equ SAVED_FLOATS * FLOAT_SLOT_SIZE
SHADOW_SPACE equ 32

.code

leaf_add_one PROC
	lea rax, [rcx + 1]
	ret
leaf_add_one ENDP

leaf_add_floats PROC
	addss xmm0, xmm1
	ret
leaf_add_floats ENDP

call_keeping_registers PROC FRAME
	push rbx
	.pushreg rbx
	sub rsp, SHADOW_SPACE
	.allocstack SHADOW_SPACE
	.endprolog

	mov rbx, rdx
	mov rax, rcx
	movdqu xmm0, XMMWORD PTR [rbx]
	movdqu xmm1, XMMWORD PTR [rbx + FLOAT_SLOT_SIZE]
	movdqu xmm2, XMMWORD PTR [rbx + 2 * FLOAT_SLOT_SIZE]
	movdqu xmm3, XMMWORD PTR [rbx + 3 * FLOAT_SLOT_SIZE]
	movdqu xmm4, XMMWORD PTR [rbx + 4 * FLOAT_SLOT_SIZE]
	movdqu xmm5, XMMWORD PTR [rbx + 5 * FLOAT_SLOT_SIZE]
	mov rcx, [rbx + REGISTERS]
	mov rdx, [rbx + REGISTERS + SLOT_SIZE]
	mov r8, [rbx + REGISTERS + 2 * SLOT_SIZE]
	mov r9, [rbx + REGISTERS + 3 * SLOT_SIZE]
	mov r10, [rbx + REGISTERS + 4 * SLOT_SIZE]
	mov r11, [rbx + REGISTERS + 5 * SLOT_SIZE]
	call rax
	movdqu XMMWORD PTR [rbx], xmm0
	movdqu XMMWORD PTR [rbx + FLOAT_SLOT_SIZE], xmm1
	movdqu XMMWORD PTR [rbx + 2 * FLOAT_SLOT_SIZE], xmm2
	movdqu XMMWORD PTR [rbx + 3 * FLOAT_SLOT_SIZE], xmm3
	movdqu XMMWORD PTR [rbx + 4 * FLOAT_SLOT_SIZE], xmm4
	movdqu XMMWORD PTR [rbx + 5 * FLOAT_SLOT_SIZE], xmm5
	mov [rbx + REGISTERS], rcx
	mov [rbx + REGISTERS + SLOT_SIZE], rdx
	mov [rbx + REGISTERS + 2 * SLOT_SIZE], r8
	mov [rbx + REGISTERS + 3 * SLOT_SIZE], r9
	mov [rbx + REGISTERS + 4 * SLOT_SIZE], r10
	mov [rbx + REGISTERS + 5 * SLOT_SIZE], r11
	mov [rbx + REGISTERS + 6 * SLOT_SIZE], rax

	add rsp, SHADOW_SPACE
	pop rbx
	ret
call_keeping_registers ENDP

END
