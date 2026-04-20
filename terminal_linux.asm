; ============================================================================
; ASM Terminal v2.0 - Full-featured terminal in x86-64 Assembly (NASM)
; Target: Linux x86-64, using raw syscalls (no libc)
; Port of the Windows version to Linux
; ============================================================================
bits 64
default rel

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
%define SYS_KILL            62
%define SYS_GETCWD          79
%define SYS_CHDIR           80
%define SYS_RENAME          82
%define SYS_MKDIR           83
%define SYS_RMDIR           84
%define SYS_UNLINK          87
%define SYS_READLINK        89
%define SYS_GETUID          102
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
%define SIGCONT             18

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
%define ENV_OVERLAY_COUNT   64
%define AT_FDCWD            -100
%define S_IFDIR             0o040000

; Timezone offset: PKT = UTC+5 = 18000 seconds
%define TZ_OFFSET_SECONDS   18000

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
                    db "  ASM Terminal v2.0 - x86-64 Assembly Shell", 10
                    db "  Type 'help' for available commands", 10
                    db 10, 0
    welcome_len     equ $ - welcome_msg - 1

    help_msg        db 10
                    db "  ASM Terminal v2.0 - Command Reference", 10
                    db "  =====================================================", 10
                    db 10
                    db "  NAVIGATION", 10
                    db "  ---------------------------------------------------", 10
                    db "    cd <path>       Change directory", 10
                    db "                    cd /home        go to /home", 10
                    db "                    cd ..           go up one level", 10
                    db "                    cd -            go to previous dir", 10
                    db "                    cd              show current dir", 10
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
                    db "    date            Show current date and time", 10
                    db "                    date   -> Fri Apr  3 08:14:01 PM PKT 2026", 10
                    db "    time            Same as date", 10
                    db "    uptime          Show system uptime", 10
                    db "                    uptime -> up 2 days, 05:30:12", 10
                    db "    free            Show memory usage", 10
                    db "                    free   -> MemTotal, MemFree, ...", 10
                    db "    calc <expr>     Integer calculator (+, -, *, /)", 10
                    db "                    calc 2 + 3          -> 5", 10
                    db "                    calc 100 / 3        -> 33", 10
                    db "                    calc 10 + 5 * 2     -> 30", 10
                    db "    source <file>   Execute commands from a file", 10
                    db "                    source setup.sh", 10
                    db "    help            This help message", 10
                    db "    exit            Exit the terminal", 10
                    db 10
                    db "  CUSTOMIZATION", 10
                    db "  ---------------------------------------------------", 10
                    db "    alias <n>=<cmd> Create a command alias", 10
                    db "                    alias ll=ls -la", 10
                    db "                    alias gs=git status", 10
                    db "                    alias          list all aliases", 10
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
                    db 10
                    db "  SHELL FEATURES", 10
                    db "  ---------------------------------------------------", 10
                    db "    cmd1 ; cmd2     Run multiple commands", 10
                    db "                    echo hi ; echo bye", 10
                    db "    cmd1 && cmd2    Run next only if prev succeeded", 10
                    db "                    mkdir d && cd d", 10
                    db "    cmd > file      Redirect output to file", 10
                    db "                    ls > files.txt", 10
                    db "    cmd >> file     Append output to file", 10
                    db "                    echo log >> out.txt", 10
                    db "    cmd < file      Redirect input from file", 10
                    db "    cmd | cmd       Pipe (handled by /bin/sh)", 10
                    db "                    ls | grep .asm", 10
                    db "    $VAR            Expand environment variable", 10
                    db "                    echo $HOME", 10
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

    ver_msg         db "ASM Terminal v2.0 [x86-64 NASM/Linux]", 10, 0
    ver_len         equ $ - ver_msg - 1
    err_cd_msg      db "Error: Could not change directory.", 10, 0
    err_cd_len      equ $ - err_cd_msg - 1
    err_exec_msg    db "Error: Could not execute command.", 10, 0
    err_exec_len    equ $ - err_exec_msg - 1
    err_file_msg    db "Error: Could not open file.", 10, 0
    err_copy_read_msg db "copy: read error from source.", 10, 0
    err_copy_read_len equ $ - err_copy_read_msg - 1
    err_copy_write_msg db "copy: write error to destination.", 10, 0
    err_copy_write_len equ $ - err_copy_write_msg - 1
    err_file_len    equ $ - err_file_msg - 1
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
        dq cmd_s_del,    handler_del,    3
        dq cmd_s_copy,   handler_copy,   4
        dq cmd_s_move,   handler_move,   4
        dq cmd_s_rename, handler_rename, 6
        dq cmd_s_set,    handler_set,    3
        dq cmd_s_pushd,  handler_pushd,  5
        dq cmd_s_alias,  handler_alias,  5
        dq cmd_s_source, handler_source, 6
        dq cmd_s_cat,    handler_type,   3
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
    git_prompt_pre  db 27, "[33m (", 0     ; " ("  in yellow
    git_prompt_post db ")", 27, "[0m", 0   ; ")"

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
    err_calc_usage  db "Usage: calc <expr>  (e.g. calc 2 + 3 * 4)", 10, 0
    err_calc_usage_len equ $ - err_calc_usage - 1
    err_div_zero    db "Error: Division by zero.", 10, 0
    err_div_zero_len equ $ - err_div_zero - 1

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
    str_pkt         db " PKT ", 0
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
    env_overlay         resb 64*512 ; 64 entries, each up to 512 bytes (NAME=VALUE)
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
    tab_prefix          resb MAX_PATH_BUF
    tab_prefix_len      resd 1
    tab_active          resb 1
    tab_dir_fd          resd 1      ; fd for opendir equivalent
    tab_find_handle     resq 1      ; alias for compatibility
    tab_dirent_buf      resb 8192
    ls_perms_buf        resb 16            ; rendered "drwxr-xr-x" + NUL
    tz_offset_cache     resq 1             ; cached TZ offset (seconds)
    tz_offset_resolved  resb 1             ; 0 = unresolved, 1 = resolved
    interactive_mode    resb 1             ; 1 = stdin & stdout are tty
    color_enabled       resb 1             ; 1 = ANSI/color permitted
    termios_probe_buf   resb 60             ; scratch for ioctl probe
    winch_pending       resb 1             ; set by SIGWINCH handler
    term_rows           resw 1             ; cached from TIOCGWINSZ
    term_cols           resw 1             ; cached from TIOCGWINSZ
    winch_sigaction_buf resb 32            ; sigaction struct for SIGWINCH
    merged_envp         resq 256            ; argv-style envp for child: 256 slots
    merged_envp_count   resd 1
    git_scratch_path    resb 4096          ; for walking up looking for .git
    git_head_buf        resb 512           ; contents of .git/HEAD
    git_branch          resb 128           ; extracted branch name (or NUL)
    tab_dirent_pos      resd 1      ; current position in dirent buffer
    tab_dirent_end      resd 1      ; end of valid data in dirent buffer
    tab_dirent_offset   resd 1      ; alias for offset tracking
    tab_dirent_bytes    resd 1      ; total bytes from getdents64
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
    compound_buf        resb MAX_INPUT  ; temp copy of full input for splitting

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
    grep_line_buf    resb 4096
    ; grep pattern buffer
    grep_pattern_buf resb 256
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

    ; Syntax highlighting scratch
    first_word_buf      resb 128                ; extracted first word

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
    ; Skip empty lines
    cmp byte [input_buf], 0
    je .main_loop

    ; Add to history and save to persistent file
    lea rdi, [input_buf]
    call history_add
    lea rdi, [input_buf]
    call history_save_entry

    ; OSC 133 C — output region begins
    lea rdi, [osc133_c]
    call print_cstring

    ; Execute command (supports ; and && compound commands)
    call execute_compound

    ; OSC 133 D;<exit_status> — end of command + exit code
    lea rdi, [osc133_d_pre]
    call print_cstring
    mov eax, [last_exit_status]
    call print_number
    lea rdi, [osc133_bel]
    call print_cstring

    jmp .main_loop

.main_eof:
    xor edi, edi
    mov eax, SYS_EXIT
    syscall

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

    ; Start assuming color is ok; disable if NO_COLOR set or TERM=dumb
    mov byte [color_enabled], 1

    lea rdi, [str_no_color]
    call getenv_internal
    test rax, rax
    jz .iom_check_term
    ; NO_COLOR must be non-empty per no-color.org spec
    cmp byte [rax], 0
    je .iom_check_term
    mov byte [color_enabled], 0
    jmp .iom_done

.iom_check_term:
    lea rdi, [str_term]
    call getenv_internal
    test rax, rax
    jz .iom_done
    mov rbx, rax
    lea rsi, [str_term_dumb]
    mov rdi, rbx
    call str_icompare
    test eax, eax
    jnz .iom_done
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
; ============================================================================
read_line_plain:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 16

    lea rbx, [input_buf]
    xor r12d, r12d                   ; r12 = offset (syscall preserves r12)

.rlp_loop:
    cmp r12d, MAX_INPUT - 1
    jge .rlp_terminate              ; full; discard rest of line silently
    mov edi, STDIN_FD
    mov rsi, rbx
    add rsi, r12
    mov edx, 1
    mov eax, SYS_READ
    syscall
    test rax, rax
    jz .rlp_eof
    js .rlp_eof
    movzx edx, byte [rbx + r12]
    cmp dl, 10                       ; LF ends the line
    je .rlp_terminate
    cmp dl, 13                       ; drop CR (CRLF line endings)
    je .rlp_loop
    inc r12d
    jmp .rlp_loop

.rlp_terminate:
    mov byte [rbx + r12], 0
    mov eax, 1
    jmp .rlp_done

.rlp_eof:
    test r12d, r12d
    jnz .rlp_terminate              ; flush pending bytes
    mov byte [rbx], 0
    xor eax, eax

