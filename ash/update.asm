; ============================================================================
; update - check GitHub for a newer release and install it (Linux)
;
;   update            check for a newer release
;   update install    download it, verify its SHA-256, replace this binary
;
; At startup (interactive only, at most once a day) a detached background
; process checks the latest release and caches its tag in ~/.asm_update.
; The next start prints a one-line notice if that tag is newer.
; Set ASM_NO_UPDATE_CHECK=1 to turn the background check off.
;
; HTTPS is done by the system 'curl' (TLS in pure asm is not practical);
; checksums by 'sha256sum'. Both ship with every mainstream distro.
; Included from terminal_linux.asm, after ash/ash_exec.asm.
; ============================================================================

%define SYS_CHMOD           90
%define SYS_SETSID          112
%define SYS_ACCESS          21
%define UPD_BUF_SIZE        16384
%define UPD_TAG_MAX         32
%define UPD_CHECK_INTERVAL  86400       ; seconds between background checks
%define STAT_ST_MTIME       88

section .data
    upd_cur_version     db ASM_VERSION, 0
    upd_api_url         db "https://api.github.com/repos/Umar-Khan-Yousafzai/asm-terminal/releases/latest", 0
    upd_dl_base         db "https://github.com/Umar-Khan-Yousafzai/asm-terminal/releases/download/", 0
    upd_asset           db "asm-terminal-linux-x86_64", 0
    upd_sums_name       db "SHA256SUMS", 0
    upd_sums_needle     db "  asm-terminal-linux-x86_64", 10, 0
    upd_tag_key         db '"tag_name"', 0
    upd_cache_name      db "/.asm_update", 0
    upd_new_suffix      db ".new", 0
    upd_self_link       db "/proc/self/exe", 0
    upd_dev_null        db "/dev/null", 0
    upd_s_install       db "install", 0
    upd_s_noenv         db "ASM_NO_UPDATE_CHECK", 0

    upd_s_curl          db "curl", 0
    upd_s_fsSL          db "-fsSL", 0
    upd_s_maxtime       db "--max-time", 0
    upd_s_t8            db "8", 0
    upd_s_t300          db "300", 0
    upd_s_H             db "-H", 0
    upd_s_accept        db "Accept: application/vnd.github+json", 0
    upd_s_o             db "-o", 0
    upd_s_sha256sum     db "sha256sum", 0

    upd_msg_checking    db "Checking for updates...", 10, 0
    upd_msg_offline     db "Could not reach GitHub. Check your connection and that 'curl' is installed.", 10, 0
    upd_msg_badreply    db "Could not read the latest release from GitHub.", 10, 0
    upd_msg_latest1     db "You are on the latest version (v", 0
    upd_msg_latest2     db ").", 10, 0
    upd_msg_avail1      db "Update available: v", 0
    upd_msg_arrow       db " -> ", 0
    upd_msg_avail2      db 10, "Run 'update install' to install it.", 10, 0
    upd_msg_download    db "Downloading ", 0
    upd_msg_dots        db "...", 10, 0
    upd_msg_dlfail      db "Download failed. Nothing was changed.", 10, 0
    upd_msg_nosums      db "Could not get checksums for this release. Nothing was changed.", 10, 0
    upd_msg_badsum      db "Checksum mismatch. The download was deleted and nothing was changed.", 10, 0
    upd_msg_noself      db "Could not find this program's own path.", 10, 0
    upd_msg_noperm1     db "No permission to replace ", 0
    upd_msg_noperm2     db 10, "Reinstall with your package manager, or run the update with sudo.", 10, 0
    upd_msg_done1       db "Updated to ", 0
    upd_msg_done2       db ". Type 'exit' and start the terminal again to use it.", 10, 0
    upd_msg_usage       db "Usage: update            check for a newer version", 10
                        db "       update install    download and install it", 10, 0
    upd_msg_notice1     db "  Update available: v", 0
    upd_msg_notice2     db "  (type 'update install')", 10, 10, 0

    ; argv arrays; slots marked 0 are filled in at run time
    upd_argv_check      dq upd_s_curl, upd_s_fsSL, upd_s_maxtime, upd_s_t8
                        dq upd_s_H, upd_s_accept, upd_api_url, 0
    upd_argv_get        dq upd_s_curl, upd_s_fsSL, upd_s_maxtime, upd_s_t300
                        dq upd_s_o, 0, 0, 0          ; [5] = out file, [6] = url
    upd_argv_sums       dq upd_s_curl, upd_s_fsSL, upd_s_maxtime, upd_s_t8
                        dq 0, 0                      ; [4] = url
    upd_argv_sha        dq upd_s_sha256sum, 0, 0     ; [1] = file

