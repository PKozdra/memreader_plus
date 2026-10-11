PUBLIC site_split_here
PUBLIC site_split_free

.code

site_split PROC FRAME
	.endprolog
	mov r10d, ecx
	test ecx, ecx
	jnz site_split_cold
site_split_here::
	db 0Fh, 1Fh, 44h, 00h, 00h
	lea eax, [r10 + 1]
site_split_free::
	db 0Fh, 1Fh, 44h, 00h, 00h
	ret
site_split ENDP

site_split_cold PROC FRAME
	.endprolog
	db 0E9h
	dd site_split_here + 2 - ($ + 4)
site_split_cold ENDP

END
