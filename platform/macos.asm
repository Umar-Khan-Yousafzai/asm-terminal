; ============================================================================
; platform/macos.asm - the macOS (XNU, x86-64) side of the platform layer
;
; Included at the end of terminal_linux.asm when PLATFORM_MACOS is defined.
;   _start              entry point (dyld calls it like main)
;   mac_sigtramp        signal trampoline (XNU calls it, it calls sigreturn)
;   mac_*               the SYSCALL_X routines: the Linux call's arguments
;                       and result, built from the calls XNU has. Each keeps
;                       every register but rax, rcx and r11.
;   plat_uptime_seconds, handler_free, handler_trace, handler_sandbox
; Nothing here calls libSystem.
; ============================================================================

%define MAC_PATH_MAX        4096
%define MAC_CTL_KERN        1
%define MAC_CTL_HW          6
%define MAC_KERN_OSTYPE     1
%define MAC_KERN_OSRELEASE  2
%define MAC_KERN_VERSION    4
%define MAC_KERN_HOSTNAME   10
%define MAC_KERN_BOOTTIME   21
%define MAC_HW_MACHINE      1
%define MAC_HW_MEMSIZE      24
%define MAC_PROC_PIDINFO    2               ; proc_info call number
%define MAC_PIDPATHINFO     11              ; proc_info flavor: the executable's path

section .data
    mac_s_dot           db ".", 0
    mac_s_pagefree      db "vm.page_free_count", 0
    mac_s_pagesize      db "vm.pagesize", 0
    mac_s_memtotal      db "MemTotal:      ", 0
    mac_s_memfree       db "MemFree:       ", 0
    mac_s_kb            db " kB", 10, 0
    mac_s_free_err      db "free: cannot read the memory size", 10, 0
    tr_s_trace          db "trace", 0
    sb_s_sandbox        db "sandbox", 0
    mac_s_deleted       db " (deleted)", 0
    mac_s_no_trace      db "trace: not available on macOS (it needs Linux ptrace)", 10, 0
    mac_s_no_sandbox    db "sandbox: not available on macOS (it needs Linux seccomp and Landlock); the command was not run", 10, 0

section .bss
    mac_path_tmp        resb MAC_PATH_MAX
    mac_dir_base        resq 1          ; getdirentries64 position, not used
    mac_fdset           resb 128        ; select() set for fds 0..1023
    mac_oid             resd 16
    mac_sysval          resq 1
    mac_stat_tmp        resb 144        ; struct stat64
    mac_self_ino        resq 1
    mac_self_dev        resd 1
    mac_self_known      resb 1

section .text

; ----------------------------------------------------------------------------
; _start(argc = rdi, argv = rsi, envp = rdx, apple = rcx), called by dyld
; ----------------------------------------------------------------------------
_start:
    mov [saved_envp], rdx
    and rsp, -16
    call mac_self_record
    call main
    mov edi, eax
    mov eax, SYS_EXIT
    SYSCALL

; ----------------------------------------------------------------------------
; mac_sigtramp - XNU enters here for every caught signal with
;   rdi = handler, esi = infostyle, edx = signal, rcx = siginfo,
;   r8 = ucontext, r9 = sigreturn token
; Runs the handler, then sigreturn(ucontext, infostyle, token) puts back
; every register the signal interrupted.
; ----------------------------------------------------------------------------
mac_sigtramp:
    mov rbx, r8
    mov r12d, esi
    mov r13, r9
    mov rax, rdi
    mov edi, edx
    mov rsi, rcx
    mov rdx, r8
    and rsp, -16
    call rax
    mov rdi, rbx
    mov esi, r12d
    mov rdx, r13
    mov eax, SYS_SIGRETURN
    syscall
    ud2                             ; sigreturn does not come back

; ----------------------------------------------------------------------------
; mac_fork -> rax = child pid in the parent, 0 in the child, or -errno
; ----------------------------------------------------------------------------
mac_fork:
    push rdx
    mov eax, SYS_FORK
    syscall
    jc .err
    test edx, edx                   ; rdx = 1 in the child
    jz .ret
    xor eax, eax
.ret:
    pop rdx
    ret
.err:
    neg rax
    pop rdx
    ret

