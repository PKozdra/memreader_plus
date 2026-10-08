PUBLIC fake_dlfree

.data

allocator_flags db 2

.code

fake_dlfree PROC FRAME
	sub rsp, 78h
	.allocstack 78h
	.endprolog
	test rcx, rcx
	db 0Fh, 84h
	dd skip - ($ + 4)
	test byte ptr [allocator_flags], 2
	mov [rsp + 68h], rbx
	lea rbx, [rcx - 10h]
	db 74h, 13h
	db 0B8h
	dd 0
	mov rax, [rcx + 10h]
	mov [rax + 18h], rbx
	mov rbx, [rsp + 68h]
skip:
	add rsp, 78h
	ret
fake_dlfree ENDP

END