section .bss
    upd_buf             resb UPD_BUF_SIZE
    upd_drain           resb 4096
    upd_status          resd 1
    upd_latest          resb UPD_TAG_MAX
    upd_cache_path      resb MAX_PATH_BUF
    upd_self            resb MAX_PATH_BUF
    upd_tmp             resb MAX_PATH_BUF
    upd_url             resb 512
    upd_hash            resb 72

section .text

; ----------------------------------------------------------------------------
; handler_update(rdi = args or 0)
; ----------------------------------------------------------------------------
handler_update:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 8

    xor ebx, ebx                    ; ebx = 1 for 'install'
    test rdi, rdi
    jz .hu_check
    cmp byte [rdi], 0
    je .hu_check
    lea rsi, [upd_s_install]
    call str_icompare
    test eax, eax
    jnz .hu_usage
    mov ebx, 1

.hu_check:
    lea rdi, [upd_msg_checking]
    call print_cstring
    call upd_fetch_latest           ; eax = 1 ok
    test eax, eax
    jz .hu_fail

    lea rdi, [upd_latest]
    call upd_is_newer
    test eax, eax
    jnz .hu_newer

    lea rdi, [upd_msg_latest1]
    call print_cstring
    lea rdi, [upd_cur_version]
    call print_cstring
    lea rdi, [upd_msg_latest2]
    call print_cstring
    jmp .hu_ok

.hu_newer:
    test ebx, ebx
    jnz .hu_install
    lea rdi, [upd_msg_avail1]
    call print_cstring
    lea rdi, [upd_cur_version]
    call print_cstring
    lea rdi, [upd_msg_arrow]
    call print_cstring
    lea rdi, [upd_latest]
    call print_cstring
    lea rdi, [upd_msg_avail2]
    call print_cstring
    jmp .hu_ok

.hu_install:
    call upd_install                ; eax = 1 ok
    test eax, eax
    jz .hu_fail_quiet
    jmp .hu_ok

.hu_usage:
    lea rdi, [upd_msg_usage]
    call print_cstring
.hu_fail_quiet:
    mov dword [last_exit_status], 1
    jmp .hu_ret

.hu_fail:
    mov dword [last_exit_status], 1
    jmp .hu_ret
.hu_ok:
    mov dword [last_exit_status], 0
.hu_ret:
    add rsp, 8
    pop rbx
    pop rbp
    ret

; ----------------------------------------------------------------------------
; upd_fetch_latest() -> eax = 1 if upd_latest holds the newest release tag.
; Prints its own error message on failure. Refreshes ~/.asm_update.
; ----------------------------------------------------------------------------
upd_fetch_latest:
    push rbp
    mov rbp, rsp

    lea rdi, [upd_argv_check]
    mov esi, 1
    call upd_capture
    test eax, eax
    jle .uf_offline
    cmp dword [upd_status], 0
    jne .uf_offline

    call upd_parse_tag
    test eax, eax
    jz .uf_bad
    call upd_write_cache
    mov eax, 1
    jmp .uf_ret

.uf_offline:
    lea rdi, [upd_msg_offline]
    call print_cstring
    xor eax, eax
    jmp .uf_ret
.uf_bad:
    lea rdi, [upd_msg_badreply]
    call print_cstring
    xor eax, eax
.uf_ret:
    pop rbp
    ret

; ----------------------------------------------------------------------------
; upd_install() - upd_latest is newer: download, verify, replace. eax = 1 ok
; ----------------------------------------------------------------------------
upd_install:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 8

    ; Own path, from /proc/self/exe
    lea rdi, [upd_self_link]
    lea rsi, [upd_self]
    mov edx, MAX_PATH_BUF - 8
    mov eax, SYS_READLINK
    syscall
    test rax, rax
    jle .ui_noself
    mov byte [upd_self + rax], 0

    ; Need write access to our own folder (tmp file + rename live there)
    lea rdi, [upd_self]
    call str_len
    lea rdi, [upd_self + rax]
