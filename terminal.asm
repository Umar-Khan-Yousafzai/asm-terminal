; ============================================================================
; ASM Terminal v2.0 - Full-featured terminal in x86-64 Assembly (NASM)
; Target: Windows x64, linked with MinGW ld
; ============================================================================
bits 64
default rel

; ---- External Windows API functions ----
extern GetStdHandle
extern WriteConsoleA
extern ReadConsoleA
extern SetConsoleTitleA
extern GetCurrentDirectoryA
extern SetCurrentDirectoryA
extern GetLocalTime
extern SetConsoleTextAttribute
extern CreateProcessA
extern WaitForSingleObject
extern CloseHandle
extern ExitProcess
extern FillConsoleOutputCharacterA
extern FillConsoleOutputAttribute
extern GetConsoleScreenBufferInfo
extern SetConsoleCursorPosition
extern GetConsoleMode
extern SetConsoleMode
extern ReadConsoleInputA
extern FindFirstFileA
extern FindNextFileA
extern FindClose
extern CreateFileA
extern ReadFile
extern WriteFile
extern DeleteFileA
extern CreateDirectoryA
extern RemoveDirectoryA
extern CopyFileA
extern MoveFileA
extern GetFileAttributesA
extern GetComputerNameA
extern GetEnvironmentVariableA
extern SetEnvironmentVariableA
extern GetEnvironmentStringsA
extern FreeEnvironmentStringsA
extern GetModuleFileNameA
extern CreatePipe
extern SetStdHandle
extern GetLastError
extern FormatMessageA
extern SetConsoleCtrlHandler

; ---- Constants ----
%define STD_INPUT_HANDLE  -10
%define STD_OUTPUT_HANDLE -11
%define MAX_INPUT         512
%define MAX_PATH_BUF      260
%define INFINITE          0xFFFFFFFF
%define ENABLE_PROCESSED_INPUT  0x0001
%define ENABLE_LINE_INPUT       0x0002
%define ENABLE_ECHO_INPUT       0x0004
%define VK_BACK     0x08
%define VK_TAB      0x09
%define VK_RETURN   0x0D
%define VK_END      0x23
%define VK_HOME     0x24
%define VK_LEFT     0x25
%define VK_UP       0x26
%define VK_RIGHT    0x27
%define VK_DOWN     0x28
%define VK_DELETE   0x2E
%define IR_EVENT_TYPE     0
%define IR_KEY_DOWN       4
%define IR_VKEY_CODE      10
%define IR_ASCII_CHAR     14
%define INPUT_RECORD_SIZE 20
%define GENERIC_READ        0x80000000
%define GENERIC_WRITE       0x40000000
%define FILE_SHARE_READ     0x00000001
%define CREATE_ALWAYS       2
%define OPEN_EXISTING       3
%define OPEN_ALWAYS         4
%define FILE_ATTRIBUTE_NORMAL     0x80
%define FILE_ATTRIBUTE_DIRECTORY  0x10
%define INVALID_HANDLE_VALUE      -1
%define FD_ATTRS       0
%define FD_SIZE_HIGH   28
%define FD_SIZE_LOW    32
%define FD_FILENAME    44
%define FIND_DATA_SIZE 320
%define SI_FLAGS       60
%define SI_STDIN       80
%define SI_STDOUT      88
%define SI_STDERR      96
%define STARTF_USESTDHANDLES  0x100
%define FORMAT_MESSAGE_FROM_SYSTEM     0x1000
%define FORMAT_MESSAGE_IGNORE_INSERTS  0x200
%define HISTORY_COUNT      32
%define HISTORY_ENTRY_SIZE 512
%define ALIAS_COUNT        32
%define ALIAS_NAME_SIZE    64
%define ALIAS_CMD_SIZE     256
%define ALIAS_ENTRY_SIZE   320
%define DIR_STACK_COUNT    16
%define READ_BUF_SIZE      4096
%define COLOR_GREEN   0x0A
%define COLOR_WHITE   0x0F
%define COLOR_DEFAULT 0x07
%define FILE_APPEND_DATA 0x0004

; ---- Data Section ----
section .data
    prompt_gt       db "> ", 0
    newline         db 13, 10, 0

    welcome_msg     db 13, 10
                    db "      _    ____  __  __", 13, 10
                    db "     / \  / ___||  \/  |", 13, 10
                    db "    / _ \ \___ \| |\/| |", 13, 10
                    db "   / ___ \ ___) | |  | |", 13, 10
                    db "  /_/   \_\____/|_|  |_|", 13, 10
                    db 13, 10
                    db "  ASM Terminal v2.0 - x86-64 Assembly Shell", 13, 10
                    db "  Type 'help' for available commands", 13, 10
                    db 13, 10, 0
    welcome_len     equ $ - welcome_msg - 1

    help_msg        db 13, 10
                    db "  Built-in Commands:", 13, 10
                    db "  -----------------------------------------------", 13, 10
                    db "  Navigation:", 13, 10
                    db "    cd <path>     Change directory (cd - for prev)", 13, 10
                    db "    pwd           Print working directory", 13, 10
                    db "    pushd <path>  Push directory onto stack", 13, 10
                    db "    popd          Pop directory from stack", 13, 10
                    db "  Files:", 13, 10
                    db "    dir [path]    List directory contents", 13, 10
                    db "    type <file>   Display file contents", 13, 10
                    db "    copy <s> <d>  Copy file", 13, 10
                    db "    move <s> <d>  Move/rename file", 13, 10
                    db "    rename <s><d> Rename file", 13, 10
                    db "    del <file>    Delete file", 13, 10
                    db "    mkdir <dir>   Create directory", 13, 10
                    db "    rmdir <dir>   Remove directory", 13, 10
                    db "  Environment:", 13, 10
                    db "    set [var=val] View/set environment variables", 13, 10
                    db "    whoami        Display current username", 13, 10
                    db "  Display:", 13, 10
                    db "    echo <text>   Print text to screen", 13, 10
                    db "    cls           Clear the screen", 13, 10
                    db "    color <hex>   Set console color (e.g. 0A)", 13, 10
                    db "    title <text>  Set console window title", 13, 10
                    db "  System:", 13, 10
                    db "    ver           Show version info", 13, 10
                    db "    date          Show current date", 13, 10
                    db "    time          Show current time", 13, 10
                    db "    alias <n>=<c> Create command alias", 13, 10
                    db "    help          This help message", 13, 10
                    db "    exit          Exit the terminal", 13, 10
                    db 13, 10
                    db "  Features: Tab completion, history (Up/Down),", 13, 10
                    db "  env vars (%VAR%), redirection (> >> <), piping (|)", 13, 10
                    db 13, 10, 0
    help_len        equ $ - help_msg - 1

    ver_msg         db "ASM Terminal v2.0 [x86-64 NASM/Windows]", 13, 10, 0
    ver_len         equ $ - ver_msg - 1
    err_cd_msg      db "Error: Could not change directory.", 13, 10, 0
    err_cd_len      equ $ - err_cd_msg - 1
    err_exec_msg    db "Error: Could not execute command.", 13, 10, 0
    err_exec_len    equ $ - err_exec_msg - 1
    err_file_msg    db "Error: Could not open file.", 13, 10, 0
    err_file_len    equ $ - err_file_msg - 1
    err_args_msg    db "Error: Missing arguments.", 13, 10, 0
    err_args_len    equ $ - err_args_msg - 1
    err_stack_empty db "Error: Directory stack empty.", 13, 10, 0
    err_stack_e_len equ $ - err_stack_empty - 1
    err_stack_full  db "Error: Directory stack full.", 13, 10, 0
    err_stack_f_len equ $ - err_stack_full - 1
    err_alias_full  db "Error: Alias table full.", 13, 10, 0
    err_alias_f_len equ $ - err_alias_full - 1
    err_no_prev_dir db "Error: No previous directory.", 13, 10, 0
    err_no_prev_len equ $ - err_no_prev_dir - 1

    title_default   db "ASM Terminal v2.0", 0
    cmd_prefix      db "cmd.exe /c ", 0
    date_slash      db "/", 0
    time_colon      db ":", 0
    date_prefix     db "Date: ", 0
    date_prefix_len equ $ - date_prefix - 1
    time_prefix     db "Time: ", 0
    time_prefix_len equ $ - time_prefix - 1
    dir_header      db "  Directory of ", 0
    dir_tag         db "  <DIR>  ", 0
    str_username    db "USERNAME", 0
    str_dot         db ".", 0
    str_dotdot      db "..", 0
    str_equals      db "=", 0
    str_space       db " ", 0
    str_ctrlc       db "^C", 13, 10, 0

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
        dq 0, 0

    ; Prefix-match dispatch table: [name_ptr, handler_ptr, name_len] terminated by [0,0,0]
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
        dq 0, 0, 0

