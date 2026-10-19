; ============================================================================
; ASH tools (milestone 2, part C/D)
;
;   bench [-n N] COMMAND    run COMMAND N times (default 10, output hidden)
;                           and print mean / min / max time and peak memory
;   undo                    reverse the last del, move/rename or copy
;
; Undo: del moves the file into ~/.asm_trash instead of deleting it, and
; move/copy first move a file they would overwrite there. A journal of the
; last UNDO_MAX operations lives in memory for this session.
;
; Included from terminal_linux.asm, after ash/script.asm.
; ============================================================================

%define BENCH_DEFAULT_RUNS  10
%define BENCH_MAX_RUNS      100000
%define TL_SYS_DUP          32
%define TL_SYS_LSTAT        6
%define TL_EXDEV            18
%define TL_R_OK             4

%define UNDO_MAX            16
%define UNDO_PATH           400
%define UNDO_SIZE           1216
%define U_TYPE              0
%define U_SAVED             4           ; 1 = a replaced file sits in trash
%define U_A                 8           ; del: file   move: source  copy: -
%define U_B                 (8 + UNDO_PATH)         ; move/copy: destination
%define U_T                 (8 + 2 * UNDO_PATH)     ; trash copy
%define UT_DEL              1
%define UT_MOVE             2
%define UT_COPY             3

section .data
    tl_s_dash_n         db "-n", 0
    tl_s_bench          db "bench", 0
    tl_s_undo           db "undo", 0
    tl_s_trash          db "/.asm_trash", 0
    tl_s_ns             db " ns", 0
    tl_s_us             db " us", 0
    tl_s_ms             db " ms", 0
    tl_s_sec            db " s", 0
    tl_s_dot            db ".", 0
    tl_s_bench_hdr      db "bench: ", 0
    tl_s_bench_runs1    db "  (", 0
    tl_s_bench_runs2    db " runs)", 10, 0
    tl_s_mean           db "  mean ", 0
    tl_s_min            db "   min ", 0
    tl_s_max            db "   max ", 0
    tl_s_peak           db "  peak ", 0
    tl_s_kb             db " KB", 0
    tl_s_mb             db " MB", 0
    tl_s_failed         db "  failed ", 0
    tl_s_nl             db 10, 0
    tl_s_bench_usage    db "Usage: bench [-n N] COMMAND", 10, 0
    tl_s_bench_stopped  db "bench: stopped (Ctrl+C)", 10, 0

    tl_s_undo_none      db "undo: nothing to undo", 10, 0
    tl_s_undo_restored  db "undo: restored ", 0
    tl_s_undo_moved     db "undo: moved back ", 0
    tl_s_undo_removed   db "undo: removed copy ", 0
    tl_s_undo_arrow     db " -> ", 0
    tl_s_undo_exists    db "undo: target already exists: ", 0
    tl_s_undo_failed    db "undo: could not restore ", 0
    tl_s_undo_keep      db "undo: ", 0
    tl_s_undo_keep2     db " was not restored", 10, 0

section .bss
    alignb 8
    tl_t0               resq 2
    tl_t1               resq 2
    tl_sum              resq 1
    tl_min              resq 1
    tl_max              resq 1
    tl_peak             resq 1
    tl_saved_fd         resd 1
    tl_trash_seq        resd 1
    undo_count          resd 1
    tl_path_a           resb UNDO_PATH
    tl_path_b           resb UNDO_PATH
    tl_path_t           resb UNDO_PATH
    tl_stat             resb 144
    tl_cmd_buf          resb MAX_INPUT
    undo_journal        resb UNDO_MAX * UNDO_SIZE

section .text