.ui_find_slash:
    lea rdx, [upd_self]
    cmp rdi, rdx
    jbe .ui_dir_ok                  ; no '/' (cannot happen for /proc/self/exe)
    dec rdi
    cmp byte [rdi], '/'
    jne .ui_find_slash
    mov rbx, rdi
    mov byte [rbx], 0
    lea rdi, [upd_self]
    cmp byte [rdi], 0
    jne .ui_access
    mov byte [rdi], '/'             ; binary in "/": check "/"
    mov byte [rdi + 1], 0
.ui_access:
    mov esi, 2                      ; W_OK
    mov eax, SYS_ACCESS
    syscall
    mov byte [rbx], '/'
    test rax, rax
    js .ui_noperm_early
.ui_dir_ok:

    ; tmp = self + ".new"
    lea rdi, [upd_tmp]
    lea rsi, [upd_self]
    call upd_stpcpy
    mov rdi, rax
    lea rsi, [upd_new_suffix]
    call upd_stpcpy

    ; url = base + tag + "/" + asset
    lea rsi, [upd_asset]
    call upd_build_url

    lea rdi, [upd_msg_download]
    call print_cstring
    lea rdi, [upd_latest]
    call print_cstring
    lea rdi, [upd_msg_dots]
    call print_cstring

    lea rax, [upd_tmp]
    mov [upd_argv_get + 5*8], rax
    lea rax, [upd_url]
    mov [upd_argv_get + 6*8], rax
    lea rdi, [upd_argv_get]
    mov esi, 1
    call upd_capture
    test eax, eax
    js .ui_dlfail
    cmp dword [upd_status], 0
    jne .ui_dlfail

    ; Expected hash from the release's SHA256SUMS
    lea rsi, [upd_sums_name]
    call upd_build_url
    lea rax, [upd_url]
    mov [upd_argv_sums + 4*8], rax
    lea rdi, [upd_argv_sums]
    mov esi, 1
    call upd_capture
    test eax, eax
    jle .ui_nosums
    cmp dword [upd_status], 0
    jne .ui_nosums
    lea rdi, [upd_buf]
    lea rsi, [upd_sums_needle]
    call upd_find
    test rax, rax
    jz .ui_nosums
    lea rsi, [rax - 64]             ; hash is the 64 chars before "  name"
    lea rdx, [upd_buf]
    cmp rsi, rdx
    jb .ui_nosums
    lea rdi, [upd_hash]
    mov ecx, 64
    rep movsb
    mov byte [rdi], 0

    ; Actual hash of what we downloaded
    lea rax, [upd_tmp]
    mov [upd_argv_sha + 8], rax
    lea rdi, [upd_argv_sha]
    mov esi, 1
    call upd_capture
    cmp eax, 64
    jl .ui_badsum
    cmp dword [upd_status], 0
    jne .ui_badsum
    lea rsi, [upd_buf]
    lea rdi, [upd_hash]
    mov ecx, 64
    repe cmpsb
    jne .ui_badsum

    ; chmod 755, then atomically replace ourselves
    lea rdi, [upd_tmp]
    mov esi, 0o755
    mov eax, SYS_CHMOD
    syscall
    lea rdi, [upd_tmp]
    lea rsi, [upd_self]
    mov eax, SYS_RENAME
    syscall
    test rax, rax
    js .ui_noperm

    lea rdi, [upd_msg_done1]
    call print_cstring
    lea rdi, [upd_latest]
    call print_cstring
    lea rdi, [upd_msg_done2]
    call print_cstring
    mov eax, 1
    jmp .ui_ret

.ui_noself:
    lea rdi, [upd_msg_noself]
    call print_cstring
    xor eax, eax
    jmp .ui_ret
.ui_dlfail:
    lea rbx, [upd_msg_dlfail]
    jmp .ui_cleanup
.ui_nosums:
    lea rbx, [upd_msg_nosums]
    jmp .ui_cleanup
.ui_badsum:
    lea rbx, [upd_msg_badsum]
    jmp .ui_cleanup
.ui_noperm_early:
    lea rdi, [upd_msg_noperm1]
    call print_cstring
    lea rdi, [upd_self]
    call print_cstring
    lea rdi, [upd_msg_noperm2]
    call print_cstring
    xor eax, eax
    jmp .ui_ret
.ui_noperm:
    lea rdi, [upd_msg_noperm1]
    call print_cstring
    lea rdi, [upd_self]
    call print_cstring
    lea rbx, [upd_msg_noperm2]
