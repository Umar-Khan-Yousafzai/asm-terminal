; ============================================================================
; ASH tools (milestone 2, part C/D)
;
;   bench [-n N] COMMAND    run COMMAND N times (default 10, output hidden)
;                           and print mean / min / max time and peak memory
;   undo                    reverse the last del, move/rename or copy
;   trash [empty]           list what del/move/copy keep, or empty it
;
; Undo: del moves the file into ~/.asm_trash instead of deleting it, and
; move/copy first move a file they would overwrite there. Every operation is
; also appended to ~/.asm_trash/.journal, so undo still works after the shell
; has been restarted. Trash file names are "<time>.<pid>.<seq>.<name>" and are
; created without ever replacing an existing file. When the trash cannot be
; used the command refuses unless -f is given. The trash keeps at most
; TRASH_MAX_BYTES and TRASH_MAX_AGE seconds of history; older entries are
; removed when a new one is added.
;
; Included from terminal_linux.asm, after ash/script.asm.
; ============================================================================

%define BENCH_DEFAULT_RUNS  10
%define BENCH_MAX_RUNS      100000
%define TL_SYS_LSTAT        6
%define TL_SYS_FCNTL        72
%define TL_SYS_FLOCK        73
%define TL_SYS_FTRUNCATE    77
%define TL_SYS_SYMLINK      88
%define TL_SYS_FCHMOD       91
%define TL_SYS_TIME         201
%define TL_SYS_UTIMENSAT    280
%define TL_SYS_RENAMEAT2    316
%define TL_F_DUPFD_CLOEXEC  1030
%define TL_LOCK_EX          2
%define TL_O_EXCL           0x80
%define TL_RENAME_NOREPLACE 1
%define TL_ENOENT           2
%define TL_EEXIST           17
%define TL_EXDEV            18
%define TL_EISDIR           21
%define TL_EINVAL           22
%define TL_EFBIG            27
%define TL_ENOSYS           38
%define TL_ESAME            1000        ; not a kernel errno: src is dst
%define TL_R_OK             4

%define UNDO_PATH           4096
%define TL_PATH_MAX         4096
%define TL_NAME_MAX         255
%define TL_COPY_BUF         65536
%define TRASH_MAX_BYTES     (512 * 1024 * 1024)
%define TRASH_MAX_AGE       (30 * 86400)
%define TL_JBUF_MAX         (256 * 1024)
%define TL_DENTS            8192

; one journal record: header, then A, B and the trash name, each NUL ended
%define J_LEN               0           ; u32 length of the whole record
%define J_TYPE              4           ; u32
%define J_SAVED             8           ; u32 1 = a replaced file sits in trash, 2 = move/copy already undone
%define J_WHEN              16          ; u64 time of the operation
%define J_SIZE              24          ; u64 bytes the trash holds for it
%define J_CMTIME            32          ; u64 copy: mtime of the new file
%define J_CSIZE             40          ; u64 copy: size of the new file
%define J_STR               48
%define UT_DEL              1
%define UT_MOVE             2
%define UT_COPY             3

section .data
    tl_s_dash_n         db "-n", 0
    tl_s_dash_f         db "-f", 0
    tl_s_bench          db "bench", 0
    tl_s_undo           db "undo", 0
    tl_s_trashcmd       db "trash", 0
    tl_s_empty          db "empty", 0
    tl_s_trash          db "/.asm_trash", 0
    tl_s_jname          db "/.journal", 0
    tl_s_jtmp           db "/.journal.tmp", 0
    tl_s_lockname       db "/.lock", 0
    tl_s_ns             db " ns", 0
    tl_s_us             db " us", 0
    tl_s_ms             db " ms", 0
    tl_s_sec            db " s", 0
    tl_s_dot            db ".", 0
    tl_s_bench_hdr      db "bench: ", 0
    tl_s_bench_runs1    db "  (", 0
    tl_s_bench_runs2    db " runs)", 10, 0
    tl_s_bench_run1     db " run)", 10, 0
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
    tl_s_bench_range    db "bench: N must be between 1 and 100000", 10, 0
    tl_s_bench_nonum    db "bench: -n needs a number", 10, 0
    tl_s_bench_long     db "bench: the command is too long", 10, 0
    tl_s_bench_nested   db "bench: cannot be nested", 10, 0

    tl_s_undo_none      db "undo: nothing to undo", 10, 0
    tl_s_undo_restored  db "undo: restored ", 0
    tl_s_undo_moved     db "undo: moved back ", 0
    tl_s_undo_removed   db "undo: removed copy ", 0
    tl_s_undo_arrow     db " -> ", 0
    tl_s_undo_exists    db "undo: target already exists: ", 0
    tl_s_undo_failed    db "undo: could not restore ", 0
    tl_s_undo_failmv    db "undo: could not move back ", 0
    tl_s_undo_failrm    db "undo: could not remove copy ", 0
    tl_s_undo_where     db "undo: the file is still in the trash: ", 0
    tl_s_undo_changed   db "undo: the copy was changed after it was made; it is now in the trash: ", 0
    tl_s_undo_gone      db "undo: the copy is already gone: ", 0
    tl_s_undo_keepold   db "undo: could not put back the file the command replaced: ", 0
    tl_s_undo_lp        db " (", 0
    tl_s_undo_rp        db ")", 10, 0

    tl_s_cp_same        db "copy: source and destination are the same file", 10, 0
    tl_s_cp_dir         db "copy: the source is a folder", 10, 0
    tl_s_exdev_dir      db "Error: a folder cannot be moved to another filesystem", 10, 0
    tl_s_same_file      db "Error: source and destination are the same file", 10, 0

    tl_s_cannot1        db ": cannot keep ", 0
    tl_s_cannot2        db " in the trash (", 0
    tl_s_cannot3        db "); nothing was changed.", 10, "Use '", 0
    tl_s_cannot4        db " -f ...' to go ahead without undo.", 10, 0
    tl_s_norecord1      db ": done, but the undo record could not be written (", 0
    tl_s_norecord2      db ")", 10, 0
    tl_s_name_del       db "del", 0
    tl_s_name_copy      db "copy", 0
    tl_s_name_move      db "move", 0
    tl_s_name_undo      db "undo", 0

    tl_r_nohome         db "HOME is not set to a full path", 0
    tl_r_perm           db "permission denied", 0
    tl_r_eperm          db "operation not permitted", 0
    tl_r_noent          db "no such file or directory", 0
    tl_r_exists         db "already exists", 0
    tl_r_xdev           db "different filesystem", 0
    tl_r_notdir         db "not a folder", 0
    tl_r_isdir          db "is a folder", 0
    tl_r_big            db "larger than the 512 MiB trash limit", 0
    tl_r_nospace        db "no space left on device", 0
    tl_r_ro             db "read-only file system", 0
    tl_r_long           db "path too long", 0
    tl_r_kind           db "this kind of file cannot be kept", 0

    tl_s_trash_none     db "trash: empty", 10, 0
    tl_s_trash_hdr1     db "trash: ", 0
    tl_s_trash_hdr2     db " entries, ", 0
    tl_s_trash_hdr3     db " kept in ", 0
    tl_s_trash_usage    db "Usage: trash [empty]", 10, 0
    tl_s_trash_emptied1 db "trash: emptied (", 0
    tl_s_trash_emptied2 db " files removed)", 10, 0
    tl_s_t_del          db "del   ", 0
    tl_s_t_move         db "move  ", 0
    tl_s_t_copy         db "copy  ", 0
    tl_s_2sp            db "  ", 0