; ============================================================================
; bench
; ============================================================================
handler_bench:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8

    test rdi, rdi
    jz .bn_usage
    mov r12, rdi                    ; command text
    mov r13d, BENCH_DEFAULT_RUNS

    mov rdi, r12
    lea rsi, [tl_s_dash_n]
    call ash_word_is
    test eax, eax
    jz .bn_cmd
    lea rdi, [r12 + 2]
    call ash_skip_blanks
    mov rdi, rax
    call bi_parse_uint              ; eax = N, rdi after the word
    test edx, edx
    jz .bn_usage
    test eax, eax
    jz .bn_usage
    cmp eax, BENCH_MAX_RUNS
    ja .bn_usage
    mov r13d, eax
    call ash_skip_blanks            ; rdi still after the number
    mov r12, rax
.bn_cmd:
    cmp byte [r12], 0
    je .bn_usage
    ; Own copy: each run reuses input_buf, where the text lives now
    mov rdi, r12
    call str_len
    cmp eax, MAX_INPUT - 1
    jae .bn_usage
    lea rdi, [tl_cmd_buf]
    mov rsi, r12
    call str_copy
    lea r12, [tl_cmd_buf]

    ; Header
    lea rdi, [tl_s_bench_hdr]
    call print_cstring
    mov rdi, r12
    call print_cstring
    lea rdi, [tl_s_bench_runs1]
    call print_cstring
    mov eax, r13d
    call print_number
    lea rdi, [tl_s_bench_runs2]
    call print_cstring

    ; Hide the command's output: stdout -> /dev/null for the runs
    mov edi, 1
    mov eax, TL_SYS_DUP
    syscall
    mov [tl_saved_fd], eax
    lea rdi, [upd_dev_null]
    mov esi, O_RDWR
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .bn_runs
    mov ebx, eax
    mov edi, ebx
    mov esi, 1
    mov eax, SYS_DUP2
    syscall
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall

.bn_runs:
    mov qword [tl_sum], 0
    mov qword [tl_max], 0
    mov rax, -1
    mov [tl_min], rax
    mov qword [tl_peak], 0
    xor r14d, r14d                  ; runs done
    xor r15d, r15d                  ; failures
.bn_loop:
    cmp r14d, r13d
    jae .bn_restore
    cmp byte [ctrl_c_flag], 0
    jne .bn_restore
    mov edi, CLOCK_MONOTONIC
    lea rsi, [tl_t0]
    mov eax, SYS_CLOCK_GETTIME
    syscall
    mov qword [stats_maxrss_kb], 0
    mov rdi, r12
    mov esi, 1
    call ash_eval
    mov edi, CLOCK_MONOTONIC
    lea rsi, [tl_t1]
    mov eax, SYS_CLOCK_GETTIME
    syscall
    mov rax, [tl_t1]
    sub rax, [tl_t0]
    imul rax, rax, 1000000000
    add rax, [tl_t1 + 8]
    sub rax, [tl_t0 + 8]
    add [tl_sum], rax
    cmp rax, [tl_min]
    jae .bn_not_min
    mov [tl_min], rax
.bn_not_min:
    cmp rax, [tl_max]
    jbe .bn_not_max
    mov [tl_max], rax
.bn_not_max:
    mov rax, [stats_maxrss_kb]
    cmp rax, [tl_peak]
    jbe .bn_not_peak
    mov [tl_peak], rax
.bn_not_peak:
    cmp dword [last_exit_status], 0
    je .bn_ok
    inc r15d
.bn_ok:
    inc r14d
    jmp .bn_loop

.bn_restore:
    mov edi, [tl_saved_fd]
    test edi, edi
    js .bn_report
    mov esi, 1
    mov eax, SYS_DUP2
    syscall
    mov edi, [tl_saved_fd]
    mov eax, SYS_CLOSE
    syscall
.bn_report:
    mov byte [stats_valid], 0       ; no "took" line for bench itself
    cmp r14d, r13d
    jae .bn_full
    lea rdi, [tl_s_bench_stopped]
    call print_cstring
    test r14d, r14d
    jz .bn_status
