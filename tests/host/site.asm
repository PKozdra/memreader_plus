SLOT_SIZE equ 8
YMM_SIZE equ 32
XMM_SIZE equ 16
FLAGS_IN equ 16 * SLOT_SIZE
MISALIGN equ 17 * SLOT_SIZE
REGISTERS_OUT equ 18 * SLOT_SIZE
FLAGS_OUT equ 34 * SLOT_SIZE
RSP_AT_SITE equ 35 * SLOT_SIZE
VECTOR_OUT equ 16 * YMM_SIZE
XMM_OUT equ 6 * XMM_SIZE
SAVED_XMM equ 10 * XMM_SIZE
SAVED_XMM_FRAME equ SAVED_XMM + 8

PUBLIC site_target_here
PUBLIC site_far_here
PUBLIC site_overlap_here
PUBLIC site_overlap_b_here
PUBLIC site_flags_here
PUBLIC site_single_here
PUBLIC site_rip_here
PUBLIC site_inbound_here
PUBLIC site_ret_here
PUBLIC site_spin_here
PUBLIC site_probe_here
PUBLIC site_xmm_here
PUBLIC site_vector_here
PUBLIC site_crash_here
PUBLIC site_table_here
PUBLIC site_codetable_here
PUBLIC site_noise_here
PUBLIC site_call_short_here
PUBLIC site_call_last_here
PUBLIC site_leaf_here
PUBLIC site_leaf_mid_here
PUBLIC site_leaf_inbound_here
PUBLIC site_early_here
PUBLIC site_tail_here

.data

site_data dd 7
ALIGN 16
site_ones dq 0FFFFFFFFFFFFFFFFh, 0FFFFFFFFFFFFFFFFh
probe_scratch dq 0
probe_misaligned dq 0

.code

site_target PROC FRAME
	.endprolog
	mov r10d, ecx
	mov r11d, edx
site_target_here::
	lea eax, [r10 + r10 * 4]
	add eax, eax
	add eax, r11d
	ret
site_target ENDP

site_flags_target PROC FRAME
	.endprolog
	xor eax, eax
site_flags_here::
	mov edx, 1
	jz zero_flag
	mov eax, 2
	ret
zero_flag:
	mov eax, 1
	ret
site_flags_target ENDP

site_far PROC FRAME
	.endprolog
	mov eax, ecx
site_far_here::
	lea eax, [rax + rax]
	add eax, 1
	ret
site_far ENDP

site_overlap PROC FRAME
	.endprolog
	mov r10d, ecx
site_overlap_here::
	lea eax, [r10 + 4]
	add eax, 1
	ret
site_overlap ENDP

site_overlap_b PROC FRAME
	.endprolog
	mov r10d, ecx
site_overlap_b_here::
	lea eax, [r10 + 4]
	add eax, 1
	ret
site_overlap_b ENDP

site_single PROC FRAME
	.endprolog
site_single_here::
	lea rax, [rcx + rcx]
	add rax, 1
	ret
site_single ENDP

site_rip_target PROC FRAME
	.endprolog
site_rip_here::
	mov eax, DWORD PTR [site_data]
	add eax, ecx
	ret
site_rip_target ENDP

site_inbound PROC FRAME
	.endprolog
	xor eax, eax
	test ecx, ecx
	jnz site_inbound_middle
site_inbound_here::
	inc eax
site_inbound_middle:
	add eax, 2
	ret
site_inbound ENDP

site_ret PROC FRAME
	.endprolog
	nop
site_ret_here::
	ret
	int 3
	int 3
	int 3
	int 3
	int 3
site_ret ENDP

site_spin PROC FRAME
	.endprolog
site_spin_here::
	db 0Fh, 1Fh, 44h, 00h, 00h
	dec rcx
	jnz site_spin_here
	ret
site_spin ENDP

site_callee PROC FRAME
	.endprolog
	lea eax, [rcx + 1]
	ret
site_callee ENDP

site_call_short PROC FRAME
	sub rsp, 28h
	.allocstack 28h
	.endprolog
site_call_short_here::
	call rdx
	mov ecx, 1
	add eax, ecx
	add rsp, 28h
	ret
site_call_short ENDP

site_call_last PROC FRAME
	sub rsp, 28h
	.allocstack 28h
	.endprolog
site_call_last_here::
	xor edx, edx
	call site_callee
	add eax, 10
	add rsp, 28h
	ret
site_call_last ENDP

site_leaf PROC
	mov eax, ecx
site_leaf_here::
	lea eax, [rax + rax]
	add eax, 1
	ret
site_leaf ENDP

site_leaf_mid PROC
	mov eax, ecx
site_leaf_mid_here::
	lea eax, [rax + rax]
	add eax, 1
	ret
site_leaf_mid ENDP

