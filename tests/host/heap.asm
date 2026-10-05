EXTERN host_game_malloc:PROC
EXTERN host_game_free:PROC
EXTERN host_string_construct:PROC
EXTERN host_string_release:PROC
EXTERN host_unistring_construct:PROC
EXTERN host_vfs:PROC
EXTERN host_file_name:PROC
EXTERN host_file_exists:PROC
EXTERN host_open_file:PROC
EXTERN host_emplace:PROC

PUBLIC host_empty_string

.data

host_init_guard dd 0
free_tracking dq 0
host_empty_string db 16 dup (0)
host_empty_wide db 16 dup (0)

.code

fake_custom_malloc PROC
	mov qword ptr [rsp + 8], rbx
	db 57h
	db 48h, 83h, 0ECh, 30h
	db 65h, 48h, 8Bh, 04h, 25h, 58h, 00h, 00h, 00h
	db 48h, 8Bh, 0F9h
	db 0B9h, 18h, 00h, 00h, 00h
	db 48h, 8Bh, 10h
	db 8Bh, 04h, 11h
	cmp dword ptr host_init_guard, eax
	db 7Fh, 00h
	db 48h, 8Bh, 0CFh
	call host_game_malloc
	db 48h, 8Bh, 0D8h
	db 48h, 85h, 0C0h
	mov rbx, qword ptr [rsp + 48h]
	add rsp, 30h
	pop rdi
	ret
fake_custom_malloc ENDP

fake_custom_free PROC
	db 48h, 85h, 0C9h
	jz SHORT done
	db 53h
	db 48h, 83h, 0ECh, 20h
	db 48h, 8Bh, 0D9h
	call host_game_free
	mov rax, qword ptr free_tracking
	db 48h, 85h, 0C0h
	jnz SHORT tracked
back:
	db 48h, 83h, 0C4h, 20h
	db 5Bh
done:
	db 0C3h
tracked:
	db 33h, 0D2h
	db 48h, 8Bh, 0CBh
	db 0FFh, 0D0h
	jmp SHORT back
fake_custom_free ENDP

fake_custom_free_twin PROC
	db 48h, 85h, 0C9h
	jz SHORT done
	db 53h
	db 48h, 83h, 0ECh, 20h
	db 48h, 8Bh, 0D9h
	call host_game_free
	mov rax, qword ptr free_tracking
	db 48h, 85h, 0C0h
	jnz SHORT tracked
back:
	db 48h, 83h, 0C4h, 20h
	db 5Bh
done:
	db 0C3h
tracked:
	db 33h, 0D2h
	db 48h, 8Bh, 0CBh
	db 0FFh, 0D0h
	jmp SHORT back
fake_custom_free_twin ENDP

fake_string_constructor PROC
	db 40h, 53h
	db 48h, 83h, 0ECh, 20h
	db 48h, 8Bh, 0D9h
	db 48h, 0C7h, 41h, 08h, 00h, 00h, 00h, 00h
	db 48h, 0C7h, 0C0h, 0FFh, 0FFh, 0FFh, 0FFh
	db 0Fh, 1Fh, 84h, 00h, 00h, 00h, 00h, 00h
	db 48h, 0FFh, 0C0h
	call host_string_construct
	mov rax, rbx
	add rsp, 20h
	pop rbx
	ret
fake_string_constructor ENDP

fake_string_destructor PROC
	db 40h, 53h
	db 48h, 83h, 0ECh, 20h
	db 48h, 8Bh, 59h, 08h
	lea rax, host_empty_string
	db 48h, 3Bh, 0D8h
	db 74h, 38h
	db 48h, 8Bh, 0C3h
	db 48h, 0B9h, 00h, 00h, 00h, 00h, 00h, 00h, 00h, 0F0h
	db 48h, 23h, 0C1h
	db 48h, 8Bh, 0CBh
	call host_string_release
	db 32 dup (90h)
done:
	add rsp, 20h
	pop rbx
	ret
fake_string_destructor ENDP

fake_unistring_constructor PROC
	db 40h, 53h
	db 48h, 83h, 0ECh, 20h
	db 48h, 8Bh, 0D9h
	db 4Ch, 8Bh, 0C2h
	db 33h, 0C9h
	db 48h, 89h, 4Bh, 08h
	db 41h, 0Fh, 0B7h, 00h
	db 49h, 83h, 0C0h, 02h
	db 66h, 85h, 0C0h
	db 75h, 0F3h
	db 4Ch, 2Bh, 0C2h
	mov rcx, rbx
	call host_unistring_construct
	mov rax, rbx
	add rsp, 20h
	pop rbx
	ret
fake_unistring_constructor ENDP

fake_unistring_destructor PROC
	db 40h, 53h
	db 48h, 83h, 0ECh, 30h
	db 48h, 8Bh, 59h, 08h
	lea rax, host_empty_wide
	db 48h, 3Bh, 0D8h
	db 74h, 47h
	db 48h, 0B9h, 00h, 00h, 00h, 00h, 00h, 00h, 00h, 0F0h
	db 48h, 8Bh, 0C3h
	db 48h, 23h, 0C1h
	db 48h, 0B9h, 00h, 00h, 00h, 00h, 00h, 00h, 00h, 80h
	db 48h, 3Bh, 0C1h
	db 74h, 28h
	db 48h, 85h, 0DBh
	db 74h, 23h
	db 48h, 8Bh, 0CBh
	call host_game_free
	db 27 dup (90h)
done:
	add rsp, 30h
	pop rbx
	ret
fake_unistring_destructor ENDP

fake_file_loader PROC
	call host_vfs
	db 48h, 8Dh, 55h, 0E7h
	db 48h, 8Dh, 4Dh, 77h
	call host_file_name
	db 45h, 33h, 0C0h
	db 48h, 8Bh, 0D0h
	call host_file_exists
	db 84h, 0C0h, 75h, 08h, 83h, 0CBh, 0FFh
	db 0E9h, 95h, 00h, 00h, 00h
	call host_vfs
	db 48h, 8Dh, 55h, 0E7h, 48h, 89h, 7Dh, 27h, 48h, 8Dh, 4Dh, 77h
	db 48h, 89h, 7Dh, 2Fh, 40h, 88h, 7Dh, 37h
	call host_file_name
	db 4Ch, 8Dh, 4Dh, 27h, 4Ch, 8Bh, 0C0h, 48h, 8Dh, 55h, 0F7h
	call host_open_file
	db 48h, 8Bh, 75h, 0F7h
	ret
fake_file_loader ENDP

fake_emplace_unique PROC
	db 48h, 8Bh, 0C4h
	db 48h, 89h, 58h, 10h
	db 55h, 56h, 57h, 41h, 54h, 41h, 55h, 41h, 56h, 41h, 57h
	db 48h, 83h, 0ECh, 30h
	db 44h, 8Bh, 69h, 1Ch
	db 4Dh, 8Bh, 0E0h
	db 4Ch, 89h, 40h, 18h
	db 48h, 8Bh, 0F2h
	db 33h, 0C0h
	db 4Ch, 8Bh, 0F1h
	db 49h, 8Bh, 0CEh
	db 48h, 8Bh, 0D6h
	db 4Dh, 8Bh, 0C4h
	call host_emplace
	add rsp, 30h
	pop r15
	pop r14
	pop r13
	pop r12
	pop rdi
	pop rsi
	pop rbp
	mov rbx, qword ptr [rsp + 10h]
	ret
fake_emplace_unique ENDP

patch_target PROC
	mov eax, 1
	ret
patch_target ENDP

END