.bn_full:
    lea rdi, [tl_s_mean]
    call print_cstring
    mov rax, [tl_sum]
    xor edx, edx
    mov ecx, r14d
    div rcx
    call tl_print_time
    lea rdi, [tl_s_min]
    call print_cstring
    mov rax, [tl_min]
    call tl_print_time
    lea rdi, [tl_s_max]
    call print_cstring
    mov rax, [tl_max]
    call tl_print_time
    call print_newline

    mov rax, [tl_peak]
    test rax, rax
    jz .bn_fail_line
    lea rdi, [tl_s_peak]
    call print_cstring
    mov rax, [tl_peak]
    call tl_print_kb
.bn_fail_line:
    lea rdi, [tl_s_failed]
    call print_cstring
    mov eax, r15d
    call print_number
    call print_newline
.bn_status:
    xor eax, eax
    test r15d, r15d
    setnz al
    mov [last_exit_status], eax
    jmp .bn_ret
.bn_usage:
    lea rdi, [tl_s_bench_usage]
    call print_cstring
    mov dword [last_exit_status], 2
.bn_ret:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; tl_print_time(rax = ns): "850 us", "12.34 ms" or "2.31 s"
tl_print_time:
    push rbx
    mov rbx, rax
    cmp rax, 1000
    jae .pt_us
    call print_number
    lea rdi, [tl_s_ns]
    call print_cstring
    pop rbx
    ret
.pt_us:
    cmp rax, 1000000
    jae .pt_ms
    xor edx, edx
    mov ecx, 1000
    div rcx
    call print_number
    lea rdi, [tl_s_us]
    call print_cstring
    pop rbx
    ret
.pt_ms:
    cmp rax, 1000000000
    jae .pt_s
    mov ecx, 10000                  ; hundredths of a ms
    lea rdi, [tl_s_ms]
    jmp .pt_frac
.pt_s:
    mov ecx, 10000000               ; hundredths of a second
    lea rdi, [tl_s_sec]
.pt_frac:
    push rdi
    sub rsp, 8
    mov rax, rbx
    xor edx, edx
    div rcx                         ; rax = hundredths
    xor edx, edx
    mov ecx, 100
    div rcx
    mov rbx, rdx
    call print_number
    lea rdi, [tl_s_dot]
    call print_cstring
    cmp rbx, 10
    jae .pt_two
    xor eax, eax
    call print_number
.pt_two:
    mov rax, rbx
    call print_number
    add rsp, 8
    pop rdi
    call print_cstring
    pop rbx
    ret

; tl_print_kb(rax = KB): "900 KB" or "45.2 MB"
tl_print_kb:
    push rbx
    cmp rax, 1024
    jae .pk_mb
    call print_number
    lea rdi, [tl_s_kb]
    call print_cstring
    pop rbx
    ret
.pk_mb:
    imul rax, rax, 10
    xor edx, edx
    mov ecx, 1024
    div rcx
    xor edx, edx
    mov ecx, 10
    div rcx
    mov rbx, rdx
    call print_number
    lea rdi, [tl_s_dot]
    call print_cstring
    mov rax, rbx
    call print_number
    lea rdi, [tl_s_mb]
    call print_cstring
    pop rbx
    ret

; ============================================================================
; undo support
; ============================================================================

; tl_abspath(rdi = path, rsi = dst UNDO_PATH bytes) -> eax 1 ok / 0 too long
tl_abspath:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx                    ; bytes written
    cmp byte [r12], '/'
    je .ap_copy
    mov rdi, r13
    mov esi, UNDO_PATH
    mov eax, SYS_GETCWD
    syscall
    test rax, rax
    jle .ap_fail
    lea ebx, [eax - 1]              ; length without NUL
    cmp ebx, 1
    jne .ap_slash
    cmp byte [r13], '/'
    je .ap_copy                     ; cwd is "/"
.ap_slash:
    cmp ebx, UNDO_PATH - 2
    jae .ap_fail
    mov byte [r13 + rbx], '/'
    inc ebx
.ap_copy:
    mov al, [r12]
    cmp ebx, UNDO_PATH - 1
    jae .ap_fail
    mov [r13 + rbx], al
    test al, al
    jz .ap_ok
    inc ebx
    inc r12
    jmp .ap_copy