.ui_cleanup:
    lea rdi, [upd_tmp]
    mov eax, SYS_UNLINK
    syscall
    mov rdi, rbx
    call print_cstring
    xor eax, eax
.ui_ret:
    add rsp, 8
    pop rbx
    pop rbp
    ret

; ----------------------------------------------------------------------------
; update_startup() - called once from main, after the welcome banner.
; Prints a notice from the cached tag, and refreshes the cache in a
; detached background process when it is older than a day.
; ----------------------------------------------------------------------------
update_startup:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 16

    cmp byte [interactive_mode], 0
    je .us_ret
    lea rdi, [upd_s_noenv]
    call getenv_internal
    test rax, rax
    jnz .us_ret
    call upd_cache_path_init
    test eax, eax
    jz .us_ret

    ; Cached tag + its age
    lea rdi, [upd_cache_path]
    lea rsi, [stat_buf]
    mov eax, SYS_STAT
    syscall
    test rax, rax
    js .us_spawn
    mov r12, [stat_buf + STAT_ST_MTIME]

    lea rdi, [upd_cache_path]
    xor esi, esi                    ; O_RDONLY
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .us_spawn
    mov ebx, eax
    mov edi, ebx
    lea rsi, [upd_latest]
    mov edx, UPD_TAG_MAX - 1
    xor eax, eax                    ; SYS_READ
    syscall
    push rax
    push rax
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall
    pop rax
    pop rax
    test rax, rax
    jle .us_age
    mov byte [upd_latest + rax], 0
    lea rdi, [upd_latest]           ; cut at the first newline
.us_strip:
    mov al, [rdi]
    test al, al
    jz .us_stripped
    cmp al, 10
    je .us_cut
    inc rdi
    jmp .us_strip
.us_cut:
    mov byte [rdi], 0
.us_stripped:
    lea rdi, [upd_latest]
    call upd_is_newer
    test eax, eax
    jz .us_age
    lea rdi, [upd_msg_notice1]
    call print_cstring
    lea rdi, [upd_cur_version]
    call print_cstring
    lea rdi, [upd_msg_arrow]
    call print_cstring
    lea rdi, [upd_latest]
    call print_cstring
    lea rdi, [upd_msg_notice2]
    call print_cstring

.us_age:
    mov edi, CLOCK_REALTIME
    lea rsi, [timespec_buf]
    mov eax, SYS_CLOCK_GETTIME
    syscall
    mov rax, [timespec_buf]
    sub rax, r12
    cmp rax, UPD_CHECK_INTERVAL
    jl .us_ret

.us_spawn:
    ; Double fork so the checker is reparented to init and never a zombie
    mov eax, SYS_FORK
    syscall
    test rax, rax
    js .us_ret
    jnz .us_reap
    mov eax, SYS_FORK
    syscall
    test rax, rax
    jnz .us_child_exit              ; middle process exits at once

    ; Grandchild: leave the terminal's session (no SIGHUP or Ctrl+C from
    ; it), then do a quiet check, refresh the cache and exit
    mov eax, SYS_SETSID
    syscall
    lea rdi, [upd_argv_check]
    mov esi, 1
    call upd_capture
    test eax, eax
    jle .us_child_exit
    cmp dword [upd_status], 0
    jne .us_child_exit
    call upd_parse_tag
    test eax, eax
    jz .us_child_exit
    call upd_write_cache
.us_child_exit:
    xor edi, edi
    mov eax, SYS_EXIT
    syscall

.us_reap:
    mov rdi, rax
    xor esi, esi
    xor edx, edx
    xor r10d, r10d
    mov eax, SYS_WAIT4
    syscall

.us_ret:
    add rsp, 16
    pop r12
    pop rbx
    pop rbp
    ret

; ----------------------------------------------------------------------------
; upd_capture(rdi = argv, esi = quiet) -> eax = bytes captured, -1 on error.
; Runs argv with stdout into upd_buf (NUL-terminated, extra output is
; drained and dropped). stdin is /dev/null; stderr too when quiet.
; Exit code (or 128 + signal) goes to upd_status.
; ----------------------------------------------------------------------------
upd_capture:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 16                     ; [rsp] status, [rsp+8] pipe fds

    mov r12, rdi
    mov r13d, esi
    mov dword [upd_status], 1
    mov byte [upd_buf], 0

    lea rdi, [rsp + 8]
    mov esi, O_CLOEXEC
    mov eax, SYS_PIPE2
    syscall
    test rax, rax
    js .uc_error

    mov eax, SYS_FORK
    syscall
    test rax, rax
    js .uc_fork_error
    jz .uc_child
    mov ebx, eax                    ; child pid

    mov edi, [rsp + 12]             ; parent keeps only the read end
    mov eax, SYS_CLOSE
    syscall

    xor r14d, r14d                  ; bytes stored
