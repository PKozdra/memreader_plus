REGISTER_ARGUMENTS equ 4
SAVED_REGISTERS equ 6
SLOT_SIZE equ 8
FLOAT_SLOT_SIZE equ 16
SHADOW_SPACE equ REGISTER_ARGUMENTS * SLOT_SIZE
STACK_ALIGNMENT equ 16
ALIGNMENT_PADDING equ 8
FRAME_REGISTERS equ SHADOW_SPACE
FRAME_FLOATS equ FRAME_REGISTERS + SAVED_REGISTERS * SLOT_SIZE
FRAME_STACK equ FRAME_FLOATS + SAVED_REGISTERS * FLOAT_SLOT_SIZE
FRAME_RESULT equ FRAME_STACK + SLOT_SIZE
FRAME_FLOAT_RESULT equ FRAME_RESULT + SLOT_SIZE
FRAME_ORIGINAL equ FRAME_FLOAT_RESULT + SLOT_SIZE
FRAME_END equ FRAME_ORIGINAL + SLOT_SIZE
HOOK_STACK equ FRAME_END + ALIGNMENT_PADDING
RETURN_ADDRESS equ SLOT_SIZE
RUN_ORIGINAL equ 0
RETURN_FLOAT_RESULT equ 2

EXTERN run_hook:PROC

.code

call_function PROC FRAME
	push rbp
	.pushreg rbp
	push rbx
	.pushreg rbx
	push rsi
	.pushreg rsi
	push rdi
	.pushreg rdi
	sub rsp, ALIGNMENT_PADDING
	.allocstack ALIGNMENT_PADDING
	mov rbp, rsp
	.setframe rbp, 0
	.endprolog

	mov rbx, rcx
	mov rsi, rdx
	mov rdi, r9

	mov rax, r8
	sub rax, REGISTER_ARGUMENTS
	jbe no_stack_arguments
	lea rcx, [rax * SLOT_SIZE + SHADOW_SPACE + STACK_ALIGNMENT - 1]
	and rcx, -STACK_ALIGNMENT
	sub rsp, rcx
	xor rcx, rcx
copy_stack_argument:
	mov rdx, [rsi + SHADOW_SPACE + rcx * SLOT_SIZE]
	mov [rsp + SHADOW_SPACE + rcx * SLOT_SIZE], rdx
	inc rcx
	cmp rcx, rax
	jb copy_stack_argument
	jmp load_registers
no_stack_arguments:
	sub rsp, SHADOW_SPACE

load_registers:
	mov rcx, [rsi]
	mov rdx, [rsi + SLOT_SIZE]
	mov r8, [rsi + 2 * SLOT_SIZE]
	mov r9, [rsi + 3 * SLOT_SIZE]
	movq xmm0, rcx
	movq xmm1, rdx
	movq xmm2, r8
	movq xmm3, r9
	call rbx
	movsd QWORD PTR [rdi], xmm0

	lea rsp, [rbp + ALIGNMENT_PADDING]
	pop rdi
	pop rsi
	pop rbx
	pop rbp
	ret
call_function ENDP

hook_entry PROC FRAME
	sub rsp, HOOK_STACK
	.allocstack HOOK_STACK
	.endprolog

	mov [rsp + FRAME_REGISTERS], rcx
	mov [rsp + FRAME_REGISTERS + SLOT_SIZE], rdx
	mov [rsp + FRAME_REGISTERS + 2 * SLOT_SIZE], r8
	mov [rsp + FRAME_REGISTERS + 3 * SLOT_SIZE], r9
	mov [rsp + FRAME_REGISTERS + 4 * SLOT_SIZE], r10
	mov [rsp + FRAME_REGISTERS + 5 * SLOT_SIZE], r11
	movdqu XMMWORD PTR [rsp + FRAME_FLOATS], xmm0
	movdqu XMMWORD PTR [rsp + FRAME_FLOATS + FLOAT_SLOT_SIZE], xmm1
	movdqu XMMWORD PTR [rsp + FRAME_FLOATS + 2 * FLOAT_SLOT_SIZE], xmm2
	movdqu XMMWORD PTR [rsp + FRAME_FLOATS + 3 * FLOAT_SLOT_SIZE], xmm3
	movdqu XMMWORD PTR [rsp + FRAME_FLOATS + 4 * FLOAT_SLOT_SIZE], xmm4
	movdqu XMMWORD PTR [rsp + FRAME_FLOATS + 5 * FLOAT_SLOT_SIZE], xmm5
	lea rcx, [rsp + HOOK_STACK + RETURN_ADDRESS + SHADOW_SPACE]
	mov [rsp + FRAME_STACK], rcx

	mov rcx, rax
	lea rdx, [rsp + FRAME_REGISTERS]
	call run_hook

	mov rcx, [rsp + FRAME_REGISTERS]
	mov rdx, [rsp + FRAME_REGISTERS + SLOT_SIZE]
	mov r8, [rsp + FRAME_REGISTERS + 2 * SLOT_SIZE]
	mov r9, [rsp + FRAME_REGISTERS + 3 * SLOT_SIZE]
	mov r10, [rsp + FRAME_REGISTERS + 4 * SLOT_SIZE]
	mov r11, [rsp + FRAME_REGISTERS + 5 * SLOT_SIZE]
	movdqu xmm0, XMMWORD PTR [rsp + FRAME_FLOATS]
	movdqu xmm1, XMMWORD PTR [rsp + FRAME_FLOATS + FLOAT_SLOT_SIZE]
	movdqu xmm2, XMMWORD PTR [rsp + FRAME_FLOATS + 2 * FLOAT_SLOT_SIZE]
	movdqu xmm3, XMMWORD PTR [rsp + FRAME_FLOATS + 3 * FLOAT_SLOT_SIZE]
	movdqu xmm4, XMMWORD PTR [rsp + FRAME_FLOATS + 4 * FLOAT_SLOT_SIZE]
	movdqu xmm5, XMMWORD PTR [rsp + FRAME_FLOATS + 5 * FLOAT_SLOT_SIZE]
	cmp eax, RUN_ORIGINAL
	je jump_to_original
	cmp eax, RETURN_FLOAT_RESULT
	mov rax, [rsp + FRAME_RESULT]
	jne return_result
	movlpd xmm0, QWORD PTR [rsp + FRAME_FLOAT_RESULT]
return_result:
	add rsp, HOOK_STACK
	ret

jump_to_original:
	mov rax, [rsp + FRAME_ORIGINAL]
	add rsp, HOOK_STACK
	jmp rax
hook_entry ENDP

END