; ---- BSS Section ----
section .bss
    hStdOut         resq 1
    hStdIn          resq 1
    input_buf       resb MAX_INPUT
    chars_read      resd 1
    chars_written   resd 1
    path_buf        resb MAX_PATH_BUF
    cmd_line_buf    resb 1024
    num_buf         resb 16
    sys_time        resw 8
    startup_info    resb 104
    proc_info       resb 24
    csbi            resb 24
    orig_console_mode resd 1
    line_buf        resb MAX_INPUT
    line_len        resd 1
    line_cursor     resd 1
    input_record    resb 24
    events_read     resd 1
    prompt_row      resw 1
    prompt_col      resw 1
    history_buf     resb HISTORY_COUNT * HISTORY_ENTRY_SIZE
    history_write_idx resd 1
    history_count   resd 1
    history_nav_idx resd 1
    history_saved   resb MAX_INPUT
    history_browsing resb 1
    find_data       resb FIND_DATA_SIZE
    read_buffer     resb READ_BUF_SIZE
    file_path_buf   resb MAX_PATH_BUF
    find_pattern    resb MAX_PATH_BUF
    tab_find_handle resq 1
    tab_prefix      resb MAX_PATH_BUF
    tab_prefix_len  resd 1
    tab_active      resb 1
    tab_find_data   resb FIND_DATA_SIZE
    env_expand_buf  resb 1024
    env_var_name    resb 256
    env_var_value   resb 1024
    redir_stdout_handle resq 1
    redir_stdin_handle  resq 1
    redir_stdout_active resb 1
    redir_stdin_active  resb 1
    redir_append        resb 1
    redir_filename      resb MAX_PATH_BUF
    cleaned_cmd_buf     resb MAX_INPUT
    alias_table     resb ALIAS_COUNT * ALIAS_ENTRY_SIZE
    alias_count     resd 1
    dir_stack       resb DIR_STACK_COUNT * MAX_PATH_BUF
    dir_stack_top   resd 1
    prev_dir_buf    resb MAX_PATH_BUF
    has_prev_dir    resb 1
    ctrl_c_flag     resb 1
    err_msg_buf     resb 512
    bytes_rw        resd 1
    autoexec_path   resb MAX_PATH_BUF
    module_path     resb MAX_PATH_BUF

; ---- Code Section ----
section .text
    global main

; ============================================================================
; main - Entry point
; ============================================================================
main:
    push rbp
    mov rbp, rsp
    sub rsp, 96
    ; Get handles
    mov ecx, STD_OUTPUT_HANDLE
    call GetStdHandle
    mov [hStdOut], rax
    mov ecx, STD_INPUT_HANDLE
    call GetStdHandle
    mov [hStdIn], rax
    ; Set title
    lea rcx, [title_default]
    call SetConsoleTitleA
    ; Raw input mode
    call setup_raw_mode
    ; Ctrl+C handler
    lea rcx, [ctrl_c_handler]
    mov edx, 1
    call SetConsoleCtrlHandler
    ; Init state
    mov byte [has_prev_dir], 0
    mov dword [dir_stack_top], 0
    mov dword [alias_count], 0
    mov dword [history_count], 0
    mov dword [history_write_idx], 0
    mov byte [ctrl_c_flag], 0
    mov byte [redir_stdout_active], 0
    mov byte [redir_stdin_active], 0
    mov byte [tab_active], 0
    ; Welcome banner
    lea rcx, [welcome_msg]
    mov edx, welcome_len
    call print_string_len
    ; Autoexec
    call run_autoexec
.main_loop:
    ; Green path
    mov rcx, [hStdOut]
    mov edx, COLOR_GREEN
    call SetConsoleTextAttribute
    mov ecx, MAX_PATH_BUF
    lea rdx, [path_buf]
    call GetCurrentDirectoryA
    lea rcx, [path_buf]
    call print_cstring
    ; White >
    mov rcx, [hStdOut]
    mov edx, COLOR_WHITE
    call SetConsoleTextAttribute
    lea rcx, [prompt_gt]
    mov edx, 2
    call print_string_len
    ; Default for input
    mov rcx, [hStdOut]
    mov edx, COLOR_DEFAULT
    call SetConsoleTextAttribute
    ; Save cursor position for line editing
    mov rcx, [hStdOut]
    lea rdx, [csbi]
    call GetConsoleScreenBufferInfo
    mov ax, [csbi + 4]
    mov [prompt_col], ax
    mov ax, [csbi + 6]
    mov [prompt_row], ax
    ; Read line with editing
    call read_line
    cmp byte [input_buf], 0
    je .main_loop
    ; Add to history
    lea rcx, [input_buf]
    call history_add
    ; Dispatch
    call dispatch_command
    jmp .main_loop

; ============================================================================
; setup_raw_mode / restore_console_mode
; ============================================================================
setup_raw_mode:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov rcx, [hStdIn]
    lea rdx, [orig_console_mode]
    call GetConsoleMode
    mov eax, [orig_console_mode]
    and eax, 0xFFFFFFF9         ; clear LINE_INPUT | ECHO_INPUT
    or eax, ENABLE_PROCESSED_INPUT
    mov rcx, [hStdIn]
    mov edx, eax
    call SetConsoleMode
    leave
    ret

restore_console_mode:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov rcx, [hStdIn]
    mov edx, [orig_console_mode]
    call SetConsoleMode
    leave
    ret

; Ctrl+C handler (called by OS in separate thread)
ctrl_c_handler:
    cmp ecx, 0
    jne .cc_no
    mov byte [ctrl_c_flag], 1
    mov eax, 1
    ret
.cc_no:
    xor eax, eax
    ret

; ============================================================================
; read_line - Read input with line editing, history, tab completion
; ============================================================================
read_line:
    push rbp
    mov rbp, rsp
    push rbx
    push rdi
    sub rsp, 48
    mov dword [line_len], 0
    mov dword [line_cursor], 0
    mov byte [line_buf], 0
    mov byte [history_browsing], 0
    mov byte [tab_active], 0
.rl_loop:
    cmp byte [ctrl_c_flag], 0
    jne .rl_ctrlc
    mov rcx, [hStdIn]
    lea rdx, [input_record]
    mov r8d, 1
    lea r9, [events_read]
    call ReadConsoleInputA
    cmp word [input_record], 1
    jne .rl_loop
    cmp dword [input_record + IR_KEY_DOWN], 0
    je .rl_loop
    movzx ebx, word [input_record + IR_VKEY_CODE]
    movzx edi, byte [input_record + IR_ASCII_CHAR]
    ; Cancel tab on non-tab key
    cmp bx, VK_TAB
    je .rl_dispatch
    cmp byte [tab_active], 0
    je .rl_dispatch
    push rbx
    push rdi
    mov rcx, [tab_find_handle]
    cmp rcx, INVALID_HANDLE_VALUE
    je .rl_tab_skip
    call FindClose
.rl_tab_skip:
    mov byte [tab_active], 0
    pop rdi
    pop rbx
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
    ; Printable?
    cmp edi, 32
    jb .rl_loop
    cmp edi, 126
    ja .rl_loop
    cmp dword [line_len], MAX_INPUT - 2
    jge .rl_loop
    ; Shift right to insert
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
    mov [rax + rdx], dil
    inc dword [line_len]
    inc dword [line_cursor]
    mov ecx, [line_len]
    mov byte [rax + rcx], 0
    call redraw_line
    jmp .rl_loop
.rl_enter:
    lea r8, [line_buf]
    lea r9, [input_buf]
    mov ecx, [line_len]
    inc ecx