.ap_ok:
    mov eax, 1
    jmp .ap_ret
.ap_fail:
    xor eax, eax
.ap_ret:
    pop r13
    pop r12
    pop rbx
    ret

; tl_trash_path(rdi = dst) -> eax 1 ok: "$HOME/.asm_trash/<pid>.<seq>"
; Creates the trash folder (mode 0700) when missing.
tl_trash_path:
    push rbx
    push r12
    sub rsp, 8
    mov r12, rdi
    lea rdi, [str_home]
    call getenv_internal
    test rax, rax
    jz .tp_fail
    mov rdi, r12
    mov rsi, rax
    call upd_stpcpy
    mov rdi, rax
    lea rsi, [tl_s_trash]
    call upd_stpcpy
    mov rbx, rax
    sub rax, r12
    cmp rax, UNDO_PATH - 48
    jae .tp_fail
    mov rdi, r12
    mov esi, 0o700
    mov eax, SYS_MKDIR
    syscall                         ; EEXIST is fine
    mov byte [rbx], '/'
    lea rdi, [rbx + 1]
    push rdi
    mov eax, 39                     ; getpid
    syscall
    pop rdi
    mov rsi, rax
    call ash_fmt_int
    mov byte [rax], '.'
    lea rdi, [rax + 1]
    inc dword [tl_trash_seq]
    mov esi, [tl_trash_seq]
    call ash_fmt_int
    mov eax, 1
    jmp .tp_ret
.tp_fail:
    xor eax, eax
.tp_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret

; tl_is_file(rdi = path) -> eax 1 if it exists and is not a directory
tl_is_file:
    lea rsi, [tl_stat]
    mov eax, TL_SYS_LSTAT
    syscall
    test rax, rax
    jnz .if_no
    mov eax, [tl_stat + STAT_ST_MODE]
    and eax, ASH_S_IFMT
    cmp eax, ASH_S_IFDIR
    je .if_no
    mov eax, 1
    ret
.if_no:
    xor eax, eax
    ret

; tl_stash(rdi = abs path) -> eax 1 if moved into trash (path in tl_path_t)
tl_stash:
    push rbx
    mov rbx, rdi
    lea rdi, [tl_path_t]
    call tl_trash_path
    test eax, eax
    jz .st_ret
    mov rdi, rbx
    lea rsi, [tl_path_t]
    mov eax, SYS_RENAME
    syscall
    xor ecx, ecx
    test rax, rax
    sete cl
    mov eax, ecx
.st_ret:
    pop rbx
    ret

; undo_record(edi = type, esi = saved) - copy tl_path_a/b/t into the journal
undo_record:
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13d, esi
    mov eax, [undo_count]
    cmp eax, UNDO_MAX
    jb .ur_slot
    ; full: drop the oldest entry
    lea rdi, [undo_journal]
    lea rsi, [undo_journal + UNDO_SIZE]
    mov ecx, (UNDO_MAX - 1) * UNDO_SIZE
    rep movsb
    mov eax, UNDO_MAX - 1
    mov [undo_count], eax
.ur_slot:
    imul eax, eax, UNDO_SIZE
    lea rbx, [undo_journal]
    add rbx, rax
    inc dword [undo_count]
    mov [rbx + U_TYPE], r12d
    mov [rbx + U_SAVED], r13d
    lea rdi, [rbx + U_A]
    lea rsi, [tl_path_a]
    mov ecx, UNDO_PATH * 3
    rep movsb
    pop r13
    pop r12
    pop rbx
    ret

; ---------- del FILE (keeps a copy in the trash for undo) ----------
handler_del_safe:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    mov rbx, rdi
    test rbx, rbx
    jz .ds_plain
    cmp byte [rbx], 0
    je .ds_plain
    mov rdi, rbx
    call tl_is_file
    test eax, eax
    jz .ds_plain                    ; missing or a folder: old behaviour
    mov rdi, rbx
    lea rsi, [tl_path_a]
    call tl_abspath
    test eax, eax
    jz .ds_plain
    lea rdi, [tl_path_a]
    call tl_stash
    test eax, eax
    jz .ds_plain                    ; e.g. other filesystem: really delete
    mov byte [tl_path_b], 0
    mov edi, UT_DEL
    mov esi, 1
    call undo_record
    mov dword [last_exit_status], 0
    jmp .ds_ret
