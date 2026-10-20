PUBLIC fake_mod_list
PUBLIC fake_search_paths
PUBLIC fake_mod_array
PUBLIC fake_path_slot

.data

fake_mod_array dq 0, 0
fake_path_slot dq 0

.code

fake_mod_getter PROC
	lea rax, fake_mod_array
	ret
fake_mod_getter ENDP

fake_path_getter PROC
	mov rax, qword ptr fake_path_slot
	ret
fake_path_getter ENDP

fake_mod_list PROC
	db 0CCh, 89h, 78h, 20h, 41h, 56h
	db 48h, 81h, 0ECh, 0, 0, 0, 0
	db 0E8h, 0, 0, 0, 0
	db 80h, 3Dh, 0, 0, 0, 0, 0
	db 0Fh, 85h, 0, 0, 0, 0
	call fake_mod_getter
	ret
fake_mod_list ENDP

fake_search_paths PROC
	call fake_path_getter
	db 0CCh, 8Bh, 58h, 18h
	db 48h, 8Bh, 78h, 20h
	db 48h, 0C1h, 0E7h, 04h
	db 48h, 03h, 0FBh
	db 48h, 3Bh, 0DFh
	db 0Fh, 84h, 0, 0, 0, 0
	db 48h, 8Dh, 15h
	ret
fake_search_paths ENDP

END