.uc_read:
    mov edx, UPD_BUF_SIZE - 1
    sub edx, r14d
    jz .uc_drain
    mov edi, [rsp + 8]
    lea rsi, [upd_buf + r14]
    xor eax, eax                    ; SYS_READ
    syscall
    cmp rax, -EINTR
    je .uc_read
    test rax, rax
    jle .uc_read_done
    add r14d, eax
    jmp .uc_read
.uc_drain:
    mov edi, [rsp + 8]
    lea rsi, [upd_drain]
    mov edx, 4096
    xor eax, eax
    syscall
    cmp rax, -EINTR
    je .uc_drain
    test rax, rax
    jg .uc_drain
.uc_read_done:
    mov byte [upd_buf + r14], 0
    mov edi, [rsp + 8]
    mov eax, SYS_CLOSE
    syscall

.uc_wait:
    mov dword [rsp], 0
    mov edi, ebx
    mov rsi, rsp
    xor edx, edx
    xor r10d, r10d
    mov eax, SYS_WAIT4
    syscall
    cmp rax, -EINTR
    je .uc_wait
    mov eax, [rsp]
    mov edx, eax
    and edx, 0x7F
    jz .uc_exited
    lea eax, [rdx + 128]
    jmp .uc_status
.uc_exited:
    shr eax, 8
    and eax, 0xFF
.uc_status:
    mov [upd_status], eax
    mov eax, r14d
    jmp .uc_ret

.uc_fork_error:
    mov edi, [rsp + 8]
    mov eax, SYS_CLOSE
    syscall
    mov edi, [rsp + 12]
    mov eax, SYS_CLOSE
    syscall
.uc_error:
    mov eax, -1
.uc_ret:
    add rsp, 16
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

.uc_child:
    mov edi, [rsp + 12]
    mov esi, 1
    mov eax, SYS_DUP2
    syscall
    lea rdi, [upd_dev_null]
    mov esi, O_RDWR
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .uc_exec
    mov ebx, eax
    mov edi, ebx
    xor esi, esi
    mov eax, SYS_DUP2
    syscall
    test r13d, r13d
    jz .uc_exec
    mov edi, ebx
    mov esi, 2
    mov eax, SYS_DUP2
    syscall
.uc_exec:
    mov rdi, r12
    call ash_exec_argv              ; does not return

; ----------------------------------------------------------------------------
; upd_parse_tag() - find "tag_name": "..." in upd_buf, copy to upd_latest.
; eax = 1 ok, 0 not found.
; ----------------------------------------------------------------------------
upd_parse_tag:
    push rbp
    mov rbp, rsp
    lea rdi, [upd_buf]
    lea rsi, [upd_tag_key]
    call upd_find
    test rax, rax
    jz .pt_fail
    add rax, 10                     ; past "tag_name"
.pt_colon:
    mov cl, [rax]
    test cl, cl
    jz .pt_fail
    inc rax
    cmp cl, '"'
    jne .pt_colon                   ; skips ':' and blanks up to the quote
    lea rdi, [upd_latest]
    xor edx, edx
.pt_copy:
    mov cl, [rax + rdx]
    test cl, cl
    jz .pt_fail
    cmp cl, '"'
    je .pt_done
    cmp edx, UPD_TAG_MAX - 1
    jae .pt_fail
    mov [rdi + rdx], cl
    inc edx
    jmp .pt_copy
.pt_done:
    test edx, edx
    jz .pt_fail
    mov byte [rdi + rdx], 0
    mov eax, 1
    pop rbp
    ret
.pt_fail:
    xor eax, eax
    pop rbp
    ret

; ----------------------------------------------------------------------------
; upd_is_newer(rdi = "vX.Y.Z" or "X.Y.Z") -> eax = 1 if newer than ours
; ----------------------------------------------------------------------------
upd_is_newer:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 8
    call upd_parse_version
    mov rbx, rax
    lea rdi, [upd_cur_version]
    call upd_parse_version
    xor ecx, ecx
    cmp rbx, rax
    seta cl
    mov eax, ecx
    add rsp, 8
    pop rbx
    pop rbp
    ret