; ----------------------------------------------------------------------------
; mac_pipe2(rdi = int fds[2], esi = O_CLOEXEC or 0) -> rax = 0 or -errno
; ----------------------------------------------------------------------------
mac_pipe2:
    push rdx
    push rsi
    push rdi
    mov eax, SYS_PIPE
    syscall                         ; rax = read end, rdx = write end
    jc .err
    mov rdi, [rsp]
    mov [rdi], eax
    mov [rdi + 4], edx
    test dword [rsp + 8], O_CLOEXEC
    jz .ok
    mov edi, eax
    mov esi, F_SETFD
    mov edx, FD_CLOEXEC
    mov eax, SYS_FCNTL
    syscall
    mov rdi, [rsp]
    mov edi, [rdi + 4]
    mov esi, F_SETFD
    mov edx, FD_CLOEXEC
    mov eax, SYS_FCNTL
    syscall
.ok:
    xor eax, eax
    jmp .ret
.err:
    neg rax
.ret:
    pop rdi
    pop rsi
    pop rdx
    ret

; ----------------------------------------------------------------------------
; mac_getcwd(rdi = buf, esi = size) -> rax = length with the NUL, or -errno
; The path of an open "." (fcntl F_GETPATH), as libSystem's getcwd does.
; ----------------------------------------------------------------------------
mac_getcwd:
    push rdi
    push rsi
    push rdx
    push r8
    push r9
    mov r8, rdi                     ; r8 = caller's buffer
    mov r9d, esi                    ; r9d = its size
    lea rdi, [mac_s_dot]
    mov esi, O_RDONLY | O_DIRECTORY | O_CLOEXEC
    xor edx, edx
    mov eax, SYS_OPEN
    SYSCALL
    test rax, rax
    js .ret
    mov edi, eax
    push rdi
    mov esi, F_GETPATH
    lea rdx, [mac_path_tmp]
    mov eax, SYS_FCNTL
    SYSCALL
    mov rdx, rax
    pop rdi
    mov eax, SYS_CLOSE
    SYSCALL
    mov rax, rdx
    test rax, rax
    js .ret
    lea rsi, [mac_path_tmp]
    xor ecx, ecx
.len:
    cmp byte [rsi + rcx], 0
    je .len_done
    inc ecx
    jmp .len
.len_done:
    inc ecx                         ; the NUL
    mov rax, -ERANGE
    cmp ecx, r9d
    ja .ret
    mov eax, ecx
.copy:
    mov dl, [rsi]
    mov [r8], dl
    inc rsi
    inc r8
    dec ecx
    jnz .copy
.ret:
    pop r9
    pop r8
    pop rdx
    pop rsi
    pop rdi
    ret

; ----------------------------------------------------------------------------
; mac_getdents64(edi = fd, rsi = buf, edx = size) -> rax = bytes, 0 at the end
; The records are XNU's struct direntry (DIRENT64_* in platform/macos.inc).
; ----------------------------------------------------------------------------
mac_getdents64:
    push r10
    lea r10, [mac_dir_base]
    mov eax, SYS_GETDIRENTRIES64
    SYSCALL
    pop r10
    ret

; ----------------------------------------------------------------------------
; mac_now -> rax = seconds, rdx = microseconds since the epoch
; Keeps rdi and rsi. XNU before 10.12 returned the time in rax:rdx; later
; ones fill the struct and return 0.
; ----------------------------------------------------------------------------
mac_now:
    push rdi
    push rsi
    sub rsp, 16
    mov rdi, rsp
    xor esi, esi
    xor edx, edx
    mov eax, SYS_GETTIMEOFDAY
    syscall
    jc .zero
    test rax, rax
    jnz .ret
    mov rax, [rsp]
    mov edx, [rsp + 8]
    jmp .ret
.zero:
    xor eax, eax
    xor edx, edx
.ret:
    mov edx, edx
    add rsp, 16
    pop rsi
    pop rdi
    ret

; ----------------------------------------------------------------------------
; mac_clock_gettime(edi = clock, rsi = struct timespec *) -> rax = 0
; Both clocks read the wall clock, to the microsecond.
; ----------------------------------------------------------------------------
mac_clock_gettime:
    push rdx
    call mac_now
    imul rdx, rdx, 1000
    mov [rsi], rax
    mov [rsi + 8], rdx
    xor eax, eax
    pop rdx
    ret

