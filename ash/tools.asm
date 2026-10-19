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

; ============================================================================
; trace [-a] COMMAND
;   Runs COMMAND (through /bin/sh, children included) under ptrace and
;   prints, on stderr, each program it starts, file it opens, deletes,
;   renames or creates, and each network connection it makes. Only calls
;   that succeed are shown. Shared-library and /proc, /sys, /dev reads are
;   hidden unless -a is given.
; ============================================================================

%define TR_PTRACE_TRACEME       0
%define TR_PTRACE_SYSCALL       24
%define TR_PTRACE_SETOPTIONS    0x4200
%define TR_PTRACE_GET_SYSINFO   0x420e
%define TR_OPTIONS              0x10001F    ; SYSGOOD FORK VFORK CLONE EXEC EXITKILL
%define TR_WALL                 0x40000000
%define TR_SYS_PTRACE           101
%define TR_SYS_VM_READV         310
%define TR_SIGSTOP              19
%define TR_SIGTRAP              5
%define TR_SLOTS                32
%define TR_SLOT_SIZE            1040        ; pid, kind, line[1032]
%define TR_LINE_MAX             1000

; event kinds (also the counters' index)
%define TK_EXEC                 1
%define TK_READ                 2
%define TK_WRITE                3
%define TK_DELETE               4
%define TK_RENAME               5
%define TK_MKDIR                6
%define TK_NET                  7
%define TK_LIST                 8

section .data
    tr_s_dash_a         db "-a", 0
    tr_s_trace          db "trace", 0
    tr_s_usage          db "Usage: trace [-a] COMMAND", 10, 0
    tr_s_noperm         db "trace: cannot trace (ptrace not permitted here)", 10, 0
    tr_t_exec           db "  exec     ", 0
    tr_t_read           db "  read     ", 0
    tr_t_write          db "  write    ", 0
    tr_t_delete         db "  delete   ", 0
    tr_t_rename         db "  rename   ", 0
    tr_t_mkdir          db "  mkdir    ", 0
    tr_t_net            db "  connect  ", 0
    tr_t_list           db "  list     ", 0
    tr_s_arrow          db " -> ", 0
    tr_s_unix           db "unix:", 0
    tr_s_colon          db ":", 0
    tr_s_v6             db "[ipv6]", 0
    tr_s_sum1           db "trace: ", 0
    tr_s_sum_prog       db " programs, ", 0
    tr_s_sum_read       db " files read, ", 0
    tr_s_sum_write      db " written, ", 0
    tr_s_sum_del        db " deleted, ", 0
    tr_s_sum_net        db " network connections", 10, 0
    tr_s_nl             db 10, 0
    ; reads hidden by default
    tr_hide_list        dq tr_h1, tr_h2, tr_h3, tr_h4, tr_h5, tr_h6, tr_h7, 0
    tr_h1               db "/lib", 0
    tr_h2               db "/usr/lib", 0
    tr_h3               db "/etc/ld.so", 0
    tr_h4               db "/proc/", 0
    tr_h5               db "/sys/", 0
    tr_h6               db "/dev/", 0
    tr_h7               db "/usr/share/locale", 0

section .bss
    alignb 8
    tr_info             resb 96
    tr_liov             resq 2
    tr_riov             resq 2
    tr_sockaddr         resb 112
    tr_counts           resd 16
    tr_wstatus          resd 1
    tr_child            resd 1
    tr_child_status     resd 1
    tr_all              resb 1
    tr_tmp              resb 512
    tr_slots            resb TR_SLOTS * TR_SLOT_SIZE

section .text

handler_trace:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8

    test rdi, rdi
    jz .tr_usage
    mov r12, rdi
    mov byte [tr_all], 0
    mov rdi, r12
    lea rsi, [tr_s_dash_a]
    call ash_word_is
    test eax, eax
    jz .tr_cmd
    mov byte [tr_all], 1
    lea rdi, [r12 + 2]
    call ash_skip_blanks
    mov r12, rax
.tr_cmd:
    cmp byte [r12], 0
    je .tr_usage
    mov rdi, r12
    call str_len
    cmp eax, MAX_INPUT - 1
    jae .tr_usage
    lea rdi, [tl_cmd_buf]
    mov rsi, r12
    call str_copy

    lea rdi, [tr_counts]
    xor eax, eax
    mov ecx, 16
    rep stosd
    lea rdi, [tr_slots]
    xor eax, eax
    mov ecx, TR_SLOTS * TR_SLOT_SIZE / 4
    rep stosd
    mov dword [tr_child_status], 1

    cmp byte [interactive_mode], 0
    je .tr_fork
    call restore_terminal
.tr_fork:
    mov eax, SYS_FORK
    syscall
    test rax, rax
    js .tr_noperm
    jz .tr_child_proc
    mov [tr_child], eax

    ; first stop (SIGSTOP the child sent itself)
.tr_first:
    mov edi, [tr_child]
    lea rsi, [tr_wstatus]
    mov edx, TR_WALL
    xor r10d, r10d
    mov eax, SYS_WAIT4
    syscall
    cmp rax, -EINTR
    je .tr_first
    test rax, rax
    js .tr_done
    mov eax, [tr_wstatus]
    and eax, 0xFF
    cmp eax, 0x7F
    jne .tr_child_gone              ; exited: ptrace refused

    mov eax, TR_SYS_PTRACE
    mov edi, TR_PTRACE_SETOPTIONS
    mov esi, [tr_child]
    xor edx, edx
    mov r10d, TR_OPTIONS
    syscall
    mov eax, TR_SYS_PTRACE
    mov edi, TR_PTRACE_SYSCALL
    mov esi, [tr_child]
    xor edx, edx
    xor r10d, r10d
    syscall

.tr_loop:
    mov edi, -1
    lea rsi, [tr_wstatus]
    mov edx, TR_WALL
    xor r10d, r10d
    mov eax, SYS_WAIT4
    syscall
    cmp rax, -EINTR
    je .tr_loop
    test rax, rax
    js .tr_done                     ; ECHILD: everything finished
    mov ebx, eax                    ; pid
    mov eax, [tr_wstatus]
    mov ecx, eax
    and ecx, 0xFF
    cmp ecx, 0x7F
    je .tr_stopped
    ; exited or killed
    cmp ebx, [tr_child]
    jne .tr_loop
    mov ecx, eax
    and ecx, 0x7F
    jz .tr_exit_code
    add ecx, 128
    mov [tr_child_status], ecx
    jmp .tr_loop
.tr_exit_code:
    shr eax, 8
    and eax, 0xFF
    mov [tr_child_status], eax
    jmp .tr_loop

.tr_stopped:
    xor r13d, r13d                  ; signal to pass on
    mov ecx, eax
    shr ecx, 16
    jnz .tr_resume                  ; fork/clone/exec event
    shr eax, 8
    and eax, 0xFF
    cmp eax, 0x85                   ; SIGTRAP | 0x80: syscall stop
    jne .tr_signal
    mov edi, ebx
    call tr_syscall_stop
    jmp .tr_resume
.tr_signal:
    cmp eax, TR_SIGSTOP
    je .tr_resume
    cmp eax, TR_SIGTRAP
    je .tr_resume
    mov r13d, eax
.tr_resume:
    mov eax, TR_SYS_PTRACE
    mov edi, TR_PTRACE_SYSCALL
    mov esi, ebx
    xor edx, edx
    mov r10d, r13d
    syscall
    jmp .tr_loop

.tr_child_gone:
.tr_noperm:
    lea rdi, [tr_s_noperm]
    call ash_write_err
    mov dword [tr_child_status], 1
.tr_done:
    cmp byte [interactive_mode], 0
    je .tr_summary
    call setup_raw_mode
.tr_summary:
    lea rdi, [tr_s_sum1]
    call ash_write_err
    mov eax, [tr_counts + TK_EXEC * 4]
    lea rsi, [tr_s_sum_prog]
    call tr_write_count
    mov eax, [tr_counts + TK_READ * 4]
    lea rsi, [tr_s_sum_read]
    call tr_write_count
    mov eax, [tr_counts + TK_WRITE * 4]
    lea rsi, [tr_s_sum_write]
    call tr_write_count
    mov eax, [tr_counts + TK_DELETE * 4]
    lea rsi, [tr_s_sum_del]
    call tr_write_count
    mov eax, [tr_counts + TK_NET * 4]
    lea rsi, [tr_s_sum_net]
    call tr_write_count
    mov eax, [tr_child_status]
    mov [last_exit_status], eax
    jmp .tr_ret
.tr_usage:
    lea rdi, [tr_s_usage]
    call print_cstring
    mov dword [last_exit_status], 2
.tr_ret:
    mov byte [stats_valid], 0
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

.tr_child_proc:
    mov eax, TR_SYS_PTRACE
    mov edi, TR_PTRACE_TRACEME
    xor esi, esi
    xor edx, edx
    xor r10d, r10d
    syscall
    test rax, rax
    js .tr_child_fail
    mov eax, 39                     ; getpid
    syscall
    mov edi, eax
    mov esi, TR_SIGSTOP
    mov eax, SYS_KILL
    syscall
    lea rdi, [ash_shc_argv]
    lea rax, [tl_cmd_buf]
    mov [rdi + 16], rax
    call ash_exec_argv              ; does not return
.tr_child_fail:
    mov edi, 126
    mov eax, SYS_EXIT
    syscall

; tr_write_count(eax = n, rsi = label) - "<n><label>" on stderr
tr_write_count:
    push rbx
    mov rbx, rsi
    lea rdi, [tr_tmp]
    mov esi, eax
    call ash_fmt_int
    lea rdi, [tr_tmp]
    call ash_write_err
    mov rdi, rbx
    call ash_write_err
    pop rbx
    ret

; tr_find_slot(edi = pid, esi = create) -> rax = slot or 0
tr_find_slot:
    lea rax, [tr_slots]
    xor ecx, ecx
.fs_loop:
    cmp ecx, TR_SLOTS
    jae .fs_new
    cmp [rax], edi
    je .fs_ret
    add rax, TR_SLOT_SIZE
    inc ecx
    jmp .fs_loop
.fs_new:
    test esi, esi
    jz .fs_none
    lea rax, [tr_slots]
    xor ecx, ecx
.fs_free:
    cmp ecx, TR_SLOTS
    jae .fs_none
    cmp dword [rax], 0
    je .fs_take
    add rax, TR_SLOT_SIZE
    inc ecx
    jmp .fs_free
.fs_take:
    mov [rax], edi
    ret
.fs_none:
    xor eax, eax
.fs_ret:
    ret

; tr_read_str(edi = pid, rsi = remote address, rdx = dst, ecx = max)
; -> eax = length (dst NUL-terminated)
tr_read_str:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13, rsi
    mov r14, rdx
    lea r15d, [ecx - 1]
    xor ebx, ebx                    ; bytes so far
.rs_loop:
    cmp ebx, r15d
    jae .rs_end
    lea rax, [r13 + rbx]
    and eax, 4095
    mov ecx, 4096
    sub ecx, eax                    ; to the end of the page
    mov eax, r15d
    sub eax, ebx
    cmp ecx, eax
    jbe .rs_chunk
    mov ecx, eax
.rs_chunk:
    lea rax, [r14 + rbx]
    mov [tr_liov], rax
    mov [tr_liov + 8], rcx
    lea rax, [r13 + rbx]
    mov [tr_riov], rax
    mov [tr_riov + 8], rcx
    mov edi, r12d
    lea rsi, [tr_liov]
    mov edx, 1
    lea r10, [tr_riov]
    mov r8d, 1
    xor r9d, r9d
    mov eax, TR_SYS_VM_READV
    syscall
    test rax, rax
    jle .rs_end
    ; look for the NUL in what arrived
    xor ecx, ecx
.rs_scan:
    cmp rcx, rax
    jae .rs_more
    cmp byte [r14 + rbx], 0
    je .rs_end
    inc ebx
    inc rcx
    jmp .rs_scan
.rs_more:
    jmp .rs_loop
.rs_end:
    mov byte [r14 + rbx], 0
    mov eax, ebx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; tr_syscall_stop(edi = pid): on entry, build a line for interesting calls;
; on exit, print it if the call succeeded.
tr_syscall_stop:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov r12d, edi

    mov eax, TR_SYS_PTRACE
    mov edi, TR_PTRACE_GET_SYSINFO
    mov esi, r12d
    mov edx, 88
    lea r10, [tr_info]
    syscall
    test rax, rax
    jle .ss_ret
    cmp byte [tr_info], 2
    je .ss_exit
    cmp byte [tr_info], 1
    jne .ss_ret

    ; ---- entry ----
    mov rax, [tr_info + 24]         ; syscall number
    mov r13, [tr_info + 32]         ; args[0]
    mov r14, [tr_info + 40]         ; args[1]
    cmp rax, 59                     ; execve
    je .ss_exec
    cmp rax, 322                    ; execveat
    je .ss_exec2
    cmp rax, 2                      ; open
    je .ss_open
    cmp rax, 257                    ; openat
    je .ss_openat
    cmp rax, 85                     ; creat
    je .ss_creat
    cmp rax, 87                     ; unlink
    je .ss_unlink
    cmp rax, 263                    ; unlinkat
    je .ss_unlinkat
    cmp rax, 84                     ; rmdir
    je .ss_unlink
    cmp rax, 83                     ; mkdir
    je .ss_mkdir
    cmp rax, 258                    ; mkdirat
    je .ss_mkdirat
    cmp rax, 82                     ; rename
    je .ss_rename
    cmp rax, 264                    ; renameat
    je .ss_renameat
    cmp rax, 316                    ; renameat2
    je .ss_renameat
    cmp rax, 42                     ; connect
    je .ss_connect
    jmp .ss_ret

.ss_exec2:
    mov r13, r14
.ss_exec:
    mov ebx, TK_EXEC
    lea rsi, [tr_t_exec]
    jmp .ss_path
.ss_creat:
    mov ebx, TK_WRITE
    lea rsi, [tr_t_write]
    jmp .ss_path
.ss_open:
    mov rcx, r14                    ; flags
    jmp .ss_open_kind
.ss_openat:
    mov rcx, [tr_info + 48]         ; flags
    mov r13, r14
.ss_open_kind:
    mov ebx, TK_READ
    lea rsi, [tr_t_read]
    test ecx, 0x10000               ; O_DIRECTORY
    jz .ss_open_w
    mov ebx, TK_LIST
    lea rsi, [tr_t_list]
.ss_open_w:
    test ecx, 0x243                 ; O_WRONLY|O_RDWR|O_CREAT|O_TRUNC
    jz .ss_path
    mov ebx, TK_WRITE
    lea rsi, [tr_t_write]
    jmp .ss_path
.ss_unlinkat:
    mov r13, r14
.ss_unlink:
    mov ebx, TK_DELETE
    lea rsi, [tr_t_delete]
    jmp .ss_path
.ss_mkdirat:
    mov r13, r14
.ss_mkdir:
    mov ebx, TK_MKDIR
    lea rsi, [tr_t_mkdir]
    jmp .ss_path
.ss_renameat:
    mov r13, r14                    ; old = args[1], new = args[3]
    mov r14, [tr_info + 56]
.ss_rename:
    mov ebx, TK_RENAME
    lea rsi, [tr_t_rename]
    call .ss_begin
    test rax, rax
    jz .ss_ret
    mov rdi, rax
    call .ss_add_path
    mov rdi, rax
    lea rsi, [tr_s_arrow]
    call upd_stpcpy
    mov r13, r14
    mov rdi, rax
    call .ss_add_path
    jmp .ss_ret

.ss_path:
    call .ss_begin                  ; rax = write pointer in the line
    test rax, rax
    jz .ss_ret
    mov rdi, rax
    call .ss_add_path
    cmp ebx, TK_READ
    jne .ss_ret
    cmp byte [tr_all], 0
    jne .ss_ret
    call .ss_hidden
    jmp .ss_ret

.ss_connect:
    ; read the sockaddr
    mov edi, r12d
    lea rax, [tr_sockaddr]
    mov [tr_liov], rax
    mov qword [tr_liov + 8], 28
    mov [tr_riov], r14
    mov qword [tr_riov + 8], 28
    lea rsi, [tr_liov]
    mov edx, 1
    lea r10, [tr_riov]
    mov r8d, 1
    xor r9d, r9d
    mov eax, TR_SYS_VM_READV
    syscall
    test rax, rax
    jle .ss_ret
    mov ebx, TK_NET
    lea rsi, [tr_t_net]
    call .ss_begin
    test rax, rax
    jz .ss_ret
    mov rdi, rax
    movzx eax, word [tr_sockaddr]
    cmp eax, 2
    je .ss_inet
    cmp eax, 10
    je .ss_inet6
    cmp eax, 1
    jne .ss_drop                    ; other families: skip
    lea rsi, [tr_s_unix]
    call upd_stpcpy
    lea rsi, [tr_sockaddr + 2]
    mov byte [tr_sockaddr + 27], 0
    call upd_stpcpy
    jmp .ss_ret
.ss_inet6:
    lea rsi, [tr_s_v6]
    call upd_stpcpy
    jmp .ss_port
.ss_inet:
    mov rax, rdi                    ; write pointer
    xor ecx, ecx
.ss_ip:
    push rcx
    push rcx
    movzx esi, byte [tr_sockaddr + 4 + rcx]
    mov rdi, rax
    call ash_fmt_int
    pop rcx
    pop rcx
    cmp ecx, 3
    je .ss_port
    mov byte [rax], '.'
    inc rax
    inc ecx
    jmp .ss_ip
.ss_port:
    mov rdi, rax
    lea rsi, [tr_s_colon]
    call upd_stpcpy
    mov rdi, rax
    movzx esi, word [tr_sockaddr + 2]
    rol si, 8                       ; network byte order
    movzx esi, si
    call ash_fmt_int
    jmp .ss_ret
.ss_drop:
    mov dword [r15], 0              ; forget the slot (r15 = slot)
    jmp .ss_ret

    ; ---- exit ----
.ss_exit:
    mov edi, r12d
    xor esi, esi
    call tr_find_slot
    test rax, rax
    jz .ss_ret
    mov rbx, rax
    mov dword [rbx], 0              ; free the slot
    mov ecx, [rbx + 4]
    test ecx, ecx
    jz .ss_ret
    mov rax, [tr_info + 24]         ; rval < 0: failed call
    cmp rax, -115                   ; EINPROGRESS: a non-blocking connect
    je .ss_ok
    test rax, rax
    js .ss_ret
.ss_ok:
    cmp ecx, TK_LIST
    je .ss_print
    lea rax, [tr_counts]
    inc dword [rax + rcx * 4]
.ss_print:
    lea rdi, [rbx + 8]
    call str_len
    lea rdi, [rbx + 8]
    mov byte [rdi + rax], 10
    mov byte [rdi + rax + 1], 0
    call ash_write_err
.ss_ret:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; local: claim a slot for this pid, set kind (ebx) and tag (rsi);
; -> rax = write pointer (0 if no slot), r15 = slot
.ss_begin:
    push rsi
    mov edi, r12d
    mov esi, 1
    call tr_find_slot
    pop rsi
    test rax, rax
    jz .sb_ret
    mov r15, rax
    mov [r15 + 4], ebx
    lea rdi, [r15 + 8]
    call upd_stpcpy
.sb_ret:
    ret

; local: append the tracee string at r13 to rdi -> rax = end
.ss_add_path:
    push rdi
    mov rdx, rdi
    mov edi, r12d
    mov rsi, r13
    lea rcx, [r15 + 8]
    add rcx, TR_LINE_MAX / 2
    sub rcx, rdx                    ; room left (keeps the line bounded)
    cmp ecx, 16
    jge .ap_room
    mov ecx, 16
.ap_room:
    call tr_read_str
    pop rdi
    add rax, rdi
    ret

; local: drop the pending read if its path is on the hide list
.ss_hidden:
    lea r8, [tr_hide_list]
.sh_next:
    mov rsi, [r8]
    test rsi, rsi
    jz .sh_ret
    lea rdi, [r15 + 8 + 11]         ; path after the tag
.sh_cmp:
    mov al, [rsi]
    test al, al
    jz .sh_hit
    cmp al, [rdi]
    jne .sh_miss
    inc rsi
    inc rdi
    jmp .sh_cmp
.sh_hit:
    mov dword [r15 + 4], 0          ; keep the slot, print nothing
    ret
.sh_miss:
    add r8, 8
    jmp .sh_next
.sh_ret:
    ret

; ============================================================================
; sandbox [-w] [-n] COMMAND
;   Runs COMMAND (through /bin/sh) with:
;     - no network: socket(AF_INET/AF_INET6) fails with EPERM (seccomp);
;       -n keeps the network
;     - no file changes outside /tmp (Landlock); -w also allows the
;       current folder. Reading and running programs stay allowed.
;   The shell itself is not restricted, only the command.
; ============================================================================

%define SB_SYS_PRCTL            157
%define SB_SYS_SECCOMP          317
%define SB_SYS_LL_CREATE        444
%define SB_SYS_LL_ADD           445
%define SB_SYS_LL_RESTRICT      446
%define SB_PR_NO_NEW_PRIVS      38
%define SB_O_PATH               0x200000
%define SB_FS_WRITE             0x1FF2      ; Landlock ABI 1 write/create/remove rights
%define SB_FS_WRITE_FILE        2

section .data
    sb_s_dash_w         db "-w", 0
    sb_s_sandbox        db "sandbox", 0
    sb_s_dash_n         db "-n", 0
    sb_s_tmp            db "/tmp", 0
    sb_s_dev            db "/dev", 0
    sb_s_dot            db ".", 0
    sb_s_usage          db "Usage: sandbox [-w] [-n] COMMAND", 10
                        db "  default: no network, file changes only in /tmp", 10
                        db "  -w  also allow changes in the current folder", 10
                        db "  -n  keep network access", 10, 0
    sb_s_no_landlock    db "sandbox: Landlock is not available; file changes are NOT restricted", 10, 0
    sb_s_no_seccomp     db "sandbox: could not block the network", 10, 0

    ; seccomp filter: socket(AF_INET|AF_INET6, ...) -> EPERM, x32 calls -> EPERM
    align 8
    sb_filter:
        dw 0x20
        db 0, 0
        dd 4                        ; ld arch
        dw 0x15
        db 1, 0
        dd 0xC000003E               ; jeq x86_64
        dw 0x06
        db 0, 0
        dd 0x80000000               ; ret KILL_PROCESS (other arch)
        dw 0x20
        db 0, 0
        dd 0                        ; ld nr
        dw 0x35
        db 5, 0
        dd 0x40000000               ; jge x32 -> EPERM
        dw 0x15
        db 0, 3
        dd 41                       ; jeq socket
        dw 0x20
        db 0, 0
        dd 16                       ; ld args[0] (low half)
        dw 0x15
        db 2, 0
        dd 2                        ; AF_INET -> EPERM
        dw 0x15
        db 1, 0
        dd 10                       ; AF_INET6 -> EPERM
        dw 0x06
        db 0, 0
        dd 0x7FFF0000               ; ret ALLOW
        dw 0x06
        db 0, 0
        dd 0x00050001               ; ret ERRNO(EPERM)
    sb_filter_len equ ($ - sb_filter) / 8
    sb_prog:
        dw sb_filter_len
        dw 0, 0, 0
        dq sb_filter

section .bss
    alignb 8
    sb_ruleset_attr     resq 1
    sb_rule             resb 16         ; u64 allowed_access, s32 parent_fd (packed)
    sb_wstatus          resd 1
    sb_flags            resb 1          ; bit0 = -w, bit1 = -n

section .text

handler_sandbox:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    mov byte [sb_flags], 0
    test rdi, rdi
    jz .sb_usage
    mov r12, rdi
.sb_opts:
    mov rdi, r12
    lea rsi, [sb_s_dash_w]
    call ash_word_is
    test eax, eax
    jz .sb_opt_n
    or byte [sb_flags], 1
    jmp .sb_opt_next
.sb_opt_n:
    mov rdi, r12
    lea rsi, [sb_s_dash_n]
    call ash_word_is
    test eax, eax
    jz .sb_cmd
    or byte [sb_flags], 2
.sb_opt_next:
    lea rdi, [r12 + 2]
    call ash_skip_blanks
    mov r12, rax
    jmp .sb_opts
.sb_cmd:
    cmp byte [r12], 0
    je .sb_usage
    mov rdi, r12
    call str_len
    cmp eax, MAX_INPUT - 1
    jae .sb_usage
    lea rdi, [tl_cmd_buf]
    mov rsi, r12
    call str_copy

    cmp byte [interactive_mode], 0
    je .sb_fork
    call restore_terminal
.sb_fork:
    mov eax, SYS_FORK
    syscall
    test rax, rax
    js .sb_fail
    jz .sb_child
    mov ebx, eax
.sb_wait:
    mov edi, ebx
    lea rsi, [sb_wstatus]
    xor edx, edx
    xor r10d, r10d
    mov eax, SYS_WAIT4
    syscall
    cmp rax, -EINTR
    je .sb_wait
    mov eax, [sb_wstatus]
    mov edx, eax
    and edx, 0x7F
    jz .sb_exited
    lea eax, [rdx + 128]
    jmp .sb_status
.sb_exited:
    shr eax, 8
    and eax, 0xFF
.sb_status:
    mov [last_exit_status], eax
    jmp .sb_done
.sb_fail:
    mov dword [last_exit_status], 1
.sb_done:
    cmp byte [interactive_mode], 0
    je .sb_ret
    call setup_raw_mode
    jmp .sb_ret
.sb_usage:
    lea rdi, [sb_s_usage]
    call print_cstring
    mov dword [last_exit_status], 2
.sb_ret:
    pop r12
    pop rbx
    pop rbp
    ret

; ---- child: lock itself down, then exec /bin/sh -c COMMAND ----
.sb_child:
    mov eax, SB_SYS_PRCTL
    mov edi, SB_PR_NO_NEW_PRIVS
    mov esi, 1
    xor edx, edx
    xor r10d, r10d
    xor r8d, r8d
    syscall

    ; Landlock: handle all write rights, then allow them under /tmp (+ cwd)
    mov qword [sb_ruleset_attr], SB_FS_WRITE
    lea rdi, [sb_ruleset_attr]
    mov esi, 8
    xor edx, edx
    mov eax, SB_SYS_LL_CREATE
    syscall
    test rax, rax
    js .sbc_no_ll
    mov r12d, eax                   ; ruleset fd
    lea rdi, [sb_s_tmp]
    mov esi, SB_FS_WRITE
    call .sbc_allow
    lea rdi, [sb_s_dev]             ; /dev/null, /dev/tty
    mov esi, SB_FS_WRITE_FILE
    call .sbc_allow
    test byte [sb_flags], 1
    jz .sbc_restrict
    lea rdi, [sb_s_dot]
    mov esi, SB_FS_WRITE
    call .sbc_allow
.sbc_restrict:
    mov edi, r12d
    xor esi, esi
    mov eax, SB_SYS_LL_RESTRICT
    syscall
    test rax, rax
    jns .sbc_net
.sbc_no_ll:
    lea rdi, [sb_s_no_landlock]
    call ash_write_err
.sbc_net:
    test byte [sb_flags], 2
    jnz .sbc_exec
    mov eax, SB_SYS_SECCOMP
    mov edi, 1                      ; SECCOMP_SET_MODE_FILTER
    xor esi, esi
    lea rdx, [sb_prog]
    syscall
    test rax, rax
    jns .sbc_exec
    lea rdi, [sb_s_no_seccomp]
    call ash_write_err
    mov edi, 126                    ; refuse to run unrestricted
    mov eax, SYS_EXIT
    syscall
.sbc_exec:
    lea rdi, [ash_shc_argv]
    lea rax, [tl_cmd_buf]
    mov [rdi + 16], rax
    call ash_exec_argv              ; does not return

; local: add a path-beneath rule (rdi = path, esi = rights) to r12d
.sbc_allow:
    push rbx
    mov ebx, esi
    mov esi, SB_O_PATH | O_CLOEXEC
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .sa_ret
    mov qword [sb_rule], rbx
    mov [sb_rule + 8], eax
    push rax
    mov edi, r12d
    mov esi, 1                      ; LANDLOCK_RULE_PATH_BENEATH
    lea rdx, [sb_rule]
    xor r10d, r10d
    mov eax, SB_SYS_LL_ADD
    syscall
    pop rdi
    mov eax, SYS_CLOSE
    syscall
.sa_ret:
    pop rbx
    ret