site_leaf_inbound PROC
	xor eax, eax
	test ecx, ecx
	jnz site_leaf_inbound_middle
site_leaf_inbound_here::
	inc eax
site_leaf_inbound_middle:
	add eax, 2
	ret
site_leaf_inbound ENDP

site_early PROC FRAME
	.endprolog
	xor eax, eax
	jmp site_early_go
	db 06h, 06h, 06h
site_early_go:
site_early_here::
	db 0Fh, 1Fh, 44h, 00h, 00h
	inc eax
	ret
site_early ENDP

site_tail PROC FRAME
	.endprolog
	xor eax, eax
site_tail_here::
	mov eax, ecx
	ud2
site_tail ENDP

site_tail_next PROC FRAME
	.endprolog
	mov eax, 1
	ret
site_tail_next ENDP

site_probe PROC FRAME
	push rbx
	.pushreg rbx
	push rbp
	.pushreg rbp
	push rsi
	.pushreg rsi
	push rdi
	.pushreg rdi
	push r12
	.pushreg r12
	push r13
	.pushreg r13
	push r14
	.pushreg r14
	push r15
	.pushreg r15
	sub rsp, SLOT_SIZE
	.allocstack SLOT_SIZE
	.endprolog

	mov rax, rcx
	mov probe_scratch, rax
	mov rdx, [rax + MISALIGN]
	mov probe_misaligned, rdx
	test rdx, rdx
	jz stack_aligned
	lea rsp, [rsp - SLOT_SIZE]
stack_aligned:
	push QWORD PTR [rax + FLAGS_IN]
	popfq
	mov rcx, [rax + 1 * SLOT_SIZE]
	mov rdx, [rax + 2 * SLOT_SIZE]
	mov rbx, [rax + 3 * SLOT_SIZE]
	mov rbp, [rax + 5 * SLOT_SIZE]
	mov rsi, [rax + 6 * SLOT_SIZE]
	mov rdi, [rax + 7 * SLOT_SIZE]
	mov r8, [rax + 8 * SLOT_SIZE]
	mov r9, [rax + 9 * SLOT_SIZE]
	mov r10, [rax + 10 * SLOT_SIZE]
	mov r11, [rax + 11 * SLOT_SIZE]
	mov r12, [rax + 12 * SLOT_SIZE]
	mov r13, [rax + 13 * SLOT_SIZE]
	mov r14, [rax + 14 * SLOT_SIZE]
	mov r15, [rax + 15 * SLOT_SIZE]
	mov [rax + RSP_AT_SITE], rsp
	mov rax, [rax]
site_probe_here::
	db 0Fh, 1Fh, 44h, 00h, 00h
	xchg rax, QWORD PTR [probe_scratch]
	pushfq
	pop QWORD PTR [rax + FLAGS_OUT]
	mov [rax + REGISTERS_OUT + 1 * SLOT_SIZE], rcx
	mov [rax + REGISTERS_OUT + 2 * SLOT_SIZE], rdx
	mov [rax + REGISTERS_OUT + 3 * SLOT_SIZE], rbx
	mov [rax + REGISTERS_OUT + 4 * SLOT_SIZE], rsp
	mov [rax + REGISTERS_OUT + 5 * SLOT_SIZE], rbp
	mov [rax + REGISTERS_OUT + 6 * SLOT_SIZE], rsi
	mov [rax + REGISTERS_OUT + 7 * SLOT_SIZE], rdi
	mov [rax + REGISTERS_OUT + 8 * SLOT_SIZE], r8
	mov [rax + REGISTERS_OUT + 9 * SLOT_SIZE], r9
	mov [rax + REGISTERS_OUT + 10 * SLOT_SIZE], r10
	mov [rax + REGISTERS_OUT + 11 * SLOT_SIZE], r11
	mov [rax + REGISTERS_OUT + 12 * SLOT_SIZE], r12
	mov [rax + REGISTERS_OUT + 13 * SLOT_SIZE], r13
	mov [rax + REGISTERS_OUT + 14 * SLOT_SIZE], r14
	mov [rax + REGISTERS_OUT + 15 * SLOT_SIZE], r15
	mov rcx, QWORD PTR [probe_scratch]
	mov [rax + REGISTERS_OUT], rcx
	cmp QWORD PTR [probe_misaligned], 0
	je stack_restored
	lea rsp, [rsp + SLOT_SIZE]
stack_restored:
	add rsp, SLOT_SIZE
	pop r15
	pop r14
	pop r13
	pop r12
	pop rdi
	pop rsi
	pop rbp
	pop rbx
	ret
site_probe ENDP