; mac_time(rdi = NULL) -> rax = seconds since the epoch
mac_time:
    push rdx
    call mac_now
    pop rdx
    ret

; ----------------------------------------------------------------------------
; mac_sysctl2(edi = level 1, esi = level 2, rdx = out, r8 = out size)
;   -> rax = bytes stored, or -errno
; ----------------------------------------------------------------------------
mac_sysctl2:
    push rdi
    push rsi
    push r8
    push r9
    push r10
    sub rsp, 16
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], r8               ; *oldlenp
    mov rdi, rsp
    mov esi, 2
    lea r10, [rsp + 8]
    xor r8d, r8d
    xor r9d, r9d
    mov eax, SYS_SYSCTL
    SYSCALL
    test rax, rax
    js .ret
    mov rax, [rsp + 8]
.ret:
    add rsp, 16
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdi
    ret

; mac_sysctl_name(rdi = "a.b.c", rdx = out, r8 = out size) -> rax = bytes or -errno
mac_sysctl_name:
    push rdi
    push rsi
    push rdx
    push r8
    push r9
    push r10
    sub rsp, 24
    mov [rsp + 8], rdx              ; out
    mov [rsp + 16], r8              ; out size
    mov rsi, rdi                    ; strlen
    xor r9d, r9d
.len:
    cmp byte [rsi + r9], 0
    je .len_done
    inc r9
    jmp .len
.len_done:
    mov r8, rdi                     ; new = the name: sysctl.name2oid {0, 3}
    mov dword [rsp], 0
    mov dword [rsp + 4], 3
    mov rdi, rsp
    mov esi, 2
    lea rdx, [mac_oid]
    mov qword [mac_sysval], 64      ; room in mac_oid
    lea r10, [mac_sysval]
    mov eax, SYS_SYSCTL
    SYSCALL
    test rax, rax
    js .ret
    lea rdi, [mac_oid]
    mov rsi, [mac_sysval]
    shr rsi, 2                      ; bytes -> levels
    mov rdx, [rsp + 8]
    lea r10, [rsp + 16]
    xor r8d, r8d
    xor r9d, r9d
    mov eax, SYS_SYSCTL
    SYSCALL
    test rax, rax
    js .ret
    mov rax, [rsp + 16]
.ret:
    add rsp, 24
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rsi
    pop rdi
    ret

; mac_uts_field(edi, esi = sysctl name, r9 = 65-byte field): copy, NUL-ended
mac_uts_field:
    push rdx
    push r8
    lea rdx, [mac_path_tmp]
    mov r8d, MAC_PATH_MAX - 1
    call mac_sysctl2
    test rax, rax
    js .ret
    lea rdx, [mac_path_tmp]
    xor ecx, ecx
.copy:
    cmp ecx, UTS_FIELD - 1
    jae .ret
    cmp rcx, rax
    jae .ret
    mov r8b, [rdx + rcx]
    test r8b, r8b
    jz .ret
    mov [r9 + rcx], r8b
    inc ecx
    jmp .copy
.ret:
    pop r8
    pop rdx
    ret

; ----------------------------------------------------------------------------
; mac_uname(rdi = struct utsname, Linux layout) -> rax = 0
; ----------------------------------------------------------------------------
mac_uname:
    push rdi
    push rsi
    push r9
    mov r9, rdi
    xor eax, eax
    mov ecx, UTS_FIELD * 6
.clear:
    mov byte [rdi], 0
    inc rdi
    dec ecx
    jnz .clear
    mov edi, MAC_CTL_KERN
    mov esi, MAC_KERN_OSTYPE
    call mac_uts_field
    add r9, UTS_FIELD
    mov esi, MAC_KERN_HOSTNAME
    call mac_uts_field
    add r9, UTS_FIELD
    mov esi, MAC_KERN_OSRELEASE
    call mac_uts_field
    add r9, UTS_FIELD
    mov esi, MAC_KERN_VERSION
    call mac_uts_field
    add r9, UTS_FIELD
    mov edi, MAC_CTL_HW
    mov esi, MAC_HW_MACHINE
    call mac_uts_field
    xor eax, eax
    pop r9
    pop rsi
    pop rdi
    ret