.rl_cpy:
    mov al, [r8]
    mov [r9], al
    inc r8
    inc r9
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
.rl_ctrlc:
    mov byte [ctrl_c_flag], 0
    mov dword [line_len], 0
    mov dword [line_cursor], 0
    mov byte [line_buf], 0
    mov byte [input_buf], 0
    lea rcx, [str_ctrlc]
    call print_cstring
.rl_done:
    add rsp, 48
    pop rdi
    pop rbx
    pop rbp
    ret

; ============================================================================
; redraw_line - Redraw line buffer at prompt position
; ============================================================================
redraw_line:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    ; Move cursor to prompt start
    movzx eax, word [prompt_col]
    movzx ecx, word [prompt_row]
    shl ecx, 16
    or eax, ecx
    mov rcx, [hStdOut]
    mov edx, eax
    call SetConsoleCursorPosition
    ; Write line content
    mov edx, [line_len]
    test edx, edx
    jz .rd_clear
    lea rcx, [line_buf]
    call print_string_len
.rd_clear:
    ; Fill spaces past text to clear old chars
    movzx eax, word [prompt_col]
    add eax, [line_len]
    movzx ecx, word [prompt_row]
    shl ecx, 16
    or eax, ecx
    mov rcx, [hStdOut]
    mov edx, ' '
    mov r8d, 20
    mov r9d, eax
    lea rax, [chars_written]
    mov [rsp + 32], rax
    call FillConsoleOutputCharacterA
    call update_cursor_pos
    leave
    ret

; ============================================================================
; update_cursor_pos - Set cursor to prompt_col + line_cursor
; ============================================================================
update_cursor_pos:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    movzx eax, word [prompt_col]
    add eax, [line_cursor]
    movzx edx, word [prompt_row]
    shl edx, 16
    or eax, edx
    mov rcx, [hStdOut]
    mov edx, eax
    call SetConsoleCursorPosition
    leave
    ret

; ============================================================================
; history_add - Add line to command history circular buffer
; rcx = string pointer
; ============================================================================
history_add:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 56
    mov rsi, rcx
    cmp byte [rsi], 0
    je .ha_done
    ; Skip duplicate of last entry
    mov eax, [history_count]
    test eax, eax
    jz .ha_add
    mov eax, [history_write_idx]
    test eax, eax
    jnz .ha_dup_idx
    mov eax, HISTORY_COUNT
.ha_dup_idx:
    dec eax
    imul eax, HISTORY_ENTRY_SIZE
    lea rdi, [history_buf]
    add rdi, rax
    mov rcx, rsi
    mov rdx, rdi
    call str_icompare
    test eax, eax
    jz .ha_done
.ha_add:
    mov eax, [history_write_idx]
    imul eax, HISTORY_ENTRY_SIZE
    lea rdi, [history_buf]
    add rdi, rax
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
    mov eax, [history_write_idx]
    inc eax
    cmp eax, HISTORY_COUNT
    jl .ha_nowrap
    xor eax, eax
.ha_nowrap:
    mov [history_write_idx], eax
    mov eax, [history_count]
    cmp eax, HISTORY_COUNT
    jge .ha_done
    inc eax
    mov [history_count], eax
.ha_done:
    mov eax, [history_write_idx]
    mov [history_nav_idx], eax
    mov byte [history_browsing], 0
    add rsp, 56
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================================
; history_navigate_up - Load previous history entry
; ============================================================================
history_navigate_up:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 56
    mov eax, [history_count]
    test eax, eax
    jz .hnu_done
    ; Save current line if first navigation
    cmp byte [history_browsing], 0
    jne .hnu_nav
    mov byte [history_browsing], 1
    lea rcx, [history_saved]
    lea rdx, [line_buf]
    call str_copy
.hnu_nav:
    mov eax, [history_nav_idx]
    test eax, eax
    jnz .hnu_dec
    mov eax, HISTORY_COUNT
.hnu_dec:
    dec eax
    ; Check if at oldest entry
    mov ecx, [history_write_idx]
    sub ecx, [history_count]
    jge .hnu_check
    add ecx, HISTORY_COUNT
.hnu_check:
    cmp eax, ecx
    je .hnu_done
    mov [history_nav_idx], eax
    imul eax, HISTORY_ENTRY_SIZE
    lea rdx, [history_buf]
    add rdx, rax
    lea rcx, [line_buf]
    call str_copy
    lea rcx, [line_buf]
    call str_len
    mov [line_len], eax
    mov [line_cursor], eax
    call redraw_line
.hnu_done:
    add rsp, 56
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================================
; history_navigate_down - Load next history entry or restore saved line
; ============================================================================
history_navigate_down:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 40
    cmp byte [history_browsing], 0
    je .hnd_done
    mov eax, [history_nav_idx]
    inc eax
    cmp eax, HISTORY_COUNT
    jl .hnd_nowrap
    xor eax, eax
.hnd_nowrap:
    cmp eax, [history_write_idx]
    je .hnd_restore
    mov [history_nav_idx], eax
    imul eax, HISTORY_ENTRY_SIZE
    lea rdx, [history_buf]
    add rdx, rax
    lea rcx, [line_buf]
    call str_copy
    lea rcx, [line_buf]
    call str_len
    mov [line_len], eax
    mov [line_cursor], eax
    call redraw_line
    jmp .hnd_done
.hnd_restore:
    mov [history_nav_idx], eax
    mov byte [history_browsing], 0
    lea rcx, [line_buf]
    lea rdx, [history_saved]
    call str_copy
    lea rcx, [line_buf]
    call str_len
    mov [line_len], eax
    mov [line_cursor], eax
    call redraw_line
.hnd_done:
    add rsp, 40
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
    push rsi
    push rdi
    push r12
    sub rsp, 48
    ; Expand environment variables
    call expand_env_vars
    ; Check aliases
    call check_alias
    ; Check for pipe - if found, pass entire command to cmd.exe
    lea rcx, [input_buf]
.dc_pipe_check:
    mov al, [rcx]
    test al, al
    jz .dc_no_pipe
    cmp al, '|'
    je .dc_external
    inc rcx
    jmp .dc_pipe_check
.dc_no_pipe:
    ; Parse redirection
    call parse_redirection
    ; Try exact match table
    lea rsi, [cmd_table_exact]
.dc_exact:
    mov rdi, [rsi]
    test rdi, rdi
    jz .dc_prefix
    lea rcx, [input_buf]
    mov rdx, rdi
    call str_icompare
    test eax, eax
    jz .dc_exact_found
    add rsi, 16
    jmp .dc_exact
.dc_exact_found:
    mov rax, [rsi + 8]
    xor ecx, ecx
    call rax
    jmp .dc_done
.dc_prefix:
    lea rsi, [cmd_table_prefix]
.dc_pfx_loop:
    mov rdi, [rsi]
    test rdi, rdi
    jz .dc_external
    mov r12d, [rsi + 16]
    lea rcx, [input_buf]
    mov rdx, rdi
    mov r8d, r12d
    call str_icompare_n
    test eax, eax
    jnz .dc_pfx_next
    lea rax, [input_buf]
    movzx eax, byte [rax + r12]
    cmp al, ' '
    je .dc_pfx_args
    cmp al, 0
    je .dc_pfx_noargs
.dc_pfx_next:
    add rsi, 24
    jmp .dc_pfx_loop
.dc_pfx_args:
    mov rbx, [rsi + 8]
    lea rcx, [input_buf]
    add rcx, r12
    inc rcx
    call skip_spaces
    mov rcx, rax
    call rbx
    jmp .dc_done
.dc_pfx_noargs:
    mov rax, [rsi + 8]
    xor ecx, ecx
    call rax
    jmp .dc_done
.dc_external:
    call execute_external
.dc_done:
    call restore_redirection
    add rsp, 48
    pop r12
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================================
; expand_env_vars - Replace %VAR% in input_buf with env values
; ============================================================================
expand_env_vars:
    push rbp
    mov rbp, rsp
    push r12
    push r13
    push r14
    sub rsp, 40
    lea r12, [input_buf]
    lea r13, [env_expand_buf]
