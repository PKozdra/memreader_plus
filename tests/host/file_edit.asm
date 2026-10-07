EXTERN host_open_file:PROC
EXTERN host_load_buffer:PROC
EXTERN host_parse_buffer:PROC
EXTERN host_load_layout:PROC
EXTERN host_fast_xml:PROC
EXTERN host_clear_from_cache:PROC

PUBLIC fake_load_buffer
PUBLIC fake_open_file
PUBLIC fake_parse_buffer
PUBLIC fake_new_document
PUBLIC fake_destroy_document
PUBLIC fake_load_layout_file
PUBLIC fake_new_fast_xml
PUBLIC fake_clear_from_cache
PUBLIC spare_sites

.data

document_table dq 16 dup (0)

.code

nothing PROC
	ret
nothing ENDP

set_document PROC
	lea rax, document_table
	mov qword ptr [rcx], rax
	ret
set_document ENDP

fake_load_buffer PROC
	db 48h, 89h, 5Ch, 24h, 08h
	db 48h, 89h, 6Ch, 24h, 10h
	db 48h, 89h, 74h, 24h, 18h
	db 57h
	db 48h, 83h, 0ECh, 30h
	db 49h, 8Bh, 0F9h
	db 49h, 8Bh, 0F0h
	db 48h, 8Bh, 0EAh
	db 48h, 8Bh, 0D9h
	call nothing
	db 48h, 8Bh, 0CBh
	call nothing
	db 4Ch, 8Bh, 03h
	mov rax, qword ptr [rsp + 60h]
	mov qword ptr [rsp + 20h], rax
	mov eax, dword ptr [rsp + 68h]
	mov qword ptr [rsp + 28h], rax
	mov rcx, rbx
	mov rdx, rbp
	mov r8, rsi
	mov r9, rdi
	call host_load_buffer
	add rsp, 30h
	pop rdi
	mov rbx, qword ptr [rsp + 8]
	mov rbp, qword ptr [rsp + 10h]
	mov rsi, qword ptr [rsp + 18h]
	ret
fake_load_buffer ENDP

fake_open_file PROC
	db 4Ch, 8Bh, 0DCh
	db 49h, 89h, 5Bh, 10h
	db 49h, 89h, 73h, 18h
	db 49h, 89h, 7Bh, 20h
	db 49h, 89h, 4Bh, 08h
	db 55h
	db 41h, 56h
	db 41h, 57h
	db 48h, 8Bh, 0ECh
	db 48h, 83h, 0ECh, 20h
	db 45h, 33h, 0FFh
	call host_open_file
	add rsp, 20h
	pop r15
	pop r14
	pop rbp
	ret
fake_open_file ENDP

fake_parse_buffer PROC
	db 48h, 89h, 5Ch, 24h, 08h
	db 48h, 89h, 74h, 24h, 10h
	db 57h
	db 48h, 83h, 0ECh, 20h
	db 41h, 8Bh, 0F8h
	db 48h, 8Bh, 0D9h
	db 48h, 8Bh, 0F2h
	db 8Dh, 4Fh, 01h
	call nothing
	db 48h, 8Bh, 4Bh, 08h
	mov rcx, rbx
	mov rdx, rsi
	mov r8d, edi
	call host_parse_buffer
	add rsp, 20h
	pop rdi
	mov rbx, qword ptr [rsp + 8]
	mov rsi, qword ptr [rsp + 10h]
	ret
fake_parse_buffer ENDP

fake_new_document PROC
	db 48h, 83h, 0ECh, 28h
	db 48h, 83h, 21h, 00h
	db 4Ch, 8Bh, 0D1h
	db 48h, 83h, 61h, 08h, 00h
	call set_document
	db 49h, 8Bh, 0C2h
	db 48h, 83h, 0C4h, 28h
	db 0C3h
	db 0CCh, 0CCh, 0CCh
	db 45h, 33h, 0C9h
	ret
fake_new_document ENDP

fake_destroy_document PROC
	db 48h, 89h, 5Ch, 24h, 08h
	db 57h
	db 48h, 83h, 0ECh, 20h
	db 48h, 8Bh, 0F9h
	db 48h, 8Bh, 49h, 08h
	db 48h, 85h, 0C9h
	db 0Fh, 85h, 00h, 00h, 00h, 00h
	db 48h, 8Bh, 07h
	db 48h, 8Bh, 58h, 58h
	add rsp, 20h
	pop rdi
	mov rbx, qword ptr [rsp + 8]
	ret
fake_destroy_document ENDP

fake_load_layout_file PROC
	db 48h, 89h, 5Ch, 24h, 08h
	db 4Ch, 89h, 44h, 24h, 18h
	db 55h, 56h, 57h, 41h, 54h, 41h, 55h, 41h, 56h, 41h, 57h
	db 48h, 8Dh, 0ACh, 24h, 0E0h, 0FDh, 0FFh, 0FFh
	db 48h, 81h, 0ECh, 20h, 03h, 00h, 00h
	call host_load_layout
	add rsp, 320h
	pop r15
	pop r14
	pop r13
	pop r12
	pop rdi
	pop rsi
	pop rbp
	mov rbx, qword ptr [rsp + 8]
	ret
fake_load_layout_file ENDP

fake_new_fast_xml PROC
	db 48h, 89h, 5Ch, 24h, 10h
	db 48h, 89h, 74h, 24h, 18h
	db 57h
	db 48h, 83h, 0ECh, 20h
	db 33h, 0FFh
	db 48h, 8Bh, 0F1h
	db 40h, 88h, 39h
	db 48h, 8Bh, 0DAh
	db 48h, 89h, 79h, 08h
	db 0B9h, 10h, 00h, 00h, 00h
	call nothing
	mov rcx, rsi
	mov rdx, rbx
	call host_fast_xml
	mov rax, rsi
	add rsp, 20h
	pop rdi
	mov rbx, qword ptr [rsp + 10h]
	mov rsi, qword ptr [rsp + 18h]
	ret
fake_new_fast_xml ENDP

fake_clear_from_cache PROC
	db 48h, 89h, 5Ch, 24h, 08h
	db 57h
	db 48h, 83h, 0ECh, 30h
	db 48h, 8Bh, 0DAh
	call nothing
	db 44h, 8Bh, 0C8h
	db 48h, 8Dh, 54h, 24h, 20h
	db 4Ch, 8Bh, 0C3h
	db 8Bh, 0F8h
	call host_clear_from_cache
	add rsp, 30h
	pop rdi
	mov rbx, qword ptr [rsp + 8]
	ret
fake_clear_from_cache ENDP

spare_sites PROC
	db 1024 dup (0CCh)
spare_sites ENDP

END
