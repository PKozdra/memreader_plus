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
SITE_FLOATS equ 0
SITE_UPPER equ 96
SITE_UPPER_USED equ 352
SITE_SAVE equ 368
SITE_RSP equ SITE_SAVE + 4 * SLOT_SIZE
SITE_ORIGINAL_RSP equ 512
SITE_FRAME_ALIGN equ -16

EXTERN run_hook:PROC
EXTERN run_site:PROC
EXTERN site_avx:BYTE

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

site_entry PROC FRAME
	pushfq
	.allocstack SLOT_SIZE
	push r15
	.pushreg r15
	push r14
	.pushreg r14
	push r13
	.pushreg r13
	push r12
	.pushreg r12
	push r11
	.pushreg r11
	push r10
	.pushreg r10
	push r9
	.pushreg r9
	push r8
	.pushreg r8
	push rdi
	.pushreg rdi
	push rsi
	.pushreg rsi
	push rbp
	.pushreg rbp
	sub rsp, SLOT_SIZE
	.allocstack SLOT_SIZE
	push rbx
	.pushreg rbx
	push rdx
	.pushreg rdx
	push rcx
	.pushreg rcx
	push rax
	.pushreg rax
	sub rsp, SITE_SAVE
	.allocstack SITE_SAVE
	mov rbp, rsp
	.setframe rbp, 0
	.endprolog

	movdqu XMMWORD PTR [rbp + SITE_FLOATS + 0 * FLOAT_SLOT_SIZE], xmm0
	movdqu XMMWORD PTR [rbp + SITE_FLOATS + 1 * FLOAT_SLOT_SIZE], xmm1
	movdqu XMMWORD PTR [rbp + SITE_FLOATS + 2 * FLOAT_SLOT_SIZE], xmm2
	movdqu XMMWORD PTR [rbp + SITE_FLOATS + 3 * FLOAT_SLOT_SIZE], xmm3
	movdqu XMMWORD PTR [rbp + SITE_FLOATS + 4 * FLOAT_SLOT_SIZE], xmm4
	movdqu XMMWORD PTR [rbp + SITE_FLOATS + 5 * FLOAT_SLOT_SIZE], xmm5
	cmp BYTE PTR [site_avx], 0
	je vectors_saved
	vextractf128 XMMWORD PTR [rbp + SITE_UPPER + 0 * FLOAT_SLOT_SIZE], ymm0, 1
	vextractf128 XMMWORD PTR [rbp + SITE_UPPER + 1 * FLOAT_SLOT_SIZE], ymm1, 1
	vextractf128 XMMWORD PTR [rbp + SITE_UPPER + 2 * FLOAT_SLOT_SIZE], ymm2, 1
	vextractf128 XMMWORD PTR [rbp + SITE_UPPER + 3 * FLOAT_SLOT_SIZE], ymm3, 1
	vextractf128 XMMWORD PTR [rbp + SITE_UPPER + 4 * FLOAT_SLOT_SIZE], ymm4, 1
	vextractf128 XMMWORD PTR [rbp + SITE_UPPER + 5 * FLOAT_SLOT_SIZE], ymm5, 1
	vextractf128 XMMWORD PTR [rbp + SITE_UPPER + 6 * FLOAT_SLOT_SIZE], ymm6, 1
	vextractf128 XMMWORD PTR [rbp + SITE_UPPER + 7 * FLOAT_SLOT_SIZE], ymm7, 1
	vextractf128 XMMWORD PTR [rbp + SITE_UPPER + 8 * FLOAT_SLOT_SIZE], ymm8, 1
	vextractf128 XMMWORD PTR [rbp + SITE_UPPER + 9 * FLOAT_SLOT_SIZE], ymm9, 1
	vextractf128 XMMWORD PTR [rbp + SITE_UPPER + 10 * FLOAT_SLOT_SIZE], ymm10, 1
	vextractf128 XMMWORD PTR [rbp + SITE_UPPER + 11 * FLOAT_SLOT_SIZE], ymm11, 1
	vextractf128 XMMWORD PTR [rbp + SITE_UPPER + 12 * FLOAT_SLOT_SIZE], ymm12, 1
	vextractf128 XMMWORD PTR [rbp + SITE_UPPER + 13 * FLOAT_SLOT_SIZE], ymm13, 1
	vextractf128 XMMWORD PTR [rbp + SITE_UPPER + 14 * FLOAT_SLOT_SIZE], ymm14, 1
	vextractf128 XMMWORD PTR [rbp + SITE_UPPER + 15 * FLOAT_SLOT_SIZE], ymm15, 1
	vzeroupper
