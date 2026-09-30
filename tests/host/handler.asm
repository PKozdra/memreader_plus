FRAME_OFFSET equ 200h
LOCALS_SIZE equ 40h
EXCEPTION_CONTINUE_SEARCH equ 0

EXTERN write_game_crash_file:PROC

.data

crash_in_progress db 0

.code

game_crash_handler PROC
	mov [rsp + 8], rbx
	push rbp
	push rsi
	push rdi
	push r12
	push r13
	push r14
	push r15
	lea rbp, [rsp - FRAME_OFFSET]
	mov eax, LOCALS_SIZE
	call probe_stack
	sub rsp, rax
	xor r12d, r12d
	mov r14, rdx
	cmp crash_in_progress, r12b
	mov ebx, ecx
	je first_crash
	or rcx, -1
	call end_process
	int 3
first_crash:
	mov eax, 0C000008Dh
	call write_game_crash_file
	mov eax, EXCEPTION_CONTINUE_SEARCH
	lea rsp, [rbp + FRAME_OFFSET]
	pop r15
	pop r14
	pop r13
	pop r12
	pop rdi
	pop rsi
	pop rbp
	mov rbx, [rsp + 8]
	ret
game_crash_handler ENDP

probe_stack PROC
	ret
probe_stack ENDP

end_process PROC
	ret
end_process ENDP

END