.ev_loop:
    movzx eax, byte [r12]
    test al, al
    jz .ev_done
    cmp al, '%'
    je .ev_pct
    mov [r13], al
    inc r12
    inc r13
    jmp .ev_loop
.ev_pct:
    inc r12
    xor r14d, r14d
.ev_find:
    movzx eax, byte [r12 + r14]
    test al, al
    jz .ev_literal
    cmp al, '%'
    je .ev_found
    inc r14d
    jmp .ev_find
.ev_literal:
    mov byte [r13], '%'
    inc r13
    jmp .ev_loop
.ev_found:
    test r14d, r14d
    jz .ev_empty_pct
    lea rdi, [env_var_name]
    xor ecx, ecx
.ev_cpname:
    cmp ecx, r14d
    jge .ev_cpname_done
    mov al, [r12 + rcx]
    mov [rdi + rcx], al
    inc ecx
    jmp .ev_cpname
.ev_cpname_done:
    mov byte [rdi + rcx], 0
    add r12, r14
    inc r12
    lea rcx, [env_var_name]
    lea rdx, [env_var_value]
    mov r8d, 1024
    call GetEnvironmentVariableA
    test eax, eax
    jz .ev_loop
    lea rcx, [env_var_value]
.ev_cpval:
    mov al, [rcx]
    test al, al
    jz .ev_loop
    mov [r13], al
    inc r13
    inc rcx
    jmp .ev_cpval
.ev_empty_pct:
    mov byte [r13], '%'
    inc r13
    inc r12
    jmp .ev_loop
.ev_done:
    mov byte [r13], 0
    lea rcx, [input_buf]
    lea rdx, [env_expand_buf]
    call str_copy
    add rsp, 40
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
    sub rsp, 40
    mov eax, [alias_count]
    test eax, eax
    jz .ca_done
    lea rbx, [alias_table]
    xor r12d, r12d
.ca_loop:
    cmp r12d, [alias_count]
    jge .ca_done
    mov rcx, rbx
    call str_len
    mov r13d, eax
    lea rcx, [input_buf]
    mov rdx, rbx
    mov r8d, r13d
    call str_icompare_n
    test eax, eax
    jnz .ca_next
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
    lea rcx, [env_expand_buf]
    lea rdx, [rbx + ALIAS_NAME_SIZE]
    call str_copy
    lea rcx, [env_expand_buf]
    call str_len
    lea rcx, [env_expand_buf]
    add rcx, rax
    lea rdx, [input_buf]
    add rdx, r13
    call str_copy
    lea rcx, [input_buf]
    lea rdx, [env_expand_buf]
    call str_copy
.ca_done:
    add rsp, 40
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; parse_redirection - Scan input_buf for > >> <, open files, clean command
; ============================================================================
parse_redirection:
    push rbp
    mov rbp, rsp
    push rdi
    push r12
    push r13
    sub rsp, 56
    mov byte [redir_stdout_active], 0
    mov byte [redir_stdin_active], 0
    mov byte [redir_append], 0
    mov qword [redir_stdout_handle], 0
    mov qword [redir_stdin_handle], 0
    lea r12, [input_buf]
    lea r13, [cleaned_cmd_buf]
.pr_loop:
    movzx eax, byte [r12]
    test al, al
    jz .pr_finish
    cmp al, '>'
    je .pr_out
    cmp al, '<'
    je .pr_in
    mov [r13], al
    inc r12
    inc r13
    jmp .pr_loop
.pr_out:
    inc r12
    cmp byte [r12], '>'
    jne .pr_out_create
    inc r12
    mov byte [redir_append], 1
.pr_out_create:
.pr_skip1:
    cmp byte [r12], ' '
    jne .pr_fname_out
    inc r12
    jmp .pr_skip1
.pr_fname_out:
    lea rdi, [redir_filename]
.pr_cpfn1:
    movzx eax, byte [r12]
    test al, al
    jz .pr_cpfn1_done
    cmp al, ' '
    je .pr_cpfn1_done
    mov [rdi], al
    inc r12
    inc rdi
    jmp .pr_cpfn1
.pr_cpfn1_done:
    mov byte [rdi], 0
    lea rcx, [redir_filename]
    cmp byte [redir_append], 0
    jne .pr_append
    mov edx, GENERIC_WRITE
    xor r8d, r8d
    xor r9d, r9d
    mov dword [rsp + 32], CREATE_ALWAYS
    jmp .pr_do_open
.pr_append:
    mov edx, FILE_APPEND_DATA
    xor r8d, r8d
    xor r9d, r9d
    mov dword [rsp + 32], OPEN_ALWAYS
.pr_do_open:
    mov dword [rsp + 40], FILE_ATTRIBUTE_NORMAL
    mov qword [rsp + 48], 0
    call CreateFileA
    cmp rax, INVALID_HANDLE_VALUE
    je .pr_loop
    mov [redir_stdout_handle], rax
    mov byte [redir_stdout_active], 1
    jmp .pr_loop
.pr_in:
    inc r12
.pr_skip2:
    cmp byte [r12], ' '
    jne .pr_fname_in
    inc r12
    jmp .pr_skip2
.pr_fname_in:
    lea rdi, [redir_filename]
.pr_cpfn2:
    movzx eax, byte [r12]
    test al, al
    jz .pr_cpfn2_done
    cmp al, ' '
    je .pr_cpfn2_done
    mov [rdi], al
    inc r12
    inc rdi
    jmp .pr_cpfn2
.pr_cpfn2_done:
    mov byte [rdi], 0
    lea rcx, [redir_filename]
    mov edx, GENERIC_READ
    mov r8d, FILE_SHARE_READ
    xor r9d, r9d
    mov dword [rsp + 32], OPEN_EXISTING
    mov dword [rsp + 40], FILE_ATTRIBUTE_NORMAL
    mov qword [rsp + 48], 0
    call CreateFileA
    cmp rax, INVALID_HANDLE_VALUE
    je .pr_loop
    mov [redir_stdin_handle], rax
    mov byte [redir_stdin_active], 1
    jmp .pr_loop
.pr_finish:
    ; Strip trailing spaces from cleaned cmd
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
    lea rcx, [input_buf]
    lea rdx, [cleaned_cmd_buf]
    call str_copy
    add rsp, 56
    pop r13
    pop r12
    pop rdi
    pop rbp
    ret

; ============================================================================
; restore_redirection - Close redirect handles
; ============================================================================
restore_redirection:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    cmp byte [redir_stdout_active], 0
    je .rr_stdin
    mov rcx, [redir_stdout_handle]
    call CloseHandle
    mov byte [redir_stdout_active], 0
.rr_stdin:
    cmp byte [redir_stdin_active], 0
    je .rr_done
    mov rcx, [redir_stdin_handle]
    call CloseHandle
    mov byte [redir_stdin_active], 0
.rr_done:
    leave
    ret

; ============================================================================
; tab_complete - File/dir name completion on Tab key
; ============================================================================
tab_complete:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    sub rsp, 40
    cmp byte [tab_active], 1
    je .tc_next
    ; Find word start
    mov r12d, [line_cursor]
.tc_scan:
    test r12d, r12d
    jz .tc_start
    dec r12d
    lea rax, [line_buf]
    cmp byte [rax + r12], ' '
    jne .tc_scan
    inc r12d
.tc_start:
    ; Copy prefix + append *
    mov ebx, [line_cursor]
    sub ebx, r12d
    mov [tab_prefix_len], ebx
    xor ecx, ecx
.tc_cp:
    cmp ecx, ebx
    jge .tc_cp_done
    lea rax, [line_buf]
    add rax, r12
    mov dl, [rax + rcx]
    lea r8, [tab_prefix]
    mov [r8 + rcx], dl
    inc ecx
    jmp .tc_cp
.tc_cp_done:
    lea rax, [tab_prefix]
    mov byte [rax + rbx], '*'
    mov byte [rax + rbx + 1], 0
    lea rcx, [tab_prefix]
    lea rdx, [tab_find_data]
    call FindFirstFileA
    cmp rax, INVALID_HANDLE_VALUE
    je .tc_done
    mov [tab_find_handle], rax
    mov byte [tab_active], 1
    jmp .tc_check