vectors_saved:
	lea rax, [rbp + SITE_ORIGINAL_RSP]
	mov [rbp + SITE_RSP], rax
	mov rcx, rbp
	cld
	and rsp, SITE_FRAME_ALIGN
	sub rsp, SHADOW_SPACE
	call run_site
	mov rsp, rbp
	movdqu xmm0, XMMWORD PTR [rbp + SITE_FLOATS + 0 * FLOAT_SLOT_SIZE]
	movdqu xmm1, XMMWORD PTR [rbp + SITE_FLOATS + 1 * FLOAT_SLOT_SIZE]
	movdqu xmm2, XMMWORD PTR [rbp + SITE_FLOATS + 2 * FLOAT_SLOT_SIZE]
	movdqu xmm3, XMMWORD PTR [rbp + SITE_FLOATS + 3 * FLOAT_SLOT_SIZE]
	movdqu xmm4, XMMWORD PTR [rbp + SITE_FLOATS + 4 * FLOAT_SLOT_SIZE]
	movdqu xmm5, XMMWORD PTR [rbp + SITE_FLOATS + 5 * FLOAT_SLOT_SIZE]
	cmp BYTE PTR [site_avx], 0
	je vectors_restored
	cmp QWORD PTR [rbp + SITE_UPPER_USED], 0
	jne restore_upper
	vzeroupper
	jmp vectors_restored
restore_upper:
	vinsertf128 ymm0, ymm0, XMMWORD PTR [rbp + SITE_UPPER + 0 * FLOAT_SLOT_SIZE], 1
	vinsertf128 ymm1, ymm1, XMMWORD PTR [rbp + SITE_UPPER + 1 * FLOAT_SLOT_SIZE], 1
	vinsertf128 ymm2, ymm2, XMMWORD PTR [rbp + SITE_UPPER + 2 * FLOAT_SLOT_SIZE], 1
	vinsertf128 ymm3, ymm3, XMMWORD PTR [rbp + SITE_UPPER + 3 * FLOAT_SLOT_SIZE], 1
	vinsertf128 ymm4, ymm4, XMMWORD PTR [rbp + SITE_UPPER + 4 * FLOAT_SLOT_SIZE], 1
	vinsertf128 ymm5, ymm5, XMMWORD PTR [rbp + SITE_UPPER + 5 * FLOAT_SLOT_SIZE], 1
	vinsertf128 ymm6, ymm6, XMMWORD PTR [rbp + SITE_UPPER + 6 * FLOAT_SLOT_SIZE], 1
	vinsertf128 ymm7, ymm7, XMMWORD PTR [rbp + SITE_UPPER + 7 * FLOAT_SLOT_SIZE], 1
	vinsertf128 ymm8, ymm8, XMMWORD PTR [rbp + SITE_UPPER + 8 * FLOAT_SLOT_SIZE], 1
	vinsertf128 ymm9, ymm9, XMMWORD PTR [rbp + SITE_UPPER + 9 * FLOAT_SLOT_SIZE], 1
	vinsertf128 ymm10, ymm10, XMMWORD PTR [rbp + SITE_UPPER + 10 * FLOAT_SLOT_SIZE], 1
	vinsertf128 ymm11, ymm11, XMMWORD PTR [rbp + SITE_UPPER + 11 * FLOAT_SLOT_SIZE], 1
	vinsertf128 ymm12, ymm12, XMMWORD PTR [rbp + SITE_UPPER + 12 * FLOAT_SLOT_SIZE], 1
	vinsertf128 ymm13, ymm13, XMMWORD PTR [rbp + SITE_UPPER + 13 * FLOAT_SLOT_SIZE], 1
	vinsertf128 ymm14, ymm14, XMMWORD PTR [rbp + SITE_UPPER + 14 * FLOAT_SLOT_SIZE], 1
	vinsertf128 ymm15, ymm15, XMMWORD PTR [rbp + SITE_UPPER + 15 * FLOAT_SLOT_SIZE], 1
vectors_restored:
	add rsp, SITE_SAVE
	pop rax
	pop rcx
	pop rdx
	pop rbx
	add rsp, SLOT_SIZE
	pop rbp
	pop rsi
	pop rdi
	pop r8
	pop r9
	pop r10
	pop r11
	pop r12
	pop r13
	pop r14
	pop r15
	popfq
	ret
site_entry ENDP

END
