; ============================================================================
; ASM Terminal - Full-featured terminal in x86-64 Assembly (NASM)
; Target: Linux x86-64, using raw syscalls (no libc)
; Port of the Windows version to Linux
; ============================================================================
bits 64
default rel

%include "version.inc"

; ============================================================================
; Linux syscall numbers
; ============================================================================
%define SYS_READ            0
%define SYS_WRITE           1
%define SYS_OPEN            2
%define SYS_CLOSE           3
%define SYS_STAT            4
%define SYS_FSTAT           5
%define SYS_LSEEK           8
%define SYS_RT_SIGACTION    13
%define SYS_RT_SIGRETURN    15
%define SYS_IOCTL           16
%define SYS_PIPE            22
%define SYS_DUP2            33
%define SYS_FORK            57
%define SYS_EXECVE          59
%define SYS_EXIT            60
%define SYS_WAIT4           61
%define SYS_KILL            62
%define SYS_UNAME           63
%define SYS_GETCWD          79
%define SYS_CHDIR           80
%define SYS_RENAME          82
%define SYS_MKDIR           83
%define SYS_RMDIR           84
%define SYS_UNLINK          87
%define SYS_READLINK        89
%define SYS_GETUID          102
%define SYS_GETEUID         107
%define SYS_GETDENTS64      217
%define SYS_CLOCK_GETTIME   228
%define SYS_NEWFSTATAT      262

; ============================================================================
; Terminal / file / signal constants
; ============================================================================
; ioctl request codes
%define TCGETS              0x5401
%define TCSETS              0x5402
%define TIOCGWINSZ          0x5413

; termios c_lflag bits
%define ICANON              0x0002
%define ECHO_FLAG           0x0008
%define ISIG                0x0001

; termios structure offsets
%define TERMIOS_C_LFLAG     12      ; offset of c_lflag in struct termios
%define TERMIOS_C_CC        17      ; offset of c_cc array
%define VMIN_INDEX          6       ; c_cc[6] = VMIN
%define VTIME_INDEX         5       ; c_cc[5] = VTIME

; Signal constants
%define SIGINT              2
%define SIGCONT             18
%define SIGTSTP             20
%define SIGHUP              1
%define SIGTERM             15
%define SA_RESTORER         0x04000000
%define SA_RESTART          0x10000000

; File open flags
%define O_RDONLY            0
%define O_WRONLY            1
%define O_RDWR              2
%define O_CREAT             0x40
%define O_TRUNC             0x200
%define O_APPEND            0x400

; File mode bits
%define S_IRUSR             0o400
%define S_IWUSR             0o200
%define S_IRGRP             0o040
%define S_IROTH             0o004
%define FILE_MODE_DEFAULT   0o644   ; rw-r--r--
%define DIR_MODE_DEFAULT    0o755   ; rwxr-xr-x

; dirent64 structure offsets
%define DIRENT64_D_INO      0       ; 8 bytes
%define DIRENT64_D_OFF      8       ; 8 bytes
%define DIRENT64_D_RECLEN   16      ; 2 bytes
%define DIRENT64_D_TYPE     18      ; 1 byte
%define DIRENT64_D_NAME     19      ; variable

; d_type values
%define DT_DIR              4
%define DT_REG              8

; stat structure offsets (x86-64 Linux)
%define STAT_ST_MODE        24      ; offset of st_mode
%define STAT_ST_SIZE        48      ; offset of st_size
%define STAT_ST_UID         28      ; offset of st_uid

; Clock IDs
%define CLOCK_REALTIME      0

; File descriptors
%define STDIN_FD            0
%define STDOUT_FD           1
%define STDERR_FD           2

; ============================================================================
; Shared constants (same as Windows version)
; ============================================================================
%define MAX_INPUT           512
%define MAX_PATH_BUF        4096    ; Linux paths can be much longer than Windows

; ---------------------------------------------------------------------------
; Convenience macros for common patterns throughout the codebase.
; These do not change semantics — they just compact repetitive sequences.
; ---------------------------------------------------------------------------

%macro PRINT_BYTES 2
    lea rdi, [%1]
    mov esi, %2
    call print_string_len
%endmacro

%macro PRINT_CSTR 1
    lea rdi, [%1]
    call print_cstring
%endmacro

%macro SYSCALL_N 1
    mov eax, %1
    syscall
%endmacro

%define HISTORY_COUNT       500
%define HISTORY_ENTRY_SIZE  512
%define ALIAS_COUNT         32
%define ALIAS_NAME_SIZE     64
%define ALIAS_CMD_SIZE      256
%define ALIAS_ENTRY_SIZE    320
%define DIR_STACK_COUNT     16
%define READ_BUF_SIZE       4096

; Virtual key constants (same as Windows for internal use)
%define VK_BACK             0x08
%define VK_TAB              0x09
%define VK_RETURN           0x0D
%define VK_END              0x23
%define VK_HOME             0x24
%define VK_LEFT             0x25
%define VK_UP               0x26
%define VK_RIGHT            0x27
%define VK_DOWN             0x28
%define VK_DELETE           0x2E

; ---- Additional constants needed by part 2 ----
%define O_DIRECTORY         0x10000
%define DIRENT_BUF_SIZE     8192
%define DIRENT_D_INO        DIRENT64_D_INO
%define DIRENT_D_OFF        DIRENT64_D_OFF
%define DIRENT_D_RECLEN     DIRENT64_D_RECLEN
%define DIRENT_D_TYPE       DIRENT64_D_TYPE
%define DIRENT_D_NAME       DIRENT64_D_NAME
%define PERM_0644           FILE_MODE_DEFAULT
%define PERM_0755           DIR_MODE_DEFAULT
%define ENV_OVERLAY_SIZE    512
%define ENV_OVERLAY_COUNT   256
%define MERGED_ENVP_MAX     8192    ; env slots handed to a child, NULL included
%define AT_FDCWD            -100
%define S_IFDIR             0o040000

; Timezone used when neither $ASM_TZ nor $TZ is usable: PKT = UTC+5 = 18000 seconds
%define TZ_OFFSET_SECONDS   18000
%define TZ_NAME_DEFAULT     "PKT"

; ============================================================================
; ANSI escape sequence strings
; ============================================================================
section .data

    ; ANSI color codes
    ansi_green      db 27, "[32m", 0
    ansi_green_len  equ $ - ansi_green - 1
    ansi_white      db 27, "[97m", 0
    ansi_white_len  equ $ - ansi_white - 1
    ansi_default    db 27, "[0m", 0
    ansi_default_len equ $ - ansi_default - 1
    ansi_clear_eol  db 27, "[K", 0
    ansi_clear_eol_len equ $ - ansi_clear_eol - 1
    ansi_clear_screen db 27, "[2J", 27, "[H", 0
    ansi_clear_screen_len equ $ - ansi_clear_screen - 1
    ansi_cursor_col_prefix db 27, "[", 0  ; followed by number and 'G'

    ; Title escape sequences
    ansi_title_pre  db 27, "]0;", 0
    ansi_title_post db 7, 0             ; BEL character

    ; Clear screen
    ansi_clear      equ ansi_clear_screen

    ; Carriage return for line redraw
    str_cr          db 13, 0
    ansi_cr         equ str_cr

    prompt_gt       db "> ", 0
    newline         db 10, 0

; ============================================================================
; String data - welcome, help, errors, commands
; All strings use LF (10) instead of CRLF (13,10)
; ============================================================================

    welcome_msg     db 10
                    db "      _    ____  __  __", 10
                    db "     / \  / ___||  \/  |", 10
                    db "    / _ \ \___ \| |\/| |", 10
                    db "   / ___ \ ___) | |  | |", 10
                    db "  /_/   \_\____/|_|  |_|", 10
                    db 10
                    db "  ASM Terminal v", ASM_VERSION, " - x86-64 Assembly Shell", 10
                    db "  Type 'help' for available commands", 10
                    db 10, 0
    welcome_len     equ $ - welcome_msg - 1

    help_msg        db 10
                    db "  ASM Terminal v", ASM_VERSION, " - Command Reference", 10
                    db "  =====================================================", 10
                    db 10
                    db "  NAVIGATION", 10
                    db "  ---------------------------------------------------", 10
                    db "    cd <path>       Change directory", 10
                    db "                    cd /home        go to /home", 10
                    db "                    cd ..           go up one level", 10
                    db "                    cd -            go to previous dir", 10
                    db "                    cd              go to $HOME", 10
                    db "    pwd             Print working directory", 10
                    db "                    pwd", 10
                    db "    pushd <path>    Push dir onto stack and cd", 10
                    db "                    pushd /tmp", 10
                    db "    popd            Pop dir from stack and cd back", 10
                    db "                    popd", 10
                    db 10
                    db "  FILES", 10
                    db "  ---------------------------------------------------", 10
                    db "    ls [opts] [dir] List files (colored)", 10
                    db "                    ls              compact listing", 10
                    db "                    ls -l           long format", 10
                    db "                    ls -a           show hidden files", 10
                    db "                    ls -la /tmp     combined flags", 10
                    db "    dir [path]      List directory (classic format)", 10
                    db "                    dir             current directory", 10
                    db "                    dir /home       specific path", 10
                    db "    cat <file>      Display file contents", 10
                    db "                    cat README.md", 10
                    db "    type <file>     Display file contents (alias)", 10
                    db "                    type config.txt", 10
                    db "    copy <src> <dst>  Copy a file", 10
                    db "                    copy file.txt backup.txt", 10
                    db "    move <src> <dst>  Move/rename a file", 10
                    db "                    move old.txt new.txt", 10
                    db "    rename <s> <d>  Rename a file", 10
                    db "                    rename data.csv data_old.csv", 10
                    db "    del <file>      Delete a file", 10
                    db "                    del temp.log", 10
                    db "    mkdir <dir>     Create a directory", 10
                    db "                    mkdir projects", 10
                    db "    rmdir <dir>     Remove empty directory", 10
                    db "                    rmdir old_folder", 10
                    db "    grep <pat> <f>  Search file for pattern", 10
                    db "                    grep TODO main.c", 10
                    db "                    grep error log.txt", 10
                    db 10
                    db "  ENVIRONMENT", 10
                    db "  ---------------------------------------------------", 10
                    db "    set             List all environment variables", 10
                    db "    set <var>       Show value of a variable", 10
                    db "                    set HOME", 10
                    db "    set <var>=<val> Set environment variable", 10
                    db "                    set EDITOR=vim", 10
                    db "    export V=val    Same as set V=val", 10
                    db "    unset <var>     Remove a variable (also an inherited one)", 10
                    db "    whoami          Display current username", 10
                    db "                    whoami", 10
                    db 10
                    db "  DISPLAY", 10
                    db "  ---------------------------------------------------", 10
                    db "    echo <text>     Print text to screen", 10
                    db "                    echo Hello World!", 10
                    db "                    echo $HOME      expand variable", 10
                    db "    cls             Clear the screen", 10
                    db "    color <hex>     Set text color (Windows-style)", 10
                    db "                    color 0A        green on black", 10
                    db "                    color 0F        white on black", 10
                    db "    title <text>    Set terminal window title", 10
                    db "                    title My Shell", 10
                    db 10
                    db "  SYSTEM", 10
                    db "  ---------------------------------------------------", 10
                    db "    ver             Show version info", 10
                    db "    about           About ASM Terminal and its developer", 10
                    db "    update          Check for a new version ('update install' installs it)", 10
                    db "    date            Show current date and time", 10
                    db "                    date   -> Fri Apr  3 08:14:01 PM PKT 2026", 10
                    db "                    zone: ASM_TZ=<seconds east of UTC>, or TZ=EST5", 10
                    db "    time            Same as date", 10
                    db "    uptime          Show system uptime", 10
                    db "                    uptime -> up 2 days, 05:30:12", 10
                    db "    free            Show memory usage", 10
                    db "                    free   -> MemTotal, MemFree, ...", 10
                    db "    calc <expr>     Integer calculator (+, -, *, /), left to right", 10
                    db "                    calc 2 + 3          -> 5", 10
                    db "                    calc 100 / 3        -> 33", 10
                    db "                    calc 10 + 5 * 2     -> 30", 10
                    db "    source <file>   Execute commands from a file", 10
                    db "                    source setup.sh", 10
                    db "    help            This help message", 10
                    db "    exit [N]        Exit the terminal (with status N)", 10
                    db "    true / false    Set status 0 / 1", 10
                    db "    clear           Clear screen (same as cls)", 10
                    db "    which NAME      Show if NAME is a builtin, alias or program", 10
                    db "    history [-c]    List command history (-c clears it)", 10
                    db "    kill [-SIG] ID  Send a signal to a PID or %job", 10
                    db "    bench [-n N] CMD  Time CMD over N runs (mean/min/max, memory)", 10
                    db "                    bench -n 20 ls -la", 10
                    db "    undo            Reverse the last del, move/rename or copy", 10
                    db "    trash [empty]   List what del/move/copy keep, or empty it", 10
                    db "                    (kept in ~/.asm_trash; del/move/copy -f skip it)", 10
                    db "    trace [-a] CMD  Show programs, files and network used by CMD", 10
                    db "    sandbox [-w] [-n] [-b] CMD  Run CMD with no sockets (-n: IPv4/6", 10
                    db "                    only); file changes only in /tmp (-w: also here).", 10
                    db "                    Run 'sandbox' alone for what it does not block", 10
                    db 10
                    db "  CUSTOMIZATION", 10
                    db "  ---------------------------------------------------", 10
                    db "    alias <n>=<cmd> Create a command alias", 10
                    db "                    alias ll=ls -la", 10
                    db "                    alias gs=git status", 10
                    db "                    alias          list all aliases", 10
                    db "    unalias <name>  Remove an alias", 10
                    db "    theme [name]    Switch color theme", 10
                    db "                    theme           list themes", 10
                    db "                    theme default   bold colors", 10
                    db "                    theme minimal   no colors", 10
                    db "                    theme classic   original look", 10
                    db 10
                    db "  JOB CONTROL", 10
                    db "  ---------------------------------------------------", 10
                    db "    <cmd> &         Run command in background", 10
                    db "                    sleep 10 &", 10
                    db "    jobs            List background jobs", 10
                    db "    fg <n>          Bring job to foreground", 10
                    db "                    fg 1", 10
                    db "    bg <n>          Resume a stopped job in the background", 10
                    db "    Ctrl+Z          Stop the running command (then fg or bg)", 10
                    db 10
                    db "  SHELL FEATURES", 10
                    db "  ---------------------------------------------------", 10
                    db "    cmd1 ; cmd2     Run multiple commands", 10
                    db "                    echo hi ; echo bye", 10
                    db "    cmd1 && cmd2    Run next only if prev succeeded", 10
                    db "                    mkdir d && cd d", 10
                    db "    cmd1 || cmd2    Run next only if prev failed", 10
                    db "                    cd /x || echo no such dir", 10
                    db "    cmd > file      Redirect output to file", 10
                    db "                    ls > files.txt", 10
                    db "    cmd >> file     Append output to file", 10
                    db "                    echo log >> out.txt", 10
                    db "    cmd < file      Redirect input from file", 10
                    db "    cmd | cmd       Pipe (handled by /bin/sh)", 10
                    db "                    ls | grep .asm", 10
                    db "    $VAR            Expand environment variable", 10
                    db "                    echo $HOME", 10
                    db "    $? $$ $((1+2))  Last status, shell PID, arithmetic", 10
                    db "    NAME=value      Set a variable", 10
                    db 10
                    db "  SCRIPTING (ASH)", 10
                    db "  ---------------------------------------------------", 10
                    db "    if CMD; then ...; elif CMD; then ...; else ...; fi", 10
                    db "    while CMD; do ...; done     until CMD; do ...; done", 10
                    db "    for x in a b c; do echo $x; done", 10
                    db "    break / continue / ! CMD / { cmd1; cmd2; }", 10
                    db "    name() { echo $1 $#; return 0; }   define a function", 10
                    db "    test EXPR, [ EXPR ]  -f -d -e -z -n = != -eq -lt -gt ...", 10
                    db "                    i=0; while [ $i -lt 3 ]; do i=$((i+1)); done", 10
                    db "    Blocks can span lines; ASH shows '> ' until it is complete.", 10
                    db "    Tab             Filename completion", 10
                    db "    Up/Down         Browse command history", 10
                    db "    Ctrl+R          Reverse search history", 10
                    db "    Ctrl+L          Clear screen", 10
                    db "    Ctrl+W          Delete word backward", 10
                    db "    Ctrl+U          Clear line before cursor", 10
                    db "    Ctrl+C          Cancel current input", 10
                    db 10
                    db "  CONFIG: ~/.asmrc is executed on startup.", 10
                    db "  HISTORY: ~/.asm_history persists across sessions.", 10
                    db 10, 0
    help_len        equ $ - help_msg - 1

    ver_msg         db "ASM Terminal v", ASM_VERSION, " [x86-64 NASM/Linux] - developed by Umer Farooq Khan", 10, 0
    ver_len         equ $ - ver_msg - 1
    about_msg       db 10
                    db "  ASM Terminal v", ASM_VERSION, " with ASH (Assembly Shell)", 10
                    db "  A terminal shell written entirely in x86-64 assembly (NASM).", 10
                    db "  No libc, no runtime: raw Linux syscalls only.", 10
                    db 10
                    db "  Developed by: Umer Farooq Khan", 10
                    db "  GitHub:       https://github.com/Umar-Khan-Yousafzai", 10
                    db "  Source:       https://github.com/Umar-Khan-Yousafzai/asm-terminal", 10
                    db 10, 0
    about_len       equ $ - about_msg - 1
    err_cd_msg      db "Error: Could not change directory.", 10, 0
    err_cd_len      equ $ - err_cd_msg - 1
    err_exec_msg    db "Error: Could not execute command.", 10, 0
    err_exec_len    equ $ - err_exec_msg - 1
    err_file_msg    db "Error: Could not open file.", 10, 0
    err_file_len    equ $ - err_file_msg - 1
    err_copy_read_msg db "copy: read error from source.", 10, 0
    err_copy_read_len equ $ - err_copy_read_msg - 1
    err_copy_write_msg db "copy: write error to destination.", 10, 0
    err_copy_write_len equ $ - err_copy_write_msg - 1
    err_args_msg    db "Error: Missing arguments.", 10, 0
    err_args_len    equ $ - err_args_msg - 1
    err_stack_empty db "Error: Directory stack empty.", 10, 0
    err_stack_e_len equ $ - err_stack_empty - 1
    err_stack_full  db "Error: Directory stack full.", 10, 0
    err_stack_f_len equ $ - err_stack_full - 1
    err_alias_full  db "Error: Alias table full.", 10, 0
    err_alias_f_len equ $ - err_alias_full - 1
    err_no_prev_dir db "Error: No previous directory.", 10, 0
    err_no_prev_len equ $ - err_no_prev_dir - 1

    date_slash      db "/", 0
    time_colon      db ":", 0
    date_prefix     db "Date: ", 0
    date_prefix_len equ $ - date_prefix - 1
    time_prefix     db "Time: ", 0
    time_prefix_len equ $ - time_prefix - 1
    dir_header      db "  Directory of ", 0
    dir_tag         db "  <DIR>  ", 0
    str_dot         db ".", 0
    str_dotdot      db "..", 0
    str_equals      db "=", 0
    str_space       db " ", 0
    str_ctrlc       db "^C", 10, 0

    ; Command name strings
    cmd_s_help      db "help", 0
    cmd_s_cls       db "cls", 0
    cmd_s_exit      db "exit", 0
    cmd_s_ver       db "ver", 0
    cmd_s_about     db "about", 0
    cmd_s_update    db "update", 0
    cmd_s_date      db "date", 0
    cmd_s_time      db "time", 0
    cmd_s_pwd       db "pwd", 0
    cmd_s_whoami    db "whoami", 0
    cmd_s_popd      db "popd", 0
    cmd_s_echo      db "echo", 0
    cmd_s_title     db "title", 0
    cmd_s_color     db "color", 0
    cmd_s_cd        db "cd", 0
    cmd_s_dir       db "dir", 0
    cmd_s_type      db "type", 0
    cmd_s_mkdir     db "mkdir", 0
    cmd_s_rmdir     db "rmdir", 0
    cmd_s_del       db "del", 0
    cmd_s_copy      db "copy", 0
    cmd_s_move      db "move", 0
    cmd_s_rename    db "rename", 0
    cmd_s_set       db "set", 0
    cmd_s_pushd     db "pushd", 0
    cmd_s_alias     db "alias", 0
    cmd_s_unset     db "unset", 0
    cmd_s_export    db "export", 0
    cmd_s_unalias   db "unalias", 0

    err_set_pre     db "set: ", 0
    err_set_post    db ": not defined.", 10, 0
    err_unset_usage db "Usage: unset VAR", 10, 0
    err_unset_usage_len equ $ - err_unset_usage - 1
    err_unalias_usage db "Usage: unalias NAME", 10, 0
    err_unalias_usage_len equ $ - err_unalias_usage - 1
    err_unalias_notfound db "unalias: not found.", 10, 0
    err_unalias_notfound_len equ $ - err_unalias_notfound - 1

; ============================================================================
; Command dispatch tables
; ============================================================================

    ; Exact-match dispatch table: [name_ptr, handler_ptr] terminated by [0,0]
    cmd_table_exact:
        dq cmd_s_help,   handler_help
        dq cmd_s_cls,    handler_cls
        dq cmd_s_exit,   handler_exit
        dq cmd_s_ver,    handler_ver
        dq cmd_s_about,  handler_about
        dq cmd_s_update, handler_update
        dq bi_s_true,    handler_true
        dq bi_s_false,   handler_false
        dq bi_s_clear,   handler_cls
        dq bi_s_history, handler_history
        dq ash_s_test,   handler_test
        dq ash_s_lbracket, handler_bracket
        dq ash_s_colon,  handler_true
        dq tl_s_undo,    handler_undo
        dq cmd_s_date,   handler_date
        dq cmd_s_time,   handler_time
        dq cmd_s_pwd,    handler_pwd
        dq cmd_s_whoami, handler_whoami
        dq cmd_s_popd,   handler_popd
        dq cmd_s_uptime, handler_uptime
        dq cmd_s_free,   handler_free
        dq cmd_s_jobs,   handler_jobs
        dq 0, 0

    ; Prefix-match dispatch table: [name_ptr, handler_ptr, name_len]
    ; terminated by [0,0,0]
    cmd_table_prefix:
        dq cmd_s_echo,   handler_echo,   4
        dq cmd_s_title,  handler_title,  5
        dq cmd_s_color,  handler_color,  5
        dq cmd_s_cd,     handler_cd,     2
        dq cmd_s_dir,    handler_dir,    3
        dq cmd_s_type,   handler_type,   4
        dq cmd_s_mkdir,  handler_mkdir,  5
        dq cmd_s_rmdir,  handler_rmdir,  5
        dq cmd_s_del,    handler_del_safe, 3
        dq cmd_s_copy,   handler_copy_safe, 4
        dq cmd_s_move,   handler_move_safe, 4
        dq cmd_s_rename, handler_move_safe, 6
        dq cmd_s_set,    handler_set,    3
        dq cmd_s_pushd,  handler_pushd,  5
        dq cmd_s_alias,  handler_alias,  5
        dq cmd_s_source, handler_source, 6
        dq cmd_s_cat,    handler_type,   3
        dq cmd_s_update, handler_update, 6
        dq cmd_s_exit,   handler_exit_code, 4
        dq bi_s_which,   handler_which,  5
        dq bi_s_history, handler_history, 7
        dq bi_s_kill,    handler_kill,   4
        dq ash_s_test,   handler_test,   4
        dq ash_s_lbracket, handler_bracket, 1
        dq ash_s_colon,  handler_true,   1
        dq tl_s_bench,   handler_bench,  5
        dq tl_s_trashcmd, handler_trash, 5
        dq tr_s_trace,   handler_trace,  5
        dq sb_s_sandbox, handler_sandbox, 7
        dq cmd_s_ls,     handler_ls,     2
        dq cmd_s_grep,   handler_grep,   4
        dq cmd_s_calc,   handler_calc,   4
        dq cmd_s_theme,  handler_theme,  5
        dq cmd_s_fg,       handler_fg,       2
        dq cmd_s_bg,       handler_bg,       2
        dq cmd_s_unset,    handler_unset,    5
        dq cmd_s_export,   handler_set,      6
        dq cmd_s_unalias,  handler_unalias,  7
        dq 0, 0, 0

; ============================================================================
; Additional Linux-specific data
; ============================================================================

    ; Shell path for external command execution
    sh_path         db "/bin/sh", 0
    sh_dash_c       db "-c", 0

    ; Environment variable name for whoami
    str_user        db "USER", 0

    ; Months table (days per month, non-leap year) for date conversion
    months_table    db 31,28,31,30,31,30,31,31,30,31,30,31

    ; Errno messages for common errors
    errno_msg_perm  db "Permission denied", 10, 0
    errno_msg_noent db "No such file or directory", 10, 0
    errno_msg_exist db "File exists", 10, 0
    errno_msg_notdir db "Not a directory", 10, 0
    errno_msg_isdir db "Is a directory", 10, 0
    errno_msg_inval db "Invalid argument", 10, 0
    errno_msg_nospc db "No space left on device", 10, 0
    errno_msg_notempty db "Directory not empty", 10, 0
    errno_msg_generic db "Operation failed", 10, 0

    ; Errno number to message table: [errno_value, msg_ptr]
    errno_table:
        dd 1
        dq errno_msg_perm       ; EPERM
        dd 2
        dq errno_msg_noent      ; ENOENT
        dd 13
        dq errno_msg_perm       ; EACCES
        dd 17
        dq errno_msg_exist      ; EEXIST
        dd 20
        dq errno_msg_notdir     ; ENOTDIR
        dd 21
        dq errno_msg_isdir      ; EISDIR
        dd 22
        dq errno_msg_inval      ; EINVAL
        dd 28
        dq errno_msg_nospc      ; ENOSPC
        dd 39
        dq errno_msg_notempty   ; ENOTEMPTY
        dd 0                    ; terminator

    ; Autoexec file name
    autoexec_name   db "/autoexec.txt", 0

    ; Windows console color to ANSI color mapping table
    ; Maps Windows color index (0-7) to ANSI color index
    ; Windows: 0=Black,1=Blue,2=Green,3=Cyan,4=Red,5=Purple,6=Yellow,7=White
    ; ANSI:    0=Black,1=Red,2=Green,3=Yellow,4=Blue,5=Magenta,6=Cyan,7=White
    win_to_ansi     db 0,4,2,6,1,5,3,7

    ; ======== Batch 2 Data ========

    ; --- Source command ---
    cmd_s_source    db "source", 0
    err_source_msg  db "Error: source: missing filename.", 10, 0
    err_source_len  equ $ - err_source_msg - 1
    err_source_open db "Error: source: could not open file.", 10, 0
    err_source_o_len equ $ - err_source_open - 1
    err_source_depth_msg db "Error: source: recursion depth exceeded.", 10, 0
    err_source_depth_len equ $ - err_source_depth_msg - 1

    ; --- Timezone env var name ---
    tz_env_name_str db "ASM_TZ", 0

    ; --- Color / TTY detection env var names ---
    str_no_color    db "NO_COLOR", 0
    str_term        db "TERM", 0
    str_term_dumb   db "dumb", 0
    str_term_linux  db "linux", 0

    ; --- OSC 7 (cwd notification) prefix + terminator ---
    osc7_prefix     db 27, "]7;file://", 0
    osc7_prefix_len equ $ - osc7_prefix - 1
    osc7_bel        db 7, 0

    ; --- OSC 133 shell integration markers ---
    osc133_a        db 27, "]133;A", 7, 0       ; prompt start
    osc133_b        db 27, "]133;B", 7, 0       ; command start
    osc133_c        db 27, "]133;C", 7, 0       ; output start
    osc133_d_pre    db 27, "]133;D;", 0         ; end prefix
    osc133_bel      db 7, 0

    ; --- Bracketed paste mode enable/disable sequences ---
    bracketed_paste_on  db 27, "[?2004h"
    bracketed_paste_on_len equ $ - bracketed_paste_on
    bracketed_paste_off db 27, "[?2004l"
    bracketed_paste_off_len equ $ - bracketed_paste_off

    ; --- Cursor shape reset (DECSCUSR 0) + show cursor (DECSET 25) ---
    cursor_shape_reset    db 27, "[0 q"
    cursor_shape_reset_len equ $ - cursor_shape_reset
    cursor_show           db 27, "[?25h"
    cursor_show_len       equ $ - cursor_show

    ; --- Git branch detection (direct .git/HEAD read, no fork) ---
    str_git_head    db "/.git/HEAD", 0
    str_ref_prefix  db "ref: refs/heads/", 0

    ; --- Prompt exit-status indicator: ' [N]' in red ---
    exit_prompt_pre  db 27, "[31m [", 0
    exit_prompt_post db "]", 27, "[0m", 0

    ; --- Compound command error ---
    err_compound_msg db "Error: command failed, aborting &&-chain.", 10, 0
    err_compound_len equ $ - err_compound_msg - 1

    ; --- Reverse history search prompt ---
    search_prompt       db "(reverse-i-search)`", 0
    search_prompt_len   equ $ - search_prompt - 1
    search_prompt_end   db "': ", 0
    search_prompt_e_len equ $ - search_prompt_end - 1
    search_fail_msg     db "(no match)", 0
    search_fail_len     equ $ - search_fail_msg - 1

    ; ======== Batch 3 Data ========

    ; ---------- Command name strings ----------
    cmd_s_cat       db "cat", 0
    cmd_s_ls        db "ls", 0
    cmd_s_grep      db "grep", 0
    cmd_s_uptime    db "uptime", 0
    cmd_s_free      db "free", 0
    cmd_s_calc      db "calc", 0

    ; ---------- ANSI color escapes for ls ----------
    ansi_blue       db 27, "[34m", 0
    ansi_blue_len   equ $ - ansi_blue - 1
    ansi_green_ls   db 27, "[32m", 0
    ansi_green_ls_len equ $ - ansi_green_ls - 1
    ansi_red_hi     db 27, "[1;31m", 0           ; bold red for grep highlight
    ansi_red_hi_len equ $ - ansi_red_hi - 1

    ; ---------- /proc paths ----------
    proc_uptime     db "/proc/uptime", 0
    proc_meminfo    db "/proc/meminfo", 0

    ; ---------- Miscellaneous strings ----------
    str_up          db "up ", 0
    str_days        db " days, ", 0
    str_day         db " day, ", 0
    str_two_spaces  db "  ", 0
    str_colon_sp    db ": ", 0
    str_dash        db "-", 0
    ls_perm_dir     db "drwxr-xr-x", 0      ; simplified directory permissions
    ls_perm_file    db "-rw-r--r--", 0       ; simplified file permissions
    ls_perm_exec    db "-rwxr-xr-x", 0       ; simplified executable permissions
    err_grep_usage  db "Usage: grep <pattern> <filename>", 10, 0
    err_grep_usage_len equ $ - err_grep_usage - 1
    err_calc_usage  db "Usage: calc <expr>  (+ - * /, evaluated left to right)", 10, 0
    err_calc_usage_len equ $ - err_calc_usage - 1
    err_div_zero    db "Error: Division by zero.", 10, 0
    err_div_zero_len equ $ - err_div_zero - 1
    err_overflow    db "Error: Integer overflow.", 10, 0
    err_overflow_len equ $ - err_overflow - 1

    ; Permission mode bits for executable check
    %define S_IXUSR  0o100
    %define S_IXGRP  0o010
    %define S_IXOTH  0o001
    %define S_IWGRP  0o020
    %define S_IWOTH  0o002
    %define S_IFMT   0o170000
    %define S_IFLNK  0o120000
    %define S_IFREG  0o100000
    %define S_IFBLK  0o060000
    %define S_IFCHR  0o020000
    %define S_IFIFO  0o010000
    %define S_IFSOCK 0o140000

    ; ======== Batch 4 Data ========

    ; ---------- ANSI bold color codes for new prompt ----------
    ansi_bold_green  db 27, "[1;32m", 0       ; bold green (user@host)
    ansi_bold_green_len equ $ - ansi_bold_green - 1
    ansi_bold_blue   db 27, "[1;34m", 0       ; bold blue (path)
    ansi_bold_blue_len equ $ - ansi_bold_blue - 1
    ansi_red         db 27, "[31m", 0         ; red (invalid command highlight)
    ansi_red_len     equ $ - ansi_red - 1

    ; ---------- Prompt structural strings ----------
    str_at           db "@", 0
    str_colon        db ":", 0
    str_dollar_space db "$ ", 0
    str_gt_space     db "> ", 0
    str_unknown_user db "user", 0
    str_unknown_host db "localhost", 0
    str_ampersand    db "&", 0

    ; ---------- Theme command strings ----------
    cmd_s_theme      db "theme", 0
    cmd_s_jobs       db "jobs", 0
    cmd_s_fg         db "fg", 0
    cmd_s_bg         db "bg", 0

    bg_resumed_msg   db "[bg] resumed job ", 0
    bg_noarg_msg     db "Usage: bg JOBNUM", 10, 0
    bg_noarg_len     equ $ - bg_noarg_msg - 1

    ; Theme name strings
    theme_name_default  db "default", 0
    theme_name_minimal  db "minimal", 0
    theme_name_classic  db "classic", 0

    ; Theme help / listing text
    theme_list_msg      db 10
                        db "  Available themes:", 10
                        db "    default  - bold green user, bold blue path, $ prompt", 10
                        db "    minimal  - no colors, $ prompt", 10
                        db "    classic  - green path, > prompt (original look)", 10
                        db 10, 0
    theme_list_msg_len  equ $ - theme_list_msg - 1

    theme_set_msg       db "Theme set to: ", 0
    theme_unknown_msg   db "Unknown theme. Type 'theme' for available themes.", 10, 0

    ; Job control messages
    jobs_header_msg     db "  Active background jobs:", 10, 0
    jobs_none_msg       db "  No active background jobs.", 10, 0
    jobs_bracket_open   db "  [", 0
    jobs_bracket_close  db "] ", 0
    jobs_pid_label      db "PID ", 0
    jobs_running_msg    db " Running  ", 0
    jobs_done_msg       db " Done     ", 0
    jobs_fg_noarg_msg   db "Usage: fg <job_number>", 10, 0
    jobs_fg_invalid_msg db "No such job.", 10, 0
    jobs_bg_started_msg db "[bg] PID ", 0
    jobs_full_msg       db "Job table full, running in foreground.", 10, 0

    ; ---------- Theme data tables ----------
    ; Theme 0: "default" - bold green user, bold blue path, "$ "
    theme_table:
    theme_0:
        dq ansi_bold_green,  ansi_bold_green_len   ; user color
        dq ansi_bold_blue,   ansi_bold_blue_len    ; path color
        dq ansi_default,     ansi_default_len      ; reset
        dq str_dollar_space, 2                     ; symbol
    ; Theme 1: "minimal" - no colors, "$ "
    theme_1:
        dq ansi_default,     ansi_default_len      ; user color (none)
        dq ansi_default,     ansi_default_len      ; path color (none)
        dq ansi_default,     ansi_default_len      ; reset
        dq str_dollar_space, 2                     ; symbol
    ; Theme 2: "classic" - green path only, "> " (original look)
    theme_2:
        dq ansi_default,     ansi_default_len      ; user color (not used)
        dq ansi_green,       ansi_green_len        ; path color
        dq ansi_default,     ansi_default_len      ; reset
        dq str_gt_space,     2                     ; symbol

    THEME_ENTRY_SIZE equ 64     ; 8 qwords * 8 bytes
    THEME_COUNT      equ 3

    ; Theme name table (ptrs for name lookup)
    theme_names:
        dq theme_name_default   ; index 0
        dq theme_name_minimal   ; index 1
        dq theme_name_classic   ; index 2

    ; History and config file names
    str_asm_history db "/.asm_history", 0
    str_asmrc       db "/.asmrc", 0
    str_home        db "HOME", 0

    ; Day-of-week name table (4 bytes each: 3 chars + null)
    dow_names       db "Sun", 0, "Mon", 0, "Tue", 0, "Wed", 0
                    db "Thu", 0, "Fri", 0, "Sat", 0

    ; Month name table (4 bytes each: 3 chars + null)
    month_names     db "Jan", 0, "Feb", 0, "Mar", 0, "Apr", 0
                    db "May", 0, "Jun", 0, "Jul", 0, "Aug", 0
                    db "Sep", 0, "Oct", 0, "Nov", 0, "Dec", 0

    ; Timezone and AM/PM strings
    str_am          db "AM", 0
    str_pm          db "PM", 0

; ============================================================================
; BSS Section - Uninitialized data buffers
; ============================================================================
section .bss

    ; Terminal state
    orig_termios        resb 60     ; saved original terminal settings
    raw_termios         resb 60     ; modified raw mode terminal settings

    ; Environment pointer from kernel stack
    saved_envp          resq 1

    ; Signal handling
    sigaction_buf       resb 32     ; struct sigaction for rt_sigaction
    ctrl_c_flag         resb 1

    ; Key input
    key_buf             resb 8      ; buffer for reading key sequences
    key_vkey            resw 1      ; virtual key code from read_key
    key_char            resb 1      ; ASCII character from read_key

    ; Line editing buffers
    input_buf           resb MAX_INPUT
    line_buf            resb MAX_INPUT
    line_len            resd 1
    line_cursor         resd 1

    ; Path and general buffers
    path_buf            resb MAX_PATH_BUF
    cmd_line_buf        resb 1024
    num_buf             resb 32            ; up to 20 digits for 64-bit + padding
    file_path_buf       resb MAX_PATH_BUF
    read_buffer         resb READ_BUF_SIZE
    history_read_buf    resb 262144         ; 256KB for full history file load

    ; Directory listing
    dirent_buf          resb 8192   ; buffer for getdents64
    find_pattern        resb MAX_PATH_BUF

    ; File stat
    stat_buf            resb 144    ; struct stat

    ; Exec support
    exec_argv           resq 4      ; argv array for execve

    ; Prompt length tracking (for cursor positioning)
    prompt_total_len    resd 1

    ; Time support
    timespec_buf        resb 16     ; struct timespec (tv_sec + tv_nsec)

    ; ANSI sequence building buffer
    ansi_num_buf        resb 16

    ; Environment overlay (for set command, since we can't modify real env easily)
    env_overlay         resb ENV_OVERLAY_COUNT * ENV_OVERLAY_SIZE ; NAME=VALUE slots
    env_overlay_count   resd 1

    ; Terminal window size
    winsize_buf         resb 8      ; struct winsize

    ; Date/time parsed fields
    date_year           resd 1
    date_month          resd 1
    date_day            resd 1
    time_hour           resd 1
    time_minute         resd 1
    time_second         resd 1
    time_seconds        resd 1

    ; Process ID buffer
    pid_buf             resd 1

    ; History
    history_buf         resb HISTORY_COUNT * HISTORY_ENTRY_SIZE
    history_write_idx   resd 1
    history_count       resd 1
    history_nav_idx     resd 1
    history_saved       resb MAX_INPUT
    history_browsing    resb 1

    ; Tab completion
    tab_active          resb 1
    ls_perms_buf        resb 16            ; rendered "drwxr-xr-x" + NUL
    interactive_mode    resb 1             ; 1 = stdin & stdout are tty
    color_enabled       resb 1             ; 1 = ANSI/color permitted
    termios_probe_buf   resb 60             ; scratch for ioctl probe
    winch_pending       resb 1             ; set by SIGWINCH handler
    term_rows           resw 1             ; cached from TIOCGWINSZ
    term_cols           resw 1             ; cached from TIOCGWINSZ
    winch_sigaction_buf resb 32            ; sigaction struct for SIGWINCH
    merged_envp         resq MERGED_ENVP_MAX ; argv-style envp for child
    merged_envp_count   resd 1
    git_scratch_path    resb 4096          ; for walking up looking for .git
    git_head_buf        resb 512           ; contents of .git/HEAD
    git_branch          resb 128           ; extracted branch name (or NUL)
    kill_buf            resb 512           ; Ctrl+K kill target / Ctrl+Y source
    tab_base_pos        resd 1      ; position in line_buf where completion starts
    tab_name_prefix     resb MAX_PATH_BUF  ; name part to match
    tab_name_prefix_len resd 1      ; length of name prefix

    ; Environment expansion
    env_expand_buf      resb 1024
    env_var_name        resb 256
    env_var_value       resb 1024

    ; Redirection state (using fds instead of handles)
    redir_stdout_fd     resd 1
    redir_stdin_fd      resd 1
    redir_stdout_active resb 1
    redir_stdin_active  resb 1
    redir_append        resb 1
    redir_filename      resb MAX_PATH_BUF
    cleaned_cmd_buf     resb MAX_INPUT

    ; Alias table
    alias_table         resb ALIAS_COUNT * ALIAS_ENTRY_SIZE
    alias_count         resd 1

    ; Directory stack
    dir_stack           resb DIR_STACK_COUNT * MAX_PATH_BUF
    dir_stack_top       resd 1

    ; Previous directory for cd -
    prev_dir_buf        resb MAX_PATH_BUF
    has_prev_dir        resb 1

    ; Error message buffer
    err_msg_buf         resb 512

    ; Bytes read/written scratch
    bytes_rw            resd 1

    ; Autoexec/module path
    autoexec_path       resb MAX_PATH_BUF
    module_path         resb MAX_PATH_BUF

    ; Chars written scratch (for compatibility)
    chars_written       resd 1

    ; Persistent history file path
    history_file_path   resb MAX_PATH_BUF

    ; .asmrc config file path
    asmrc_path          resb MAX_PATH_BUF

    ; Day-of-week (0=Sun..6=Sat)
    date_dow            resd 1

    ; ======== Batch 2 BSS ========

    ; --- Compound command execution ---
    last_exit_status    resd 1      ; 0 = success, nonzero = failure

    ; --- Source command ---
    source_read_buf     resb READ_BUF_SIZE  ; dedicated buffer for source
    source_depth        resd 1              ; recursion depth counter

    ; --- Reverse history search ---
    search_buf          resb 256    ; characters typed during search
    search_len          resd 1      ; length of search string
    search_match_idx    resd 1      ; index into history_buf of current match
    search_match_found  resb 1      ; 1 if a match was found

    ; ======== Batch 3 BSS ========

    ; grep line buffer (holds one line extracted from file)
    grep_line_buf    resb 65536
    ; ls flag state
    ls_flags         resb 1          ; bit 0 = -l, bit 1 = -a
    ; calc accumulator (signed 64-bit)
    calc_accum       resq 1

    ; ======== Batch 4 BSS ========

    ; Cached prompt components (filled once at startup)
    cached_username     resb 64
    cached_hostname     resb 64
    uname_buf           resb 390        ; struct utsname (6 fields * 65 bytes)

    ; Theme state
    current_theme       resd 1          ; 0=default, 1=minimal, 2=classic

    ; Job control table
    %define JOB_MAX       8
    %define JOB_CMD_SIZE  128
    job_pids            resq JOB_MAX            ; PIDs of background jobs
    job_count           resd 1                  ; number of active slots used
    job_cmds            resb JOB_MAX * JOB_CMD_SIZE  ; command strings

; ============================================================================
; Code Section
; ============================================================================
section .text
    global _start

; ============================================================================
; _start - ELF entry point
; Parse kernel stack for argc, argv, envp. Save envp, align stack, call main.
; Linux kernel places on stack: [argc] [argv0] [argv1] ... [NULL] [envp0] ...
; ============================================================================
_start:
    ; On entry, rsp points to argc
    ; [rsp]     = argc (qword)
    ; [rsp+8]   = argv[0]
    ; ...
    ; [rsp+8+argc*8] = NULL
    ; [rsp+8+(argc+1)*8] = envp[0]
    ; ...

    ; Load argc
    mov rdi, [rsp]          ; argc
    lea rsi, [rsp + 8]      ; argv

    ; Calculate envp = argv + (argc + 1) * 8
    mov rax, rdi
    inc rax                 ; argc + 1 (skip NULL terminator)
    lea rdx, [rsi + rax*8]  ; envp
    mov [saved_envp], rdx

    ; Align stack to 16 bytes (required by System V ABI)
    and rsp, -16

    ; Call main
    call main

    ; Exit with return code from main (eax)
    mov edi, eax
    mov eax, SYS_EXIT
    syscall

; ============================================================================
; main - Initialize terminal and run command loop
; Sets up raw mode, signal handler, prints welcome, runs autoexec,
; then enters the main read-eval-print loop.
; ============================================================================
main:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 32

    ; Detect whether we are running interactively + whether color is allowed
    call init_io_modes

    ; Only put the terminal in raw mode if we own the tty
    cmp byte [interactive_mode], 0
    je .main_skip_raw
    call setup_raw_mode
.main_skip_raw:

    ; Install SIGINT handler
    call setup_sigint
    call setup_sigwinch
    call setup_term_signals

    ; Initialize state variables
    mov byte [has_prev_dir], 0
    mov dword [dir_stack_top], 0
    mov dword [alias_count], 0
    mov dword [history_count], 0
    mov dword [history_write_idx], 0
    mov byte [ctrl_c_flag], 0
    mov byte [redir_stdout_active], 0
    mov byte [redir_stdin_active], 0
    mov byte [tab_active], 0
    mov dword [env_overlay_count], 0
    mov dword [job_count], 0        ; autoexec/.asmrc may start jobs or set a
    mov dword [current_theme], 0    ; theme; init_prompt_cache must not undo that

    ; Print welcome banner
    lea rdi, [welcome_msg]
    mov esi, welcome_len
    call print_string_len

    ; Run autoexec.txt if present
    call run_autoexec

    ; Load persistent history from ~/.asm_history
    call load_history

    ; Run ~/.asmrc config if present
    call run_asmrc

    ; Flag a newer release (cached), refresh the cache in the background.
    ; After ~/.asmrc so that "set ASM_NO_UPDATE_CHECK=1" there is honoured.
    call update_startup

    ; Cache username and hostname for prompt
    call init_prompt_cache

.main_loop:
    ; --- Reap any finished background jobs ---
    call reap_finished_jobs

    ; --- Refresh terminal size if a SIGWINCH was observed ---
    cmp byte [winch_pending], 0
    je .main_no_winch
    mov byte [winch_pending], 0
    call update_term_size
.main_no_winch:

    cmp byte [interactive_mode], 0
    je .main_noninteractive

    ; --- Print themed prompt ---
    call print_prompt

    ; Read a line with full editing support
    call read_line
    jmp .main_after_read

.main_noninteractive:
    ; Non-interactive: no prompt, no syntax highlight, just read a raw line
    call read_line_plain
    test rax, rax
    jz .main_eof                    ; EOF -> exit

.main_after_read:
    ; Skip empty lines, except inside an open quote or block where the
    ; blank line is part of the text
    cmp byte [input_buf], 0
    jne .main_nonempty
    cmp byte [ash_cont], 0
    je .main_loop
    jmp .main_run

.main_nonempty:
    ; Add to history; only a person typing at the terminal feeds the file
    lea rdi, [input_buf]
    call history_add
    cmp byte [interactive_mode], 0
    je .main_no_save
    lea rdi, [input_buf]
    call history_save_entry
.main_no_save:

.main_run:
    ; OSC 133 C — output region begins (only for a terminal that asked for
    ; shell integration; a pipe must see the command output and nothing else)
    cmp byte [osc_enabled], 0
    je .main_no_osc_c
    lea rdi, [osc133_c]
    call print_cstring
.main_no_osc_c:

    ; Run it through the ASH script engine (; && || if while for ...).
    ; An open block waits for more lines behind a "> " prompt. Ctrl+C raises
    ; SIGINT while it runs, so even a loop of builtins can be stopped.
    call script_isig_on
    call ash_feed_line
    call script_isig_off

    ; OSC 133 D;<exit_status> — end of command + exit code
    cmp byte [osc_enabled], 0
    je .main_loop
    lea rdi, [osc133_d_pre]
    call print_cstring
    mov eax, [last_exit_status]
    call print_number
    lea rdi, [osc133_bel]
    call print_cstring

    jmp .main_loop

.main_eof:
    call ash_feed_eof               ; run or report an unfinished block
    mov edi, [last_exit_status]
    mov eax, SYS_EXIT
    syscall

section .bss
    osc_enabled         resb 1      ; 1 = OSC 7 / OSC 133 marks may be sent
section .text
; ============================================================================
; init_io_modes - Resolve interactive_mode and color_enabled flags
; interactive = ioctl(0, TCGETS) succeeds  AND  ioctl(1, TCGETS) succeeds
; color = interactive  AND  !$NO_COLOR  AND  $TERM != "dumb"
; ============================================================================
init_io_modes:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 8

    ; Default: not interactive, no color
    mov byte [interactive_mode], 0
    mov byte [color_enabled], 0

    ; ioctl(STDIN, TCGETS, &termios_probe_buf)
    mov eax, SYS_IOCTL
    mov edi, STDIN_FD
    mov esi, TCGETS
    lea rdx, [termios_probe_buf]
    syscall
    test rax, rax
    js .iom_done                    ; stdin not a tty

    ; ioctl(STDOUT, TCGETS, &termios_probe_buf)
    mov eax, SYS_IOCTL
    mov edi, 1
    mov esi, TCGETS
    lea rdx, [termios_probe_buf]
    syscall
    test rax, rax
    js .iom_done                    ; stdout not a tty

    mov byte [interactive_mode], 1
    mov byte [osc_enabled], 1

    ; Start assuming color is ok; TERM=dumb takes colors and the OSC
    ; shell-integration marks away, NO_COLOR only the colors
    mov byte [color_enabled], 1

    lea rdi, [str_term]
    call getenv_internal
    test rax, rax
    jz .iom_check_nocolor
    mov rbx, rax
    lea rsi, [str_term_dumb]
    mov rdi, rbx
    call str_icompare
    test eax, eax
    jnz .iom_not_dumb
    mov byte [color_enabled], 0
    mov byte [osc_enabled], 0
    jmp .iom_done

.iom_not_dumb:
    ; The Linux console has no 24-bit color: highlighting uses 16-color codes
    lea rsi, [str_term_linux]
    mov rdi, rbx
    call str_icompare
    test eax, eax
    jnz .iom_check_nocolor
    mov byte [hl_basic], 1

.iom_check_nocolor:
    lea rdi, [str_no_color]
    call getenv_internal
    test rax, rax
    jz .iom_done
    ; NO_COLOR must be non-empty per no-color.org spec
    cmp byte [rax], 0
    je .iom_done
    mov byte [color_enabled], 0

.iom_done:
    add rsp, 8
    pop rbx
    pop rbp
    ret

; ============================================================================
; read_line_plain - Read one line (terminated by LF or EOF) into input_buf
; Used when interactive_mode = 0. Returns rax = 1 if a line was read,
; rax = 0 on EOF with no bytes.
; Input is read one byte at a time on purpose: a command that runs from the
; script (cat, head, read) must find the lines after its own still unread on
; stdin. A line longer than the buffer is not run in pieces: the rest of it is
; read and dropped, an error goes to stderr and an empty line is returned
; (main skips it).
; ============================================================================
section .data
    rlp_msg_long        db "ash: line too long (limit 511 bytes), ignored", 10
    rlp_msg_long_len    equ $ - rlp_msg_long
section .text
read_line_plain:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 8

    lea rbx, [input_buf]
    xor r12d, r12d                   ; r12 = length so far
    xor r13d, r13d                   ; r13 = 1 once the line is over the limit

.rlp_next:
    mov eax, SYS_READ
    xor edi, edi
    lea rsi, [key_buf]
    mov edx, 1
    syscall
    cmp rax, -4                      ; EINTR: read again
    je .rlp_next
    test rax, rax
    jle .rlp_eof
    movzx edx, byte [key_buf]
    cmp dl, 10                       ; LF ends the line
    je .rlp_terminate
    cmp dl, 13                       ; drop CR (CRLF line endings)
    je .rlp_next
    test r13d, r13d
    jnz .rlp_next                    ; over the limit: keep dropping
    cmp r12d, MAX_INPUT - 1
    jae .rlp_over
    mov [rbx + r12], dl
    inc r12d
    jmp .rlp_next
.rlp_over:
    mov r13d, 1
    jmp .rlp_next

.rlp_terminate:
    test r13d, r13d
    jnz .rlp_toolong
    mov byte [rbx + r12], 0
    mov eax, 1
    jmp .rlp_done

.rlp_toolong:
    mov eax, SYS_WRITE
    mov edi, STDERR_FD
    lea rsi, [rlp_msg_long]
    mov edx, rlp_msg_long_len
    syscall
    mov dword [last_exit_status], 1
    mov byte [rbx], 0
    mov eax, 1
    jmp .rlp_done

.rlp_eof:
    test r13d, r13d
    jnz .rlp_toolong                ; the overlong line was the last one
    test r12d, r12d
    jnz .rlp_terminate              ; flush pending bytes
    mov byte [rbx], 0
    xor eax, eax

.rlp_done:
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; setup_raw_mode - Switch terminal to raw mode
; Uses ioctl TCGETS to save the startup settings (once), then clears ICANON,
; ECHO and ISIG in a copy, sets VMIN=1, VTIME=0 and applies it with TCSETS.
; Does nothing unless we own the tty (interactive_mode).
; ============================================================================
section .bss
    termios_saved       resb 1      ; orig_termios holds the startup tty state
    raw_active          resb 1      ; the tty is in our raw mode right now
section .text
setup_raw_mode:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    ; A script on a pipe, or stdout redirected: the tty is not ours to touch
    cmp byte [interactive_mode], 0
    je .srm_ret

    ; Remember the startup settings once. Later calls come after a child ran
    ; and must not mistake whatever it left behind (stty -echo, a crashed
    ; full-screen program) for the state to restore at exit.
    cmp byte [termios_saved], 0
    jne .srm_have_orig
    mov eax, SYS_IOCTL
    mov edi, STDIN_FD
    mov esi, TCGETS
    lea rdx, [orig_termios]
    syscall
    test rax, rax
    js .srm_ret                     ; cannot read the tty: leave it alone
    mov byte [termios_saved], 1
.srm_have_orig:

    ; Copy orig_termios to raw_termios
    lea rsi, [orig_termios]
    lea rdi, [raw_termios]
    mov ecx, 60
.copy_termios:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jnz .copy_termios

    ; Clear ICANON, ECHO, and ISIG in c_lflag (offset 12 in termios)
    ; Clearing ISIG prevents Ctrl+Z (SIGTSTP) from suspending the shell
    ; and Ctrl+C (SIGINT) from being handled at kernel level — we handle
    ; Ctrl+C in software via read_key, and Ctrl+Z is now consumed as a
    ; regular keystroke (no-op) to avoid dropping the shell into the
    ; background.
    lea rax, [raw_termios]
    mov edx, [rax + TERMIOS_C_LFLAG]
    and edx, ~(ICANON | ECHO_FLAG | ISIG)  ; clear ICANON, ECHO, ISIG
    mov [rax + TERMIOS_C_LFLAG], edx

    ; Set VMIN=1 (minimum 1 char for read), VTIME=0 (no timeout)
    ; c_cc is at offset 17, VMIN = c_cc[6], VTIME = c_cc[5]
    mov byte [rax + TERMIOS_C_CC + VMIN_INDEX], 1
    mov byte [rax + TERMIOS_C_CC + VTIME_INDEX], 0

    ; ioctl(STDIN_FD, TCSETS, &raw_termios)  - apply raw settings
    mov eax, SYS_IOCTL
    mov edi, STDIN_FD
    mov esi, TCSETS
    lea rdx, [raw_termios]
    syscall
    mov byte [raw_active], 1

    ; Enable bracketed paste mode so pasted content is wrapped in
    ; ESC[200~ ... ESC[201~ markers we can consume in read_key.
    lea rdi, [bracketed_paste_on]
    mov esi, bracketed_paste_on_len
    call term_write

    cmp byte [script_running], 0    ; a command line is running: Ctrl+C stays live
    je .srm_ret
    call script_isig_apply
.srm_ret:
    leave
    ret

; ============================================================================
; term_write - write straight to the terminal (fd 1), never to a redirect
; target: mode switches and cursor resets belong to the screen, not to the
; file of an "extcmd > file".
; rdi = buffer, esi = length. Clobbers rax, rcx, rdx, rsi, rdi, r11.
; ============================================================================
term_write:
    mov edx, esi
    mov rsi, rdi
    mov edi, 1
    mov eax, SYS_WRITE
    syscall
    ret

; ============================================================================
; restore_terminal - Put the tty back the way we found it
; Called before a child runs and before exit. Does nothing unless
; setup_raw_mode switched the tty (so it is safe to call twice, from a
; signal handler, or when stdin is a tty but stdout is not).
; ============================================================================
restore_terminal:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    cmp byte [raw_active], 0
    je .rt_ret
    mov byte [raw_active], 0

    ; Disable bracketed paste mode before restoring termios
    lea rdi, [bracketed_paste_off]
    mov esi, bracketed_paste_off_len
    call term_write

    ; Restore cursor shape + make sure cursor visible (TUI children may have changed)
    lea rdi, [cursor_shape_reset]
    mov esi, cursor_shape_reset_len
    call term_write
    lea rdi, [cursor_show]
    mov esi, cursor_show_len
    call term_write

    ; ioctl(STDIN_FD, TCSETS, &orig_termios)
    mov eax, SYS_IOCTL
    mov edi, STDIN_FD
    mov esi, TCSETS
    lea rdx, [orig_termios]
    syscall

.rt_ret:
    leave
    ret

; ============================================================================
; setup_sigint - Install a signal handler for SIGINT (Ctrl+C)
; Uses rt_sigaction syscall with SA_RESTORER and SA_RESTART flags.
; The handler sets ctrl_c_flag instead of terminating the process.
; ============================================================================
setup_sigint:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    ; Fill sigaction_buf:
    ;   offset 0:  sa_handler  (8 bytes) = sigint_handler
    ;   offset 8:  sa_flags    (8 bytes) = SA_RESTORER | SA_RESTART
    ;   offset 16: sa_restorer (8 bytes) = sig_restorer
    ;   offset 24: sa_mask     (8 bytes) = 0 (empty mask)
    lea rax, [sigaction_buf]
    lea rcx, [sigint_handler]
    mov [rax], rcx                                  ; sa_handler
    mov qword [rax + 8], SA_RESTORER | SA_RESTART   ; sa_flags
    lea rcx, [sig_restorer]
    mov [rax + 16], rcx                             ; sa_restorer
    mov qword [rax + 24], 0                         ; sa_mask (empty)

    ; rt_sigaction(SIGINT, &sigaction_buf, NULL, sigsetsize=8)
    mov eax, SYS_RT_SIGACTION
    mov edi, SIGINT
    lea rsi, [sigaction_buf]
    xor edx, edx               ; old_act = NULL
    mov r10d, 8                 ; sigsetsize = 8
    syscall

    leave
    ret

; ============================================================================
; sigint_handler - SIGINT signal handler
; Sets the ctrl_c_flag so the main loop can detect Ctrl+C gracefully.
; ============================================================================
sigint_handler:
    mov byte [ctrl_c_flag], 1
    ret

; ============================================================================
; setup_term_signals - leave the tty usable when the shell is killed
; SIGHUP, SIGQUIT, SIGTERM and the crash signals get a handler that puts the
; terminal back (restore_terminal), then dies of the same signal. The crash
; signals run on their own stack so a stack overflow can still be reported.
; ============================================================================
section .data
term_sig_list   db SIGHUP, 3, 4, 7, 8, 11, SIGTERM, 0   ; HUP QUIT ILL BUS FPE SEGV TERM
section .bss
    term_sigaction_buf  resb 32
    term_altstack_desc  resb 24         ; stack_t: sp, flags, size
    term_altstack       resb 16384
section .text
setup_term_signals:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 8

    ; sigaltstack(&desc, NULL)
    lea rax, [term_altstack_desc]
    lea rcx, [term_altstack]
    mov [rax], rcx                  ; ss_sp
    mov qword [rax + 8], 0          ; ss_flags
    mov qword [rax + 16], 16384     ; ss_size
    mov eax, 131                    ; SYS_sigaltstack
    lea rdi, [term_altstack_desc]
    xor esi, esi
    syscall

    ; One-shot handler (SA_RESETHAND) on the alternate stack (SA_ONSTACK)
    lea rax, [term_sigaction_buf]
    lea rcx, [term_signal_handler]
    mov [rax], rcx                  ; sa_handler
    mov ecx, SA_RESTORER | 0x80000000 | 0x08000000
    mov [rax + 8], rcx              ; sa_flags
    lea rcx, [sig_restorer]
    mov [rax + 16], rcx             ; sa_restorer
    mov qword [rax + 24], 0         ; sa_mask

    lea rbx, [term_sig_list]
.sts_loop:
    movzx edi, byte [rbx]
    test edi, edi
    jz .sts_done
    mov eax, SYS_RT_SIGACTION
    lea rsi, [term_sigaction_buf]
    xor edx, edx
    mov r10d, 8
    syscall
    inc rbx
    jmp .sts_loop
.sts_done:
    add rsp, 8
    pop rbx
    pop rbp
    ret

; term_signal_handler - rdi = signal number
term_signal_handler:
    push rdi                        ; keeps the stack aligned for the call
    call restore_terminal
    mov eax, 39                     ; SYS_getpid
    syscall
    mov edi, eax
    mov rsi, [rsp]                  ; signal number
    mov eax, SYS_KILL
    syscall                         ; delivered when this handler returns
    pop rdi
    ret

; ============================================================================
; setup_sigwinch - install SIGWINCH handler so terminal resize is observable
; ============================================================================
setup_sigwinch:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    lea rax, [winch_sigaction_buf]
    lea rcx, [sigwinch_handler]
    mov [rax], rcx
    mov qword [rax + 8], SA_RESTORER | SA_RESTART
    lea rcx, [sig_restorer]
    mov [rax + 16], rcx
    mov qword [rax + 24], 0

    mov eax, SYS_RT_SIGACTION
    mov edi, 28                     ; SIGWINCH
    lea rsi, [winch_sigaction_buf]
    xor edx, edx
    mov r10d, 8
    syscall

    ; Prime the rows/cols cache
    call update_term_size

    leave
    ret

; ============================================================================
; sigwinch_handler - signal handler for SIGWINCH; defers work to main loop
; ============================================================================
sigwinch_handler:
    mov byte [winch_pending], 1
    ret

; ============================================================================
; update_term_size - ioctl(TIOCGWINSZ) -> term_rows / term_cols
; Async-signal unsafe; must be called from main loop after signal observed.
; winsize layout: ushort row; ushort col; ushort xpix; ushort ypix.
; ============================================================================
update_term_size:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    mov eax, SYS_IOCTL
    mov edi, 1                      ; STDOUT
    mov esi, TIOCGWINSZ
    lea rdx, [winsize_buf]
    syscall
    test rax, rax
    js .uts_done

    movzx eax, word [winsize_buf]
    mov [term_rows], ax
    movzx eax, word [winsize_buf + 2]
    mov [term_cols], ax

.uts_done:
    leave
    ret

; ============================================================================
; sig_restorer - Signal return trampoline
; Required by SA_RESTORER flag. Calls rt_sigreturn to properly return
; from the signal handler.
; ============================================================================
sig_restorer:
    mov eax, SYS_RT_SIGRETURN
    syscall

; ============================================================================
; read_key - Read a single key from stdin, decoding escape sequences
;
; ESC starts a sequence. After "ESC [" the parser reads parameter and
; intermediate bytes up to the final byte, so every CSI sequence is consumed
; whole even when it is not one we act on:
;   A/B/C/D = Up/Down/Right/Left, H/F = Home/End, 1~ 7~ = Home, 4~ 8~ = End,
;   3~ = Delete, 200~ / 201~ = bracketed paste start / end.
; "ESC O x" (SS3) is read the same way. Sequences carrying a modifier
; (ESC[1;5C) and every other key (F1-F12, PgUp, Insert, Alt+key) produce no
; key at all. A lone ESC (nothing follows within 100 ms) yields key_char 27.
; Maps LF(10)/CR(13) -> VK_RETURN, DEL(127) -> VK_BACK, TAB(9) -> VK_TAB.
; Bytes >= 0x80 are gathered into one complete UTF-8 character.
; When stdin reports EOF or an error the terminal is gone: restore and exit.
;
; Output: [key_vkey] = virtual key code, [key_char] = ASCII char,
;         [key_ulen] = byte count of a printable key held in [key_ubuf]
;         (1 for ASCII 32..126, 2..4 for a UTF-8 character), else 0
; ============================================================================
section .bss
    key_ubuf            resb 4      ; bytes of the printable key just read
    key_ulen            resb 1      ; 0 = not a printable key
    key_pushback        resd 1      ; byte+1 given back by the parser, 0 = none
    paste_active        resb 1      ; inside ESC[200~ ... ESC[201~
section .text

; rk_getc - next input byte. eax = 0..255, or -1 on EOF / read error.
rk_getc:
    mov eax, [key_pushback]
    test eax, eax
    jz .rkg_read
    mov dword [key_pushback], 0
    dec eax
    ret
.rkg_read:
    mov eax, SYS_READ
    mov edi, STDIN_FD
    lea rsi, [key_buf]
    mov edx, 1
    syscall
    cmp rax, -4                     ; EINTR: read again
    je .rkg_read
    cmp rax, 1
    jne .rkg_eof
    movzx eax, byte [key_buf]
    ret
.rkg_eof:
    mov eax, -1
    ret

; rk_getc_wait - like rk_getc, but gives up after 100 ms (eax = -2).
; The rest of an escape sequence is already queued when it was sent by a
; terminal, so the wait only ever costs time for a lone ESC.
rk_getc_wait:
    cmp dword [key_pushback], 0
    jne rk_getc
    sub rsp, 16
    mov dword [rsp], STDIN_FD       ; struct pollfd { fd, events, revents }
    mov dword [rsp + 4], 1          ; POLLIN
    mov eax, 7                      ; SYS_poll
    mov rdi, rsp
    mov esi, 1
    mov edx, 100
    syscall
    add rsp, 16
    cmp rax, 1
    jge rk_getc                     ; ready, or hung up (rk_getc sees the EOF)
    mov eax, -2
    ret

read_key:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 24                     ; [rsp] = ';' count, [rsp+4] = bytes seen

    ; Clear output
    mov word [key_vkey], 0
    mov byte [key_char], 0
    mov byte [key_ulen], 0

    call rk_getc
    test eax, eax
    js .rk_gone
    mov ebx, eax

    cmp bl, 27
    je .rk_escape
    cmp bl, 10
    je .rk_return
    cmp bl, 13
    je .rk_return
    cmp bl, 127
    je .rk_backspace
    cmp bl, 9
    je .rk_tab
    cmp bl, 3
    je .rk_ctrlc
    cmp bl, 0x80
    jae .rk_utf8

    ; Regular printable character or other control byte
    mov [key_char], bl
    cmp bl, 32
    jb .rk_done
    mov [key_ubuf], bl
    mov byte [key_ulen], 1
    jmp .rk_done

.rk_return:
    mov byte [key_char], 13     ; CR for compatibility
    mov word [key_vkey], VK_RETURN
    jmp .rk_done

.rk_backspace:
    mov byte [key_char], 8
    mov word [key_vkey], VK_BACK
    jmp .rk_done

.rk_tab:
    mov byte [key_char], 9
    mov word [key_vkey], VK_TAB
    jmp .rk_done

.rk_ctrlc:
    ; Set ctrl_c flag directly
    mov byte [ctrl_c_flag], 1
    mov byte [key_char], 3
    jmp .rk_done

.rk_gone:
    ; The terminal vanished (hangup, closed pty): nobody can read the prompt
    ; any more, so leave instead of spinning on a dead descriptor.
    call restore_terminal
    mov edi, 1
    mov eax, SYS_EXIT
    syscall

; --- UTF-8: collect lead byte + continuation bytes into key_ubuf ---
.rk_utf8:
    cmp bl, 0xC2
    jb .rk_done                     ; stray continuation / overlong lead
    mov r12d, 2
    cmp bl, 0xE0
    jb .rk_u_go
    mov r12d, 3
    cmp bl, 0xF0
    jb .rk_u_go
    mov r12d, 4
    cmp bl, 0xF5
    jae .rk_done
.rk_u_go:
    mov [key_ubuf], bl
    mov r13d, 1
.rk_u_loop:
    cmp r13d, r12d
    jae .rk_u_done
    call rk_getc_wait
    test eax, eax
    js .rk_done                     ; truncated: drop it
    mov ecx, eax
    and cl, 0xC0
    cmp cl, 0x80
    jne .rk_u_bad
    lea rcx, [key_ubuf]
    mov [rcx + r13], al
    inc r13d
    jmp .rk_u_loop
.rk_u_bad:
    inc eax                         ; not a continuation: it starts the next key
    mov [key_pushback], eax
    jmp .rk_done
.rk_u_done:
    mov [key_ulen], r12b
    jmp .rk_done

; --- ESC: lone ESC, CSI, SS3 or Alt+key ---
.rk_escape:
    call rk_getc_wait
    test eax, eax
    jns .rk_esc_next
    cmp eax, -2
    jne .rk_done                    ; EOF: the next read reports it
    mov byte [key_char], 27         ; nothing followed: a real Escape
    jmp .rk_done
.rk_esc_next:
    cmp al, '['
    je .rk_csi
    cmp al, 'O'
    je .rk_ss3
    jmp .rk_done                    ; Alt+key: swallowed

.rk_ss3:
    call rk_getc_wait
    test eax, eax
    js .rk_done
    mov ebx, eax
    xor ecx, ecx                    ; no modifier
    jmp .rk_final_plain

.rk_csi:
    xor r12d, r12d                  ; first parameter
    xor r13d, r13d                  ; second parameter
    mov dword [rsp], 0              ; ';' seen
    mov dword [rsp + 4], 0          ; bytes seen
.rk_csi_next:
    call rk_getc_wait
    test eax, eax
    js .rk_done                     ; timeout / EOF: abandon the sequence
    mov ebx, eax
    inc dword [rsp + 4]
    cmp dword [rsp + 4], 32
    ja .rk_done                     ; runaway sequence
    cmp bl, 0x40
    jae .rk_csi_final
    cmp bl, ';'
    je .rk_csi_sep
    cmp bl, '0'
    jb .rk_csi_next                 ; intermediate byte
    cmp bl, '9'
    ja .rk_csi_next                 ; ':' '<' '=' '>' '?'
    sub ebx, '0'
    cmp dword [rsp], 0
    jne .rk_csi_p2
    imul r12d, r12d, 10
    add r12d, ebx
    cmp r12d, 100000
    jbe .rk_csi_next
    mov r12d, 100000
    jmp .rk_csi_next
.rk_csi_p2:
    cmp dword [rsp], 1
    jne .rk_csi_next
    imul r13d, r13d, 10
    add r13d, ebx
    cmp r13d, 100000
    jbe .rk_csi_next
    mov r13d, 100000
    jmp .rk_csi_next
.rk_csi_sep:
    inc dword [rsp]
    jmp .rk_csi_next

.rk_csi_final:
    cmp bl, 0x7F
    jae .rk_done
    mov ecx, [rsp]                  ; nonzero = a modifier parameter was sent
    cmp bl, '~'
    jne .rk_final_plain
    test ecx, ecx
    jnz .rk_done
    cmp r12d, 200
    je .rk_paste_on
    cmp r12d, 201
    je .rk_paste_off
    cmp r12d, 1
    je .rk_home
    cmp r12d, 7
    je .rk_home
    cmp r12d, 4
    je .rk_end
    cmp r12d, 8
    je .rk_end
    cmp r12d, 3
    je .rk_del
    jmp .rk_done                    ; Insert, PgUp, PgDn, F5..F12

.rk_final_plain:
    test ecx, ecx
    jnz .rk_done
    cmp bl, 'A'
    je .rk_up
    cmp bl, 'B'
    je .rk_down
    cmp bl, 'C'
    je .rk_right
    cmp bl, 'D'
    je .rk_left
    cmp bl, 'H'
    je .rk_home
    cmp bl, 'F'
    je .rk_end
    jmp .rk_done

.rk_paste_on:
    mov byte [paste_active], 1
    jmp .rk_done
.rk_paste_off:
    mov byte [paste_active], 0
    jmp .rk_done
.rk_del:
    mov word [key_vkey], VK_DELETE
    jmp .rk_done
.rk_up:
    mov word [key_vkey], VK_UP
    jmp .rk_done
.rk_down:
    mov word [key_vkey], VK_DOWN
    jmp .rk_done
.rk_right:
    mov word [key_vkey], VK_RIGHT
    jmp .rk_done
.rk_left:
    mov word [key_vkey], VK_LEFT
    jmp .rk_done
.rk_home:
    mov word [key_vkey], VK_HOME
    jmp .rk_done
.rk_end:
    mov word [key_vkey], VK_END

.rk_done:
    add rsp, 24
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; read_line - Read input with full line editing, history, tab completion
;
; Supports: character insert, backspace, delete, left/right arrow, home/end,
; up/down for history navigation, tab for completion, Ctrl+C to cancel.
; Result is placed in input_buf (null-terminated).
; ============================================================================
read_line:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 32

    ; Initialize line state
    mov dword [line_len], 0
    mov dword [line_cursor], 0
    mov byte [line_buf], 0
    mov byte [history_browsing], 0
    mov byte [tab_active], 0
    mov byte [paste_active], 0
    mov byte [hl_cache_valid], 0    ; PATH or aliases may have changed

    ; A new line starts browsing at the newest entry. Ctrl+C and an empty
    ; Enter never reach history_add, so an earlier Up must not carry over.
    mov eax, [history_write_idx]
    mov [history_nav_idx], eax
    mov dword [history_nav_steps], 0

    ; A ^C that interrupted a child is not meant for this line
    mov byte [ctrl_c_flag], 0

.rl_loop:
    ; Check for pending Ctrl+C
    cmp byte [ctrl_c_flag], 0
    jne .rl_ctrlc

    ; Read a key
    call read_key

    ; Load virtual key and ascii char
    movzx ebx, word [key_vkey]
    movzx r12d, byte [key_char]

    ; Inside a bracketed paste only text counts: a pasted newline or Tab
    ; becomes a space, every other control byte is dropped, so nothing
    ; pasted can run a command or trigger an editing key.
    cmp byte [paste_active], 0
    je .rl_not_paste
    cmp bx, VK_RETURN
    je .rl_paste_space
    cmp bx, VK_TAB
    je .rl_paste_space
    cmp byte [key_ulen], 0
    je .rl_loop
    jmp .rl_not_paste
.rl_paste_space:
    mov byte [key_ubuf], ' '
    mov byte [key_ulen], 1
    xor ebx, ebx
    mov r12d, ' '
.rl_not_paste:

    ; Cancel tab completion on any non-tab key
    cmp bx, VK_TAB
    je .rl_dispatch
    cmp byte [tab_active], 0
    je .rl_dispatch
    ; Tab was active but non-tab pressed - cancel tab state
    mov byte [tab_active], 0

.rl_dispatch:
    cmp bx, VK_RETURN
    je .rl_enter
    cmp bx, VK_BACK
    je .rl_backspace
    cmp bx, VK_DELETE
    je .rl_delete
    cmp bx, VK_LEFT
    je .rl_left
    cmp bx, VK_RIGHT
    je .rl_right
    cmp bx, VK_UP
    je .rl_up
    cmp bx, VK_DOWN
    je .rl_down
    cmp bx, VK_HOME
    je .rl_home
    cmp bx, VK_END
    je .rl_end
    cmp bx, VK_TAB
    je .rl_tab

    ; Check if it's a printable character (no special vkey, char >= 32)
    test bx, bx
    jnz .rl_loop            ; had a vkey but not handled above, ignore
    ; Ctrl+key shortcuts (raw byte values)
    cmp r12d, 12            ; Ctrl+L = clear screen
    je .rl_ctrl_l
    cmp r12d, 23            ; Ctrl+W = delete word backward
    je .rl_ctrl_w
    cmp r12d, 21            ; Ctrl+U = clear line before cursor
    je .rl_ctrl_u
    cmp r12d, 18            ; Ctrl+R = reverse history search
    je .rl_ctrl_r
    cmp r12d, 1             ; Ctrl+A = beginning of line (alias of Home)
    je .rl_home
    cmp r12d, 5             ; Ctrl+E = end of line (alias of End)
    je .rl_end
    cmp r12d, 2             ; Ctrl+B = back one char (alias of Left)
    je .rl_left
    cmp r12d, 6             ; Ctrl+F = forward one char (alias of Right)
    je .rl_right
    cmp r12d, 16            ; Ctrl+P = previous history (alias of Up)
    je .rl_up
    cmp r12d, 14            ; Ctrl+N = next history (alias of Down)
    je .rl_down
    cmp r12d, 11            ; Ctrl+K = kill from cursor to end of line
    je .rl_ctrl_k
    cmp r12d, 25            ; Ctrl+Y = yank kill buffer at cursor
    je .rl_ctrl_y
    cmp r12d, 4             ; Ctrl+D = EOF (empty) / delete-char
    je .rl_ctrl_d

    ; A printable key: one ASCII byte or a whole UTF-8 character
    movzx r8d, byte [key_ulen]
    test r8d, r8d
    jz .rl_loop

    ; Buffer full?
    mov eax, [line_len]
    add eax, r8d
    cmp eax, MAX_INPUT - 2
    ja .rl_loop

    ; Insert at cursor position: shift the tail right by the key's length
    lea rdi, [line_buf]
    mov ecx, [line_len]
    mov edx, [line_cursor]
.rl_shift_r:
    cmp ecx, edx
    jle .rl_ins
    dec ecx
    movzx eax, byte [rdi + rcx]
    lea r9, [rcx + r8]
    mov [rdi + r9], al
    jmp .rl_shift_r
.rl_ins:
    xor ecx, ecx
.rl_ins_copy:
    movzx eax, byte [key_ubuf + rcx]
    lea r9, [rdx + rcx]
    mov [rdi + r9], al
    inc ecx
    cmp ecx, r8d
    jb .rl_ins_copy
    add [line_len], r8d
    add [line_cursor], r8d
    mov ecx, [line_len]
    mov byte [rdi + rcx], 0
    call redraw_line
    jmp .rl_loop

.rl_enter:
    ; Park the cursor behind the last character so the newline lands below
    ; the whole (possibly wrapped) line
    mov eax, [line_len]
    cmp eax, [line_cursor]
    je .rl_enter_copy
    mov [line_cursor], eax
    call update_cursor_pos
.rl_enter_copy:
    ; Copy line_buf to input_buf
    lea rsi, [line_buf]
    lea rdi, [input_buf]
    mov ecx, [line_len]
    inc ecx                 ; include null terminator
.rl_cpy:
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jnz .rl_cpy
    call print_newline
    jmp .rl_done

.rl_backspace:
    mov ecx, [line_cursor]
    test ecx, ecx
    jz .rl_loop
    lea rdi, [line_buf]
    mov edx, ecx                    ; end of the range to remove
.rl_bs_back:                        ; step back to the start of the character
    dec ecx
    jz .rl_bs_do
    mov al, [rdi + rcx]
    and al, 0xC0
    cmp al, 0x80
    je .rl_bs_back
.rl_bs_do:
    mov esi, ecx
    call line_remove
    call redraw_line
    jmp .rl_loop

.rl_delete:
    mov esi, [line_cursor]
    mov ecx, [line_len]
    cmp esi, ecx
    jge .rl_loop
    lea rdi, [line_buf]
    lea edx, [rsi + 1]
.rl_del_fwd:                        ; swallow the continuation bytes
    cmp edx, ecx
    jge .rl_del_do
    mov al, [rdi + rdx]
    and al, 0xC0
    cmp al, 0x80
    jne .rl_del_do
    inc edx
    jmp .rl_del_fwd
.rl_del_do:
    call line_remove
    call redraw_line
    jmp .rl_loop

.rl_left:
    mov ecx, [line_cursor]
    test ecx, ecx
    jz .rl_loop
    lea rdi, [line_buf]
.rl_left_back:
    dec ecx
    jz .rl_left_set
    mov al, [rdi + rcx]
    and al, 0xC0
    cmp al, 0x80
    je .rl_left_back
.rl_left_set:
    mov [line_cursor], ecx
    call update_cursor_pos
    jmp .rl_loop

.rl_right:
    mov ecx, [line_cursor]
    mov edx, [line_len]
    cmp ecx, edx
    jge .rl_loop
    lea rdi, [line_buf]
.rl_right_fwd:
    inc ecx
    cmp ecx, edx
    jge .rl_right_set
    mov al, [rdi + rcx]
    and al, 0xC0
    cmp al, 0x80
    je .rl_right_fwd
.rl_right_set:
    mov [line_cursor], ecx
    call update_cursor_pos
    jmp .rl_loop

.rl_home:
    mov dword [line_cursor], 0
    call update_cursor_pos
    jmp .rl_loop

.rl_end:
    mov eax, [line_len]
    mov [line_cursor], eax
    call update_cursor_pos
    jmp .rl_loop

.rl_up:
    call history_navigate_up
    jmp .rl_loop

.rl_down:
    call history_navigate_down
    jmp .rl_loop

.rl_tab:
    call tab_complete
    jmp .rl_loop

; --- Ctrl+L: Clear screen and redraw prompt with current line ---
.rl_ctrl_l:
    call clear_screen
    mov dword [cursor_row], 0       ; the cursor is home, on the prompt's row
    call redraw_line
    jmp .rl_loop

; --- Ctrl+K: Kill from cursor to end of line into kill_buf ---
.rl_ctrl_k:
    mov ecx, [line_cursor]
    mov eax, [line_len]
    cmp ecx, eax
    jge .rl_loop                    ; nothing right of cursor
    lea rdi, [line_buf]
    lea rsi, [kill_buf]
    mov edx, ecx                    ; src index
    xor r8d, r8d                    ; dst index
.rl_ck_copy:
    cmp edx, eax
    jge .rl_ck_done
    mov r9b, [rdi + rdx]
    mov [rsi + r8], r9b
    inc edx
    inc r8d
    cmp r8d, 511
    jge .rl_ck_done
    jmp .rl_ck_copy
.rl_ck_done:
    mov byte [rsi + r8], 0
    mov [line_len], ecx
    mov byte [rdi + rcx], 0
    call redraw_line
    jmp .rl_loop

; --- Ctrl+Y: Yank kill_buf at cursor position ---
.rl_ctrl_y:
    cmp byte [kill_buf], 0
    je .rl_loop                    ; nothing to yank
    lea rsi, [kill_buf]
    xor r8d, r8d                    ; kill_buf index
.rl_cy_loop:
    movzx eax, byte [rsi + r8]
    test al, al
    jz .rl_cy_done
    mov ecx, [line_len]
    cmp ecx, MAX_INPUT - 2
    jge .rl_cy_done
    mov edx, [line_cursor]
.rl_cy_shift:
    cmp ecx, edx
    jle .rl_cy_ins
    lea rdi, [line_buf]
    mov r9b, [rdi + rcx - 1]
    mov [rdi + rcx], r9b
    dec ecx
    jmp .rl_cy_shift
.rl_cy_ins:
    lea rdi, [line_buf]
    mov [rdi + rdx], al
    inc dword [line_len]
    inc dword [line_cursor]
    mov ecx, [line_len]
    mov byte [rdi + rcx], 0
    inc r8d
    jmp .rl_cy_loop
.rl_cy_done:
    call redraw_line
    jmp .rl_loop

; --- Ctrl+D: EOF on empty line, else delete-char at cursor ---
.rl_ctrl_d:
    mov ecx, [line_len]
    test ecx, ecx
    jnz .rl_delete
    cmp byte [ash_cont], 0
    jne .rl_cd_block
    call print_newline
    call restore_terminal
    mov edi, [last_exit_status]     ; leave with the last status, like exit
    mov eax, SYS_EXIT
    syscall
.rl_cd_block:
    ; EOF inside an unfinished if/while/for: report it and fall back to the
    ; primary prompt instead of closing the shell
    call print_newline
    call ash_feed_eof
    mov byte [input_buf], 0
    jmp .rl_done

; --- Ctrl+W: Delete word backward from cursor ---
.rl_ctrl_w:
    mov ecx, [line_cursor]
    test ecx, ecx
    jz .rl_loop                     ; nothing to delete
    lea rdi, [line_buf]
    mov edx, ecx                    ; edx = original cursor (deletion end)
    ; Skip spaces backward
.rl_cw_skip_sp:
    test ecx, ecx
    jz .rl_cw_do_delete
    cmp byte [rdi + rcx - 1], ' '
    jne .rl_cw_skip_word
    dec ecx
    jmp .rl_cw_skip_sp
    ; Skip non-space chars backward (the word)
.rl_cw_skip_word:
    test ecx, ecx
    jz .rl_cw_do_delete
    cmp byte [rdi + rcx - 1], ' '
    je .rl_cw_do_delete
    dec ecx
    jmp .rl_cw_skip_word
.rl_cw_do_delete:
    ; ecx = new cursor, edx = old cursor
    mov [line_cursor], ecx
    mov ebx, edx                    ; source index
    mov eax, [line_len]
    mov r8d, ecx                    ; destination index
.rl_cw_shift:
    cmp ebx, eax
    jge .rl_cw_done
    mov r9b, [rdi + rbx]
    mov [rdi + r8], r9b
    inc ebx
    inc r8d
    jmp .rl_cw_shift
.rl_cw_done:
    mov [line_len], r8d
    mov byte [rdi + r8], 0
    call redraw_line
    jmp .rl_loop

; --- Ctrl+U: Clear everything before cursor ---
.rl_ctrl_u:
    mov ecx, [line_cursor]
    test ecx, ecx
    jz .rl_loop                     ; nothing before cursor
    lea rdi, [line_buf]
    mov eax, [line_len]
    xor edx, edx                    ; destination index = 0
.rl_cu_shift:
    cmp ecx, eax
    jge .rl_cu_done
    mov r8b, [rdi + rcx]
    mov [rdi + rdx], r8b
    inc ecx
    inc edx
    jmp .rl_cu_shift
.rl_cu_done:
    mov [line_len], edx
    mov byte [rdi + rdx], 0
    mov dword [line_cursor], 0
    call redraw_line
    jmp .rl_loop

; --- Ctrl+R: Reverse history search ---
.rl_ctrl_r:
    call reverse_history_search
    jmp .rl_loop

.rl_ctrlc:
    mov byte [ctrl_c_flag], 0
    ; ^C goes behind the text, not into the middle of a wrapped line
    mov eax, [line_len]
    cmp eax, [line_cursor]
    je .rl_ctrlc_at_end
    mov [line_cursor], eax
    call update_cursor_pos
.rl_ctrlc_at_end:
    mov byte [ash_cont], 0          ; Ctrl+C also drops an unfinished block
    mov dword [ash_pending_len], 0
    mov dword [line_len], 0
    mov dword [line_cursor], 0
    mov byte [line_buf], 0
    mov byte [input_buf], 0
    lea rdi, [str_ctrlc]
    call print_cstring

.rl_done:
    add rsp, 32
    pop r12
    pop rbx
    pop rbp
    ret

; ----------------------------------------------------------------------------
; line_remove - delete line_buf[esi..edx) and leave the cursor at esi
; ----------------------------------------------------------------------------
line_remove:
    lea rdi, [line_buf]
    mov eax, [line_len]
    sub eax, edx
    inc eax                         ; bytes after the range, plus the NUL
    mov r8d, esi
    mov r9d, edx
.lr_loop:
    mov cl, [rdi + r9]
    mov [rdi + r8], cl
    inc r8d
    inc r9d
    dec eax
    jnz .lr_loop
    sub edx, esi
    sub [line_len], edx
    mov [line_cursor], esi
    ret

; ============================================================================
; Screen output for the line editor
;
; The line is drawn from the first row of the prompt every time. cursor_row
; remembers which row (counted from that first row) the terminal cursor is
; on, so a prompt plus command that wraps past the terminal width is erased
; and redrawn in place. All output of one redraw is collected in ob_buf and
; written with a single write(2).
; ============================================================================
%define OB_SIZE 8192
section .bss
    cursor_row          resd 1      ; terminal cursor row, 0 = first prompt row
    ob_active           resb 1      ; print_string_len appends to ob_buf
    ob_len              resd 1
    ob_buf              resb OB_SIZE
section .data
    ansi_clear_eos      db 27, "[J"
section .text

; ob_begin - start collecting output
ob_begin:
    mov dword [ob_len], 0
    mov byte [ob_active], 1
    ret

; ob_end - stop collecting and write what was collected
ob_end:
    mov byte [ob_active], 0
; ob_flush - write ob_buf to the terminal
ob_flush:
    mov edx, [ob_len]
    test edx, edx
    jz .obf_ret
    lea rsi, [ob_buf]
.obf_again:
    mov edi, 1
    mov eax, SYS_WRITE
    syscall
    test rax, rax
    jle .obf_done
    add rsi, rax
    sub rdx, rax
    jnz .obf_again
.obf_done:
    mov dword [ob_len], 0
.obf_ret:
    ret

; write_csi_num - write ESC [ <eax> <cl> (cursor movement) to the output
write_csi_num:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 16

    mov ebx, ecx                ; final byte
    lea r12, [ansi_num_buf]
    mov byte [r12], 27          ; ESC
    mov byte [r12 + 1], '['
    lea rdi, [r12 + 2]
    call uint_to_str            ; eax = number -> digits at rdi, ecx = count
    mov [r12 + rcx + 2], bl
    lea esi, [rcx + 3]
    lea rdi, [ansi_num_buf]
    call print_string_len

    add rsp, 16
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; redraw_line - Redraw the prompt and the (highlighted) line buffer
;
; Back to the first prompt row, replay the cached prompt, draw the line, push
; a pending wrap through if the text ends exactly at the right margin, erase
; whatever an earlier longer draw left, then put the cursor on line_cursor.
; ============================================================================
redraw_line:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 32

    ; The window may have been resized since the last prompt
    cmp byte [winch_pending], 0
    je .rd_size_ok
    mov byte [winch_pending], 0
    call update_term_size
.rd_size_ok:
    call ob_begin

    lea rdi, [str_cr]
    mov esi, 1
    call print_string_len
    mov eax, [cursor_row]
    test eax, eax
    jz .rd_at_top
    mov ecx, 'A'
    call write_csi_num
.rd_at_top:
    call print_prompt_line

    ; --- Syntax highlighting for line content (ash/highlight.asm) ---
    call hl_draw_line

    ; r12d = cells used by prompt + text = where the cursor is now
    lea rdi, [line_buf]
    mov esi, [line_len]
    call utf8_cols
    add eax, [prompt_total_len]
    mov r12d, eax
    call cur_cols
    mov ecx, eax
    mov eax, r12d
    xor edx, edx
    div ecx                     ; eax = end row, edx = end column
    mov r14d, eax
    test edx, edx
    jnz .rd_erase
    test r12d, r12d
    jz .rd_erase
    lea rdi, [wrap_nudge]       ; text fills the last column: wrap now, so the
    mov esi, 2                  ; erase below does not hit the last character
    call print_string_len
.rd_erase:
    lea rdi, [ansi_clear_eos]
    mov esi, 3
    call print_string_len

    ; Cursor target: prompt + the text before line_cursor
    lea rdi, [line_buf]
    mov esi, [line_cursor]
    call utf8_cols
    add eax, [prompt_total_len]
    mov r13d, eax
    call cur_cols
    mov ecx, eax
    mov eax, r13d
    xor edx, edx
    div ecx                     ; eax = target row, edx = target column
    mov [cursor_row], eax
    mov ebx, edx
    sub r14d, eax               ; rows between the end of the text and it
    jle .rd_col
    mov eax, r14d
    mov ecx, 'A'
    call write_csi_num
.rd_col:
    lea eax, [rbx + 1]
    mov ecx, 'G'
    call write_csi_num
    call ob_end

    add rsp, 32
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; update_cursor_pos - Move the cursor to line_cursor without redrawing
; Works out the target row and column from the text before the cursor and
; moves relative to cursor_row.
; ============================================================================
update_cursor_pos:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 16

    call ob_begin
    lea rdi, [line_buf]
    mov esi, [line_cursor]
    call utf8_cols
    add eax, [prompt_total_len]
    mov r12d, eax
    call cur_cols
    mov ecx, eax
    mov eax, r12d
    xor edx, edx
    div ecx                     ; eax = target row, edx = target column
    mov ebx, edx
    mov ecx, [cursor_row]
    mov [cursor_row], eax
    cmp eax, ecx
    je .ucp_col
    jb .ucp_up
    sub eax, ecx
    mov ecx, 'B'
    call write_csi_num
    jmp .ucp_col
.ucp_up:
    sub ecx, eax
    mov eax, ecx
    mov ecx, 'A'
    call write_csi_num
.ucp_col:
    lea eax, [rbx + 1]
    mov ecx, 'G'
    call write_csi_num
    call ob_end

    add rsp, 16
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; uint_to_str - Convert unsigned integer to decimal string
; eax = number, rdi = output buffer
; Returns: ecx = number of digits written, string written to [rdi]
; Uses a small local stack buffer to reverse digits.
; ============================================================================
uint_to_str:
    push rbx
    push rdx
    push rbp
    mov rbp, rsp
    sub rsp, 16                 ; local buffer for reversed digits

    mov ebx, 10
    xor ecx, ecx               ; digit count

    ; Handle zero case
    test eax, eax
    jnz .uts_loop
    mov byte [rdi], '0'
    mov ecx, 1
    jmp .uts_done

.uts_loop:
    ; Divide eax by 10, push remainder digit onto local buffer
    test eax, eax
    jz .uts_reverse
    xor edx, edx
    div ebx
    add dl, '0'
    mov [rbp - 16 + rcx], dl   ; store digit in local buffer (reversed)
    inc ecx
    jmp .uts_loop

.uts_reverse:
    ; Copy digits from local buffer to output in correct order
    mov ebx, ecx               ; total digits
    xor edx, edx               ; output index
.uts_rev_loop:
    cmp edx, ebx
    jge .uts_done
    mov eax, ebx
    dec eax
    sub eax, edx               ; source index = (count-1) - output_index
    movzx eax, byte [rbp - 16 + rax]
    mov [rdi + rdx], al
    inc edx
    jmp .uts_rev_loop

.uts_done:
    ; ecx = number of digits written
    add rsp, 16
    pop rbp
    pop rdx
    pop rbx
    ret

; ============================================================================
; history_add - Add a command line to the circular history buffer
; rdi = pointer to null-terminated string to add
; Skips empty strings and duplicates of the most recent entry.
; ============================================================================
history_add:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 24

    mov r12, rdi                ; save string pointer

    ; Skip empty strings
    cmp byte [r12], 0
    je .ha_done

    ; Skip duplicate of last entry
    mov eax, [history_count]
    test eax, eax
    jz .ha_add

    ; Get index of most recent entry
    mov eax, [history_write_idx]
    test eax, eax
    jnz .ha_dup_idx
    mov eax, HISTORY_COUNT
.ha_dup_idx:
    dec eax
    imul eax, HISTORY_ENTRY_SIZE
    lea rsi, [history_buf]
    add rsi, rax

    ; Compare with new string (commands are case-sensitive)
    mov rdi, r12
    ; rsi already points to last entry
    call hist_streq
    test eax, eax
    jz .ha_done                 ; duplicate, skip

.ha_add:
    ; Copy string to history buffer at write_idx
    mov eax, [history_write_idx]
    imul eax, HISTORY_ENTRY_SIZE
    lea rdi, [history_buf]
    add rdi, rax
    mov rsi, r12
    mov ecx, HISTORY_ENTRY_SIZE - 1
.ha_copy:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .ha_term
    inc rsi
    inc rdi
    dec ecx
    jnz .ha_copy
.ha_term:
    mov byte [rdi], 0

    ; Advance write index (wrap around)
    mov eax, [history_write_idx]
    inc eax
    cmp eax, HISTORY_COUNT
    jl .ha_nowrap
    xor eax, eax
.ha_nowrap:
    mov [history_write_idx], eax

    ; Increment count (cap at HISTORY_COUNT)
    mov eax, [history_count]
    cmp eax, HISTORY_COUNT
    jge .ha_done
    inc eax
    mov [history_count], eax

.ha_done:
    ; Reset navigation state
    mov eax, [history_write_idx]
    mov [history_nav_idx], eax
    mov dword [history_nav_steps], 0
    mov byte [history_browsing], 0

    add rsp, 24
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; hist_streq - eax = 0 if the NUL-terminated strings at rdi and rsi are equal
; ============================================================================
hist_streq:
.hse_loop:
    mov al, [rdi]
    cmp al, [rsi]
    jne .hse_ne
    test al, al
    jz .hse_eq
    inc rdi
    inc rsi
    jmp .hse_loop
.hse_eq:
    xor eax, eax
    ret
.hse_ne:
    mov eax, 1
    ret

; ============================================================================
; history_navigate_up - Navigate to the previous (older) history entry
; Saves current line on first navigation, then walks backwards through
; the circular buffer. history_nav_steps counts how far back we are (1 = the
; newest entry), so the oldest entry is reachable even in a full ring where
; its index equals the write index.
; ============================================================================
section .bss
    history_nav_steps   resd 1
section .text
history_navigate_up:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 24

    ; Nothing to navigate if history is empty
    mov eax, [history_count]
    test eax, eax
    jz .hnu_done

    ; Already on the oldest entry?
    mov ecx, [history_nav_steps]
    cmp ecx, eax
    jae .hnu_done

    ; Save current line if this is the first navigation press
    cmp byte [history_browsing], 0
    jne .hnu_nav
    mov byte [history_browsing], 1
    lea rdi, [history_saved]
    lea rsi, [line_buf]
    call str_copy

.hnu_nav:
    ; One step further back: index = write_idx - steps (mod HISTORY_COUNT)
    mov ecx, [history_nav_steps]
    inc ecx
    mov [history_nav_steps], ecx
    mov eax, [history_write_idx]
    sub eax, ecx
    jge .hnu_idx
    add eax, HISTORY_COUNT
.hnu_idx:

    ; Load history entry into line_buf
    mov [history_nav_idx], eax
    imul eax, HISTORY_ENTRY_SIZE
    lea rsi, [history_buf]
    add rsi, rax
    lea rdi, [line_buf]
    call str_copy

    ; Update line_len and line_cursor
    lea rdi, [line_buf]
    call str_len
    mov [line_len], eax
    mov [line_cursor], eax
    call redraw_line

.hnu_done:
    add rsp, 24
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; history_navigate_down - Navigate to the next (newer) history entry
; If at the newest entry, restores the saved line.
; ============================================================================
history_navigate_down:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 24

    ; Only works if we're currently browsing history
    cmp byte [history_browsing], 0
    je .hnd_done

    ; One step forward; past the newest entry the saved line comes back
    mov ecx, [history_nav_steps]
    dec ecx
    mov [history_nav_steps], ecx
    jz .hnd_restore
    mov eax, [history_write_idx]
    sub eax, ecx
    jge .hnd_idx
    add eax, HISTORY_COUNT
.hnd_idx:

    ; Load history entry into line_buf
    mov [history_nav_idx], eax
    imul eax, HISTORY_ENTRY_SIZE
    lea rsi, [history_buf]
    add rsi, rax
    lea rdi, [line_buf]
    call str_copy

    lea rdi, [line_buf]
    call str_len
    mov [line_len], eax
    mov [line_cursor], eax
    call redraw_line
    jmp .hnd_done

.hnd_restore:
    ; Restore the saved line (what user was typing before navigating)
    mov eax, [history_write_idx]
    mov [history_nav_idx], eax
    mov byte [history_browsing], 0
    lea rdi, [line_buf]
    lea rsi, [history_saved]
    call str_copy

    lea rdi, [line_buf]
    call str_len
    mov [line_len], eax
    mov [line_cursor], eax
    call redraw_line

.hnd_done:
    add rsp, 24
    pop rbx
    pop rbp
    ret


; ============================================================================
; tab_complete - File/directory tab completion using getdents64
; Called from read_line when Tab is pressed.
;
; The first Tab remembers the word under the cursor (tab_name_prefix), the
; text behind the cursor (tab_tail) and starts at match 0. Every Tab - the
; first and each repeat - opens the directory, walks it to the
; tab_cycle_idx-th match, closes it again and rebuilds the line as
;     text before the word + directory part + name (+ "/") + tail.
; Past the last match the cycle starts over. Nothing stays open between key
; presses, so an abandoned cycle leaks nothing, and a directory of any size
; is read to its end.
; ============================================================================
section .bss
    tab_cycle_idx       resd 1      ; which match the next Tab inserts
    tab_tail            resb MAX_INPUT
    tab_tail_len        resd 1
section .text
tab_complete:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24

    ; ------ Continuing a previous tab cycle? ------
    cmp byte [tab_active], 1
    je .tc_derive

    ; ====== FIRST TAB: remember the word, the tail, start at match 0 ======

    ; Find the start of the word being completed (scan backwards from cursor)
    mov r12d, [line_cursor]         ; r12d = word start position
.tc_scan:
    test r12d, r12d
    jz .tc_start
    dec r12d
    lea rax, [line_buf]
    cmp byte [rax + r12], ' '
    jne .tc_scan
    inc r12d                        ; don't include the space itself

.tc_start:
    ; r12d = index of word start in line_buf
    ; Save the base position (where completions will be inserted)
    mov [tab_base_pos], r12d

    ; Copy the word (from line_buf[r12d] .. line_buf[cursor-1]) to tab_name_prefix
    mov ebx, [line_cursor]
    sub ebx, r12d                   ; ebx = prefix length
    mov [tab_name_prefix_len], ebx

    xor ecx, ecx
.tc_cp_prefix:
    cmp ecx, ebx
    jge .tc_cp_prefix_done
    lea rax, [line_buf]
    add rax, r12
    movzx edx, byte [rax + rcx]
    lea r8, [tab_name_prefix]
    mov [r8 + rcx], dl
    inc ecx
    jmp .tc_cp_prefix
.tc_cp_prefix_done:
    lea r8, [tab_name_prefix]
    mov byte [r8 + rbx], 0

    ; Keep the text behind the cursor: the completion goes in front of it
    mov ecx, [line_cursor]
    mov edx, [line_len]
    lea rsi, [line_buf]
    lea rdi, [tab_tail]
    xor eax, eax
.tc_cp_tail:
    cmp ecx, edx
    jae .tc_tail_done
    mov r8b, [rsi + rcx]
    mov [rdi + rax], r8b
    inc ecx
    inc eax
    jmp .tc_cp_tail
.tc_tail_done:
    mov byte [rdi + rax], 0
    mov [tab_tail_len], eax

    mov dword [tab_cycle_idx], 0
    mov byte [tab_active], 1

.tc_derive:
    ; Split the stored word at its last '/': r15d = where the name starts
    lea rdi, [tab_name_prefix]
    mov ecx, [tab_name_prefix_len]
    xor r15d, r15d                  ; no slash: the name is the whole word
.tc_find_slash:
    test ecx, ecx
    jz .tc_slash_done
    dec ecx
    cmp byte [rdi + rcx], '/'
    jne .tc_find_slash
    lea r15d, [rcx + 1]
.tc_slash_done:

    ; The directory to read goes to find_pattern: "." or the part before the name
    lea rdi, [find_pattern]
    test r15d, r15d
    jz .tc_dir_dot
    lea rsi, [tab_name_prefix]
    xor ecx, ecx
.tc_cp_dir:
    cmp ecx, r15d
    jge .tc_cp_dir_done
    movzx eax, byte [rsi + rcx]
    mov [rdi + rcx], al
    inc ecx
    jmp .tc_cp_dir
.tc_cp_dir_done:
    ; "dir/" loses its trailing '/'; a lone "/" stays so we open the root
    cmp r15d, 1
    jle .tc_dir_root
    mov byte [rdi + rcx - 1], 0
    jmp .tc_scan_dir
.tc_dir_root:
    mov byte [rdi + rcx], 0
    jmp .tc_scan_dir
.tc_dir_dot:
    mov word [rdi], 0x002E          ; "."

.tc_scan_dir:
    ; open(dir, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    lea rdi, [find_pattern]
    mov esi, O_RDONLY | O_DIRECTORY | 0x80000
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .tc_giveup
    mov ebx, eax                    ; ebx = directory fd
    xor r13d, r13d                  ; r13d = matches passed so far

.tc_read:
    mov edi, ebx
    lea rsi, [dirent_buf]
    mov edx, DIRENT_BUF_SIZE
    mov eax, SYS_GETDENTS64
    syscall
    test rax, rax
    jle .tc_dir_end                 ; end of directory (or a read error)
    mov r14d, eax                   ; bytes in dirent_buf
    xor r12d, r12d                  ; offset of the next entry

.tc_entry:
    cmp r12d, r14d
    jae .tc_read
    lea rsi, [dirent_buf]
    add rsi, r12                    ; rsi = this entry
    movzx eax, word [rsi + DIRENT_D_RECLEN]
    add r12d, eax
    lea r9, [rsi + DIRENT_D_NAME]   ; r9 = d_name

    ; Skip "." and ".."
    cmp byte [r9], '.'
    jne .tc_pfx
    cmp byte [r9 + 1], 0
    je .tc_entry
    cmp byte [r9 + 1], '.'
    jne .tc_pfx
    cmp byte [r9 + 2], 0
    je .tc_entry

.tc_pfx:
    ; d_name must start with the typed name (case-insensitive)
    lea r8, [tab_name_prefix]
    add r8, r15
    mov ecx, [tab_name_prefix_len]
    sub ecx, r15d
    xor edx, edx
.tc_cmp_loop:
    cmp edx, ecx
    jge .tc_ctl
    movzx edi, byte [r8 + rdx]
    movzx r10d, byte [r9 + rdx]
    cmp dil, 'A'
    jb .tc_cmp_s2
    cmp dil, 'Z'
    ja .tc_cmp_s2
    add dil, 32
.tc_cmp_s2:
    cmp r10b, 'A'
    jb .tc_cmp_check
    cmp r10b, 'Z'
    ja .tc_cmp_check
    add r10b, 32
.tc_cmp_check:
    cmp dil, r10b
    jne .tc_entry
    inc edx
    jmp .tc_cmp_loop

.tc_ctl:
    ; A name with control bytes would garble the line: never offer it
    xor edx, edx
.tc_ctl_loop:
    movzx eax, byte [r9 + rdx]
    test al, al
    jz .tc_matched
    cmp al, 0x20
    jb .tc_entry
    cmp al, 0x7F
    je .tc_entry
    inc edx
    jmp .tc_ctl_loop

.tc_matched:
    cmp r13d, [tab_cycle_idx]
    je .tc_insert
    inc r13d
    jmp .tc_entry

.tc_dir_end:
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall
    cmp dword [tab_cycle_idx], 0
    je .tc_giveup                   ; nothing matches at all
    mov dword [tab_cycle_idx], 0    ; past the last match: start over
    jmp .tc_scan_dir

.tc_insert:
    ; rsi = the chosen entry. The dirent data stays valid after the close.
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall
    inc dword [tab_cycle_idx]
    lea r9, [rsi + DIRENT_D_NAME]
    movzx r10d, byte [rsi + DIRENT_D_TYPE]

    xor ecx, ecx                    ; ecx = length of d_name
.tc_nlen:
    cmp byte [r9 + rcx], 0
    je .tc_nlen_done
    inc ecx
    jmp .tc_nlen
.tc_nlen_done:

    ; New cursor = word start + directory part + name (+ "/")
    xor edx, edx
    cmp r10b, DT_DIR
    sete dl                         ; edx = 1 when a '/' follows
    mov r8d, [tab_base_pos]
    add r8d, r15d
    add r8d, ecx
    add r8d, edx
    mov eax, r8d
    add eax, [tab_tail_len]
    cmp eax, MAX_INPUT - 2
    ja .tc_done                     ; would overflow the line: leave it be

    lea rdi, [line_buf]
    mov eax, [tab_base_pos]
    add rdi, rax
    lea rsi, [tab_name_prefix]
    mov eax, r15d                   ; directory part
.tc_w1:
    test eax, eax
    jz .tc_w2
    mov r11b, [rsi]
    mov [rdi], r11b
    inc rsi
    inc rdi
    dec eax
    jmp .tc_w1
.tc_w2:
    mov rsi, r9
    mov eax, ecx                    ; name
.tc_w3:
    test eax, eax
    jz .tc_w4
    mov r11b, [rsi]
    mov [rdi], r11b
    inc rsi
    inc rdi
    dec eax
    jmp .tc_w3
.tc_w4:
    test edx, edx
    jz .tc_w5
    mov byte [rdi], '/'
    inc rdi
.tc_w5:
    mov [line_cursor], r8d
    lea rsi, [tab_tail]
    mov eax, [tab_tail_len]
.tc_w6:
    test eax, eax
    jz .tc_w7
    mov r11b, [rsi]
    mov [rdi], r11b
    inc rsi
    inc rdi
    dec eax
    jmp .tc_w6
.tc_w7:
    mov byte [rdi], 0
    mov eax, r8d
    add eax, [tab_tail_len]
    mov [line_len], eax
    call redraw_line
    jmp .tc_done

.tc_giveup:
    mov byte [tab_active], 0

.tc_done:
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; dispatch_command - Expand env, check alias, parse redir, dispatch
;
; Variable and command-substitution results are data. expand_env_vars marks
; every byte of such a value that any later scanner could read as syntax by
; putting EV_MARK in front of it; the scanners (read_word in ash_exec.asm,
; ash_next_word, parse_redirection, the pipe scan) treat "EV_MARK c" as the
; plain character c, and the text handed to /bin/sh goes through
; ash_sh_decode first.
;
; Redirections are applied here only for builtins. Everything else keeps its
; redirections in the text: the native executor (or /bin/sh) opens them in
; the child, so a failed open stops the command and no descriptor leaks.
; ============================================================================
section .data
    ; Bytes of a substituted value that get an EV_MARK in front of them
    ev_special_chars    db 0x5C, 0x27, '"', '`', '$', '|', '&', ';', '<', '>'
                        db '(', ')', '*', '?', '[', '~', '=', '#', 0
    ev_e_long           db "ash: line too long after expansion", 10, 0
    ev_e_subst          db "ash: unterminated command substitution", 10, 0
    ev_e_brace          db "ash: unsupported ${...} expansion", 10, 0
    ev_e_redir          db "ash: syntax error in redirection", 10, 0
    ev_e_alias          db "ash: alias expansion too long", 10, 0
    ev_msg_ash          db "ash: ", 0
    ev_msg_colon        db ": ", 0
    ev_msg_generic      db "cannot open file", 10, 0
    ev_dev_null         db "/dev/null", 0

    ; Builtins that parse their own arguments word by word; every other
    ; builtin gets its argument text unquoted as a single string.
    dc_raw_handlers     dq handler_echo, handler_grep, handler_copy
                        dq handler_move, handler_copy_safe, handler_move_safe
                        dq handler_test, handler_bracket, handler_bench
                        dq handler_trace, handler_sandbox, 0

section .bss
    ev_mode             resb 1              ; 1 = leave $( ) and `` for /bin/sh
    ev_overflow         resb 1              ; 1 = too long, 2 = error reported
    alignb 4
    ev_subst_status     resd 1              ; status of the last $( ), -1 none
    ev_inner_buf        resb MAX_INPUT
    ev_cap_buf          resb 4096
    sh_line_buf         resb 1100
    dc_args_buf         resb MAX_INPUT
    redir_ops           resb 8 * 16         ; kind, fd, target (see parse_redirection)
    redir_nops          resd 1
    redir_err_saved     resd 1              ; saved stderr fd + 1, 0 = none
    redir_pool          resb 4096
section .text

%define EV_MARK             0x01
%define EV_SYS_PIPE2        293
%define EV_SYS_FCNTL        72
%define EV_F_DUPFD_CLOEXEC  1030
%define EV_O_CLOEXEC        0x80000
%define EV_CAP_SIZE         4096

dispatch_command:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 48

    ; Save the caller's redirection state (a builtin such as "source f > out"
    ; runs nested commands that must keep writing to out); it is put back
    ; on the way out. Layout from rbp-56: stderr, stdin fd, stdin active,
    ; stdout fd, stdout active.
    mov eax, [redir_err_saved]
    mov [rbp - 56], eax
    mov dword [redir_err_saved], 0
    mov eax, [redir_stdin_fd]
    mov [rbp - 52], eax
    movzx eax, byte [redir_stdin_active]
    mov [rbp - 48], eax
    mov eax, [redir_stdout_fd]
    mov [rbp - 44], eax
    movzx eax, byte [redir_stdout_active]
    mov [rbp - 40], eax

    ; Expand environment variables ($VAR, ${VAR}, $?, $((...)), $(cmd))
    call expand_env_vars
    test eax, eax
    jnz .dc_done                    ; message printed, status set

    ; Assume success by default (overwritten on failure). Done after the
    ; expansion so "$?" still sees the previous command's status.
    mov eax, [last_exit_status]
    mov [prev_exit_status], eax     ; a bare "exit" reports this one
    mov dword [last_exit_status], 0

    ; Check aliases. The alias text is syntax, so its own $VAR and $( ) are
    ; expanded now; the part that came from the line is left as it was.
    call check_alias
    cmp eax, 1
    je .dc_done
    cmp eax, 2
    jne .dc_alias_done
    call expand_env_vars
    test eax, eax
    jnz .dc_done
.dc_alias_done:

    ; A pipeline goes to the native executor as a whole
    lea rdi, [input_buf]
    call dc_has_pipe
    test eax, eax
    jnz .dc_external

    ; Look for a builtin on the line without its redirections
    call parse_redirection
    mov r14d, eax                   ; 1 = malformed redirection
    lea rdi, [cleaned_cmd_buf]
    call dc_find_builtin
    test rax, rax
    jz .dc_external                 ; not a builtin: the executor handles redirections
    test r14d, r14d
    jnz .dc_bad_redir

    lea rdi, [rbp - 56]
    call apply_redirections
    test eax, eax
    jnz .dc_done

    lea rdi, [input_buf]
    lea rsi, [cleaned_cmd_buf]
    call str_copy
    lea rdi, [input_buf]
    call dc_find_builtin
    mov rdi, rax
    mov rsi, rdx
    call dc_run_handler
    jmp .dc_done

.dc_bad_redir:
    lea rdi, [ev_e_redir]
    call ash_write_err
    mov dword [last_exit_status], 2
    jmp .dc_done

.dc_external:
    call stats_begin
    call execute_external
    call stats_end

.dc_done:
    lea rdi, [rbp - 56]
    call restore_redirection

    add rsp, 48
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ----------------------------------------------------------------------------
; dc_find_builtin(rdi = line) -> rax = handler or 0, rdx = argument text or 0
; Exact-match table first, then the prefix table (name followed by a blank
; or the end of the line).
; ----------------------------------------------------------------------------
dc_find_builtin:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14

    mov r14, rdi
    lea r12, [cmd_table_exact]
.fb_exact:
    mov rsi, [r12]
    test rsi, rsi
    jz .fb_prefix
    mov rdi, r14
    call str_icompare
    test eax, eax
    jz .fb_exact_hit
    add r12, 16
    jmp .fb_exact
.fb_exact_hit:
    mov rax, [r12 + 8]
    xor edx, edx
    jmp .fb_ret

.fb_prefix:
    lea r12, [cmd_table_prefix]
.fb_pfx:
    mov rsi, [r12]
    test rsi, rsi
    jz .fb_none
    mov r13d, [r12 + 16]
    mov rdi, r14
    mov edx, r13d
    call str_icompare_n
    test eax, eax
    jnz .fb_pfx_next
    movzx eax, byte [r14 + r13]
    cmp al, ' '
    je .fb_args
    test al, al
    jz .fb_noargs
.fb_pfx_next:
    add r12, 24
    jmp .fb_pfx
.fb_args:
    lea rdi, [r14 + r13 + 1]
    call skip_spaces
    mov rdx, rax
    mov rax, [r12 + 8]
    jmp .fb_ret
.fb_noargs:
    mov rax, [r12 + 8]
    xor edx, edx
    jmp .fb_ret
.fb_none:
    xor eax, eax
    xor edx, edx
.fb_ret:
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ----------------------------------------------------------------------------
; dc_run_handler(rdi = handler, rsi = argument text or 0)
; Most builtins take their arguments as one unquoted string; the ones in
; dc_raw_handlers get the text as typed and split it themselves.
; ----------------------------------------------------------------------------
dc_run_handler:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    test r12, r12
    jz .rh_call
    call dc_wants_raw
    test eax, eax
    jnz .rh_call
    mov rdi, r12
    lea rsi, [dc_args_buf]
    xor edx, edx
    call ash_next_word
    lea r12, [dc_args_buf]
.rh_call:
    mov rdi, r12
    call rbx
    pop r12
    pop rbx
    pop rbp
    ret

; dc_wants_raw(rdi = handler) -> eax = 1 if it parses its own arguments
dc_wants_raw:
    lea rsi, [dc_raw_handlers]
.wr_loop:
    mov rax, [rsi]
    test rax, rax
    jz .wr_no
    cmp rax, rdi
    je .wr_yes
    add rsi, 8
    jmp .wr_loop
.wr_yes:
    mov eax, 1
    ret
.wr_no:
    xor eax, eax
    ret

; ----------------------------------------------------------------------------
; dc_has_pipe(rdi = text) -> eax = 1 if there is a '|' outside quotes that is
; neither escaped nor marked as data.
; ----------------------------------------------------------------------------
dc_has_pipe:
    xor ecx, ecx                    ; 0 plain, 1 '...', 2 "..."
.hp_loop:
    movzx eax, byte [rdi]
    test al, al
    jz .hp_no
    cmp al, EV_MARK
    je .hp_skip2
    cmp ecx, 1
    je .hp_in_sq
    cmp al, '\'
    je .hp_skip2
    cmp ecx, 2
    je .hp_in_dq
    cmp al, 0x27
    je .hp_open_sq
    cmp al, '"'
    je .hp_open_dq
    cmp al, '|'
    je .hp_yes
.hp_next:
    inc rdi
    jmp .hp_loop
.hp_skip2:
    cmp byte [rdi + 1], 0
    je .hp_no
    add rdi, 2
    jmp .hp_loop
.hp_open_sq:
    mov ecx, 1
    jmp .hp_next
.hp_open_dq:
    mov ecx, 2
    jmp .hp_next
.hp_in_sq:
    cmp al, 0x27
    jne .hp_next
    xor ecx, ecx
    jmp .hp_next
.hp_in_dq:
    cmp al, '"'
    jne .hp_next
    xor ecx, ecx
    jmp .hp_next
.hp_yes:
    mov eax, 1
    ret
.hp_no:
    xor eax, eax
    ret

; ----------------------------------------------------------------------------
; dc_trailing_amp(rdi = text) -> rax = address of a final unquoted '&' (only
; blanks after it) or 0. Escaped, quoted and marked '&' do not count.
; ----------------------------------------------------------------------------
dc_trailing_amp:
    xor ecx, ecx                    ; quote state
    xor r8d, r8d                    ; last '&' seen
    xor r9d, r9d                    ; last byte that is not a blank
.ta_loop:
    movzx eax, byte [rdi]
    test al, al
    jz .ta_end
    cmp al, EV_MARK
    je .ta_pair
    cmp ecx, 1
    je .ta_in_sq
    cmp al, '\'
    je .ta_pair
    cmp ecx, 2
    je .ta_in_dq
    cmp al, 0x27
    je .ta_open_sq
    cmp al, '"'
    je .ta_open_dq
    cmp al, ' '
    je .ta_next
    cmp al, 9
    je .ta_next
    mov r9, rdi
    cmp al, '&'
    jne .ta_next
    mov r8, rdi
.ta_next:
    inc rdi
    jmp .ta_loop
.ta_pair:
    mov r9, rdi
    cmp byte [rdi + 1], 0
    je .ta_end
    add rdi, 2
    jmp .ta_loop
.ta_open_sq:
    mov ecx, 1
    mov r9, rdi
    jmp .ta_next
.ta_open_dq:
    mov ecx, 2
    mov r9, rdi
    jmp .ta_next
.ta_in_sq:
    mov r9, rdi
    cmp al, 0x27
    jne .ta_next
    xor ecx, ecx
    jmp .ta_next
.ta_in_dq:
    mov r9, rdi
    cmp al, '"'
    jne .ta_next
    xor ecx, ecx
    jmp .ta_next
.ta_end:
    xor eax, eax
    test r8, r8
    jz .ta_ret
    cmp r8, r9
    jne .ta_ret
    mov rax, r8
.ta_ret:
    ret

; ----------------------------------------------------------------------------
; ash_sh_decode(rdi = text) -> rax = sh_line_buf
; Turns the marked bytes of an expanded line back into plain data for
; /bin/sh: backslash-escaped when unquoted, escaped only where needed inside
; "..." and '...'. The quoting state follows the text as /bin/sh will read it.
; ----------------------------------------------------------------------------
ash_sh_decode:
    lea rsi, [sh_line_buf]
    lea r8, [sh_line_buf + 1090]
    xor ecx, ecx                    ; 0 plain, 1 '...', 2 "..."
.sd_loop:
    movzx eax, byte [rdi]
    test al, al
    jz .sd_done
    cmp rsi, r8
    jae .sd_done
    cmp al, EV_MARK
    je .sd_mark
    cmp ecx, 1
    je .sd_in_sq
    cmp al, '\'
    jne .sd_not_bs
    mov [rsi], al                   ; copy the backslash and what it escapes
    inc rsi
    inc rdi
    movzx eax, byte [rdi]
    test al, al
    jz .sd_done
    jmp .sd_store
.sd_not_bs:
    cmp ecx, 2
    je .sd_in_dq
    cmp al, 0x27
    jne .sd_chk_dq
    mov ecx, 1
    jmp .sd_store
.sd_chk_dq:
    cmp al, '"'
    jne .sd_store
    mov ecx, 2
    jmp .sd_store
.sd_in_sq:
    cmp al, 0x27
    jne .sd_store
    xor ecx, ecx
    jmp .sd_store
.sd_in_dq:
    cmp al, '"'
    jne .sd_store
    xor ecx, ecx
.sd_store:
    mov [rsi], al
    inc rsi
    inc rdi
    jmp .sd_loop

.sd_mark:
    movzx edx, byte [rdi + 1]
    test dl, dl
    jz .sd_done
    add rdi, 2
    cmp dl, EV_MARK
    jne .sd_mark_c
    mov [rsi], dl                   ; a literal marker byte
    inc rsi
    jmp .sd_loop
.sd_mark_c:
    cmp ecx, 1
    je .sd_m_sq
    cmp ecx, 2
    je .sd_m_dq
    cmp dl, 10                      ; a newline would end the command
    jne .sd_m_bs
    mov byte [rsi], 0x27
    mov byte [rsi + 1], 10
    mov byte [rsi + 2], 0x27
    add rsi, 3
    jmp .sd_loop
.sd_m_bs:
    mov byte [rsi], '\'
    mov [rsi + 1], dl
    add rsi, 2
    jmp .sd_loop
.sd_m_dq:
    cmp dl, '$'
    je .sd_m_bs
    cmp dl, '`'
    je .sd_m_bs
    cmp dl, '"'
    je .sd_m_bs
    cmp dl, '\'
    je .sd_m_bs
    jmp .sd_m_plain
.sd_m_sq:
    cmp dl, 0x27                    ; close the quote, escape it, reopen
    jne .sd_m_plain
    mov byte [rsi], 0x27
    mov byte [rsi + 1], '\'
    mov byte [rsi + 2], 0x27
    mov byte [rsi + 3], 0x27
    add rsi, 4
    jmp .sd_loop
.sd_m_plain:
    mov [rsi], dl
    inc rsi
    jmp .sd_loop
.sd_done:
    mov byte [rsi], 0
    lea rax, [sh_line_buf]
    ret

; ============================================================================
; expand_env_vars - Replace $VAR, ${VAR}, $?, $$, $#, $@, $((expr)),
; $(cmd) and `cmd` in input_buf with their values.
; Linux uses $VAR instead of Windows %VAR%.
;
; The text is rewritten into env_expand_buf and copied back. A value is data:
; spaces and tabs stay (an unquoted value splits into words), a newline
; becomes a blank outside quotes, and every byte listed in ev_special_chars
; (and the marker itself) gets EV_MARK in front. A backslash keeps the next
; character literal, text inside '...' is copied untouched, and EV_MARK pairs
; already in the text pass through, so expanding twice changes nothing more.
; Returns eax = 0, or 1 after printing why (too long, unterminated $( ).
; expand_env_vars_sh leaves $( ) and `` unexpanded for a later /bin/sh run.
; ============================================================================
expand_env_vars_sh:
    mov byte [ev_mode], 1
    jmp expand_env_vars.body
expand_env_vars:
    mov byte [ev_mode], 0
.body:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24

    mov byte [ev_overflow], 0
    mov dword [ev_subst_status], -1
    lea r12, [input_buf]           ; source pointer
    lea r13, [env_expand_buf]      ; destination pointer
    lea r14, [env_expand_buf + MAX_INPUT - 1] ; result goes back to input_buf
    mov r15d, 1                     ; at-word-start flag
    xor ebx, ebx                    ; inside "..."

.ev_loop:
    movzx eax, byte [r12]
    test al, al
    jz .ev_done
    cmp al, EV_MARK
    je .ev_pair
    cmp al, '\'
    je .ev_bs
    cmp al, '"'
    jne .ev_not_dq
    xor ebx, 1
    jmp .ev_regular
.ev_not_dq:
    cmp al, 0x27                    ; '...' is copied as-is (no expansion)
    jne .ev_not_sq
    test ebx, ebx
    jnz .ev_regular
    jmp .ev_sq
.ev_not_sq:
    cmp al, '$'
    je .ev_dollar
    cmp al, '`'
    je .ev_btick
    cmp al, '~'
    jne .ev_regular
    test ebx, ebx
    jnz .ev_regular
    test r15d, r15d                 ; only expand at word start; anywhere else
    jz .ev_tilde_mark               ; it is a plain character, also after $VAR
    movzx ecx, byte [r12 + 1]
    test cl, cl
    jz .ev_tilde
    cmp cl, '/'
    je .ev_tilde
    cmp cl, ' '
    je .ev_tilde
    cmp cl, 9
    je .ev_tilde
    cmp cl, '$'                     ; "~$x": what follows may expand to nothing,
    je .ev_tilde_mark               ; the tilde must not become a prefix then
    cmp cl, '`'
    je .ev_tilde_mark

.ev_regular:
    ; Regular character -- copy through (bounded)
    cmp r13, r14
    jae .ev_over
    mov [r13], al
    inc r12
    inc r13
    xor r15d, r15d
    cmp al, ' '
    je .ev_ws
    cmp al, 9
    jne .ev_loop
.ev_ws:
    mov r15d, 1
    jmp .ev_loop

.ev_pair:
    ; An EV_MARK pair already in the text: keep both bytes
    lea rax, [r13 + 1]
    cmp rax, r14
    jae .ev_over
    mov byte [r13], EV_MARK
    inc r12
    inc r13
    movzx eax, byte [r12]
    test al, al
    jz .ev_loop
    mov [r13], al
    inc r12
    inc r13
    xor r15d, r15d
    jmp .ev_loop

.ev_bs:
    ; A backslash and the character after it are copied without looking at it
    movzx ecx, byte [r12 + 1]
    test cl, cl
    jz .ev_regular                  ; trailing backslash
    lea rax, [r13 + 3]
    cmp rax, r14
    jae .ev_over
    mov byte [r13], '\'
    inc r13
    cmp cl, EV_MARK
    jne .ev_bs_put
    mov byte [r13], EV_MARK
    inc r13
    mov cl, EV_MARK
.ev_bs_put:
    mov [r13], cl
    inc r13
    add r12, 2
    xor r15d, r15d
    jmp .ev_loop

.ev_sq:
    ; '...' copied untouched (EV_MARK is doubled so it stays literal)
    cmp r13, r14
    jae .ev_over
    mov byte [r13], 0x27
    inc r13
    inc r12
.ev_sq_loop:
    movzx eax, byte [r12]
    test al, al
    jz .ev_done
    cmp al, EV_MARK
    jne .ev_sq_put
    lea rcx, [r13 + 1]
    cmp rcx, r14
    jae .ev_over
    mov byte [r13], EV_MARK
    inc r13
.ev_sq_put:
    cmp r13, r14
    jae .ev_over
    mov [r13], al
    inc r13
    inc r12
    cmp al, 0x27
    jne .ev_sq_loop
    xor r15d, r15d
    jmp .ev_loop

.ev_tilde:
    inc r12                         ; consume the tilde
    lea rdi, [str_home]
    call getenv_internal
    test rax, rax
    jz .ev_tilde_literal
    mov rcx, rax
    jmp .ev_value
.ev_tilde_literal:
    cmp r13, r14
    jae .ev_over
    mov byte [r13], '~'
    inc r13
    xor r15d, r15d
    jmp .ev_loop
.ev_tilde_mark:
    lea rax, [r13 + 1]
    cmp rax, r14
    jae .ev_over
    mov byte [r13], EV_MARK
    mov byte [r13 + 1], '~'
    add r13, 2
    inc r12
    xor r15d, r15d
    jmp .ev_loop

.ev_dollar:
    inc r12                         ; skip '$'
    movzx eax, byte [r12]

    cmp al, '?'
    je .ev_status
    cmp al, '$'
    je .ev_pid
    cmp al, '#'                     ; $# $@ $* (function arguments)
    je .ev_special
    cmp al, '@'
    je .ev_special
    cmp al, '*'
    jne .ev_not_special
    mov al, '@'
.ev_special:
    inc r12
    lea rdi, [env_var_name]
    mov [rdi], al
    mov byte [rdi + 1], 0
    jmp .ev_lookup
.ev_not_special:
    cmp al, '('
    jne .ev_not_paren
    cmp byte [r12 + 1], '('
    jne .ev_subst
    lea rdi, [r12 + 2]
    call ash_expand_arith           ; result in ash_num_buf
    test rax, rax
    jz .ev_literal_dollar           ; no closing "))"
    mov r12, rax
    cmp byte [ash_arith_failed], 0
    je .ev_arith_ok
    mov byte [ev_overflow], 2       ; message printed: cancel the command
.ev_arith_ok:
    lea rcx, [ash_num_buf]
    jmp .ev_value
.ev_status:
    inc r12
    movsxd rsi, dword [last_exit_status]
    jmp .ev_emit_num
.ev_pid:
    inc r12
    mov eax, 39                     ; getpid
    syscall
    mov rsi, rax
.ev_emit_num:
    lea rdi, [ash_num_buf]
    call ash_fmt_int
    lea rcx, [ash_num_buf]
    jmp .ev_value

.ev_subst:
    ; $( ... ): r12 is at the '('
    lea rdi, [r12 + 1]
    call ev_find_close
    test rax, rax
    jz .ev_bad_subst
    mov [rbp - 48], rax             ; the closing ')'
    cmp byte [ev_mode], 0
    jne .ev_subst_verbatim
    lea rsi, [r12 + 1]
    mov rdx, rax
    xor ecx, ecx
    call ev_copy_inner
    lea rdi, [ev_inner_buf]
    call ev_capture
    mov rcx, rax
    mov r12, [rbp - 48]
    inc r12
    jmp .ev_value
.ev_subst_verbatim:
    lea rsi, [r12 - 1]              ; from the '$'
    mov rdx, [rbp - 48]
    inc rdx
    mov r12, rdx
    jmp .ev_verbatim

.ev_btick:
    ; `...`: r12 is at the opening backtick
    lea rdi, [r12 + 1]
    call ev_find_btick
    test rax, rax
    jz .ev_bad_subst
    mov [rbp - 48], rax
    cmp byte [ev_mode], 0
    jne .ev_btick_verbatim
    lea rsi, [r12 + 1]
    mov rdx, rax
    mov ecx, 1
    call ev_copy_inner
    lea rdi, [ev_inner_buf]
    call ev_capture
    mov rcx, rax
    mov r12, [rbp - 48]
    inc r12
    jmp .ev_value
.ev_btick_verbatim:
    mov rsi, r12
    mov rdx, [rbp - 48]
    inc rdx
    mov r12, rdx
    ; falls through

.ev_verbatim:
    ; copy [rsi, rdx) as it is, doubling EV_MARK
.ev_vb_loop:
    cmp rsi, rdx
    jae .ev_vb_done
    movzx eax, byte [rsi]
    cmp al, EV_MARK
    jne .ev_vb_put
    lea rcx, [r13 + 1]
    cmp rcx, r14
    jae .ev_over
    mov byte [r13], EV_MARK
    inc r13
.ev_vb_put:
    cmp r13, r14
    jae .ev_over
    mov [r13], al
    inc r13
    inc rsi
    jmp .ev_vb_loop
.ev_vb_done:
    xor r15d, r15d
    jmp .ev_loop

.ev_not_paren:
    ; Check for ${VAR} form
    cmp al, '{'
    je .ev_brace

    ; $VAR form: read alphanumeric/underscore chars
    lea rdi, [env_var_name]
    xor r15d, r15d                  ; length of var name
    xor edx, edx                    ; characters taken from the source
.ev_read_name:
    movzx eax, byte [r12 + rdx]
    ; Check if alphanumeric or underscore
    cmp al, '_'
    je .ev_name_ok
    cmp al, 'A'
    jb .ev_name_check_digit         ; digits sort below 'A'
    cmp al, 'Z'
    jbe .ev_name_ok
    cmp al, 'a'
    jb .ev_name_check_digit
    cmp al, 'z'
    jbe .ev_name_ok
    jmp .ev_name_end
.ev_name_check_digit:
    cmp al, '0'
    jb .ev_name_end
    cmp al, '9'
    ja .ev_name_end
.ev_name_ok:
    cmp r15d, 255                   ; longer names cannot exist: read the rest, keep nothing
    jae .ev_name_skip
    mov [rdi + r15], al
    inc r15d
.ev_name_skip:
    inc edx
    jmp .ev_read_name

.ev_name_end:
    test edx, edx
    jz .ev_literal_dollar           ; no name chars after $, copy literal $
    cmp r15d, 255
    jb .ev_name_term
    mov r15d, 0                     ; over-long name: look up the empty name
.ev_name_term:
    mov byte [rdi + r15], 0
    add r12, rdx                    ; advance source past the name
    xor r15d, r15d
    jmp .ev_lookup

.ev_brace:
    inc r12                         ; skip '{'
    xor edx, edx
.ev_brace_find:
    movzx eax, byte [r12 + rdx]
    test al, al
    jz .ev_literal_dollar_brace     ; unterminated ${
    cmp al, '}'
    je .ev_brace_found
    inc edx
    jmp .ev_brace_find
.ev_brace_found:
    test edx, edx
    jz .ev_brace_empty
    ; only plain names are supported
    lea rdi, [env_var_name]
    xor ecx, ecx
.ev_brace_chk:
    cmp ecx, edx
    jae .ev_brace_ok
    movzx eax, byte [r12 + rcx]
    cmp al, '_'
    je .ev_brace_char
    cmp al, '0'
    jb .ev_bad_brace
    cmp al, '9'
    jbe .ev_brace_char
    cmp al, 'A'
    jb .ev_bad_brace
    cmp al, 'Z'
    jbe .ev_brace_char
    cmp al, 'a'
    jb .ev_bad_brace
    cmp al, 'z'
    ja .ev_bad_brace
.ev_brace_char:
    cmp ecx, 255
    jae .ev_brace_next
    mov [rdi + rcx], al
.ev_brace_next:
    inc ecx
    jmp .ev_brace_chk
.ev_brace_ok:
    mov ecx, edx
    cmp ecx, 255
    jb .ev_brace_term
    xor ecx, ecx
.ev_brace_term:
    mov byte [rdi + rcx], 0
    lea r12, [r12 + rdx + 1]        ; past the '}'
    jmp .ev_lookup

.ev_brace_empty:
    ; ${} -- just skip it
    inc r12                         ; skip '}'
    jmp .ev_loop

.ev_bad_brace:
    lea rdi, [ev_e_brace]
    call ash_write_err
    mov byte [ev_overflow], 2
    jmp .ev_fail

.ev_bad_subst:
    lea rdi, [ev_e_subst]
    call ash_write_err
    mov byte [ev_overflow], 2
    jmp .ev_fail

.ev_literal_dollar:
    cmp r13, r14
    jae .ev_over
    mov byte [r13], '$'
    inc r13
    xor r15d, r15d
    jmp .ev_loop

.ev_literal_dollar_brace:
    ; Unterminated ${ -- copy literal "${" and continue
    lea rax, [r13 + 1]
    cmp rax, r14
    jae .ev_over
    mov byte [r13], '$'
    mov byte [r13 + 1], '{'
    add r13, 2
    xor r15d, r15d
    jmp .ev_loop

.ev_lookup:
    ; env_var_name holds the variable name, look it up
    lea rdi, [env_var_name]
    call getenv_internal
    xor r15d, r15d
    test rax, rax
    jz .ev_loop                     ; variable not found, output nothing
    mov rcx, rax

.ev_value:
    ; rcx = value. When a redirection operator follows, digits are marked
    ; too, so "echo $N>f" is not read as the descriptor redirection "2>f".
    xor edx, edx
    cmp byte [r12], '>'
    je .ev_value_op
    cmp byte [r12], '<'
    jne .ev_value_flag
.ev_value_op:
    mov edx, 1
.ev_value_flag:
    mov [rbp - 56], edx
.ev_cpval:
    ; rcx = value. It is data: mark whatever could read as syntax.
    movzx eax, byte [rcx]
    test al, al
    jz .ev_cpval_end
    cmp al, ' '
    je .ev_cp_plain
    cmp al, 9
    je .ev_cp_plain
    cmp al, 10
    jne .ev_cp_chk
    test ebx, ebx
    jnz .ev_cp_mark                 ; inside quotes a newline is data
    mov al, ' '                     ; otherwise it separates words
    jmp .ev_cp_plain
.ev_cp_chk:
    cmp al, EV_MARK
    je .ev_cp_mark
    cmp al, '0'
    jb .ev_cp_special
    cmp al, '9'
    ja .ev_cp_special
    cmp dword [rbp - 56], 0
    jne .ev_cp_mark
.ev_cp_special:
    call ev_is_special
    test edx, edx
    jz .ev_cp_plain
.ev_cp_mark:
    lea rdx, [r13 + 1]
    cmp rdx, r14
    jae .ev_over
    mov byte [r13], EV_MARK
    mov [r13 + 1], al
    add r13, 2
    inc rcx
    jmp .ev_cpval
.ev_cp_plain:
    cmp r13, r14
    jae .ev_over
    mov [r13], al
    inc r13
    inc rcx
    jmp .ev_cpval
.ev_cpval_end:
    xor r15d, r15d
    jmp .ev_loop

.ev_over:
    mov byte [ev_overflow], 1

.ev_done:
    mov byte [r13], 0
    cmp byte [ev_overflow], 0
    jne .ev_fail

    ; Copy result back to input_buf
    lea rdi, [input_buf]
    lea rsi, [env_expand_buf]
    call str_copy
    xor eax, eax
    jmp .ev_ret

.ev_fail:
    cmp byte [ev_overflow], 1
    jne .ev_fail_status
    lea rdi, [ev_e_long]
    call ash_write_err
.ev_fail_status:
    mov dword [last_exit_status], 1
    mov eax, 1
.ev_ret:
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ev_is_special(al) -> edx = 1 if the byte is in ev_special_chars.
; Clobbers rsi and r8b only.
ev_is_special:
    lea rsi, [ev_special_chars]
.is_loop:
    mov r8b, [rsi]
    test r8b, r8b
    jz .is_no
    cmp r8b, al
    je .is_yes
    inc rsi
    jmp .is_loop
.is_yes:
    mov edx, 1
    ret
.is_no:
    xor edx, edx
    ret

; ev_find_close(rdi = text after "$(") -> rax = the matching ')' or 0.
; Quotes and nested parentheses are skipped.
ev_find_close:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 8
    xor ebx, ebx                    ; open parentheses
.fc_loop:
    movzx eax, byte [rdi]
    test al, al
    jz .fc_fail
    cmp al, '\'
    je .fc_bs
    cmp al, 0x27
    je .fc_sq
    cmp al, '"'
    je .fc_dq
    cmp al, '('
    je .fc_lp
    cmp al, ')'
    je .fc_rp
.fc_next:
    inc rdi
    jmp .fc_loop
.fc_bs:
    cmp byte [rdi + 1], 0
    je .fc_fail
    add rdi, 2
    jmp .fc_loop
.fc_sq:
    inc rdi
.fc_sq_loop:
    movzx eax, byte [rdi]
    test al, al
    jz .fc_fail
    cmp al, 0x27
    je .fc_next
    inc rdi
    jmp .fc_sq_loop
.fc_dq:
    inc rdi
.fc_dq_loop:
    movzx eax, byte [rdi]
    test al, al
    jz .fc_fail
    cmp al, '"'
    je .fc_next
    cmp al, '\'
    jne .fc_dq_dollar
    cmp byte [rdi + 1], 0
    je .fc_fail
    add rdi, 2
    jmp .fc_dq_loop
.fc_dq_dollar:
    cmp al, '$'
    jne .fc_dq_next
    cmp byte [rdi + 1], '('
    jne .fc_dq_next
    add rdi, 2                      ; a nested $( ) inside the quotes
    call ev_find_close
    test rax, rax
    jz .fc_fail
    lea rdi, [rax + 1]
    jmp .fc_dq_loop
.fc_dq_next:
    inc rdi
    jmp .fc_dq_loop
.fc_lp:
    inc ebx
    jmp .fc_next
.fc_rp:
    test ebx, ebx
    jz .fc_found
    dec ebx
    jmp .fc_next
.fc_found:
    mov rax, rdi
    jmp .fc_ret
.fc_fail:
    xor eax, eax
.fc_ret:
    add rsp, 8
    pop rbx
    pop rbp
    ret

; ev_find_btick(rdi = text after a backtick) -> rax = the closing backtick or 0
ev_find_btick:
.fb_loop:
    movzx eax, byte [rdi]
    test al, al
    jz .fb_fail
    cmp al, '`'
    je .fb_found
    cmp al, '\'
    jne .fb_next
    cmp byte [rdi + 1], 0
    je .fb_fail
    inc rdi
.fb_next:
    inc rdi
    jmp .fb_loop
.fb_found:
    mov rax, rdi
    ret
.fb_fail:
    xor eax, eax
    ret

; ev_copy_inner(rsi = start, rdx = end, ecx = 1 to drop the backslash of
; \` \\ \$) copies the command text into ev_inner_buf.
ev_copy_inner:
    lea rdi, [ev_inner_buf]
    lea r8, [ev_inner_buf + MAX_INPUT - 1]
.ci_loop:
    cmp rsi, rdx
    jae .ci_done
    mov al, [rsi]
    test ecx, ecx
    jz .ci_store
    cmp al, '\'
    jne .ci_store
    mov r9b, [rsi + 1]
    cmp r9b, '`'
    je .ci_esc
    cmp r9b, '\'
    je .ci_esc
    cmp r9b, '$'
    jne .ci_store
.ci_esc:
    inc rsi
    mov al, r9b
.ci_store:
    cmp rdi, r8
    jae .ci_done
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .ci_loop
.ci_done:
    mov byte [rdi], 0
    ret

; ----------------------------------------------------------------------------
; ev_capture(rdi = command text) -> rax = its output in ev_cap_buf with the
; trailing newlines removed. Runs the text through the script engine in a
; forked child (so builtins, functions and pipelines all work and nothing it
; changes leaks back); stdout is a pipe, stdin is /dev/null. The status goes
; to ev_subst_status.
; ----------------------------------------------------------------------------
ev_capture:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 24                     ; [rsp] wait status, [rsp+8] pipe fds

    mov r12, rdi
    mov byte [ev_cap_buf], 0
    mov dword [ev_subst_status], 1

    lea rdi, [rsp + 8]
    mov esi, EV_O_CLOEXEC
    mov eax, EV_SYS_PIPE2
    syscall
    test rax, rax
    js .cap_ret

    mov eax, SYS_FORK
    syscall
    test rax, rax
    js .cap_fork_error
    jz .cap_child
    mov ebx, eax                    ; child pid

    mov edi, [rsp + 12]             ; the parent keeps only the read end
    mov eax, SYS_CLOSE
    syscall

    xor r13d, r13d                  ; bytes stored
.cap_read:
    mov edx, EV_CAP_SIZE - 1
    sub edx, r13d
    jz .cap_drain
    mov edi, [rsp + 8]
    lea rsi, [ev_cap_buf + r13]
    xor eax, eax                    ; SYS_READ
    syscall
    cmp rax, -4                     ; EINTR
    je .cap_read
    test rax, rax
    jle .cap_read_done
    add r13d, eax
    jmp .cap_read
.cap_drain:
    mov edi, [rsp + 8]
    lea rsi, [ev_inner_buf]         ; the command text is no longer needed
    mov edx, MAX_INPUT
    xor eax, eax
    syscall
    cmp rax, -4
    je .cap_drain
    test rax, rax
    jg .cap_drain
.cap_read_done:
    mov byte [ev_cap_buf + r13], 0
    mov edi, [rsp + 8]
    mov eax, SYS_CLOSE
    syscall

.cap_wait:
    mov dword [rsp], 0
    mov edi, ebx
    mov rsi, rsp
    xor edx, edx
    xor r10d, r10d
    mov eax, SYS_WAIT4
    syscall
    cmp rax, -4
    je .cap_wait
    mov eax, [rsp]
    mov edx, eax
    and edx, 0x7F
    jz .cap_exited
    lea eax, [rdx + 128]
    jmp .cap_status
.cap_exited:
    shr eax, 8
    and eax, 0xFF
.cap_status:
    mov [ev_subst_status], eax
.cap_strip:                         ; trailing newlines are not part of the value
    test r13d, r13d
    jz .cap_ret
    cmp byte [ev_cap_buf + r13 - 1], 10
    jne .cap_ret
    dec r13d
    mov byte [ev_cap_buf + r13], 0
    jmp .cap_strip

.cap_fork_error:
    mov edi, [rsp + 8]
    mov eax, SYS_CLOSE
    syscall
    mov edi, [rsp + 12]
    mov eax, SYS_CLOSE
    syscall
.cap_ret:
    lea rax, [ev_cap_buf]
    add rsp, 24
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

.cap_child:
    mov edi, [rsp + 12]
    mov esi, 1
    mov eax, SYS_DUP2
    syscall
    lea rdi, [ev_dev_null]
    xor esi, esi
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .cap_child_run
    mov edi, eax
    xor esi, esi
    mov eax, SYS_DUP2
    syscall
.cap_child_run:
    ; Output goes to a pipe: no terminal handling, no colour, and no
    ; redirection of the shell's own (it would bypass the pipe).
    mov byte [interactive_mode], 0
    mov byte [color_enabled], 0
    mov byte [redir_stdout_active], 0
    mov byte [redir_stdin_active], 0
    ; Its commands stay in the shell's process group, so a Ctrl+C at the
    ; keyboard reaches them (a group of their own would never get it).
    mov byte [jc_state], 2
    mov rdi, r12
    mov esi, 1
    call ash_eval
    mov edi, [last_exit_status]
    mov eax, SYS_EXIT
    syscall

; ============================================================================
; check_alias - If first word matches an alias, expand it.
; Returns eax = 0 no alias, 2 expanded, 1 (after a message) if the expansion
; would not fit.
; ============================================================================
check_alias:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 24

    mov eax, [alias_count]
    test eax, eax
    jz .ca_done

    lea rbx, [alias_table]
    xor r12d, r12d                  ; index

.ca_loop:
    cmp r12d, [alias_count]
    jge .ca_done

    ; Get length of alias name
    mov rdi, rbx
    call str_len
    mov r13d, eax                   ; r13d = alias name length

    ; Compare first r13d chars of input_buf with alias name
    lea rdi, [input_buf]
    mov rsi, rbx
    mov edx, r13d
    call str_icompare_n
    test eax, eax
    jnz .ca_next

    ; Check that input_buf[r13d] is space or null (exact word boundary)
    lea rax, [input_buf]
    movzx eax, byte [rax + r13]
    cmp al, ' '
    je .ca_match
    cmp al, 0
    je .ca_match

.ca_next:
    add rbx, ALIAS_ENTRY_SIZE
    inc r12d
    jmp .ca_loop

.ca_match:
    ; The expansion (alias value + rest of the line) has to fit a command
    ; line. If it does not, run nothing rather than a different command.
    lea rdi, [rbx + ALIAS_NAME_SIZE]
    call str_len
    mov r12d, eax
    lea rdi, [input_buf + r13]
    call str_len
    add eax, r12d
    cmp eax, MAX_INPUT - 1
    jae .ca_too_long

    ; Build expanded command: alias_value + rest of input
    lea rdi, [env_expand_buf]
    lea rsi, [rbx + ALIAS_NAME_SIZE]   ; alias value
    call str_copy

    ; Append rest of input_buf after the alias name
    lea rdi, [env_expand_buf]
    call str_len
    lea rdi, [env_expand_buf]
    add rdi, rax                    ; end of alias value
    lea rsi, [input_buf]
    add rsi, r13                    ; rest of input (including space)
    call str_copy

    ; Copy back to input_buf
    lea rdi, [input_buf]
    lea rsi, [env_expand_buf]
    call str_copy
    mov eax, 2                      ; expanded
    jmp .ca_ret

.ca_done:
    xor eax, eax
    jmp .ca_ret
.ca_too_long:
    lea rdi, [ev_e_alias]
    call ash_write_err
    mov dword [last_exit_status], 1
    mov eax, 1
.ca_ret:
    add rsp, 24
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; parse_redirection - Find redirections in input_buf without opening anything.
; Writes the line without them to cleaned_cmd_buf and the operations to
; redir_ops (16 bytes each: dword kind, dword fd, qword target). Kinds:
; 1 > file, 2 >> file, 3 < file, 4 duplicate (target = the fd number).
; Quotes, backslashes and marked bytes are respected; "N>" is recognised when
; the digits start a word, "&>file" means > file plus 2>&1.
; Returns eax = 1 if a redirection is malformed.
; ============================================================================
parse_redirection:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40

    mov dword [redir_nops], 0
    lea r12, [input_buf]           ; source pointer
    lea r13, [cleaned_cmd_buf]     ; destination (cleaned command)
    lea r14, [redir_pool]          ; next free byte for targets
    xor ebx, ebx                   ; quote state: 0 plain, 1 '...', 2 "..."
    xor r15d, r15d                 ; malformed flag
    mov [rbp - 48], r13            ; where the current word starts
    mov dword [rbp - 52], 0        ; digits so far, -1 once the word has anything else

.pr_loop:
    movzx eax, byte [r12]
    test al, al
    jz .pr_finish
    cmp al, EV_MARK
    je .pr_pair
    cmp ebx, 1
    je .pr_in_sq
    cmp al, '\'
    je .pr_pair
    cmp ebx, 2
    je .pr_in_dq
    cmp al, 0x27
    je .pr_open_sq
    cmp al, '"'
    je .pr_open_dq
    cmp al, ' '
    je .pr_blank
    cmp al, 9
    je .pr_blank
    cmp al, '>'
    je .pr_op
    cmp al, '<'
    je .pr_op
    cmp al, '&'
    jne .pr_char
    cmp byte [r12 + 1], '>'
    jne .pr_char
    cmp dword [rbp - 52], 0
    jne .pr_char
    ; "&>" and "&>>" at the start of a word
    inc r12
    mov dword [rbp - 56], 1         ; fd: stdout
    mov dword [rbp - 60], 1         ; also send stderr along
    jmp .pr_op_kind

.pr_char:
    mov ecx, [rbp - 52]
    cmp al, '0'
    jb .pr_not_digit
    cmp al, '9'
    ja .pr_not_digit
    test ecx, ecx
    js .pr_store
    inc ecx
    mov [rbp - 52], ecx
    jmp .pr_store
.pr_not_digit:
    mov dword [rbp - 52], -1
.pr_store:
    mov [r13], al
    inc r13
    inc r12
    jmp .pr_loop

.pr_pair:
    mov [r13], al
    inc r13
    inc r12
    movzx eax, byte [r12]
    test al, al
    jz .pr_finish
    mov [r13], al
    inc r13
    inc r12
    mov dword [rbp - 52], -1
    jmp .pr_loop

.pr_open_sq:
    mov ebx, 1
    mov dword [rbp - 52], -1
    jmp .pr_store
.pr_open_dq:
    mov ebx, 2
    mov dword [rbp - 52], -1
    jmp .pr_store
.pr_in_sq:
    cmp al, 0x27
    jne .pr_store
    xor ebx, ebx
    jmp .pr_store
.pr_in_dq:
    cmp al, '"'
    jne .pr_store
    xor ebx, ebx
    jmp .pr_store

.pr_blank:
    mov [r13], al
    inc r13
    inc r12
    mov [rbp - 48], r13
    mov dword [rbp - 52], 0
    jmp .pr_loop

.pr_op:
    ; fd: the digits that start this word, else 1 for '>' and 0 for '<'
    mov dword [rbp - 60], 0
    mov ecx, [rbp - 52]
    test ecx, ecx
    jle .pr_default_fd
    cmp ecx, 2
    ja .pr_fd_big
    mov rdx, [rbp - 48]
    movzx esi, byte [rdx]
    sub esi, '0'
    cmp ecx, 2
    jne .pr_fd_set
    imul esi, esi, 10
    movzx edi, byte [rdx + 1]
    sub edi, '0'
    add esi, edi
    jmp .pr_fd_set
.pr_fd_big:
    mov esi, 99                     ; a descriptor we do not handle
.pr_fd_set:
    mov [rbp - 56], esi
    mov r13, [rbp - 48]             ; the digits are not an argument
    jmp .pr_op_kind
.pr_default_fd:
    mov dword [rbp - 56], 1
    cmp al, '>'
    je .pr_op_kind
    mov dword [rbp - 56], 0

.pr_op_kind:
    ; r12 is at the '>' or '<'. [rbp-64]: kind 1 trunc, 2 append, 3 in, 4 dup
    movzx eax, byte [r12]
    inc r12
    cmp al, '<'
    je .pr_lt
    mov dword [rbp - 64], 1
    movzx eax, byte [r12]
    cmp al, '>'
    jne .pr_gt_2
    inc r12
    mov dword [rbp - 64], 2
    jmp .pr_after_op
.pr_gt_2:
    cmp al, '|'                     ; ">|" is just ">" here
    jne .pr_after_op
    inc r12
    jmp .pr_after_op
.pr_lt:
    mov dword [rbp - 64], 3
    movzx eax, byte [r12]
    cmp al, '<'                     ; here-documents are not supported
    je .pr_bad
    cmp al, '>'
    je .pr_bad
.pr_after_op:
    cmp byte [r12], '&'
    jne .pr_target
    cmp dword [rbp - 60], 0
    jne .pr_bad
    ; ">&N" / "<&N": duplicate a descriptor
    inc r12
    movzx eax, byte [r12]
    cmp al, '0'
    jb .pr_bad
    cmp al, '9'
    ja .pr_bad
    sub eax, '0'
    movzx ecx, byte [r12 + 1]
    cmp cl, '0'
    jb .pr_dup_end
    cmp cl, '9'
    ja .pr_dup_end
    imul eax, eax, 10               ; two digits: not one of ours
    sub ecx, '0'
    add eax, ecx
    inc r12
.pr_dup_end:
    inc r12
    movzx ecx, byte [r12]           ; the number must end the word
    test cl, cl
    jz .pr_dup_rec
    cmp cl, ' '
    je .pr_dup_rec
    cmp cl, 9
    je .pr_dup_rec
    jmp .pr_bad
.pr_dup_rec:
    mov [rbp - 72], rax
    mov dword [rbp - 64], 4
    call .pr_record_prep
    test rdx, rdx
    jz .pr_bad
    mov dword [rdx], 4
    mov eax, [rbp - 56]
    mov [rdx + 4], eax
    mov rax, [rbp - 72]
    mov [rdx + 8], rax
    jmp .pr_loop

.pr_target:
    ; Read the target word (quotes removed) into the pool
    mov rdi, r12
    call ash_skip_blanks
    mov r12, rax
    movzx eax, byte [r12]
    test al, al
    jz .pr_bad
    cmp al, '<'
    je .pr_bad
    cmp al, '>'
    je .pr_bad
    cmp al, '|'
    je .pr_bad
    cmp al, '&'
    je .pr_bad
    cmp al, ';'
    je .pr_bad
    lea rax, [redir_pool + 4096 - MAX_INPUT]
    cmp r14, rax
    ja .pr_bad
    mov rdi, r12
    mov rsi, r14
    mov edx, 1
    call ash_next_word
    test rax, rax
    jz .pr_bad
    mov r12, rax
    mov [rbp - 72], r14             ; the word
    mov r14, rdx
    call .pr_record_prep
    test rdx, rdx
    jz .pr_bad
    mov eax, [rbp - 64]
    mov [rdx], eax
    mov eax, [rbp - 56]
    mov [rdx + 4], eax
    mov rax, [rbp - 72]
    mov [rdx + 8], rax
    cmp dword [rbp - 60], 0
    je .pr_loop
    ; "&>file" also sends stderr to the same place
    call .pr_record_prep
    test rdx, rdx
    jz .pr_bad
    mov dword [rdx], 4
    mov dword [rdx + 4], 2
    mov qword [rdx + 8], 1
    jmp .pr_loop

.pr_bad:
    mov r15d, 1
    ; skip the rest of this word so the scan keeps moving
.pr_bad_skip:
    movzx eax, byte [r12]
    test al, al
    jz .pr_loop
    cmp al, ' '
    je .pr_loop
    inc r12
    jmp .pr_bad_skip

; next free slot of redir_ops in rdx (0 when full); counts it
.pr_record_prep:
    mov eax, [redir_nops]
    xor edx, edx
    cmp eax, 8
    jae .pr_rp_ret
    inc dword [redir_nops]
    shl eax, 4
    lea rdx, [redir_ops]
    add rdx, rax
.pr_rp_ret:
    ret

.pr_finish:
    ; Strip trailing blanks from the cleaned command
    lea rax, [cleaned_cmd_buf]
.pr_strip:
    cmp r13, rax
    je .pr_strip_done
    cmp byte [r13 - 1], ' '
    je .pr_strip_one
    cmp byte [r13 - 1], 9
    jne .pr_strip_done
.pr_strip_one:
    dec r13
    jmp .pr_strip
.pr_strip_done:
    mov byte [r13], 0
    mov eax, r15d

    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; apply_redirections(rdi = caller state block) -> eax = 0, or 1 after an error
; Carries out the operations of parse_redirection for a builtin, in order.
; stdout and stdin use the redir_* variables read by print_string_len; stderr
; is moved onto fd 2 itself, with the old fd 2 kept in redir_err_saved.
; The block (from dispatch_command) says which descriptors the caller owns.
; ============================================================================
apply_redirections:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8

    mov r15, rdi
    xor ebx, ebx
.ap_next:
    cmp ebx, [redir_nops]
    jae .ap_ok
    mov eax, ebx
    shl eax, 4
    lea r12, [redir_ops]
    add r12, rax
    mov r13d, [r12 + 4]             ; fd being redirected
    mov eax, [r12]
    cmp eax, 4
    je .ap_dup

    mov rdi, [r12 + 8]
    mov esi, O_WRONLY | O_CREAT | O_TRUNC | EV_O_CLOEXEC
    cmp eax, 1
    je .ap_open
    mov esi, O_WRONLY | O_CREAT | O_APPEND | EV_O_CLOEXEC
    cmp eax, 2
    je .ap_open
    mov esi, O_RDONLY | EV_O_CLOEXEC
.ap_open:
    mov edx, PERM_0644
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .ap_open_err
    mov r14d, eax
    cmp r13d, 1
    je .ap_set_out
    test r13d, r13d
    jz .ap_set_in
    cmp r13d, 2
    je .ap_set_err
    mov edi, r14d                   ; another descriptor: the file is only created
    mov eax, SYS_CLOSE
    syscall
    jmp .ap_adv

.ap_set_out:
    call .ap_close_out
    mov [redir_stdout_fd], r14d
    mov byte [redir_stdout_active], 1
    jmp .ap_adv
.ap_set_in:
    call .ap_close_in
    mov [redir_stdin_fd], r14d
    mov byte [redir_stdin_active], 1
    jmp .ap_adv
.ap_set_err:
    call .ap_save_err
    mov edi, r14d
    mov esi, 2
    mov eax, SYS_DUP2
    syscall
    mov edi, r14d
    mov eax, SYS_CLOSE
    syscall
    jmp .ap_adv

.ap_dup:
    mov r14d, [r12 + 8]             ; descriptor to copy
    cmp r13d, 1
    je .ap_dup_out
    cmp r13d, 2
    je .ap_dup_err
    jmp .ap_adv
.ap_dup_out:
    cmp r14d, 2                     ; ">&2": stdout becomes a copy of stderr
    jne .ap_adv
    mov edi, 2
    mov esi, EV_F_DUPFD_CLOEXEC
    mov edx, 10
    mov eax, EV_SYS_FCNTL
    syscall
    test rax, rax
    js .ap_adv
    mov r14d, eax
    jmp .ap_set_out
.ap_dup_err:
    cmp r14d, 1                     ; "2>&1": stderr follows stdout
    jne .ap_adv
    call .ap_save_err
    mov edi, 1
    cmp byte [redir_stdout_active], 0
    je .ap_dup_err_do
    mov edi, [redir_stdout_fd]
.ap_dup_err_do:
    mov esi, 2
    mov eax, SYS_DUP2
    syscall

.ap_adv:
    inc ebx
    jmp .ap_next

.ap_open_err:
    neg eax
    mov edi, eax
    mov rsi, [r12 + 8]
    call dc_redir_error
    mov dword [last_exit_status], 1
    mov eax, 1
    jmp .ap_ret
.ap_ok:
    xor eax, eax
.ap_ret:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; Close the current stdout redirect when this command opened it (the caller's
; own is left for the caller to close).
.ap_close_out:
    cmp byte [redir_stdout_active], 0
    je .ap_co_ret
    mov eax, [redir_stdout_fd]
    cmp dword [r15 + 16], 0
    je .ap_co_close
    cmp eax, [r15 + 12]
    je .ap_co_ret
.ap_co_close:
    mov edi, eax
    mov eax, SYS_CLOSE
    syscall
.ap_co_ret:
    ret
.ap_close_in:
    cmp byte [redir_stdin_active], 0
    je .ap_ci_ret
    mov eax, [redir_stdin_fd]
    cmp dword [r15 + 8], 0
    je .ap_ci_close
    cmp eax, [r15 + 4]
    je .ap_ci_ret
.ap_ci_close:
    mov edi, eax
    mov eax, SYS_CLOSE
    syscall
.ap_ci_ret:
    ret
; Keep the real stderr (once per command) before it is replaced
.ap_save_err:
    cmp dword [redir_err_saved], 0
    jne .ap_se_ret
    mov edi, 2
    mov esi, EV_F_DUPFD_CLOEXEC
    mov edx, 10
    mov eax, EV_SYS_FCNTL
    syscall
    test rax, rax
    js .ap_se_ret
    inc eax
    mov [redir_err_saved], eax
.ap_se_ret:
    ret

; dc_redir_error(edi = errno, rsi = file name) - "ash: FILE: reason" on stderr
dc_redir_error:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    mov ebx, edi
    mov r12, rsi
    lea rdi, [ev_msg_ash]
    call ash_write_err
    mov rdi, r12
    call ash_write_err
    lea rdi, [ev_msg_colon]
    call ash_write_err
    lea rsi, [errno_table]
.re_find:
    mov eax, [rsi]
    test eax, eax
    jz .re_generic
    cmp eax, ebx
    je .re_found
    add rsi, 12
    jmp .re_find
.re_found:
    mov rdi, [rsi + 4]
    jmp .re_print
.re_generic:
    lea rdi, [ev_msg_generic]
.re_print:
    call ash_write_err
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; restore_redirection(rdi = block saved by dispatch_command)
; Closes what this command opened and puts the caller's state back.
; ============================================================================
restore_redirection:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 8
    mov rbx, rdi

    cmp byte [redir_stdout_active], 0
    je .rr_stdin
    mov eax, [redir_stdout_fd]
    cmp dword [rbx + 16], 0
    je .rr_close_out
    cmp eax, [rbx + 12]
    je .rr_stdin
.rr_close_out:
    mov edi, eax
    mov eax, SYS_CLOSE
    syscall
.rr_stdin:
    cmp byte [redir_stdin_active], 0
    je .rr_restore
    mov eax, [redir_stdin_fd]
    cmp dword [rbx + 8], 0
    je .rr_close_in
    cmp eax, [rbx + 4]
    je .rr_restore
.rr_close_in:
    mov edi, eax
    mov eax, SYS_CLOSE
    syscall

.rr_restore:
    mov eax, [rbx + 16]
    mov [redir_stdout_active], al
    mov eax, [rbx + 12]
    mov [redir_stdout_fd], eax
    mov eax, [rbx + 8]
    mov [redir_stdin_active], al
    mov eax, [rbx + 4]
    mov [redir_stdin_fd], eax

    mov edi, [redir_err_saved]
    test edi, edi
    jz .rr_err_done
    dec edi                         ; put the real stderr back on fd 2
    mov esi, 2
    mov eax, SYS_DUP2
    syscall
    mov eax, [redir_err_saved]
    dec eax
    mov edi, eax
    mov eax, SYS_CLOSE
    syscall
.rr_err_done:
    mov eax, [rbx]
    mov [redir_err_saved], eax

    add rsp, 8
    pop rbx
    pop rbp
    ret


; ============================================================================
; Command Handlers - Each takes rdi = args pointer (or NULL/0)
; System V AMD64 calling convention
; ============================================================================

; ---------- handler_help ----------
handler_help:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    lea rdi, [help_msg]
    mov esi, help_len
    call print_string_len

    leave
    ret

; ---------- handler_cls ----------
handler_cls:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    call clear_screen

    leave
    ret

; ---------- handler_exit ----------
; dispatch_command clears last_exit_status before it runs a handler, so a bare
; "exit" takes the status the previous command left in prev_exit_status.
section .bss
    prev_exit_status    resd 1
section .text
handler_exit:
    sub rsp, 8                      ; keep the call below 16-byte aligned
    ; Restore terminal to cooked mode before exiting
    call restore_terminal

    ; exit with the status of the last command (like sh)
    mov edi, [prev_exit_status]
    mov eax, SYS_EXIT
    syscall
    ; Does not return

; ---------- handler_ver ----------
handler_ver:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    lea rdi, [ver_msg]
    mov esi, ver_len
    call print_string_len

    leave
    ret

; ---------- handler_about ----------
handler_about:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    lea rdi, [about_msg]
    mov esi, about_len
    call print_string_len

    leave
    ret

; ---------- handler_date ----------
; Format: Fri Apr  3 08:14:01 PM PKT 2026
handler_date:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 8

    ; Get current time
    xor edi, edi
    lea rsi, [timespec_buf]
    mov eax, SYS_CLOCK_GETTIME
    syscall

    ; Add the timezone offset ($ASM_TZ, $TZ or the build default)
    call resolve_tz_offset
    mov rdi, [timespec_buf]
    add rdi, rax
    call epoch_to_datetime

    ; Save 24h hour in rbx for AM/PM decision later
    movzx ebx, byte [time_hour]

    ; 1. Day-of-week name (e.g., "Fri")
    mov eax, [date_dow]
    shl eax, 2                      ; * 4 bytes per entry
    lea rdi, [dow_names]
    add rdi, rax
    call print_cstring

    ; Space
    lea rdi, [str_space]
    call print_cstring

    ; 2. Month name (e.g., "Apr") - date_month is 1-based
    movzx eax, word [date_month]
    dec eax                          ; 0-based index
    shl eax, 2                      ; * 4 bytes per entry
    lea rdi, [month_names]
    add rdi, rax
    call print_cstring

    ; 3. Day, space-padded (e.g., " 3" or "15")
    movzx eax, word [date_day]
    cmp eax, 10
    jge .hd_day_2digit
    ; Single digit: print 2 spaces then digit
    lea rdi, [str_space]
    call print_cstring
    lea rdi, [str_space]
    call print_cstring
    movzx eax, word [date_day]
    call print_number
    jmp .hd_day_done
.hd_day_2digit:
    lea rdi, [str_space]
    call print_cstring
    movzx eax, word [date_day]
    call print_number
.hd_day_done:

    ; Space before time
    lea rdi, [str_space]
    call print_cstring

    ; 4. Time in 12-hour format HH:MM:SS
    mov eax, ebx                    ; 24h hour
    test eax, eax
    jnz .hd_not_midnight
    mov eax, 12                     ; 0 -> 12 AM
    jmp .hd_print_hour
.hd_not_midnight:
    cmp eax, 12
    jle .hd_print_hour              ; 1-12 stay as-is
    sub eax, 12                     ; 13-23 -> 1-11
.hd_print_hour:
    call print_number_2digit

    lea rdi, [time_colon]
    call print_cstring

    movzx eax, byte [time_minute]
    call print_number_2digit

    lea rdi, [time_colon]
    call print_cstring

    movzx eax, byte [time_second]
    call print_number_2digit

    ; Space
    lea rdi, [str_space]
    call print_cstring

    ; 5. AM/PM
    cmp ebx, 12
    jge .hd_pm
    lea rdi, [str_am]
    jmp .hd_ampm_done
.hd_pm:
    lea rdi, [str_pm]
.hd_ampm_done:
    call print_cstring

    ; 6. Zone name (" PKT ", " +0530 ", " EST ")
    lea rdi, [str_space]
    call print_cstring
    lea rdi, [tz_label]
    call print_cstring
    lea rdi, [str_space]
    call print_cstring

    ; 7. Year
    mov eax, [date_year]
    call print_number

    call print_newline

    add rsp, 8
    pop rbx
    pop rbp
    ret

; ============================================================================
; resolve_tz_offset - return the offset from UTC in seconds (rax) and leave the
; zone name to print in tz_label. Looked up on every call, so changing the
; variables takes effect at once. Order:
;   $ASM_TZ  seconds east of UTC (signed integer, nothing else allowed);
;            the name shown is the offset as "+HHMM"
;   $TZ      "NAME", "NAMEh[:mm[:ss]]" or "<NAME>h[:mm[:ss]]" with the POSIX
;            sign (positive = west of UTC); zone files such as
;            "Europe/Paris" and daylight saving rules are not understood
;   build default (TZ_OFFSET_SECONDS, shown as TZ_NAME_DEFAULT)
; A value that cannot be read is skipped, never half-used.
; ============================================================================
%define TZ_MAX_SECONDS  93600           ; 26 hours, beyond any real zone
section .data
    tz_env_tz_str   db "TZ", 0
    tz_default_name db TZ_NAME_DEFAULT, 0
section .bss
    tz_label        resb 24
section .text
resolve_tz_offset:
    push rbp
    mov rbp, rsp
    push rbx
    push r12

    lea rdi, [tz_env_name_str]
    call getenv_internal
    test rax, rax
    jz .rto_posix
    mov rdi, rax
    call tz_parse_seconds
    test edx, edx
    jnz .rto_posix
    call tz_numeric_label
    jmp .rto_ret

.rto_posix:
    lea rdi, [tz_env_tz_str]
    call getenv_internal
    test rax, rax
    jz .rto_default
    mov rsi, rax
    lea rdi, [tz_label]
    xor ecx, ecx                    ; ecx = length of the name
    cmp byte [rsi], '<'
    je .rto_quoted

    ; Plain name: at least three letters
.rto_name:
    movzx eax, byte [rsi]
    mov edx, eax
    or edx, 0x20
    sub edx, 'a'
    cmp edx, 25
    ja .rto_name_end
    cmp ecx, 15
    jae .rto_default
    mov [rdi + rcx], al
    inc ecx
    inc rsi
    jmp .rto_name
.rto_name_end:
    cmp ecx, 3
    jb .rto_default
    jmp .rto_after_name

.rto_quoted:
    inc rsi
.rto_qloop:
    movzx eax, byte [rsi]
    cmp al, '>'
    je .rto_qend
    test al, al
    jz .rto_default
    cmp ecx, 15
    jae .rto_default
    mov [rdi + rcx], al
    inc ecx
    inc rsi
    jmp .rto_qloop
.rto_qend:
    inc rsi
    test ecx, ecx
    jz .rto_default

.rto_after_name:
    mov byte [rdi + rcx], 0
    xor eax, eax
    cmp byte [rsi], 0
    je .rto_ret                     ; a bare name means UTC
    mov r12d, 1                     ; r12d = 1 while the offset is west of UTC
    cmp byte [rsi], '-'
    jne .rto_notminus
    xor r12d, r12d
    inc rsi
    jmp .rto_hours
.rto_notminus:
    cmp byte [rsi], '+'
    jne .rto_hours
    inc rsi
.rto_hours:
    call tz_num2
    test edx, edx
    jnz .rto_default
    cmp eax, 24
    ja .rto_default
    imul ebx, eax, 3600
    cmp byte [rsi], ':'
    jne .rto_tail
    inc rsi
    call tz_num2
    test edx, edx
    jnz .rto_default
    cmp eax, 59
    ja .rto_default
    imul eax, eax, 60
    add ebx, eax
    cmp byte [rsi], ':'
    jne .rto_tail
    inc rsi
    call tz_num2
    test edx, edx
    jnz .rto_default
    cmp eax, 59
    ja .rto_default
    add ebx, eax
.rto_tail:
    cmp byte [rsi], 0
    jne .rto_default                ; daylight saving part or other text
    mov eax, ebx
    test r12d, r12d
    jz .rto_ret
    neg rax
    jmp .rto_ret

.rto_default:
    lea rdi, [tz_label]
    lea rsi, [tz_default_name]
    call str_copy
    mov rax, TZ_OFFSET_SECONDS

.rto_ret:
    pop r12
    pop rbx
    pop rbp
    ret

; tz_parse_seconds - rdi = text "[+-]digits". Returns rax = value and edx = 0,
; or edx = 1 when the text is empty, has other characters or is out of range.
tz_parse_seconds:
    xor eax, eax
    xor r8d, r8d                    ; r8d = 1 for a minus sign
    xor r9d, r9d                    ; r9d = digits seen
    cmp byte [rdi], '-'
    jne .tps_plus
    mov r8d, 1
    inc rdi
    jmp .tps_digit
.tps_plus:
    cmp byte [rdi], '+'
    jne .tps_digit
    inc rdi
.tps_digit:
    movzx ecx, byte [rdi]
    test ecx, ecx
    jz .tps_end
    sub ecx, '0'
    cmp ecx, 9
    ja .tps_bad
    inc r9d
    cmp r9d, 7
    ja .tps_bad
    imul rax, rax, 10
    add rax, rcx
    inc rdi
    jmp .tps_digit
.tps_end:
    test r9d, r9d
    jz .tps_bad
    cmp rax, TZ_MAX_SECONDS
    ja .tps_bad
    test r8d, r8d
    jz .tps_ok
    neg rax
.tps_ok:
    xor edx, edx
    ret
.tps_bad:
    mov edx, 1
    ret

; tz_num2 - rsi = text. Reads one or two digits into eax and advances rsi.
; edx = 0 on success, 1 if no digit is there. Changes only eax, ecx, edx, rsi.
tz_num2:
    movzx eax, byte [rsi]
    sub eax, '0'
    cmp eax, 9
    ja .tn_bad
    inc rsi
    movzx ecx, byte [rsi]
    sub ecx, '0'
    cmp ecx, 9
    ja .tn_ok
    imul eax, eax, 10
    add eax, ecx
    inc rsi
.tn_ok:
    xor edx, edx
    ret
.tn_bad:
    mov edx, 1
    ret

; tz_numeric_label - rax = offset in seconds (|rax| <= TZ_MAX_SECONDS). Writes
; "+HHMM" to tz_label and leaves rax unchanged.
tz_numeric_label:
    push rax
    lea rdi, [tz_label]
    mov byte [rdi], '+'
    test rax, rax
    jns .tnl_abs
    mov byte [rdi], '-'
    neg rax
.tnl_abs:
    xor edx, edx
    mov ecx, 3600
    div ecx                         ; eax = hours, edx = seconds left
    mov r8d, edx
    xor edx, edx
    mov ecx, 10
    div ecx
    add al, '0'
    mov [rdi + 1], al
    add dl, '0'
    mov [rdi + 2], dl
    mov eax, r8d
    xor edx, edx
    mov ecx, 60
    div ecx                         ; eax = minutes
    xor edx, edx
    mov ecx, 10
    div ecx
    add al, '0'
    mov [rdi + 3], al
    add dl, '0'
    mov [rdi + 4], dl
    mov byte [rdi + 5], 0
    pop rax
    ret

; ---------- handler_time ----------
; Same output as handler_date
handler_time:
    jmp handler_date

; ---------- handler_echo ----------
section .bss
    echo_word           resb MAX_INPUT
section .text
handler_echo:
    ; The words are unquoted like a shell would (rdi is the raw argument
    ; text) and joined with one blank. Flags: -n no newline, -e enable
    ; backslash escapes, -E disable them; they may be combined (-ne).
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14

    xor r12d, r12d                  ; bit 0 = -n, bit 1 = -e
    test rdi, rdi
    jz .he_print_nl
    mov rbx, rdi                    ; rbx = argument text

.he_flag_loop:
    mov rdi, rbx
    lea rsi, [echo_word]
    mov edx, 1
    call ash_next_word
    test rax, rax
    jz .he_print_nl                 ; no words
    lea rsi, [echo_word]
    cmp byte [rsi], '-'
    jne .he_words
    cmp byte [rsi + 1], 0
    je .he_words
    mov ecx, 1
.he_flag_chk:                       ; is every letter n, e or E?
    movzx edx, byte [rsi + rcx]
    test dl, dl
    jz .he_flag_apply
    cmp dl, 'n'
    je .he_flag_next
    cmp dl, 'e'
    je .he_flag_next
    cmp dl, 'E'
    jne .he_words
.he_flag_next:
    inc ecx
    jmp .he_flag_chk
.he_flag_apply:
    mov ecx, 1
.he_flag_set:
    movzx edx, byte [rsi + rcx]
    test dl, dl
    jz .he_flag_done
    cmp dl, 'n'
    jne .he_flag_e
    or r12d, 1
    jmp .he_flag_step
.he_flag_e:
    cmp dl, 'e'
    jne .he_flag_E
    or r12d, 2
    jmp .he_flag_step
.he_flag_E:
    and r12d, ~2
.he_flag_step:
    inc ecx
    jmp .he_flag_set
.he_flag_done:
    mov rbx, rax                    ; the flag word is consumed
    jmp .he_flag_loop

.he_words:
    lea r13, [env_expand_buf]       ; output cursor
    xor r14d, r14d                  ; 1 once a word was written
.he_word_loop:
    mov rdi, rbx
    lea rsi, [echo_word]
    mov edx, 1
    call ash_next_word
    test rax, rax
    jz .he_out_done
    mov rbx, rax
    test r14d, r14d
    jz .he_first
    mov byte [r13], ' '
    inc r13
.he_first:
    mov r14d, 1
    lea rsi, [echo_word]
.he_cp:
    movzx eax, byte [rsi]
    test al, al
    jz .he_word_loop
    cmp al, '\'
    jne .he_put
    test r12d, 2
    jz .he_put
    movzx ecx, byte [rsi + 1]
    cmp cl, 'n'
    mov al, 10
    je .he_esc2
    cmp cl, 't'
    mov al, 9
    je .he_esc2
    cmp cl, 'r'
    mov al, 13
    je .he_esc2
    cmp cl, 'a'
    mov al, 7
    je .he_esc2
    cmp cl, 'b'
    mov al, 8
    je .he_esc2
    cmp cl, 'e'
    mov al, 27
    je .he_esc2
    cmp cl, 'f'
    mov al, 12
    je .he_esc2
    cmp cl, 'v'
    mov al, 11
    je .he_esc2
    cmp cl, '\'
    mov al, '\'
    je .he_esc2
    cmp cl, 'c'                     ; \c stops all output, including the newline
    je .he_stop
    cmp cl, '0'
    je .he_octal
    cmp cl, 'x'
    je .he_hex
    mov al, '\'                     ; unknown escape: keep the backslash
    jmp .he_put
.he_esc2:
    add rsi, 2
    mov [r13], al
    inc r13
    jmp .he_cp
.he_put:
    mov [r13], al
    inc r13
    inc rsi
    jmp .he_cp

.he_octal:                          ; \0 and up to three more octal digits
    add rsi, 2
    xor eax, eax
    xor ecx, ecx
.he_oct_loop:
    cmp ecx, 3
    jae .he_num_store
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 7
    ja .he_num_store
    shl eax, 3
    add eax, edx
    inc rsi
    inc ecx
    jmp .he_oct_loop
.he_hex:                            ; \xH or \xHH
    xor eax, eax
    xor ecx, ecx
    lea rdi, [rsi + 2]
.he_hex_loop:
    cmp ecx, 2
    jae .he_hex_end
    movzx edx, byte [rdi]
    cmp dl, '0'
    jb .he_hex_end
    cmp dl, '9'
    jbe .he_hex_dig
    or dl, 0x20
    cmp dl, 'a'
    jb .he_hex_end
    cmp dl, 'f'
    ja .he_hex_end
    sub dl, 'a' - 10 - '0'
.he_hex_dig:
    sub dl, '0'
    shl eax, 4
    add eax, edx
    inc rdi
    inc ecx
    jmp .he_hex_loop
.he_hex_end:
    test ecx, ecx
    jnz .he_hex_ok
    mov al, '\'                     ; no digits: a plain "\x"
    jmp .he_put
.he_hex_ok:
    mov rsi, rdi
.he_num_store:
    mov [r13], al
    inc r13
    jmp .he_cp

.he_stop:
    or r12d, 1                      ; no newline either
.he_out_done:
    lea rdi, [env_expand_buf]
    mov rsi, r13
    sub rsi, rdi
    call print_string_len
    test r12d, 1
    jnz .he_done
.he_print_nl:
    test r12d, 1
    jnz .he_done
    call print_newline
.he_done:
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ---------- handler_title ----------
; Set terminal title using ANSI escape: "\e]0;<title>\a"
; Control bytes are dropped from the text, so a title taken from a variable
; or a file name cannot end the sequence early and smuggle in its own.
; Nothing is sent when output is not an interactive terminal.
section .bss
    title_buf       resb MAX_INPUT
section .text
handler_title:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 8

    test rdi, rdi
    jz .ht_done
    cmp byte [rdi], 0
    je .ht_done
    cmp byte [color_enabled], 0
    je .ht_done
    cmp byte [redir_stdout_active], 0
    jne .ht_done
    mov rbx, rdi

    ; Copy the printable bytes
    lea rdi, [title_buf]
.ht_copy:
    movzx eax, byte [rbx]
    inc rbx
    test al, al
    jz .ht_copied
    cmp al, 0x20
    jb .ht_copy
    cmp al, 0x7f
    je .ht_copy
    mov [rdi], al
    inc rdi
    jmp .ht_copy
.ht_copied:
    mov byte [rdi], 0

    ; Write "\e]0;"
    lea rdi, [ansi_title_pre]
    call print_cstring

    ; Write the title text
    lea rdi, [title_buf]
    call print_cstring

    ; Write BEL (0x07) -- the ansi_title_post should contain this
    lea rdi, [ansi_title_post]
    call print_cstring

.ht_done:
    add rsp, 8
    pop rbx
    pop rbp
    ret

; ---------- put_dec ----------
; Write eax (10..999) as decimal at [rdi] and advance rdi past it.
put_dec:
    cmp eax, 100
    jb .pd_two
    xor edx, edx
    mov ecx, 100
    div ecx                         ; eax = hundreds, edx = rest
    add al, '0'
    mov [rdi], al
    inc rdi
    mov eax, edx
.pd_two:
    xor edx, edx
    mov ecx, 10
    div ecx
    add al, '0'
    mov [rdi], al
    add dl, '0'
    mov [rdi + 1], dl
    add rdi, 2
    ret

section .data
    err_color_usage     db "Usage: color <bg><fg>  (two hex digits, e.g. color 0A)", 10, 0
    err_color_usage_len equ $ - err_color_usage - 1
section .text

; ---------- handler_color ----------
; Parse 2 hex digits (bg nibble, fg nibble in Windows scheme).
; Map through win_to_ansi table. Emit ANSI "\e[<fg>;<bg>m".
; Windows colors 0-7 = normal, 8-F = bright.
; ANSI: fg normal=30+n, fg bright=90+n, bg normal=40+n, bg bright=100+n.
handler_color:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 8

    test rdi, rdi
    jz .hco_done
    cmp byte [rdi], 0
    je .hco_done
    mov rbx, rdi

    ; Skip leading spaces
.hco_skip:
    cmp byte [rbx], ' '
    jne .hco_parse
    inc rbx
    jmp .hco_skip

.hco_parse:
    ; First hex digit = background (Windows convention)
    movzx eax, byte [rbx]
    call hex_to_int
    cmp eax, 15
    ja .hco_usage
    mov r12d, eax                   ; r12d = bg index (0-15)

    ; Second hex digit = foreground
    movzx eax, byte [rbx + 1]
    call hex_to_int
    cmp eax, 15
    ja .hco_usage
    mov r13d, eax                   ; r13d = fg index (0-15)

    ; Nothing but spaces may follow
    cmp byte [rbx + 2], 0
    je .hco_args_ok
    cmp byte [rbx + 2], ' '
    jne .hco_usage
.hco_args_ok:

    ; Colour escapes only make sense on an interactive colour terminal
    cmp byte [color_enabled], 0
    je .hco_done
    cmp byte [redir_stdout_active], 0
    jne .hco_done

    ; Convert fg index to ANSI code
    ; 0-7: normal (30 + win_to_ansi[n]), 8-15: bright (90 + win_to_ansi[n-8])
    lea rax, [win_to_ansi]
    mov ecx, 30
    cmp r13d, 8
    jb .hco_fg_set
    sub r13d, 8
    mov ecx, 90                     ; bright fg: 90-97
.hco_fg_set:
    movzx r13d, byte [rax + r13]
    add r13d, ecx

    ; Convert bg index to ANSI code
    ; 0-7: normal (40 + win_to_ansi[n]), 8-15: bright (100 + win_to_ansi[n-8])
    mov ecx, 40
    cmp r12d, 8
    jb .hco_bg_set
    sub r12d, 8
    mov ecx, 100                    ; bright bg: 100-107
.hco_bg_set:
    movzx r12d, byte [rax + r12]
    add r12d, ecx

    ; Build ANSI sequence: ESC [ <fg> ; <bg> m
    lea rdi, [num_buf]
    mov byte [rdi], 0x1B            ; ESC
    mov byte [rdi + 1], '['
    add rdi, 2
    mov eax, r13d
    call put_dec
    mov byte [rdi], ';'
    inc rdi
    mov eax, r12d
    call put_dec
    mov byte [rdi], 'm'
    inc rdi

    ; Print the ANSI sequence
    lea rsi, [num_buf]
    sub rdi, rsi
    mov esi, edi
    lea rdi, [num_buf]
    call print_string_len
    jmp .hco_done

.hco_usage:
    lea rdi, [err_color_usage]
    mov esi, err_color_usage_len
    call report_error_len

.hco_done:
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ---------- change_dir ----------
; chdir() that keeps `cd -`, $PWD and $OLDPWD in step.
; rdi = path. Returns eax = 0, or -errno. On success path_buf holds the new
; working directory. The old directory is recorded only after the chdir
; worked, so a failed cd leaves `cd -` pointing where it did.
change_dir:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 16

    mov rbx, rdi                    ; rbx = target

    ; Where are we now? Fails when the current directory was removed.
    lea rdi, [file_path_buf]
    mov esi, MAX_PATH_BUF
    mov eax, SYS_GETCWD
    syscall
    mov r12d, eax                   ; r12d <= 0: old directory unknown

    mov rdi, rbx
    mov eax, SYS_CHDIR
    syscall
    test rax, rax
    js .cdr_ret                     ; eax = -errno

    test r12d, r12d
    jle .cdr_pwd
    lea rdi, [prev_dir_buf]
    lea rsi, [file_path_buf]
    call str_copy
    mov byte [has_prev_dir], 1
    lea rdi, [str_oldpwd]
    lea rsi, [file_path_buf]
    call setenv_internal

.cdr_pwd:
    lea rdi, [path_buf]
    mov esi, MAX_PATH_BUF
    mov eax, SYS_GETCWD
    syscall
    test rax, rax
    jle .cdr_ok
    lea rdi, [str_pwd]
    lea rsi, [path_buf]
    call setenv_internal

.cdr_ok:
    xor eax, eax

.cdr_ret:
    add rsp, 16
    pop r12
    pop rbx
    pop rbp
    ret

section .data
    str_pwd         db "PWD", 0
    str_oldpwd      db "OLDPWD", 0
    err_no_cwd      db "Error: Could not determine the current directory.", 10, 0
    err_no_cwd_len  equ $ - err_no_cwd - 1
section .text

; ---------- handler_cd ----------
; Change directory. "cd -" goes to the previous directory, "cd" alone to $HOME.
handler_cd:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 16

    mov rbx, rdi                    ; rbx = args
    xor r12d, r12d                  ; r12d = 1 for "cd -" (shows the new dir)

    test rbx, rbx
    jz .hcd_home
    cmp byte [rbx], 0
    je .hcd_home

    ; Check for "cd -"
    cmp byte [rbx], '-'
    jne .hcd_change
    cmp byte [rbx + 1], 0
    jne .hcd_change

    ; cd - : go to previous directory
    cmp byte [has_prev_dir], 0
    je .hcd_no_prev
    lea rbx, [prev_dir_buf]
    mov r12d, 1

.hcd_change:
    mov rdi, rbx
    call change_dir
    test eax, eax
    js .hcd_err
    test r12d, r12d
    jz .hcd_done

    ; Print new directory
    lea rdi, [path_buf]
    call print_cstring
    call print_newline
    jmp .hcd_done

.hcd_no_prev:
    lea rdi, [err_no_prev_dir]
    mov esi, err_no_prev_len
    call report_error_len
    jmp .hcd_done

.hcd_err:
    lea rdi, [err_cd_msg]
    mov esi, err_cd_len
    call report_error_len
    jmp .hcd_done

.hcd_home:
    ; No args: go to $HOME (POSIX behaviour). Fall back to printing cwd if HOME unset.
    lea rdi, [str_home]
    call getenv_internal
    test rax, rax
    jz .hcd_print_cwd
    mov rbx, rax
    jmp .hcd_change

.hcd_print_cwd:
    lea rdi, [path_buf]
    mov esi, MAX_PATH_BUF
    mov eax, SYS_GETCWD
    syscall
    lea rdi, [path_buf]
    call print_cstring
    call print_newline

.hcd_done:
    add rsp, 16
    pop r12
    pop rbx
    pop rbp
    ret

; ---------- handler_pwd ----------
handler_pwd:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    ; getcwd(path_buf, MAX_PATH_BUF)
    lea rdi, [path_buf]
    mov esi, MAX_PATH_BUF
    mov eax, SYS_GETCWD
    syscall
    test rax, rax
    jle .hpw_err

    lea rdi, [path_buf]
    call print_cstring
    call print_newline
    jmp .hpw_done

.hpw_err:
    ; The directory was removed under us
    lea rdi, [err_no_cwd]
    mov esi, err_no_cwd_len
    call report_error_len

.hpw_done:
    leave
    ret

; ---------- passwd_find_uid ----------
; rdi = buffer holding /etc/passwd, esi = its length, edx = uid.
; Returns rax = login name (NUL-terminated in place) or 0. Registers only.
passwd_find_uid:
    mov esi, esi
    lea r8, [rdi + rsi]             ; end of data
    mov r9, rdi                     ; scan pointer
.pfu_line:
    cmp r9, r8
    jae .pfu_none
    mov r10, r9                     ; line start = name
.pfu_f1:
    cmp r9, r8
    jae .pfu_none
    movzx eax, byte [r9]
    cmp al, 10
    je .pfu_skip
    inc r9
    cmp al, ':'
    jne .pfu_f1
    lea r11, [r9 - 1]               ; the colon after the name
.pfu_f2:
    cmp r9, r8
    jae .pfu_none
    movzx eax, byte [r9]
    cmp al, 10
    je .pfu_skip
    inc r9
    cmp al, ':'
    jne .pfu_f2
    xor ecx, ecx                    ; uid value
    xor esi, esi                    ; digits seen
.pfu_f3:
    cmp r9, r8
    jae .pfu_none
    movzx eax, byte [r9]
    sub eax, '0'
    cmp eax, 9
    ja .pfu_f3_end
    imul ecx, ecx, 10
    add ecx, eax
    inc esi
    inc r9
    jmp .pfu_f3
.pfu_f3_end:
    test esi, esi
    jz .pfu_skip
    cmp byte [r9], ':'
    jne .pfu_skip
    cmp ecx, edx
    jne .pfu_skip
    mov byte [r11], 0
    mov rax, r10
    ret
.pfu_skip:
    cmp r9, r8
    jae .pfu_none
    cmp byte [r9], 10
    je .pfu_next
    inc r9
    jmp .pfu_skip
.pfu_next:
    inc r9
    jmp .pfu_line
.pfu_none:
    xor eax, eax
    ret

section .data
    passwd_path     db "/etc/passwd", 0
    err_whoami      db "whoami: cannot find a name for the current user.", 10, 0
section .bss
    passwd_buf      resb 32768
section .text

; ---------- handler_whoami ----------
; The name belonging to the effective uid (from /etc/passwd), so it cannot be
; faked with $USER. Falls back to $USER when the user is not listed.
handler_whoami:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 16

    mov eax, SYS_GETEUID
    syscall
    mov ebx, eax                    ; ebx = uid

    lea rdi, [passwd_path]
    xor esi, esi                    ; O_RDONLY
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .hw_env
    mov r12d, eax                   ; r12d = fd

    mov edi, r12d
    lea rsi, [passwd_buf]
    mov edx, 32768
    mov eax, SYS_READ
    syscall
    mov [rbp - 24], eax             ; bytes read (or -errno)

    mov edi, r12d
    mov eax, SYS_CLOSE
    syscall

    mov esi, [rbp - 24]
    test esi, esi
    jle .hw_env
    lea rdi, [passwd_buf]
    mov edx, ebx
    call passwd_find_uid
    test rax, rax
    jz .hw_env
    mov rdi, rax
    jmp .hw_print

.hw_env:
    lea rdi, [str_user]
    call getenv_internal
    test rax, rax
    jz .hw_err
    mov rdi, rax

.hw_print:
    call print_cstring
    call print_newline
    jmp .hw_done

.hw_err:
    lea rdi, [err_whoami]
    call report_error_cstr

.hw_done:
    add rsp, 16
    pop r12
    pop rbx
    pop rbp
    ret

; ---------- handler_dir ----------
; List directory contents using getdents64 + newfstatat for size/type info.
handler_dir:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40

    mov rbx, rdi                    ; rbx = optional path argument

    ; Pick the directory: the argument, else the current one
    test rbx, rbx
    jz .hd_use_cwd
    cmp byte [rbx], 0
    je .hd_use_cwd
    mov r15, rbx                    ; r15 = name shown in the header
    jmp .hd_open_dir

.hd_use_cwd:
    lea rdi, [path_buf]
    mov esi, MAX_PATH_BUF
    mov eax, SYS_GETCWD
    syscall
    lea r15, [path_buf]
    lea rbx, [str_dot]

.hd_open_dir:
    ; open(path, O_RDONLY | O_DIRECTORY, 0) before anything is printed, so a
    ; bad path gives an error and no header
    mov rdi, rbx
    mov esi, O_RDONLY | O_DIRECTORY
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .hd_open_fail
    mov r12d, eax                   ; r12d = directory fd

    call print_newline
    lea rdi, [dir_header]
    call print_cstring
    mov rdi, r15
    call print_cstring
    call print_newline
    call print_newline

.hd_read_batch:
    ; getdents64(fd, buf, bufsize)
    mov edi, r12d
    lea rsi, [dirent_buf]
    mov edx, DIRENT_BUF_SIZE
    mov eax, SYS_GETDENTS64
    syscall
    test rax, rax
    jle .hd_close                   ; done or error

    mov r13d, eax                   ; r13d = bytes returned
    xor r14d, r14d                  ; r14d = offset into buffer

.hd_entry:
    cmp r14d, r13d
    jge .hd_read_batch              ; process next batch

    lea rsi, [dirent_buf]
    add rsi, r14                    ; rsi = current dirent

    ; Get d_name
    lea rbx, [rsi + DIRENT_D_NAME]

    ; Skip "." and ".."
    cmp byte [rbx], '.'
    jne .hd_print_entry
    cmp byte [rbx + 1], 0
    je .hd_next_entry
    cmp byte [rbx + 1], '.'
    jne .hd_print_entry
    cmp byte [rbx + 2], 0
    je .hd_next_entry

.hd_print_entry:
    ; Use d_type to check if directory
    movzx eax, byte [rsi + DIRENT_D_TYPE]
    cmp al, DT_DIR
    je .hd_is_dir

    ; It's a file -- try to get size with newfstatat
    ; newfstatat(dirfd, pathname, statbuf, flags=0)
    mov edi, r12d
    mov rsi, rbx                    ; filename
    lea rdx, [stat_buf]
    xor r10d, r10d                  ; flags = 0
    mov eax, SYS_NEWFSTATAT
    syscall
    test rax, rax
    js .hd_size_unknown

    ; Print file size from stat_buf + STAT_ST_SIZE (8 bytes)
    mov rax, [stat_buf + STAT_ST_SIZE]
    call print_number_9pad
    lea rdi, [str_space]
    call print_cstring
    jmp .hd_print_name

.hd_size_unknown:
    ; Print placeholder
    mov eax, 0
    call print_number_9pad
    lea rdi, [str_space]
    call print_cstring
    jmp .hd_print_name

.hd_is_dir:
    lea rdi, [dir_tag]
    call print_cstring

.hd_print_name:
    mov rdi, rbx
    call print_cstring
    call print_newline

.hd_next_entry:
    ; Advance to next dirent using d_reclen
    lea rsi, [dirent_buf]
    add rsi, r14
    movzx eax, word [rsi + DIRENT_D_RECLEN]
    add r14d, eax
    jmp .hd_entry

.hd_close:
    mov edi, r12d
    mov eax, SYS_CLOSE
    syscall

.hd_done:
    call print_newline
    jmp .hd_exit

.hd_open_fail:
    neg eax
    mov edi, eax
    call print_last_error

.hd_exit:
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ---------- open_intr ----------
; open_intr(rdi = path, esi = flags) -> rax = fd or -errno (read-only opens)
; Like open(2), but a FIFO whose writer has not arrived yet does not hold the
; shell until one does: the wait is cut short by Ctrl+C (-EINTR).
%define O_NONBLOCK          0x800
%define F_SETFL             4
%define SYS_POLL            7
%define SYS_FCNTL           72

open_intr:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 16                     ; [rsp] = struct pollfd

    or esi, O_NONBLOCK
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .oi_ret
    mov ebx, eax
    mov edi, ebx
    lea rsi, [stat_buf]
    mov eax, SYS_FSTAT
    syscall
    test rax, rax
    js .oi_blocking
    mov eax, [stat_buf + STAT_ST_MODE]
    and eax, 0o170000
    cmp eax, 0o010000               ; S_IFIFO
    jne .oi_blocking
.oi_poll:
    cmp byte [ctrl_c_flag], 0
    jne .oi_intr
    mov [rsp], ebx                  ; pollfd.fd
    mov dword [rsp + 4], 1          ; events = POLLIN, revents = 0
    mov rdi, rsp
    mov esi, 1
    mov edx, 100                    ; look at Ctrl+C every 100 ms
    mov eax, SYS_POLL
    syscall
    test rax, rax
    jle .oi_poll                    ; timeout or a signal
.oi_blocking:
    mov edi, ebx                    ; reads and writes block again from here on
    mov esi, F_SETFL
    xor edx, edx
    mov eax, SYS_FCNTL
    syscall
    mov eax, ebx
    jmp .oi_ret
.oi_intr:
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall
    mov rax, -4                     ; -EINTR
.oi_ret:
    add rsp, 16
    pop rbx
    pop rbp
    ret

; ---------- handler_type ----------
; Display file contents (type FILE, cat FILE). `cat` with options, several
; files or no file at all is handed to /bin/cat, which handles stdin too.
IO_BUF_SIZE equ 65536           ; shared by type/cat and grep
section .bss
    io_buf          resb IO_BUF_SIZE
section .text
handler_type:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 16

    mov r12, rdi                    ; r12 = args (may be NULL)
    test r12, r12
    jz .hty_noargs
    cmp byte [r12], 0
    je .hty_noargs

    ; An option or "-" (stdin) is for /bin/cat
    cmp byte [r12], '-'
    jne .hty_open
    movzx eax, byte [input_buf]
    or al, 0x20
    cmp al, 'c'
    je .hty_external

.hty_open:
    ; open(filename, O_RDONLY, 0); Ctrl+C can end the wait on a FIFO
    mov rdi, r12
    mov esi, O_RDONLY
    call open_intr
    test rax, rax
    js .hty_err
    mov ebx, eax                    ; ebx = file descriptor

.hty_read:
    cmp byte [ctrl_c_flag], 0       ; ^C raised by SIGINT stops a long file
    jne .hty_interrupted

    ; read(fd, io_buf, IO_BUF_SIZE)
    mov edi, ebx
    lea rsi, [io_buf]
    mov edx, IO_BUF_SIZE
    mov eax, SYS_READ
    syscall
    test rax, rax
    jz .hty_close                   ; EOF
    js .hty_read_err

    ; Print what was read
    lea rdi, [io_buf]
    mov esi, eax
    call print_string_len
    jmp .hty_read

.hty_close:
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall
    jmp .hty_done

.hty_read_err:
    mov r12d, eax
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall
    mov edi, r12d
    neg edi                         ; EISDIR for a directory, EIO ...
    call print_last_error
    jmp .hty_done

.hty_interrupted:
    mov byte [ctrl_c_flag], 0
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall
    mov dword [last_exit_status], 130
    jmp .hty_done

.hty_noargs:
    ; Plain `cat` reads stdin; `type` needs a file
    movzx eax, byte [input_buf]
    or al, 0x20
    cmp al, 'c'
    je .hty_external
    lea rdi, [err_args_msg]
    mov esi, err_args_len
    call report_error_len
    jmp .hty_done

.hty_err:
    cmp byte [ctrl_c_flag], 0       ; Ctrl+C ended the open of a FIFO
    jne .hty_aborted
    ; "cat a b" is not a file called "a b": let /bin/cat take the list
    movzx eax, byte [input_buf]
    or al, 0x20
    cmp al, 'c'
    jne .hty_err_msg
    mov rdi, r12
.hty_find_space:
    movzx eax, byte [rdi]
    test al, al
    jz .hty_err_msg
    cmp al, ' '
    je .hty_external
    inc rdi
    jmp .hty_find_space
.hty_err_msg:
    lea rdi, [err_file_msg]
    mov esi, err_file_len
    call report_error_len
    jmp .hty_done

.hty_external:
    ; input_buf still holds the whole command line
    call stats_begin
    call execute_external
    call stats_end
    jmp .hty_done

.hty_aborted:
    mov byte [ctrl_c_flag], 0
    mov dword [last_exit_status], 130

.hty_done:
    add rsp, 16
    pop r12
    pop rbx
    pop rbp
    ret

; ---------- handler_mkdir ----------
handler_mkdir:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 16

    test rdi, rdi
    jz .hmk_err
    cmp byte [rdi], 0
    je .hmk_err

    mov rbx, rdi
    xor r12d, r12d                  ; 0 = single, 1 = -p recursive

    ; Detect leading -p
    cmp byte [rbx], '-'
    jne .hmk_go
    cmp byte [rbx + 1], 'p'
    jne .hmk_go
    cmp byte [rbx + 2], ' '
    je .hmk_flag_p
    cmp byte [rbx + 2], 0
    jne .hmk_go
.hmk_flag_p:
    mov r12d, 1
    add rbx, 2                      ; at the space, or at the end for a bare "-p"
    ; skip extra spaces
.hmk_skip_sp:
    cmp byte [rbx], ' '
    jne .hmk_go
    inc rbx
    jmp .hmk_skip_sp

.hmk_go:
    cmp byte [rbx], 0
    je .hmk_err
    test r12d, r12d
    jnz .hmk_recursive

    mov rdi, rbx
    mov esi, PERM_0755
    mov eax, SYS_MKDIR
    syscall
    test rax, rax
    jns .hmk_done
    neg eax
    mov edi, eax
    call print_last_error
    jmp .hmk_done

.hmk_recursive:
    ; Copy path into file_path_buf character by character, calling mkdir at
    ; every intermediate '/'. Index kept in r14 because syscall clobbers rcx;
    ; source pointer read directly from rbx because syscall clobbers rsi
    ; (as the 2nd syscall arg it gets overwritten with PERM_0755).
    lea r13, [file_path_buf]
    xor r14d, r14d
.hmk_copy:
    movzx eax, byte [rbx + r14]
    test al, al
    jz .hmk_finalize
    mov [r13 + r14], al
    cmp al, '/'
    jne .hmk_advance
    test r14d, r14d
    jz .hmk_advance                 ; skip leading '/'
    mov byte [r13 + r14], 0
    mov rdi, r13
    mov esi, PERM_0755
    mov eax, SYS_MKDIR
    syscall
    test rax, rax
    jns .hmk_restore_slash
    cmp eax, -17
    jne .hmk_rec_err
.hmk_restore_slash:
    mov byte [r13 + r14], '/'
.hmk_advance:
    inc r14d
    cmp r14d, MAX_PATH_BUF - 1
    jge .hmk_err
    jmp .hmk_copy

.hmk_finalize:
    mov byte [r13 + r14], 0
    test r14d, r14d
    jz .hmk_err
    mov rdi, r13
    mov esi, PERM_0755
    mov eax, SYS_MKDIR
    syscall
    test rax, rax
    jns .hmk_done
    cmp eax, -17
    jne .hmk_rec_err
    ; The name already exists: fine for -p only if it is a directory
    mov rdi, r13
    lea rsi, [stat_buf]
    mov eax, SYS_STAT
    syscall
    test rax, rax
    js .hmk_exists
    mov eax, [stat_buf + STAT_ST_MODE]
    and eax, S_IFMT
    cmp eax, S_IFDIR
    je .hmk_done
.hmk_exists:
    mov eax, -17
.hmk_rec_err:
    neg eax
    mov edi, eax
    call print_last_error
    jmp .hmk_done

.hmk_err:
    lea rdi, [err_args_msg]
    mov esi, err_args_len
    call report_error_len

.hmk_done:
    add rsp, 16
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ---------- handler_rmdir ----------
handler_rmdir:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    test rdi, rdi
    jz .hrd_err
    cmp byte [rdi], 0
    je .hrd_err

    ; rmdir(path)
    mov eax, SYS_RMDIR
    syscall
    test rax, rax
    jns .hrd_done

    neg eax
    mov edi, eax
    call print_last_error
    jmp .hrd_done

.hrd_err:
    lea rdi, [err_args_msg]
    mov esi, err_args_len
    call report_error_len

.hrd_done:
    leave
    ret

; ---------- handler_del ----------
handler_del:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    test rdi, rdi
    jz .hdl_err
    cmp byte [rdi], 0
    je .hdl_err

    ; unlink(path)
    mov eax, SYS_UNLINK
    syscall
    test rax, rax
    jns .hdl_done

    neg eax
    mov edi, eax
    call print_last_error
    mov dword [last_exit_status], 1
    jmp .hdl_done

.hdl_err:
    lea rdi, [err_args_msg]
    mov esi, err_args_len
    call print_string_len
    mov dword [last_exit_status], 1

.hdl_done:
    leave
    ret

; ---------- handler_copy ----------
; Plain copy without the undo bookkeeping (handler_copy_safe in
; ash/tools.asm is what the command table uses). Parses "src dst" and lets
; tl_copy_cmd do the work: it refuses folders and copying a file onto itself,
; keeps the source's permissions and reports every failure.
handler_copy:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 24

    test rdi, rdi
    jz .hcp_err

    call parse_two_args             ; rax=arg1(src), rdx=arg2(dst)
    test rax, rax
    jz .hcp_err
    test rdx, rdx
    jz .hcp_err

    mov rdi, rax
    mov rsi, rdx
    call tl_copy_cmd
    jmp .hcp_done
.hcp_err:
    lea rdi, [err_args_msg]
    mov esi, err_args_len
    call print_string_len
    mov dword [last_exit_status], 1

.hcp_done:
    add rsp, 24
    pop rbx
    pop rbp
    ret

; ---------- handler_move / handler_rename ----------
; Move/rename file using rename syscall
handler_move:
handler_rename:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 24

    test rdi, rdi
    jz .hmv_err

    call parse_two_args             ; rax=arg1(src), rdx=arg2(dst)
    test rax, rax
    jz .hmv_err
    test rdx, rdx
    jz .hmv_err

    ; rename(old_path, new_path)
    mov rdi, rax                    ; old path
    mov rsi, rdx                    ; new path
    mov eax, SYS_RENAME
    syscall
    test rax, rax
    jns .hmv_done

    neg eax
    mov edi, eax
    call print_last_error
    mov dword [last_exit_status], 1
    jmp .hmv_done

.hmv_err:
    lea rdi, [err_args_msg]
    mov esi, err_args_len
    call print_string_len
    mov dword [last_exit_status], 1

.hmv_done:
    add rsp, 24
    pop rbx
    pop rbp
    ret

; ---------- handler_set ----------
; View/set environment variables.
; No args: iterate saved_envp printing each entry.
; With "VAR=VAL": store in env_overlay.
; With "VAR": getenv_internal, print result.
handler_set:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 24

    mov rbx, rdi
    test rbx, rbx
    jz .hs_list
    cmp byte [rbx], 0
    je .hs_list

    ; Find '=' sign
    mov r12, rbx
.hs_find_eq:
    movzx eax, byte [r12]
    test al, al
    jz .hs_show                     ; no '=' found, show variable
    cmp al, '='
    je .hs_assign
    inc r12
    jmp .hs_find_eq

.hs_assign:
    ; Split at '='
    mov byte [r12], 0              ; null-terminate the name
    lea rsi, [r12 + 1]            ; rsi = value (after '=')
    mov rdi, rbx                   ; rdi = name
    ; If value is empty, still set it
    call setenv_internal
    jmp .hs_done

.hs_show:
    ; Show a single variable
    mov rdi, rbx
    call getenv_internal
    test rax, rax
    jz .hs_notfound

    ; Print "NAME=VALUE"
    mov r13, rax                    ; save value pointer
    mov rdi, rbx
    call print_cstring
    lea rdi, [str_equals]
    call print_cstring
    mov rdi, r13
    call print_cstring
    call print_newline
    jmp .hs_done

.hs_notfound:
    ; Variable not found -- "set: NAME: not defined" on stderr
    lea rdi, [err_set_pre]
    call report_error_cstr
    mov rdi, rbx
    call report_error_cstr
    lea rdi, [err_set_post]
    call report_error_cstr
    jmp .hs_done

.hs_list:
    ; Inherited variables first, minus the ones the overlay overrides or unset
    mov r12, [saved_envp]
    test r12, r12
    jz .hs_list_overlay

.hs_list_loop:
    mov rdi, [r12]                  ; load envp[i]
    test rdi, rdi
    jz .hs_list_overlay             ; end of envp array

    call env_is_shadowed
    test eax, eax
    jnz .hs_list_next
    mov rdi, [r12]
    call print_cstring
    call print_newline
.hs_list_next:
    add r12, 8                      ; next pointer
    jmp .hs_list_loop

.hs_list_overlay:
    ; Then the variables set in this shell
    lea r12, [env_overlay]
    xor r13d, r13d
.hs_overlay_loop:
    cmp r13d, [env_overlay_count]
    jge .hs_done
    mov rdi, r12
    call env_slot_exportable
    test eax, eax
    jz .hs_overlay_next
    mov rdi, r12
    call print_cstring
    call print_newline
.hs_overlay_next:
    add r12, ENV_OVERLAY_SIZE
    inc r13d
    jmp .hs_overlay_loop

.hs_done:
    add rsp, 24
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ---------- handler_pushd ----------
handler_pushd:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 24

    test rdi, rdi
    jz .hpd_err
    cmp byte [rdi], 0
    je .hpd_err
    mov rbx, rdi

    cmp dword [dir_stack_top], DIR_STACK_COUNT
    jge .hpd_full

    ; Save current directory onto stack
    mov eax, [dir_stack_top]
    imul eax, MAX_PATH_BUF
    lea rdi, [dir_stack]
    add rdi, rax
    mov esi, MAX_PATH_BUF
    mov eax, SYS_GETCWD
    syscall
    test rax, rax
    jle .hpd_nocwd                  ; current directory was removed

    inc dword [dir_stack_top]

    ; chdir to argument
    mov rdi, rbx
    call change_dir
    test eax, eax
    jns .hpd_done

    ; chdir failed -- undo stack push
    dec dword [dir_stack_top]
    lea rdi, [err_cd_msg]
    mov esi, err_cd_len
    call report_error_len
    jmp .hpd_done

.hpd_nocwd:
    lea rdi, [err_no_cwd]
    mov esi, err_no_cwd_len
    call report_error_len
    jmp .hpd_done

.hpd_full:
    lea rdi, [err_stack_full]
    mov esi, err_stack_f_len
    call report_error_len
    jmp .hpd_done

.hpd_err:
    lea rdi, [err_args_msg]
    mov esi, err_args_len
    call report_error_len

.hpd_done:
    add rsp, 24
    pop rbx
    pop rbp
    ret

; ---------- handler_popd ----------
handler_popd:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    cmp dword [dir_stack_top], 0
    je .hpo_empty

    dec dword [dir_stack_top]
    mov eax, [dir_stack_top]
    imul eax, MAX_PATH_BUF
    lea rdi, [dir_stack]
    add rdi, rax
    call change_dir
    test eax, eax
    jns .hpo_done

    ; The saved directory is gone. The entry stays dropped, otherwise popd
    ; would fail on it forever.
    lea rdi, [err_cd_msg]
    mov esi, err_cd_len
    call report_error_len
    jmp .hpo_done

.hpo_empty:
    lea rdi, [err_stack_empty]
    mov esi, err_stack_e_len
    call report_error_len

.hpo_done:
    leave
    ret

; ---------- alias_find ----------
; rdi = alias name. Returns rax = its table entry, or 0. Names compare
; without regard to case, as when an alias is looked up for a command.
alias_find:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 8

    mov r13, rdi
    lea rbx, [alias_table]
    xor r12d, r12d
.af_loop:
    cmp r12d, [alias_count]
    jge .af_none
    mov rdi, r13
    mov rsi, rbx
    call str_icompare
    test eax, eax
    jz .af_hit
    add rbx, ALIAS_ENTRY_SIZE
    inc r12d
    jmp .af_loop
.af_hit:
    mov rax, rbx
    jmp .af_ret
.af_none:
    xor eax, eax
.af_ret:
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

section .data
    err_alias_long      db "Error: alias name or command too long.", 10, 0
    err_alias_long_len  equ $ - err_alias_long - 1
    err_alias_pre       db "alias: ", 0
    err_alias_nf_post   db ": not found.", 10, 0
section .text

; ---------- handler_alias ----------
; Create/list aliases. Format: alias name=command
; "alias" lists them all, "alias name" shows one.
handler_alias:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 24

    mov rbx, rdi
    test rbx, rbx
    jz .hal_list
    cmp byte [rbx], 0
    je .hal_list

    ; Find '=' sign
    mov r12, rbx
.hal_find_eq:
    movzx eax, byte [r12]
    test al, al
    jz .hal_show                    ; no '=': show this alias
    cmp al, '='
    je .hal_set
    inc r12
    jmp .hal_find_eq

.hal_set:
    mov byte [r12], 0              ; null-terminate alias name
    lea r13, [r12 + 1]            ; r13 = alias command

    ; The name and the command each have a fixed-size field
    mov rdi, rbx
    call str_len
    test eax, eax
    jz .hal_too_long
    cmp eax, ALIAS_NAME_SIZE - 1
    ja .hal_too_long
    mov rdi, r13
    call str_len
    cmp eax, ALIAS_CMD_SIZE - 1
    ja .hal_too_long

    ; Redefining an existing alias needs no free slot
    mov rdi, rbx
    call alias_find
    test rax, rax
    jnz .hal_have_entry

    cmp dword [alias_count], ALIAS_COUNT
    jge .hal_full
    mov eax, [alias_count]
    imul eax, ALIAS_ENTRY_SIZE
    lea rdi, [alias_table]
    add rdi, rax
    mov r12, rdi
    mov rsi, rbx                   ; alias name
    call str_copy
    inc dword [alias_count]
    jmp .hal_value

.hal_have_entry:
    mov r12, rax
.hal_value:
    lea rdi, [r12 + ALIAS_NAME_SIZE]
    mov rsi, r13                   ; alias command
    call str_copy
    jmp .hal_done

.hal_show:
    mov rdi, rbx
    call alias_find
    test rax, rax
    jz .hal_not_found
    mov r12, rax
    jmp .hal_print_one

.hal_list:
    lea r12, [alias_table]
    xor ebx, ebx

.hal_list_loop:
    cmp ebx, [alias_count]
    jge .hal_done
    call .hal_print_entry
    add r12, ALIAS_ENTRY_SIZE
    inc ebx
    jmp .hal_list_loop

.hal_print_one:
    call .hal_print_entry
    jmp .hal_done

; prints "name=command" for the entry in r12
.hal_print_entry:
    sub rsp, 8
    mov rdi, r12                   ; alias name
    call print_cstring
    lea rdi, [str_equals]
    call print_cstring
    lea rdi, [r12 + ALIAS_NAME_SIZE] ; alias command
    call print_cstring
    call print_newline
    add rsp, 8
    ret

.hal_not_found:
    lea rdi, [err_alias_pre]
    call report_error_cstr
    mov rdi, rbx
    call report_error_cstr
    lea rdi, [err_alias_nf_post]
    call report_error_cstr
    jmp .hal_done

.hal_too_long:
    lea rdi, [err_alias_long]
    mov esi, err_alias_long_len
    call report_error_len
    jmp .hal_done

.hal_full:
    lea rdi, [err_alias_full]
    mov esi, err_alias_f_len
    call report_error_len

.hal_done:
    add rsp, 24
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; handler_unalias - Remove an alias by name; later entries move up so the
; slot is free again and the table never holds holes
; ============================================================================
handler_unalias:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    test rdi, rdi
    jz .hua_usage
    cmp byte [rdi], 0
    je .hua_usage

    call alias_find
    test rax, rax
    jz .hua_notfound

    mov rdi, rax                    ; entry being removed
    lea rsi, [rax + ALIAS_ENTRY_SIZE]
    mov eax, [alias_count]
    imul eax, ALIAS_ENTRY_SIZE
    lea rcx, [alias_table]
    add rcx, rax                    ; end of the used entries
    sub rcx, rsi                    ; bytes behind the removed entry
    rep movsb                       ; copies downwards, so overlap is fine
    dec dword [alias_count]
    jmp .hua_done

.hua_usage:
    lea rdi, [err_unalias_usage]
    mov esi, err_unalias_usage_len
    call report_error_len
    jmp .hua_done

.hua_notfound:
    lea rdi, [err_unalias_notfound]
    mov esi, err_unalias_notfound_len
    call report_error_len

.hua_done:
    leave
    ret

; ============================================================================
; execute_external - Run command via fork + execve("/bin/sh", "-c", cmd)
; Supports background execution with trailing '&'.
; Captures exit status in last_exit_status.
; ============================================================================
%define WNOHANG  1
%define WUNTRACED  2
%define WCONTINUED 8
%define EINTR      4
%define JOB_RUNNING 1                   ; job_state values
%define JOB_STOPPED 2

execute_external:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 32

    ; --- Check for trailing '&' to determine background mode ---
    ; r14b = 1 if background, 0 if foreground
    xor r14d, r14d                  ; assume foreground

    lea rdi, [input_buf]
    call str_len
    mov r13d, eax                   ; r13d = length

    test r13d, r13d
    jz .ee_error                    ; empty command

    ; A final '&' that is not quoted, escaped or marked as data
    lea rdi, [input_buf]
    call dc_trailing_amp
    test rax, rax
    jz .ee_no_bg

    ; Found '&' - enable background mode
    mov r14d, 1

    ; Remove the '&' and any trailing spaces before it
    lea rbx, [input_buf]
    mov byte [rax], 0
    mov rcx, rax
    sub rcx, rbx
.ee_trim_before_amp:
    dec ecx
    js .ee_bg_trimmed
    cmp byte [rbx + rcx], ' '
    jne .ee_bg_trimmed
    mov byte [rbx + rcx], 0
    jmp .ee_trim_before_amp

.ee_bg_trimmed:
.ee_no_bg:
    ; ASH: run foreground commands and pipelines natively when the
    ; parser understands the whole line; otherwise fall back to /bin/sh.
    test r14d, r14d
    jnz .ee_legacy
    lea rdi, [input_buf]
    call ash_parse
    test eax, eax
    jz .ee_legacy
    mov edi, eax
    call ash_run
    jmp .ee_done

.ee_legacy:
    ; A background job needs a free slot (finished jobs are dropped first).
    ; With none left it runs in the foreground instead, as a normal command.
    test r14d, r14d
    jz .ee_launch
    call job_slots_free
    test eax, eax
    jnz .ee_launch
    lea rdi, [jobs_full_msg]
    call print_cstring
    xor r14d, r14d

.ee_launch:
    ; Restore terminal to cooked mode so child process gets sane terminal
    call restore_terminal
    call jc_prepare                 ; the child starts its own process group

    ; fork()
    mov eax, SYS_FORK
    syscall
    test rax, rax
    js .ee_fork_error               ; fork failed
    jnz .ee_parent                  ; parent: rax = child PID

    ; ====== CHILD PROCESS ======
    mov edi, 1                      ; a foreground job takes the terminal
    test r14d, r14d
    jz .ee_child_group
    xor edi, edi
.ee_child_group:
    call jc_child_setup

    ; Handle redirection with dup2
    cmp byte [redir_stdout_active], 0
    je .ee_child_check_in
    ; dup2(redir_stdout_fd, 1) -- redirect stdout
    mov edi, [redir_stdout_fd]
    mov esi, 1                      ; stdout
    mov eax, SYS_DUP2
    syscall
    cmp edi, 1                      ; the original must not leak into the command
    je .ee_child_check_in
    mov eax, SYS_CLOSE
    syscall

.ee_child_check_in:
    cmp byte [redir_stdin_active], 0
    je .ee_child_exec
    ; dup2(redir_stdin_fd, 0) -- redirect stdin
    mov edi, [redir_stdin_fd]
    xor esi, esi                    ; stdin
    mov eax, SYS_DUP2
    syscall
    test edi, edi
    jz .ee_child_exec
    mov eax, SYS_CLOSE
    syscall

.ee_child_exec:
    ; Build argv: ["/bin/sh", "-c", input_buf, NULL]
    lea rax, [exec_argv]
    lea rcx, [sh_path]
    mov [rax], rcx                  ; argv[0] = "/bin/sh"
    lea rcx, [sh_dash_c]
    mov [rax + 8], rcx              ; argv[1] = "-c"
    lea rdi, [input_buf]            ; marked data bytes become plain text for sh
    call ash_sh_decode
    lea rcx, [exec_argv]
    mov [rcx + 16], rax             ; argv[2] = command string
    mov qword [rcx + 24], 0         ; argv[3] = NULL

    ; Build merged envp = overlay entries first, then inherited envp.
    ; Ensures 'set NAME=VAL' is visible to child processes (POSIX export).
    call build_merged_envp

    ; execve("/bin/sh", argv, merged_envp)
    lea rdi, [sh_path]
    lea rsi, [exec_argv]
    lea rdx, [merged_envp]
    mov eax, SYS_EXECVE
    syscall

    ; If execve returns, it failed -- exit child
    mov edi, 1
    mov eax, SYS_EXIT
    syscall

    ; ====== PARENT PROCESS ======
.ee_parent:
    mov ebx, eax                    ; ebx = child PID

    mov edi, ebx                    ; same grouping from this side, so the
    mov esi, 1                      ; child's group exists before anyone waits
    test r14d, r14d
    jz .ee_parent_group
    xor esi, esi
.ee_parent_group:
    call jc_parent_after_fork

    ; Check if background mode
    test r14d, r14d
    jnz .ee_background

    ; --- Foreground: wait for child ---
    ; Exit code, or 128 + signal when the child was killed (as ASH does)
    mov edi, ebx
    xor esi, esi
    call jc_wait_fg
    mov [last_exit_status], eax

.ee_restore:
    ; Re-enable raw mode for our terminal
    call setup_raw_mode
    jmp .ee_done

.ee_background:
    ; --- Background: store PID in job table, don't wait ---

    ; Re-enable raw mode first
    call setup_raw_mode

    mov edi, ebx
    mov esi, [jc_pgid]              ; 0 without job control
    mov edx, JOB_RUNNING
    xor ecx, ecx
    call job_add                    ; a slot was free before the fork

    ; Print "[bg] PID XXXX\n"
    lea rdi, [jobs_bg_started_msg]
    call print_cstring
    mov eax, ebx
    call print_number
    call print_newline

    jmp .ee_done

.ee_fork_error:
    lea rdi, [err_exec_msg]
    mov esi, err_exec_len
    call print_string_len
    mov dword [last_exit_status], 1

    ; Restore raw mode even on error
    call setup_raw_mode

.ee_error:
.ee_done:
    add rsp, 32
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; Utility Functions
; ============================================================================

; ---------- print_string_len ----------
; rdi = string pointer, esi = length
; Writes to stdout (fd 1) or redir_stdout_fd if redirection is active.
print_string_len:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    test esi, esi
    jz .psl_done

    ; A redraw collects its pieces and writes them once
    cmp byte [ob_active], 0
    jne .psl_collect

    ; Determine output fd
    cmp byte [redir_stdout_active], 0
    jne .psl_file

    ; write(1, buf, len)
    mov edx, esi                    ; length
    mov rsi, rdi                    ; buffer
    mov edi, 1                      ; stdout fd
    mov eax, SYS_WRITE
    syscall
    jmp .psl_done

.psl_file:
    ; write(redir_stdout_fd, buf, len)
    mov edx, esi
    mov rsi, rdi
    mov edi, [redir_stdout_fd]
    mov eax, SYS_WRITE
    syscall
    jmp .psl_done

.psl_collect:
    mov eax, [ob_len]
    mov ecx, eax
    add ecx, esi
    cmp ecx, OB_SIZE
    jbe .psl_append
    push rdi                        ; does not fit: write what is there first
    push rsi
    call ob_flush
    pop rsi
    pop rdi
    xor eax, eax
    cmp esi, OB_SIZE
    jbe .psl_append
    mov edx, esi                    ; larger than the whole buffer: direct
    mov rsi, rdi
    mov edi, 1
    mov eax, SYS_WRITE
    syscall
    jmp .psl_done
.psl_append:
    mov r8d, esi
    mov ecx, esi
    mov rdx, rdi
    lea rdi, [ob_buf]
    add rdi, rax
    mov rsi, rdx
    rep movsb
    add [ob_len], r8d
    jmp .psl_done

.psl_done:
    leave
    ret

; ---------- print_cstring ----------
; rdi = null-terminated string. Compute length, then call print_string_len.
print_cstring:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 8

    mov rbx, rdi                    ; save string pointer
    ; Compute length
    xor esi, esi
.pc_len:
    cmp byte [rbx + rsi], 0
    je .pc_print
    inc esi
    jmp .pc_len

.pc_print:
    mov rdi, rbx
    call print_string_len

    add rsp, 8
    pop rbx
    pop rbp
    ret

; ---------- print_newline ----------
; Print a single LF character (\n).
print_newline:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    lea rdi, [newline]
    mov esi, 1                      ; LF is 1 byte on Linux
    call print_string_len

    leave
    ret

; ---------- report_error_len ----------
; rdi = message, esi = length. Builtin error text goes to stderr, never into
; a redirected stdout file, and the command is marked as failed so that
; "cd /x && ..." and "if mkdir d; then" see the failure.
report_error_len:
    mov dword [last_exit_status], 1
    test esi, esi
    jz .rel_ret
    mov edx, esi
    mov rsi, rdi
    mov edi, STDERR_FD
    mov eax, SYS_WRITE
    syscall
.rel_ret:
    ret

; ---------- report_error_cstr ----------
; rdi = NUL-terminated message; same as report_error_len.
report_error_cstr:
    xor esi, esi
.rec_len:
    cmp byte [rdi + rsi], 0
    je report_error_len
    inc esi
    jmp .rec_len

; ---------- str_icompare ----------
; Case-insensitive full string compare.
; rdi = str1, rsi = str2. Returns: eax = 0 if equal, 1 if not.
str_icompare:
.sic_loop:
    movzx eax, byte [rdi]
    movzx ecx, byte [rsi]
    ; Lowercase str1 char
    cmp al, 'A'
    jb .sic_s1
    cmp al, 'Z'
    ja .sic_s1
    add al, 32
.sic_s1:
    ; Lowercase str2 char
    cmp cl, 'A'
    jb .sic_s2
    cmp cl, 'Z'
    ja .sic_s2
    add cl, 32
.sic_s2:
    cmp al, cl
    jne .sic_neq
    test al, al
    jz .sic_eq
    inc rdi
    inc rsi
    jmp .sic_loop
.sic_eq:
    xor eax, eax
    ret
.sic_neq:
    mov eax, 1
    ret

; ---------- str_icompare_n ----------
; Case-insensitive compare first N chars.
; rdi = str1, rsi = str2, edx = n. Returns: eax = 0 if equal, 1 if not.
str_icompare_n:
    mov ecx, edx                    ; ecx = counter
.sicn_loop:
    test ecx, ecx
    jz .sicn_eq
    movzx eax, byte [rdi]
    movzx r8d, byte [rsi]
    ; Lowercase both
    cmp al, 'A'
    jb .sicn_s1
    cmp al, 'Z'
    ja .sicn_s1
    add al, 32
.sicn_s1:
    cmp r8b, 'A'
    jb .sicn_s2
    cmp r8b, 'Z'
    ja .sicn_s2
    add r8b, 32
.sicn_s2:
    cmp al, r8b
    jne .sicn_neq
    inc rdi
    inc rsi
    dec ecx
    jmp .sicn_loop
.sicn_eq:
    xor eax, eax
    ret
.sicn_neq:
    mov eax, 1
    ret

; ---------- str_copy ----------
; Copy null-terminated string. rdi = dest, rsi = src.
str_copy:
.sc_loop:
    movzx eax, byte [rsi]
    mov [rdi], al
    test al, al
    jz .sc_done
    inc rdi
    inc rsi
    jmp .sc_loop
.sc_done:
    ret

; ---------- str_len ----------
; Get string length. rdi = string. Returns: eax = length.
str_len:
    xor eax, eax
.sl_loop:
    cmp byte [rdi + rax], 0
    je .sl_done
    inc eax
    jmp .sl_loop
.sl_done:
    ret

; ---------- skip_spaces ----------
; Skip leading spaces. rdi = string. Returns: rax = first non-space.
skip_spaces:
    mov rax, rdi
.ss_loop:
    cmp byte [rax], ' '
    jne .ss_done
    inc rax
    jmp .ss_loop
.ss_done:
    ret

; ---------- parse_two_args ----------
; Split an argument string into exactly two words, honouring quotes and
; backslashes (the one shared helper for builtins that take two names).
; In: rdi = argument text. Out: rax = first word, rdx = second word, both
; unquoted copies in static buffers (the text itself is left alone); rax =
; rdx = 0 unless there are exactly two words.
section .bss
    pta_a               resb MAX_INPUT
    pta_b               resb MAX_INPUT
section .text
parse_two_args:
    push rbp
    mov rbp, rsp
    test rdi, rdi
    jz .pta_fail
    lea rsi, [pta_a]
    mov edx, 1
    call ash_next_word
    test rax, rax
    jz .pta_fail
    mov rdi, rax
    lea rsi, [pta_b]
    mov edx, 1
    call ash_next_word
    test rax, rax
    jz .pta_fail
    mov rdi, rax
    call ash_skip_blanks
    cmp byte [rax], 0
    jne .pta_fail                   ; a third word
    lea rax, [pta_a]
    lea rdx, [pta_b]
    pop rbp
    ret
.pta_fail:
    xor eax, eax
    xor edx, edx
    pop rbp
    ret

; ---------- hex_to_int ----------
; Convert hex char in al to integer 0-15. Returns: eax = value, or -1 if the
; character is not a hex digit.
hex_to_int:
    cmp al, '0'
    jb .hti_bad
    cmp al, '9'
    jbe .hti_digit
    cmp al, 'A'
    jb .hti_bad
    cmp al, 'F'
    jbe .hti_upper
    cmp al, 'a'
    jb .hti_bad
    cmp al, 'f'
    jbe .hti_lower
.hti_bad:
    mov eax, -1
    ret
.hti_digit:
    sub al, '0'
    movzx eax, al
    ret
.hti_lower:
    sub al, 'a'
    add al, 10
    movzx eax, al
    ret
.hti_upper:
    sub al, 'A'
    add al, 10
    movzx eax, al
    ret

; ---------- print_number ----------
; Print unsigned integer in rax as decimal string. Callers that set eax
; get automatic zero-extension of the high 32 bits, so pre-existing call
; sites remain correct.
print_number:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 16

    lea r12, [num_buf + 31]
    mov byte [r12], 0
    mov rbx, 10
    test rax, rax
    jnz .pn_loop
    dec r12
    mov byte [r12], '0'
    jmp .pn_print
.pn_loop:
    test rax, rax
    jz .pn_print
    xor edx, edx
    div rbx                         ; 64-bit: rdx:rax / rbx
    add dl, '0'
    dec r12
    mov [r12], dl
    jmp .pn_loop
.pn_print:
    mov rdi, r12
    call print_cstring

    add rsp, 16
    pop r12
    pop rbx
    pop rbp
    ret

; ---------- print_number_2digit ----------
; Print eax as 2-digit decimal with leading zero.
print_number_2digit:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    mov ecx, 10
    xor edx, edx
    div ecx                         ; eax = tens, edx = ones
    add al, '0'
    lea rdi, [num_buf]
    mov [rdi], al
    add dl, '0'
    mov [rdi + 1], dl
    mov byte [rdi + 2], 0

    lea rdi, [num_buf]
    call print_cstring

    leave
    ret

; ---------- print_number_9pad ----------
; Print rax (64-bit unsigned) right-aligned. Field width is at least 9 chars
; (space-padded); numbers longer than 9 digits extend the field naturally.
print_number_9pad:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 16

    ; Convert number right-to-left starting from num_buf+23.
    lea r12, [num_buf + 23]
    mov byte [r12 + 1], 0           ; null-terminate at slot 24
    mov rbx, 10
    test rax, rax
    jnz .np9_loop
    mov byte [r12], '0'
    dec r12
    jmp .np9_pad
.np9_loop:
    test rax, rax
    jz .np9_pad
    xor edx, edx
    div rbx                         ; 64-bit divide: rdx:rax / rbx → rax, rem rdx
    add dl, '0'
    mov [r12], dl
    dec r12
    jmp .np9_loop
.np9_pad:
    ; Pad to at least 9 chars by filling spaces to the left.
    lea rcx, [num_buf + 14]         ; = num_buf + 23 - 9 = first of 9-char window
.np9_pad_loop:
    cmp r12, rcx
    jb .np9_print                   ; already wider than 9 chars
    mov byte [r12], ' '
    dec r12
    jmp .np9_pad_loop
.np9_print:
    lea rdi, [r12 + 1]
    call print_cstring

    add rsp, 16
    pop r12
    pop rbx
    pop rbp
    ret

; ---------- clear_screen ----------
; Write ANSI escape sequence to clear screen and home cursor.
clear_screen:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    lea rdi, [ansi_clear]
    call print_cstring

    leave
    ret

; ---------- print_ansi_num ----------
; Write the decimal digits of eax to stdout (helper for ANSI sequences).
; Does NOT go through print_string_len / redirection -- writes raw to fd 1.
print_ansi_num:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 16

    lea r12, [ansi_num_buf + 15]
    mov byte [r12], 0
    mov ebx, 10
    test eax, eax
    jnz .pan_loop
    dec r12
    mov byte [r12], '0'
    jmp .pan_print
.pan_loop:
    test eax, eax
    jz .pan_print
    xor edx, edx
    div ebx
    add dl, '0'
    dec r12
    mov [r12], dl
    jmp .pan_loop
.pan_print:
    ; Compute length
    lea rax, [ansi_num_buf + 15]
    sub rax, r12
    ; write(1, r12, len)
    mov edx, eax
    mov rsi, r12
    mov edi, 1
    mov eax, SYS_WRITE
    syscall

    add rsp, 16
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; Environment overlay
;
; Variables set by the shell live in env_overlay as "NAME=VALUE" slots in
; front of the inherited environment (saved_envp). Names are case-sensitive,
; as on any Unix. A slot whose first byte is NUL is free and gets reused.
; A bare "NAME" slot (no '=') hides an inherited variable that was unset.
; ============================================================================

section .data
    err_env_full    db "Error: environment full, variable not set.", 10, 0
    err_env_long    db "Error: variable too long, not set.", 10, 0
    err_env_name    db "Error: invalid variable name.", 10, 0
section .text

; ----------------------------------------------------------------------------
; env_find_slot - find NAME in the overlay (exact match)
; rdi = name, edx = name length. Returns rax = slot or 0. The slot holds
; either "NAME=VALUE" or a bare "NAME" (unset marker). Keeps rdi, rsi, rdx;
; clobbers rax, rcx, r8, r9.
; ----------------------------------------------------------------------------
env_find_slot:
    test edx, edx
    jz .efs_none
    lea r8, [env_overlay]
    mov r9d, [env_overlay_count]
.efs_slot:
    test r9d, r9d
    jz .efs_none
    xor ecx, ecx
.efs_cmp:
    cmp ecx, edx
    jae .efs_tail
    movzx eax, byte [r8 + rcx]
    cmp al, [rdi + rcx]
    jne .efs_next
    inc ecx
    jmp .efs_cmp
.efs_tail:
    movzx eax, byte [r8 + rdx]
    cmp al, '='
    je .efs_hit
    test al, al
    jz .efs_hit
.efs_next:
    add r8, ENV_OVERLAY_SIZE
    dec r9d
    jmp .efs_slot
.efs_hit:
    mov rax, r8
    ret
.efs_none:
    xor eax, eax
    ret

; ----------------------------------------------------------------------------
; env_find_inherited - find NAME in the inherited environment (exact match)
; rdi = name, edx = name length. Returns rax = "NAME=VALUE" entry or 0.
; Keeps rdi, rsi, rdx; clobbers rax, rcx, r8, r9.
; ----------------------------------------------------------------------------
env_find_inherited:
    test edx, edx
    jz .efi_none
    mov r8, [saved_envp]
    test r8, r8
    jz .efi_none
.efi_loop:
    mov r9, [r8]
    test r9, r9
    jz .efi_none
    xor ecx, ecx
.efi_cmp:
    cmp ecx, edx
    jae .efi_tail
    movzx eax, byte [r9 + rcx]
    cmp al, [rdi + rcx]
    jne .efi_next
    inc ecx
    jmp .efi_cmp
.efi_tail:
    cmp byte [r9 + rdx], '='
    je .efi_hit
.efi_next:
    add r8, 8
    jmp .efi_loop
.efi_hit:
    mov rax, r9
    ret
.efi_none:
    xor eax, eax
    ret

; ----------------------------------------------------------------------------
; env_name_len - length of the NAME part of a "NAME=VALUE" string
; rdi = entry. Returns edx. Clobbers rax.
; ----------------------------------------------------------------------------
env_name_len:
    xor edx, edx
.enl_loop:
    movzx eax, byte [rdi + rdx]
    test al, al
    jz .enl_done
    cmp al, '='
    je .enl_done
    inc edx
    jmp .enl_loop
.enl_done:
    ret

; ----------------------------------------------------------------------------
; env_alloc_slot - take a free overlay slot (reusing unset ones first)
; Returns rax = slot, or 0 when the table is full. Clobbers rcx.
; ----------------------------------------------------------------------------
env_alloc_slot:
    lea rax, [env_overlay]
    xor ecx, ecx
.eas_scan:
    cmp ecx, [env_overlay_count]
    jae .eas_append
    cmp byte [rax], 0
    je .eas_ret
    add rax, ENV_OVERLAY_SIZE
    inc ecx
    jmp .eas_scan
.eas_append:
    cmp ecx, ENV_OVERLAY_COUNT
    jae .eas_full
    inc dword [env_overlay_count]
.eas_ret:
    ret
.eas_full:
    xor eax, eax
    ret

; ----------------------------------------------------------------------------
; env_trim_count - forget free slots at the end of the overlay table
; Clobbers rax, rcx, rdx.
; ----------------------------------------------------------------------------
env_trim_count:
    mov eax, [env_overlay_count]
    lea rdx, [env_overlay]
.etc_loop:
    test eax, eax
    jz .etc_done
    lea ecx, [rax - 1]
    imul ecx, ecx, ENV_OVERLAY_SIZE
    cmp byte [rdx + rcx], 0
    jne .etc_done
    dec eax
    jmp .etc_loop
.etc_done:
    mov [env_overlay_count], eax
    ret

; ----------------------------------------------------------------------------
; env_is_shadowed - does the overlay hold an entry for this inherited string?
; rdi = "NAME=VALUE" inherited entry. Returns eax = 1 if so (a value or an
; unset marker), else 0. Keeps rdi; clobbers rax, rcx, rdx, r8, r9.
; ----------------------------------------------------------------------------
env_is_shadowed:
    sub rsp, 8                      ; keep the stack 16-byte aligned for the calls
    call env_name_len
    call env_find_slot
    add rsp, 8
    test rax, rax
    setnz al
    movzx eax, al
    ret

; ============================================================================
; getenv_internal - Look up environment variable
; rdi = variable name (null-terminated)
; Returns: rax = pointer to value (after '='), or 0 if not found.
; Searches env_overlay first, then saved_envp.
; ============================================================================
getenv_internal:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 8

    mov r12, rdi                    ; r12 = variable name to find
    call str_len
    mov r13d, eax                   ; r13d = name length

    mov rdi, r12
    mov edx, r13d
    call env_find_slot
    test rax, rax
    jz .ge_inherited
    cmp byte [rax + r13], '='
    jne .ge_not_found               ; unset marker: the inherited one is hidden
    lea rax, [rax + r13 + 1]
    jmp .ge_done

.ge_inherited:
    mov rdi, r12
    mov edx, r13d
    call env_find_inherited
    test rax, rax
    jz .ge_done
    lea rax, [rax + r13 + 1]
    jmp .ge_done

.ge_not_found:
    xor eax, eax

.ge_done:
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; setenv_internal - Set environment variable in overlay
; rdi = name, rsi = value
; Finds the existing entry, else the first free slot. Format: "KEY=VALUE\0".
; Returns eax = 0, or -1 after reporting why the variable could not be set
; (empty name, no room in the slot, table full). Callers may ignore it.
; ============================================================================
setenv_internal:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 16

    mov r12, rdi                    ; r12 = name
    mov r13, rsi                    ; r13 = value

    call str_len
    mov r14d, eax                   ; r14d = name length
    test r14d, r14d
    jz .se_bad_name

    mov rdi, r13
    call str_len
    lea eax, [rax + r14 + 2]        ; "NAME=" + value + NUL
    cmp eax, ENV_OVERLAY_SIZE
    ja .se_too_long

    mov rdi, r12
    mov edx, r14d
    call env_find_slot
    test rax, rax
    jnz .se_write
    call env_alloc_slot
    test rax, rax
    jz .se_full

.se_write:
    mov rdi, rax
    mov rsi, r12
    mov ecx, r14d
    rep movsb                       ; name
    mov byte [rdi], '='
    inc rdi
    mov rsi, r13
    call str_copy                   ; value and NUL
    xor eax, eax
    jmp .se_done

.se_bad_name:
    lea rdi, [err_env_name]
    jmp .se_fail
.se_too_long:
    lea rdi, [err_env_long]
    jmp .se_fail
.se_full:
    lea rdi, [err_env_full]
.se_fail:
    call report_error_cstr
    mov eax, -1

.se_done:
    add rsp, 16
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; unsetenv_internal - Remove a variable
; rdi = name. An overlay-only variable frees its slot. An inherited one stays
; in saved_envp, so a bare "NAME" marker takes the slot and hides it from
; getenv_internal, from `set` and from child processes.
; ============================================================================
unsetenv_internal:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8

    mov r12, rdi                    ; r12 = name
    call str_len
    mov r13d, eax                   ; r13d = name length
    test r13d, r13d
    jz .ue_done

    mov rdi, r12
    mov edx, r13d
    call env_find_inherited
    xor ebx, ebx
    test rax, rax
    setnz bl                        ; ebx = 1 when an inherited copy exists

    mov rdi, r12
    mov edx, r13d
    call env_find_slot
    test rax, rax
    jnz .ue_have_slot
    test ebx, ebx
    jz .ue_done                     ; not set anywhere
    cmp r13d, ENV_OVERLAY_SIZE - 1
    ja .ue_done
    call env_alloc_slot
    test rax, rax
    jz .ue_full
    jmp .ue_marker

.ue_have_slot:
    test ebx, ebx
    jnz .ue_marker
    mov byte [rax], 0               ; free the slot
    call env_trim_count
    jmp .ue_done

.ue_marker:
    mov rdi, rax
    mov rsi, r12
    call str_copy                   ; bare NAME
    jmp .ue_done

.ue_full:
    lea rdi, [err_env_full]
    call report_error_cstr

.ue_done:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret


; ============================================================================
; build_merged_envp - Fill merged_envp[] with overlay entries + inherited envp
; Overlay entries appear first so getenv() in children returns overridden
; values. Unset markers and names that are not identifiers (the positional
; parameters of script functions) are not exported, and an inherited variable
; that the overlay overrides or unsets is left out.
; ============================================================================
build_merged_envp:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 16

    lea r12, [merged_envp]
    xor r13d, r13d                  ; slot index

    ; --- Copy overlay entries ---
    mov r14d, [env_overlay_count]
    lea rbx, [env_overlay]
.bme_overlay_loop:
    test r14d, r14d
    jz .bme_inherited
    cmp r13d, MERGED_ENVP_MAX - 1
    jge .bme_terminate
    mov rdi, rbx
    call env_slot_exportable
    test eax, eax
    jz .bme_next_overlay
    mov [r12 + r13*8], rbx
    inc r13d
.bme_next_overlay:
    add rbx, ENV_OVERLAY_SIZE
    dec r14d
    jmp .bme_overlay_loop

.bme_inherited:
    ; --- Copy inherited envp pointers ---
    mov rbx, [saved_envp]
    test rbx, rbx
    jz .bme_terminate
.bme_env_loop:
    mov rdi, [rbx]
    test rdi, rdi
    jz .bme_terminate
    cmp r13d, MERGED_ENVP_MAX - 1
    jge .bme_terminate
    call env_is_shadowed
    test eax, eax
    jnz .bme_next_env
    mov rax, [rbx]
    mov [r12 + r13*8], rax
    inc r13d
.bme_next_env:
    add rbx, 8
    jmp .bme_env_loop

.bme_terminate:
    mov qword [r12 + r13*8], 0
    mov [merged_envp_count], r13d

    add rsp, 16
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ----------------------------------------------------------------------------
; env_slot_exportable - is this overlay slot a real "NAME=VALUE" variable?
; rdi = slot. Returns eax = 1 if the name starts with a letter or '_' and the
; entry has a '=', else 0. Free slots, unset markers and the "1", "#", "@"
; slots used for function arguments give 0. Clobbers rax, rcx.
; ----------------------------------------------------------------------------
env_slot_exportable:
    movzx eax, byte [rdi]
    cmp al, '_'
    je .ese_scan
    or al, 0x20
    cmp al, 'a'
    jb .ese_no
    cmp al, 'z'
    ja .ese_no
.ese_scan:
    xor ecx, ecx
.ese_loop:
    movzx eax, byte [rdi + rcx]
    test al, al
    jz .ese_no
    cmp al, '='
    je .ese_yes
    inc ecx
    jmp .ese_loop
.ese_yes:
    mov eax, 1
    ret
.ese_no:
    xor eax, eax
    ret

; ============================================================================
; handler_unset - Remove a variable (one set with `set`, or an inherited one)
; ============================================================================
handler_unset:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    test rdi, rdi
    jz .hun_usage
    cmp byte [rdi], 0
    je .hun_usage

    call unsetenv_internal
    jmp .hun_done

.hun_usage:
    lea rdi, [err_unset_usage]
    mov esi, err_unset_usage_len
    call report_error_len
.hun_done:
    leave
    ret

; ============================================================================
; read_script_file - Load a whole script file into script_file_buf
; rdi = path, esi = 1 to insist that the file belongs to the user or root and
; is not writable by others (used for autoexec.txt, which is found next to
; the program). Returns eax = number of bytes (the buffer is NUL-terminated),
; or a negative code: -1 cannot open, -2 larger than SCRIPT_FILE_MAX,
; -3 read error or NUL byte inside (the engine works on C strings, so the
; text after the NUL would silently not run), -4 not trusted.
; Nothing partial is ever returned, so a cut-off last line cannot run.
; ============================================================================
%define SCRIPT_FILE_MAX 65536
section .data
    err_autoexec_name db "autoexec.txt: ", 0
    err_asmrc_name  db ".asmrc: ", 0
    err_source_name db "source: ", 0
    err_script_big  db "file is larger than 65536 bytes, not run.", 10, 0
    err_script_bad  db "unreadable or contains NUL bytes, not run.", 10, 0
    err_script_trust db "ignored, it must belong to you and not be writable by others.", 10, 0
section .bss
    script_file_buf resb SCRIPT_FILE_MAX + 2
section .text
read_script_file:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 8

    mov r13d, esi                   ; r13d = trust check wanted
    mov esi, O_RDONLY
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .rsf_noopen
    mov ebx, eax                    ; ebx = fd

    test r13d, r13d
    jz .rsf_start

    ; fstat on the open file, so it cannot be swapped after the check
    mov edi, ebx
    lea rsi, [stat_buf]
    mov eax, SYS_FSTAT
    syscall
    test rax, rax
    js .rsf_untrusted
    test dword [stat_buf + STAT_ST_MODE], S_IWOTH
    jnz .rsf_untrusted
    mov eax, SYS_GETEUID
    syscall
    mov ecx, [stat_buf + STAT_ST_UID]
    test ecx, ecx
    jz .rsf_start                   ; root's file
    cmp ecx, eax
    jne .rsf_untrusted

.rsf_start:
    xor r12d, r12d                  ; r12d = bytes read so far
.rsf_read:
    mov edi, ebx
    lea rsi, [script_file_buf]
    add rsi, r12
    mov edx, SCRIPT_FILE_MAX + 1
    sub edx, r12d                   ; one byte more than allowed shows it is too big
    mov eax, SYS_READ
    syscall
    cmp rax, -4                     ; EINTR
    je .rsf_read
    test rax, rax
    js .rsf_error
    jz .rsf_eof
    add r12d, eax
    cmp r12d, SCRIPT_FILE_MAX
    jbe .rsf_read
    mov r12d, -2
    jmp .rsf_close

.rsf_eof:
    lea rdi, [script_file_buf]
    mov byte [rdi + r12], 0
    test r12d, r12d
    jz .rsf_close
    mov ecx, r12d
    xor eax, eax
    repne scasb                     ; any NUL inside the file?
    jne .rsf_close
    mov r12d, -3
    jmp .rsf_close

.rsf_error:
    mov r12d, -3
    jmp .rsf_close

.rsf_untrusted:
    mov r12d, -4

.rsf_close:
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall
    mov eax, r12d
    jmp .rsf_ret

.rsf_noopen:
    mov eax, -1

.rsf_ret:
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; report_script_error - rdi = "name: " prefix, esi = negative code from
; read_script_file. Says on stderr why the file was not run.
report_script_error:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 8

    mov ebx, esi
    call report_error_cstr
    lea rdi, [err_script_big]
    cmp ebx, -2
    je .rse_print
    lea rdi, [err_script_trust]
    cmp ebx, -4
    je .rse_print
    lea rdi, [err_script_bad]
.rse_print:
    call report_error_cstr

    add rsp, 8
    pop rbx
    pop rbp
    ret

; ============================================================================
; run_autoexec - Execute autoexec.txt from program directory if it exists
; Uses readlink("/proc/self/exe") to find the executable location.
; ============================================================================
run_autoexec:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 24

    ; readlink("/proc/self/exe", module_path, MAX_PATH_BUF)
    lea rdi, [autoexec_path]        ; reuse as temp for "/proc/self/exe"
    ; Build the string "/proc/self/exe" in autoexec_path
    mov byte [rdi],    '/'
    mov byte [rdi+1],  'p'
    mov byte [rdi+2],  'r'
    mov byte [rdi+3],  'o'
    mov byte [rdi+4],  'c'
    mov byte [rdi+5],  '/'
    mov byte [rdi+6],  's'
    mov byte [rdi+7],  'e'
    mov byte [rdi+8],  'l'
    mov byte [rdi+9],  'f'
    mov byte [rdi+10], '/'
    mov byte [rdi+11], 'e'
    mov byte [rdi+12], 'x'
    mov byte [rdi+13], 'e'
    mov byte [rdi+14], 0

    lea rdi, [autoexec_path]
    lea rsi, [module_path]
    mov edx, MAX_PATH_BUF - 16      ; room for "/autoexec.txt"
    mov eax, SYS_READLINK
    syscall
    test rax, rax
    js .ra_done                     ; readlink failed

    ; Null-terminate the result (readlink doesn't)
    lea rcx, [module_path]
    mov byte [rcx + rax], 0

    ; Strip the filename: find last '/'
    mov rdi, rcx
    call str_len
    lea rcx, [module_path]
.ra_strip:
    dec eax
    cmp eax, 0
    jl .ra_done
    cmp byte [rcx + rax], '/'
    je .ra_found
    jmp .ra_strip

.ra_found:
    ; Append "/autoexec.txt" after the last '/'
    lea rdx, [rcx + rax]           ; points to the last '/'
    lea rsi, [autoexec_name]       ; "/autoexec.txt\0"
.ra_app:
    movzx ebx, byte [rsi]
    mov [rdx], bl
    test bl, bl
    jz .ra_try_open
    inc rdx
    inc rsi
    jmp .ra_app

.ra_try_open:
    ; Read the whole file, unless somebody else could have written it
    lea rdi, [module_path]
    mov esi, 1                      ; check ownership
    call read_script_file
    cmp eax, -1
    je .ra_done                     ; no autoexec.txt
    test eax, eax
    js .ra_failed
    jz .ra_done                     ; empty file

    ; Run the whole file through the ASH script engine
    lea rdi, [script_file_buf]
    mov esi, 1
    call ash_eval
    jmp .ra_done

.ra_failed:
    mov esi, eax
    lea rdi, [err_autoexec_name]
    call report_script_error

.ra_done:
    add rsp, 24
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; load_history - Load command history from ~/.asm_history at startup
; Only the newest part of a big file is read (the last 256 KB, starting at
; the first complete line), so recent commands win. A file past
; HISTORY_FILE_MAX is rewritten with just the lines the ring holds.
; ============================================================================
%define HISTORY_FILE_MAX    131072
section .bss
    history_tmp_path    resb MAX_PATH_BUF
section .data
    str_tmp_suffix      db ".tmp", 0
section .text
load_history:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 32                     ; [rbp-48] read position, [rbp-56] mid-file flag

    ; Build path: $HOME/.asm_history
    lea rdi, [str_home]
    call getenv_internal
    test rax, rax
    jz .lh_done

    ; A $HOME too long for the path buffers means no history file
    mov r12, rax
    mov rdi, rax
    call str_len
    cmp eax, MAX_PATH_BUF - 32
    jae .lh_done

    ; Copy HOME to history_file_path
    lea rdi, [history_file_path]
    mov rsi, r12
.lh_copy_home:
    mov cl, [rsi]
    mov [rdi], cl
    test cl, cl
    jz .lh_append
    inc rdi
    inc rsi
    jmp .lh_copy_home
.lh_append:
    lea rsi, [str_asm_history]
.lh_copy_name:
    mov cl, [rsi]
    mov [rdi], cl
    test cl, cl
    jz .lh_open
    inc rdi
    inc rsi
    jmp .lh_copy_name

.lh_open:
    lea rdi, [history_file_path]
    mov esi, O_RDONLY
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .lh_done                     ; file doesn't exist, OK
    mov ebx, eax                    ; fd

    ; The commands typed here may hold passwords: keep the file private
    mov eax, 91                     ; SYS_fchmod
    mov edi, ebx
    mov esi, 0o600
    syscall

    ; Size of the file, then where to start reading
    mov eax, SYS_LSEEK
    mov edi, ebx
    xor esi, esi
    mov edx, 2                      ; SEEK_END
    syscall
    mov r14, rax                    ; r14 = file size
    mov qword [rbp - 56], 0         ; 1 = we start in the middle of the file
    xor r12d, r12d                  ; total bytes read
    test rax, rax
    jle .lh_read_done
    mov rsi, rax
    sub rsi, 262143                 ; room for the NUL
    ja .lh_mid
    xor esi, esi
    jmp .lh_seek
.lh_mid:
    mov qword [rbp - 56], 1
.lh_seek:
    mov eax, SYS_LSEEK
    mov edi, ebx
    xor edx, edx                    ; SEEK_SET
    syscall

    ; Read file in a loop into a 256KB buffer (handles multi-chunk files).
    lea rax, [history_read_buf]
    mov [rbp - 48], rax             ; current write position
.lh_read_chunk:
    mov eax, 262143
    sub eax, r12d
    jle .lh_read_done               ; buffer full
    mov edi, ebx
    mov rsi, [rbp - 48]
    mov edx, eax
    mov eax, SYS_READ
    syscall
    test rax, rax
    jle .lh_read_done               ; EOF or error
    add r12d, eax
    add [rbp - 48], rax
    jmp .lh_read_chunk
.lh_read_done:

    ; Close file
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall

    ; Null-terminate
    test r12d, r12d
    jle .lh_done
    lea rcx, [history_read_buf]
    mov byte [rcx + r12], 0

    ; Parse lines and add to history buffer
    lea r13, [history_read_buf]
    cmp qword [rbp - 56], 0
    je .lh_line
.lh_skip_partial:                   ; the first line is cut off: drop it
    movzx eax, byte [r13]
    test al, al
    jz .lh_trim
    inc r13
    cmp al, 10
    jne .lh_skip_partial

.lh_line:
    cmp byte [r13], 0
    je .lh_trim
    ; Copy one line to cmd_line_buf, keeping at most one history entry
    lea rdi, [cmd_line_buf]
    xor ecx, ecx
.lh_cpy:
    movzx eax, byte [r13]
    cmp al, 0
    je .lh_add
    cmp al, 13
    je .lh_skip_cr
    cmp al, 10
    je .lh_add
    inc r13
    cmp ecx, HISTORY_ENTRY_SIZE - 1
    jae .lh_cpy                     ; the rest of an overlong line is dropped
    mov [rdi + rcx], al
    inc ecx
    jmp .lh_cpy
.lh_skip_cr:
    inc r13
    jmp .lh_cpy
.lh_add:
    cmp byte [r13], 10
    jne .lh_no_lf
    inc r13
.lh_no_lf:
    mov byte [rdi + rcx], 0
    test ecx, ecx
    jz .lh_line
    lea rdi, [cmd_line_buf]
    call history_add
    jmp .lh_line

.lh_trim:
    ; An oversized file is cut down to what the ring holds
    cmp r14, HISTORY_FILE_MAX
    jbe .lh_done
    call history_rewrite

.lh_done:
    add rsp, 32
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; history_rewrite - replace the history file with the entries of the ring,
; oldest first, through a temporary file renamed over the original
history_rewrite:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 8

    lea rdi, [history_tmp_path]
    lea rsi, [history_file_path]
    call str_copy
    lea rdi, [history_tmp_path]
    call str_len
    lea rdi, [history_tmp_path]
    add rdi, rax
    lea rsi, [str_tmp_suffix]
    call str_copy

    ; All lines into history_read_buf (256000 bytes at most fit)
    lea r12, [history_read_buf]
    xor r13d, r13d
.hr_loop:
    cmp r13d, [history_count]
    jae .hr_write
    mov eax, [history_write_idx]
    sub eax, [history_count]
    add eax, r13d
    jge .hr_idx
    add eax, HISTORY_COUNT
.hr_idx:
    imul eax, HISTORY_ENTRY_SIZE
    lea rsi, [history_buf]
    add rsi, rax
.hr_copy:
    mov al, [rsi]
    test al, al
    jz .hr_eol
    mov [r12], al
    inc r12
    inc rsi
    jmp .hr_copy
.hr_eol:
    mov byte [r12], 10
    inc r12
    inc r13d
    jmp .hr_loop

.hr_write:
    lea rdi, [history_tmp_path]
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    mov edx, 0o600
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .hr_done
    mov ebx, eax
    lea rsi, [history_read_buf]
    mov rdx, r12
    sub rdx, rsi
    mov r13, rdx                    ; bytes to write
    mov edi, ebx
    mov eax, SYS_WRITE
    syscall
    mov r12, rax
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall
    cmp r12, r13
    jne .hr_discard
    lea rdi, [history_tmp_path]
    lea rsi, [history_file_path]
    mov eax, SYS_RENAME
    syscall
    jmp .hr_done
.hr_discard:
    lea rdi, [history_tmp_path]
    mov eax, SYS_UNLINK
    syscall

.hr_done:
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; history_save_entry - Append a command to ~/.asm_history
; rdi = pointer to null-terminated command string
; The file is created readable by its owner only.
; ============================================================================
history_save_entry:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 16

    mov r12, rdi                    ; save command pointer

    ; Check if history path was built
    lea rdi, [history_file_path]
    cmp byte [rdi], 0
    je .hse_done

    ; Open file for append (create if needed), O_CLOEXEC
    mov esi, O_WRONLY | O_CREAT | O_APPEND | 0x80000
    mov edx, 0o600
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .hse_done
    mov ebx, eax                    ; fd

    ; Get command length
    mov rdi, r12
    call str_len
    mov edx, eax                    ; length

    ; Write command
    mov edi, ebx
    mov rsi, r12
    mov eax, SYS_WRITE
    syscall

    ; Write newline
    mov edi, ebx
    lea rsi, [newline]
    mov edx, 1
    mov eax, SYS_WRITE
    syscall

    ; Close file
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall

.hse_done:
    add rsp, 16
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; run_asmrc - Execute commands from ~/.asmrc config file at startup
; ============================================================================
run_asmrc:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 8

    ; Build path: $HOME/.asmrc
    lea rdi, [str_home]
    call getenv_internal
    test rax, rax
    jz .rc_done

    ; An absurdly long $HOME cannot be a real home directory
    mov rbx, rax
    mov rdi, rax
    call str_len
    cmp eax, MAX_PATH_BUF - 16
    ja .rc_done

    ; Copy HOME to asmrc_path
    lea rdi, [asmrc_path]
    mov rsi, rbx
.rc_copy_home:
    mov cl, [rsi]
    mov [rdi], cl
    test cl, cl
    jz .rc_append
    inc rdi
    inc rsi
    jmp .rc_copy_home
.rc_append:
    lea rsi, [str_asmrc]
.rc_copy_name:
    mov cl, [rsi]
    mov [rdi], cl
    test cl, cl
    jz .rc_open
    inc rdi
    inc rsi
    jmp .rc_copy_name

.rc_open:
    lea rdi, [asmrc_path]
    xor esi, esi
    call read_script_file
    cmp eax, -1
    je .rc_done                     ; file doesn't exist, silent fail
    test eax, eax
    js .rc_failed
    jz .rc_done

    ; Run the whole file through the ASH script engine
    lea rdi, [script_file_buf]
    mov esi, 1
    call ash_eval
    jmp .rc_done

.rc_failed:
    mov esi, eax
    lea rdi, [err_asmrc_name]
    call report_script_error

.rc_done:
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; ==================== BATCH 2 FUNCTIONS ====================================
; ============================================================================

; ============================================================================
; handler_source - Execute commands from a user-specified file
; rdi = pointer to filename argument (already past "source ")
; ============================================================================
handler_source:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 24

    ; Check for missing argument
    test rdi, rdi
    jz .hsrc_noargs
    cmp byte [rdi], 0
    je .hsrc_noargs

    ; Cap recursion depth to prevent stack growth from self-sourcing
    cmp dword [source_depth], 10
    jge .hsrc_depth_err
    inc dword [source_depth]

    ; Read the whole file (rdi already points to the filename)
    xor esi, esi
    call read_script_file
    cmp eax, -1
    je .hsrc_open_err
    test eax, eax
    js .hsrc_bad_file
    jz .hsrc_done                   ; empty file

    ; Run the whole file through the ASH script engine
    lea rdi, [script_file_buf]
    mov esi, 1
    call ash_eval
    jmp .hsrc_done

.hsrc_bad_file:
    mov esi, eax
    lea rdi, [err_source_name]
    call report_script_error
    jmp .hsrc_done

.hsrc_noargs:
    lea rdi, [err_source_msg]
    mov esi, err_source_len
    call report_error_len
    jmp .hsrc_done_nodepth

.hsrc_open_err:
    lea rdi, [err_source_open]
    mov esi, err_source_o_len
    call report_error_len
    jmp .hsrc_done

.hsrc_depth_err:
    lea rdi, [err_source_depth_msg]
    mov esi, err_source_depth_len
    call report_error_len
    jmp .hsrc_done_nodepth

.hsrc_done:
    dec dword [source_depth]
.hsrc_done_nodepth:
    add rsp, 24
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret


; rhs_note_rows - the search line is on screen: note which row its end is on
; (a long match wraps like the prompt line does)
rhs_note_rows:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 8

    mov ebx, search_prompt_len + search_prompt_e_len
    add ebx, [search_len]
    cmp byte [search_match_found], 0
    je .rnr_nomatch
    mov eax, [search_match_idx]
    imul eax, HISTORY_ENTRY_SIZE
    lea rdi, [history_buf]
    add rdi, rax
    call str_len
    mov esi, eax
    call utf8_cols
    add ebx, eax
    jmp .rnr_calc
.rnr_nomatch:
    cmp dword [search_len], 0
    je .rnr_calc
    add ebx, search_fail_len
.rnr_calc:
    call cur_cols
    mov ecx, eax
    lea eax, [rbx - 1]
    xor edx, edx
    div ecx                         ; a text ending in the last column has
    mov [cursor_row], eax           ; its cursor still on that row
    add rsp, 8
    pop rbx
    pop rbp
    ret

; ============================================================================
; reverse_history_search - Ctrl+R interactive reverse search mode
; ============================================================================
reverse_history_search:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40

    ; Initialize search state
    mov dword [search_len], 0
    mov byte [search_buf], 0
    mov byte [search_match_found], 0

    ; Start searching from the most recent history entry
    mov eax, [history_write_idx]
    test eax, eax
    jnz .rhs_init_idx
    mov eax, HISTORY_COUNT
.rhs_init_idx:
    dec eax
    mov [search_match_idx], eax

.rhs_redraw_prompt:
    call ob_begin

    ; Back to the first row of what is on screen, then erase it all (the
    ; search line can wrap just like the prompt line)
    lea rdi, [str_cr]
    mov esi, 1
    call print_string_len
    mov eax, [cursor_row]
    test eax, eax
    jz .rhs_top
    mov ecx, 'A'
    call write_csi_num
.rhs_top:
    lea rdi, [ansi_clear_eos]
    mov esi, 3
    call print_string_len

    ; Print "(reverse-i-search)`"
    lea rdi, [search_prompt]
    mov esi, search_prompt_len
    call print_string_len

    ; Print the search query string
    mov ecx, [search_len]
    test ecx, ecx
    jz .rhs_prompt_end
    lea rdi, [search_buf]
    mov esi, ecx
    call print_string_len

.rhs_prompt_end:
    ; Print "': "
    lea rdi, [search_prompt_end]
    mov esi, search_prompt_e_len
    call print_string_len

    ; Print the matched command (if any)
    cmp byte [search_match_found], 0
    je .rhs_no_match_display

    ; Load the matched history entry and print it
    mov eax, [search_match_idx]
    imul eax, HISTORY_ENTRY_SIZE
    lea rdi, [history_buf]
    add rdi, rax
    call print_cstring
    jmp .rhs_read_key

.rhs_no_match_display:
    mov ecx, [search_len]
    test ecx, ecx
    jz .rhs_read_key
    lea rdi, [search_fail_msg]
    mov esi, search_fail_len
    call print_string_len

.rhs_read_key:
    call rhs_note_rows
    call ob_end
    call read_key

    movzx ebx, word [key_vkey]
    movzx r12d, byte [key_char]

    ; --- Enter: accept the current match ---
    cmp bx, VK_RETURN
    je .rhs_accept

    ; --- Ctrl+C (char 3) or Esc (char 27): cancel ---
    cmp r12d, 3
    je .rhs_cancel
    cmp r12d, 27
    je .rhs_cancel

    ; --- Ctrl+R (char 18): find next older match ---
    cmp r12d, 18
    je .rhs_next_match

    ; --- Backspace: remove last search char ---
    cmp bx, VK_BACK
    je .rhs_backspace

    ; --- Printable character: add to search string ---
    cmp r12d, 32
    jb .rhs_read_key                ; ignore control chars we don't handle
    cmp r12d, 126
    ja .rhs_read_key

    ; Append character to search_buf
    mov ecx, [search_len]
    cmp ecx, 254                    ; guard buffer overflow
    jge .rhs_read_key

    lea rax, [search_buf]
    mov [rax + rcx], r12b
    inc ecx
    mov byte [rax + rcx], 0
    mov [search_len], ecx

    ; Perform search from the current match position
    call .rhs_do_search
    jmp .rhs_redraw_prompt

.rhs_backspace:
    mov ecx, [search_len]
    test ecx, ecx
    jz .rhs_redraw_prompt           ; nothing to delete
    dec ecx
    mov [search_len], ecx
    lea rax, [search_buf]
    mov byte [rax + rcx], 0

    ; Re-search from the beginning (most recent entry)
    mov eax, [history_write_idx]
    test eax, eax
    jnz .rhs_bs_idx
    mov eax, HISTORY_COUNT
.rhs_bs_idx:
    dec eax
    mov [search_match_idx], eax
    mov byte [search_match_found], 0

    test ecx, ecx
    jz .rhs_redraw_prompt

    call .rhs_do_search
    jmp .rhs_redraw_prompt

.rhs_next_match:
    cmp byte [search_match_found], 0
    je .rhs_redraw_prompt
    cmp dword [search_len], 0
    je .rhs_redraw_prompt

    mov eax, [search_match_idx]
    test eax, eax
    jnz .rhs_nm_dec
    mov eax, HISTORY_COUNT
.rhs_nm_dec:
    dec eax
    mov [search_match_idx], eax

    call .rhs_do_search
    jmp .rhs_redraw_prompt

.rhs_accept:
    cmp byte [search_match_found], 0
    je .rhs_cancel                  ; no match, treat like cancel

    mov eax, [search_match_idx]
    imul eax, HISTORY_ENTRY_SIZE
    lea rsi, [history_buf]
    add rsi, rax
    lea rdi, [line_buf]
    call str_copy

    lea rdi, [line_buf]
    call str_len
    mov [line_len], eax
    mov [line_cursor], eax

    call redraw_line
    jmp .rhs_done

.rhs_cancel:
    call redraw_line
    jmp .rhs_done

.rhs_done:
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; --- Internal: search history backward for a substring match ---
.rhs_do_search:
    mov r14d, [history_count]
    test r14d, r14d
    jz .rhs_ds_no_match

    mov r15d, [search_match_idx]

.rhs_ds_loop:
    test r14d, r14d
    jz .rhs_ds_no_match

    mov eax, r15d
    imul eax, HISTORY_ENTRY_SIZE
    lea rbx, [history_buf]
    add rbx, rax

    cmp byte [rbx], 0
    je .rhs_ds_advance

    mov r13, rbx

.rhs_ds_substr:
    cmp byte [r13], 0
    je .rhs_ds_advance

    lea rdi, [search_buf]
    mov rsi, r13
    mov ecx, [search_len]
    xor edx, edx
.rhs_ds_cmp:
    cmp edx, ecx
    jge .rhs_ds_found

    movzx eax, byte [rdi + rdx]
    movzx r8d, byte [rsi + rdx]
    test r8b, r8b
    jz .rhs_ds_advance

    cmp al, 'A'
    jb .rhs_ds_cmp_s2
    cmp al, 'Z'
    ja .rhs_ds_cmp_s2
    add al, 32
.rhs_ds_cmp_s2:
    cmp r8b, 'A'
    jb .rhs_ds_cmp_check
    cmp r8b, 'Z'
    ja .rhs_ds_cmp_check
    add r8b, 32
.rhs_ds_cmp_check:
    cmp al, r8b
    jne .rhs_ds_next_pos
    inc edx
    jmp .rhs_ds_cmp

.rhs_ds_next_pos:
    inc r13
    jmp .rhs_ds_substr

.rhs_ds_found:
    mov [search_match_idx], r15d
    mov byte [search_match_found], 1
    ret

.rhs_ds_advance:
    test r15d, r15d
    jnz .rhs_ds_dec
    mov r15d, HISTORY_COUNT
.rhs_ds_dec:
    dec r15d
    dec r14d
    jmp .rhs_ds_loop

.rhs_ds_no_match:
    mov byte [search_match_found], 0
    ret


; ============================================================================
; ==================== BATCH 3 FUNCTIONS ====================================
; ============================================================================

; ============================================================================
; print_ls_perms(ecx = st_mode) - Render "drwxr-xr-x" style permission string
; Uses the ls_perms_buf in .bss. Preserves caller registers except rax.
; ============================================================================
print_ls_perms:
    push rbp
    mov rbp, rsp
    push rcx
    push rdi
    push rsi
    sub rsp, 8                      ; keep the stack 16-byte aligned for the call below

    lea rdi, [ls_perms_buf]
    mov esi, ecx

    ; --- Byte 0: file type ---
    mov eax, esi
    and eax, S_IFMT
    cmp eax, S_IFDIR
    je .plp_dir
    cmp eax, S_IFLNK
    je .plp_lnk
    cmp eax, S_IFCHR
    je .plp_chr
    cmp eax, S_IFBLK
    je .plp_blk
    cmp eax, S_IFIFO
    je .plp_fifo
    cmp eax, S_IFSOCK
    je .plp_sock
    mov byte [rdi], '-'
    jmp .plp_perm
.plp_dir:
    mov byte [rdi], 'd'
    jmp .plp_perm
.plp_lnk:
    mov byte [rdi], 'l'
    jmp .plp_perm
.plp_chr:
    mov byte [rdi], 'c'
    jmp .plp_perm
.plp_blk:
    mov byte [rdi], 'b'
    jmp .plp_perm
.plp_fifo:
    mov byte [rdi], 'p'
    jmp .plp_perm
.plp_sock:
    mov byte [rdi], 's'

.plp_perm:
    ; Byte 1: owner read
    mov byte [rdi + 1], '-'
    test esi, S_IRUSR
    jz .plp_wu
    mov byte [rdi + 1], 'r'
.plp_wu:
    mov byte [rdi + 2], '-'
    test esi, S_IWUSR
    jz .plp_xu
    mov byte [rdi + 2], 'w'
.plp_xu:
    mov byte [rdi + 3], '-'
    test esi, S_IXUSR
    jz .plp_rg
    mov byte [rdi + 3], 'x'
.plp_rg:
    mov byte [rdi + 4], '-'
    test esi, S_IRGRP
    jz .plp_wg
    mov byte [rdi + 4], 'r'
.plp_wg:
    mov byte [rdi + 5], '-'
    test esi, S_IWGRP
    jz .plp_xg
    mov byte [rdi + 5], 'w'
.plp_xg:
    mov byte [rdi + 6], '-'
    test esi, S_IXGRP
    jz .plp_ro
    mov byte [rdi + 6], 'x'
.plp_ro:
    mov byte [rdi + 7], '-'
    test esi, S_IROTH
    jz .plp_wo
    mov byte [rdi + 7], 'r'
.plp_wo:
    mov byte [rdi + 8], '-'
    test esi, S_IWOTH
    jz .plp_xo
    mov byte [rdi + 8], 'w'
.plp_xo:
    mov byte [rdi + 9], '-'
    test esi, S_IXOTH
    jz .plp_emit
    mov byte [rdi + 9], 'x'
.plp_emit:
    mov byte [rdi + 10], 0
    ; Print the 10-byte string
    lea rdi, [ls_perms_buf]
    mov esi, 10
    call print_string_len

    add rsp, 8
    pop rsi
    pop rdi
    pop rcx
    pop rbp
    ret

; ============================================================================
; handler_ls - List directories (or files) with -l, -a, sorted by name
; Options may appear anywhere, any number of paths may be given. Colours are
; used only on an interactive colour terminal, and control bytes in names
; are shown as '?' when the output is a terminal, so a hostile file name
; cannot send escape sequences to it.
; ls_flags: bit 0 = -l, bit 1 = -a, bit 2 = colour, bit 3 = sanitise names.
; Status: 0, 1 if a path could not be read, 2 for a bad option.
; ============================================================================
%define AT_SYMLINK_NOFOLLOW 0x100
%define SYS_READLINKAT      267
%define LS_POOL_SIZE        262144
%define LS_MAX_ENTRIES      16384
%define LS_MAX_PATHS        32

section .data
    ansi_cyan       db 27, "[36m", 0
    ansi_cyan_len   equ $ - ansi_cyan - 1
    str_arrow       db " -> ", 0
    err_ls_usage    db "Usage: ls [-la] [path...]", 10, 0
    err_ls_usage_len equ $ - err_ls_usage - 1
    err_ls_many     db "ls: too many paths.", 10, 0
    err_ls_many_len equ $ - err_ls_many - 1
    err_ls_cut      db "ls: directory too large, listing truncated.", 10, 0
    err_ls_cut_len  equ $ - err_ls_cut - 1
section .bss
    ls_pool         resb LS_POOL_SIZE   ; [d_type][name\0] for each entry
    ls_ptrs         resq LS_MAX_ENTRIES
    ls_paths        resq LS_MAX_PATHS
    ls_count        resd 1
    ls_pool_used    resd 1
    ls_name_buf     resb 4112
    ls_link_buf     resb 4112
section .text

handler_ls:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24

    mov rbx, rdi                    ; rbx = args (may be NULL)
    mov byte [ls_flags], 0
    xor r12d, r12d                  ; r12d = number of paths
    xor r15d, r15d                  ; r15d = 1 once a path failed
    test rbx, rbx
    jz .ls_args_done

    ; --- Split the arguments into options and paths ---
.ls_tok:
    cmp byte [rbx], ' '
    jne .ls_tok_start
    inc rbx
    jmp .ls_tok
.ls_tok_start:
    cmp byte [rbx], 0
    je .ls_args_done
    mov r13, rbx                    ; r13 = start of this word
.ls_tok_end:
    cmp byte [rbx], 0
    je .ls_tok_have
    cmp byte [rbx], ' '
    je .ls_tok_cut
    inc rbx
    jmp .ls_tok_end
.ls_tok_cut:
    mov byte [rbx], 0
    inc rbx
.ls_tok_have:
    cmp byte [r13], '-'
    jne .ls_operand
    cmp byte [r13 + 1], 0
    je .ls_operand                  ; a lone "-" is a name
    lea r14, [r13 + 1]
.ls_opt:
    movzx eax, byte [r14]
    test al, al
    jz .ls_tok
    cmp al, 'l'
    je .ls_opt_l
    cmp al, 'a'
    je .ls_opt_a
    jmp .ls_usage
.ls_opt_l:
    or byte [ls_flags], 1
    inc r14
    jmp .ls_opt
.ls_opt_a:
    or byte [ls_flags], 2
    inc r14
    jmp .ls_opt
.ls_operand:
    cmp r12d, LS_MAX_PATHS
    jae .ls_too_many
    lea rax, [ls_paths]
    mov [rax + r12*8], r13
    inc r12d
    jmp .ls_tok

.ls_args_done:
    test r12d, r12d
    jnz .ls_have_paths
    lea rax, [str_dot]              ; default to "."
    lea rcx, [ls_paths]
    mov [rcx], rax
    mov r12d, 1

.ls_have_paths:
    call ls_output_flags
    xor r14d, r14d                  ; r14d = index of the current path

.ls_next_path:
    cmp r14d, r12d
    jae .ls_finish
    lea rax, [ls_paths]
    mov r13, [rax + r14*8]          ; r13 = path

    ; Follow links to see whether it is a directory
    mov edi, AT_FDCWD
    mov rsi, r13
    lea rdx, [stat_buf]
    xor r10d, r10d
    mov eax, SYS_NEWFSTATAT
    syscall
    test rax, rax
    jns .ls_have_stat

    ; A dangling link is still something to show
    mov edi, AT_FDCWD
    mov rsi, r13
    lea rdx, [stat_buf]
    mov r10d, AT_SYMLINK_NOFOLLOW
    mov eax, SYS_NEWFSTATAT
    syscall
    test rax, rax
    jns .ls_file_operand
    neg eax
    mov edi, eax
    call print_last_error
    mov r15d, 1
    jmp .ls_path_done

.ls_have_stat:
    mov eax, [stat_buf + STAT_ST_MODE]
    and eax, S_IFMT
    cmp eax, S_IFDIR
    jne .ls_file_operand

    ; A directory. With several paths each gets a heading.
    cmp r12d, 1
    jbe .ls_dir_list
    test r14d, r14d
    jz .ls_heading
    call print_newline
.ls_heading:
    mov rdi, r13
    call print_cstring
    lea rdi, [str_colon]
    call print_cstring
    call print_newline
.ls_dir_list:
    mov rdi, r13
    call ls_list_dir
    or r15d, eax
    jmp .ls_path_done

.ls_file_operand:
    mov edi, AT_FDCWD
    mov rsi, r13
    xor edx, edx
    call ls_print_entry
    test byte [ls_flags], 1
    jnz .ls_path_done               ; long format ended its line
    call print_newline

.ls_path_done:
    inc r14d
    jmp .ls_next_path

.ls_finish:
    test r15d, r15d
    jz .ls_done
    mov dword [last_exit_status], 1
    jmp .ls_done

.ls_usage:
    lea rdi, [err_ls_usage]
    mov esi, err_ls_usage_len
    call report_error_len
    mov dword [last_exit_status], 2
    jmp .ls_done

.ls_too_many:
    lea rdi, [err_ls_many]
    mov esi, err_ls_many_len
    call report_error_len
    mov dword [last_exit_status], 2

.ls_done:
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ---------- ls_output_flags ----------
; Sets ls_flags bit 2 (colour) and bit 3 (sanitise names) from where stdout
; goes. Neither applies to a redirected stdout.
ls_output_flags:
    and byte [ls_flags], 3
    cmp byte [redir_stdout_active], 0
    jne .lof_done
    cmp byte [color_enabled], 0
    je .lof_tty
    or byte [ls_flags], 4
.lof_tty:
    mov eax, SYS_IOCTL
    mov edi, STDOUT_FD
    mov esi, TCGETS
    lea rdx, [termios_probe_buf]
    syscall
    test rax, rax
    js .lof_done
    or byte [ls_flags], 8
.lof_done:
    ret

; ---------- ls_list_dir ----------
; rdi = directory. Reads every entry, sorts them by name and prints them.
; Returns eax = 1 if the directory could not be read, else 0.
ls_list_dir:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24

    mov esi, O_RDONLY | O_DIRECTORY
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    jns .lld_opened
    neg eax
    mov edi, eax
    call print_last_error
    mov eax, 1
    jmp .lld_ret

.lld_opened:
    mov r12d, eax                   ; r12d = directory fd
    mov dword [ls_count], 0
    mov dword [ls_pool_used], 0
    xor r15d, r15d                  ; r15d = 1 if entries had to be dropped

.lld_read_batch:
    mov edi, r12d
    lea rsi, [dirent_buf]
    mov edx, DIRENT_BUF_SIZE
    mov eax, SYS_GETDENTS64
    syscall
    test rax, rax
    jle .lld_collected              ; 0 = done, negative = error

    mov r13d, eax                   ; r13d = bytes returned
    xor r14d, r14d                  ; r14d = offset into buffer

.lld_entry:
    cmp r14d, r13d
    jge .lld_read_batch

    lea rsi, [dirent_buf]
    add rsi, r14
    movzx eax, word [rsi + DIRENT64_D_RECLEN]
    mov [rbp - 48], eax             ; length of this record
    lea rbx, [rsi + DIRENT64_D_NAME]
    movzx r8d, byte [rsi + DIRENT64_D_TYPE]

    ; Hidden entries (and . and ..) only with -a
    cmp byte [rbx], '.'
    jne .lld_add
    test byte [ls_flags], 2
    jz .lld_next

.lld_add:
    xor ecx, ecx                    ; name length
.lld_len:
    cmp byte [rbx + rcx], 0
    je .lld_len_done
    inc ecx
    jmp .lld_len
.lld_len_done:
    mov eax, [ls_pool_used]
    lea edx, [rax + rcx + 2]        ; type byte + name + NUL
    cmp edx, LS_POOL_SIZE
    ja .lld_full
    mov r9d, [ls_count]
    cmp r9d, LS_MAX_ENTRIES
    jae .lld_full
    lea rdi, [ls_pool]
    add rdi, rax                    ; entry
    lea r10, [ls_ptrs]
    mov [r10 + r9*8], rdi
    inc r9d
    mov [ls_count], r9d
    mov [ls_pool_used], edx
    mov [rdi], r8b                  ; d_type
    inc rdi
    mov rsi, rbx
    inc ecx                         ; copy the NUL too
    rep movsb
    jmp .lld_next

.lld_full:
    mov r15d, 1

.lld_next:
    add r14d, [rbp - 48]
    jmp .lld_entry

.lld_collected:
    call ls_sort

    xor r14d, r14d
.lld_print:
    cmp r14d, [ls_count]
    jae .lld_printed
    lea rax, [ls_ptrs]
    mov rsi, [rax + r14*8]
    movzx edx, byte [rsi]
    inc rsi
    mov edi, r12d
    call ls_print_entry
    inc r14d
    jmp .lld_print

.lld_printed:
    test byte [ls_flags], 1
    jnz .lld_close
    call print_newline

.lld_close:
    mov edi, r12d
    mov eax, SYS_CLOSE
    syscall
    xor eax, eax
    test r15d, r15d
    jz .lld_ret
    lea rdi, [err_ls_cut]
    mov esi, err_ls_cut_len
    call report_error_len
    mov eax, 1

.lld_ret:
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ---------- ls_sort ----------
; Shell sort of ls_ptrs[0 .. ls_count) by entry name (byte order).
ls_sort:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8

    lea r15, [ls_ptrs]
    mov r12d, [ls_count]
    mov r13d, r12d
    shr r13d, 1                     ; r13d = gap
.lss_gap:
    test r13d, r13d
    jz .lss_done
    mov r14d, r13d                  ; r14d = i
.lss_outer:
    cmp r14d, r12d
    jae .lss_next_gap
    mov rbx, [r15 + r14*8]          ; rbx = entry to place
    mov r9d, r14d                   ; r9d = j
.lss_inner:
    cmp r9d, r13d
    jb .lss_place
    mov eax, r9d
    sub eax, r13d
    mov rdi, [r15 + rax*8]
    mov rsi, rbx
    call ls_name_cmp
    test eax, eax
    jle .lss_place
    mov eax, r9d
    sub eax, r13d
    mov rdx, [r15 + rax*8]
    mov [r15 + r9*8], rdx
    sub r9d, r13d
    jmp .lss_inner
.lss_place:
    mov [r15 + r9*8], rbx
    inc r14d
    jmp .lss_outer
.lss_next_gap:
    shr r13d, 1
    jmp .lss_gap
.lss_done:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ls_name_cmp - rdi, rsi = entries ([type][name\0]); eax <0, 0, >0.
; Leaf routine: only eax, ecx and edx change.
ls_name_cmp:
    xor ecx, ecx
.lnc_loop:
    movzx eax, byte [rdi + rcx + 1]
    movzx edx, byte [rsi + rcx + 1]
    cmp eax, edx
    jne .lnc_diff
    test eax, eax
    jz .lnc_eq
    inc ecx
    jmp .lnc_loop
.lnc_diff:
    sub eax, edx
    ret
.lnc_eq:
    xor eax, eax
    ret

; ---------- ls_print_entry ----------
; edi = directory fd (or AT_FDCWD), rsi = name, edx = d_type from the
; directory record (0 if unknown). Prints one entry: "perms size name" and a
; newline in long format, "name  " otherwise. Links are not followed, and an
; entry that cannot be examined is shown from its d_type rather than from the
; data of the previous entry.
ls_print_entry:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 16

    mov r12d, edi                   ; r12d = dir fd
    mov rbx, rsi                    ; rbx = name
    mov r13d, edx                   ; r13d = d_type

    mov edi, r12d
    mov rsi, rbx
    lea rdx, [stat_buf]
    mov r10d, AT_SYMLINK_NOFOLLOW
    mov eax, SYS_NEWFSTATAT
    syscall
    test rax, rax
    jns .lpe_have

    ; Could not examine it: regular file of unknown size unless d_type says more
    mov qword [stat_buf + STAT_ST_SIZE], 0
    mov dword [stat_buf + STAT_ST_MODE], S_IFREG
    cmp r13d, DT_DIR
    jne .lpe_not_dir
    mov dword [stat_buf + STAT_ST_MODE], S_IFDIR
.lpe_not_dir:
    cmp r13d, 10                    ; DT_LNK
    jne .lpe_have
    mov dword [stat_buf + STAT_ST_MODE], S_IFLNK

.lpe_have:
    mov r14d, [stat_buf + STAT_ST_MODE]

    test byte [ls_flags], 1
    jz .lpe_name
    mov ecx, r14d
    call print_ls_perms
    lea rdi, [str_two_spaces]
    call print_cstring
    mov rax, [stat_buf + STAT_ST_SIZE]
    call print_number_9pad
    lea rdi, [str_space]
    call print_cstring

.lpe_name:
    ; Colour: directories blue, links cyan, executables green
    xor esi, esi                    ; rsi = colour escape, 0 for none
    mov eax, r14d
    and eax, S_IFMT
    cmp eax, S_IFDIR
    jne .lpe_not_d
    lea rsi, [ansi_blue]
    mov edx, ansi_blue_len
    jmp .lpe_colour_set
.lpe_not_d:
    cmp eax, S_IFLNK
    jne .lpe_not_l
    lea rsi, [ansi_cyan]
    mov edx, ansi_cyan_len
    jmp .lpe_colour_set
.lpe_not_l:
    test r14d, S_IXUSR | S_IXGRP | S_IXOTH
    jz .lpe_colour_set
    lea rsi, [ansi_green_ls]
    mov edx, ansi_green_ls_len
.lpe_colour_set:
    test byte [ls_flags], 4
    jnz .lpe_colour_on
    xor esi, esi
.lpe_colour_on:
    mov r13, rsi                    ; r13 = colour escape or 0
    test r13, r13
    jz .lpe_print_name
    mov rdi, r13
    mov esi, edx
    call print_string_len

.lpe_print_name:
    mov rdi, rbx
    call ls_emit_name

    test r13, r13
    jz .lpe_after_name
    lea rdi, [ansi_default]
    mov esi, ansi_default_len
    call print_string_len

.lpe_after_name:
    test byte [ls_flags], 1
    jz .lpe_short

    ; Long format: show where a link points
    mov eax, r14d
    and eax, S_IFMT
    cmp eax, S_IFLNK
    jne .lpe_newline
    mov edi, r12d
    mov rsi, rbx
    lea rdx, [ls_link_buf]
    mov r10d, 4096
    mov eax, SYS_READLINKAT
    syscall
    test rax, rax
    jle .lpe_newline
    lea rdi, [ls_link_buf]
    mov byte [rdi + rax], 0
    lea rdi, [str_arrow]
    call print_cstring
    lea rdi, [ls_link_buf]
    call ls_emit_name
.lpe_newline:
    call print_newline
    jmp .lpe_done

.lpe_short:
    lea rdi, [str_two_spaces]
    call print_cstring

.lpe_done:
    add rsp, 16
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ---------- ls_emit_name ----------
; rdi = name. Prints it; on a terminal control bytes become '?'.
ls_emit_name:
    test byte [ls_flags], 8
    jz print_cstring
    lea rsi, [ls_name_buf]
    xor ecx, ecx
.len_loop:
    movzx eax, byte [rdi + rcx]
    test al, al
    jz .len_done
    cmp ecx, 4095
    jae .len_done
    cmp al, 0x20
    jb .len_bad
    cmp al, 0x7f
    jne .len_store
.len_bad:
    mov al, '?'
.len_store:
    mov [rsi + rcx], al
    inc ecx
    jmp .len_loop
.len_done:
    mov byte [rsi + rcx], 0
    mov rdi, rsi
    jmp print_cstring


; ============================================================================
; handler_grep - Simple substring search in a file with color highlighting
; Status: 0 a line matched, 1 none did, 2 the file could not be read.
; ============================================================================
GREP_LINE_MAX equ 65535
section .data
    err_grep_long   db "grep: pattern too long.", 10, 0
    err_grep_long_len equ $ - err_grep_long - 1
    err_grep_cut    db "grep: line too long, truncated.", 10, 0
    err_grep_cut_len equ $ - err_grep_cut - 1
    grep_bin_pre    db "Binary file ", 0
    grep_bin_post   db " matches", 10, 0
section .bss
    grep_binary     resb 1          ; the file holds NUL bytes: only report a match
section .text
handler_grep:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 72

    test rdi, rdi
    jz .grep_usage
    cmp byte [rdi], 0
    je .grep_usage

    call parse_two_args
    test rax, rax
    jz .grep_usage
    test rdx, rdx
    jz .grep_usage

    mov r12, rax                    ; r12 = pattern (stays in input_buf)
    mov r13, rdx                    ; r13 = filename
    mov [rbp - 104], rdx

    mov rdi, r12
    call str_len
    mov r14d, eax                   ; r14d = pattern length
    test r14d, r14d
    jz .grep_usage
    cmp r14d, 255
    ja .grep_pat_long

    mov rdi, r13
    mov esi, O_RDONLY
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .grep_file_err
    mov ebx, eax                    ; ebx = file descriptor

    xor r15d, r15d                  ; line buffer write position
    mov dword [rbp - 88], 1         ; status: 1 until a line matches
    mov dword [rbp - 92], 0         ; set once a long line was cut
    mov byte [grep_binary], 0

.grep_read_chunk:
    cmp byte [ctrl_c_flag], 0       ; ^C raised by SIGINT stops a long file
    jne .grep_interrupted
    mov edi, ebx
    lea rsi, [io_buf]
    mov edx, IO_BUF_SIZE
    mov eax, SYS_READ
    syscall
    test rax, rax
    jz .grep_flush_last
    js .grep_read_err

    mov r13d, eax
    xor ecx, ecx

.grep_scan_byte:
    cmp ecx, r13d
    jge .grep_read_chunk

    movzx eax, byte [io_buf + rcx]
    cmp al, 10
    je .grep_end_line
    test al, al
    jnz .grep_store
    mov byte [grep_binary], 1       ; NUL byte: binary file
.grep_store:
    cmp r15d, GREP_LINE_MAX - 1
    jge .grep_cut_byte
    mov [grep_line_buf + r15], al
    inc r15d
    jmp .grep_skip_byte

.grep_cut_byte:
    ; Keep the first part of an overlong line, say so once
    cmp dword [rbp - 92], 0
    jne .grep_skip_byte
    mov dword [rbp - 92], 1
    mov [rbp - 80], ecx
    lea rdi, [err_grep_cut]
    mov esi, err_grep_cut_len
    call report_error_len
    mov ecx, [rbp - 80]

.grep_skip_byte:
    inc ecx
    jmp .grep_scan_byte

.grep_end_line:
    mov byte [grep_line_buf + r15], 0

    mov [rbp - 80], ecx
    mov [rbp - 84], r13d

    lea rdi, [grep_line_buf]
    mov esi, r15d
    mov rdx, r12
    mov ecx, r14d
    call grep_print_highlighted_line
    test eax, eax
    jz .grep_line_done
    mov dword [rbp - 88], 0
    cmp byte [grep_binary], 0
    jne .grep_binary_match

.grep_line_done:
    mov ecx, [rbp - 80]
    mov r13d, [rbp - 84]

    xor r15d, r15d

    inc ecx
    jmp .grep_scan_byte

.grep_flush_last:
    test r15d, r15d
    jz .grep_close
    mov byte [grep_line_buf + r15], 0

    lea rdi, [grep_line_buf]
    mov esi, r15d
    mov rdx, r12
    mov ecx, r14d
    call grep_print_highlighted_line
    test eax, eax
    jz .grep_close
    mov dword [rbp - 88], 0
    cmp byte [grep_binary], 0
    jne .grep_binary_match

.grep_close:
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall
    mov eax, [rbp - 88]
    cmp dword [rbp - 92], 0         ; a cut line makes the result unreliable
    je .grep_set_status
    mov eax, 2
.grep_set_status:
    mov [last_exit_status], eax
    jmp .grep_done

.grep_binary_match:
    ; Say that the file matched instead of dumping binary data
    lea rdi, [grep_bin_pre]
    call print_cstring
    mov rdi, [rbp - 104]
    call print_cstring
    lea rdi, [grep_bin_post]
    call print_cstring
    jmp .grep_close

.grep_interrupted:
    mov byte [ctrl_c_flag], 0
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall
    mov dword [last_exit_status], 130
    jmp .grep_done

.grep_read_err:
    ; EISDIR for a directory, EIO ...
    mov r12d, eax
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall
    mov edi, r12d
    neg edi
    call print_last_error
    mov dword [last_exit_status], 2
    jmp .grep_done

.grep_usage:
    lea rdi, [err_grep_usage]
    mov esi, err_grep_usage_len
    call report_error_len
    mov dword [last_exit_status], 2
    jmp .grep_done

.grep_pat_long:
    lea rdi, [err_grep_long]
    mov esi, err_grep_long_len
    call report_error_len
    mov dword [last_exit_status], 2
    jmp .grep_done

.grep_file_err:
    lea rdi, [err_file_msg]
    mov esi, err_file_len
    call report_error_len
    mov dword [last_exit_status], 2

.grep_done:
    add rsp, 72
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret


; ============================================================================
; grep_print_highlighted_line - Print line with pattern highlighted
; rdi = line, esi = line length, rdx = pattern, ecx = pattern length
; Returns eax = 1 if the line contains the pattern (and was printed, unless
; the file is binary), else 0. Prints each stretch of text with one write.
; Highlighting is only used on an interactive colour terminal.
; ============================================================================
grep_print_highlighted_line:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40

    mov r12, rdi
    mov r13d, esi
    mov r14, rdx
    mov r15d, ecx

    xor ebx, ebx                    ; ebx = scan position
    mov dword [rbp - 48], 0         ; start of text not yet printed
    mov dword [rbp - 52], 0         ; 1 once a match was seen

.ghl_scan:
    mov eax, r13d
    sub eax, ebx
    cmp eax, r15d
    jl .ghl_end

    movzx eax, byte [r12 + rbx]
    cmp al, [r14]
    jne .ghl_next

    lea rdi, [r12 + rbx]
    mov rsi, r14
    mov ecx, r15d
    call grep_memcmp
    test eax, eax
    jnz .ghl_next

    ; A match at ebx
    mov dword [rbp - 52], 1
    cmp byte [grep_binary], 0
    jne .ghl_end                    ; binary: one match is all we need

    ; Text before the match
    mov esi, ebx
    sub esi, [rbp - 48]
    jz .ghl_match_text
    mov eax, [rbp - 48]
    lea rdi, [r12 + rax]
    call print_string_len
.ghl_match_text:
    cmp byte [color_enabled], 0
    je .ghl_plain_match
    cmp byte [redir_stdout_active], 0
    jne .ghl_plain_match

    lea rdi, [ansi_red_hi]
    mov esi, ansi_red_hi_len
    call print_string_len
    lea rdi, [r12 + rbx]
    mov esi, r15d
    call print_string_len
    lea rdi, [ansi_default]
    mov esi, ansi_default_len
    call print_string_len
    jmp .ghl_matched

.ghl_plain_match:
    lea rdi, [r12 + rbx]
    mov esi, r15d
    call print_string_len

.ghl_matched:
    add ebx, r15d
    mov [rbp - 48], ebx
    jmp .ghl_scan

.ghl_next:
    inc ebx
    jmp .ghl_scan

.ghl_end:
    cmp dword [rbp - 52], 0
    je .ghl_done
    cmp byte [grep_binary], 0
    jne .ghl_done

    ; Rest of the line, then the newline
    mov esi, r13d
    sub esi, [rbp - 48]
    jz .ghl_newline
    mov eax, [rbp - 48]
    lea rdi, [r12 + rax]
    call print_string_len
.ghl_newline:
    call print_newline

.ghl_done:
    mov eax, [rbp - 52]
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret


; ============================================================================
; grep_memcmp - Compare N bytes (case-sensitive)
; rdi = ptr1, rsi = ptr2, ecx = count
; Returns: eax = 0 if equal, 1 if not
; ============================================================================
grep_memcmp:
    test ecx, ecx
    jz .gmc_eq
.gmc_loop:
    movzx eax, byte [rdi]
    cmp al, [rsi]
    jne .gmc_neq
    inc rdi
    inc rsi
    dec ecx
    jnz .gmc_loop
.gmc_eq:
    xor eax, eax
    ret
.gmc_neq:
    mov eax, 1
    ret


; ============================================================================
; handler_uptime - Display system uptime from /proc/uptime
; ============================================================================
handler_uptime:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 32

    lea rdi, [proc_uptime]
    mov esi, O_RDONLY
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .uptime_err
    mov ebx, eax

    mov edi, ebx
    lea rsi, [read_buffer]
    mov edx, 256
    mov eax, SYS_READ
    syscall
    mov r12d, eax

    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall

    lea rdi, [read_buffer]
    xor eax, eax
    mov ecx, 10

.uptime_parse:
    movzx edx, byte [rdi]
    cmp dl, '.'
    je .uptime_parse_done
    cmp dl, ' '
    je .uptime_parse_done
    cmp dl, 0
    je .uptime_parse_done
    cmp dl, 10
    je .uptime_parse_done
    sub dl, '0'
    cmp dl, 9
    ja .uptime_parse_done
    imul eax, ecx
    movzx edx, dl
    add eax, edx
    inc rdi
    jmp .uptime_parse

.uptime_parse_done:
    mov r12d, eax

    xor edx, edx
    mov ecx, 86400
    div ecx
    mov r13d, eax
    mov eax, edx

    xor edx, edx
    mov ecx, 3600
    div ecx
    mov r14d, eax
    mov eax, edx

    xor edx, edx
    mov ecx, 60
    div ecx
    mov ebx, eax

    mov [rbp - 48], edx

    lea rdi, [str_up]
    call print_cstring

    mov eax, r13d
    call print_number

    cmp r13d, 1
    je .uptime_one_day
    lea rdi, [str_days]
    call print_cstring
    jmp .uptime_print_time

.uptime_one_day:
    lea rdi, [str_day]
    call print_cstring

.uptime_print_time:
    mov eax, r14d
    call print_number_2digit

    lea rdi, [time_colon]
    call print_cstring

    mov eax, ebx
    call print_number_2digit

    lea rdi, [time_colon]
    call print_cstring

    mov eax, [rbp - 48]
    call print_number_2digit

    call print_newline
    jmp .uptime_done

.uptime_err:
    lea rdi, [err_file_msg]
    mov esi, err_file_len
    call report_error_len

.uptime_done:
    add rsp, 32
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret


; ============================================================================
; handler_free - Display memory info from /proc/meminfo
; ============================================================================
handler_free:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 24

    lea rdi, [proc_meminfo]
    mov esi, O_RDONLY
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .free_err
    mov ebx, eax

    mov edi, ebx
    lea rsi, [read_buffer]
    mov edx, READ_BUF_SIZE
    mov eax, SYS_READ
    syscall
    mov r12d, eax

    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall

    test r12d, r12d
    jle .free_done

    lea rdi, [read_buffer]
    xor ecx, ecx
    xor r13d, r13d

.free_scan:
    cmp ecx, r12d
    jge .free_print_all
    cmp byte [rdi + rcx], 10
    jne .free_next_byte
    inc r13d
    cmp r13d, 6
    je .free_print_partial

.free_next_byte:
    inc ecx
    jmp .free_scan

.free_print_partial:
    inc ecx
    lea rdi, [read_buffer]
    mov esi, ecx
    call print_string_len
    jmp .free_done

.free_print_all:
    lea rdi, [read_buffer]
    mov esi, r12d
    call print_string_len

.free_done:
    add rsp, 24
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

.free_err:
    lea rdi, [err_file_msg]
    mov esi, err_file_len
    call report_error_len
    jmp .free_done


; ============================================================================
; handler_calc - Simple integer calculator (left-to-right, no precedence)
; ============================================================================
handler_calc:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40

    test rdi, rdi
    jz .calc_usage
    cmp byte [rdi], 0
    je .calc_usage

    mov r12, rdi

    mov rdi, r12
    call skip_spaces
    mov r12, rax

    mov rdi, r12
    call calc_parse_number
    cmp rcx, 2
    je .calc_overflow
    test rcx, rcx
    jz .calc_usage
    mov r13, rax
    mov r12, rdx

.calc_loop:
    mov rdi, r12
    call skip_spaces
    mov r12, rax

    movzx eax, byte [r12]
    test al, al
    jz .calc_print_result

    mov r14b, al
    cmp al, '+'
    je .calc_have_op
    cmp al, '-'
    je .calc_have_op
    cmp al, '*'
    je .calc_have_op
    cmp al, '/'
    je .calc_have_op
    jmp .calc_usage                 ; unknown operator or trailing text

.calc_have_op:
    inc r12

    mov rdi, r12
    call skip_spaces
    mov r12, rax

    mov rdi, r12
    call calc_parse_number
    cmp rcx, 2
    je .calc_overflow
    test rcx, rcx
    jz .calc_usage
    mov r15, rax
    mov r12, rdx

    cmp r14b, '+'
    je .calc_add
    cmp r14b, '-'
    je .calc_sub
    cmp r14b, '*'
    je .calc_mul
    cmp r14b, '/'
    je .calc_div
    jmp .calc_print_result

.calc_add:
    add r13, r15
    jo .calc_overflow
    jmp .calc_loop

.calc_sub:
    sub r13, r15
    jo .calc_overflow
    jmp .calc_loop

.calc_mul:
    imul r13, r15
    jo .calc_overflow
    jmp .calc_loop

.calc_div:
    test r15, r15
    jz .calc_div_zero

    ; INT64_MIN / -1 does not fit and would raise #DE
    cmp r15, -1
    jne .calc_do_div
    mov rax, 0x8000000000000000
    cmp r13, rax
    je .calc_overflow
.calc_do_div:
    mov rax, r13
    cqo
    idiv r15
    mov r13, rax
    jmp .calc_loop

.calc_print_result:
    test r13, r13
    jns .calc_print_positive

    lea rdi, [str_dash]
    call print_cstring
    neg r13

.calc_print_positive:
    mov rax, r13                    ; full 64-bit result
    call print_number
    call print_newline
    jmp .calc_done

.calc_div_zero:
    lea rdi, [err_div_zero]
    mov esi, err_div_zero_len
    call report_error_len
    jmp .calc_done

.calc_overflow:
    lea rdi, [err_overflow]
    mov esi, err_overflow_len
    call report_error_len
    jmp .calc_done

.calc_usage:
    lea rdi, [err_calc_usage]
    mov esi, err_calc_usage_len
    call report_error_len

.calc_done:
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret


; ============================================================================
; calc_parse_number - Parse a signed decimal integer from string
; rdi = pointer to string
; Returns: rax = number, rdx = ptr after number,
;          rcx = 1 if ok, 0 if no number there, 2 if it does not fit in 64 bits
; ============================================================================
calc_parse_number:
    mov r8, rdi
.cpn_skip:
    cmp byte [r8], ' '
    jne .cpn_check_sign
    inc r8
    jmp .cpn_skip

.cpn_check_sign:
    xor r11d, r11d                  ; r11d = 1 for a leading '-'
    cmp byte [r8], '-'
    jne .cpn_check_plus
    mov r11d, 1
    inc r8
    jmp .cpn_digits

.cpn_check_plus:
    cmp byte [r8], '+'
    jne .cpn_digits
    inc r8

.cpn_digits:
    xor r9d, r9d                    ; r9 = magnitude
    xor r10d, r10d                  ; r10d = digits seen

.cpn_digit_loop:
    movzx esi, byte [r8]
    sub esi, '0'
    cmp esi, 9
    ja .cpn_done_digits
    mov rax, r9
    mov ecx, 10
    mul rcx
    jc .cpn_overflow
    add rax, rsi
    jc .cpn_overflow
    mov r9, rax
    inc r10d
    inc r8
    jmp .cpn_digit_loop

.cpn_done_digits:
    test r10d, r10d
    jz .cpn_error

    ; The magnitude may reach 2^63 only for a negative number
    mov rax, 0x8000000000000000
    test r11d, r11d
    jz .cpn_positive
    cmp r9, rax
    ja .cpn_overflow
    neg r9
    jmp .cpn_ok

.cpn_positive:
    cmp r9, rax
    jae .cpn_overflow

.cpn_ok:
    mov rax, r9
    mov rdx, r8
    mov ecx, 1
    ret

.cpn_overflow:
    xor eax, eax
    mov rdx, r8
    mov ecx, 2
    ret

.cpn_error:
    xor eax, eax
    xor edx, edx
    xor ecx, ecx
    ret


; ============================================================================
; ==================== BATCH 4 FUNCTIONS ====================================
; ============================================================================

; ============================================================================
; Prompt
;
; print_prompt runs once per command. It prints the status hint and the OSC
; marks, renders the visible prompt ("user@host:/cwd (branch)$ ") into
; prompt_buf and records how many terminal columns it covers
; (prompt_total_len). The redraw that follows every keystroke only replays
; prompt_buf, so typing costs no getcwd, no .git lookup and no marks.
; Everything shown from outside the shell (user, host, directory, branch)
; goes through pb_text, which replaces control bytes so a hostile name cannot
; talk to the terminal.
; ============================================================================
%define PB_CAP 6000
section .bss
    prompt_buf          resb 6144
    prompt_len          resd 1
    osc7_buf            resb 12800  ; "file://host/path" with every byte escaped
section .data
    prompt_exit_pre_plain  db " [", 0
    prompt_exit_post_plain db "]", 0
    pb_git_color        db 27, "[33m"
    pb_git_color_len    equ $ - pb_git_color
    pb_git_open         db " (", 0
    pb_git_close        db ")", 0
    wrap_nudge          db " ", 13      ; forces the wrap of a full last column
section .text

; pb_reset - start an empty prompt
pb_reset:
    mov dword [prompt_len], 0
    mov dword [prompt_total_len], 0
    ret

; pb_color - append rdi/esi (an escape sequence, zero columns) unless colors
; are off
pb_color:
    cmp byte [color_enabled], 0
    je .pbc_ret
    mov eax, [prompt_len]
    mov ecx, eax
    add ecx, esi
    cmp ecx, PB_CAP
    ja .pbc_ret
    lea rdx, [prompt_buf]
    add rdx, rax
    mov ecx, esi
.pbc_loop:
    test ecx, ecx
    jz .pbc_done
    mov al, [rdi]
    mov [rdx], al
    inc rdi
    inc rdx
    dec ecx
    jmp .pbc_loop
.pbc_done:
    add [prompt_len], esi
.pbc_ret:
    ret

; pb_text - append the NUL-terminated string at rdi as visible text.
; Control bytes become '?'. Adds the columns it covers to prompt_total_len.
pb_text:
    push rbx
    mov eax, [prompt_len]
    mov ebx, eax                    ; where this piece starts
    lea rdx, [prompt_buf]
    add rdx, rax
.pbt_loop:
    movzx ecx, byte [rdi]
    test cl, cl
    jz .pbt_done
    cmp eax, PB_CAP
    jae .pbt_done
    cmp cl, 0x20
    jb .pbt_bad
    cmp cl, 0x7F
    jne .pbt_put
.pbt_bad:
    mov cl, '?'
.pbt_put:
    mov [rdx], cl
    inc rdx
    inc rdi
    inc eax
    jmp .pbt_loop
.pbt_done:
    mov [prompt_len], eax
    sub eax, ebx
    jz .pbt_ret
    lea rdi, [prompt_buf]
    add rdi, rbx
    mov esi, eax
    call utf8_cols
    add [prompt_total_len], eax
.pbt_ret:
    pop rbx
    ret

; ----------------------------------------------------------------------------
; utf8_cols - terminal columns taken by esi bytes of UTF-8 text at rdi:
; one per code point, two for East Asian wide characters and emoji, none for
; combining marks. A byte that is not valid UTF-8 counts as one.
; Returns eax. Clobbers ecx, edx, esi, r8-r10.
; ----------------------------------------------------------------------------
section .data
    align 4
utf8_width_table:                   ; first, last, columns
    dd 0x0300, 0x036F, 0
    dd 0x0483, 0x0489, 0
    dd 0x0591, 0x05BD, 0
    dd 0x0610, 0x061A, 0
    dd 0x064B, 0x065F, 0
    dd 0x1AB0, 0x1AFF, 0
    dd 0x1DC0, 0x1DFF, 0
    dd 0x200B, 0x200F, 0
    dd 0x20D0, 0x20FF, 0
    dd 0xFE00, 0xFE0F, 0
    dd 0xFE20, 0xFE2F, 0
    dd 0xE0100, 0xE01EF, 0
    dd 0x1100, 0x115F, 2
    dd 0x2E80, 0x303E, 2
    dd 0x3041, 0x33FF, 2
    dd 0x3400, 0x4DBF, 2
    dd 0x4E00, 0x9FFF, 2
    dd 0xA000, 0xA4CF, 2
    dd 0xAC00, 0xD7A3, 2
    dd 0xF900, 0xFAFF, 2
    dd 0xFE30, 0xFE4F, 2
    dd 0xFF00, 0xFF60, 2
    dd 0xFFE0, 0xFFE6, 2
    dd 0x1F300, 0x1F64F, 2
    dd 0x1F680, 0x1F6FF, 2
    dd 0x1F900, 0x1F9FF, 2
    dd 0x20000, 0x3FFFD, 2
    dd 0, 0, 0
section .text
utf8_cols:
    xor eax, eax                    ; columns
    xor ecx, ecx                    ; byte index
.uc_loop:
    cmp ecx, esi
    jae .uc_ret
    movzx edx, byte [rdi + rcx]
    inc ecx
    cmp dl, 0xC2
    jb .uc_one                      ; ASCII, or a stray continuation byte
    mov r9d, 1
    cmp dl, 0xE0
    jb .uc_lead
    mov r9d, 2
    cmp dl, 0xF0
    jb .uc_lead
    mov r9d, 3
    cmp dl, 0xF5
    jae .uc_one
    and edx, 0x07
    jmp .uc_cont
.uc_lead:
    cmp r9d, 1
    jne .uc_lead3
    and edx, 0x1F
    jmp .uc_cont
.uc_lead3:
    and edx, 0x0F
.uc_cont:
    test r9d, r9d
    jz .uc_have
    cmp ecx, esi
    jae .uc_have                    ; cut off: judge what we have
    movzx r8d, byte [rdi + rcx]
    mov r10d, r8d
    and r10d, 0xC0
    cmp r10d, 0x80
    jne .uc_have
    shl edx, 6
    and r8d, 0x3F
    or edx, r8d
    inc ecx
    dec r9d
    jmp .uc_cont
.uc_have:
    cmp edx, 0x300
    jb .uc_one
    lea r8, [utf8_width_table]
.uc_tab:
    mov r9d, [r8]
    test r9d, r9d
    jz .uc_one                      ; not in the table: one column
    cmp edx, r9d
    jb .uc_next
    cmp edx, [r8 + 4]
    ja .uc_next
    add eax, [r8 + 8]
    jmp .uc_loop
.uc_next:
    add r8, 12
    jmp .uc_tab
.uc_one:
    inc eax
    jmp .uc_loop
.uc_ret:
    ret

; cur_cols - eax = terminal width in columns (huge when unknown, so nothing
; is ever taken for a wrapped row)
cur_cols:
    movzx eax, word [term_cols]
    test eax, eax
    jnz .cc_ret
    mov eax, 0x7FFFFFFF
.cc_ret:
    ret

; osc7_put - append the NUL-terminated string at rsi to the OSC 7 URI at rdi,
; percent-encoding every byte outside [A-Za-z0-9/._~-]. Advances rdi.
osc7_put:
.op_loop:
    movzx eax, byte [rsi]
    test al, al
    jz .op_ret
    inc rsi
    cmp al, '/'
    je .op_raw
    cmp al, '.'
    je .op_raw
    cmp al, '_'
    je .op_raw
    cmp al, '~'
    je .op_raw
    cmp al, '-'
    je .op_raw
    cmp al, '0'
    jb .op_esc
    cmp al, '9'
    jbe .op_raw
    cmp al, 'A'
    jb .op_esc
    cmp al, 'Z'
    jbe .op_raw
    cmp al, 'a'
    jb .op_esc
    cmp al, 'z'
    ja .op_esc
.op_raw:
    mov [rdi], al
    inc rdi
    jmp .op_loop
.op_esc:
    mov byte [rdi], '%'
    mov ecx, eax
    shr ecx, 4
    add cl, '0'
    cmp cl, '9'
    jbe .op_hi
    add cl, 7
.op_hi:
    mov [rdi + 1], cl
    and eax, 15
    add al, '0'
    cmp al, '9'
    jbe .op_lo
    add al, 7
.op_lo:
    mov [rdi + 2], al
    add rdi, 3
    jmp .op_loop
.op_ret:
    ret

; ============================================================================
; emit_osc7_cwd - emit ESC]7;file://host/path BEL so modern terminals
; (Ghostty, WezTerm, iTerm2, kitty, Warp, VS Code) track the shell's cwd.
; Host and path are percent-encoded; the path is the one build_prompt_line
; left in path_buf.
; ============================================================================
emit_osc7_cwd:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    cmp byte [path_buf], '/'
    jne .osc7_done                  ; getcwd failed: nothing to report

    lea rdi, [osc7_buf]
    lea rsi, [osc7_prefix]
.osc7_pre:
    mov al, [rsi]
    test al, al
    jz .osc7_host
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .osc7_pre
.osc7_host:
    lea rsi, [cached_hostname]
    call osc7_put
    lea rsi, [path_buf]
    call osc7_put
    mov byte [rdi], 7               ; BEL
    inc rdi
    lea rsi, [osc7_buf]
    sub rdi, rsi
    mov esi, edi
    lea rdi, [osc7_buf]
    call print_string_len

.osc7_done:
    leave
    ret

; str_copy_cap - copy at most edx bytes of the string at rsi to rdi, then NUL
str_copy_cap:
.scc_loop:
    test edx, edx
    jz .scc_end
    mov al, [rsi]
    test al, al
    jz .scc_end
    mov [rdi], al
    inc rdi
    inc rsi
    dec edx
    jmp .scc_loop
.scc_end:
    mov byte [rdi], 0
    ret

; ============================================================================
; init_prompt_cache - Cache username and hostname at startup
; Both are cut to 63 bytes so a huge $USER cannot spill into its neighbours.
; ============================================================================
init_prompt_cache:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 8

    ; --- Cache username from $USER ---
    lea rdi, [str_user]
    call getenv_internal
    test rax, rax
    jz .ipc_default_user

    lea rdi, [cached_username]
    mov rsi, rax
    mov edx, 63
    call str_copy_cap
    jmp .ipc_hostname

.ipc_default_user:
    lea rdi, [cached_username]
    lea rsi, [str_unknown_user]
    mov edx, 63
    call str_copy_cap

.ipc_hostname:
    lea rdi, [uname_buf]
    mov eax, SYS_UNAME
    syscall
    test rax, rax
    js .ipc_default_host

    lea rdi, [cached_hostname]
    lea rsi, [uname_buf + 65]
    mov edx, 63
    call str_copy_cap
    jmp .ipc_done

.ipc_default_host:
    lea rdi, [cached_hostname]
    lea rsi, [str_unknown_host]
    mov edx, 63
    call str_copy_cap

.ipc_done:
    add rsp, 8
    pop rbx
    pop rbp
    ret


; ============================================================================
; print_prompt - Print the themed prompt (user@host:path$) for a new command
; ============================================================================
print_prompt:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 16

    call pb_reset

    ; Inside an unfinished if/while/for block: short "> " prompt
    cmp byte [ash_cont], 0
    je .pp_primary
    lea rdi, [ash_ps2]
    call pb_text
    xor edi, edi                    ; no OSC 133 B for the continuation prompt
    call prompt_show
    jmp .pp_ret
.pp_primary:
    ; "took 2.31s, peak 45.2 MB" after slow commands
    call print_cmd_stats

    ; Show exit status of last command in red when non-zero (fish-style hint)
    mov eax, [last_exit_status]
    test eax, eax
    jz .pp_no_exit
    lea rdi, [exit_prompt_pre]
    lea rsi, [prompt_exit_pre_plain]
    cmp byte [color_enabled], 0
    cmove rdi, rsi
    call print_cstring
    mov eax, [last_exit_status]
    call print_number
    lea rdi, [exit_prompt_post]
    lea rsi, [prompt_exit_post_plain]
    cmp byte [color_enabled], 0
    cmove rdi, rsi
    call print_cstring
    call print_newline
.pp_no_exit:

    call build_prompt_line

    cmp byte [osc_enabled], 0
    je .pp_no_marks
    ; OSC 133 A - mark the start of a new prompt region
    lea rdi, [osc133_a]
    call print_cstring
    ; OSC 7 - emit cwd for terminal integration
    call emit_osc7_cwd
.pp_no_marks:
    mov edi, 1
    call prompt_show
.pp_ret:
    add rsp, 16
    pop r12
    pop rbx
    pop rbp
    ret

; prompt_show - print prompt_buf, then (edi != 0) the OSC 133 B mark, and
; note which row the cursor is on. A prompt that ends exactly at the right
; margin leaves a pending wrap; resolve it so later cursor moves are exact.
prompt_show:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 8

    mov ebx, edi
    lea rdi, [prompt_buf]
    mov esi, [prompt_len]
    call print_string_len

    test ebx, ebx
    jz .ps_cursor
    cmp byte [osc_enabled], 0
    je .ps_cursor
    ; OSC 133 B - prompt rendering finished, command entry begins
    lea rdi, [osc133_b]
    call print_cstring
.ps_cursor:
    call cur_cols
    mov ecx, eax
    mov eax, [prompt_total_len]
    xor edx, edx
    div ecx
    mov [cursor_row], eax
    test edx, edx
    jnz .ps_ret
    test eax, eax
    jz .ps_ret
    lea rdi, [wrap_nudge]
    mov esi, 2
    call print_string_len
.ps_ret:
    add rsp, 8
    pop rbx
    pop rbp
    ret

; print_prompt_line - replay the prompt of the current line (for redraws)
print_prompt_line:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    lea rdi, [prompt_buf]
    mov esi, [prompt_len]
    call print_string_len
    leave
    ret

; ----------------------------------------------------------------------------
; build_prompt_line - render the prompt into prompt_buf for the current theme
; Leaves the working directory in path_buf (OSC 7 uses it).
; ----------------------------------------------------------------------------
build_prompt_line:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 16

    mov r12d, [current_theme]
    mov eax, r12d
    imul eax, THEME_ENTRY_SIZE
    lea rbx, [theme_table + rax]

    lea rdi, [path_buf]
    mov esi, MAX_PATH_BUF
    mov eax, SYS_GETCWD
    syscall
    test rax, rax
    jg .bpl_have_cwd
    mov word [path_buf], 0x003F     ; "?" when the directory is gone
.bpl_have_cwd:

    cmp r12d, 2
    je .bpl_path

    ; --- user@host: ---
    mov rdi, [rbx]
    mov esi, [rbx + 8]
    call pb_color
    lea rdi, [cached_username]
    call pb_text
    lea rdi, [str_at]
    call pb_text
    lea rdi, [cached_hostname]
    call pb_text
    mov rdi, [rbx + 32]
    mov esi, [rbx + 40]
    call pb_color
    lea rdi, [str_colon]
    call pb_text

.bpl_path:
    mov rdi, [rbx + 16]
    mov esi, [rbx + 24]
    call pb_color
    lea rdi, [path_buf]
    call pb_text
    mov rdi, [rbx + 32]
    mov esi, [rbx + 40]
    call pb_color

    ; --- " (branch)" in a repository ---
    call read_git_branch
    cmp byte [git_branch], 0
    je .bpl_symbol
    lea rdi, [pb_git_color]
    mov esi, pb_git_color_len
    call pb_color
    lea rdi, [pb_git_open]
    call pb_text
    lea rdi, [git_branch]
    call pb_text
    lea rdi, [pb_git_close]
    call pb_text
    lea rdi, [ansi_default]
    mov esi, ansi_default_len
    call pb_color

.bpl_symbol:
    mov rdi, [rbx + 48]
    call pb_text

    add rsp, 16
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; read_git_branch - walk up from cwd to the first directory that has a .git,
; read its HEAD and put the branch name (or short SHA) in git_branch + NUL.
; A ".git" file ("gitdir: PATH", as in worktrees and submodules) is followed.
; On failure git_branch[0] = 0.
; ============================================================================
read_git_branch:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 16

    mov byte [git_branch], 0

    lea rdi, [git_scratch_path]
    mov esi, 4000
    mov eax, SYS_GETCWD
    syscall
    test rax, rax
    jle .rgb_done

    ; r12 = length of cwd string
    lea rdi, [git_scratch_path]
    call str_len
    mov r12d, eax

.rgb_try_here:
    ; Append "/.git/HEAD" at offset r12
    lea rdi, [git_scratch_path + r12]
    lea rsi, [str_git_head]
    call str_copy

    ; Open the candidate file (O_RDONLY | O_CLOEXEC)
    lea rdi, [git_scratch_path]
    mov esi, 0x80000
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    jns .rgb_opened
    cmp rax, -20                    ; ENOTDIR: ".git" is a file here
    je .rgb_gitfile
    cmp rax, -2                     ; ENOENT: not in this directory
    jne .rgb_done                   ; anything else (EACCES...): give up

    ; Not here - truncate git_scratch_path at last '/' and retry
    mov byte [git_scratch_path + r12], 0
    mov r13d, r12d
    test r13d, r13d
    jz .rgb_done
    dec r13d
.rgb_trunc:
    cmp r13d, 0
    jl .rgb_done
    cmp byte [git_scratch_path + r13], '/'
    je .rgb_trunc_hit
    dec r13d
    jmp .rgb_trunc
.rgb_trunc_hit:
    ; don't slice off the leading '/' root itself
    test r13d, r13d
    jz .rgb_done
    mov byte [git_scratch_path + r13], 0
    mov r12d, r13d
    jmp .rgb_try_here

.rgb_gitfile:
    ; "<dir>/.git" is a plain file: read "gitdir: PATH" from it
    mov byte [git_scratch_path + r12 + 5], 0
    lea rdi, [git_scratch_path]
    mov esi, 0x80000
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .rgb_done
    mov ebx, eax
    mov edi, ebx
    lea rsi, [git_head_buf]
    mov edx, 500
    mov eax, SYS_READ
    syscall
    mov r14d, eax
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall
    test r14d, r14d
    jle .rgb_done
    mov byte [git_head_buf + r14], 0
    lea rdi, [git_head_buf]
    lea rsi, [str_gitdir_prefix]
    call str_startswith
    test eax, eax
    jz .rgb_done

    ; The path ends at the line break. Relative paths start at <dir>.
    lea rsi, [git_head_buf + 8]
    xor ecx, ecx
.rgb_gd_len:
    movzx eax, byte [rsi + rcx]
    test al, al
    jz .rgb_gd_end
    cmp al, 10
    je .rgb_gd_end
    cmp al, 13
    je .rgb_gd_end
    inc ecx
    jmp .rgb_gd_len
.rgb_gd_end:
    test ecx, ecx
    jz .rgb_done
    lea rdi, [git_scratch_path]
    cmp byte [rsi], '/'
    je .rgb_gd_copy
    lea eax, [rcx + r12 + 8]        ; <dir> + "/" + path + "/HEAD" must fit
    cmp eax, 4090
    ja .rgb_done
    add rdi, r12                    ; <dir> + "/" + relative path
    mov byte [rdi], '/'
    inc rdi
.rgb_gd_copy:
    xor edx, edx
.rgb_gd_cp:
    cmp edx, ecx
    jae .rgb_gd_done
    mov al, [rsi + rdx]
    mov [rdi + rdx], al
    inc edx
    jmp .rgb_gd_cp
.rgb_gd_done:
    add rdi, rcx
    lea rsi, [str_head_name]
    call str_copy
    lea rdi, [git_scratch_path]
    mov esi, 0x80000
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .rgb_done

.rgb_opened:
    mov ebx, eax                        ; fd
    mov edi, ebx
    lea rsi, [git_head_buf]
    mov edx, 511
    mov eax, SYS_READ
    syscall
    mov r14d, eax
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall

    test r14d, r14d
    jle .rgb_done
    mov byte [git_head_buf + r14], 0

    ; "ref: refs/heads/NAME" shows NAME; any other ref shows its last path
    ; component; a bare SHA (detached HEAD) shows its first 8 characters.
    lea rsi, [str_ref_prefix]
    lea rdi, [git_head_buf]
    call str_startswith
    test eax, eax
    jz .rgb_other_ref
    lea rsi, [git_head_buf + 16]       ; skip prefix
    jmp .rgb_copy_ref

.rgb_other_ref:
    lea rdi, [git_head_buf]
    lea rsi, [str_ref_any]
    call str_startswith
    test eax, eax
    jz .rgb_detached
    lea rsi, [git_head_buf + 5]
    mov rdx, rsi                        ; start of the last component
.rgb_last:
    movzx eax, byte [rsi]
    test al, al
    jz .rgb_last_done
    cmp al, 10
    je .rgb_last_done
    cmp al, 13
    je .rgb_last_done
    inc rsi
    cmp al, '/'
    jne .rgb_last
    mov rdx, rsi
    jmp .rgb_last
.rgb_last_done:
    mov rsi, rdx

.rgb_copy_ref:
    lea rdi, [git_branch]
    xor ecx, ecx
.rgb_copy_branch:
    movzx eax, byte [rsi + rcx]
    cmp al, 0
    je .rgb_cb_end
    cmp al, 10
    je .rgb_cb_end
    cmp al, 13
    je .rgb_cb_end
    cmp ecx, 127
    jge .rgb_cb_end
    mov [rdi + rcx], al
    inc ecx
    jmp .rgb_copy_branch
.rgb_cb_end:
    mov byte [rdi + rcx], 0
    jmp .rgb_done

.rgb_detached:
    ; Detached HEAD: copy first 8 chars
    lea rsi, [git_head_buf]
    lea rdi, [git_branch]
    xor ecx, ecx
.rgb_copy_sha:
    movzx eax, byte [rsi + rcx]
    cmp al, 0
    je .rgb_sha_end
    cmp al, 10
    je .rgb_sha_end
    cmp ecx, 8
    jge .rgb_sha_end
    mov [rdi + rcx], al
    inc ecx
    jmp .rgb_copy_sha
.rgb_sha_end:
    mov byte [rdi + rcx], 0

.rgb_done:
    add rsp, 16
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

section .data
    str_gitdir_prefix   db "gitdir: ", 0
    str_head_name       db "/HEAD", 0
    str_ref_any         db "ref: ", 0
section .text

; str_startswith(rdi=haystack, rsi=prefix) -> eax=1 if haystack starts with prefix
str_startswith:
    xor eax, eax
.ssw_loop:
    movzx ecx, byte [rsi]
    test cl, cl
    jz .ssw_yes
    movzx edx, byte [rdi]
    cmp cl, dl
    jne .ssw_no
    inc rdi
    inc rsi
    jmp .ssw_loop
.ssw_yes:
    mov eax, 1
    ret
.ssw_no:
    xor eax, eax
    ret

; ============================================================================
; check_command_exists - Check if word matches any command in dispatch tables
; rdi = word (null-terminated), esi = word length
; Returns: eax = 1 if found, 0 if not
; ============================================================================
check_command_exists:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 16

    mov r12, rdi
    mov r13d, esi

    lea r14, [cmd_table_exact]

.cce_exact_loop:
    mov rdi, [r14]
    test rdi, rdi
    jz .cce_prefix

    mov rdi, r12
    mov rsi, [r14]
    call str_icompare
    test eax, eax
    jz .cce_found

    add r14, 16
    jmp .cce_exact_loop

.cce_prefix:
    lea r14, [cmd_table_prefix]

.cce_prefix_loop:
    mov rdi, [r14]
    test rdi, rdi
    jz .cce_not_found

    mov ebx, [r14 + 16]

    cmp r13d, ebx
    jne .cce_prefix_next

    mov rdi, r12
    mov rsi, [r14]
    mov edx, r13d
    call str_icompare_n
    test eax, eax
    jz .cce_found

.cce_prefix_next:
    add r14, 24
    jmp .cce_prefix_loop

.cce_not_found:
    mov rdi, r12                    ; if / then / done ... are valid too
    call ash_kw_match
    test eax, eax
    jnz .cce_found
    xor eax, eax
    jmp .cce_done

.cce_found:
    mov eax, 1

.cce_done:
    add rsp, 16
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret


; ============================================================================
; handler_theme - Set/list color themes
; rdi = argument string (or NULL/0 if no args)
; ============================================================================
handler_theme:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 16

    test rdi, rdi
    jz .hth_list
    cmp byte [rdi], 0
    je .hth_list

    mov r12, rdi

    mov rdi, r12
    lea rsi, [theme_name_default]
    call str_icompare
    test eax, eax
    jz .hth_set_default

    mov rdi, r12
    lea rsi, [theme_name_minimal]
    call str_icompare
    test eax, eax
    jz .hth_set_minimal

    mov rdi, r12
    lea rsi, [theme_name_classic]
    call str_icompare
    test eax, eax
    jz .hth_set_classic

    lea rdi, [theme_unknown_msg]
    call report_error_cstr
    jmp .hth_done

.hth_set_default:
    mov dword [current_theme], 0
    jmp .hth_confirm

.hth_set_minimal:
    mov dword [current_theme], 1
    jmp .hth_confirm

.hth_set_classic:
    mov dword [current_theme], 2
    jmp .hth_confirm

.hth_confirm:
    lea rdi, [theme_set_msg]
    call print_cstring
    mov eax, [current_theme]
    lea rbx, [theme_names]
    mov rdi, [rbx + rax*8]
    call print_cstring
    call print_newline
    jmp .hth_done

.hth_list:
    lea rdi, [theme_list_msg]
    mov esi, theme_list_msg_len
    call print_string_len

    lea rdi, [theme_set_msg]
    call print_cstring
    mov eax, [current_theme]
    lea rbx, [theme_names]
    mov rdi, [rbx + rax*8]
    call print_cstring
    call print_newline

.hth_done:
    add rsp, 16
    pop r12
    pop rbx
    pop rbp
    ret


; ============================================================================
; Jobs. job_pids[slot] is the pid whose exit status counts (the last stage of
; a pipeline), job_pgids[slot] the job's process group (0 when it shares the
; shell's group), job_state[slot] JOB_RUNNING or JOB_STOPPED and job_cmds the
; command text. Jobs are numbered by their position among the used slots.
; ============================================================================
section .bss
    job_pgids           resq JOB_MAX
    job_state           resb JOB_MAX
section .data
    jobs_stopped_msg    db " Stopped  ", 0
section .text

; job_slots_free() -> eax = number of free slots, after dropping finished jobs
job_slots_free:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    call reap_finished_jobs
    xor eax, eax
    xor ecx, ecx
.jsf_loop:
    cmp ecx, JOB_MAX
    jge .jsf_done
    cmp qword [job_pids + rcx*8], 0
    jne .jsf_next
    inc eax
.jsf_next:
    inc ecx
    jmp .jsf_loop
.jsf_done:
    leave
    ret

; job_add(edi = pid, esi = process group or 0, edx = JOB_*, rcx = command text
; or 0 for input_buf) -> eax = slot or -1
job_add:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8

    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15, rcx
    call reap_finished_jobs
    xor ebx, ebx
.ja_find:
    cmp ebx, JOB_MAX
    jge .ja_full
    cmp qword [job_pids + rbx*8], 0
    je .ja_found
    inc ebx
    jmp .ja_find
.ja_found:
    mov eax, r12d
    mov [job_pids + rbx*8], rax
    mov eax, r13d
    mov [job_pgids + rbx*8], rax
    mov eax, r14d
    mov [job_state + rbx], al

    mov eax, ebx
    imul eax, JOB_CMD_SIZE
    lea rdi, [job_cmds + rax]
    lea rsi, [input_buf]
    test r15, r15
    cmovnz rsi, r15
    xor edx, edx
.ja_copy:
    cmp edx, JOB_CMD_SIZE - 1
    jge .ja_copied
    movzx eax, byte [rsi + rdx]
    test al, al
    jz .ja_copied
    mov [rdi + rdx], al
    inc edx
    jmp .ja_copy
.ja_copied:
    mov byte [rdi + rdx], 0
    inc dword [job_count]
    mov eax, ebx
    jmp .ja_ret
.ja_full:
    mov eax, -1
.ja_ret:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; job_free(edi = slot) - forget a job
job_free:
    cmp qword [job_pids + rdi*8], 0
    je .jf_ret
    mov qword [job_pids + rdi*8], 0
    mov qword [job_pgids + rdi*8], 0
    mov byte [job_state + rdi], 0
    dec dword [job_count]
.jf_ret:
    ret

; job_ordinal(edi = slot) -> eax = its number as 'jobs' shows it (1-based)
job_ordinal:
    xor eax, eax
    xor ecx, ecx
.jo_loop:
    cmp qword [job_pids + rcx*8], 0
    je .jo_next
    inc eax
.jo_next:
    cmp ecx, edi
    jae .jo_done
    inc ecx
    cmp ecx, JOB_MAX
    jl .jo_loop
.jo_done:
    ret

; job_find(edi = job number) -> eax = slot, or -1 when there is no such job
job_find:
    xor eax, eax                    ; eax = number of used slots seen
    xor ecx, ecx
.jfind_loop:
    cmp ecx, JOB_MAX
    jge .jfind_none
    cmp qword [job_pids + rcx*8], 0
    je .jfind_next
    inc eax
    cmp eax, edi
    je .jfind_found
.jfind_next:
    inc ecx
    jmp .jfind_loop
.jfind_found:
    mov eax, ecx
    ret
.jfind_none:
    mov eax, -1
    ret

; job_parse_number(rdi = text) -> eax = job number (1-255), 0 if not one
job_parse_number:
    xor eax, eax
    xor ecx, ecx                    ; digits seen
.jpn_loop:
    movzx edx, byte [rdi]
    test dl, dl
    jz .jpn_end
    cmp dl, ' '
    je .jpn_end
    sub edx, '0'
    cmp edx, 9
    ja .jpn_bad
    imul eax, eax, 10
    add eax, edx
    cmp eax, 255
    ja .jpn_bad
    inc ecx
    inc rdi
    jmp .jpn_loop
.jpn_end:
    test ecx, ecx
    jz .jpn_bad
    ret
.jpn_bad:
    xor eax, eax
    ret

; job_print_line(edi = slot) - "  [1] PID 1234 Running  command"
job_print_line:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 8

    mov ebx, edi
    call job_ordinal
    mov r12d, eax
    lea rdi, [jobs_bracket_open]
    call print_cstring
    mov eax, r12d
    call print_number
    lea rdi, [jobs_bracket_close]
    call print_cstring
    lea rdi, [jobs_pid_label]
    call print_cstring
    mov rax, [job_pids + rbx*8]
    mov eax, eax
    call print_number
    lea rdi, [jobs_running_msg]
    cmp byte [job_state + rbx], JOB_STOPPED
    jne .jpl_state
    lea rdi, [jobs_stopped_msg]
.jpl_state:
    call print_cstring
    mov eax, ebx
    imul eax, JOB_CMD_SIZE
    lea rdi, [job_cmds + rax]
    call print_cstring
    call print_newline

    add rsp, 8
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; job_notify_stopped(edi = slot) - tell the user a foreground job was stopped.
; Goes to the terminal even when the command's stdout was redirected.
job_notify_stopped:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    mov r12d, edi
    movzx ebx, byte [redir_stdout_active]
    mov byte [redir_stdout_active], 0
    call print_newline
    mov edi, r12d
    call job_print_line
    mov [redir_stdout_active], bl
    pop r12
    pop rbx
    pop rbp
    ret

; job_poll(edi = slot) -> eax = 1 if the job is gone (its slot is freed),
; 0 if it still exists. Also notes whether it is running or stopped.
job_poll:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 16                     ; [rsp] = wait status

    mov ebx, edi
    mov r12, [job_pids + rbx*8]
.jp_again:
    mov edi, r12d
    mov edx, WNOHANG
    mov r8, [job_pgids + rbx*8]
    test r8, r8
    jz .jp_do
    mov edi, r8d
    neg edi                         ; any process of the job's group
    mov edx, WNOHANG | WUNTRACED | WCONTINUED
.jp_do:
    mov dword [rsp], 0
    mov rsi, rsp
    xor r10d, r10d
    mov eax, SYS_WAIT4
    syscall
    cmp rax, -EINTR
    je .jp_again
    test rax, rax
    jz .jp_alive
    js .jp_gone                     ; nothing of the job is left
    cmp qword [job_pgids + rbx*8], 0
    je .jp_gone                     ; a single process of the shell's group ended
    mov eax, [rsp]
    mov ecx, eax
    and ecx, 0xFF
    cmp ecx, 0x7F
    jne .jp_not_stopped
    mov byte [job_state + rbx], JOB_STOPPED
    jmp .jp_again
.jp_not_stopped:
    cmp eax, 0xFFFF                 ; continued
    jne .jp_again                   ; one stage ended; look for the others
    mov byte [job_state + rbx], JOB_RUNNING
    jmp .jp_again
.jp_alive:
    xor eax, eax
    jmp .jp_ret
.jp_gone:
    mov edi, ebx
    call job_free
    mov eax, 1
.jp_ret:
    add rsp, 16
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; handler_jobs - List active background jobs
; ============================================================================
handler_jobs:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 16

    call reap_finished_jobs

    cmp dword [job_count], 0
    jle .hj_none

    lea rdi, [jobs_header_msg]
    call print_cstring

    xor ebx, ebx
.hj_loop:
    cmp ebx, JOB_MAX
    jge .hj_done
    cmp qword [job_pids + rbx*8], 0
    je .hj_next
    mov edi, ebx
    call job_print_line
.hj_next:
    inc ebx
    jmp .hj_loop

.hj_none:
    lea rdi, [jobs_none_msg]
    call print_cstring

.hj_done:
    add rsp, 16
    pop r12
    pop rbx
    pop rbp
    ret


; ============================================================================
; reap_finished_jobs - Check all job slots and remove finished ones
; ============================================================================
reap_finished_jobs:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 16

    xor r12d, r12d

.rfj_loop:
    cmp r12d, JOB_MAX
    jge .rfj_done
    cmp qword [job_pids + r12*8], 0
    je .rfj_next
    mov edi, r12d
    call job_poll
.rfj_next:
    inc r12d
    jmp .rfj_loop

.rfj_done:
    add rsp, 16
    pop r12
    pop rbx
    pop rbp
    ret


; ============================================================================
; handler_fg - Bring a job to the foreground (resuming it if it was stopped)
; rdi = argument string ("1", "2", etc.) or NULL
; ============================================================================
handler_fg:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24                     ; [rsp] = wait status

    test rdi, rdi
    jz .hfg_noarg
    cmp byte [rdi], 0
    je .hfg_noarg
    call job_parse_number
    test eax, eax
    jz .hfg_invalid
    mov edi, eax
    call job_find
    test eax, eax
    js .hfg_invalid
    mov r12d, eax                   ; r12d = slot

    ; Print the command
    mov eax, r12d
    imul eax, JOB_CMD_SIZE
    lea rdi, [job_cmds + rax]
    call print_cstring
    call print_newline

    mov rbx, [job_pids + r12*8]     ; rbx = pid that gives the status
    mov r13, [job_pgids + r12*8]    ; r13 = its process group, 0 if shared
    mov byte [job_state + r12], JOB_RUNNING
    xor r14d, r14d                  ; r14d = exit status

    call restore_terminal
    test r13, r13
    jz .hfg_plain

    ; Hand the terminal to the job and wake it (harmless if it is running)
    mov edi, r13d
    call jc_give_tty
    mov edi, r13d
    neg edi
    mov esi, SIGCONT
    mov eax, SYS_KILL
    syscall
.hfg_wait:
    mov dword [rsp], 0
    mov edi, r13d
    neg edi
    mov rsi, rsp
    mov edx, WUNTRACED
    xor r10d, r10d
    mov eax, SYS_WAIT4
    syscall
    cmp rax, -EINTR
    je .hfg_wait
    test rax, rax
    jle .hfg_finished               ; ECHILD: every process of the job is gone
    mov r15d, eax
    mov eax, [rsp]
    mov esi, 1
    call jc_status
    test edx, edx
    jnz .hfg_stopped
    cmp r15, rbx
    jne .hfg_wait
    mov r14d, eax
    jmp .hfg_wait

.hfg_stopped:
    mov [last_exit_status], eax
    mov byte [job_state + r12], JOB_STOPPED
    call jc_reclaim
    mov edi, r12d
    call job_notify_stopped
    call restore_terminal           ; the program may have left the terminal raw
    jmp .hfg_raw

.hfg_finished:
    call jc_reclaim
    mov edi, r12d
    call job_free
    mov [last_exit_status], r14d
    jmp .hfg_raw

.hfg_plain:
    ; The job shares the shell's group: wake it and wait for that one process
    mov edi, ebx
    mov esi, SIGCONT
    mov eax, SYS_KILL
    syscall
.hfg_plain_wait:
    mov dword [rsp], 0
    mov edi, ebx
    mov rsi, rsp
    xor edx, edx
    xor r10d, r10d
    mov eax, SYS_WAIT4
    syscall
    cmp rax, -EINTR
    je .hfg_plain_wait
    mov eax, [rsp]
    xor esi, esi
    call jc_status
    mov [last_exit_status], eax
    mov edi, r12d
    call job_free

.hfg_raw:
    call setup_raw_mode
    jmp .hfg_done

.hfg_noarg:
    lea rdi, [jobs_fg_noarg_msg]
    call print_cstring
    jmp .hfg_done

.hfg_invalid:
    lea rdi, [jobs_fg_invalid_msg]
    call print_cstring
    mov dword [last_exit_status], 1

.hfg_done:
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; handler_bg - resume a stopped job in the background, do NOT wait
; ============================================================================
handler_bg:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 8

    test rdi, rdi
    jz .hbg_noarg
    cmp byte [rdi], 0
    je .hbg_noarg
    call job_parse_number
    test eax, eax
    jz .hbg_noarg
    mov r13d, eax                   ; r13d = job number
    mov edi, eax
    call job_find
    test eax, eax
    js .hbg_nojob
    mov r12d, eax                   ; r12d = slot

    mov rdi, [job_pids + r12*8]
    mov r8, [job_pgids + r12*8]
    test r8, r8
    jz .hbg_signal
    mov edi, r8d
    neg edi                         ; the whole job
.hbg_signal:
    mov esi, SIGCONT
    mov eax, SYS_KILL
    syscall
    test rax, rax
    jnz .hbg_nojob
    mov byte [job_state + r12], JOB_RUNNING

    lea rdi, [bg_resumed_msg]
    call print_cstring
    mov eax, r13d
    call print_number
    call print_newline
    jmp .hbg_done

.hbg_nojob:
    lea rdi, [jobs_fg_invalid_msg]
    call print_cstring
    mov dword [last_exit_status], 1
    jmp .hbg_done

.hbg_noarg:
    lea rdi, [bg_noarg_msg]
    mov esi, bg_noarg_len
    call print_string_len

.hbg_done:
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; epoch_to_datetime - Convert Unix epoch seconds to date/time components
; Input: rdi = epoch seconds (64-bit)
; Output: date_year, date_month, date_day, time_hour, time_minute, time_second
; Algorithm: iterative subtraction from year 1970 forward.
; ============================================================================
epoch_to_datetime:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8

    mov rax, rdi                    ; rax = total epoch seconds

    ; Separate into days and time-of-day
    ; total_days = epoch / 86400, time_seconds = epoch % 86400
    xor edx, edx
    mov rcx, 86400
    div rcx                         ; rax = days, rdx = seconds of day
    mov r12, rax                    ; r12 = total days since 1970-01-01
    mov r13, rdx                    ; r13 = seconds within the day

    ; Calculate day of week: (total_days + 4) % 7
    ; Jan 1, 1970 was a Thursday (index 4, where 0=Sun)
    mov rax, r12
    add rax, 4
    xor edx, edx
    mov ecx, 7
    div ecx                         ; edx = day of week (0=Sun..6=Sat)
    mov [date_dow], edx

    ; Convert time-of-day to H:M:S
    mov rax, r13
    xor edx, edx
    mov ecx, 3600
    div ecx                         ; eax = hours, edx = remaining seconds
    mov [time_hour], al
    mov eax, edx
    xor edx, edx
    mov ecx, 60
    div ecx                         ; eax = minutes, edx = seconds
    mov [time_minute], al
    mov [time_second], dl

    ; Convert days to Y/M/D
    ; Start at year 1970, subtract days per year
    mov ecx, 1970                   ; ecx = current year

.etd_year_loop:
    ; Determine days in this year (365 or 366)
    push rcx
    call is_leap_year               ; eax = 1 if leap
    pop rcx
    mov ebx, 365
    add ebx, eax                    ; ebx = days in this year

    cmp r12d, ebx
    jl .etd_year_found
    sub r12d, ebx
    inc ecx
    jmp .etd_year_loop

.etd_year_found:
    mov [date_year], ecx            ; store year
    ; r12d = remaining days within the year (0-based)

    ; Determine month
    lea r14, [months_table]         ; byte array: 31,28,31,30,...
    mov r15d, 1                     ; month counter (1-based)

    ; Check if leap year for February adjustment
    push rcx
    call is_leap_year
    pop rcx
    mov ebx, eax                    ; ebx = 1 if leap year

.etd_month_loop:
    movzx eax, byte [r14]          ; days in this month
    ; If February and leap year, add 1
    cmp r15d, 2
    jne .etd_month_noadj
    add eax, ebx
.etd_month_noadj:
    cmp r12d, eax
    jl .etd_month_found
    sub r12d, eax
    inc r15d
    inc r14
    jmp .etd_month_loop

.etd_month_found:
    mov [date_month], r15w          ; store month (word)
    inc r12d                        ; days are 1-based
    mov [date_day], r12w            ; store day (word)

    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; is_leap_year - Check if year in ecx is a leap year
; Input: ecx = year
; Output: eax = 1 if leap year, 0 if not
; Rule: divisible by 4 AND (not by 100 OR by 400)
; ============================================================================
is_leap_year:
    push rbx
    mov eax, ecx
    ; Check divisible by 4
    test eax, 3
    jnz .ily_no
    ; Check divisible by 100
    xor edx, edx
    mov ebx, 100
    div ebx
    test edx, edx
    jnz .ily_yes                    ; div by 4 but not 100 -> leap
    ; Check divisible by 400
    ; eax is now year/100, check if divisible by 4
    test eax, 3
    jnz .ily_no
.ily_yes:
    mov eax, 1
    pop rbx
    ret
.ily_no:
    xor eax, eax
    pop rbx
    ret

; ============================================================================
; print_last_error - Print error message for a given errno
; Input: edi = errno value (positive)
; Common errnos: 2=ENOENT, 13=EACCES, 17=EEXIST, 20=ENOTDIR,
;   21=EISDIR, 22=EINVAL, 39=ENOTEMPTY
; ============================================================================
print_last_error:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 24

    mov ebx, edi                    ; save errno

    ; "Error: " prefix (also marks the command as failed)
    lea rdi, [.ple_prefix]
    call report_error_cstr

    ; Look up errno in our small table
    cmp ebx, 2
    je .ple_enoent
    cmp ebx, 13
    je .ple_eacces
    cmp ebx, 17
    je .ple_eexist
    cmp ebx, 20
    je .ple_enotdir
    cmp ebx, 21
    je .ple_eisdir
    cmp ebx, 22
    je .ple_einval
    cmp ebx, 39
    je .ple_enotempty

    ; Unknown errno -- print "errno <number>"
    lea rdi, [.ple_errno_str]
    call report_error_cstr
    mov eax, ebx
    lea r8, [num_buf + 31]
    mov byte [r8], 0
    mov ecx, 10
.ple_digits:
    xor edx, edx
    div ecx
    add dl, '0'
    dec r8
    mov [r8], dl
    test eax, eax
    jnz .ple_digits
    mov rdi, r8
    call report_error_cstr
    jmp .ple_newline

.ple_enoent:
    lea rdi, [.ple_msg_enoent]
    jmp .ple_print_msg
.ple_eacces:
    lea rdi, [.ple_msg_eacces]
    jmp .ple_print_msg
.ple_eexist:
    lea rdi, [.ple_msg_eexist]
    jmp .ple_print_msg
.ple_enotdir:
    lea rdi, [.ple_msg_enotdir]
    jmp .ple_print_msg
.ple_eisdir:
    lea rdi, [.ple_msg_eisdir]
    jmp .ple_print_msg
.ple_einval:
    lea rdi, [.ple_msg_einval]
    jmp .ple_print_msg
.ple_enotempty:
    lea rdi, [.ple_msg_enotempty]

.ple_print_msg:
    call report_error_cstr
.ple_newline:
    lea rdi, [newline]
    mov esi, 1
    call report_error_len

    add rsp, 24
    pop rbx
    pop rbp
    ret

; ---- Embedded string data for print_last_error (in .text section) ----
; These are small read-only strings embedded near the code that uses them.
; NASM allows db in .text.
align 1
.ple_prefix:        db "Error: ", 0
.ple_errno_str:     db "errno ", 0
.ple_msg_enoent:    db "No such file or directory", 0
.ple_msg_eacces:    db "Permission denied", 0
.ple_msg_eexist:    db "File exists", 0
.ple_msg_enotdir:   db "Not a directory", 0
.ple_msg_eisdir:    db "Is a directory", 0
.ple_msg_einval:    db "Invalid argument", 0
.ple_msg_enotempty: db "Directory not empty", 0

; ============================================================================
; End of Part 2
; ============================================================================

; ASH native executor (milestone 1)
%include "ash/ash_exec.asm"
%include "ash/update.asm"
%include "ash/builtins.asm"
%include "ash/script.asm"
%include "ash/tools.asm"
%include "ash/highlight.asm"