.tc_next:
    mov rcx, [tab_find_handle]
    lea rdx, [tab_find_data]
    call FindNextFileA
    test eax, eax
    jnz .tc_check
    mov rcx, [tab_find_handle]
    call FindClose
    lea rcx, [tab_prefix]
    lea rdx, [tab_find_data]
    call FindFirstFileA
    cmp rax, INVALID_HANDLE_VALUE
    je .tc_done
    mov [tab_find_handle], rax
.tc_check:
    lea rcx, [tab_find_data + FD_FILENAME]
    cmp byte [rcx], '.'
    jne .tc_replace
    cmp byte [rcx + 1], 0
    je .tc_next
    cmp byte [rcx + 1], '.'
    jne .tc_replace
    cmp byte [rcx + 2], 0
    je .tc_next
.tc_replace:
    lea rcx, [tab_find_data + FD_FILENAME]
    call str_len
    mov r13d, eax
    lea r8, [line_buf]
    add r8, r12
    lea r9, [tab_find_data + FD_FILENAME]
    xor edx, edx
.tc_ins:
    cmp edx, r13d
    jge .tc_ins_done
    movzx eax, byte [r9 + rdx]
    mov [r8 + rdx], al
    inc edx
    jmp .tc_ins
.tc_ins_done:
    mov eax, r12d
    add eax, r13d
    mov [line_len], eax
    mov [line_cursor], eax
    lea rax, [line_buf]
    mov ecx, [line_len]
    mov byte [rax + rcx], 0
    call redraw_line
.tc_done:
    add rsp, 40
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; ============================================================================
; Command Handlers - Each takes rcx = args pointer (or NULL)
; ============================================================================
handler_help:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    lea rcx, [help_msg]
    mov edx, help_len
    call print_string_len
    leave
    ret

handler_cls:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    call clear_screen
    leave
    ret

handler_exit:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    call restore_console_mode
    xor ecx, ecx
    call ExitProcess

handler_ver:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    lea rcx, [ver_msg]
    mov edx, ver_len
    call print_string_len
    leave
    ret

handler_date:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    lea rcx, [sys_time]
    call GetLocalTime
    lea rcx, [date_prefix]
    mov edx, date_prefix_len
    call print_string_len
    movzx eax, word [sys_time + 2]
    call print_number_2digit
    lea rcx, [date_slash]
    call print_cstring
    movzx eax, word [sys_time + 6]
    call print_number_2digit
    lea rcx, [date_slash]
    call print_cstring
    movzx eax, word [sys_time]
    call print_number
    call print_newline
    leave
    ret

handler_time:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    lea rcx, [sys_time]
    call GetLocalTime
    lea rcx, [time_prefix]
    mov edx, time_prefix_len
    call print_string_len
    movzx eax, word [sys_time + 8]
    call print_number_2digit
    lea rcx, [time_colon]
    call print_cstring
    movzx eax, word [sys_time + 10]
    call print_number_2digit
    lea rcx, [time_colon]
    call print_cstring
    movzx eax, word [sys_time + 12]
    call print_number_2digit
    call print_newline
    leave
    ret

handler_echo:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    test rcx, rcx
    jz .he_empty
    cmp byte [rcx], 0
    je .he_empty
    call print_cstring
.he_empty:
    call print_newline
    leave
    ret

handler_title:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    test rcx, rcx
    jz .ht_done
    call SetConsoleTitleA
.ht_done:
    leave
    ret

handler_color:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 40
    test rcx, rcx
    jz .hco_done
    mov rbx, rcx
.hco_skip:
    cmp byte [rbx], ' '
    jne .hco_parse
    inc rbx
    jmp .hco_skip
.hco_parse:
    movzx eax, byte [rbx]
    call hex_to_int
    shl eax, 4
    mov [rsp + 32], eax
    movzx eax, byte [rbx + 1]
    call hex_to_int
    or eax, [rsp + 32]
    mov rcx, [hStdOut]
    mov edx, eax
    call SetConsoleTextAttribute
.hco_done:
    add rsp, 40
    pop rbx
    pop rbp
    ret

; handler_cd - Change directory with cd - support
handler_cd:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 40
    mov rbx, rcx
    test rbx, rbx
    jz .hcd_show
    cmp byte [rbx], 0
    je .hcd_show
    ; cd -
    cmp byte [rbx], '-'
    jne .hcd_change
    cmp byte [rbx + 1], 0
    jne .hcd_change
    cmp byte [has_prev_dir], 0
    je .hcd_no_prev
    mov ecx, MAX_PATH_BUF
    lea rdx, [file_path_buf]
    call GetCurrentDirectoryA
    lea rcx, [prev_dir_buf]
    call SetCurrentDirectoryA
    test eax, eax
    jz .hcd_err
    lea rcx, [prev_dir_buf]
    lea rdx, [file_path_buf]
    call str_copy
    mov ecx, MAX_PATH_BUF
    lea rdx, [path_buf]
    call GetCurrentDirectoryA
    lea rcx, [path_buf]
    call print_cstring
    call print_newline
    jmp .hcd_done
.hcd_no_prev:
    lea rcx, [err_no_prev_dir]
    mov edx, err_no_prev_len
    call print_string_len
    jmp .hcd_done
.hcd_change:
    mov ecx, MAX_PATH_BUF
    lea rdx, [prev_dir_buf]
    call GetCurrentDirectoryA
    mov byte [has_prev_dir], 1
    mov rcx, rbx
    call SetCurrentDirectoryA
    test eax, eax
    jnz .hcd_done
.hcd_err:
    lea rcx, [err_cd_msg]
    mov edx, err_cd_len
    call print_string_len
.hcd_done:
    jmp .hcd_ret
.hcd_show:
    mov ecx, MAX_PATH_BUF
    lea rdx, [path_buf]
    call GetCurrentDirectoryA
    lea rcx, [path_buf]
    call print_cstring
    call print_newline
.hcd_ret:
    add rsp, 40
    pop rbx
    pop rbp
    ret

handler_pwd:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov ecx, MAX_PATH_BUF
    lea rdx, [path_buf]
    call GetCurrentDirectoryA
    lea rcx, [path_buf]
    call print_cstring
    call print_newline
    leave
    ret

handler_whoami:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    lea rcx, [str_username]
    lea rdx, [env_var_value]
    mov r8d, 256
    call GetEnvironmentVariableA
    test eax, eax
    jz .hw_done
    lea rcx, [env_var_value]
    call print_cstring
    call print_newline
.hw_done:
    leave
    ret

; handler_dir - List directory contents
handler_dir:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 56
    lea rdi, [find_pattern]
    test rcx, rcx
    jz .hd_noargs
    cmp byte [rcx], 0
    je .hd_noargs
    mov rdx, rcx
    mov rcx, rdi
    call str_copy
    lea rcx, [find_pattern]
    call str_len
    lea rcx, [find_pattern]
    mov byte [rcx + rax], 92    ; backslash
    mov byte [rcx + rax + 1], '*'
    mov byte [rcx + rax + 2], 0
    jmp .hd_search
.hd_noargs:
    mov byte [rdi], '*'
    mov byte [rdi + 1], 0
.hd_search:
    call print_newline
    lea rcx, [dir_header]
    call print_cstring
    mov ecx, MAX_PATH_BUF
    lea rdx, [path_buf]
    call GetCurrentDirectoryA
    lea rcx, [path_buf]
    call print_cstring
    call print_newline
    call print_newline
    lea rcx, [find_pattern]
    lea rdx, [find_data]
    call FindFirstFileA
    cmp rax, INVALID_HANDLE_VALUE
    je .hd_done
    mov rbx, rax
.hd_entry:
    lea rcx, [find_data + FD_FILENAME]
    cmp byte [rcx], '.'
    jne .hd_print
    cmp byte [rcx + 1], 0
    je .hd_next
    cmp byte [rcx + 1], '.'
    jne .hd_print
    cmp byte [rcx + 2], 0
    je .hd_next
.hd_print:
    mov eax, [find_data + FD_ATTRS]
    test eax, FILE_ATTRIBUTE_DIRECTORY
    jz .hd_file
    lea rcx, [dir_tag]
    call print_cstring
    jmp .hd_name
