PUBLIC asm_float_here
PUBLIC asm_call_here
PUBLIC asm_site_here
PUBLIC asm_site_b_here
PUBLIC asm_site_c_here
PUBLIC asm_site_d_here
PUBLIC asm_site_e_here
PUBLIC asm_site_f_here
PUBLIC asm_site_g_here
PUBLIC asm_site_h_here
PUBLIC asm_site_i_here
PUBLIC asm_site_j_here
PUBLIC asm_site_k_here
PUBLIC many_site_0

.code

asm_double PROC
	lea eax, [rcx + rcx]
	ret
asm_double ENDP

asm_float PROC FRAME
	push rbx
	.pushreg rbx
	sub rsp, 96
	.allocstack 96
	movaps xmmword ptr [rsp + 50h], xmm6
	.savexmm128 xmm6, 50h
	.endprolog
	mov ebx, ecx
	movaps xmm6, xmm1
	movss dword ptr [rsp + 44h], xmm2
	xorps xmm0, xmm0
asm_float_here::
	addss xmm0, dword ptr [rsp + 44h]
	movaps xmm6, xmmword ptr [rsp + 50h]
	add rsp, 96
	pop rbx
	ret
asm_float ENDP

asm_call PROC FRAME
	sub rsp, 40
	.allocstack 40
	.endprolog
	mov eax, ecx
asm_call_here::
	add eax, 1000
	add rsp, 40
	ret
asm_call ENDP

asm_site PROC FRAME
	.endprolog
	mov eax, ecx
	imul eax, eax, 3
asm_site_here::
	add eax, 2001
	ret
asm_site ENDP

asm_site_b PROC FRAME
	.endprolog
	mov eax, ecx
	mov edx, 7
	imul eax, edx
asm_site_b_here::
	add eax, 3001
	ret
asm_site_b ENDP

asm_site_c PROC FRAME
	.endprolog
	lea eax, [rcx + 5]
asm_site_c_here::
	add eax, 4001
	ret
asm_site_c ENDP

asm_site_d PROC FRAME
	.endprolog
	lea eax, [rcx + 6]
asm_site_d_here::
	add eax, 5001
	ret
asm_site_d ENDP

asm_site_e PROC FRAME
	.endprolog
	lea eax, [rcx + 7]
asm_site_e_here::
	add eax, 6001
	ret
asm_site_e ENDP

asm_site_f PROC FRAME
	.endprolog
	lea eax, [rcx + 8]
asm_site_f_here::
	add eax, 7001
	ret
asm_site_f ENDP

asm_site_g PROC FRAME
	.endprolog
	lea eax, [rcx + 9]
asm_site_g_here::
	add eax, 8001
	ret
asm_site_g ENDP

asm_site_h PROC FRAME
	.endprolog
	lea eax, [rcx + 10]
asm_site_h_here::
	add eax, 9001
	ret
asm_site_h ENDP

asm_site_i PROC FRAME
	.endprolog
	lea eax, [rcx + 11]
asm_site_i_here::
	add eax, 10001
	ret
asm_site_i ENDP

asm_site_j PROC FRAME
	.endprolog
	lea eax, [rcx + 12]
asm_site_j_here::
	add eax, 11001
	ret
asm_site_j ENDP

asm_site_k PROC FRAME
	.endprolog
	lea eax, [rcx + 13]
asm_site_k_here::
	add eax, 12001
	ret
asm_site_k ENDP

many_site MACRO number
	ALIGN 16
many_site_&number PROC FRAME
	.endprolog
	lea eax, [rcx + number + 1]
	add eax, 1000
	ret
many_site_&number ENDP
ENDM

site_number = 0
REPT 64
	many_site %site_number
	site_number = site_number + 1
ENDM

END