.ds_plain:
    mov rdi, rbx
    call handler_del
.ds_ret:
    pop r12
    pop rbx
    pop rbp
    ret

; ---------- move/rename SRC DST (saves an overwritten DST) ----------
handler_move_safe:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    test rdi, rdi
    jz .ms_plain_arg
    mov rbx, rdi
    call parse_two_args
    test rax, rax
    jz .ms_plain_rejoin
    mov r12, rax
    mov r13, rdx
    xor r14d, r14d                  ; saved?
    mov rdi, r12
    lea rsi, [tl_path_a]
    call tl_abspath
    test eax, eax
    jz .ms_raw
    mov rdi, r13
    lea rsi, [tl_path_b]
    call tl_abspath
    test eax, eax
    jz .ms_raw
    mov rdi, r12
    call tl_is_file
    test eax, eax
    jz .ms_raw                      ; source missing: let rename report it
    lea rdi, [tl_path_b]
    call tl_is_file
    test eax, eax
    jz .ms_rename
    lea rdi, [tl_path_b]
    call tl_stash
    mov r14d, eax
.ms_rename:
    lea rdi, [tl_path_a]
    lea rsi, [tl_path_b]
    mov eax, SYS_RENAME
    syscall
    test rax, rax
    js .ms_failed
    mov edi, UT_MOVE
    mov esi, r14d
    call undo_record
    mov dword [last_exit_status], 0
    jmp .ms_ret
.ms_failed:
    neg eax
    push rax
    push rax
    test r14d, r14d                 ; put the stashed file back
    jz .ms_failed_msg
    lea rdi, [tl_path_t]
    lea rsi, [tl_path_b]
    mov eax, SYS_RENAME
    syscall
.ms_failed_msg:
    pop rdi
    pop rax
    call print_last_error
    mov dword [last_exit_status], 1
    jmp .ms_ret
.ms_raw:
    mov rdi, r12
    mov rsi, r13
    mov eax, SYS_RENAME
    syscall
    test rax, rax
    jns .ms_ret
    neg eax
    mov edi, eax
    call print_last_error
    mov dword [last_exit_status], 1
    jmp .ms_ret
.ms_plain_rejoin:
    mov rdi, rbx
.ms_plain_arg:
    call handler_move               ; prints the usage error
.ms_ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ---------- copy SRC DST (saves an overwritten DST) ----------
handler_copy_safe:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    test rdi, rdi
    jz .cs_plain
    mov rbx, rdi
    call parse_two_args
    test rax, rax
    jz .cs_plain_args
    mov r12, rax
    mov r13, rdx
    xor r14d, r14d
    mov rdi, r12                    ; where parse_two_args put the NUL
    call str_len
    push rax
    push rax
    mov rdi, r12
    mov esi, TL_R_OK
    mov eax, ASH_SYS_ACCESS
    syscall
    test rax, rax
    jnz .cs_go                      ; unreadable source: copy reports it
    mov rdi, r13
    lea rsi, [tl_path_b]
    call tl_abspath
    test eax, eax
    jz .cs_go
    lea rdi, [tl_path_b]
    call tl_is_file
    mov r14d, 2                     ; 2 = new file
    test eax, eax
    jz .cs_go
    lea rdi, [tl_path_b]
    call tl_stash
    mov r14d, eax                   ; 1 = old file saved, 0 = not saved
    test eax, eax
    jnz .cs_go
    mov r14d, 3                     ; could not save: no undo entry
.cs_go:
    pop rax
    pop rax
    mov byte [r12 + rax], ' '       ; rejoin "SRC DST" for handler_copy
    mov rdi, rbx
    call handler_copy
    cmp r14d, 1
    je .cs_record
    cmp r14d, 2
    jne .cs_ret
    xor r14d, r14d