section .bss
    alignb 8
    tl_t0               resq 2
    tl_t1               resq 2
    tl_sum              resq 1
    tl_min              resq 1
    tl_max              resq 1
    tl_peak             resq 1
    bench_active        resb 1
    alignb 4
    tl_trash_seq        resd 1
    tl_err              resd 1          ; errno of the last trash failure, 0 = no usable HOME
    tl_lockfd           resd 1
    tl_jlen             resd 1
    tl_stage            resb 1          ; copy: 1 src open, 2 dst open, 3 read, 4 write
    alignb 8
    tl_held             resq 1          ; bytes the last stash put in the trash
    tl_chk_mtime        resq 1
    tl_chk_size         resq 1
    tl_path_a           resb TL_PATH_MAX
    tl_path_b           resb TL_PATH_MAX
    tl_path_t           resb TL_PATH_MAX        ; full path of the trash file
    tl_path_s           resb TL_PATH_MAX        ; scratch
    tl_base             resb TL_PATH_MAX        ; $HOME/.asm_trash
    tl_jpath            resb TL_PATH_MAX
    tl_jpath2           resb TL_PATH_MAX
    tl_lbuf             resb TL_PATH_MAX        ; readlink target
    tl_tname            resb TL_NAME_MAX + 1    ; name of the trash file
    tl_numbuf           resb 32
    tl_stat             resb 144
    tl_stat2            resb 144
    tl_stat3            resb 144
    tl_cmd_buf          resb MAX_INPUT
    bench_cmd_buf       resb MAX_INPUT
    tl_dents            resb TL_DENTS
    tl_copy_buf         resb TL_COPY_BUF
    tl_jbuf             resb TL_JBUF_MAX

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
    sub rsp, 24                     ; [rsp + 4 * fd]: copy of fd 0, 1 and 2

    test rdi, rdi
    jz .bn_usage
    cmp byte [bench_active], 0
    jne .bn_nested
    mov r12, rdi                    ; command text
    mov r13d, BENCH_DEFAULT_RUNS

    mov rdi, r12
    lea rsi, [tl_s_dash_n]
    call ash_word_is
    test eax, eax
    jz .bn_cmd
    lea rdi, [r12 + 2]
    call ash_skip_blanks
    mov rsi, rax
    xor eax, eax                    ; value; stays just above the limit once over it
    xor ecx, ecx                    ; digits seen
.bn_digit:
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .bn_digits_end
    imul rax, rax, 10
    add rax, rdx
    cmp rax, BENCH_MAX_RUNS
    jbe .bn_digit_next
    mov eax, BENCH_MAX_RUNS + 1
.bn_digit_next:
    inc ecx
    inc rsi
    jmp .bn_digit
.bn_digits_end:
    test ecx, ecx
    jz .bn_nonum
    movzx edx, byte [rsi]           ; the number must be a word of its own
    test dl, dl
    jz .bn_num_ok
    cmp dl, ' '
    je .bn_num_ok
    cmp dl, 9
    jne .bn_nonum
.bn_num_ok:
    test eax, eax
    jz .bn_range
    cmp eax, BENCH_MAX_RUNS
    ja .bn_range
    mov r13d, eax
    mov rdi, rsi
    call ash_skip_blanks
    mov r12, rax
.bn_cmd:
    cmp byte [r12], 0
    je .bn_usage
    ; Own copy: each run reuses input_buf, where the text lives now
    mov rdi, r12
    call str_len
    cmp eax, MAX_INPUT - 1
    jae .bn_toolong
    lea rdi, [bench_cmd_buf]
    mov rsi, r12
    call str_copy
    lea r12, [bench_cmd_buf]
    mov byte [bench_active], 1

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
    cmp r13d, 1
    jne .bn_hdr_end
    lea rdi, [tl_s_bench_run1]
.bn_hdr_end:
    call print_cstring

    ; Hide the command's output and keep it off the keyboard: stdin, stdout
    ; and stderr point at /dev/null for the runs. The saved copies are close
    ; on exec so the commands never see them.
    mov dword [rsp], -1
    mov dword [rsp + 4], -1
    mov dword [rsp + 8], -1
    lea rdi, [upd_dev_null]
    mov esi, O_RDWR
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .bn_runs
    mov ebx, eax
    xor r14d, r14d
.bn_hide:
    mov edi, r14d
    mov esi, TL_F_DUPFD_CLOEXEC
    mov edx, 10
    mov eax, TL_SYS_FCNTL
    syscall
    test rax, rax
    js .bn_hide_next
    mov [rsp + r14 * 4], eax
    mov edi, ebx
    mov esi, r14d
    mov eax, SYS_DUP2
    syscall
.bn_hide_next:
    inc r14d
    cmp r14d, 3
    jb .bn_hide
    cmp ebx, 2
    jbe .bn_runs                    ; /dev/null took a standard fd: keep it
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
    xor ebx, ebx
.bn_unhide:
    mov edi, [rsp + rbx * 4]
    test edi, edi
    js .bn_unhide_next
    mov esi, ebx
    mov eax, SYS_DUP2
    syscall
    mov edi, [rsp + rbx * 4]
    mov eax, SYS_CLOSE
    syscall
.bn_unhide_next:
    inc ebx
    cmp ebx, 3
    jb .bn_unhide
    mov byte [bench_active], 0
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
.bn_nested:
    lea rdi, [tl_s_bench_nested]
    jmp .bn_err
.bn_range:
    lea rdi, [tl_s_bench_range]
    jmp .bn_err
.bn_nonum:
    lea rdi, [tl_s_bench_nonum]
    jmp .bn_err
.bn_toolong:
    lea rdi, [tl_s_bench_long]
.bn_err:
    call ash_write_err
    mov dword [last_exit_status], 2
    jmp .bn_ret
.bn_usage:
    lea rdi, [tl_s_bench_usage]
    call print_cstring
    mov dword [last_exit_status], 2
.bn_ret:
    add rsp, 24
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
; trash, journal and undo support
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

; tl_reason(edi = errno) -> rax = short description (0 means no usable HOME)
tl_reason:
    lea rax, [tl_r_nohome]
    test edi, edi
    jz .rs_ret
    lea rax, [tl_r_eperm]
    cmp edi, 1
    je .rs_ret
    lea rax, [tl_r_noent]
    cmp edi, TL_ENOENT
    je .rs_ret
    lea rax, [tl_r_perm]
    cmp edi, EACCES
    je .rs_ret
    lea rax, [tl_r_exists]
    cmp edi, TL_EEXIST
    je .rs_ret
    lea rax, [tl_r_xdev]
    cmp edi, TL_EXDEV
    je .rs_ret
    lea rax, [tl_r_notdir]
    cmp edi, 20
    je .rs_ret
    lea rax, [tl_r_isdir]
    cmp edi, TL_EISDIR
    je .rs_ret
    lea rax, [tl_r_big]
    cmp edi, TL_EFBIG
    je .rs_ret
    lea rax, [tl_r_nospace]
    cmp edi, 28
    je .rs_ret
    lea rax, [tl_r_ro]
    cmp edi, 30
    je .rs_ret
    lea rax, [tl_r_long]
    cmp edi, 36
    je .rs_ret
    lea rax, [tl_r_kind]
    cmp edi, TL_ESAME
    je .rs_ret
    ; anything else: "error N"
    push rbx
    mov esi, edi
    lea rbx, [tl_numbuf]
    mov dword [rbx], "erro"
    mov word [rbx + 4], "r "
    lea rdi, [rbx + 6]
    call ash_fmt_int
    mov rax, rbx
    pop rbx
.rs_ret:
    ret

; tl_perr(edi = errno) - "Error: ..." line on stdout, like the other builtins
tl_perr:
    cmp edi, TL_ESAME
    je .pe_same
    cmp edi, TL_EXDEV
    je .pe_xdev
    jmp print_last_error
.pe_same:
    sub rsp, 8
    lea rdi, [tl_s_same_file]
    call print_cstring
    add rsp, 8
    ret
.pe_xdev:
    sub rsp, 8
    lea rdi, [tl_s_exdev_dir]
    call print_cstring
    add rsp, 8
    ret

; tl_refuse(rdi = command name, rsi = file, edx = errno)
; "<cmd>: cannot keep <file> in the trash (<why>); nothing was changed." on stderr
tl_refuse:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    call ash_write_err              ; rdi still the command name
    lea rdi, [tl_s_cannot1]
    call ash_write_err
    mov rdi, r12
    call ash_write_err
    lea rdi, [tl_s_cannot2]
    call ash_write_err
    mov edi, r13d
    call tl_reason
    mov rdi, rax
    call ash_write_err
    lea rdi, [tl_s_cannot3]
    call ash_write_err
    mov rdi, rbx
    call ash_write_err
    lea rdi, [tl_s_cannot4]
    call ash_write_err
    pop r13
    pop r12
    pop rbx
    ret

