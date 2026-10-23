section .data
    ok_msg  db "regs ok: ", 0
    bad_msg db "!!CLOBBER ", 0
    sv_rbx dq 0
    c_inp  db "echo hi", 0
    c_inp2 db "foo bar", 0
    c_inp3 db "echo x > o.txt", 0
    c_alias db "ll=dir /w", 0
    c_set  db "A=1", 0
    c_two  db "a b", 0
    c_dir  db "foo", 0
    c_hex  db "0A", 0
    c_inp4 db "ll x", 0
section .bss
    clob_flag resb 1
section .text
%macro CANARY 0
    mov rbx, 0x1111111111111111
    mov rsi, 0x2222222222222222
    mov rdi, 0x3333333333333333
    mov r12, 0x4444444444444444
    mov r13, 0x5555555555555555
    mov r14, 0x6666666666666666
    mov r15, 0x7777777777777777
%endmacro
%macro CANARYCHK 1
    %defstr %%str %1
    mov byte [rel clob_flag], 0
    mov rax, 0x1111111111111111
    cmp rbx, rax
    jne %%bad
    mov rax, 0x2222222222222222
    cmp rsi, rax
    jne %%bad
    mov rax, 0x3333333333333333
    cmp rdi, rax
    jne %%bad
    mov rax, 0x4444444444444444
    cmp r12, rax
    jne %%bad
    mov rax, 0x5555555555555555
    cmp r13, rax
    jne %%bad
    mov rax, 0x6666666666666666
    cmp r14, rax
    jne %%bad
    mov rax, 0x7777777777777777
    cmp r15, rax
    jne %%bad
    jmp %%ok
%%bad:
    lea r10, [rel bad_msg]
    call lg_str
    lea r10, [rel %%nm]
    call lg_str
    lea r10, [rel nl_ch]
    call lg_str
    jmp %%ok
%%nm: db %%str, 0
%%ok:
%endmacro
; CALLF fn, rcx-value-label-or-0
%macro CALLF 2
    CANARY
%ifnidn %2, 0
    lea rcx, [rel %2]
%else
    xor ecx, ecx
%endif
    call %1
    CANARYCHK %1
%endmacro
; set input_buf from label
%macro SETIN 1
    lea rcx, [rel input_buf]
    lea rdx, [rel %1]
    call str_copy
%endmacro
chk_start:
    and rsp, -16
    sub rsp, 8          ; emulate rsp%16==8 at entry like a callee body? keep aligned for calls: make rsp%16==0
    add rsp, 8
    CALLF GetStdHandle, 0
    SETIN c_inp
    CALLF history_add, input_buf
    SETIN c_inp2
    CALLF history_add, input_buf
    CALLF history_navigate_up, 0
    CALLF history_navigate_down, 0
    SETIN c_inp
    CALLF expand_env_vars, 0
    CALLF check_alias, 0
    SETIN c_inp3
    CALLF parse_redirection, 0
    CALLF restore_redirection, 0
    CALLF tab_complete, 0
    CALLF handler_help, 0
    CALLF handler_cls, 0
    CALLF handler_ver, 0
    CALLF handler_date, 0
    CALLF handler_time, 0
    CALLF handler_echo, c_inp
    CALLF handler_title, c_inp
    CALLF handler_color, c_hex
    CALLF handler_cd, c_dir
    CALLF handler_cd, 0
    CALLF handler_pwd, 0
    CALLF handler_whoami, 0
    CALLF handler_dir, c_dir
    CALLF handler_dir, 0
    CALLF handler_type, c_dir
    CALLF handler_mkdir, c_dir
    CALLF handler_rmdir, c_dir
    CALLF handler_del, c_dir
    CALLF handler_set, 0
    CALLF handler_pushd, c_dir
    CALLF handler_popd, 0
    CALLF handler_alias, c_alias
    CALLF handler_alias, 0
    SETIN c_inp4
    CALLF check_alias, 0
    SETIN c_inp2
    CALLF execute_external, 0
    SETIN c_inp
    CALLF dispatch_command, 0
    SETIN c_inp2
    CALLF dispatch_command, 0
    CALLF print_last_error, 0
    CALLF clear_screen, 0
    CALLF run_autoexec, 0
    ; copy/move take writable strings (parse_two_args modifies)
    lea rcx, [rel tmp2]
    lea rdx, [rel c_two]
    call str_copy
    CANARY
    lea rcx, [rel tmp2]
    call handler_copy
    CANARYCHK handler_copy
    lea rcx, [rel tmp2]
    lea rdx, [rel c_two]
    call str_copy
    CANARY
    lea rcx, [rel tmp2]
    call handler_move
    CANARYCHK handler_move
    lea rcx, [rel tmp3]
    lea rdx, [rel c_set]
    call str_copy
    CANARY
    lea rcx, [rel tmp3]
    call handler_set
    CANARYCHK handler_set_A1
    CANARY
    mov eax, 123456
    call print_number
    CANARYCHK print_number
    CANARY
    mov eax, 12
    call print_number_2digit
    CANARYCHK print_number_2digit
    CANARY
    mov eax, 12
    call print_number_9pad
    CANARYCHK print_number_9pad
    lea r10, [rel ok_msg]
    call lg_str
    mov eax, 231
    xor edi, edi
    syscall
section .bss
    tmp2 resb 64
    tmp3 resb 64
