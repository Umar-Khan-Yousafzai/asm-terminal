; ============================================================================
; platform/macos.inc - macOS x86-64 (XNU) ABI for the shared code
;
; Same names as platform/linux.inc, macOS values. The binary is Mach-O,
; linked against libSystem only because dyld insists on it: no libSystem
; function is ever called, every system call is a raw `syscall`.
;
; XNU differences the macros hide:
;   - BSD call numbers are 0x2000000 + n
;   - an error sets the carry flag and returns the positive errno in rax;
;     SYSCALL turns that into -errno, as Linux returns it
;   - fork returns the parent's pid in the child too (rdx = 1 there)
;   - pipe returns both ends in rax and rdx
;   - no getcwd, getdents64, clock_gettime, uname, utimensat, time or pipe2
;     system calls: SYSCALL_X calls a routine in platform/macos.asm that
;     does the same job with the calls XNU has
; Runs on Apple Silicon through Rosetta 2.
; ============================================================================

%define PLATFORM_MACOS      1
%define PLATFORM_NAME       "macOS"
%define UPDATE_ASSET        "asm-terminal-macos-x86_64"  ; release file `update` installs
%define SHA256_TOOL         "shasum"                     ; run as shasum -a 256

%macro SYSCALL 0
    syscall
    jnc %%ok
    neg rax
%%ok:
%endmacro

; SYSCALL_X name - a routine in platform/macos.asm (mac_name) that acts like
; the Linux call: same arguments, rax = result or -errno, and every register
; but rax, rcx and r11 kept.
%macro SYSCALL_X 1
    call mac_%1
%endmacro

%macro SYSNO 1
    mov eax, %1
%endmacro

; ----------------------------------------------------------------------------
; System call numbers (BSD class)
; ----------------------------------------------------------------------------
%define MAC_SYS(n)          (0x2000000 + (n))
%define SYS_EXIT            MAC_SYS(1)
%define SYS_FORK            MAC_SYS(2)
%define SYS_READ            MAC_SYS(3)
%define SYS_WRITE           MAC_SYS(4)
%define SYS_OPEN            MAC_SYS(5)
%define SYS_CLOSE           MAC_SYS(6)
%define SYS_WAIT4           MAC_SYS(7)
%define SYS_UNLINK          MAC_SYS(10)
%define SYS_CHDIR           MAC_SYS(12)
%define SYS_CHMOD           MAC_SYS(15)
%define SYS_GETPID          MAC_SYS(20)
%define SYS_GETUID          MAC_SYS(24)
%define SYS_GETEUID         MAC_SYS(25)
%define SYS_ACCESS          MAC_SYS(33)
%define SYS_KILL            MAC_SYS(37)
%define SYS_PIPE            MAC_SYS(42)
%define SYS_RT_SIGACTION    MAC_SYS(46)     ; sigaction(sig, act, oact); r10 is ignored
%define SYS_RT_SIGPROCMASK  MAC_SYS(48)     ; sigprocmask(how, &set32, &old)
%define SIG_UNBLOCK         2
%define SYS_SIGALTSTACK     MAC_SYS(53)
%define SYS_IOCTL           MAC_SYS(54)
%define SYS_SYMLINK         MAC_SYS(57)
%define SYS_READLINK        MAC_SYS(58)
%define SYS_EXECVE          MAC_SYS(59)
%define SYS_GETPGRP         MAC_SYS(81)
%define SYS_SETPGID         MAC_SYS(82)
%define SYS_DUP2            MAC_SYS(90)
%define SYS_FCNTL           MAC_SYS(92)
%define SYS_SELECT          MAC_SYS(93)
%define SYS_FSYNC           MAC_SYS(95)
%define SYS_GETTIMEOFDAY    MAC_SYS(116)
%define SYS_FCHMOD          MAC_SYS(124)
%define SYS_RENAME          MAC_SYS(128)
%define SYS_FLOCK           MAC_SYS(131)
%define SYS_MKDIR           MAC_SYS(136)
%define SYS_RMDIR           MAC_SYS(137)
%define SYS_UTIMES          MAC_SYS(138)
%define SYS_FUTIMES         MAC_SYS(139)
%define SYS_SETSID          MAC_SYS(147)
%define SYS_SIGRETURN       MAC_SYS(184)
%define SYS_LSEEK           MAC_SYS(199)
%define SYS_FTRUNCATE       MAC_SYS(201)
%define SYS_SYSCTL          MAC_SYS(202)
%define SYS_POLL            MAC_SYS(230)    ; does not work on ttys: SYSCALL_X poll uses select
%define SYS_PROC_INFO       MAC_SYS(336)
%define SYS_STAT            MAC_SYS(338)    ; stat64, fstat64, lstat64: the struct below
%define SYS_FSTAT           MAC_SYS(339)
%define SYS_LSTAT           MAC_SYS(340)
%define SYS_GETDIRENTRIES64 MAC_SYS(344)
%define SYS_OPENAT          MAC_SYS(463)
%define SYS_NEWFSTATAT      MAC_SYS(470)    ; fstatat64
%define SYS_READLINKAT      MAC_SYS(473)
%define SYS_RENAMEAT2       MAC_SYS(488)    ; renameatx_np: same arguments as renameat2