; tl_trash_base() -> eax 1 ok / 0 failed (tl_err = errno, 0 = HOME unusable)
; Builds "$HOME/.asm_trash" in tl_base and creates the folder (mode 0700).
tl_trash_base:
    push rbx
    mov dword [tl_err], 0
    lea rdi, [str_home]
    call getenv_internal
    test rax, rax
    jz .tb_fail
    cmp byte [rax], '/'
    jne .tb_fail                    ; unset, empty or relative HOME
    mov rbx, rax
    mov rdi, rbx
    call str_len
    cmp eax, TL_PATH_MAX - 400      ; room for "/.asm_trash/" and a 255 byte name
    jae .tb_long
    lea rdi, [tl_base]
    mov rsi, rbx
    call upd_stpcpy
    mov rdi, rax
    lea rsi, [tl_s_trash]
    call upd_stpcpy
    lea rdi, [tl_base]
    mov esi, 0o700
    mov eax, SYS_MKDIR
    syscall
    test rax, rax
    jns .tb_ok
    cmp rax, -TL_EEXIST
    je .tb_ok
    neg eax
    mov [tl_err], eax
    jmp .tb_fail
.tb_long:
    mov dword [tl_err], 36
    jmp .tb_fail
.tb_ok:
    mov eax, 1
    pop rbx
    ret
.tb_fail:
    xor eax, eax
    pop rbx
    ret

; tl_copy_fds(edi = source fd, esi = destination fd) -> eax 0 / -errno
; Sets tl_stage to 3 (read) or 4 (write) when it fails.
tl_copy_fds:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov ebx, edi
    mov r12d, esi
.cf_read:
    mov byte [tl_stage], 3
    mov edi, ebx
    lea rsi, [tl_copy_buf]
    mov edx, TL_COPY_BUF
    mov eax, SYS_READ
    syscall
    cmp rax, -EINTR
    je .cf_read
    test rax, rax
    jz .cf_done
    js .cf_ret
    mov r13, rax                    ; bytes left to write
    lea r14, [tl_copy_buf]
    mov byte [tl_stage], 4
.cf_write:
    mov edi, r12d
    mov rsi, r14
    mov rdx, r13
    mov eax, SYS_WRITE
    syscall
    cmp rax, -EINTR
    je .cf_write
    test rax, rax
    jg .cf_wrote
    jnz .cf_ret                     ; error
    mov rax, -5                     ; wrote nothing: EIO, never loop forever
    jmp .cf_ret
.cf_wrote:
    add r14, rax
    sub r13, rax
    jnz .cf_write
    jmp .cf_read
.cf_done:
    xor eax, eax
.cf_ret:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; tl_copy_file(rdi = src, rsi = dst, edx = flags) -> eax 0 / errno
; flags: bit 0 keep the exact mode and times, bit 1 fail when dst exists.
; A folder is refused and dst is not truncated before it is known to be a
; different file than src. tl_stage says where it failed (1 src, 2 dst,
; 3 read, 4 write).
tl_copy_file:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov r12, rdi
    mov r13, rsi
    mov r14d, edx
    mov byte [tl_stage], 1
    mov rdi, r12
    mov esi, O_RDONLY | O_CLOEXEC
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .cp_fail
    mov ebx, eax                    ; source fd
    mov edi, ebx
    lea rsi, [tl_stat2]
    mov eax, SYS_FSTAT
    syscall
    test rax, rax
    js .cp_fail_src
    mov eax, [tl_stat2 + STAT_ST_MODE]
    and eax, ASH_S_IFMT
    cmp eax, ASH_S_IFDIR
    jne .cp_open_dst
    mov rax, -TL_EISDIR
    jmp .cp_fail_src
.cp_open_dst:
    mov byte [tl_stage], 2
    mov rdi, r13
    mov esi, O_WRONLY | O_CREAT | O_CLOEXEC
    test r14d, 2
    jz .cp_flags
    or esi, TL_O_EXCL
.cp_flags:
    mov edx, [tl_stat2 + STAT_ST_MODE]
    and edx, 0o777
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .cp_fail_src
    mov r15d, eax                   ; destination fd
    test r14d, 2
    jnz .cp_copy                    ; created just now, cannot be the source
    mov edi, r15d
    lea rsi, [tl_stat3]
    mov eax, SYS_FSTAT
    syscall
    test rax, rax
    js .cp_fail_both
    mov rax, [tl_stat3]             ; st_dev
    cmp rax, [tl_stat2]
    jne .cp_trunc
    mov rax, [tl_stat3 + 8]         ; st_ino
    cmp rax, [tl_stat2 + 8]
    jne .cp_trunc
    mov rax, -TL_ESAME
    jmp .cp_fail_both
.cp_trunc:
    mov eax, [tl_stat3 + STAT_ST_MODE]
    and eax, ASH_S_IFMT
    cmp eax, ASH_S_IFREG
    jne .cp_copy                    ; a device or pipe: nothing to truncate
    mov edi, r15d
    xor esi, esi
    mov eax, TL_SYS_FTRUNCATE
    syscall
    mov byte [tl_stage], 2
    test rax, rax
    js .cp_fail_both
.cp_copy:
    mov edi, ebx
    mov esi, r15d
    call tl_copy_fds
    test eax, eax
    jnz .cp_fail_both
    test r14d, 1
    jz .cp_close
    mov edi, r15d
    mov esi, [tl_stat2 + STAT_ST_MODE]
    and esi, 0o7777
    mov eax, TL_SYS_FCHMOD
    syscall
    mov edi, r15d
    xor esi, esi                    ; no path: the descriptor is the file
    lea rdx, [tl_stat2 + 72]        ; st_atim, st_mtim
    xor r10d, r10d
    mov eax, TL_SYS_UTIMENSAT
    syscall
.cp_close:
    mov edi, r15d
    mov eax, SYS_CLOSE
    syscall
    mov r14, rax                    ; a late write error shows up here
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall
    xor eax, eax
    test r14, r14
    jns .cp_ret
    mov byte [tl_stage], 4
    mov eax, r14d
    neg eax
    jmp .cp_ret
.cp_fail_both:
    mov r14, rax
    mov edi, r15d
    mov eax, SYS_CLOSE
    syscall
    mov rax, r14
.cp_fail_src:
    mov r14, rax
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall
    mov rax, r14
.cp_fail:
    neg eax
.cp_ret:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; tl_xmove(rdi = src, rsi = dst, edx = 1 to fail when dst exists) -> eax 0 / errno
; Move across filesystems: copy a file or link, then delete the original.
; Anything else (folders, devices) is left alone and reported as EXDEV.
tl_xmove:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    mov ebx, edx
    mov rdi, r12
    lea rsi, [tl_stat]
    mov eax, TL_SYS_LSTAT
    syscall
    test rax, rax
    js .xm_neg
    mov eax, [tl_stat + STAT_ST_MODE]
    and eax, ASH_S_IFMT
    cmp eax, ASH_S_IFLNK
    je .xm_link
    cmp eax, ASH_S_IFREG
    jne .xm_exdev
    mov rdi, r12
    mov rsi, r13
    mov edx, 1
    test ebx, ebx
    jz .xm_copy
    or edx, 2
.xm_copy:
    call tl_copy_file
    test eax, eax
    jnz .xm_ret
    jmp .xm_unlink
.xm_link:
    mov rdi, r12
    lea rsi, [tl_lbuf]
    mov edx, TL_PATH_MAX - 1
    mov eax, SYS_READLINK
    syscall
    test rax, rax
    js .xm_neg
    mov byte [tl_lbuf + rax], 0
    lea rdi, [tl_lbuf]
    mov rsi, r13
    mov eax, TL_SYS_SYMLINK
    syscall
    test rax, rax
    js .xm_neg
.xm_unlink:
    mov rdi, r12
    mov eax, SYS_UNLINK
    syscall
    test rax, rax
    jns .xm_ok
    mov ebx, eax
    neg ebx                         ; keep the original and drop the half-made copy
    mov rdi, r13
    mov eax, SYS_UNLINK
    syscall
    mov eax, ebx
    jmp .xm_ret
.xm_ok:
    xor eax, eax
    jmp .xm_ret
.xm_exdev:
    mov eax, TL_EXDEV
    jmp .xm_ret
.xm_neg:
    neg eax
.xm_ret:
    pop r13
    pop r12
    pop rbx
    ret

; tl_rename_x(rdi = src, rsi = dst) -> eax 0 / errno
; rename(2), or a copy and delete when the two are on different filesystems.
tl_rename_x:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov eax, SYS_RENAME
    syscall
    test rax, rax
    jns .rx_ok
    cmp rax, -TL_EXDEV
    je .rx_xdev
    neg eax
    jmp .rx_ret
.rx_xdev:
    mov rdi, rbx
    mov rsi, r12
    xor edx, edx
    call tl_xmove
    jmp .rx_ret
.rx_ok:
    xor eax, eax