.cs_record:
    ; only record when DST now exists
    lea rdi, [tl_path_b]
    call tl_is_file
    test eax, eax
    jz .cs_ret
    mov byte [tl_path_a], 0
    mov edi, UT_COPY
    mov esi, r14d
    call undo_record
    jmp .cs_ret
.cs_plain_args:
    mov rdi, rbx
.cs_plain:
    call handler_copy
.cs_ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ---------- undo ----------
handler_undo:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    mov eax, [undo_count]
    test eax, eax
    jz .un_none
    dec eax
    mov [undo_count], eax
    imul eax, eax, UNDO_SIZE
    lea rbx, [undo_journal]
    add rbx, rax
    mov dword [last_exit_status], 0
    mov eax, [rbx + U_TYPE]
    cmp eax, UT_DEL
    je .un_del
    cmp eax, UT_MOVE
    je .un_move

    ; copy: remove the new file, bring back the one it replaced
    lea rdi, [rbx + U_B]
    mov eax, SYS_UNLINK
    syscall
    lea rdi, [tl_s_undo_removed]
    call print_cstring
    lea rdi, [rbx + U_B]
    call print_cstring
    call print_newline
    jmp .un_saved

.un_move:
    lea rdi, [rbx + U_A]
    call tl_is_file
    test eax, eax
    jnz .un_exists_a
    lea rdi, [rbx + U_B]
    lea rsi, [rbx + U_A]
    mov eax, SYS_RENAME
    syscall
    test rax, rax
    js .un_fail_b
    lea rdi, [tl_s_undo_moved]
    call print_cstring
    lea rdi, [rbx + U_B]
    call print_cstring
    lea rdi, [tl_s_undo_arrow]
    call print_cstring
    lea rdi, [rbx + U_A]
    call print_cstring
    call print_newline
    jmp .un_saved

.un_del:
    lea rdi, [rbx + U_A]
    call tl_is_file
    test eax, eax
    jnz .un_exists_a
    lea rdi, [rbx + U_T]
    lea rsi, [rbx + U_A]
    mov eax, SYS_RENAME
    syscall
    test rax, rax
    js .un_fail_a
    lea rdi, [tl_s_undo_restored]
    call print_cstring
    lea rdi, [rbx + U_A]
    call print_cstring
    call print_newline
    jmp .un_ret

.un_saved:
    ; move/copy: put back the destination file they replaced
    cmp dword [rbx + U_SAVED], 0
    je .un_ret
    lea rdi, [rbx + U_T]
    lea rsi, [rbx + U_B]
    mov eax, SYS_RENAME
    syscall
    test rax, rax
    js .un_keep
    lea rdi, [tl_s_undo_restored]
    call print_cstring
    lea rdi, [rbx + U_B]
    call print_cstring
    call print_newline
    jmp .un_ret
.un_keep:
    lea rdi, [tl_s_undo_keep]
    call print_cstring
    lea rdi, [rbx + U_T]
    call print_cstring
    lea rdi, [tl_s_undo_keep2]
    call print_cstring
    mov dword [last_exit_status], 1
    jmp .un_ret

.un_exists_a:
    lea rdi, [tl_s_undo_exists]
    call print_cstring
    lea rdi, [rbx + U_A]
    call print_cstring
    call print_newline
    inc dword [undo_count]          ; keep the entry
    mov dword [last_exit_status], 1
    jmp .un_ret
.un_fail_a:
    lea r12, [rbx + U_A]
    jmp .un_fail
.un_fail_b:
    lea r12, [rbx + U_B]
.un_fail:
    lea rdi, [tl_s_undo_failed]
    call print_cstring
    mov rdi, r12
    call print_cstring
    call print_newline
    mov dword [last_exit_status], 1
    jmp .un_ret
.un_none:
    lea rdi, [tl_s_undo_none]
    call print_cstring
    mov dword [last_exit_status], 1
.un_ret:
    pop r12
    pop rbx
    pop rbp
    ret