.hd_file:
    mov eax, [find_data + FD_SIZE_LOW]
    call print_number_9pad
    lea rcx, [str_space]
    call print_cstring
.hd_name:
    lea rcx, [find_data + FD_FILENAME]
    call print_cstring
    call print_newline
.hd_next:
    mov rcx, rbx
    lea rdx, [find_data]
    call FindNextFileA
    test eax, eax
    jnz .hd_entry
    mov rcx, rbx
    call FindClose
.hd_done:
    call print_newline
    add rsp, 56
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; handler_type - Display file contents
handler_type:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 56
    test rcx, rcx
    jz .hty_noargs
    cmp byte [rcx], 0
    je .hty_noargs
    mov edx, GENERIC_READ
    mov r8d, FILE_SHARE_READ
    xor r9d, r9d
    mov dword [rsp + 32], OPEN_EXISTING
    mov dword [rsp + 40], FILE_ATTRIBUTE_NORMAL
    mov qword [rsp + 48], 0
    call CreateFileA
    cmp rax, INVALID_HANDLE_VALUE
    je .hty_err
    mov rbx, rax
.hty_read:
    mov rcx, rbx
    lea rdx, [read_buffer]
    mov r8d, READ_BUF_SIZE
    lea r9, [bytes_rw]
    mov qword [rsp + 32], 0
    call ReadFile
    test eax, eax
    jz .hty_close
    mov eax, [bytes_rw]
    test eax, eax
    jz .hty_close
    lea rcx, [read_buffer]
    mov edx, eax
    call print_string_len
    jmp .hty_read
.hty_close:
    mov rcx, rbx
    call CloseHandle
    jmp .hty_done
.hty_noargs:
    lea rcx, [err_args_msg]
    mov edx, err_args_len
    call print_string_len
    jmp .hty_done
.hty_err:
    lea rcx, [err_file_msg]
    mov edx, err_file_len
    call print_string_len
.hty_done:
    add rsp, 56
    pop rbx
    pop rbp
    ret

handler_mkdir:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    test rcx, rcx
    jz .hmk_err
    cmp byte [rcx], 0
    je .hmk_err
    xor edx, edx
    call CreateDirectoryA
    test eax, eax
    jnz .hmk_done
    call print_last_error
    jmp .hmk_done
.hmk_err:
    lea rcx, [err_args_msg]
    mov edx, err_args_len
    call print_string_len
.hmk_done:
    leave
    ret

handler_rmdir:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    test rcx, rcx
    jz .hrd_err
    cmp byte [rcx], 0
    je .hrd_err
    call RemoveDirectoryA
    test eax, eax
    jnz .hrd_done
    call print_last_error
    jmp .hrd_done
.hrd_err:
    lea rcx, [err_args_msg]
    mov edx, err_args_len
    call print_string_len
.hrd_done:
    leave
    ret

handler_del:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    test rcx, rcx
    jz .hdl_err
    cmp byte [rcx], 0
    je .hdl_err
    call DeleteFileA
    test eax, eax
    jnz .hdl_done
    call print_last_error
    jmp .hdl_done
.hdl_err:
    lea rcx, [err_args_msg]
    mov edx, err_args_len
    call print_string_len
.hdl_done:
    leave
    ret

handler_copy:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 40
    test rcx, rcx
    jz .hcp_err
    call parse_two_args
    test rax, rax
    jz .hcp_err
    test rdx, rdx
    jz .hcp_err
    mov rcx, rax
    mov r8d, 0
    call CopyFileA
    test eax, eax
    jnz .hcp_done
    call print_last_error
    jmp .hcp_done
.hcp_err:
    lea rcx, [err_args_msg]
    mov edx, err_args_len
    call print_string_len
.hcp_done:
    add rsp, 40
    pop rbx
    pop rbp
    ret

handler_move:
handler_rename:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    test rcx, rcx
    jz .hmv_err
    call parse_two_args
    test rax, rax
    jz .hmv_err
    test rdx, rdx
    jz .hmv_err
    mov rcx, rax
    call MoveFileA
    test eax, eax
    jnz .hmv_done
    call print_last_error
    jmp .hmv_done
.hmv_err:
    lea rcx, [err_args_msg]
    mov edx, err_args_len
    call print_string_len
.hmv_done:
    leave
    ret

; handler_set - View/set environment variables
handler_set:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    sub rsp, 48
    mov rbx, rcx
    test rbx, rbx
    jz .hs_list
    cmp byte [rbx], 0
    je .hs_list
    ; Find = sign
    mov rsi, rbx
.hs_find_eq:
    movzx eax, byte [rsi]
    test al, al
    jz .hs_show
    cmp al, '='
    je .hs_assign
    inc rsi
    jmp .hs_find_eq
.hs_assign:
    mov byte [rsi], 0
    inc rsi
    mov rcx, rbx
    mov rdx, rsi
    cmp byte [rsi], 0
    jne .hs_do_set
    xor edx, edx
.hs_do_set:
    call SetEnvironmentVariableA
    jmp .hs_done
.hs_show:
    mov rcx, rbx
    lea rdx, [env_var_value]
    mov r8d, 1024
    call GetEnvironmentVariableA
    test eax, eax
    jz .hs_notfound
    mov rcx, rbx
    call print_cstring
    lea rcx, [str_equals]
    call print_cstring
    lea rcx, [env_var_value]
    call print_cstring
    call print_newline
    jmp .hs_done
.hs_notfound:
    call print_last_error
    jmp .hs_done
.hs_list:
    call GetEnvironmentStringsA
    test rax, rax
    jz .hs_done
    mov rbx, rax
    mov rsi, rax
.hs_list_loop:
    cmp byte [rsi], 0
    je .hs_list_end
    mov rcx, rsi
    call print_cstring
    call print_newline
    mov rcx, rsi
    call str_len
    lea rsi, [rsi + rax + 1]
    jmp .hs_list_loop
.hs_list_end:
    mov rcx, rbx
    call FreeEnvironmentStringsA
.hs_done:
    add rsp, 48
    pop rsi
    pop rbx
    pop rbp
    ret

handler_pushd:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 40
    test rcx, rcx
    jz .hpd_err
    cmp byte [rcx], 0
    je .hpd_err
    mov rbx, rcx
    cmp dword [dir_stack_top], DIR_STACK_COUNT
    jge .hpd_full
    mov eax, [dir_stack_top]
    imul eax, MAX_PATH_BUF
    lea rdx, [dir_stack]
    add rdx, rax
    mov ecx, MAX_PATH_BUF
    call GetCurrentDirectoryA
    inc dword [dir_stack_top]
    mov rcx, rbx
    call SetCurrentDirectoryA
    test eax, eax
    jnz .hpd_done
    dec dword [dir_stack_top]
    lea rcx, [err_cd_msg]
    mov edx, err_cd_len
    call print_string_len
    jmp .hpd_done
.hpd_full:
    lea rcx, [err_stack_full]
    mov edx, err_stack_f_len
    call print_string_len
    jmp .hpd_done
.hpd_err:
    lea rcx, [err_args_msg]
    mov edx, err_args_len
    call print_string_len
.hpd_done:
    add rsp, 40
    pop rbx
    pop rbp
    ret

handler_popd:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    cmp dword [dir_stack_top], 0
    je .hpo_empty
    dec dword [dir_stack_top]
    mov eax, [dir_stack_top]
    imul eax, MAX_PATH_BUF
    lea rcx, [dir_stack]
    add rcx, rax
    call SetCurrentDirectoryA
    test eax, eax
    jnz .hpo_done
    inc dword [dir_stack_top]
    lea rcx, [err_cd_msg]
    mov edx, err_cd_len
    call print_string_len
    jmp .hpo_done
.hpo_empty:
    lea rcx, [err_stack_empty]
    mov edx, err_stack_e_len
    call print_string_len
.hpo_done:
    leave
    ret

; handler_alias - Create/list aliases
handler_alias:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    sub rsp, 48
    mov rbx, rcx
    test rbx, rbx
    jz .hal_list
    cmp byte [rbx], 0
    je .hal_list
    mov rsi, rbx
.hal_find_eq:
    movzx eax, byte [rsi]
    test al, al
    jz .hal_list
    cmp al, '='
    je .hal_set
    inc rsi
    jmp .hal_find_eq