; Emulated by SYSCALL_X (the number only fills eax; mac_* ignores it)
%define SYS_GETCWD          0
%define SYS_GETDENTS64      SYS_GETDIRENTRIES64
%define SYS_CLOCK_GETTIME   0
%define SYS_UNAME           0
%define SYS_UTIMENSAT       0
%define SYS_TIME            0
%define SYS_PIPE2           SYS_PIPE

; ----------------------------------------------------------------------------
; Terminal
; ----------------------------------------------------------------------------
%define TCGETS              0x40487413      ; TIOCGETA
%define TCSETS              0x80487414      ; TIOCSETA
%define TIOCGWINSZ          0x40087468
%define TIOCGPGRP           0x40047477
%define TIOCSPGRP           0x80047476

%define ICANON              0x00000100
%define ECHO_FLAG           0x00000008
%define ISIG                0x00000080
%define IEXTEN              0x00000400      ; ^V and ^O: off in raw mode
%define RAW_LFLAG_CLEAR     (ICANON | ECHO_FLAG | ISIG | IEXTEN)

; struct termios: tcflag_t is 8 bytes, c_cc[20] at 32, speeds after it
%define TERMIOS_SIZE        72
%define TERMIOS_C_LFLAG     24
%define TERMIOS_C_CC        32
%define VMIN_INDEX          16
%define VTIME_INDEX         17
%define VQUIT_INDEX         9
%define VSUSP_INDEX         10
%define POSIX_VDISABLE      0xFF            ; a c_cc value that turns the key off

; ----------------------------------------------------------------------------
; Signals
; ----------------------------------------------------------------------------
%define SIGHUP              1
%define SIGINT              2
%define SIGQUIT             3
%define SIGILL              4
%define SIGTRAP             5
%define SIGABRT             6
%define SIGFPE              8
%define SIGKILL             9
%define SIGBUS              10
%define SIGSEGV             11
%define SIGSYS              12
%define SIGPIPE             13
%define SIGALRM             14
%define SIGTERM             15
%define SIGURG              16
%define SIGSTOP             17
%define SIGTSTP             18
%define SIGCONT             19
%define SIGCHLD             20
%define SIGTTIN             21
%define SIGTTOU             22
%define SIGWINCH            28
%define SIGUSR1             30
%define SIGUSR2             31
%define SIG_IGN             1

%macro SIGNAL_NAME_TABLE 0
    db "HUP", 0, 1,  "INT", 0, 2,  "QUIT", 0, 3
    db "ILL", 0, 4,  "TRAP", 0, 5, "ABRT", 0, 6
    db "EMT", 0, 7,  "FPE", 0, 8,  "KILL", 0, 9
    db "BUS", 0, 10, "SEGV", 0, 11, "SYS", 0, 12
    db "PIPE", 0, 13, "ALRM", 0, 14, "TERM", 0, 15
    db "URG", 0, 16, "STOP", 0, 17, "TSTP", 0, 18
    db "CONT", 0, 19, "CHLD", 0, 20, "TTIN", 0, 21
    db "TTOU", 0, 22, "IO", 0, 23, "XCPU", 0, 24
    db "XFSZ", 0, 25, "VTALRM", 0, 26, "PROF", 0, 27
    db "WINCH", 0, 28, "INFO", 0, 29, "USR1", 0, 30
    db "USR2", 0, 31, 0