site_xmm_probe PROC FRAME
	.endprolog
	movdqu xmm0, XMMWORD PTR [rcx]
	movdqu xmm1, XMMWORD PTR [rcx + 1 * XMM_SIZE]
	movdqu xmm2, XMMWORD PTR [rcx + 2 * XMM_SIZE]
	movdqu xmm3, XMMWORD PTR [rcx + 3 * XMM_SIZE]
	movdqu xmm4, XMMWORD PTR [rcx + 4 * XMM_SIZE]
	movdqu xmm5, XMMWORD PTR [rcx + 5 * XMM_SIZE]
site_xmm_here::
	db 0Fh, 1Fh, 44h, 00h, 00h
	movdqu XMMWORD PTR [rcx + XMM_OUT], xmm0
	movdqu XMMWORD PTR [rcx + XMM_OUT + 1 * XMM_SIZE], xmm1
	movdqu XMMWORD PTR [rcx + XMM_OUT + 2 * XMM_SIZE], xmm2
	movdqu XMMWORD PTR [rcx + XMM_OUT + 3 * XMM_SIZE], xmm3
	movdqu XMMWORD PTR [rcx + XMM_OUT + 4 * XMM_SIZE], xmm4
	movdqu XMMWORD PTR [rcx + XMM_OUT + 5 * XMM_SIZE], xmm5
	ret
site_xmm_probe ENDP

site_vector_probe PROC FRAME
	sub rsp, SAVED_XMM_FRAME
	.allocstack SAVED_XMM_FRAME
	.endprolog
	movdqu XMMWORD PTR [rsp + 0 * XMM_SIZE], xmm6
	movdqu XMMWORD PTR [rsp + 1 * XMM_SIZE], xmm7
	movdqu XMMWORD PTR [rsp + 2 * XMM_SIZE], xmm8
	movdqu XMMWORD PTR [rsp + 3 * XMM_SIZE], xmm9
	movdqu XMMWORD PTR [rsp + 4 * XMM_SIZE], xmm10
	movdqu XMMWORD PTR [rsp + 5 * XMM_SIZE], xmm11
	movdqu XMMWORD PTR [rsp + 6 * XMM_SIZE], xmm12
	movdqu XMMWORD PTR [rsp + 7 * XMM_SIZE], xmm13
	movdqu XMMWORD PTR [rsp + 8 * XMM_SIZE], xmm14
	movdqu XMMWORD PTR [rsp + 9 * XMM_SIZE], xmm15
	vmovups ymm0, YMMWORD PTR [rcx + 0 * YMM_SIZE]
	vmovups ymm1, YMMWORD PTR [rcx + 1 * YMM_SIZE]
	vmovups ymm2, YMMWORD PTR [rcx + 2 * YMM_SIZE]
	vmovups ymm3, YMMWORD PTR [rcx + 3 * YMM_SIZE]
	vmovups ymm4, YMMWORD PTR [rcx + 4 * YMM_SIZE]
	vmovups ymm5, YMMWORD PTR [rcx + 5 * YMM_SIZE]
	vmovups ymm6, YMMWORD PTR [rcx + 6 * YMM_SIZE]
	vmovups ymm7, YMMWORD PTR [rcx + 7 * YMM_SIZE]
	vmovups ymm8, YMMWORD PTR [rcx + 8 * YMM_SIZE]
	vmovups ymm9, YMMWORD PTR [rcx + 9 * YMM_SIZE]
	vmovups ymm10, YMMWORD PTR [rcx + 10 * YMM_SIZE]
	vmovups ymm11, YMMWORD PTR [rcx + 11 * YMM_SIZE]
	vmovups ymm12, YMMWORD PTR [rcx + 12 * YMM_SIZE]
	vmovups ymm13, YMMWORD PTR [rcx + 13 * YMM_SIZE]
	vmovups ymm14, YMMWORD PTR [rcx + 14 * YMM_SIZE]
	vmovups ymm15, YMMWORD PTR [rcx + 15 * YMM_SIZE]