.hal_set:
    mov byte [rsi], 0
    inc rsi
    cmp dword [alias_count], ALIAS_COUNT
    jge .hal_full
    ; Check if alias already exists, update it
    push rsi
    lea r8, [alias_table]
    xor ecx, ecx
.hal_find:
    cmp ecx, [alias_count]
    jge .hal_add_new
    push rcx
    push r8
    mov rcx, rbx
    mov rdx, r8
    call str_icompare
    pop r8
    pop rcx
    test eax, eax
    jz .hal_update
    add r8, ALIAS_ENTRY_SIZE
    inc ecx
    jmp .hal_find
.hal_update:
    pop rsi
    lea rcx, [r8 + ALIAS_NAME_SIZE]
    mov rdx, rsi
    call str_copy
    jmp .hal_done
.hal_add_new:
    pop rsi
    mov eax, [alias_count]
    imul eax, ALIAS_ENTRY_SIZE
    lea rcx, [alias_table]
    add rcx, rax
    mov rdx, rbx
    call str_copy
    mov eax, [alias_count]
    imul eax, ALIAS_ENTRY_SIZE
    lea rcx, [alias_table]
    add rcx, rax
    add rcx, ALIAS_NAME_SIZE
    mov rdx, rsi
    call str_copy
    inc dword [alias_count]
    jmp .hal_done
.hal_list:
    mov ecx, [alias_count]
    test ecx, ecx
    jz .hal_done
    lea rsi, [alias_table]
    xor ebx, ebx
.hal_list_loop:
    cmp ebx, [alias_count]
    jge .hal_done
    mov rcx, rsi
    call print_cstring
    lea rcx, [str_equals]
    call print_cstring
    lea rcx, [rsi + ALIAS_NAME_SIZE]
    call print_cstring
    call print_newline
    add rsi, ALIAS_ENTRY_SIZE
    inc ebx
    jmp .hal_list_loop
.hal_full:
    lea rcx, [err_alias_full]
    mov edx, err_alias_f_len
    call print_string_len
.hal_done:
    add rsp, 48
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================================
; execute_external - Run command via cmd.exe /c with redirection support
; ============================================================================
execute_external:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    push rdi
    sub rsp, 120
    ; Build "cmd.exe /c <input>"
    lea rdi, [cmd_line_buf]
    lea rsi, [cmd_prefix]
.ee_pre:
    lodsb
    test al, al
    jz .ee_inp
    stosb
    jmp .ee_pre
.ee_inp:
    lea rsi, [input_buf]
.ee_inp_loop:
    lodsb
    stosb
    test al, al
    jnz .ee_inp_loop
    ; Zero STARTUPINFO
    lea rdi, [startup_info]
    mov ecx, 104
    xor al, al
    rep stosb
    mov dword [startup_info], 104
    ; Setup redirection handles
    cmp byte [redir_stdout_active], 0
    jne .ee_redir
    cmp byte [redir_stdin_active], 0
    jne .ee_redir
    jmp .ee_no_redir
.ee_redir:
    mov dword [startup_info + SI_FLAGS], STARTF_USESTDHANDLES
    mov rax, [hStdIn]
    mov [startup_info + SI_STDIN], rax
    mov rax, [hStdOut]
    mov [startup_info + SI_STDOUT], rax
    mov [startup_info + SI_STDERR], rax
    cmp byte [redir_stdout_active], 0
    je .ee_check_in
    mov rax, [redir_stdout_handle]
    mov [startup_info + SI_STDOUT], rax
.ee_check_in:
    cmp byte [redir_stdin_active], 0
    je .ee_no_redir
    mov rax, [redir_stdin_handle]
    mov [startup_info + SI_STDIN], rax
.ee_no_redir:
    ; Zero PROCESS_INFORMATION
    lea rdi, [proc_info]
    mov ecx, 24
    xor al, al
    rep stosb
    ; CreateProcessA
    xor ecx, ecx
    lea rdx, [cmd_line_buf]
    xor r8d, r8d
    xor r9d, r9d
    ; bInheritHandles
    cmp byte [redir_stdout_active], 0
    jne .ee_inherit
    cmp byte [redir_stdin_active], 0
    jne .ee_inherit
    mov dword [rsp + 32], 0
    jmp .ee_create
.ee_inherit:
    mov dword [rsp + 32], 1
.ee_create:
    mov dword [rsp + 40], 0
    mov qword [rsp + 48], 0
    mov qword [rsp + 56], 0
    lea rax, [startup_info]
    mov [rsp + 64], rax
    lea rax, [proc_info]
    mov [rsp + 72], rax
    call CreateProcessA
    test eax, eax
    jz .ee_error
    mov rcx, [proc_info]
    mov edx, INFINITE
    call WaitForSingleObject
    mov rcx, [proc_info]
    call CloseHandle
    mov rcx, [proc_info + 8]
    call CloseHandle
    jmp .ee_done
.ee_error:
    lea rcx, [err_exec_msg]
    mov edx, err_exec_len
    call print_string_len
.ee_done:
    add rsp, 120
    pop rdi
    pop rsi
    pop rbx
    pop rbp
    ret

; ============================================================================
; Utility Functions
; ============================================================================

; print_string_len - Print string with redirection support
; rcx = string, edx = length
print_string_len:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    cmp byte [redir_stdout_active], 0
    jne .psl_file
    mov r8d, edx
    mov rdx, rcx
    mov rcx, [hStdOut]
    lea r9, [chars_written]
    mov qword [rsp + 32], 0
    call WriteConsoleA
    jmp .psl_done
.psl_file:
    mov r8d, edx
    mov rdx, rcx
    mov rcx, [redir_stdout_handle]
    lea r9, [chars_written]
    mov qword [rsp + 32], 0
    call WriteFile
.psl_done:
    leave
    ret

; print_cstring - Print null-terminated string
print_cstring:
    push rbp
    mov rbp, rsp
    mov rax, rcx
    xor edx, edx
.pc_len:
    cmp byte [rax + rdx], 0
    je .pc_done
    inc edx
    jmp .pc_len
.pc_done:
    leave
    jmp print_string_len

; print_newline
print_newline:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    lea rcx, [newline]
    mov edx, 2
    call print_string_len
    leave
    ret

; str_icompare - Case insensitive full string compare
; rcx = str1, rdx = str2, Returns: eax = 0 if equal
str_icompare:
.sic_loop:
    movzx eax, byte [rcx]
    movzx r8d, byte [rdx]
    cmp al, 'A'
    jb .sic_s1
    cmp al, 'Z'
    ja .sic_s1
    add al, 32
.sic_s1:
    cmp r8b, 'A'
    jb .sic_s2
    cmp r8b, 'Z'
    ja .sic_s2
    add r8b, 32
.sic_s2:
    cmp al, r8b
    jne .sic_neq
    test al, al
    jz .sic_eq
    inc rcx
    inc rdx
    jmp .sic_loop
.sic_eq:
    xor eax, eax
    ret
.sic_neq:
    mov eax, 1
    ret

; str_icompare_n - Case insensitive compare first N chars
; rcx = str1, rdx = str2, r8d = n, Returns: eax = 0 if equal
str_icompare_n:
.sicn_loop:
    test r8d, r8d
    jz .sicn_eq
    movzx eax, byte [rcx]
    movzx r9d, byte [rdx]
    cmp al, 'A'
    jb .sicn_s1
    cmp al, 'Z'
    ja .sicn_s1
    add al, 32
.sicn_s1:
    cmp r9b, 'A'
    jb .sicn_s2
    cmp r9b, 'Z'
    ja .sicn_s2
    add r9b, 32
.sicn_s2:
    cmp al, r9b
    jne .sicn_neq
    inc rcx
    inc rdx
    dec r8d
    jmp .sicn_loop
.sicn_eq:
    xor eax, eax
    ret
.sicn_neq:
    mov eax, 1
    ret

; hex_to_int - Convert hex char in al to 0-15
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

; print_number - Print integer in eax as decimal
print_number:
    push rbp
    mov rbp, rsp
    push rbx
    push rdi
    sub rsp, 32
    lea rdi, [num_buf + 15]
    mov byte [rdi], 0
    mov ebx, 10
    test eax, eax
    jnz .pn_loop
    dec rdi
    mov byte [rdi], '0'
    jmp .pn_print