.rx_ret:
    pop r13
    pop r12
    pop rbx
    ret

; tl_stash(rdi = absolute path) -> eax 1 if the file now sits in the trash
; On success tl_tname holds the trash file name, tl_path_t its full path and
; tl_held the bytes kept. On failure tl_err is the errno (0 = no usable HOME,
; EFBIG = over the size limit). The name never replaces an existing file.
tl_stash:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8                      ; [rsp] = write cursor
    mov r12, rdi
    mov rdi, r12
    lea rsi, [tl_stat]
    mov eax, TL_SYS_LSTAT
    syscall
    test rax, rax
    js .st_neg
    mov eax, [tl_stat + STAT_ST_MODE]
    and eax, ASH_S_IFMT
    cmp eax, ASH_S_IFDIR
    je .st_isdir
    mov rax, [tl_stat + STAT_ST_SIZE]
    mov [tl_held], rax
    cmp rax, TRASH_MAX_BYTES
    ja .st_big
    call tl_trash_base
    test eax, eax
    jz .st_fail
    ; the file's own name: what follows the last '/'
    mov r13, r12
    mov rsi, r12
.st_base:
    mov al, [rsi]
    test al, al
    jz .st_base_end
    inc rsi
    cmp al, '/'
    jne .st_base
    mov r13, rsi
    jmp .st_base
.st_base_end:
    lea rdi, [tl_path_t]
    lea rsi, [tl_base]
    call upd_stpcpy
    mov byte [rax], '/'
    lea rbx, [rax + 1]              ; where the name starts
    xor r14d, r14d                  ; attempts
.st_try:
    mov eax, TL_SYS_TIME
    xor edi, edi
    syscall
    mov rsi, rax
    mov rdi, rbx
    call ash_fmt_int
    mov byte [rax], '.'
    inc rax
    mov [rsp], rax
    mov eax, ASH_SYS_GETPID
    syscall
    mov rsi, rax
    mov rdi, [rsp]
    call ash_fmt_int
    mov byte [rax], '.'
    inc rax
    inc dword [tl_trash_seq]
    mov esi, [tl_trash_seq]
    mov rdi, rax
    call ash_fmt_int
    mov byte [rax], '.'
    inc rax
    lea rcx, [rbx + TL_NAME_MAX - 1]
    mov rsi, r13
.st_cp:
    mov dl, [rsi]
    test dl, dl
    jz .st_cp_end
    cmp rax, rcx
    jae .st_cp_end
    mov [rax], dl
    inc rax
    inc rsi
    jmp .st_cp
.st_cp_end:
    mov byte [rax], 0
    lea rdi, [tl_tname]
    mov rsi, rbx
    call upd_stpcpy
    ; rename without replacing anything
    mov rdi, AT_FDCWD
    mov rsi, r12
    mov rdx, AT_FDCWD
    lea r10, [tl_path_t]
    mov r8d, TL_RENAME_NOREPLACE
    mov eax, TL_SYS_RENAMEAT2
    syscall
    test rax, rax
    jz .st_ok
    cmp rax, -TL_EEXIST
    je .st_again
    cmp rax, -TL_EINVAL
    je .st_plain
    cmp rax, -TL_ENOSYS
    je .st_plain
    cmp rax, -TL_EXDEV
    je .st_xdev
    jmp .st_neg
.st_again:
    inc r14d
    cmp r14d, 64
    jb .st_try
    mov dword [tl_err], TL_EEXIST
    jmp .st_fail
.st_plain:
    ; the filesystem has no RENAME_NOREPLACE: check the name is free first
    lea rdi, [tl_path_t]
    lea rsi, [tl_stat2]
    mov eax, TL_SYS_LSTAT
    syscall
    test rax, rax
    jns .st_again                   ; taken: try the next number
    mov rdi, r12
    lea rsi, [tl_path_t]
    mov eax, SYS_RENAME
    syscall
    test rax, rax
    jz .st_ok
    cmp rax, -TL_EXDEV
    jne .st_neg
.st_xdev:
    mov rdi, r12
    lea rsi, [tl_path_t]
    mov edx, 1
    call tl_xmove
    test eax, eax
    jz .st_ok
    cmp eax, TL_EEXIST
    je .st_again
    cmp eax, TL_EXDEV
    jne .st_err_eax
    mov eax, TL_ESAME               ; a folder, device or pipe: not something to keep
.st_err_eax:
    mov [tl_err], eax
    jmp .st_fail
.st_ok:
    mov eax, 1
    jmp .st_ret
.st_isdir:
    mov dword [tl_err], TL_EISDIR
    jmp .st_fail
.st_big:
    mov dword [tl_err], TL_EFBIG
    jmp .st_fail
.st_neg:
    neg eax
    mov [tl_err], eax
.st_fail:
    xor eax, eax
.st_ret:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ---------- journal ----------