; ----------------------------------------------------------------------------
; mac_utimensat(edi = dirfd, rsi = path or NULL, rdx = timespec[2] or NULL,
;               r10 = flags) -> rax = 0 or -errno
; Only what the shell uses: a path from the current folder (utimes) or,
; with path NULL, the descriptor itself (futimes). NULL times = now.
; ----------------------------------------------------------------------------
mac_utimensat:
    push rdi
    push rsi
    push rdx
    push r8
    sub rsp, 32
    xor r8d, r8d                    ; r8 = struct timeval[2] or NULL
    test rdx, rdx
    jz .call
    mov rcx, rdx
    mov rax, [rcx]
    mov [rsp], rax
    mov rax, [rcx + 8]
    xor edx, edx
    mov r8d, 1000
    div r8
    mov [rsp + 8], rax
    mov rax, [rcx + 16]
    mov [rsp + 16], rax
    mov rax, [rcx + 24]
    xor edx, edx
    div r8
    mov [rsp + 24], rax
    mov r8, rsp
.call:
    test rsi, rsi
    jz .fd
    mov rdi, rsi
    mov eax, SYS_UTIMES
    jmp .go
.fd:
    mov eax, SYS_FUTIMES
.go:
    mov rsi, r8
    SYSCALL
    add rsp, 32
    pop r8
    pop rdx
    pop rsi
    pop rdi
    ret

; ----------------------------------------------------------------------------
; mac_readlink_self(rdi = ignored, rsi = buf, edx = size) -> rax = length
; What readlink("/proc/self/exe") gives on Linux: proc_info PIDPATHINFO.
; Linux adds " (deleted)" when that file is gone or was replaced; here the
; same happens when the path no longer names the file seen at startup
; (mac_self_record), so `update install` never writes over a newer program.
; ----------------------------------------------------------------------------
mac_readlink_self:
    push rdi
    push rsi
    push rdx
    push r8
    push r9
    push r10
    call mac_self_path
    test rax, rax
    js .ret
    cmp byte [mac_self_known], 0
    je .copy_start
    lea rdi, [mac_path_tmp]
    lea rsi, [mac_stat_tmp]
    mov eax, SYS_STAT
    SYSCALL
    test rax, rax
    jnz .gone
    mov eax, [mac_stat_tmp]             ; st_dev
    cmp eax, [mac_self_dev]
    jne .gone
    mov rax, [mac_stat_tmp + 8]         ; st_ino
    cmp rax, [mac_self_ino]
    je .copy_start
.gone:
    lea rdi, [mac_path_tmp]
    xor eax, eax
.end:
    cmp byte [rdi + rax], 0
    je .append
    inc eax
    jmp .end
.append:
    cmp eax, MAC_PATH_MAX - 16
    jae .copy_start
    lea rsi, [mac_s_deleted]
    add rdi, rax
.app:
    mov cl, [rsi]
    mov [rdi], cl
    inc rsi
    inc rdi
    test cl, cl
    jnz .app
.copy_start:
    mov rsi, [rsp + 32]                 ; buf
    mov edx, [rsp + 24]                 ; size
    lea rdi, [mac_path_tmp]
    xor eax, eax
.copy:
    cmp eax, edx
    jae .ret
    mov cl, [rdi + rax]
    test cl, cl
    jz .ret
    mov [rsi + rax], cl
    inc eax
    jmp .copy
.ret:
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rsi
    pop rdi
    ret

; mac_self_path() -> mac_path_tmp = this program's path, rax < 0 on error
; (clobbers rdi, rsi, rdx, r8, r9, r10)
mac_self_path:
    mov eax, SYS_GETPID
    SYSCALL
    mov esi, eax
    mov edi, MAC_PROC_PIDINFO
    mov edx, MAC_PIDPATHINFO
    xor r10d, r10d
    lea r8, [mac_path_tmp]
    mov r9d, MAC_PATH_MAX - 16          ; room for " (deleted)"
    mov eax, SYS_PROC_INFO
    SYSCALL
    ret

; mac_self_record() - remember the device and inode of this program's file
mac_self_record:
    push rbx
    call mac_self_path
    test rax, rax
    js .done
    lea rdi, [mac_path_tmp]
    lea rsi, [mac_stat_tmp]
    mov eax, SYS_STAT
    SYSCALL
    test rax, rax
    jnz .done
    mov eax, [mac_stat_tmp]
    mov [mac_self_dev], eax
    mov rax, [mac_stat_tmp + 8]
    mov [mac_self_ino], rax
    mov byte [mac_self_known], 1