.pn_loop:
    test eax, eax
    jz .pn_print
    xor edx, edx
    div ebx
    add dl, '0'
    dec rdi
    mov [rdi], dl
    jmp .pn_loop
.pn_print:
    mov rcx, rdi
    call print_cstring
    add rsp, 32
    pop rdi
    pop rbx
    pop rbp
    ret

; print_number_2digit - Print eax as 2-digit decimal with leading zero
print_number_2digit:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 40
    mov ebx, 10
    xor edx, edx
    div ebx
    add al, '0'
    lea rcx, [num_buf]
    mov [rcx], al
    add dl, '0'
    mov [rcx + 1], dl
    mov byte [rcx + 2], 0
    call print_cstring
    add rsp, 40
    pop rbx
    pop rbp
    ret

; print_number_9pad - Print eax right-aligned in 9-char field
print_number_9pad:
    push rbp
    mov rbp, rsp
    push rbx
    push rdi
    sub rsp, 32
    lea rdi, [num_buf]
    ; Fill with spaces
    mov ecx, 9
.np9_fill:
    mov byte [rdi + rcx - 1], ' '
    dec ecx
    jnz .np9_fill
    mov byte [rdi + 9], 0
    ; Convert right to left
    lea rdi, [num_buf + 8]
    mov ebx, 10
    test eax, eax
    jnz .np9_loop
    mov byte [rdi], '0'
    jmp .np9_print
.np9_loop:
    test eax, eax
    jz .np9_print
    xor edx, edx
    div ebx
    add dl, '0'
    mov [rdi], dl
    dec rdi
    jmp .np9_loop
.np9_print:
    lea rcx, [num_buf]
    call print_cstring
    add rsp, 32
    pop rdi
    pop rbx
    pop rbp
    ret

; clear_screen
clear_screen:
    push rbp
    mov rbp, rsp
    push rbx
    sub rsp, 56
    mov rcx, [hStdOut]
    lea rdx, [csbi]
    call GetConsoleScreenBufferInfo
    movzx eax, word [csbi]
    movzx ecx, word [csbi + 2]
    imul eax, ecx
    mov ebx, eax
    mov rcx, [hStdOut]
    mov edx, ' '
    mov r8d, ebx
    xor r9d, r9d
    lea rax, [chars_written]
    mov [rsp + 32], rax
    call FillConsoleOutputCharacterA
    mov rcx, [hStdOut]
    movzx edx, word [csbi + 8]
    mov r8d, ebx
    xor r9d, r9d
    lea rax, [chars_written]
    mov [rsp + 32], rax
    call FillConsoleOutputAttribute
    mov rcx, [hStdOut]
    xor edx, edx
    call SetConsoleCursorPosition
    add rsp, 56
    pop rbx
    pop rbp
    ret

; str_copy - Copy null-terminated string, rcx = dest, rdx = src
str_copy:
    mov rax, rcx
.sc_loop:
    mov r8b, [rdx]
    mov [rcx], r8b
    test r8b, r8b
    jz .sc_done
    inc rcx
    inc rdx
    jmp .sc_loop
.sc_done:
    ret

; str_len - Get string length, rcx = string, Returns: eax
str_len:
    xor eax, eax
.sl_loop:
    cmp byte [rcx + rax], 0
    je .sl_done
    inc eax
    jmp .sl_loop
.sl_done:
    ret

; skip_spaces - Skip leading spaces, rcx = string, Returns: rax
skip_spaces:
.ss_loop:
    cmp byte [rcx], ' '
    jne .ss_done
    inc rcx
    jmp .ss_loop
.ss_done:
    mov rax, rcx
    ret

; parse_two_args - Split string at first space (modifies string in-place)
; rcx = input, Returns: rax = arg1, rdx = arg2 (or both NULL)
parse_two_args:
    mov rax, rcx
    test rax, rax
    jz .pta_fail
.pta_find:
    cmp byte [rcx], 0
    je .pta_fail
    cmp byte [rcx], ' '
    je .pta_split
    inc rcx
    jmp .pta_find
.pta_split:
    mov byte [rcx], 0
    inc rcx
.pta_skip:
    cmp byte [rcx], ' '
    jne .pta_check
    inc rcx
    jmp .pta_skip
.pta_check:
    cmp byte [rcx], 0
    je .pta_fail
    mov rdx, rcx
    ret
.pta_fail:
    xor eax, eax
    xor edx, edx
    ret

; print_last_error - Print descriptive error from GetLastError + FormatMessageA
print_last_error:
    push rbp
    mov rbp, rsp
    sub rsp, 64
    call GetLastError
    test eax, eax
    jz .ple_done
    mov ecx, FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS
    xor edx, edx
    mov r8d, eax
    xor r9d, r9d
    lea rax, [err_msg_buf]
    mov [rsp + 32], rax
    mov dword [rsp + 40], 512
    mov qword [rsp + 48], 0
    call FormatMessageA
    test eax, eax
    jz .ple_done
    lea rcx, [err_msg_buf]
    mov edx, eax
    call print_string_len
.ple_done:
    leave
    ret

; run_autoexec - Execute autoexec.txt from program directory if it exists
run_autoexec:
    push rbp
    mov rbp, rsp
    push rbx
    push rsi
    sub rsp, 64
    ; Get module path
    xor ecx, ecx
    lea rdx, [module_path]
    mov r8d, MAX_PATH_BUF
    call GetModuleFileNameA
    ; Strip filename
    lea rcx, [module_path]
    call str_len
    lea rcx, [module_path]
.ra_strip:
    dec eax
    cmp eax, 0
    jl .ra_done
    cmp byte [rcx + rax], 92   ; backslash
    je .ra_found
    cmp byte [rcx + rax], '/'
    je .ra_found
    jmp .ra_strip
.ra_found:
    ; Append \autoexec.txt
    lea rdx, [rcx + rax]
    lea rsi, [autoexec_name]
.ra_app:
    mov bl, [rsi]
    mov [rdx], bl
    test bl, bl
    jz .ra_try_open
    inc rdx
    inc rsi
    jmp .ra_app
.ra_try_open:
    ; Try to open
    lea rcx, [module_path]
    mov edx, GENERIC_READ
    mov r8d, FILE_SHARE_READ
    xor r9d, r9d
    mov dword [rsp + 32], OPEN_EXISTING
    mov dword [rsp + 40], FILE_ATTRIBUTE_NORMAL
    mov qword [rsp + 48], 0
    call CreateFileA
    cmp rax, INVALID_HANDLE_VALUE
    je .ra_done
    mov rbx, rax
    ; Read entire file
    mov rcx, rbx
    lea rdx, [read_buffer]
    mov r8d, READ_BUF_SIZE - 1
    lea r9, [bytes_rw]
    mov qword [rsp + 32], 0
    call ReadFile
    mov rcx, rbx
    call CloseHandle
    ; Null-terminate
    mov eax, [bytes_rw]
    lea rcx, [read_buffer]
    mov byte [rcx + rax], 0
    ; Process line by line
    lea rsi, [read_buffer]
.ra_line:
    cmp byte [rsi], 0
    je .ra_done
    ; Copy line to input_buf
    lea rdi, [input_buf]
    xor ecx, ecx
.ra_cpy:
    movzx eax, byte [rsi]
    cmp al, 0
    je .ra_exec
    cmp al, 13
    je .ra_skip_cr
    cmp al, 10
    je .ra_exec
    mov [rdi + rcx], al
    inc ecx
    inc rsi
    jmp .ra_cpy
.ra_skip_cr:
    inc rsi
    jmp .ra_cpy
.ra_exec:
    cmp byte [rsi], 10
    jne .ra_no_lf
    inc rsi
.ra_no_lf:
    mov byte [rdi + rcx], 0
    test ecx, ecx
    jz .ra_line
    call dispatch_command
    jmp .ra_line
.ra_done:
    add rsp, 64
    pop rsi
    pop rbx
    pop rbp
    ret

; autoexec filename
section .data
    autoexec_name   db "\autoexec.txt", 0
