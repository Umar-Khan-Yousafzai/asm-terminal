; ============================================================================
; platform/linux.inc - Linux x86-64 ABI: system call numbers, flags, errno
; values, structure layouts and the macros the shared code uses to make
; system calls.
;
; The shared code (terminal_linux.asm and ash/*.asm) never writes one of
; these numbers itself, so a port only needs its own copy of this file
; (platform/macos.inc for macOS). Every system call goes through:
;   SYSCALL          a call that returns rax >= 0, or -errno on failure
;   SYSCALL_X name   a call another system may not have under this number or
;                    shape (fork, pipe2, getcwd, getdents64 ...). Here it is a
;                    plain syscall; a port can replace it with a routine.
;   SYSNO number     load a system call number into eax
; Both keep every register but rax, rcx and r11, as the Linux kernel does.
; ============================================================================

%define PLATFORM_LINUX      1
%define PLATFORM_NAME       "Linux"
%define UPDATE_ASSET        "asm-terminal-linux-x86_64"  ; release file `update` installs

%macro SYSCALL 0
    syscall
%endmacro

%macro SYSCALL_X 1
    syscall
%endmacro

; SYSNO number - put a system call number in eax (xor for 0, as the code always did)
%macro SYSNO 1
%if (%1) == 0
    xor eax, eax
%else
    mov eax, %1
%endif
%endmacro

; ----------------------------------------------------------------------------
; System call numbers
; ----------------------------------------------------------------------------
%define SYS_READ            0
%define SYS_WRITE           1
%define SYS_OPEN            2
%define SYS_CLOSE           3
%define SYS_STAT            4
%define SYS_FSTAT           5
%define SYS_LSTAT           6
%define SYS_POLL            7
%define SYS_LSEEK           8
%define SYS_RT_SIGACTION    13
%define SYS_RT_SIGRETURN    15
%define SYS_IOCTL           16
%define SYS_ACCESS          21
%define SYS_PIPE            22
%define SYS_DUP2            33
%define SYS_GETPID          39
%define SYS_FORK            57
%define SYS_EXECVE          59
%define SYS_EXIT            60
%define SYS_WAIT4           61
%define SYS_KILL            62
%define SYS_UNAME           63
%define SYS_FCNTL           72
%define SYS_FLOCK           73
%define SYS_FSYNC           74
%define SYS_FTRUNCATE       77
%define SYS_GETCWD          79
%define SYS_CHDIR           80
%define SYS_RENAME          82
%define SYS_MKDIR           83
%define SYS_RMDIR           84
%define SYS_UNLINK          87
%define SYS_SYMLINK         88
%define SYS_READLINK        89
%define SYS_CHMOD           90
%define SYS_FCHMOD          91
%define SYS_GETUID          102
%define SYS_GETEUID         107
%define SYS_SETPGID         109
%define SYS_GETPGRP         111
%define SYS_SETSID          112
%define SYS_SIGALTSTACK     131
%define SYS_TIME            201
%define SYS_GETDENTS64      217
%define SYS_CLOCK_GETTIME   228
%define SYS_NEWFSTATAT      262
%define SYS_READLINKAT      267
%define SYS_UTIMENSAT       280
%define SYS_PIPE2           293
%define SYS_RENAMEAT2       316

; ----------------------------------------------------------------------------
; Terminal: ioctl requests and struct termios
; ----------------------------------------------------------------------------
%define TCGETS              0x5401
%define TCSETS              0x5402
%define TIOCGWINSZ          0x5413
%define TIOCGPGRP           0x540F
%define TIOCSPGRP           0x5410

; c_lflag bits
%define ICANON              0x0002
%define ECHO_FLAG           0x0008
%define ISIG                0x0001
%define RAW_LFLAG_CLEAR     (ICANON | ECHO_FLAG | ISIG)   ; raw mode turns these off

%define TERMIOS_SIZE        60      ; the buffers TCGETS / TCSETS use
%define TERMIOS_C_LFLAG     12      ; offset of c_lflag (only its low 32 bits are touched)
%define TERMIOS_C_CC        17      ; offset of the c_cc array
%define VMIN_INDEX          6       ; c_cc[VMIN]
%define VTIME_INDEX         5       ; c_cc[VTIME]
%define VQUIT_INDEX         1       ; c_cc[VQUIT]
%define VSUSP_INDEX         10      ; c_cc[VSUSP]

; ----------------------------------------------------------------------------
; Signals
; ----------------------------------------------------------------------------
%define SIGHUP              1
%define SIGINT              2
%define SIGQUIT             3
%define SIGILL              4
%define SIGTRAP             5
%define SIGABRT             6
%define SIGBUS              7
%define SIGFPE              8
%define SIGKILL             9
%define SIGUSR1             10
%define SIGSEGV             11
%define SIGUSR2             12
%define SIGPIPE             13
%define SIGALRM             14
%define SIGTERM             15
%define SIGCHLD             17
%define SIGCONT             18
%define SIGSTOP             19
%define SIGTSTP             20
%define SIGTTIN             21
%define SIGTTOU             22
%define SIGWINCH            28
%define SIG_IGN             1

; kill -l and kill -NAME: NUL-ended name, then the signal number byte
%macro SIGNAL_NAME_TABLE 0
    db "HUP", 0, 1,  "INT", 0, 2,  "QUIT", 0, 3
    db "ILL", 0, 4,  "TRAP", 0, 5, "ABRT", 0, 6
    db "BUS", 0, 7,  "FPE", 0, 8,  "KILL", 0, 9
    db "USR1", 0, 10, "SEGV", 0, 11, "USR2", 0, 12
    db "PIPE", 0, 13, "ALRM", 0, 14, "TERM", 0, 15
    db "STKFLT", 0, 16, "CHLD", 0, 17, "CONT", 0, 18
    db "STOP", 0, 19, "TSTP", 0, 20, "TTIN", 0, 21
    db "TTOU", 0, 22, "URG", 0, 23, "XCPU", 0, 24
    db "XFSZ", 0, 25, "VTALRM", 0, 26, "PROF", 0, 27
    db "WINCH", 0, 28, "IO", 0, 29, "PWR", 0, 30
    db "SYS", 0, 31, 0
%endmacro

%define SA_RESTORER         0x04000000
%define SA_RESTART          0x10000000
%define SA_ONSTACK          0x08000000
%define SA_RESETHAND        0x80000000

; struct sigaction as rt_sigaction takes it: 32 bytes
%define SIGACTION_SIZE      32

; SIGACT_FILL base, handler, flags - fill the struct sigaction at [base]
; (a register) with no blocked signals. Clobbers rcx.
%macro SIGACT_FILL 3
    lea rcx, [%2]
    mov [%1], rcx                   ; sa_handler
%if (%3) >= 0x80000000
    mov ecx, %3
    mov [%1 + 8], rcx               ; sa_flags
%else
    mov qword [%1 + 8], %3          ; sa_flags
%endif
    lea rcx, [sig_restorer]
    mov [%1 + 16], rcx              ; sa_restorer
    mov qword [%1 + 24], 0          ; sa_mask
%endmacro

; stack_t for sigaltstack
%define STACK_T_SIZE        24
%define STACK_T_FLAGS       8
%define STACK_T_SIZE_OFF    16

; ----------------------------------------------------------------------------
; Files
; ----------------------------------------------------------------------------
%define O_RDONLY            0
%define O_WRONLY            1
%define O_RDWR              2
%define O_CREAT             0x40
%define O_EXCL              0x80
%define O_TRUNC             0x200
%define O_APPEND            0x400
%define O_NONBLOCK          0x800
%define O_DIRECTORY         0x10000
%define O_CLOEXEC           0x80000

%define F_SETFD             2
%define F_SETFL             4
%define F_DUPFD_CLOEXEC     1030
%define LOCK_EX             2

%define AT_FDCWD            -100
%define AT_SYMLINK_NOFOLLOW 0x100
%define RENAME_NOREPLACE    1

; struct stat (x86-64)
%define STAT_SIZE           144
%define STAT_ST_INO         8
%define STAT_ST_MODE        24      ; u32
%define STAT_ST_UID         28
%define STAT_ST_SIZE        48
%define STAT_ST_ATIM        72      ; struct timespec st_atim, then st_mtim
%define STAT_ST_MTIME       88      ; st_mtim.tv_sec

; struct linux_dirent64 as getdents64 returns it
%define DIRENT64_D_INO      0       ; 8 bytes
%define DIRENT64_D_OFF      8       ; 8 bytes
%define DIRENT64_D_RECLEN   16      ; 2 bytes
%define DIRENT64_D_TYPE     18      ; 1 byte
%define DIRENT64_D_NAME     19      ; variable

; struct rusage
%define RUSAGE_SIZE         144
%define RU_MAXRSS           32      ; long ru_maxrss
%define RU_MAXRSS_SHIFT     0       ; ru_maxrss >> this = KiB (Linux counts KiB)

; struct utsname: 65-byte fields sysname, nodename, release, version, machine
%define UTS_FIELD           65
%define UTS_NODENAME        65

; ----------------------------------------------------------------------------
; wait4 options
; ----------------------------------------------------------------------------
%define WNOHANG             1
%define WUNTRACED           2
%define WCONTINUED          8

; ----------------------------------------------------------------------------
; errno values (system calls return them negated)
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
%define ENAMETOOLONG        36
%define ENOSYS              38
%define ENOTEMPTY           39
%define ELOOP               40
%define EINPROGRESS         115

; ----------------------------------------------------------------------------
; Clocks
; ----------------------------------------------------------------------------
%define CLOCK_REALTIME      0
%define CLOCK_MONOTONIC     1

; access modes
%define F_OK                0
%define X_OK                1
%define W_OK                2
%define R_OK                4
