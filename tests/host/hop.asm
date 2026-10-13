PUBLIC hop_leaf_here
PUBLIC hop_leaf_pad

hopcode SEGMENT ALIGN(16) READ EXECUTE ALIAS(".text$00") 'CODE'

hop_leaf PROC
hop_leaf_here::
	mov eax, ecx
	add eax, 1
	ret
hop_leaf ENDP

hop_leaf_pad::
	db 58 dup (0CCh)

hopcode ENDS

END