site_vector_here::
	db 0Fh, 1Fh, 44h, 00h, 00h
	vmovups YMMWORD PTR [rcx + VECTOR_OUT + 0 * YMM_SIZE], ymm0
	vmovups YMMWORD PTR [rcx + VECTOR_OUT + 1 * YMM_SIZE], ymm1
	vmovups YMMWORD PTR [rcx + VECTOR_OUT + 2 * YMM_SIZE], ymm2
	vmovups YMMWORD PTR [rcx + VECTOR_OUT + 3 * YMM_SIZE], ymm3
	vmovups YMMWORD PTR [rcx + VECTOR_OUT + 4 * YMM_SIZE], ymm4
	vmovups YMMWORD PTR [rcx + VECTOR_OUT + 5 * YMM_SIZE], ymm5
	vmovups YMMWORD PTR [rcx + VECTOR_OUT + 6 * YMM_SIZE], ymm6
	vmovups YMMWORD PTR [rcx + VECTOR_OUT + 7 * YMM_SIZE], ymm7
	vmovups YMMWORD PTR [rcx + VECTOR_OUT + 8 * YMM_SIZE], ymm8
	vmovups YMMWORD PTR [rcx + VECTOR_OUT + 9 * YMM_SIZE], ymm9
	vmovups YMMWORD PTR [rcx + VECTOR_OUT + 10 * YMM_SIZE], ymm10
	vmovups YMMWORD PTR [rcx + VECTOR_OUT + 11 * YMM_SIZE], ymm11
	vmovups YMMWORD PTR [rcx + VECTOR_OUT + 12 * YMM_SIZE], ymm12
	vmovups YMMWORD PTR [rcx + VECTOR_OUT + 13 * YMM_SIZE], ymm13
	vmovups YMMWORD PTR [rcx + VECTOR_OUT + 14 * YMM_SIZE], ymm14
	vmovups YMMWORD PTR [rcx + VECTOR_OUT + 15 * YMM_SIZE], ymm15
	vzeroupper
	movdqu xmm6, XMMWORD PTR [rsp + 0 * XMM_SIZE]
	movdqu xmm7, XMMWORD PTR [rsp + 1 * XMM_SIZE]
	movdqu xmm8, XMMWORD PTR [rsp + 2 * XMM_SIZE]
	movdqu xmm9, XMMWORD PTR [rsp + 3 * XMM_SIZE]
	movdqu xmm10, XMMWORD PTR [rsp + 4 * XMM_SIZE]
	movdqu xmm11, XMMWORD PTR [rsp + 5 * XMM_SIZE]
	movdqu xmm12, XMMWORD PTR [rsp + 6 * XMM_SIZE]
	movdqu xmm13, XMMWORD PTR [rsp + 7 * XMM_SIZE]
	movdqu xmm14, XMMWORD PTR [rsp + 8 * XMM_SIZE]
	movdqu xmm15, XMMWORD PTR [rsp + 9 * XMM_SIZE]
	add rsp, SAVED_XMM_FRAME
	ret
site_vector_probe ENDP

site_crash PROC FRAME
	.endprolog
	db 291 dup (90h)
site_crash_here::
	db 0Fh, 1Fh, 44h, 00h, 00h
	ret
site_crash ENDP

site_table PROC FRAME
	.endprolog
	xor eax, eax
site_table_here::
	db 0Fh, 1Fh, 44h
site_table_inside::
	db 00h, 00h
	inc eax
	ret
site_table ENDP

site_noise PROC FRAME
	.endprolog
	xor eax, eax
site_noise_here::
	db 0Fh, 1Fh, 44h
site_noise_inside::
	db 00h, 00h
	inc eax
	ret
site_noise ENDP

site_codetable PROC FRAME
	.endprolog
	xor eax, eax
site_codetable_here::
	db 0Fh, 1Fh, 44h
site_codetable_inside::
	db 00h, 00h
	ret
	ALIGN 4
	dd IMAGEREL site_codetable_inside
site_codetable ENDP

dirty_vectors PROC
	vinsertf128 ymm0, ymm0, XMMWORD PTR [site_ones], 1
	vinsertf128 ymm1, ymm1, XMMWORD PTR [site_ones], 1
	vinsertf128 ymm2, ymm2, XMMWORD PTR [site_ones], 1
	vinsertf128 ymm3, ymm3, XMMWORD PTR [site_ones], 1
	vinsertf128 ymm4, ymm4, XMMWORD PTR [site_ones], 1
	vinsertf128 ymm5, ymm5, XMMWORD PTR [site_ones], 1
	vinsertf128 ymm6, ymm6, XMMWORD PTR [site_ones], 1
	vinsertf128 ymm7, ymm7, XMMWORD PTR [site_ones], 1
	vinsertf128 ymm8, ymm8, XMMWORD PTR [site_ones], 1
	vinsertf128 ymm9, ymm9, XMMWORD PTR [site_ones], 1
	vinsertf128 ymm10, ymm10, XMMWORD PTR [site_ones], 1
	vinsertf128 ymm11, ymm11, XMMWORD PTR [site_ones], 1
	vinsertf128 ymm12, ymm12, XMMWORD PTR [site_ones], 1
	vinsertf128 ymm13, ymm13, XMMWORD PTR [site_ones], 1
	vinsertf128 ymm14, ymm14, XMMWORD PTR [site_ones], 1
	vinsertf128 ymm15, ymm15, XMMWORD PTR [site_ones], 1
	ret
dirty_vectors ENDP

.const

site_table_entries dd IMAGEREL site_table, IMAGEREL site_table_inside, IMAGEREL site_codetable
site_noise_entry dd 0, IMAGEREL site_noise_inside, 0

END