; tl_j_begin() -> eax 1 ok / 0 failed (tl_err)
; Takes the trash lock (so two shells cannot lose each other's entries) and
; loads ~/.asm_trash/.journal into tl_jbuf, keeping only whole records.
tl_j_begin:
    push rbx
    push r12
    sub rsp, 8
    mov dword [tl_jlen], 0
    mov dword [tl_lockfd], -1
    call tl_trash_base
    test eax, eax
    jz .jb_ret
    lea rdi, [tl_jpath]
    lea rsi, [tl_base]
    call upd_stpcpy
    mov rdi, rax
    lea rsi, [tl_s_lockname]
    call upd_stpcpy
    lea rdi, [tl_jpath]
    mov esi, O_RDWR | O_CREAT | O_CLOEXEC
    mov edx, 0o600
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .jb_load                     ; cannot lock: go on without
    mov [tl_lockfd], eax
.jb_flock:
    mov edi, [tl_lockfd]
    mov esi, TL_LOCK_EX
    mov eax, TL_SYS_FLOCK
    syscall
    cmp rax, -EINTR
    je .jb_flock
.jb_load:
    lea rdi, [tl_jpath]
    lea rsi, [tl_base]
    call upd_stpcpy
    mov rdi, rax
    lea rsi, [tl_s_jname]
    call upd_stpcpy
    lea rdi, [tl_jpath]
    mov esi, O_RDONLY | O_CLOEXEC
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .jb_ok                       ; no journal yet
    mov ebx, eax
    xor r12d, r12d                  ; bytes read
.jb_read:
    mov edi, ebx
    lea rsi, [tl_jbuf + r12]
    mov edx, TL_JBUF_MAX
    sub edx, r12d
    jz .jb_read_end
    mov eax, SYS_READ
    syscall
    cmp rax, -EINTR
    je .jb_read
    test rax, rax
    jle .jb_read_end
    add r12d, eax
    jmp .jb_read
.jb_read_end:
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall
    ; keep the leading run of well-formed records
    xor ecx, ecx
.jb_rec:
    lea eax, [rcx + J_STR + 3]
    cmp eax, r12d
    ja .jb_valid_end
    mov eax, [tl_jbuf + rcx + J_LEN]
    cmp eax, J_STR + 3
    jb .jb_valid_end
    lea r8d, [rcx + rax]            ; end of this record
    cmp r8d, r12d
    ja .jb_valid_end
    lea rsi, [tl_jbuf + rcx + J_STR]
    lea r9, [tl_jbuf + r8]
    mov r10d, 3                     ; three NUL ended strings
.jb_str:
    cmp rsi, r9
    jae .jb_valid_end
    cmp byte [rsi], 0
    je .jb_nul
    inc rsi
    jmp .jb_str
.jb_nul:
    inc rsi
    dec r10d
    jnz .jb_str
    cmp rsi, r9
    jne .jb_valid_end
    mov ecx, r8d
    jmp .jb_rec
.jb_valid_end:
    mov [tl_jlen], ecx
.jb_ok:
    mov eax, 1
.jb_ret:
    add rsp, 8
    pop r12
    pop rbx
    ret

; tl_j_end(edi = 1 to write the journal back) -> eax 0 / errno
; Writes tl_jbuf to a temporary file and renames it over .journal, then
; releases the lock.
tl_j_end:
    push rbx
    push r12
    push r13
    mov r12d, edi
    xor r13d, r13d                  ; result
    test r12d, r12d
    jz .je_unlock
    lea rdi, [tl_jpath]
    lea rsi, [tl_base]
    call upd_stpcpy
    mov rdi, rax
    lea rsi, [tl_s_jtmp]
    call upd_stpcpy
    lea rdi, [tl_jpath2]
    lea rsi, [tl_base]
    call upd_stpcpy
    mov rdi, rax
    lea rsi, [tl_s_jname]
    call upd_stpcpy
    lea rdi, [tl_jpath]
    mov esi, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC
    mov edx, 0o600
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .je_open_err
    mov ebx, eax
    xor r12d, r12d                  ; bytes written
.je_write:
    mov edx, [tl_jlen]
    sub edx, r12d
    jz .je_written
    mov edi, ebx
    lea rsi, [tl_jbuf + r12]
    mov eax, SYS_WRITE
    syscall
    cmp rax, -EINTR
    je .je_write
    test rax, rax
    jle .je_write_err
    add r12d, eax
    jmp .je_write
.je_written:
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall
    test rax, rax
    js .je_close_err
    lea rdi, [tl_jpath]
    lea rsi, [tl_jpath2]
    mov eax, SYS_RENAME
    syscall
    test rax, rax
    jns .je_unlock
    neg eax
    mov r13d, eax
    jmp .je_drop_tmp
.je_write_err:
    mov r13d, 5                     ; EIO, or the real error below
    test rax, rax
    jns .je_close_tmp
    mov r13d, eax
    neg r13d
.je_close_tmp:
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall
    jmp .je_drop_tmp
.je_close_err:
    neg eax
    mov r13d, eax
    jmp .je_drop_tmp
.je_open_err:
    neg eax
    mov r13d, eax
    jmp .je_unlock
.je_drop_tmp:
    lea rdi, [tl_jpath]
    mov eax, SYS_UNLINK
    syscall
.je_unlock:
    mov edi, [tl_lockfd]
    test edi, edi
    js .je_ret
    mov eax, SYS_CLOSE
    syscall
    mov dword [tl_lockfd], -1
.je_ret:
    mov eax, r13d
    pop r13
    pop r12
    pop rbx
    ret

; tl_j_drop_first() -> rax = bytes of trash it was holding
; Forgets the oldest record and deletes the trash file it points at.
tl_j_drop_first:
    push rbx
    push r12
    sub rsp, 8
    mov ebx, [tl_jbuf + J_LEN]
    mov r12, [tl_jbuf + J_SIZE]
    lea rsi, [tl_jbuf + J_STR]
.df_a:
    cmp byte [rsi], 0               ; skip A
    je .df_a_end
    inc rsi
    jmp .df_a
.df_a_end:
    inc rsi
.df_b:
    cmp byte [rsi], 0               ; skip B
    je .df_b_end
    inc rsi
    jmp .df_b
.df_b_end:
    inc rsi                         ; rsi = trash name
    cmp byte [rsi], 0
    je .df_forget
    push rsi
    sub rsp, 8
    lea rdi, [tl_path_s]
    lea rsi, [tl_base]
    call upd_stpcpy
    mov byte [rax], '/'
    lea rdi, [rax + 1]
    mov rsi, [rsp + 8]
    call upd_stpcpy
    lea rdi, [tl_path_s]
    mov eax, SYS_UNLINK
    syscall
    add rsp, 16
.df_forget:
    lea rdi, [tl_jbuf]
    lea rsi, [tl_jbuf + rbx]
    mov ecx, [tl_jlen]
    sub ecx, ebx
    cld
    rep movsb
    sub [tl_jlen], ebx
    mov rax, r12
    add rsp, 8
    pop r12
    pop rbx
    ret

; tl_j_trim(edi = bytes the new record needs, rsi = bytes it will keep)
; Drops records older than TRASH_MAX_AGE, then the oldest ones until the new
; entry fits under TRASH_MAX_BYTES and in the journal buffer.
tl_j_trim:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8
    mov r12d, edi
    mov r13, rsi
    mov eax, TL_SYS_TIME
    xor edi, edi
    syscall
    sub rax, TRASH_MAX_AGE
    mov rbx, rax                    ; cutoff
    xor r14d, r14d                  ; total held (summed below)
.tj_age:
    cmp dword [tl_jlen], 0
    je .tj_sum
    cmp [tl_jbuf + J_WHEN], rbx
    jge .tj_sum
    call tl_j_drop_first
    jmp .tj_age
.tj_sum:
    xor ecx, ecx
    xor r14d, r14d
.tj_sum_loop:
    cmp ecx, [tl_jlen]
    jae .tj_fit
    add r14, [tl_jbuf + rcx + J_SIZE]
    add ecx, [tl_jbuf + rcx + J_LEN]
    jmp .tj_sum_loop
.tj_fit:
    cmp dword [tl_jlen], 0
    je .tj_ret
    lea rax, [r14 + r13]
    cmp rax, TRASH_MAX_BYTES
    ja .tj_drop
    mov eax, [tl_jlen]
    add eax, r12d
    cmp eax, TL_JBUF_MAX
    jbe .tj_ret
.tj_drop:
    call tl_j_drop_first
    sub r14, rax
    jmp .tj_fit
.tj_ret:
    add rsp, 8
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; undo_record(edi = type, esi = saved) -> eax 1 recorded / 0 not recorded
; Appends an entry for tl_path_a, tl_path_b and the last stash (tl_tname,
; tl_held) to the journal. tl_err is the errno when it fails.
undo_record:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13d, esi
    test r13d, r13d
    jnz .ur_have_name
    mov byte [tl_tname], 0
    mov qword [tl_held], 0
.ur_have_name:
    call tl_j_begin
    test eax, eax
    jz .ur_fail
    lea rdi, [tl_path_a]
    call str_len
    mov ebx, eax
    lea rdi, [tl_path_b]
    call str_len
    add ebx, eax
    lea rdi, [tl_tname]
    call str_len
    add ebx, eax
    add ebx, J_STR + 3              ; ebx = record length
    mov edi, ebx
    mov rsi, [tl_held]
    call tl_j_trim
    mov eax, [tl_jlen]
    lea r14, [tl_jbuf + rax]
    mov [r14 + J_LEN], ebx
    mov [r14 + J_TYPE], r12d
    mov [r14 + J_SAVED], r13d
    mov dword [r14 + 12], 0
    mov eax, TL_SYS_TIME
    xor edi, edi
    syscall
    mov [r14 + J_WHEN], rax
    mov rax, [tl_held]
    mov [r14 + J_SIZE], rax
    mov rax, [tl_chk_mtime]
    mov [r14 + J_CMTIME], rax
    mov rax, [tl_chk_size]
    mov [r14 + J_CSIZE], rax
    lea rdi, [r14 + J_STR]
    lea rsi, [tl_path_a]
    call upd_stpcpy
    lea rdi, [rax + 1]
    lea rsi, [tl_path_b]
    call upd_stpcpy
    lea rdi, [rax + 1]
    lea rsi, [tl_tname]
    call upd_stpcpy
    add [tl_jlen], ebx
    mov edi, 1
    call tl_j_end
    mov qword [tl_chk_mtime], 0
    mov qword [tl_chk_size], 0
    test eax, eax
    jnz .ur_save_err
    mov eax, 1
    jmp .ur_ret
.ur_save_err:
    mov [tl_err], eax
    jmp .ur_fail
.ur_fail:
    mov qword [tl_chk_mtime], 0
    mov qword [tl_chk_size], 0
    xor eax, eax
.ur_ret:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; tl_warn_record(rdi = command name) - the work is done but not journaled
tl_warn_record:
    push rbx
    mov rbx, rdi
    call ash_write_err
    lea rdi, [tl_s_norecord1]
    call ash_write_err
    mov edi, [tl_err]
    call tl_reason
    mov rdi, rax
    call ash_write_err
    lea rdi, [tl_s_norecord2]
    call ash_write_err
    pop rbx
    ret

; tl_parse_force(rdi = args or 0) -> rax = args after an optional "-f",
; edx = 1 when -f was given
tl_parse_force:
    xor edx, edx
    test rdi, rdi
    jz .pf_ret0
    push rbx
    mov rbx, rdi
    lea rsi, [tl_s_dash_f]
    call ash_word_is
    test eax, eax
    jz .pf_none
    lea rdi, [rbx + 2]
    call ash_skip_blanks
    mov edx, 1
    pop rbx
    ret
.pf_none:
    mov rax, rbx
    xor edx, edx
    pop rbx
    ret
.pf_ret0:
    xor eax, eax
    ret

; ---------- del [-f] FILE (keeps a copy in the trash for undo) ----------
handler_del_safe:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 8
    mov dword [last_exit_status], 0
    call tl_parse_force
    mov rbx, rax                    ; the file name (rest of the line)
    mov r12d, edx                   ; -f given
    test rbx, rbx
    jz .ds_plain
    cmp byte [rbx], 0
    je .ds_plain
    test r12d, r12d
    jnz .ds_plain                   ; del -f: no trash, no undo
    mov rdi, rbx
    lea rsi, [tl_stat]
    mov eax, TL_SYS_LSTAT
    syscall
    test rax, rax
    js .ds_plain                    ; missing: handler_del reports it
    mov eax, [tl_stat + STAT_ST_MODE]
    and eax, ASH_S_IFMT
    cmp eax, ASH_S_IFDIR
    je .ds_plain                    ; a folder: handler_del reports it
    mov rdi, rbx
    lea rsi, [tl_path_a]
    call tl_abspath
    test eax, eax
    jnz .ds_stash
    mov edx, 36
    jmp .ds_refuse
.ds_stash:
    lea rdi, [tl_path_a]
    call tl_stash
    test eax, eax
    jnz .ds_kept
    mov edx, [tl_err]
.ds_refuse:
    lea rdi, [tl_s_name_del]
    mov rsi, rbx
    call tl_refuse
    mov dword [last_exit_status], 1
    jmp .ds_ret
.ds_kept:
    mov byte [tl_path_b], 0
    mov edi, UT_DEL
    mov esi, 1
    call undo_record
    test eax, eax
    jnz .ds_ret
    lea rdi, [tl_s_name_del]
    call tl_warn_record
    jmp .ds_ret
.ds_plain:
    mov rdi, rbx
    call handler_del
.ds_ret:
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ---------- move/rename [-f] SRC DST (saves an overwritten DST) ----------
handler_move_safe:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov dword [last_exit_status], 0
    call tl_parse_force
    mov r15d, edx                   ; -f given
    test rax, rax
    jz .ms_usage
    mov rdi, rax
    call parse_two_args
    test rax, rax
    jz .ms_usage
    mov r12, rax                    ; source as typed
    mov r13, rdx                    ; destination as typed
    xor r14d, r14d                  ; 1 once a replaced file sits in the trash
    mov rdi, r12
    lea rsi, [tl_path_a]
    call tl_abspath
    test eax, eax
    jz .ms_long
    mov rdi, r13
    lea rsi, [tl_path_b]
    call tl_abspath
    test eax, eax
    jz .ms_long

    lea rdi, [tl_path_a]
    lea rsi, [tl_stat]
    mov eax, TL_SYS_LSTAT
    syscall
    test rax, rax
    js .ms_errno
    lea rdi, [tl_path_b]
    lea rsi, [tl_stat2]
    mov eax, TL_SYS_LSTAT
    syscall
    test rax, rax
    js .ms_rename                   ; nothing at the destination yet
    mov rax, [tl_stat2]
    cmp rax, [tl_stat]
    jne .ms_dst_there
    mov rax, [tl_stat2 + 8]
    cmp rax, [tl_stat + 8]
    je .ms_ret                      ; the very same file: nothing to do
.ms_dst_there:
    mov eax, [tl_stat2 + STAT_ST_MODE]
    and eax, ASH_S_IFMT
    cmp eax, ASH_S_IFDIR
    je .ms_rename                   ; let rename decide about folders
    lea rdi, [tl_path_b]
    call tl_stash
    mov r14d, eax
    test eax, eax
    jnz .ms_rename
    test r15d, r15d
    jnz .ms_rename                  ; -f: overwrite without a trash copy
    mov edx, [tl_err]
    lea rdi, [tl_s_name_move]
    mov rsi, r13
    call tl_refuse
    mov dword [last_exit_status], 1
    jmp .ms_ret
.ms_rename:
    lea rdi, [tl_path_a]
    lea rsi, [tl_path_b]
    call tl_rename_x
    test eax, eax
    jnz .ms_failed
    mov edi, UT_MOVE
    mov esi, r14d
    call undo_record
    test eax, eax
    jnz .ms_ret
    lea rdi, [tl_s_name_move]
    call tl_warn_record
    jmp .ms_ret
.ms_failed:
    mov ebx, eax
    test r14d, r14d                 ; put the stashed file back
    jz .ms_failed_msg
    lea rdi, [tl_path_t]
    lea rsi, [tl_path_b]
    call tl_rename_x
.ms_failed_msg:
    mov edi, ebx
    call tl_perr
    mov dword [last_exit_status], 1
    jmp .ms_ret
.ms_errno:
    neg eax
    mov edi, eax
    call tl_perr
    mov dword [last_exit_status], 1
    jmp .ms_ret
.ms_long:
    ; without absolute paths there is no undo: only with -f
    test r15d, r15d
    jnz .ms_plain
    lea rdi, [tl_s_name_move]
    mov rsi, r12
    mov edx, 36
    call tl_refuse
    mov dword [last_exit_status], 1
    jmp .ms_ret
.ms_plain:
    mov rdi, r12
    mov rsi, r13
    call tl_rename_x
    test eax, eax
    jz .ms_ret
    mov edi, eax
    call tl_perr
    mov dword [last_exit_status], 1
    jmp .ms_ret
.ms_usage:
    lea rdi, [err_args_msg]
    mov esi, err_args_len
    call print_string_len
    mov dword [last_exit_status], 1
.ms_ret:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; tl_copy_report(eax = errno from tl_copy_file) - message for a failed copy
tl_copy_report:
    sub rsp, 8
    mov edi, eax
    cmp edi, TL_ESAME
    je .cr_same
    cmp edi, TL_EISDIR
    jne .cr_stage
    cmp byte [tl_stage], 1
    jne .cr_stage
    lea rdi, [tl_s_cp_dir]
    call print_cstring
    jmp .cr_ret
.cr_same:
    lea rdi, [tl_s_cp_same]
    call print_cstring
    jmp .cr_ret
.cr_stage:
    cmp byte [tl_stage], 3
    je .cr_read
    cmp byte [tl_stage], 4
    je .cr_write
    call tl_perr
    jmp .cr_ret
.cr_read:
    lea rdi, [err_copy_read_msg]
    mov esi, err_copy_read_len
    call print_string_len
    jmp .cr_ret
.cr_write:
    lea rdi, [err_copy_write_msg]
    mov esi, err_copy_write_len
    call print_string_len
.cr_ret:
    add rsp, 8
    ret

; tl_copy_cmd(rdi = src, rsi = dst) -> eax 0 ok / 1 failed (message printed)
tl_copy_cmd:
    sub rsp, 8
    xor edx, edx
    call tl_copy_file
    test eax, eax
    jz .cc_ok
    call tl_copy_report
    mov dword [last_exit_status], 1
    mov eax, 1
    jmp .cc_ret
.cc_ok:
    xor eax, eax
.cc_ret:
    add rsp, 8
    ret

; ---------- copy [-f] SRC DST (saves an overwritten DST) ----------
handler_copy_safe:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov dword [last_exit_status], 0
    call tl_parse_force
    mov r15d, edx                   ; -f given
    test rax, rax
    jz .cs_usage
    mov rdi, rax
    call parse_two_args
    test rax, rax
    jz .cs_usage
    mov r12, rax                    ; source as typed
    mov r13, rdx                    ; destination as typed
    mov r14d, 3                     ; 3 = no undo entry
    mov rdi, r13
    lea rsi, [tl_path_b]
    call tl_abspath
    test eax, eax
    jnz .cs_have_abs
    test r15d, r15d
    jnz .cs_copy                    ; -f: copy without undo
    lea rdi, [tl_s_name_copy]
    mov rsi, r13
    mov edx, 36
    call tl_refuse
    mov dword [last_exit_status], 1
    jmp .cs_ret
.cs_have_abs:
    ; same file? stat follows links, like the copy itself
    mov rdi, r12
    lea rsi, [tl_stat]
    mov eax, 4                      ; stat
    syscall
    test rax, rax
    js .cs_copy                     ; the copy reports the missing source
    mov rdi, r13
    lea rsi, [tl_stat2]
    mov eax, 4
    syscall
    test rax, rax
    js .cs_new                      ; destination does not exist yet
    mov rax, [tl_stat2]
    cmp rax, [tl_stat]
    jne .cs_exists
    mov rax, [tl_stat2 + 8]
    cmp rax, [tl_stat + 8]
    jne .cs_exists
    lea rdi, [tl_s_cp_same]
    call print_cstring
    mov dword [last_exit_status], 1
    jmp .cs_ret
.cs_new:
    mov r14d, 2                     ; 2 = new file
    jmp .cs_copy
.cs_exists:
    lea rdi, [tl_path_b]
    lea rsi, [tl_stat2]
    mov eax, TL_SYS_LSTAT
    syscall
    test rax, rax
    js .cs_copy
    mov eax, [tl_stat2 + STAT_ST_MODE]
    and eax, ASH_S_IFMT
    cmp eax, ASH_S_IFDIR
    je .cs_copy                     ; the copy reports "is a folder"
    mov rdi, r12
    mov esi, TL_R_OK
    mov eax, ASH_SYS_ACCESS
    syscall
    test rax, rax
    jnz .cs_copy                    ; unreadable source: the copy reports it
    lea rdi, [tl_path_b]
    call tl_stash
    mov r14d, eax                   ; 1 = old file saved
    test eax, eax
    jnz .cs_copy
    test r15d, r15d
    jnz .cs_force_ov
    mov edx, [tl_err]
    lea rdi, [tl_s_name_copy]
    mov rsi, r13
    call tl_refuse
    mov dword [last_exit_status], 1
    jmp .cs_ret
.cs_force_ov:
    mov r14d, 3
.cs_copy:
    mov rdi, r12
    mov rsi, r13
    call tl_copy_cmd
    test eax, eax
    jz .cs_ok
    ; failed: put things back as they were
    cmp r14d, 1
    jne .cs_failed_new
    mov rdi, r13
    mov eax, SYS_UNLINK
    syscall                         ; a half written copy
    lea rdi, [tl_path_t]
    lea rsi, [tl_path_b]
    call tl_rename_x
    jmp .cs_ret
.cs_failed_new:
    cmp r14d, 2
    jne .cs_ret
    ; the destination was created by this copy: do not leave a stub behind
    cmp byte [tl_stage], 2
    jbe .cs_ret                     ; it was never created
    lea rdi, [tl_path_b]
    mov eax, SYS_UNLINK
    syscall
    jmp .cs_ret
.cs_ok:
    cmp r14d, 3
    je .cs_ret
    lea rdi, [tl_path_b]
    lea rsi, [tl_stat]
    mov eax, TL_SYS_LSTAT
    syscall
    test rax, rax
    js .cs_ret
    mov rax, [tl_stat + 88]         ; st_mtim.tv_sec
    mov [tl_chk_mtime], rax
    mov rax, [tl_stat + STAT_ST_SIZE]
    mov [tl_chk_size], rax
    xor esi, esi
    cmp r14d, 1
    sete sil                        ; saved = 1 only when a file was replaced
    mov byte [tl_path_a], 0
    mov edi, UT_COPY
    call undo_record
    test eax, eax
    jnz .cs_ret
    lea rdi, [tl_s_name_copy]
    call tl_warn_record
    jmp .cs_ret
.cs_usage:
    lea rdi, [err_args_msg]
    mov esi, err_args_len
    call print_string_len
    mov dword [last_exit_status], 1
.cs_ret:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; tl_trash_file(rdi = journal name) - tl_path_t = "$base/<name>"
tl_trash_file:
    push rbx
    mov rbx, rdi
    lea rdi, [tl_path_t]
    lea rsi, [tl_base]
    call upd_stpcpy
    mov byte [rax], '/'
    lea rdi, [rax + 1]
    mov rsi, rbx
    call upd_stpcpy
    pop rbx
    ret

; ---------- undo ----------
handler_undo:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov dword [last_exit_status], 0
    call tl_j_begin
    test eax, eax
    jz .un_none_nolock
    xor ebx, ebx                    ; offset of the newest record
    xor ecx, ecx
    mov edx, [tl_jlen]
.un_last:
    cmp ecx, edx
    jae .un_found
    mov ebx, ecx
    add ecx, [tl_jbuf + rcx + J_LEN]
    jmp .un_last
.un_found:
    test edx, edx
    jz .un_none
    lea r12, [tl_jbuf + rbx]        ; the record
    lea r13, [r12 + J_STR]          ; A
    mov rsi, r13
.un_skip_a:
    cmp byte [rsi], 0
    je .un_a_end
    inc rsi
    jmp .un_skip_a
.un_a_end:
    inc rsi
    mov r14, rsi                    ; B
.un_skip_b:
    cmp byte [rsi], 0
    je .un_b_end
    inc rsi
    jmp .un_skip_b
.un_b_end:
    inc rsi
    mov r15, rsi                    ; trash name
    mov eax, [r12 + J_TYPE]
    cmp eax, UT_DEL
    je .un_del
    cmp eax, UT_MOVE
    je .un_move
    cmp eax, UT_COPY
    je .un_copy
    jmp .un_pop                     ; unknown record type: drop it

.un_del:
    mov rdi, r13
    call tl_exists
    test eax, eax
    jnz .un_exists_a
    mov rdi, r15
    call tl_trash_file
    lea rdi, [tl_path_t]
    mov rsi, r13
    call tl_rename_x
    test eax, eax
    jnz .un_fail_restore
    lea rdi, [tl_s_undo_restored]
    call print_cstring
    mov rdi, r13
    call print_cstring
    call print_newline
    jmp .un_pop

.un_move:
    cmp dword [r12 + J_SAVED], 2
    je .un_saved                    ; already moved back, file still to restore
    mov rdi, r13
    call tl_exists
    test eax, eax
    jnz .un_exists_a
    mov rdi, r14
    mov rsi, r13
    call tl_rename_x
    test eax, eax
    jnz .un_fail_move
    lea rdi, [tl_s_undo_moved]
    call print_cstring
    mov rdi, r14
    call print_cstring
    lea rdi, [tl_s_undo_arrow]
    call print_cstring
    mov rdi, r13
    call print_cstring
    call print_newline
    jmp .un_saved

.un_copy:
    cmp dword [r12 + J_SAVED], 2
    je .un_saved
    mov rdi, r14
    lea rsi, [tl_stat]
    mov eax, TL_SYS_LSTAT
    syscall
    test rax, rax
    js .un_copy_gone
    ; still the file the copy made? then it is safe to delete
    mov eax, [tl_stat + STAT_ST_MODE]
    and eax, ASH_S_IFMT
    cmp eax, ASH_S_IFREG
    jne .un_copy_changed
    mov rax, [tl_stat + STAT_ST_SIZE]
    cmp rax, [r12 + J_CSIZE]
    jne .un_copy_changed
    mov rax, [tl_stat + 88]
    cmp rax, [r12 + J_CMTIME]
    jne .un_copy_changed
    mov rdi, r14
    mov eax, SYS_UNLINK
    syscall
    test rax, rax
    js .un_fail_rm
    lea rdi, [tl_s_undo_removed]
    call print_cstring
    mov rdi, r14
    call print_cstring
    call print_newline
    jmp .un_saved
.un_copy_changed:
    ; edited since: keep its content in the trash instead of deleting it
    mov rdi, r14
    call tl_stash
    test eax, eax
    jz .un_fail_stash
    lea rdi, [tl_s_undo_changed]
    call print_cstring
    lea rdi, [tl_path_t]
    call print_cstring
    call print_newline
    jmp .un_saved
.un_copy_gone:
    lea rdi, [tl_s_undo_gone]
    call print_cstring
    mov rdi, r14
    call print_cstring
    call print_newline
    jmp .un_saved

.un_saved:
    ; move/copy: put back the file that sat at the destination before
    cmp dword [r12 + J_SAVED], 0
    je .un_pop
    mov rdi, r14
    call tl_exists
    test eax, eax
    jnz .un_keep_exists
    mov rdi, r15
    call tl_trash_file
    lea rdi, [tl_path_t]
    mov rsi, r14
    call tl_rename_x
    test eax, eax
    jnz .un_keep_fail
    lea rdi, [tl_s_undo_restored]
    call print_cstring
    mov rdi, r14
    call print_cstring
    call print_newline
    jmp .un_pop

.un_keep_exists:
    mov eax, TL_EEXIST
.un_keep_fail:
    ; the move/copy itself is undone; remember that and keep the entry so a
    ; later undo can retry putting the older file back
    mov [rsp], eax
    mov dword [r12 + J_SAVED], 2
    lea rdi, [tl_s_undo_keepold]
    call print_cstring
    mov rdi, r14
    call print_cstring
    lea rdi, [tl_s_undo_lp]
    call print_cstring
    mov edi, [rsp]
    call tl_reason
    mov rdi, rax
    call print_cstring
    lea rdi, [tl_s_undo_rp]
    call print_cstring
    mov rdi, r15
    call tl_trash_file
    lea rdi, [tl_s_undo_where]
    call print_cstring
    lea rdi, [tl_path_t]
    call print_cstring
    call print_newline
    mov dword [last_exit_status], 1
    mov edi, 1                      ; the saved flag changed
    call tl_j_end
    jmp .un_ret

.un_exists_a:
    lea rdi, [tl_s_undo_exists]
    call print_cstring
    mov rdi, r13
    call print_cstring
    call print_newline
    mov dword [last_exit_status], 1
    xor edi, edi
    call tl_j_end
    jmp .un_ret

.un_fail_restore:
    mov [rsp], eax
    lea rdi, [tl_s_undo_failed]
    call print_cstring
    mov rdi, r13
    jmp .un_fail_msg
.un_fail_move:
    mov [rsp], eax
    lea rdi, [tl_s_undo_failmv]
    call print_cstring
    mov rdi, r14
    jmp .un_fail_msg
.un_fail_stash:
    mov eax, [tl_err]
    jmp .un_fail_rm_have
.un_fail_rm:
    neg eax                         ; unlink gave -errno
.un_fail_rm_have:
    mov [rsp], eax
    lea rdi, [tl_s_undo_failrm]
    call print_cstring
    mov rdi, r14
.un_fail_msg:
    call print_cstring
    lea rdi, [tl_s_undo_lp]
    call print_cstring
    mov edi, [rsp]
    call tl_reason
    mov rdi, rax
    call print_cstring
    lea rdi, [tl_s_undo_rp]
    call print_cstring
    cmp dword [r12 + J_TYPE], UT_DEL
    jne .un_fail_end
    mov rdi, r15
    call tl_trash_file
    lea rdi, [tl_s_undo_where]
    call print_cstring
    lea rdi, [tl_path_t]
    call print_cstring
    call print_newline
.un_fail_end:
    mov dword [last_exit_status], 1
    xor edi, edi
    call tl_j_end
    jmp .un_ret

.un_pop:
    mov [tl_jlen], ebx              ; forget the entry
    mov edi, 1
    call tl_j_end
    test eax, eax
    jz .un_ret
    mov [tl_err], eax               ; done, but the journal still lists it
    lea rdi, [tl_s_name_undo]
    call tl_warn_record
    jmp .un_ret

.un_none:
    xor edi, edi
    call tl_j_end
.un_none_nolock:
    lea rdi, [tl_s_undo_none]
    call print_cstring
    mov dword [last_exit_status], 1
.un_ret:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; tl_exists(rdi = path) -> eax 1 if anything (even a dangling link) is there
tl_exists:
    lea rsi, [tl_stat]
    mov eax, TL_SYS_LSTAT
    syscall
    xor ecx, ecx
    test rax, rax
    sete cl
    mov eax, ecx
    ret

; ---------- trash [empty] ----------
handler_trash:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov dword [last_exit_status], 0
    xor r15d, r15d                  ; 1 = empty
    test rdi, rdi
    jz .tc_list
    cmp byte [rdi], 0
    je .tc_list
    lea rsi, [tl_s_empty]
    mov rbx, rdi
    call ash_word_is
    test eax, eax
    jz .tc_usage
    lea rdi, [rbx + 5]
    call ash_skip_blanks
    cmp byte [rax], 0
    jne .tc_usage
    mov r15d, 1
.tc_list:
    call tl_j_begin
    test eax, eax
    jz .tc_nothing
    test r15d, r15d
    jnz .tc_empty
    cmp dword [tl_jlen], 0
    je .tc_none_unlock
    ; header: count and size
    xor ecx, ecx
    xor r12d, r12d                  ; entries
    xor r13d, r13d                  ; bytes
.tc_count:
    cmp ecx, [tl_jlen]
    jae .tc_head
    inc r12d
    add r13, [tl_jbuf + rcx + J_SIZE]
    add ecx, [tl_jbuf + rcx + J_LEN]
    jmp .tc_count
.tc_head:
    lea rdi, [tl_s_trash_hdr1]
    call print_cstring
    mov eax, r12d
    call print_number
    lea rdi, [tl_s_trash_hdr2]
    call print_cstring
    mov rax, r13
    shr rax, 10
    call tl_print_kb
    lea rdi, [tl_s_trash_hdr3]
    call print_cstring
    lea rdi, [tl_base]
    call print_cstring
    call print_newline
    xor ebx, ebx                    ; offset
    xor r12d, r12d                  ; line number
.tc_line:
    cmp ebx, [tl_jlen]
    jae .tc_done
    inc r12d
    lea r14, [tl_jbuf + rbx]
    lea rdi, [tl_s_2sp]
    call print_cstring
    mov eax, r12d
    call print_number
    lea rdi, [tl_s_2sp]
    call print_cstring
    lea rdi, [tl_s_t_del]
    cmp dword [r14 + J_TYPE], UT_DEL
    je .tc_type
    lea rdi, [tl_s_t_move]
    cmp dword [r14 + J_TYPE], UT_MOVE
    je .tc_type
    lea rdi, [tl_s_t_copy]
.tc_type:
    call print_cstring
    lea rsi, [r14 + J_STR]          ; A
    mov rdi, rsi
.tc_a_end:
    cmp byte [rsi], 0
    je .tc_a_done
    inc rsi
    jmp .tc_a_end
.tc_a_done:
    inc rsi                         ; rsi = B
    cmp dword [r14 + J_TYPE], UT_COPY
    je .tc_only_b
    push rsi
    sub rsp, 8
    call print_cstring              ; A
    add rsp, 8
    pop rsi
    cmp dword [r14 + J_TYPE], UT_DEL
    je .tc_next
    push rsi
    sub rsp, 8
    lea rdi, [tl_s_undo_arrow]
    call print_cstring
    add rsp, 8
    pop rsi
.tc_only_b:
    mov rdi, rsi
    call print_cstring
.tc_next:
    call print_newline
    add ebx, [r14 + J_LEN]
    jmp .tc_line
.tc_done:
    xor edi, edi
    call tl_j_end
    jmp .tc_ret

.tc_none_unlock:
    xor edi, edi
    call tl_j_end
.tc_nothing:
    lea rdi, [tl_s_trash_none]
    call print_cstring
    jmp .tc_ret

.tc_empty:
    ; delete every file in the trash folder (also ones no record points at)
    xor r12d, r12d                  ; files removed
    lea rdi, [tl_base]
    mov esi, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .tc_empty_done
    mov ebx, eax
.tc_getdents:
    mov edi, ebx
    lea rsi, [tl_dents]
    mov edx, TL_DENTS
    mov eax, SYS_GETDENTS64
    syscall
    test rax, rax
    jle .tc_dents_end
    mov r13, rax                    ; bytes in the buffer
    xor r14d, r14d                  ; position
.tc_entry:
    cmp r14, r13
    jae .tc_getdents
    lea rsi, [tl_dents + r14]
    movzx eax, word [rsi + DIRENT64_D_RECLEN]
    add r14, rax
    lea rsi, [rsi + DIRENT64_D_NAME]
    cmp byte [rsi], '.'
    je .tc_entry                    ; ".", ".." and our own .journal, .lock
.tc_remove:
    push rsi
    sub rsp, 8
    lea rdi, [tl_path_s]
    lea rsi, [tl_base]
    call upd_stpcpy
    mov byte [rax], '/'
    lea rdi, [rax + 1]
    mov rsi, [rsp + 8]
    call upd_stpcpy
    lea rdi, [tl_path_s]
    mov eax, SYS_UNLINK
    syscall
    add rsp, 16
    test rax, rax
    js .tc_entry
    inc r12d
    jmp .tc_entry
.tc_dents_end:
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall
.tc_empty_done:
    mov dword [tl_jlen], 0
    mov edi, 1
    call tl_j_end
    lea rdi, [tl_s_trash_emptied1]
    call print_cstring
    mov eax, r12d
    call print_number
    lea rdi, [tl_s_trash_emptied2]
    call print_cstring
    jmp .tc_ret

.tc_usage:
    lea rdi, [tl_s_trash_usage]
    call print_cstring
    mov dword [last_exit_status], 2
.tc_ret:
    add rsp, 8
    pop r15
    pop r14
    pop r13
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