%endmacro

%define SA_RESTORER         0               ; XNU takes the trampoline in the struct
%define SA_ONSTACK          0x0001
%define SA_RESTART          0x0002
%define SA_RESETHAND        0x0004

; struct __sigaction: handler, trampoline, u32 mask, i32 flags (24 bytes).
; The buffers stay 32 bytes: jc_tty_signals clears 32.
%define SIGACTION_SIZE      32

%macro SIGACT_FILL 3
    lea rcx, [%2]
    mov [%1], rcx                   ; sa_handler
    lea rcx, [mac_sigtramp]
    mov [%1 + 8], rcx               ; sa_tramp
    mov dword [%1 + 16], 0          ; sa_mask
    ; SA_SIGINFO (0x40): the handlers ignore the extra arguments, but the
    ; kernel then hands mac_sigtramp the full context style, which is the
    ; one Rosetta 2 expects back in sigreturn
    mov dword [%1 + 20], (%3) | 0x40 ; sa_flags
%endmacro

; stack_t: ss_sp, ss_size, ss_flags
%define STACK_T_SIZE        24
%define STACK_T_FLAGS       16
%define STACK_T_SIZE_OFF    8

; ----------------------------------------------------------------------------
; Files
; ----------------------------------------------------------------------------
%define O_RDONLY            0
%define O_WRONLY            1
%define O_RDWR              2
%define O_NONBLOCK          0x4
%define O_APPEND            0x8
%define O_CREAT             0x200
%define O_TRUNC             0x400
%define O_EXCL              0x800
%define O_DIRECTORY         0x100000
%define O_CLOEXEC           0x1000000

%define F_SETFD             2
%define F_SETFL             4
%define F_GETPATH           50
%define F_DUPFD_CLOEXEC     67
%define FD_CLOEXEC          1
%define LOCK_EX             2

%define AT_FDCWD            -2
%define AT_SYMLINK_NOFOLLOW 0x20
%define RENAME_NOREPLACE    0x4             ; RENAME_EXCL

; struct stat64. st_mode is 16 bits with st_nlink above it: a dword read
; must be masked (all readers mask with S_IFMT or 0o7777).
%define STAT_SIZE           144
%define STAT_ST_INO         8
%define STAT_ST_MODE        4
%define STAT_ST_UID         16
%define STAT_ST_SIZE        96
%define STAT_ST_ATIM        32              ; st_atimespec, then st_mtimespec
%define STAT_ST_MTIME       48

; struct direntry as getdirentries64 returns it
%define DIRENT64_D_INO      0
%define DIRENT64_D_OFF      8               ; d_seekoff
%define DIRENT64_D_RECLEN   16
%define DIRENT64_D_TYPE     20              ; after the 2-byte d_namlen
%define DIRENT64_D_NAME     21

%define RUSAGE_SIZE         144
%define RU_MAXRSS           32
%define RU_MAXRSS_SHIFT     10              ; macOS counts bytes

; mac_uname fills the same struct utsname layout as Linux
%define UTS_FIELD           65
%define UTS_NODENAME        65

; ----------------------------------------------------------------------------
; wait4 options
; ----------------------------------------------------------------------------
%define WNOHANG             1
%define WUNTRACED           2
%define WCONTINUED          0x10
%define WSTATUS_CONTINUED   0x137F          ; "stopped" by SIGCONT (19): resumed

; ----------------------------------------------------------------------------
; errno
; ----------------------------------------------------------------------------
%define EPERM               1
%define ENOENT              2
%define ESRCH               3
%define EINTR               4
%define EIO                 5
%define E2BIG               7
%define ENOEXEC             8
%define ENOMEM              12
%define EACCES              13
%define EEXIST              17
%define EXDEV               18
%define ENOTDIR             20
%define EISDIR              21
%define EINVAL              22
%define ETXTBSY             26
%define EFBIG               27
%define ENOSPC              28
%define EROFS               30
%define ERANGE              34
%define EINPROGRESS         36
%define ENOTSUP             45
%define ELOOP               62
%define ENAMETOOLONG        63
%define ENOTEMPTY           66
%define ENOSYS              78

%define CLOCK_REALTIME      0
%define CLOCK_MONOTONIC     1

%define F_OK                0
%define X_OK                1
%define W_OK                2
%define R_OK                4