; rdi = version string -> rax = major<<40 | minor<<20 | patch (0 if bad)
upd_parse_version:
    xor eax, eax
    cmp byte [rdi], 'v'
    jne .pv_start
    inc rdi
.pv_start:
    xor r8d, r8d                    ; parts done
    xor edx, edx                    ; current number
.pv_loop:
    movzx ecx, byte [rdi]
    cmp cl, '0'
    jb .pv_sep
    cmp cl, '9'
    ja .pv_sep
    imul edx, edx, 10
    sub ecx, '0'
    add edx, ecx
    and edx, 0xFFFFF
    inc rdi
    jmp .pv_loop
.pv_sep:
    shl rax, 20
    or rax, rdx
    xor edx, edx
    inc r8d
    cmp r8d, 3
    jae .pv_done
    cmp byte [rdi], '.'
    jne .pv_pad
    inc rdi
    jmp .pv_loop
.pv_pad:
    shl rax, 20                     ; "2.1" counts as "2.1.0"
    inc r8d
    cmp r8d, 3
    jb .pv_pad
.pv_done:
    ret

; ----------------------------------------------------------------------------
; Small helpers
; ----------------------------------------------------------------------------

; upd_stpcpy(rdi = dest, rsi = src) -> rax = pointer to the NUL written
upd_stpcpy:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .sp_done
    inc rdi
    inc rsi
    jmp upd_stpcpy
.sp_done:
    mov rax, rdi
    ret

; upd_build_url(rsi = file name) - upd_url = base + upd_latest + "/" + name
upd_build_url:
    push rbx
    mov rbx, rsi
    lea rdi, [upd_url]
    lea rsi, [upd_dl_base]
    call upd_stpcpy
    mov rdi, rax
    lea rsi, [upd_latest]
    call upd_stpcpy
    mov byte [rax], '/'
    lea rdi, [rax + 1]
    mov rsi, rbx
    call upd_stpcpy
    pop rbx
    ret

; upd_find(rdi = haystack, rsi = needle) -> rax = first match or 0
upd_find:
.uf_outer:
    cmp byte [rdi], 0
    je .uf_none
    xor ecx, ecx
.uf_inner:
    mov al, [rsi + rcx]
    test al, al
    jz .uf_hit
    cmp al, [rdi + rcx]
    jne .uf_next
    inc ecx
    jmp .uf_inner
.uf_next:
    inc rdi
    jmp .uf_outer
.uf_hit:
    mov rax, rdi
    ret
.uf_none:
    xor eax, eax
    ret

; upd_cache_path_init() -> eax = 1 if upd_cache_path = $HOME/.asm_update
upd_cache_path_init:
    push rbp
    mov rbp, rsp
    lea rdi, [str_home]
    call getenv_internal
    test rax, rax
    jz .cp_fail
    mov rsi, rax
    lea rdi, [upd_cache_path]
    call upd_stpcpy
    mov rdi, rax
    lea rsi, [upd_cache_name]
    call upd_stpcpy
    mov eax, 1
    pop rbp
    ret
.cp_fail:
    xor eax, eax
    pop rbp
    ret

; upd_write_cache() - write upd_latest + LF to $HOME/.asm_update
upd_write_cache:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 8
    call upd_cache_path_init
    test eax, eax
    jz .wc_ret
    lea rdi, [upd_cache_path]
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    mov edx, FILE_MODE_DEFAULT
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .wc_ret
    mov ebx, eax
    lea rdi, [upd_latest]
    call str_len
    lea rcx, [upd_latest]
    mov byte [rcx + rax], 10        ; temporary LF for the write
    lea edx, [eax + 1]
    mov edi, ebx
    lea rsi, [upd_latest]
    mov eax, SYS_WRITE
    syscall
    lea rdi, [upd_latest]
    call str_len_nl_fix
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall
.wc_ret:
    add rsp, 8
    pop rbx
    pop rbp
    ret

; Turn the first LF in rdi back into NUL
str_len_nl_fix:
    mov al, [rdi]
    test al, al
    jz .nf_done
    cmp al, 10
    je .nf_cut
    inc rdi
    jmp str_len_nl_fix
.nf_cut:
    mov byte [rdi], 0
.nf_done:
    ret