.rlp_done:
    add rsp, 16
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; setup_raw_mode - Switch terminal to raw mode
; Uses ioctl TCGETS to save original settings, then modifies c_lflag to
; clear ICANON and ECHO, sets VMIN=1, VTIME=0, and applies with TCSETS.
; ============================================================================
setup_raw_mode:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    ; ioctl(STDIN_FD, TCGETS, &orig_termios)  - save original settings
    mov eax, SYS_IOCTL
    mov edi, STDIN_FD
    mov esi, TCGETS
    lea rdx, [orig_termios]
    syscall

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

    ; Enable bracketed paste mode so pasted content is wrapped in
    ; ESC[200~ ... ESC[201~ markers we can consume in read_key.
    lea rdi, [bracketed_paste_on]
    mov esi, bracketed_paste_on_len
    call print_string_len

    leave
    ret

; ============================================================================
; restore_terminal - Restore original terminal settings
; Called before exit to return terminal to its original state.
; ============================================================================
restore_terminal:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    ; Disable bracketed paste mode before restoring termios
    lea rdi, [bracketed_paste_off]
    mov esi, bracketed_paste_off_len
    call print_string_len

    ; Restore cursor shape + make sure cursor visible (TUI children may have changed)
    lea rdi, [cursor_shape_reset]
    mov esi, cursor_shape_reset_len
    call print_string_len
    lea rdi, [cursor_show]
    mov esi, cursor_show_len
    call print_string_len

    ; ioctl(STDIN_FD, TCSETS, &orig_termios)
    mov eax, SYS_IOCTL
    mov edi, STDIN_FD
    mov esi, TCSETS
    lea rdx, [orig_termios]
    syscall

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
; Reads 1 byte. If ESC (27), reads more bytes to decode CSI sequences:
;   ESC[A = Up, ESC[B = Down, ESC[C = Right, ESC[D = Left
;   ESC[H = Home, ESC[F = End, ESC[3~ = Delete
; Maps LF(10) -> VK_RETURN, DEL(127) -> VK_BACK, TAB(9) -> VK_TAB
;
; Output: [key_vkey] = virtual key code, [key_char] = ASCII char
; ============================================================================
read_key:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 24

    ; Clear output
    mov word [key_vkey], 0
    mov byte [key_char], 0

    ; Read 1 byte from stdin
    mov eax, SYS_READ
    mov edi, STDIN_FD
    lea rsi, [key_buf]
    mov edx, 1
    syscall
    cmp eax, 1
    jne .rk_done

    movzx ebx, byte [key_buf]

    ; Check for ESC (27) - potential escape sequence
    cmp bl, 27
    je .rk_escape

    ; Check for LF (10) -> map to VK_RETURN
    cmp bl, 10
    je .rk_return

    ; Check for DEL/Backspace (127) -> map to VK_BACK
    cmp bl, 127
    je .rk_backspace

    ; Check for TAB (9) -> map to VK_TAB
    cmp bl, 9
    je .rk_tab

    ; Check for Ctrl+C (3)
    cmp bl, 3
    je .rk_ctrlc

    ; Regular printable character or other
    mov [key_char], bl
    mov word [key_vkey], 0      ; no special vkey
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
    mov word [key_vkey], 0
    mov byte [key_char], 3
    jmp .rk_done

.rk_escape:
    ; Try to read next byte - could be CSI sequence
    mov eax, SYS_READ
    mov edi, STDIN_FD
    lea rsi, [key_buf + 1]
    mov edx, 1
    syscall
    cmp eax, 1
    jne .rk_esc_only

    cmp byte [key_buf + 1], '['
    je .rk_csi

    ; Not a CSI sequence, treat as just ESC
.rk_esc_only:
    mov byte [key_char], 27
    mov word [key_vkey], 0
    jmp .rk_done

.rk_csi:
    ; Read the CSI parameter byte(s)
    mov eax, SYS_READ
    mov edi, STDIN_FD
    lea rsi, [key_buf + 2]
    mov edx, 1
    syscall
    cmp eax, 1
    jne .rk_done

    movzx ebx, byte [key_buf + 2]

    ; Decode CSI sequences
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

    ; Check for extended sequences like ESC[3~ (Delete)
    cmp bl, '3'
    je .rk_maybe_delete
    cmp bl, '1'
    je .rk_maybe_home_ext
    cmp bl, '4'
    je .rk_maybe_end_ext
    cmp bl, '2'
    je .rk_maybe_paste

    ; Unknown CSI sequence
    jmp .rk_done

.rk_maybe_paste:
    ; Bracketed paste: ESC[200~ (start) or ESC[201~ (end). Consume
    ; up to and including '~' so it never enters the edit buffer.
    mov eax, SYS_READ
    mov edi, STDIN_FD
    lea rsi, [key_buf + 3]
    mov edx, 1
    syscall
    cmp eax, 1
    jne .rk_done
    cmp byte [key_buf + 3], '0'
    jne .rk_done                    ; not 20...; give up
    mov eax, SYS_READ
    mov edi, STDIN_FD
    lea rsi, [key_buf + 4]
    mov edx, 1
    syscall
    cmp eax, 1
    jne .rk_done
    ; Skip any remaining chars up to '~' (paste markers are short)
.rk_paste_skip:
    mov eax, SYS_READ
    mov edi, STDIN_FD
    lea rsi, [key_buf + 5]
    mov edx, 1
    syscall
    cmp eax, 1
    jne .rk_done
    cmp byte [key_buf + 5], '~'
    je .rk_done                     ; marker consumed, key was 0 → nothing inserted
    jmp .rk_paste_skip

.rk_maybe_delete:
    ; Read the tilde
    mov eax, SYS_READ
    mov edi, STDIN_FD
    lea rsi, [key_buf + 3]
    mov edx, 1
    syscall
    cmp eax, 1
    jne .rk_done
    cmp byte [key_buf + 3], '~'
    jne .rk_done
    mov word [key_vkey], VK_DELETE
    jmp .rk_done

.rk_maybe_home_ext:
    ; ESC[1~ = Home (some terminals)
    mov eax, SYS_READ
    mov edi, STDIN_FD
    lea rsi, [key_buf + 3]
    mov edx, 1
    syscall
    cmp eax, 1
    jne .rk_done
    cmp byte [key_buf + 3], '~'
    jne .rk_done
    mov word [key_vkey], VK_HOME
    jmp .rk_done

.rk_maybe_end_ext:
    ; ESC[4~ = End (some terminals)
    mov eax, SYS_READ
    mov edi, STDIN_FD
    lea rsi, [key_buf + 3]
    mov edx, 1
    syscall
    cmp eax, 1
    jne .rk_done
    cmp byte [key_buf + 3], '~'
    jne .rk_done
    mov word [key_vkey], VK_END
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
    jmp .rk_done

.rk_done:
    add rsp, 24
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

.rl_loop:
    ; Check for pending Ctrl+C
    cmp byte [ctrl_c_flag], 0
    jne .rl_ctrlc

    ; Read a key
    call read_key

    ; Load virtual key and ascii char
    movzx ebx, word [key_vkey]
    movzx r12d, byte [key_char]

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
    cmp r12d, 32
    jb .rl_loop
    cmp r12d, 126
    ja .rl_loop

    ; Buffer full?
    cmp dword [line_len], MAX_INPUT - 2
    jge .rl_loop

    ; Insert character at cursor position by shifting right
    mov ecx, [line_len]
    mov edx, [line_cursor]
.rl_shift_r:
    cmp ecx, edx
    jle .rl_ins
    lea rax, [line_buf]
    mov r8b, [rax + rcx - 1]
    mov [rax + rcx], r8b
    dec ecx
    jmp .rl_shift_r
.rl_ins:
    lea rax, [line_buf]
    mov [rax + rdx], r12b
    inc dword [line_len]
    inc dword [line_cursor]
    mov ecx, [line_len]
    mov byte [rax + rcx], 0
    call redraw_line
    jmp .rl_loop

.rl_enter:
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
    cmp dword [line_cursor], 0
    je .rl_loop
    mov ecx, [line_cursor]
    mov edx, [line_len]
    lea rdi, [line_buf]
.rl_bs_shift:
    cmp ecx, edx
    jge .rl_bs_end
    mov al, [rdi + rcx]
    mov [rdi + rcx - 1], al
    inc ecx
    jmp .rl_bs_shift
.rl_bs_end:
    dec dword [line_cursor]
    dec dword [line_len]
    mov ecx, [line_len]
    mov byte [rdi + rcx], 0
    call redraw_line
    jmp .rl_loop

.rl_delete:
    mov eax, [line_cursor]
    cmp eax, [line_len]
    jge .rl_loop
    mov ecx, [line_cursor]
    inc ecx
    mov edx, [line_len]
    lea rdi, [line_buf]
.rl_del_shift:
    cmp ecx, edx
    jge .rl_del_end
    mov al, [rdi + rcx]
    mov [rdi + rcx - 1], al
    inc ecx
    jmp .rl_del_shift
.rl_del_end:
    dec dword [line_len]
    mov ecx, [line_len]
    mov byte [rdi + rcx], 0
    call redraw_line
    jmp .rl_loop

.rl_left:
    cmp dword [line_cursor], 0
    je .rl_loop
    dec dword [line_cursor]
    call update_cursor_pos
    jmp .rl_loop

.rl_right:
    mov eax, [line_cursor]
    cmp eax, [line_len]
    jge .rl_loop
    inc dword [line_cursor]
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
    ; Reprint prompt using themed prompt function
    call print_prompt
    ; Redraw current line content and position cursor
    mov edx, [line_len]
    test edx, edx
    jz .rl_ctrl_l_cur
    lea rdi, [line_buf]
    mov esi, edx
    call print_string_len
.rl_ctrl_l_cur:
    call update_cursor_pos
    jmp .rl_loop

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

; ============================================================================
; redraw_line - Redraw the full prompt and line buffer
;
; Writes: \r + ANSI green + path_buf + ANSI white + "> " + ANSI default
;         + line_buf content + ANSI clear-to-eol
; Then positions cursor at the correct column using ESC[{col}G.
; ============================================================================
redraw_line:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 32

    ; Move to start of line with \r
    lea rdi, [str_cr]
    mov esi, 1
    call print_string_len

    ; Reprint the prompt using theme-aware function
    call print_prompt

    ; --- Syntax highlighting for line content ---
    mov r12d, [line_len]
    test r12d, r12d
    jz .rd_clear                    ; empty line, nothing to highlight

    ; Extract the first word from line_buf into first_word_buf
    lea rsi, [line_buf]
    lea rdi, [first_word_buf]
    xor ecx, ecx                    ; index / length of first word

.rd_extract_word:
    cmp ecx, 126                    ; guard buffer size
    jge .rd_word_done
    movzx eax, byte [rsi + rcx]
    test al, al
    jz .rd_word_done
    cmp al, ' '
    je .rd_word_done
    mov [rdi + rcx], al
    inc ecx
    jmp .rd_extract_word

.rd_word_done:
    mov byte [rdi + rcx], 0         ; null-terminate first_word_buf
    mov r13d, ecx                   ; r13d = first word length

    test r13d, r13d
    jz .rd_print_plain              ; no first word

    ; Check if this command exists
    lea rdi, [first_word_buf]
    mov esi, r13d
    call check_command_exists       ; returns eax = 1 if valid, 0 if not

    test eax, eax
    jz .rd_invalid_cmd

    ; --- Valid command: print first word in green ---
    lea rdi, [ansi_green]
    mov esi, ansi_green_len
    call print_string_len

    lea rdi, [line_buf]
    mov esi, r13d
    call print_string_len

    lea rdi, [ansi_default]
    mov esi, ansi_default_len
    call print_string_len

    jmp .rd_print_rest

.rd_invalid_cmd:
    ; --- Invalid command: print first word in red ---
    lea rdi, [ansi_red]
    mov esi, ansi_red_len
    call print_string_len

    lea rdi, [line_buf]
    mov esi, r13d
    call print_string_len

    lea rdi, [ansi_default]
    mov esi, ansi_default_len
    call print_string_len

.rd_print_rest:
    ; Print the rest of line_buf (after first word) in default color
    mov eax, r12d                   ; total line_len
    sub eax, r13d                   ; remaining chars
    jle .rd_clear                   ; nothing left

    lea rdi, [line_buf + r13]       ; use r13 as 64-bit offset
    mov esi, eax
    call print_string_len
    jmp .rd_clear

.rd_print_plain:
    ; No recognizable first word; just print entire line_buf
    lea rdi, [line_buf]
    mov esi, r12d
    call print_string_len

.rd_clear:
    ; Clear from cursor to end of line (removes any leftover chars)
    lea rdi, [ansi_clear_eol]
    mov esi, ansi_clear_eol_len
    call print_string_len

    ; Position cursor: column = prompt_total_len + line_cursor + 1 (1-based)
    mov eax, [prompt_total_len]
    add eax, [line_cursor]
    inc eax                     ; 1-based column for ANSI
    call write_ansi_cursor_col

    add rsp, 32
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; update_cursor_pos - Move cursor to correct position in line
; Computes column = prompt_total_len + line_cursor + 1 (1-based)
; and writes ESC[{col}G escape sequence.
; ============================================================================
update_cursor_pos:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    mov eax, [prompt_total_len]
    add eax, [line_cursor]
    inc eax                     ; 1-based
    call write_ansi_cursor_col

    leave
    ret

; ============================================================================
; write_ansi_cursor_col - Write ESC[{number}G to stdout
; eax = column number (1-based)
; Builds the escape sequence in ansi_num_buf and writes it.
; ============================================================================
write_ansi_cursor_col:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 16

    mov ebx, eax               ; save column number

    ; Build ESC[
    lea r12, [ansi_num_buf]
    mov byte [r12], 27          ; ESC
    mov byte [r12 + 1], '['
    lea rdi, [r12 + 2]

    ; Convert number to decimal string
    mov eax, ebx
    call uint_to_str            ; rdi = buffer, eax = number, returns length in ecx

    ; Append 'G'
    lea rax, [r12 + 2]
    add rax, rcx                ; point past the number digits
    mov byte [rax], 'G'
    inc rax
    mov byte [rax], 0           ; null terminate (not needed for write, but safe)

    ; Calculate total length: 2 (ESC[) + number_len + 1 (G)
    lea esi, [ecx + 3]          ; 2 + digits + 1

    ; Write it
    lea rdi, [ansi_num_buf]
    call print_string_len

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

    ; Compare with new string
    mov rdi, r12
    ; rsi already points to last entry
    call str_icompare
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
    mov byte [history_browsing], 0

    add rsp, 24
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; history_navigate_up - Navigate to the previous (older) history entry
; Saves current line on first navigation, then walks backwards through
; the circular buffer.
; ============================================================================
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

    ; Save current line if this is the first navigation press
    cmp byte [history_browsing], 0
    jne .hnu_nav
    mov byte [history_browsing], 1
    lea rdi, [history_saved]
    lea rsi, [line_buf]
    call str_copy

.hnu_nav:
    ; Move nav index backwards with wrap
    mov eax, [history_nav_idx]
    test eax, eax
    jnz .hnu_dec
    mov eax, HISTORY_COUNT
.hnu_dec:
    dec eax

    ; Check if we've reached the oldest entry (cannot go further back)
    mov ecx, [history_write_idx]
    sub ecx, [history_count]
    jge .hnu_check
    add ecx, HISTORY_COUNT
.hnu_check:
    cmp eax, ecx
    je .hnu_done                ; at oldest entry, stop

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

    ; Move nav index forward with wrap
    mov eax, [history_nav_idx]
    inc eax
    cmp eax, HISTORY_COUNT
    jl .hnd_nowrap
    xor eax, eax
.hnd_nowrap:
    ; Check if we've reached the write pointer (back to current)
    cmp eax, [history_write_idx]
    je .hnd_restore

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
; Uses line_buf/line_cursor to find prefix, opens directory, iterates entries.
; ============================================================================
tab_complete:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56

    ; ------ Check if we are continuing a previous tab cycle ------
    cmp byte [tab_active], 1
    je .tc_next

    ; ====== FIRST TAB: extract prefix, open dir, find first match ======

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

    ; Split into directory part and name part
    ; Find last '/' in tab_name_prefix
    lea rdi, [tab_name_prefix]
    mov ecx, ebx
    xor r14d, r14d                  ; r14d = 0 means no slash found
    mov r15d, 0                     ; r15d = position after last slash (name start)
.tc_find_slash:
    test ecx, ecx
    jz .tc_slash_done
    dec ecx
    cmp byte [rdi + rcx], '/'
    jne .tc_find_slash
    ; Found slash at position ecx
    mov r14d, 1                     ; flag: slash found
    lea r15d, [ecx + 1]            ; name part starts after slash
    jmp .tc_slash_done2
.tc_slash_done:
    ; No slash found -- directory is ".", name prefix is the whole word
    xor r15d, r15d                  ; name starts at 0
.tc_slash_done2:

    ; Open the directory
    cmp r14d, 0
    je .tc_open_dot

    ; There is a directory part: copy dir path to find_pattern, null-terminate at slash
    lea rdi, [find_pattern]
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
    ; If r15d > 0, we have "dir/" -- null-terminate. If the prefix was just "/",
    ; keep the "/" itself so we open root.
    cmp r15d, 1
    jle .tc_dir_root
    mov byte [rdi + rcx - 1], 0    ; replace the trailing '/' with null
    jmp .tc_do_open_dir
.tc_dir_root:
    mov byte [rdi + rcx], 0
.tc_do_open_dir:
    lea rdi, [find_pattern]
    jmp .tc_open_call

.tc_open_dot:
    ; Open current directory "."
    lea rdi, [str_dot]

.tc_open_call:
    ; open(dir_path, O_RDONLY | O_DIRECTORY, 0)
    mov eax, SYS_OPEN
    mov esi, O_RDONLY | O_DIRECTORY
    xor edx, edx
    syscall
    test rax, rax
    js .tc_done                     ; open failed

    mov [tab_dir_fd], eax           ; save directory fd

    ; Read first batch of dirents
    mov edi, [tab_dir_fd]
    lea rsi, [dirent_buf]
    mov edx, DIRENT_BUF_SIZE
    mov eax, SYS_GETDENTS64
    syscall
    test rax, rax
    jle .tc_close_done              ; no entries or error

    mov [tab_dirent_bytes], eax
    mov dword [tab_dirent_offset], 0

    mov byte [tab_active], 1
    jmp .tc_find_match

    ; ====== NEXT TAB: continue from where we left off ======
.tc_next:
    ; Advance past current entry
    lea rsi, [dirent_buf]
    mov eax, [tab_dirent_offset]
    movzx ecx, word [rsi + rax + DIRENT_D_RECLEN]
    add eax, ecx
    mov [tab_dirent_offset], eax

    ; ====== FIND MATCH: iterate dirent buffer ======
.tc_find_match:
    lea rsi, [dirent_buf]
    mov eax, [tab_dirent_offset]

.tc_entry_loop:
    cmp eax, [tab_dirent_bytes]
    jge .tc_refill                  ; exhausted current buffer

    ; Get pointer to this dirent entry
    lea rbx, [rsi + rax]           ; rbx = dirent entry base

    ; Get d_name
    lea r13, [rbx + DIRENT_D_NAME]

    ; Skip "." and ".."
    cmp byte [r13], '.'
    jne .tc_check_prefix
    cmp byte [r13 + 1], 0
    je .tc_skip_entry
    cmp byte [r13 + 1], '.'
    jne .tc_check_prefix
    cmp byte [r13 + 2], 0
    je .tc_skip_entry

.tc_check_prefix:
    ; Check if d_name starts with our name prefix (after the last '/')
    ; The name prefix to match is tab_name_prefix[r15d..end]
    lea r8, [tab_name_prefix]
    add r8, r15                     ; r8 = pointer to name-only prefix
    mov ecx, [tab_name_prefix_len]
    sub ecx, r15d                   ; ecx = length of name-only prefix

    ; If prefix length is 0, everything matches
    test ecx, ecx
    jz .tc_match_found

    ; Compare ecx chars
    xor edx, edx
.tc_cmp_loop:
    cmp edx, ecx
    jge .tc_match_found
    movzx edi, byte [r8 + rdx]
    movzx r9d, byte [r13 + rdx]
    ; Case-insensitive comparison
    cmp dil, 'A'
    jb .tc_cmp_s2
    cmp dil, 'Z'
    ja .tc_cmp_s2
    add dil, 32
.tc_cmp_s2:
    cmp r9b, 'A'
    jb .tc_cmp_check
    cmp r9b, 'Z'
    ja .tc_cmp_check
    add r9b, 32
.tc_cmp_check:
    cmp dil, r9b
    jne .tc_skip_entry
    inc edx
    jmp .tc_cmp_loop

.tc_match_found:
    ; Save offset for next iteration
    mov eax, [tab_dirent_offset]
    ; (tab_dirent_offset already points to this entry)

    ; Build the replacement text:
    ; If there was a dir prefix, it's tab_name_prefix[0..r15d-1] + d_name
    ; Otherwise just d_name

    ; Replace text in line_buf starting at tab_base_pos
    lea r8, [line_buf]
    mov ecx, [tab_base_pos]
    add r8, rcx                     ; r8 = insertion point

    ; Copy dir prefix part first (if any)
    xor edx, edx
    cmp r15d, 0
    je .tc_copy_name
    lea r9, [tab_name_prefix]
.tc_copy_dir_prefix:
    cmp edx, r15d
    jge .tc_copy_name
    movzx eax, byte [r9 + rdx]
    mov [r8 + rdx], al
    inc edx
    jmp .tc_copy_dir_prefix

.tc_copy_name:
    ; edx = current offset in insertion, copy d_name
    xor ecx, ecx
.tc_copy_dname:
    movzx eax, byte [r13 + rcx]
    test al, al
    jz .tc_copy_done
    mov [r8 + rdx], al
    inc edx
    inc ecx
    jmp .tc_copy_dname

.tc_copy_done:
    ; Check if it's a directory -- append '/'
    movzx eax, byte [rbx + DIRENT_D_TYPE]
    cmp al, DT_DIR
    jne .tc_finalize
    mov byte [r8 + rdx], '/'
    inc edx

.tc_finalize:
    ; Update line_len and line_cursor
    mov eax, [tab_base_pos]
    add eax, edx
    mov [line_len], eax
    mov [line_cursor], eax
    lea rax, [line_buf]
    mov ecx, [line_len]
    mov byte [rax + rcx], 0

    ; Redraw the line
    call redraw_line
    jmp .tc_done

.tc_skip_entry:
    ; Advance to next dirent entry
    lea rsi, [dirent_buf]
    mov eax, [tab_dirent_offset]
    movzx ecx, word [rsi + rax + DIRENT_D_RECLEN]
    add eax, ecx
    mov [tab_dirent_offset], eax
    jmp .tc_entry_loop

.tc_refill:
    ; Try to read more dirents (wrap around: lseek to 0 and re-read)
    mov edi, [tab_dir_fd]
    xor esi, esi                    ; offset = 0
    xor edx, edx                    ; SEEK_SET = 0
    mov eax, SYS_LSEEK
    syscall

    mov edi, [tab_dir_fd]
    lea rsi, [dirent_buf]
    mov edx, DIRENT_BUF_SIZE
    mov eax, SYS_GETDENTS64
    syscall
    test rax, rax
    jle .tc_close_done              ; nothing more

    mov [tab_dirent_bytes], eax
    mov dword [tab_dirent_offset], 0
    jmp .tc_find_match

.tc_close_done:
    ; Close the directory fd
    mov edi, [tab_dir_fd]
    mov eax, SYS_CLOSE
    syscall
    mov dword [tab_dir_fd], -1
    mov byte [tab_active], 0

.tc_done:
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; dispatch_command - Expand env, check alias, parse redir, dispatch
; ============================================================================
dispatch_command:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 32

    ; Assume success by default (overwritten on failure)
    mov dword [last_exit_status], 0

    ; Expand environment variables ($VAR, ${VAR})
    call expand_env_vars

    ; Check aliases
    call check_alias

    ; Check for pipe '|' - if found, pass to external (sh -c)
    lea rdi, [input_buf]
.dc_pipe_check:
    mov al, [rdi]
    test al, al
    jz .dc_no_pipe
    cmp al, '|'
    je .dc_external
    inc rdi
    jmp .dc_pipe_check

.dc_no_pipe:
    ; Parse redirection (>, >>, <)
    call parse_redirection

    ; Try exact match table
    lea r12, [cmd_table_exact]
.dc_exact:
    mov rdi, [r12]                  ; command name pointer
    test rdi, rdi
    jz .dc_prefix                   ; end of table

    ; Compare input_buf with this command name (case-insensitive)
    lea rdi, [input_buf]
    mov rsi, [r12]
    call str_icompare
    test eax, eax
    jz .dc_exact_found
    add r12, 16                     ; next entry (2 qwords)
    jmp .dc_exact

.dc_exact_found:
    mov rax, [r12 + 8]             ; handler address
    xor edi, edi                    ; no args
    call rax
    jmp .dc_done

.dc_prefix:
    ; Try prefix match table
    lea r12, [cmd_table_prefix]
.dc_pfx_loop:
    mov rdi, [r12]                  ; command name pointer
    test rdi, rdi
    jz .dc_external                 ; end of table, try external

    mov r13d, [r12 + 16]           ; name length (3rd qword, lower dword)

    lea rdi, [input_buf]
    mov rsi, [r12]
    mov edx, r13d
    call str_icompare_n
    test eax, eax
    jnz .dc_pfx_next

    ; Check char after the prefix
    lea rax, [input_buf]
    movzx eax, byte [rax + r13]
    cmp al, ' '
    je .dc_pfx_args
    cmp al, 0
    je .dc_pfx_noargs

.dc_pfx_next:
    add r12, 24                     ; next entry (3 qwords)
    jmp .dc_pfx_loop

.dc_pfx_args:
    ; Handler with arguments
    mov rbx, [r12 + 8]             ; handler address
    lea rdi, [input_buf]
    add rdi, r13
    inc rdi                         ; skip the space
    call skip_spaces                ; rax = first non-space
    mov rdi, rax                    ; args in rdi
    call rbx
    jmp .dc_done

.dc_pfx_noargs:
    mov rax, [r12 + 8]             ; handler address
    xor edi, edi                    ; no args
    call rax
    jmp .dc_done

.dc_external:
    call execute_external

.dc_done:
    call restore_redirection

    add rsp, 32
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; expand_env_vars - Replace $VAR and ${VAR} in input_buf with values
; Linux uses $VAR instead of Windows %VAR%
; ============================================================================
expand_env_vars:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16

    lea r12, [input_buf]           ; source pointer
    lea r13, [env_expand_buf]      ; destination pointer
    lea r14, [env_expand_buf + 1000] ; rough end guard
    mov byte [rbp - 8], 1          ; at-word-start flag

.ev_loop:
    movzx eax, byte [r12]
    test al, al
    jz .ev_done

    cmp al, '$'
    je .ev_dollar

    cmp al, '~'
    jne .ev_regular
    cmp byte [rbp - 8], 0          ; only expand at word start
    je .ev_regular
    movzx ecx, byte [r12 + 1]
    test cl, cl
    jz .ev_tilde
    cmp cl, '/'
    je .ev_tilde
    cmp cl, ' '
    je .ev_tilde
    jmp .ev_regular

.ev_regular:
    ; Regular character -- copy through (bounded)
    cmp r13, r14
    jae .ev_done
    mov [r13], al
    inc r12
    inc r13
    mov byte [rbp - 8], 0
    cmp al, ' '
    jne .ev_loop
    mov byte [rbp - 8], 1
    jmp .ev_loop

.ev_tilde:
    inc r12                         ; consume the tilde
    lea rdi, [str_home]
    call getenv_internal
    test rax, rax
    jz .ev_tilde_literal
    mov rcx, rax
.ev_tilde_cp:
    movzx eax, byte [rcx]
    test al, al
    jz .ev_tilde_done
    cmp r13, r14
    jae .ev_done
    mov [r13], al
    inc r13
    inc rcx
    jmp .ev_tilde_cp
.ev_tilde_done:
    mov byte [rbp - 8], 0
    jmp .ev_loop

.ev_tilde_literal:
    cmp r13, r14
    jae .ev_done
    mov byte [r13], '~'
    inc r13
    mov byte [rbp - 8], 0
    jmp .ev_loop

.ev_dollar:
    inc r12                         ; skip '$'
    movzx eax, byte [r12]

    ; Check for ${VAR} form
    cmp al, '{'
    je .ev_brace

    ; $VAR form: read alphanumeric/underscore chars
    lea rdi, [env_var_name]
    xor r15d, r15d                  ; length of var name
.ev_read_name:
    movzx eax, byte [r12 + r15]
    ; Check if alphanumeric or underscore
    cmp al, '_'
    je .ev_name_ok
    cmp al, 'A'
    jb .ev_name_end
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
    mov [rdi + r15], al
    inc r15d
    jmp .ev_read_name

.ev_name_end:
    test r15d, r15d
    jz .ev_literal_dollar           ; no name chars after $, copy literal $
    mov byte [rdi + r15], 0
    add r12, r15                    ; advance source past the name
    jmp .ev_lookup

.ev_brace:
    inc r12                         ; skip '{'
    lea rdi, [env_var_name]
    xor r15d, r15d
.ev_brace_loop:
    movzx eax, byte [r12 + r15]
    test al, al
    jz .ev_literal_dollar_brace     ; unterminated ${
    cmp al, '}'
    je .ev_brace_end
    mov [rdi + r15], al
    inc r15d
    jmp .ev_brace_loop

.ev_brace_end:
    test r15d, r15d
    jz .ev_brace_empty
    mov byte [rdi + r15], 0
    add r12, r15
    inc r12                         ; skip '}'
    jmp .ev_lookup

.ev_brace_empty:
    ; ${} -- just skip it
    inc r12                         ; skip '}'
    jmp .ev_loop

.ev_literal_dollar:
    cmp r13, r14
    jae .ev_done
    mov byte [r13], '$'
    inc r13
    jmp .ev_loop

.ev_literal_dollar_brace:
    ; Unterminated ${ -- copy literal "${" and continue
    cmp r13, r14
    jae .ev_done
    mov byte [r13], '$'
    inc r13
    cmp r13, r14
    jae .ev_done
    mov byte [r13], '{'
    inc r13
    jmp .ev_loop

.ev_lookup:
    ; env_var_name holds the variable name, look it up
    lea rdi, [env_var_name]
    call getenv_internal
    test rax, rax
    jz .ev_loop                     ; variable not found, output nothing

    ; Copy value to output (bounded)
    mov rcx, rax
.ev_cpval:
    movzx eax, byte [rcx]
    test al, al
    jz .ev_loop
    cmp r13, r14
    jae .ev_done
    mov [r13], al
    inc r13
    inc rcx
    jmp .ev_cpval

.ev_done:
    mov byte [r13], 0

    ; Copy result back to input_buf
    lea rdi, [input_buf]
    lea rsi, [env_expand_buf]
    call str_copy

    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    ret

; ============================================================================
; check_alias - If first word matches an alias, expand it
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

.ca_done:
    add rsp, 24
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; parse_redirection - Scan input_buf for > >> <, open files, clean command
; Uses Linux open() syscall instead of CreateFileA.
; ============================================================================
parse_redirection:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    sub rsp, 24

    mov byte [redir_stdout_active], 0
    mov byte [redir_stdin_active], 0
    mov byte [redir_append], 0
    mov dword [redir_stdout_fd], -1
    mov dword [redir_stdin_fd], -1

    lea r12, [input_buf]           ; source pointer
    lea r13, [cleaned_cmd_buf]     ; destination (cleaned command)

.pr_loop:
    movzx eax, byte [r12]
    test al, al
    jz .pr_finish
    cmp al, '>'
    je .pr_out
    cmp al, '<'
    je .pr_in

    ; Regular char -- copy to cleaned buf
    mov [r13], al
    inc r12
    inc r13
    jmp .pr_loop

.pr_out:
    inc r12
    ; Check for >> (append)
    cmp byte [r12], '>'
    jne .pr_out_create
    inc r12
    mov byte [redir_append], 1

.pr_out_create:
    ; Skip spaces after > or >>
.pr_skip1:
    cmp byte [r12], ' '
    jne .pr_fname_out
    inc r12
    jmp .pr_skip1

.pr_fname_out:
    ; Copy filename
    lea r14, [redir_filename]
.pr_cpfn1:
    movzx eax, byte [r12]
    test al, al
    jz .pr_cpfn1_done
    cmp al, ' '
    je .pr_cpfn1_done
    cmp al, '>'
    je .pr_cpfn1_done
    cmp al, '<'
    je .pr_cpfn1_done
    mov [r14], al
    inc r12
    inc r14
    jmp .pr_cpfn1
.pr_cpfn1_done:
    mov byte [r14], 0

    ; Open file for writing
    lea rdi, [redir_filename]
    cmp byte [redir_append], 0
    jne .pr_open_append

    ; Truncate mode: O_WRONLY | O_CREAT | O_TRUNC
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    jmp .pr_do_open_out
.pr_open_append:
    ; Append mode: O_WRONLY | O_CREAT | O_APPEND
    mov esi, O_WRONLY | O_CREAT | O_APPEND
.pr_do_open_out:
    mov edx, PERM_0644
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .pr_loop                     ; open failed, skip
    mov [redir_stdout_fd], eax
    mov byte [redir_stdout_active], 1
    jmp .pr_loop

.pr_in:
    inc r12
    ; Skip spaces after <
.pr_skip2:
    cmp byte [r12], ' '
    jne .pr_fname_in
    inc r12
    jmp .pr_skip2

.pr_fname_in:
    lea r14, [redir_filename]
.pr_cpfn2:
    movzx eax, byte [r12]
    test al, al
    jz .pr_cpfn2_done
    cmp al, ' '
    je .pr_cpfn2_done
    cmp al, '>'
    je .pr_cpfn2_done
    cmp al, '<'
    je .pr_cpfn2_done
    mov [r14], al
    inc r12
    inc r14
    jmp .pr_cpfn2
.pr_cpfn2_done:
    mov byte [r14], 0

    ; Open file for reading: O_RDONLY
    lea rdi, [redir_filename]
    mov esi, O_RDONLY
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .pr_loop                     ; open failed, skip
    mov [redir_stdin_fd], eax
    mov byte [redir_stdin_active], 1
    jmp .pr_loop

.pr_finish:
    ; Strip trailing spaces from cleaned command
    lea rax, [cleaned_cmd_buf]
.pr_strip:
    cmp r13, rax
    je .pr_strip_done
    cmp byte [r13 - 1], ' '
    jne .pr_strip_done
    dec r13
    jmp .pr_strip
.pr_strip_done:
    mov byte [r13], 0

    ; Copy cleaned command back to input_buf
    lea rdi, [input_buf]
    lea rsi, [cleaned_cmd_buf]
    call str_copy

    add rsp, 24
    pop r14
    pop r13
    pop r12
    pop rbp
    ret

; ============================================================================
; restore_redirection - Close redirect file descriptors
; ============================================================================
restore_redirection:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    cmp byte [redir_stdout_active], 0
    je .rr_stdin
    mov edi, [redir_stdout_fd]
    mov eax, SYS_CLOSE
    syscall
    mov byte [redir_stdout_active], 0
    mov dword [redir_stdout_fd], -1

.rr_stdin:
    cmp byte [redir_stdin_active], 0
    je .rr_done
    mov edi, [redir_stdin_fd]
    mov eax, SYS_CLOSE
    syscall
    mov byte [redir_stdin_active], 0
    mov dword [redir_stdin_fd], -1

.rr_done:
    leave
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
handler_exit:
    ; Restore terminal to cooked mode before exiting
    call restore_terminal

    ; sys_exit(0)
    xor edi, edi
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

    ; Add timezone offset (configurable via $ASM_TZ, default PKT UTC+5)
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

    ; 6. " PKT "
    lea rdi, [str_pkt]
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
; resolve_tz_offset — return tz offset in seconds (rax)
; Reads $ASM_TZ once, caches result. Accepts decimal integer with optional
; leading '-'. Falls back to TZ_OFFSET_SECONDS if unset or unparseable.
; ============================================================================
resolve_tz_offset:
    cmp byte [tz_offset_resolved], 0
    jne .rto_cached

    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 8

    lea rdi, [tz_env_name_str]
    call getenv_internal
    test rax, rax
    jz .rto_default

    ; Parse signed integer from [rax]
    mov rbx, rax
    xor r8d, r8d                    ; sign flag (0 = +, 1 = -)
    cmp byte [rbx], '-'
    jne .rto_plus
    mov r8d, 1
    inc rbx
    jmp .rto_parse
.rto_plus:
    cmp byte [rbx], '+'
    jne .rto_parse
    inc rbx
.rto_parse:
    xor rax, rax
    xor r9d, r9d                    ; digits seen
.rto_digit:
    movzx ecx, byte [rbx]
    cmp cl, '0'
    jb .rto_done_parse
    cmp cl, '9'
    ja .rto_done_parse
    sub cl, '0'
    imul rax, rax, 10
    add rax, rcx
    inc rbx
    inc r9d
    jmp .rto_digit
.rto_done_parse:
    test r9d, r9d
    jz .rto_default
    test r8d, r8d
    jz .rto_store
    neg rax
.rto_store:
    mov [tz_offset_cache], rax
    mov byte [tz_offset_resolved], 1
    add rsp, 8
    pop rbx
    pop rbp
    ret

.rto_default:
    mov qword [tz_offset_cache], TZ_OFFSET_SECONDS
    mov byte [tz_offset_resolved], 1
    add rsp, 8
    pop rbx
    pop rbp
    ; fall through

.rto_cached:
    mov rax, [tz_offset_cache]
    ret

; ---------- handler_time ----------
; Same output as handler_date
handler_time:
    jmp handler_date

; ---------- handler_echo ----------
handler_echo:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 8

    test rdi, rdi
    jz .he_empty
    cmp byte [rdi], 0
    je .he_empty

    mov rbx, rdi                    ; rbx = current arg ptr
    xor r12d, r12d                  ; r12 bit 0 = -n, bit 1 = -e

    ; --- Parse leading flags ---
.he_flag_loop:
    ; skip spaces between flags
.he_skip_sp:
    cmp byte [rbx], ' '
    jne .he_check_flag
    inc rbx
    jmp .he_skip_sp
.he_check_flag:
    cmp byte [rbx], '-'
    jne .he_parse_done
    cmp byte [rbx + 1], 'n'
    jne .he_try_e
    cmp byte [rbx + 2], 0
    je .he_set_n
    cmp byte [rbx + 2], ' '
    jne .he_parse_done
.he_set_n:
    or r12d, 1
    add rbx, 2
    jmp .he_flag_loop
.he_try_e:
    cmp byte [rbx + 1], 'e'
    jne .he_parse_done
    cmp byte [rbx + 2], 0
    je .he_set_e
    cmp byte [rbx + 2], ' '
    jne .he_parse_done
.he_set_e:
    or r12d, 2
    add rbx, 2
    jmp .he_flag_loop

.he_parse_done:
    ; Skip one leading space after flags
    cmp byte [rbx], ' '
    jne .he_emit
    inc rbx

.he_emit:
    ; If -e, expand backslash escapes into a temp buffer; else print as-is
    test r12d, 2
    jnz .he_expand
    mov rdi, rbx
    call print_cstring
    jmp .he_terminator

.he_expand:
    lea rdi, [env_expand_buf]       ; reuse 1 KB scratch
    mov rsi, rbx
.he_exp_loop:
    movzx eax, byte [rsi]
    test al, al
    jz .he_exp_done
    cmp al, '\'
    jne .he_exp_copy
    movzx eax, byte [rsi + 1]
    cmp al, 'n'
    je .he_exp_newline
    cmp al, 't'
    je .he_exp_tab
    cmp al, 'r'
    je .he_exp_cr
    cmp al, '\'
    je .he_exp_back
    cmp al, '0'
    je .he_exp_nul
    ; unknown escape -> keep literal backslash
    mov byte [rdi], '\'
    inc rdi
    inc rsi
    jmp .he_exp_loop

.he_exp_newline:
    mov byte [rdi], 10
    inc rdi
    add rsi, 2
    jmp .he_exp_loop
.he_exp_tab:
    mov byte [rdi], 9
    inc rdi
    add rsi, 2
    jmp .he_exp_loop
.he_exp_cr:
    mov byte [rdi], 13
    inc rdi
    add rsi, 2
    jmp .he_exp_loop
.he_exp_back:
    mov byte [rdi], '\'
    inc rdi
    add rsi, 2
    jmp .he_exp_loop
.he_exp_nul:
    add rsi, 2
    jmp .he_exp_loop                ; drop NULs silently (can't embed in cstring)

.he_exp_copy:
    mov byte [rdi], al
    inc rdi
    inc rsi
    jmp .he_exp_loop

.he_exp_done:
    mov byte [rdi], 0
    lea rdi, [env_expand_buf]
    call print_cstring

.he_terminator:
    test r12d, 1
    jnz .he_done                    ; -n suppresses trailing newline
    call print_newline
    jmp .he_done

.he_empty:
    call print_newline
.he_done:
    add rsp, 8
    pop r12
    pop rbx
    leave
    ret

; ---------- handler_title ----------
; Set terminal title using ANSI escape: "\e]0;<title>\a"
handler_title:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 8

    test rdi, rdi
    jz .ht_done
    cmp byte [rdi], 0
    je .ht_done
    mov rbx, rdi

    ; Write "\e]0;"
    lea rdi, [ansi_title_pre]
    call print_cstring

    ; Write the title text
    mov rdi, rbx
    call print_cstring

    ; Write BEL (0x07) -- the ansi_title_post should contain this
    lea rdi, [ansi_title_post]
    call print_cstring

.ht_done:
    add rsp, 8
    pop rbx
    pop rbp
    ret

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
    mov r12d, eax                   ; r12d = bg index (0-15)

    ; Second hex digit = foreground
    movzx eax, byte [rbx + 1]
    call hex_to_int
    mov r13d, eax                   ; r13d = fg index (0-15)

    ; Convert fg index to ANSI code
    ; 0-7: normal (30 + win_to_ansi[n]), 8-15: bright (90 + win_to_ansi[n-8])
    lea rax, [win_to_ansi]
    cmp r13d, 8
    jge .hco_fg_bright
    movzx r13d, byte [rax + r13]
    add r13d, 30                    ; normal fg: 30-37
    jmp .hco_fg_set
.hco_fg_bright:
    mov ecx, r13d
    sub ecx, 8
    movzx r13d, byte [rax + rcx]
    add r13d, 90                    ; bright fg: 90-97
.hco_fg_set:

    ; Convert bg index to ANSI code
    ; 0-7: normal (40 + win_to_ansi[n]), 8-15: bright (100 + win_to_ansi[n-8])
    lea rax, [win_to_ansi]
    cmp r12d, 8
    jge .hco_bg_bright
    movzx r12d, byte [rax + r12]
    add r12d, 40                    ; normal bg: 40-47
    jmp .hco_bg_set
.hco_bg_bright:
    mov ecx, r12d
    sub ecx, 8
    movzx r12d, byte [rax + rcx]
    add r12d, 100                   ; bright bg: 100-107
.hco_bg_set:

    ; Build ANSI sequence: ESC [ <fg> ; <bg> m
    lea rdi, [num_buf]
    mov byte [rdi], 0x1B            ; ESC
    mov byte [rdi+1], '['
    mov r8d, 2                      ; write offset

    ; Write fg number (2-3 digits)
    mov eax, r13d
    xor edx, edx
    mov ecx, 100
    div ecx                         ; eax=hundreds, edx=remainder
    test eax, eax
    jz .hco_fg_no100
    add al, '0'
    lea rax, [num_buf]
    mov [rax + r8], al
    inc r8d
    mov eax, edx
    xor edx, edx
    mov ecx, 10
    div ecx
    add al, '0'
    lea rax, [num_buf]
    mov [rax + r8], al
    inc r8d
    add dl, '0'
    mov [rax + r8], dl
    inc r8d
    jmp .hco_fg_written
.hco_fg_no100:
    mov eax, edx
    xor edx, edx
    mov ecx, 10
    div ecx
    test al, al
    jz .hco_fg_1dig
    add al, '0'
    lea rax, [num_buf]
    mov [rax + r8], al
    inc r8d
.hco_fg_1dig:
    add dl, '0'
    lea rax, [num_buf]
    mov [rax + r8], dl
    inc r8d
.hco_fg_written:

    ; Semicolon
    lea rax, [num_buf]
    mov byte [rax + r8], ';'
    inc r8d

    ; Write bg number (2-3 digits)
    mov eax, r12d
    xor edx, edx
    mov ecx, 100
    div ecx
    test eax, eax
    jz .hco_bg_no100
    add al, '0'
    lea rax, [num_buf]
    mov [rax + r8], al
    inc r8d
    mov eax, edx
    xor edx, edx
    mov ecx, 10
    div ecx
    add al, '0'
    lea rax, [num_buf]
    mov [rax + r8], al
    inc r8d
    add dl, '0'
    mov [rax + r8], dl
    inc r8d
    jmp .hco_bg_written
.hco_bg_no100:
    mov eax, edx
    xor edx, edx
    mov ecx, 10
    div ecx
    test al, al
    jz .hco_bg_1dig
    add al, '0'
    lea rax, [num_buf]
    mov [rax + r8], al
    inc r8d
.hco_bg_1dig:
    add dl, '0'
    lea rax, [num_buf]
    mov [rax + r8], dl
    inc r8d
.hco_bg_written:

    ; Terminating 'm'
    lea rax, [num_buf]
    mov byte [rax + r8], 'm'
    inc r8d

    ; Print the ANSI sequence
    lea rdi, [num_buf]
    mov esi, r8d
    call print_string_len

.hco_done:
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ---------- handler_cd ----------
; Change directory. Supports "cd -" to go to previous directory.
handler_cd:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 16

    mov rbx, rdi                    ; rbx = args

    test rbx, rbx
    jz .hcd_show
    cmp byte [rbx], 0
    je .hcd_show

    ; Check for "cd -"
    cmp byte [rbx], '-'
    jne .hcd_change
    cmp byte [rbx + 1], 0
    jne .hcd_change

    ; cd - : go to previous directory
    cmp byte [has_prev_dir], 0
    je .hcd_no_prev

    ; Save current dir to temp
    lea rdi, [file_path_buf]
    mov esi, MAX_PATH_BUF
    mov eax, SYS_GETCWD
    syscall

    ; chdir to prev_dir_buf
    lea rdi, [prev_dir_buf]
    mov eax, SYS_CHDIR
    syscall
    test rax, rax
    js .hcd_err

    ; Copy old cwd (file_path_buf) to prev_dir_buf
    lea rdi, [prev_dir_buf]
    lea rsi, [file_path_buf]
    call str_copy

    ; Print new directory
    lea rdi, [path_buf]
    mov esi, MAX_PATH_BUF
    mov eax, SYS_GETCWD
    syscall
    lea rdi, [path_buf]
    call print_cstring
    call print_newline
    jmp .hcd_done

.hcd_no_prev:
    lea rdi, [err_no_prev_dir]
    mov esi, err_no_prev_len
    call print_string_len
    jmp .hcd_done

.hcd_change:
    ; Save current directory to prev_dir_buf
    lea rdi, [prev_dir_buf]
    mov esi, MAX_PATH_BUF
    mov eax, SYS_GETCWD
    syscall
    mov byte [has_prev_dir], 1

    ; chdir to argument
    mov rdi, rbx
    mov eax, SYS_CHDIR
    syscall
    test rax, rax
    jns .hcd_done

.hcd_err:
    lea rdi, [err_cd_msg]
    mov esi, err_cd_len
    call print_string_len
    jmp .hcd_done

.hcd_show:
    ; No args: go to $HOME (POSIX behaviour). Fall back to printing cwd if HOME unset.
    lea rdi, [str_home]
    call getenv_internal
    test rax, rax
    jz .hcd_print_cwd

    ; Save current dir to prev_dir_buf before changing
    lea rdi, [prev_dir_buf]
    mov esi, MAX_PATH_BUF
    mov eax, SYS_GETCWD
    syscall
    mov byte [has_prev_dir], 1

    mov rdi, rax
    ; rax already holds HOME value ptr; move into rdi for chdir
    lea rdi, [str_home]
    call getenv_internal
    mov rdi, rax
    mov eax, SYS_CHDIR
    syscall
    test rax, rax
    js .hcd_err
    jmp .hcd_done

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

    lea rdi, [path_buf]
    call print_cstring
    call print_newline

    leave
    ret

; ---------- handler_whoami ----------
handler_whoami:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    lea rdi, [str_user]
    call getenv_internal
    test rax, rax
    jz .hw_done

    mov rdi, rax
    call print_cstring
    call print_newline

.hw_done:
    leave
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

    ; Print header
    call print_newline
    lea rdi, [dir_header]
    call print_cstring

    ; Determine which directory to list
    test rbx, rbx
    jz .hd_use_cwd
    cmp byte [rbx], 0
    je .hd_use_cwd

    ; Use the provided path
    mov rdi, rbx
    call print_cstring
    call print_newline
    call print_newline

    ; Open the specified directory
    mov rdi, rbx
    jmp .hd_open_dir

.hd_use_cwd:
    ; Print current working directory in header
    lea rdi, [path_buf]
    mov esi, MAX_PATH_BUF
    mov eax, SYS_GETCWD
    syscall
    lea rdi, [path_buf]
    call print_cstring
    call print_newline
    call print_newline

    lea rdi, [str_dot]

.hd_open_dir:
    mov r15, rdi                    ; save dir path for fstatat
    ; open(path, O_RDONLY | O_DIRECTORY, 0)
    mov esi, O_RDONLY | O_DIRECTORY
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .hd_done
    mov r12d, eax                   ; r12d = directory fd

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
    mov eax, [stat_buf + STAT_ST_SIZE]  ; low 32 bits of size
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

    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ---------- handler_type ----------
; Display file contents
handler_type:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 24

    test rdi, rdi
    jz .hty_noargs
    cmp byte [rdi], 0
    je .hty_noargs

    ; open(filename, O_RDONLY, 0)
    mov esi, O_RDONLY
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .hty_err
    mov ebx, eax                    ; ebx = file descriptor

.hty_read:
    ; read(fd, read_buffer, READ_BUF_SIZE)
    mov edi, ebx
    lea rsi, [read_buffer]
    mov edx, READ_BUF_SIZE
    mov eax, SYS_READ
    syscall
    test rax, rax
    jle .hty_close                  ; EOF or error

    ; Print what was read
    lea rdi, [read_buffer]
    mov esi, eax
    call print_string_len
    jmp .hty_read

.hty_close:
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall
    jmp .hty_done

.hty_noargs:
    lea rdi, [err_args_msg]
    mov esi, err_args_len
    call print_string_len
    jmp .hty_done

.hty_err:
    lea rdi, [err_file_msg]
    mov esi, err_file_len
    call print_string_len

.hty_done:
    add rsp, 24
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
    jne .hmk_go
    mov r12d, 1
    add rbx, 3
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
    je .hmk_done
.hmk_rec_err:
    neg eax
    mov edi, eax
    call print_last_error
    jmp .hmk_done

.hmk_err:
    lea rdi, [err_args_msg]
    mov esi, err_args_len
    call print_string_len

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
    call print_string_len

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
    jmp .hdl_done

.hdl_err:
    lea rdi, [err_args_msg]
    mov esi, err_args_len
    call print_string_len

.hdl_done:
    leave
    ret

; ---------- handler_copy ----------
; Copy file: parse_two_args, open src, open dst, read/write loop, close both
handler_copy:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24

    test rdi, rdi
    jz .hcp_err

    call parse_two_args             ; rax=arg1(src), rdx=arg2(dst)
    test rax, rax
    jz .hcp_err
    test rdx, rdx
    jz .hcp_err

    mov r12, rax                    ; r12 = source path
    mov r13, rdx                    ; r13 = dest path

    ; Open source: open(src, O_RDONLY, 0)
    mov rdi, r12
    mov esi, O_RDONLY
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .hcp_src_err
    mov ebx, eax                    ; ebx = src fd

    ; Open dest: open(dst, O_WRONLY|O_CREAT|O_TRUNC, 0644)
    mov rdi, r13
    mov esi, O_WRONLY | O_CREAT | O_TRUNC
    mov edx, PERM_0644
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .hcp_dst_err
    mov r12d, eax                   ; r12d = dst fd

.hcp_loop:
    ; read(src_fd, read_buffer, READ_BUF_SIZE)
    mov edi, ebx
    lea rsi, [read_buffer]
    mov edx, READ_BUF_SIZE
    mov eax, SYS_READ
    syscall
    test rax, rax
    jz .hcp_close_both              ; EOF
    js .hcp_read_err                ; read error

    ; write(dst_fd, read_buffer, bytes_read) — handle partial writes
    mov r14, rax                    ; r14 = total bytes remaining
    lea r15, [read_buffer]          ; r15 = current write pointer
.hcp_write_loop:
    mov edi, r12d
    mov rsi, r15
    mov rdx, r14
    mov eax, SYS_WRITE
    syscall
    test rax, rax
    js .hcp_write_err               ; EIO, ENOSPC, EPIPE etc.
    add r15, rax                    ; advance pointer by bytes written
    sub r14, rax                    ; decrement remaining
    jnz .hcp_write_loop             ; loop until all bytes written
    jmp .hcp_loop

.hcp_read_err:
    lea rdi, [err_copy_read_msg]
    mov esi, err_copy_read_len
    call print_string_len
    jmp .hcp_close_both

.hcp_write_err:
    lea rdi, [err_copy_write_msg]
    mov esi, err_copy_write_len
    call print_string_len
    jmp .hcp_close_both

.hcp_close_both:
    ; Close dst
    mov edi, r12d
    mov eax, SYS_CLOSE
    syscall
.hcp_dst_err:
    ; Close src
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall
    jmp .hcp_done

.hcp_src_err:
    lea rdi, [err_file_msg]
    mov esi, err_file_len
    call print_string_len
    jmp .hcp_done

.hcp_err:
    lea rdi, [err_args_msg]
    mov esi, err_args_len
    call print_string_len

.hcp_done:
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
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
    jmp .hmv_done

.hmv_err:
    lea rdi, [err_args_msg]
    mov esi, err_args_len
    call print_string_len

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
    ; Variable not found -- print error
    lea rdi, [err_file_msg]
    mov esi, err_file_len
    call print_string_len
    jmp .hs_done

.hs_list:
    ; List all environment variables from saved_envp
    mov rax, [saved_envp]
    test rax, rax
    jz .hs_done
    mov r12, rax                    ; r12 = char** envp

.hs_list_loop:
    mov rdi, [r12]                  ; load envp[i]
    test rdi, rdi
    jz .hs_list_overlay             ; end of envp array

    call print_cstring
    call print_newline
    add r12, 8                      ; next pointer
    jmp .hs_list_loop

.hs_list_overlay:
    ; Also print env_overlay entries
    mov eax, [env_overlay_count]
    test eax, eax
    jz .hs_done
    lea r12, [env_overlay]
    xor r13d, r13d
.hs_overlay_loop:
    cmp r13d, [env_overlay_count]
    jge .hs_done
    mov rdi, r12
    cmp byte [rdi], 0
    je .hs_overlay_next
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

    inc dword [dir_stack_top]

    ; chdir to argument
    mov rdi, rbx
    mov eax, SYS_CHDIR
    syscall
    test rax, rax
    jns .hpd_done

    ; chdir failed -- undo stack push
    dec dword [dir_stack_top]
    lea rdi, [err_cd_msg]
    mov esi, err_cd_len
    call print_string_len
    jmp .hpd_done

.hpd_full:
    lea rdi, [err_stack_full]
    mov esi, err_stack_f_len
    call print_string_len
    jmp .hpd_done

.hpd_err:
    lea rdi, [err_args_msg]
    mov esi, err_args_len
    call print_string_len

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
    mov eax, SYS_CHDIR
    syscall
    test rax, rax
    jns .hpo_done

    ; chdir failed -- restore stack
    inc dword [dir_stack_top]
    lea rdi, [err_cd_msg]
    mov esi, err_cd_len
    call print_string_len
    jmp .hpo_done

.hpo_empty:
    lea rdi, [err_stack_empty]
    mov esi, err_stack_e_len
    call print_string_len

.hpo_done:
    leave
    ret

; ---------- handler_alias ----------
; Create/list aliases. Format: alias name=command
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
    jz .hal_list                    ; no '=' means just list
    cmp al, '='
    je .hal_set
    inc r12
    jmp .hal_find_eq

.hal_set:
    mov byte [r12], 0              ; null-terminate alias name
    lea r13, [r12 + 1]            ; r13 = alias command

    cmp dword [alias_count], ALIAS_COUNT
    jge .hal_full

    ; Check if alias already exists -- update it
    lea r8, [alias_table]
    xor ecx, ecx
.hal_find:
    cmp ecx, [alias_count]
    jge .hal_add_new

    push rcx
    push r8
    mov rdi, rbx                   ; alias name we're looking for
    mov rsi, r8                    ; existing alias name
    call str_icompare
    pop r8
    pop rcx
    test eax, eax
    jz .hal_update

    add r8, ALIAS_ENTRY_SIZE
    inc ecx
    jmp .hal_find

.hal_update:
    ; Update the command part
    lea rdi, [r8 + ALIAS_NAME_SIZE]
    mov rsi, r13
    call str_copy
    jmp .hal_done

.hal_add_new:
    ; Add new alias entry
    mov eax, [alias_count]
    imul eax, ALIAS_ENTRY_SIZE
    lea rdi, [alias_table]
    add rdi, rax
    mov rsi, rbx                   ; alias name
    call str_copy

    mov eax, [alias_count]
    imul eax, ALIAS_ENTRY_SIZE
    lea rdi, [alias_table]
    add rdi, rax
    add rdi, ALIAS_NAME_SIZE
    mov rsi, r13                   ; alias command
    call str_copy

    inc dword [alias_count]
    jmp .hal_done

.hal_list:
    mov ecx, [alias_count]
    test ecx, ecx
    jz .hal_done

    lea r12, [alias_table]
    xor ebx, ebx

.hal_list_loop:
    cmp ebx, [alias_count]
    jge .hal_done

    mov rdi, r12                   ; alias name
    call print_cstring
    lea rdi, [str_equals]
    call print_cstring
    lea rdi, [r12 + ALIAS_NAME_SIZE] ; alias command
    call print_cstring
    call print_newline

    add r12, ALIAS_ENTRY_SIZE
    inc ebx
    jmp .hal_list_loop

.hal_full:
    lea rdi, [err_alias_full]
    mov esi, err_alias_f_len
    call print_string_len

.hal_done:
    add rsp, 24
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; handler_unalias - Remove an alias by name (soft-delete: clear first byte)
; ============================================================================
handler_unalias:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 8

    test rdi, rdi
    jz .hua_usage
    cmp byte [rdi], 0
    je .hua_usage

    mov r12, rdi
    lea rbx, [alias_table]
    xor r13d, r13d                   ; r13 = index (str_icompare clobbers rcx)
.hua_scan:
    cmp r13d, [alias_count]
    jge .hua_notfound
    cmp byte [rbx], 0
    je .hua_next
    mov rdi, r12
    mov rsi, rbx
    call str_icompare
    test eax, eax
    jnz .hua_next
    mov byte [rbx], 0
    jmp .hua_done
.hua_next:
    add rbx, ALIAS_ENTRY_SIZE
    inc r13d
    jmp .hua_scan

.hua_usage:
    lea rdi, [err_unalias_usage]
    mov esi, err_unalias_usage_len
    call print_string_len
    jmp .hua_done

.hua_notfound:
    lea rdi, [err_unalias_notfound]
    mov esi, err_unalias_notfound_len
    call print_string_len

.hua_done:
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; execute_external - Run command via fork + execve("/bin/sh", "-c", cmd)
; Supports background execution with trailing '&'.
; Captures exit status in last_exit_status.
; ============================================================================
%define WNOHANG  1

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

    ; Find end of input_buf
    lea rdi, [input_buf]
    call str_len
    mov r13d, eax                   ; r13d = length

    test r13d, r13d
    jz .ee_error                    ; empty command

    ; Walk backwards from end, skip trailing spaces
    lea rbx, [input_buf]
    mov ecx, r13d

.ee_trim_end:
    dec ecx
    js .ee_no_bg                    ; reached start without finding non-space
    cmp byte [rbx + rcx], ' '
    je .ee_trim_end

    ; Check if this last non-space char is '&'
    cmp byte [rbx + rcx], '&'
    jne .ee_no_bg

    ; Found '&' - enable background mode
    mov r14d, 1

    ; Remove the '&' and any trailing spaces before it
    mov byte [rbx + rcx], 0        ; null-terminate at '&'

    ; Trim more trailing spaces before the & was
    dec ecx
.ee_trim_before_amp:
    js .ee_bg_trimmed
    cmp byte [rbx + rcx], ' '
    jne .ee_bg_trimmed
    mov byte [rbx + rcx], 0
    dec ecx
    jmp .ee_trim_before_amp

.ee_bg_trimmed:
.ee_no_bg:
    ; Restore terminal to cooked mode so child process gets sane terminal
    call restore_terminal

    ; fork()
    mov eax, SYS_FORK
    syscall
    test rax, rax
    js .ee_fork_error               ; fork failed
    jnz .ee_parent                  ; parent: rax = child PID

    ; ====== CHILD PROCESS ======

    ; Handle redirection with dup2
    cmp byte [redir_stdout_active], 0
    je .ee_child_check_in
    ; dup2(redir_stdout_fd, 1) -- redirect stdout
    mov edi, [redir_stdout_fd]
    mov esi, 1                      ; stdout
    mov eax, SYS_DUP2
    syscall

.ee_child_check_in:
    cmp byte [redir_stdin_active], 0
    je .ee_child_exec
    ; dup2(redir_stdin_fd, 0) -- redirect stdin
    mov edi, [redir_stdin_fd]
    xor esi, esi                    ; stdin
    mov eax, SYS_DUP2
    syscall

.ee_child_exec:
    ; Build argv: ["/bin/sh", "-c", input_buf, NULL]
    lea rax, [exec_argv]
    lea rcx, [sh_path]
    mov [rax], rcx                  ; argv[0] = "/bin/sh"
    lea rcx, [sh_dash_c]
    mov [rax + 8], rcx              ; argv[1] = "-c"
    lea rcx, [input_buf]
    mov [rax + 16], rcx             ; argv[2] = command string
    mov qword [rax + 24], 0         ; argv[3] = NULL

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

    ; Check if background mode
    test r14d, r14d
    jnz .ee_background

    ; --- Foreground: wait for child ---
    mov edi, ebx
    lea rsi, [pid_buf]              ; reuse as status location
    xor edx, edx                    ; options = 0
    xor r10d, r10d                  ; rusage = NULL
    mov eax, SYS_WAIT4
    syscall

    ; Extract exit status
    mov eax, [pid_buf]
    ; Check WIFEXITED: (status & 0x7F) == 0
    test al, 0x7F
    jnz .ee_signaled
    ; WEXITSTATUS: (status >> 8) & 0xFF
    shr eax, 8
    and eax, 0xFF
    mov [last_exit_status], eax
    jmp .ee_restore

.ee_signaled:
    ; Child was killed by a signal -- treat as failure
    mov dword [last_exit_status], 1

.ee_restore:
    ; Re-enable raw mode for our terminal
    call setup_raw_mode
    jmp .ee_done

.ee_background:
    ; --- Background: store PID in job table, don't wait ---

    ; Re-enable raw mode first
    call setup_raw_mode

    ; Find an empty slot in job table
    xor ecx, ecx                    ; slot index

.ee_find_slot:
    cmp ecx, JOB_MAX
    jge .ee_table_full

    lea rdi, [job_pids]
    cmp qword [rdi + rcx*8], 0
    je .ee_store_job

    inc ecx
    jmp .ee_find_slot

.ee_store_job:
    ; Store the PID
    lea rdi, [job_pids]
    mov rax, rbx                    ; child PID (zero-extended from ebx)
    mov [rdi + rcx*8], rax

    ; Copy the command string into job_cmds[slot]
    mov eax, ecx
    imul eax, JOB_CMD_SIZE
    lea rdi, [job_cmds + rax]
    lea rsi, [input_buf]

    ; Copy up to JOB_CMD_SIZE-1 chars
    push rcx                        ; save slot index
    xor edx, edx

.ee_copy_cmd:
    cmp edx, JOB_CMD_SIZE - 1
    jge .ee_copy_cmd_done
    movzx eax, byte [rsi + rdx]
    test al, al
    jz .ee_copy_cmd_done
    mov [rdi + rdx], al
    inc edx
    jmp .ee_copy_cmd

.ee_copy_cmd_done:
    mov byte [rdi + rdx], 0         ; null-terminate
    pop rcx

    inc dword [job_count]

    ; Print "[bg] PID XXXX\n"
    lea rdi, [jobs_bg_started_msg]
    call print_cstring
    mov eax, ebx
    call print_number
    call print_newline

    jmp .ee_done

.ee_table_full:
    ; Job table full - print warning and wait foreground instead
    lea rdi, [jobs_full_msg]
    call print_cstring

    ; Fall back to foreground wait
    mov edi, ebx
    lea rsi, [pid_buf]
    xor edx, edx
    xor r10d, r10d
    mov eax, SYS_WAIT4
    syscall

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
; Split string at first space (modifies string in-place).
; rdi = input. Returns: rax = arg1, rdx = arg2 (or both 0 on failure).
parse_two_args:
    mov rax, rdi
    test rax, rax
    jz .pta_fail
.pta_find:
    cmp byte [rdi], 0
    je .pta_fail
    cmp byte [rdi], ' '
    je .pta_split
    inc rdi
    jmp .pta_find
.pta_split:
    mov byte [rdi], 0              ; null-terminate first arg
    inc rdi
.pta_skip:
    cmp byte [rdi], ' '
    jne .pta_check
    inc rdi
    jmp .pta_skip
.pta_check:
    cmp byte [rdi], 0
    je .pta_fail
    mov rdx, rdi                   ; second arg
    ret
.pta_fail:
    xor eax, eax
    xor edx, edx
    ret

; ---------- hex_to_int ----------
; Convert hex char in al to integer 0-15. Returns: eax = value.
hex_to_int:
    cmp al, '0'
    jb .hti_zero
    cmp al, '9'
    jbe .hti_digit
    cmp al, 'a'
    jb .hti_upper
    cmp al, 'f'
    jbe .hti_lower
    cmp al, 'A'
    jb .hti_zero
    cmp al, 'F'
    jbe .hti_upper
.hti_zero:
    xor eax, eax
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
    push r14
    sub rsp, 16

    mov r12, rdi                    ; r12 = variable name to find

    ; Get length of variable name
    call str_len
    mov r13d, eax                   ; r13d = name length

    ; ---- Search env_overlay first ----
    mov eax, [env_overlay_count]
    test eax, eax
    jz .ge_search_envp

    lea rbx, [env_overlay]
    xor r14d, r14d                  ; index

.ge_overlay_loop:
    cmp r14d, [env_overlay_count]
    jge .ge_search_envp

    ; Compare first r13d chars of overlay entry with our name
    mov rdi, r12
    mov rsi, rbx
    mov edx, r13d
    call str_icompare_n
    test eax, eax
    jnz .ge_overlay_next

    ; Check that the char at position r13d is '='
    cmp byte [rbx + r13], '='
    jne .ge_overlay_next

    ; Found! Return pointer to value (after '=')
    lea rax, [rbx + r13 + 1]
    jmp .ge_done

.ge_overlay_next:
    add rbx, ENV_OVERLAY_SIZE
    inc r14d
    jmp .ge_overlay_loop

    ; ---- Search saved_envp ----
.ge_search_envp:
    mov rax, [saved_envp]
    test rax, rax
    jz .ge_not_found
    mov rbx, rax                    ; rbx = char** envp

.ge_envp_loop:
    mov rdi, [rbx]                  ; envp[i]
    test rdi, rdi
    jz .ge_not_found                ; end of envp

    ; Compare first r13d chars with our name
    mov rsi, rdi                    ; envp entry
    mov rdi, r12                    ; our name
    mov edx, r13d
    call str_icompare_n
    test eax, eax
    jnz .ge_envp_next

    ; Check for '=' at position r13d in the envp entry
    mov rax, [rbx]
    cmp byte [rax + r13], '='
    jne .ge_envp_next

    ; Found! Return pointer to value
    lea rax, [rax + r13 + 1]
    jmp .ge_done

.ge_envp_next:
    add rbx, 8
    jmp .ge_envp_loop

.ge_not_found:
    xor eax, eax

.ge_done:
    add rsp, 16
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; setenv_internal - Set environment variable in overlay
; rdi = name, rsi = value
; Finds existing entry or creates new one. Format: "KEY=VALUE\0"
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

    ; Get name length
    mov rdi, r12
    call str_len
    mov r14d, eax                   ; r14d = name length

    ; Search for existing entry in overlay
    lea rbx, [env_overlay]
    xor ecx, ecx

.se_find:
    cmp ecx, [env_overlay_count]
    jge .se_add_new

    push rcx
    mov rdi, r12
    mov rsi, rbx
    mov edx, r14d
    call str_icompare_n
    pop rcx
    test eax, eax
    jnz .se_find_next

    ; Check for '=' at correct position
    cmp byte [rbx + r14], '='
    jne .se_find_next

    ; Found existing -- overwrite it
    jmp .se_write_entry

.se_find_next:
    add rbx, ENV_OVERLAY_SIZE
    inc ecx
    jmp .se_find

.se_add_new:
    ; Check if there's room
    cmp dword [env_overlay_count], ENV_OVERLAY_COUNT
    jge .se_done                    ; table full

    ; rbx already points to the next free slot
    mov eax, [env_overlay_count]
    imul eax, ENV_OVERLAY_SIZE
    lea rbx, [env_overlay]
    add rbx, rax

    inc dword [env_overlay_count]

.se_write_entry:
    ; Write "NAME=VALUE\0" into the overlay slot at rbx (bounded)
    mov rdi, rbx
    mov r14, rbx
    add r14, ENV_OVERLAY_SIZE - 1   ; r14 = last writable byte (reserve NUL slot)
    mov rsi, r12
    ; Copy name
.se_cp_name:
    movzx eax, byte [rsi]
    test al, al
    jz .se_eq
    cmp rdi, r14
    jae .se_terminate
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .se_cp_name

.se_eq:
    cmp rdi, r14
    jae .se_terminate
    mov byte [rdi], '='
    inc rdi

    ; Copy value
    mov rsi, r13
.se_cp_value:
    movzx eax, byte [rsi]
    test al, al
    jz .se_terminate
    cmp rdi, r14
    jae .se_terminate
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .se_cp_value

.se_terminate:
    mov byte [rdi], 0               ; ensure NUL termination within slot

.se_done:
    add rsp, 16
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; build_merged_envp - Fill merged_envp[] with overlay entries + inherited envp
; Cap at 256 slots including terminating NULL. Overlay entries appear first
; so getenv() in children returns overridden values.
; ============================================================================
build_merged_envp:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 8

    lea r12, [merged_envp]
    xor r13d, r13d                  ; slot index

    ; --- Copy overlay entries ---
    mov ecx, [env_overlay_count]
    test ecx, ecx
    jz .bme_inherited
    lea rbx, [env_overlay]
.bme_overlay_loop:
    cmp r13d, 255
    jge .bme_terminate
    ; Skip empty slots (first byte NUL)
    cmp byte [rbx], 0
    je .bme_next_overlay
    mov [r12 + r13*8], rbx
    inc r13d
.bme_next_overlay:
    add rbx, ENV_OVERLAY_SIZE
    dec ecx
    jnz .bme_overlay_loop

.bme_inherited:
    ; --- Copy inherited envp pointers ---
    mov rbx, [saved_envp]
    test rbx, rbx
    jz .bme_terminate
.bme_env_loop:
    mov rax, [rbx]
    test rax, rax
    jz .bme_terminate
    cmp r13d, 255
    jge .bme_terminate
    mov [r12 + r13*8], rax
    inc r13d
    add rbx, 8
    jmp .bme_env_loop

.bme_terminate:
    mov qword [r12 + r13*8], 0
    mov [merged_envp_count], r13d

    add rsp, 8
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; handler_unset - Remove a name from env_overlay (env vars set via 'set')
; ============================================================================
handler_unset:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 8

    test rdi, rdi
    jz .hun_usage
    cmp byte [rdi], 0
    je .hun_usage

    ; Use caller's arg as the name; length via str_len
    mov r12, rdi
    call str_len
    mov r13d, eax

    lea rbx, [env_overlay]
    xor r14d, r14d
.hun_scan:
    cmp r14d, [env_overlay_count]
    jge .hun_done
    cmp byte [rbx], 0
    je .hun_next
    mov rdi, r12
    mov rsi, rbx
    mov edx, r13d
    call str_icompare_n
    test eax, eax
    jnz .hun_next
    cmp byte [rbx + r13], '='
    jne .hun_next
    ; Found -- clear slot
    mov byte [rbx], 0
    jmp .hun_done
.hun_next:
    add rbx, ENV_OVERLAY_SIZE
    inc r14d
    jmp .hun_scan

.hun_usage:
    lea rdi, [err_unset_usage]
    mov esi, err_unset_usage_len
    call print_string_len
.hun_done:
    add rsp, 8
    pop r14
    pop r13
    pop r12
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
    mov edx, MAX_PATH_BUF - 1
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
    ; Try to open the file
    lea rdi, [module_path]
    mov esi, O_RDONLY
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .ra_done                     ; file doesn't exist

    mov ebx, eax                    ; ebx = fd

    ; Read entire file
    mov edi, ebx
    lea rsi, [read_buffer]
    mov edx, READ_BUF_SIZE - 1
    mov eax, SYS_READ
    syscall
    mov r12d, eax                   ; r12d = bytes read

    ; Close file
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall

    ; Null-terminate
    test r12d, r12d
    jle .ra_done
    lea rcx, [read_buffer]
    mov byte [rcx + r12], 0

    ; Process line by line
    lea r13, [read_buffer]

.ra_line:
    cmp byte [r13], 0
    je .ra_done

    ; Copy one line to input_buf
    lea rdi, [input_buf]
    xor ecx, ecx
.ra_cpy:
    movzx eax, byte [r13]
    cmp al, 0
    je .ra_exec
    cmp al, 13                      ; skip CR
    je .ra_skip_cr
    cmp al, 10                      ; LF = end of line
    je .ra_exec
    cmp ecx, MAX_INPUT - 1          ; bounds check
    jge .ra_truncate
    mov [rdi + rcx], al
    inc ecx
    inc r13
    jmp .ra_cpy

.ra_truncate:
    inc r13
    movzx eax, byte [r13]
    cmp al, 0
    je .ra_exec
    cmp al, 10
    je .ra_exec
    jmp .ra_truncate

.ra_skip_cr:
    inc r13
    jmp .ra_cpy

.ra_exec:
    ; Skip past LF if present
    cmp byte [r13], 10
    jne .ra_no_lf
    inc r13
.ra_no_lf:
    mov byte [rdi + rcx], 0
    test ecx, ecx
    jz .ra_line                     ; empty line, skip

    ; Dispatch the command
    call dispatch_command
    jmp .ra_line

.ra_done:
    add rsp, 24
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; load_history - Load command history from ~/.asm_history at startup
; ============================================================================
load_history:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 8

    ; Build path: $HOME/.asm_history
    lea rdi, [str_home]
    call getenv_internal
    test rax, rax
    jz .lh_done

    ; Copy HOME to history_file_path
    lea rdi, [history_file_path]
    mov rsi, rax
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

    ; Read file in a loop into a 256KB buffer (handles multi-chunk files).
    lea r13, [history_read_buf]     ; current write position
    xor r12d, r12d                  ; total bytes
.lh_read_chunk:
    mov eax, 262144
    sub eax, r12d
    cmp eax, 1
    jle .lh_read_done               ; buffer full
    mov edi, ebx
    mov rsi, r13
    mov edx, eax
    mov eax, SYS_READ
    syscall
    test rax, rax
    jle .lh_read_done               ; EOF or error
    add r12d, eax
    add r13, rax
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
.lh_line:
    cmp byte [r13], 0
    je .lh_done
    ; Copy one line to cmd_line_buf
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
    mov [rdi + rcx], al
    inc ecx
    inc r13
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

.lh_done:
    add rsp, 8
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; history_save_entry - Append a command to ~/.asm_history
; rdi = pointer to null-terminated command string
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

    ; Open file for append (create if needed)
    mov esi, O_WRONLY | O_CREAT | O_APPEND
    mov edx, FILE_MODE_DEFAULT
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

    ; Copy HOME to asmrc_path
    lea rdi, [asmrc_path]
    mov rsi, rax
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
    mov esi, O_RDONLY
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .rc_done                     ; file doesn't exist, silent fail

    mov ebx, eax                    ; fd

    ; Read file
    mov edi, ebx
    lea rsi, [read_buffer]
    mov edx, READ_BUF_SIZE - 1
    mov eax, SYS_READ
    syscall
    mov r12d, eax

    ; Close
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall

    ; Null-terminate
    test r12d, r12d
    jle .rc_done
    lea rcx, [read_buffer]
    mov byte [rcx + r12], 0

    ; Process line by line
    lea r13, [read_buffer]
.rc_line:
    cmp byte [r13], 0
    je .rc_done
    lea rdi, [input_buf]
    xor ecx, ecx
.rc_cpy:
    movzx eax, byte [r13]
    cmp al, 0
    je .rc_exec
    cmp al, 13
    je .rc_skip_cr
    cmp al, 10
    je .rc_exec
    mov [rdi + rcx], al
    inc ecx
    inc r13
    jmp .rc_cpy
.rc_skip_cr:
    inc r13
    jmp .rc_cpy
.rc_exec:
    cmp byte [r13], 10
    jne .rc_no_lf
    inc r13
.rc_no_lf:
    mov byte [rdi + rcx], 0
    test ecx, ecx
    jz .rc_line
    call dispatch_command
    jmp .rc_line

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
; check_wildcard_in_args - Scan input_buf for '*' or '?' characters
; We skip the first word (the command name) and only check arguments.
; Returns: eax = 1 if wildcards found in args, 0 if not.
; ============================================================================
check_wildcard_in_args:
    lea rdi, [input_buf]

    ; Skip first word (the command itself)
.cwa_skip_cmd:
    movzx eax, byte [rdi]
    test al, al
    jz .cwa_not_found               ; no args at all
    cmp al, ' '
    je .cwa_in_args
    inc rdi
    jmp .cwa_skip_cmd

.cwa_in_args:
    ; Now scan the argument portion
    movzx eax, byte [rdi]
    test al, al
    jz .cwa_not_found
    cmp al, '*'
    je .cwa_found
    cmp al, '?'
    je .cwa_found
    inc rdi
    jmp .cwa_in_args

.cwa_found:
    mov eax, 1
    ret

.cwa_not_found:
    xor eax, eax
    ret


; ============================================================================
; execute_compound - Split input_buf on ';' and '&&', execute each segment
; ============================================================================
execute_compound:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24

    ; Initialize exit status
    mov dword [last_exit_status], 0

    ; Copy input_buf -> compound_buf (we will scan compound_buf)
    lea rdi, [compound_buf]
    lea rsi, [input_buf]
    call str_copy

    ; r12 = current scan position in compound_buf
    lea r12, [compound_buf]

.ec_next_segment:
    ; Skip leading spaces
    cmp byte [r12], ' '
    jne .ec_find_sep
    inc r12
    jmp .ec_next_segment

    ; Check if we're at end of string (no more segments)
.ec_find_sep:
    cmp byte [r12], 0
    je .ec_done                     ; nothing left

    ; r13 = start of this segment (after skipping spaces)
    mov r13, r12

    ; Scan forward for ';' or '&&'
    ; r14 will store: 0 = end of string, 1 = found ';', 2 = found '&&'
    xor r14d, r14d                  ; separator type
    ; r15 = pointer to the separator character
.ec_scan:
    movzx eax, byte [r12]
    test al, al
    jz .ec_segment_end              ; end of string, last segment

    cmp al, ';'
    je .ec_found_semi

    cmp al, '&'
    jne .ec_scan_next
    ; Check for '&&'
    cmp byte [r12 + 1], '&'
    je .ec_found_and

.ec_scan_next:
    inc r12
    jmp .ec_scan

.ec_found_semi:
    mov r14d, 1                     ; type = semicolon
    mov r15, r12                    ; save separator position
    mov byte [r12], 0              ; null-terminate this segment
    inc r12                         ; advance past ';'
    jmp .ec_execute_segment

.ec_found_and:
    mov r14d, 2                     ; type = '&&'
    mov r15, r12                    ; save separator position
    mov byte [r12], 0              ; null-terminate this segment
    add r12, 2                      ; advance past '&&'
    jmp .ec_execute_segment

.ec_segment_end:
    ; No separator found -- this is the last (or only) segment
    xor r14d, r14d                  ; type = none (last segment)

.ec_execute_segment:
    ; r13 = start of segment, null-terminated
    ; Trim trailing spaces from the segment
    mov rdi, r13
    call str_len
    test eax, eax
    jz .ec_check_continue           ; empty segment, skip

    ; Trim trailing spaces
    lea rbx, [r13 + rax]           ; rbx = points to the null terminator
.ec_trim_trail:
    cmp rbx, r13
    je .ec_trim_done
    cmp byte [rbx - 1], ' '
    jne .ec_trim_done
    dec rbx
    jmp .ec_trim_trail
.ec_trim_done:
    mov byte [rbx], 0

    ; Check if segment is empty after trimming
    cmp byte [r13], 0
    je .ec_check_continue

    ; Copy segment to input_buf for dispatch
    lea rdi, [input_buf]
    mov rsi, r13
    call str_copy

    ; Dispatch this segment
    call dispatch_command

.ec_check_continue:
    ; If separator type == 0, we are done (was last segment)
    test r14d, r14d
    jz .ec_done

    ; If separator was '&&' (type 2), check last_exit_status
    cmp r14d, 2
    jne .ec_next_segment            ; ';' -> continue unconditionally

    ; '&&': only continue if last command succeeded
    cmp dword [last_exit_status], 0
    jne .ec_done                    ; command failed, abort chain

    jmp .ec_next_segment

.ec_done:
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret


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

    ; rdi already points to the filename -- open it
    mov esi, O_RDONLY
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .hsrc_open_err
    mov ebx, eax                    ; ebx = file descriptor

    ; Read entire file into source_read_buf
    mov edi, ebx
    lea rsi, [source_read_buf]
    mov edx, READ_BUF_SIZE - 1
    mov eax, SYS_READ
    syscall
    mov r12d, eax                   ; r12d = bytes read

    ; Close file
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall

    ; Check for empty or failed read
    test r12d, r12d
    jle .hsrc_done

    ; Null-terminate the buffer
    lea rcx, [source_read_buf]
    mov byte [rcx + r12], 0

    ; Process line by line
    lea r13, [source_read_buf]

.hsrc_line:
    cmp byte [r13], 0
    je .hsrc_done

    ; Copy one line to input_buf
    lea rdi, [input_buf]
    xor ecx, ecx

.hsrc_cpy:
    movzx eax, byte [r13]
    cmp al, 0
    je .hsrc_exec
    cmp al, 13                      ; skip CR
    je .hsrc_skip_cr
    cmp al, 10                      ; LF = end of line
    je .hsrc_exec
    cmp ecx, MAX_INPUT - 1          ; bounds check
    jge .hsrc_truncate
    mov [rdi + rcx], al
    inc ecx
    inc r13
    jmp .hsrc_cpy

.hsrc_truncate:
    ; Skip remaining bytes on this oversized line (discard to LF/NUL)
    inc r13
    movzx eax, byte [r13]
    cmp al, 0
    je .hsrc_exec
    cmp al, 10
    je .hsrc_exec
    jmp .hsrc_truncate

.hsrc_skip_cr:
    inc r13
    jmp .hsrc_cpy

.hsrc_exec:
    ; Skip past LF if present
    cmp byte [r13], 10
    jne .hsrc_no_lf
    inc r13
.hsrc_no_lf:
    mov byte [rdi + rcx], 0
    test ecx, ecx
    jz .hsrc_line                   ; empty line, skip

    ; Skip comment lines (starting with '#')
    lea rax, [input_buf]
    cmp byte [rax], '#'
    je .hsrc_line

    ; Dispatch the command
    call dispatch_command
    jmp .hsrc_line

.hsrc_noargs:
    lea rdi, [err_source_msg]
    mov esi, err_source_len
    call print_string_len
    jmp .hsrc_done_nodepth

.hsrc_open_err:
    lea rdi, [err_source_open]
    mov esi, err_source_o_len
    call print_string_len
    jmp .hsrc_done

.hsrc_depth_err:
    lea rdi, [err_source_depth_msg]
    mov esi, err_source_depth_len
    call print_string_len
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
    ; Move to start of line
    lea rdi, [str_cr]
    mov esi, 1
    call print_string_len

    ; Clear the entire line
    lea rdi, [ansi_clear_eol]
    mov esi, ansi_clear_eol_len
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

    lea rdi, [str_cr]
    mov esi, 1
    call print_string_len
    lea rdi, [ansi_clear_eol]
    mov esi, ansi_clear_eol_len
    call print_string_len
    call redraw_line
    jmp .rhs_done

.rhs_cancel:
    lea rdi, [str_cr]
    mov esi, 1
    call print_string_len
    lea rdi, [ansi_clear_eol]
    mov esi, ansi_clear_eol_len
    call print_string_len
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

    pop rsi
    pop rdi
    pop rcx
    pop rbp
    ret

; ============================================================================
; handler_ls - List directory contents with optional -l, -a flags and colors
; ============================================================================
handler_ls:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56

    mov rbx, rdi                    ; rbx = args (may be NULL)
    mov byte [ls_flags], 0          ; clear flags

    ; --- Parse flags ---
    test rbx, rbx
    jz .ls_no_flags
    cmp byte [rbx], 0
    je .ls_no_flags

.ls_parse_flags:
    cmp byte [rbx], '-'
    jne .ls_no_flags

    inc rbx                         ; skip '-'
.ls_flag_loop:
    movzx eax, byte [rbx]
    cmp al, 0
    je .ls_flags_done_advance
    cmp al, ' '
    je .ls_flags_done_advance
    cmp al, 'l'
    je .ls_set_l
    cmp al, 'a'
    je .ls_set_a
    inc rbx
    jmp .ls_flag_loop

.ls_set_l:
    or byte [ls_flags], 1           ; bit 0 = long listing
    inc rbx
    jmp .ls_flag_loop

.ls_set_a:
    or byte [ls_flags], 2           ; bit 1 = show all
    inc rbx
    jmp .ls_flag_loop

.ls_flags_done_advance:
    cmp byte [rbx], ' '
    jne .ls_check_more_flags
    inc rbx
    jmp .ls_flags_done_advance

.ls_check_more_flags:
    cmp byte [rbx], '-'
    je .ls_parse_flags
    cmp byte [rbx], 0
    jne .ls_have_path
    jmp .ls_use_dot

.ls_no_flags:
    test rbx, rbx
    jz .ls_use_dot
    cmp byte [rbx], 0
    je .ls_use_dot

.ls_have_path:
    mov r15, rbx                    ; r15 = directory path
    jmp .ls_open_dir

.ls_use_dot:
    lea r15, [str_dot]              ; default to "."

.ls_open_dir:
    mov rdi, r15
    mov esi, O_RDONLY | O_DIRECTORY
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .ls_open_err
    mov r12d, eax                   ; r12d = directory fd

.ls_read_batch:
    mov edi, r12d
    lea rsi, [dirent_buf]
    mov edx, DIRENT_BUF_SIZE
    mov eax, SYS_GETDENTS64
    syscall
    test rax, rax
    jle .ls_close                   ; 0 = done, negative = error

    mov r13d, eax                   ; r13d = bytes returned
    xor r14d, r14d                  ; r14d = offset into buffer

.ls_entry:
    cmp r14d, r13d
    jge .ls_read_batch

    lea rsi, [dirent_buf]
    add rsi, r14
    mov [rbp - 64], rsi             ; save dirent ptr

    lea rbx, [rsi + DIRENT64_D_NAME]

    ; --- Skip . and .. unless -a flag ---
    cmp byte [rbx], '.'
    jne .ls_check_hidden
    cmp byte [rbx + 1], 0
    je .ls_maybe_skip_dot
    cmp byte [rbx + 1], '.'
    jne .ls_check_hidden_dot
    cmp byte [rbx + 2], 0
    je .ls_maybe_skip_dot
    jmp .ls_check_hidden_dot

.ls_maybe_skip_dot:
    test byte [ls_flags], 2
    jz .ls_next_entry
    jmp .ls_do_stat

.ls_check_hidden_dot:
    test byte [ls_flags], 2
    jz .ls_next_entry
    jmp .ls_do_stat

.ls_check_hidden:

.ls_do_stat:
    mov edi, r12d
    mov rsi, rbx
    lea rdx, [stat_buf]
    xor r10d, r10d
    mov eax, SYS_NEWFSTATAT
    syscall

    mov eax, [stat_buf + STAT_ST_MODE]
    mov ecx, eax

    and eax, 0xF000
    cmp eax, S_IFDIR
    je .ls_entry_is_dir

    test ecx, S_IXUSR | S_IXGRP | S_IXOTH
    jnz .ls_entry_is_exec

    jmp .ls_entry_is_regular

.ls_entry_is_dir:
    test byte [ls_flags], 1
    jz .ls_dir_short

    mov ecx, [stat_buf + STAT_ST_MODE]
    call print_ls_perms
    lea rdi, [str_two_spaces]
    call print_cstring

    mov rax, [stat_buf + STAT_ST_SIZE]   ; full 64-bit size
    call print_number_9pad
    lea rdi, [str_space]
    call print_cstring

.ls_dir_short:
    lea rdi, [ansi_blue]
    mov esi, ansi_blue_len
    call print_string_len

    mov rdi, rbx
    call print_cstring

    lea rdi, [ansi_default]
    mov esi, ansi_default_len
    call print_string_len

    test byte [ls_flags], 1
    jnz .ls_entry_newline
    lea rdi, [str_two_spaces]
    call print_cstring
    jmp .ls_entry_done

.ls_entry_is_exec:
    test byte [ls_flags], 1
    jz .ls_exec_short

    mov ecx, [stat_buf + STAT_ST_MODE]
    call print_ls_perms
    lea rdi, [str_two_spaces]
    call print_cstring

    mov rax, [stat_buf + STAT_ST_SIZE]   ; full 64-bit size
    call print_number_9pad
    lea rdi, [str_space]
    call print_cstring

.ls_exec_short:
    lea rdi, [ansi_green_ls]
    mov esi, ansi_green_ls_len
    call print_string_len

    mov rdi, rbx
    call print_cstring

    lea rdi, [ansi_default]
    mov esi, ansi_default_len
    call print_string_len

    test byte [ls_flags], 1
    jnz .ls_entry_newline
    lea rdi, [str_two_spaces]
    call print_cstring
    jmp .ls_entry_done

.ls_entry_is_regular:
    test byte [ls_flags], 1
    jz .ls_reg_short

    mov ecx, [stat_buf + STAT_ST_MODE]
    call print_ls_perms
    lea rdi, [str_two_spaces]
    call print_cstring

    mov rax, [stat_buf + STAT_ST_SIZE]   ; full 64-bit size
    call print_number_9pad
    lea rdi, [str_space]
    call print_cstring

.ls_reg_short:
    mov rdi, rbx
    call print_cstring

    test byte [ls_flags], 1
    jnz .ls_entry_newline
    lea rdi, [str_two_spaces]
    call print_cstring
    jmp .ls_entry_done

.ls_entry_newline:
    call print_newline

.ls_entry_done:

.ls_next_entry:
    mov rsi, [rbp - 64]
    movzx eax, word [rsi + DIRENT64_D_RECLEN]
    add r14d, eax
    jmp .ls_entry

.ls_close:
    test byte [ls_flags], 1
    jnz .ls_close_fd
    call print_newline

.ls_close_fd:
    mov edi, r12d
    mov eax, SYS_CLOSE
    syscall
    jmp .ls_done

.ls_open_err:
    neg eax
    mov edi, eax
    call print_last_error

.ls_done:
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret


; ============================================================================
; handler_grep - Simple substring search in a file with color highlighting
; ============================================================================
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

    mov r12, rax                    ; r12 = pattern
    mov r13, rdx                    ; r13 = filename

    lea rdi, [grep_pattern_buf]
    mov rsi, r12
    call str_copy
    lea r12, [grep_pattern_buf]

    mov rdi, r12
    call str_len
    mov r14d, eax                   ; r14d = pattern length
    test r14d, r14d
    jz .grep_usage

    mov rdi, r13
    mov esi, O_RDONLY
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    js .grep_file_err
    mov ebx, eax                    ; ebx = file descriptor

    xor r15d, r15d                  ; line buffer write position

.grep_read_chunk:
    mov edi, ebx
    lea rsi, [read_buffer]
    mov edx, READ_BUF_SIZE
    mov eax, SYS_READ
    syscall
    test rax, rax
    jle .grep_flush_last

    mov r13d, eax
    xor ecx, ecx

.grep_scan_byte:
    cmp ecx, r13d
    jge .grep_read_chunk

    movzx eax, byte [read_buffer + rcx]
    cmp al, 10
    je .grep_end_line

    cmp r15d, 4094
    jge .grep_skip_byte
    mov [grep_line_buf + r15], al
    inc r15d

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

.grep_close:
    mov edi, ebx
    mov eax, SYS_CLOSE
    syscall
    jmp .grep_done

.grep_usage:
    lea rdi, [err_grep_usage]
    mov esi, err_grep_usage_len
    call print_string_len
    jmp .grep_done

.grep_file_err:
    lea rdi, [err_file_msg]
    mov esi, err_file_len
    call print_string_len

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

    xor ebx, ebx
.ghl_first_scan:
    mov eax, r13d
    sub eax, ebx
    cmp eax, r15d
    jl .ghl_no_match

    lea rdi, [r12 + rbx]
    mov rsi, r14
    mov ecx, r15d
    call grep_memcmp
    test eax, eax
    jz .ghl_found_first
    inc ebx
    jmp .ghl_first_scan

.ghl_no_match:
    jmp .ghl_done

.ghl_found_first:
    xor ebx, ebx

.ghl_print_loop:
    cmp ebx, r13d
    jge .ghl_print_newline

    mov eax, r13d
    sub eax, ebx
    cmp eax, r15d
    jl .ghl_print_rest

    lea rdi, [r12 + rbx]
    mov rsi, r14
    mov ecx, r15d
    call grep_memcmp
    test eax, eax
    jz .ghl_print_match

    lea rdi, [r12 + rbx]
    mov esi, 1
    call print_string_len
    inc ebx
    jmp .ghl_print_loop

.ghl_print_match:
    lea rdi, [ansi_red_hi]
    mov esi, ansi_red_hi_len
    call print_string_len

    lea rdi, [r12 + rbx]
    mov esi, r15d
    call print_string_len

    lea rdi, [ansi_default]
    mov esi, ansi_default_len
    call print_string_len

    add ebx, r15d
    jmp .ghl_print_loop

.ghl_print_rest:
    mov eax, r13d
    sub eax, ebx
    test eax, eax
    jz .ghl_print_newline
    lea rdi, [r12 + rbx]
    mov esi, eax
    call print_string_len

.ghl_print_newline:
    call print_newline

.ghl_done:
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
    call print_string_len

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
    call print_string_len
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
    jmp .calc_print_result

.calc_have_op:
    inc r12

    mov rdi, r12
    call skip_spaces
    mov r12, rax

    mov rdi, r12
    call calc_parse_number
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
    jmp .calc_loop

.calc_sub:
    sub r13, r15
    jmp .calc_loop

.calc_mul:
    mov rax, r13
    imul r15
    mov r13, rax
    jmp .calc_loop

.calc_div:
    test r15, r15
    jz .calc_div_zero

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
    call print_string_len
    jmp .calc_done

.calc_usage:
    lea rdi, [err_calc_usage]
    mov esi, err_calc_usage_len
    call print_string_len

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
; Returns: rax = number, rdx = ptr after number, rcx = 1 if ok, 0 if error
; ============================================================================
calc_parse_number:
    push rbx
    push r12

    mov rax, rdi
.cpn_skip:
    cmp byte [rax], ' '
    jne .cpn_check_sign
    inc rax
    jmp .cpn_skip

.cpn_check_sign:
    xor r12d, r12d
    cmp byte [rax], '-'
    jne .cpn_check_plus
    mov r12d, 1
    inc rax
    jmp .cpn_digits

.cpn_check_plus:
    cmp byte [rax], '+'
    jne .cpn_digits
    inc rax

.cpn_digits:
    xor rbx, rbx
    xor ecx, ecx

.cpn_digit_loop:
    movzx edx, byte [rax]
    sub dl, '0'
    cmp dl, 9
    ja .cpn_done_digits
    imul rbx, 10
    movzx edx, dl
    add rbx, rdx
    inc ecx
    inc rax
    jmp .cpn_digit_loop

.cpn_done_digits:
    test ecx, ecx
    jz .cpn_error

    test r12d, r12d
    jz .cpn_positive
    neg rbx

.cpn_positive:
    mov rdx, rax
    mov rax, rbx
    mov ecx, 1
    pop r12
    pop rbx
    ret

.cpn_error:
    xor eax, eax
    xor edx, edx
    xor ecx, ecx
    pop r12
    pop rbx
    ret


; ============================================================================
; ==================== BATCH 4 FUNCTIONS ====================================
; ============================================================================

; ============================================================================
; ============================================================================
; emit_osc7_cwd - emit ESC]7;file://host/path BEL so modern terminals
; (Ghostty, WezTerm, iTerm2, kitty, Warp, VS Code) track the shell's cwd.
; ============================================================================
emit_osc7_cwd:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    lea rdi, [osc7_prefix]
    mov esi, osc7_prefix_len
    call print_string_len

    lea rdi, [cached_hostname]
    call print_cstring

    lea rdi, [path_buf]
    mov esi, MAX_PATH_BUF
    mov eax, SYS_GETCWD
    syscall
    test rax, rax
    jle .osc7_done

    lea rdi, [path_buf]
    call print_cstring

.osc7_done:
    lea rdi, [osc7_bel]
    call print_cstring

    leave
    ret

; init_prompt_cache - Cache username and hostname at startup
; ============================================================================
init_prompt_cache:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 16

    ; --- Cache username from $USER ---
    lea rdi, [str_user]
    call getenv_internal
    test rax, rax
    jz .ipc_default_user

    lea rdi, [cached_username]
    mov rsi, rax
    call str_copy
    jmp .ipc_hostname

.ipc_default_user:
    lea rdi, [cached_username]
    lea rsi, [str_unknown_user]
    call str_copy

.ipc_hostname:
    lea rdi, [uname_buf]
    mov eax, SYS_UNAME
    syscall
    test rax, rax
    js .ipc_default_host

    lea rdi, [cached_hostname]
    lea rsi, [uname_buf + 65]
    call str_copy
    jmp .ipc_init_jobs

.ipc_default_host:
    lea rdi, [cached_hostname]
    lea rsi, [str_unknown_host]
    call str_copy

.ipc_init_jobs:
    mov dword [job_count], 0
    mov dword [current_theme], 0    ; default theme

    lea rdi, [job_pids]
    xor eax, eax
    mov ecx, JOB_MAX
.ipc_clear_jobs:
    mov qword [rdi], 0
    add rdi, 8
    dec ecx
    jnz .ipc_clear_jobs

    add rsp, 16
    pop rbx
    pop rbp
    ret


; ============================================================================
; print_prompt - Print themed prompt (user@host:path$)
; ============================================================================
print_prompt:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    sub rsp, 16

    ; OSC 133 A — mark the start of a new prompt region
    lea rdi, [osc133_a]
    call print_cstring

    ; OSC 7 — emit cwd for terminal integration
    call emit_osc7_cwd

    mov eax, [current_theme]
    mov r12d, eax

    cmp r12d, 2
    je .pp_classic

    ; --- Print user@host portion ---
    mov eax, r12d
    imul eax, THEME_ENTRY_SIZE
    lea rbx, [theme_table + rax]

    mov rdi, [rbx]
    mov esi, [rbx + 8]
    call print_string_len

    lea rdi, [cached_username]
    call print_cstring

    lea rdi, [str_at]
    call print_cstring

    lea rdi, [cached_hostname]
    call print_cstring

    mov rdi, [rbx + 32]
    mov esi, [rbx + 40]
    call print_string_len

    lea rdi, [str_colon]
    call print_cstring

    ; --- Print path portion ---
    mov rdi, [rbx + 16]
    mov esi, [rbx + 24]
    call print_string_len

    lea rdi, [path_buf]
    mov esi, MAX_PATH_BUF
    mov eax, SYS_GETCWD
    syscall

    lea rdi, [path_buf]
    call print_cstring

    mov rdi, [rbx + 32]
    mov esi, [rbx + 40]
    call print_string_len

    mov rdi, [rbx + 48]
    mov esi, [rbx + 56]
    call print_string_len

    ; Calculate prompt_total_len
    lea rdi, [cached_username]
    call str_len
    mov ebx, eax

    lea rdi, [cached_hostname]
    call str_len
    add ebx, eax
    add ebx, 2                      ; "@" + ":"

    lea rdi, [path_buf]
    call str_len
    add ebx, eax
    add ebx, 2                      ; "$ " (symbol always 2 chars)

    mov [prompt_total_len], ebx
    jmp .pp_done

.pp_classic:
    mov eax, r12d
    imul eax, THEME_ENTRY_SIZE
    lea rbx, [theme_table + rax]

    mov rdi, [rbx + 16]
    mov esi, [rbx + 24]
    call print_string_len

    lea rdi, [path_buf]
    mov esi, MAX_PATH_BUF
    mov eax, SYS_GETCWD
    syscall

    lea rdi, [path_buf]
    call print_cstring

    mov rdi, [rbx + 32]
    mov esi, [rbx + 40]
    call print_string_len

    mov rdi, [rbx + 48]
    mov esi, [rbx + 56]
    call print_string_len

    lea rdi, [path_buf]
    call str_len
    add eax, 2
    mov [prompt_total_len], eax

.pp_done:
    call print_git_branch_if_any

    ; OSC 133 B — prompt rendering finished, command entry begins
    lea rdi, [osc133_b]
    call print_cstring

    add rsp, 16
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; read_git_branch - walk up from cwd looking for .git/HEAD; on success,
; write branch name (or short SHA) into git_branch + NUL. On failure,
; git_branch[0] = 0.
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

    ; Open the candidate file
    lea rdi, [git_scratch_path]
    mov esi, O_RDONLY
    xor edx, edx
    mov eax, SYS_OPEN
    syscall
    test rax, rax
    jns .rgb_opened

    ; Not here — truncate git_scratch_path at last '/' and retry
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

    ; If starts with "ref: refs/heads/", copy branch name; else copy
    ; first 8 chars of SHA for a detached HEAD.
    lea rsi, [str_ref_prefix]
    lea rdi, [git_head_buf]
    call str_startswith
    test eax, eax
    jz .rgb_detached

    lea rsi, [git_head_buf + 16]       ; skip prefix
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
; print_git_branch_if_any - emit " (branch)" in yellow if cwd is in a repo
; ============================================================================
print_git_branch_if_any:
    push rbp
    mov rbp, rsp
    sub rsp, 16

    call read_git_branch
    cmp byte [git_branch], 0
    je .pgb_done

    lea rdi, [git_prompt_pre]
    call print_cstring
    lea rdi, [git_branch]
    call print_cstring
    lea rdi, [git_prompt_post]
    call print_cstring

.pgb_done:
    leave
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
    call print_cstring
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
; handler_jobs - List active background jobs
; ============================================================================
handler_jobs:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 32

    call reap_finished_jobs

    mov eax, [job_count]
    test eax, eax
    jz .hj_none

    lea rdi, [jobs_header_msg]
    call print_cstring

    xor r12d, r12d
    xor r13d, r13d

.hj_loop:
    cmp r12d, JOB_MAX
    jge .hj_done

    lea rbx, [job_pids]
    mov rax, [rbx + r12*8]
    test rax, rax
    jz .hj_next

    inc r13d
    mov r14, rax

    lea rdi, [jobs_bracket_open]
    call print_cstring

    mov eax, r13d
    call print_number

    lea rdi, [jobs_bracket_close]
    call print_cstring

    lea rdi, [jobs_pid_label]
    call print_cstring

    mov rax, r14
    mov eax, eax
    call print_number

    ; Check if still running with waitpid WNOHANG
    mov edi, r14d
    lea rsi, [pid_buf]
    mov edx, WNOHANG
    xor r10d, r10d
    mov eax, SYS_WAIT4
    syscall

    test rax, rax
    jz .hj_still_running

    ; Job finished - mark slot as empty
    lea rbx, [job_pids]
    mov qword [rbx + r12*8], 0
    dec dword [job_count]

    lea rdi, [jobs_done_msg]
    call print_cstring
    jmp .hj_print_cmd

.hj_still_running:
    lea rdi, [jobs_running_msg]
    call print_cstring

.hj_print_cmd:
    mov eax, r12d
    imul eax, JOB_CMD_SIZE
    lea rdi, [job_cmds + rax]
    call print_cstring
    call print_newline

.hj_next:
    inc r12d
    jmp .hj_loop

.hj_none:
    lea rdi, [jobs_none_msg]
    call print_cstring

.hj_done:
    add rsp, 32
    pop r14
    pop r13
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

    lea rbx, [job_pids]
    mov rax, [rbx + r12*8]
    test rax, rax
    jz .rfj_next

    mov edi, eax
    lea rsi, [pid_buf]
    mov edx, WNOHANG
    xor r10d, r10d
    mov eax, SYS_WAIT4
    syscall

    test rax, rax
    jz .rfj_next
    lea rbx, [job_pids]
    mov qword [rbx + r12*8], 0
    dec dword [job_count]

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
; handler_fg - Bring background job to foreground
; rdi = argument string ("1", "2", etc.) or NULL
; ============================================================================
handler_fg:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 16

    test rdi, rdi
    jz .hfg_noarg
    cmp byte [rdi], 0
    je .hfg_noarg

    xor eax, eax
    xor ecx, ecx

.hfg_parse_num:
    movzx edx, byte [rdi]
    test dl, dl
    jz .hfg_parsed
    cmp dl, ' '
    je .hfg_parsed
    sub dl, '0'
    cmp dl, 9
    ja .hfg_invalid
    imul ecx, ecx, 10
    movzx edx, dl
    add ecx, edx
    inc rdi
    jmp .hfg_parse_num

.hfg_parsed:
    test ecx, ecx
    jz .hfg_invalid

    xor r12d, r12d
    xor r13d, r13d

.hfg_find:
    cmp r12d, JOB_MAX
    jge .hfg_invalid

    lea rbx, [job_pids]
    mov rax, [rbx + r12*8]
    test rax, rax
    jz .hfg_find_next

    inc r13d
    cmp r13d, ecx
    je .hfg_found

.hfg_find_next:
    inc r12d
    jmp .hfg_find

.hfg_found:
    lea rbx, [job_pids]
    mov rax, [rbx + r12*8]
    mov ebx, eax

    ; Print the command
    mov eax, r12d
    imul eax, JOB_CMD_SIZE
    lea rdi, [job_cmds + rax]
    call print_cstring
    call print_newline

    call restore_terminal

    ; Resume the job if stopped (SIGCONT). Harmless if already running.
    mov edi, ebx
    mov esi, SIGCONT
    mov eax, SYS_KILL
    syscall

    ; Wait on the child
    mov edi, ebx
    lea rsi, [pid_buf]
    xor edx, edx
    xor r10d, r10d
    mov eax, SYS_WAIT4
    syscall

    call setup_raw_mode

    ; Remove from job table
    lea rdi, [job_pids]
    mov qword [rdi + r12*8], 0
    dec dword [job_count]

    jmp .hfg_done

.hfg_noarg:
    lea rdi, [jobs_fg_noarg_msg]
    call print_cstring
    jmp .hfg_done

.hfg_invalid:
    lea rdi, [jobs_fg_invalid_msg]
    call print_cstring

.hfg_done:
    add rsp, 16
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; handler_bg - resume a stopped background job (SIGCONT), do NOT wait
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

    ; Parse job number
    xor ecx, ecx
.hbg_parse:
    movzx edx, byte [rdi]
    test dl, dl
    jz .hbg_parsed
    cmp dl, ' '
    je .hbg_parsed
    sub dl, '0'
    cmp dl, 9
    ja .hbg_noarg
    imul ecx, ecx, 10
    movzx edx, dl
    add ecx, edx
    inc rdi
    jmp .hbg_parse
.hbg_parsed:
    test ecx, ecx
    jz .hbg_noarg

    xor r12d, r12d
    xor r13d, r13d
.hbg_find:
    cmp r12d, JOB_MAX
    jge .hbg_noarg
    lea rbx, [job_pids]
    mov rax, [rbx + r12*8]
    test rax, rax
    jz .hbg_next
    inc r13d
    cmp r13d, ecx
    je .hbg_found
.hbg_next:
    inc r12d
    jmp .hbg_find

.hbg_found:
    lea rbx, [job_pids]
    mov rbx, [rbx + r12*8]
    mov edi, ebx
    mov esi, SIGCONT
    mov eax, SYS_KILL
    syscall

    lea rdi, [bg_resumed_msg]
    call print_cstring
    mov eax, ecx
    call print_number
    call print_newline
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

    ; Print "Error: " prefix
    lea rdi, [.ple_prefix]
    call print_cstring

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
    call print_cstring
    mov eax, ebx
    call print_number
    call print_newline
    jmp .ple_done

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
    call print_cstring
    call print_newline

.ple_done:
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