.done:
    pop rbx
    ret

; ----------------------------------------------------------------------------
; mac_poll(rdi = struct pollfd (one), esi = 1, edx = timeout ms) -> rax
; XNU's poll does not work on terminals, so this is select() on the one fd.
; ----------------------------------------------------------------------------
mac_poll:
    push rdi
    push rsi
    push rdx
    push r8
    push r9
    push r10
    push rbx
    sub rsp, 16
    mov rbx, rdi
    lea rdi, [mac_fdset]
    xor eax, eax
    mov ecx, 16
.clear:
    mov [rdi], rax
    add rdi, 8
    dec ecx
    jnz .clear
    mov eax, [rbx]
    bts [mac_fdset], eax
    xor r8d, r8d                    ; no timeout: wait
    test edx, edx
    js .call
    mov eax, edx
    xor edx, edx
    mov ecx, 1000
    div ecx
    mov [rsp], rax                  ; tv_sec
    imul edx, edx, 1000
    mov [rsp + 8], rdx              ; tv_usec
    mov r8, rsp
.call:
    mov edi, [rbx]
    inc edi
    lea rsi, [mac_fdset]
    xor edx, edx
    xor r10d, r10d
    mov eax, SYS_SELECT
    SYSCALL
    test rax, rax
    jle .ret
    mov word [rbx + 6], 1           ; revents = POLLIN
    mov eax, 1
.ret:
    add rsp, 16
    pop rbx
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rsi
    pop rdi
    ret

; ----------------------------------------------------------------------------
; plat_uptime_seconds -> eax = seconds since boot, or -1
; ----------------------------------------------------------------------------
plat_uptime_seconds:
    sub rsp, 24
    mov edi, MAC_CTL_KERN
    mov esi, MAC_KERN_BOOTTIME
    mov rdx, rsp
    mov r8d, 16
    call mac_sysctl2
    test rax, rax
    js .fail
    call mac_now
    sub rax, [rsp]
    js .fail
    add rsp, 24
    ret
.fail:
    mov eax, -1
    add rsp, 24
    ret

; ----------------------------------------------------------------------------
; handler_free - total and free memory, in the /proc/meminfo style
; ----------------------------------------------------------------------------
handler_free:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 24
    mov edi, MAC_CTL_HW
    mov esi, MAC_HW_MEMSIZE
    lea rdx, [rsp]
    mov r8d, 8
    call mac_sysctl2
    test rax, rax
    js .err
    lea rdi, [mac_s_memtotal]
    call print_cstring
    mov rax, [rsp]
    shr rax, 10
    call print_number_9pad
    lea rdi, [mac_s_kb]
    call print_cstring

    mov qword [rsp], 0
    mov qword [rsp + 8], 0
    lea rdi, [mac_s_pagefree]
    lea rdx, [rsp]
    mov r8d, 4
    call mac_sysctl_name
    test rax, rax
    js .done
    lea rdi, [mac_s_pagesize]
    lea rdx, [rsp + 8]
    mov r8d, 4
    call mac_sysctl_name
    test rax, rax
    js .done
    lea rdi, [mac_s_memfree]
    call print_cstring
    mov eax, [rsp]
    mov ecx, [rsp + 8]
    imul rax, rcx
    shr rax, 10
    call print_number_9pad
    lea rdi, [mac_s_kb]
    call print_cstring
    jmp .done
.err:
    lea rdi, [mac_s_free_err]
    call ash_write_err
    mov dword [last_exit_status], 1
.done:
    add rsp, 24
    pop rbx
    pop rbp
    ret

; ----------------------------------------------------------------------------
; trace and sandbox are built on Linux ptrace, seccomp and Landlock
; ----------------------------------------------------------------------------
handler_trace:
    sub rsp, 8
    lea rdi, [mac_s_no_trace]
    call ash_write_err
    mov dword [last_exit_status], 1
    add rsp, 8
    ret

handler_sandbox:
    sub rsp, 8
    lea rdi, [mac_s_no_sandbox]
    call ash_write_err
    mov dword [last_exit_status], 126  ; fails closed, as when Landlock is missing
    add rsp, 8
    ret
