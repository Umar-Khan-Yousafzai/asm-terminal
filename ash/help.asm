; ============================================================================
; ash/help.asm - `help` as a table: Command | Usage | Example
;
; Rows live in hp_table. Each row can carry several examples; one is picked
; at random each time `help` runs. Colors follow the Dark+ palette used by
; the line editor (ash/highlight.asm): commands teal, commands that destroy
; data red, examples orange, section names purple. Colors are dropped when
; output is redirected or color is off. On terminals narrower than
; HP_WIDE_COLS the example moves to its own line under the command.
; ============================================================================

%define HP_CMD_W        23              ; Command column width
%define HP_USE_W        34              ; Usage column width
%define HP_WIDE_COLS    95              ; narrower than this: stacked layout

; HSEC "NAME"                      section heading
; HROW "cmd", "usage", "ex1", ...  row with zero or more examples
%macro HSEC 1
    db 1, %1, 0
%endmacro
%macro HROW 2-*
    db 2
    %rep %0
        db %1, 0
        %rotate 1
    %endrep
    db 0
%endmacro

section .data
    hp_c_section    db 27, "[1;38;2;197;134;192m", 0
    hp_c_example    db 27, "[38;2;206;145;120m", 0
    hp_c_bold       db 27, "[1m", 0
    hp_reset        db 27, "[0m", 0
    hp_title_pre    db 10, "  ", 0
    hp_title_post   db " v", ASM_VERSION, " - Command Reference", 10, 0
    hp_title_name   db "ASM Terminal", 0
    hp_h_cmd        db "Command", 0
    hp_h_use        db "Usage", 0
    hp_h_ex         db "Example", 0
    hp_bar          db " ", 0xE2, 0x94, 0x82, " ", 0          ; " | "
    hp_rule         db "  "
                    times HP_CMD_W + 1 db 0xE2, 0x94, 0x80
                    db 0xE2, 0x94, 0xBC
                    times HP_USE_W + 2 db 0xE2, 0x94, 0x80
                    db 0xE2, 0x94, 0xBC
                    times 32 db 0xE2, 0x94, 0x80
                    db 10, 0
    hp_indent       db "  ", 0
    hp_eg           db "      e.g. ", 0
    hp_footer       db 10, "  ~/.asmrc runs at startup. History is kept in ~/.asm_history.", 10
                    db "  Command colors: teal = ready, blue = help, gray = unknown, red = destroys data.", 10, 10, 0
    hp_spaces       times 64 db ' '

hp_table:
    HSEC "NAVIGATION"
    HROW "cd [path]",            "Change directory (alone: $HOME)", "cd /home", "cd ..", "cd -"
    HROW "pwd",                  "Print working directory",        "pwd"
    HROW "pushd <path>",         "Save current dir then cd",       "pushd /tmp", "pushd ~/projects"
    HROW "popd",                 "Go back to the saved dir",       "popd"

    HSEC "FILES"
    HROW "ls [-la] [dir]",       "List files (colored)",           "ls -la", "ls -a /tmp", "ls -l"
    HROW "dir [path]",           "List directory (classic look)",  "dir", "dir /home"
    HROW "cat <file>",           "Show file contents",             "cat README.md", "cat /etc/hostname"
    HROW "type <file>",          "Same as cat",                    "type config.txt"
    HROW "copy [-f] <src> <dst>", "Copy a file (undo-able)",        "copy file.txt backup.txt", "copy a.conf a.conf.bak"
    HROW "move [-f] <src> <dst>", "Move a file (undo-able)",        "move old.txt new.txt"
    HROW "rename <src> <dst>",   "Rename a file",                  "rename data.csv old.csv"
    HROW "del [-f] <file>",      "Delete (kept in ~/.asm_trash)",  "del temp.log", "del build.o"
    HROW "trash [empty]",        "List the trash, or empty it",    "trash"
    HROW "undo",                 "Reverse last del/move/copy",     "undo"
    HROW "mkdir <dir>",          "Create a directory",             "mkdir projects", "mkdir -p a/b/c"
    HROW "rmdir <dir>",          "Remove an empty directory",      "rmdir old_folder"
    HROW "grep <pat> <file>",    "Search a file for text",         "grep TODO main.c", "grep error log.txt"

    HSEC "ENVIRONMENT"
    HROW "set",                  "List all variables",             "set"
    HROW "set <var>",            "Show one variable",              "set HOME", "set PATH"
    HROW "set <var>=<val>",      "Set a variable",                 "set EDITOR=vim", "set LANG=C"
    HROW "export <var>=<val>",   "Same as set <var>=<val>",        "export EDITOR=nano"
    HROW "unset <var>",          "Remove a variable",              "unset EDITOR"
    HROW "NAME=value",           "Set a variable (sh style)",      "n=5", "name=Umer"
    HROW "whoami",               "Current username",               "whoami"

    HSEC "DISPLAY"
    HROW "echo <text>",          "Print text ($VAR expanded)",     "echo Hello World!", "echo $HOME", "echo $((6*7))"
    HROW "cls / clear",          "Clear the screen",               "cls", "clear"
    HROW "color <hex>",          "Text color (Windows style)",     "color 0A", "color 0F", "color 0B"
    HROW "title <text>",         "Set the window title",           "title My Shell"
    HROW "theme [name]",         "default / minimal / classic",    "theme minimal", "theme classic", "theme"

    HSEC "SYSTEM"
    HROW "ver",                  "Version info",                   "ver"
    HROW "about",                "About ASM Terminal",             "about"
    HROW "update [install]",     "Check for or install updates",   "update", "update install"
    HROW "date / time",          "Date and time (ASM_TZ or TZ)",          "date", "time"
    HROW "uptime",               "Time since boot",                "uptime"
    HROW "free",                 "Memory usage",                   "free"
    HROW "calc <expr>",          "Integer math, left to right",    "calc 10 + 5 * 2", "calc 100 / 3", "calc 6 * 7"
    HROW "source <file>",        "Run commands from a file",       "source setup.sh", "source ~/.asmrc"
    HROW "which <name>",         "Builtin / alias / program?",     "which ls", "which git"
    HROW "history [-c | .]",     "History (. = run in this folder)", "history", "history ."
    HROW "kill [-SIG] <id>",     "Signal a PID or %job",           "kill %1", "kill -9 1234", "kill -TERM 4321"
    HROW "true / false",         "Set status 0 / 1",               "false || echo failed"
    HROW "help",                 "This table",                     "help"
    HROW "exit [N]",             "Exit (with status N)",           "exit", "exit 1"

    HSEC "TOOLS"
    HROW "bench [-n N] <cmd>",   "Time a command over N runs",     "bench -n 20 ls -la", "bench sleep 0.1"
    HROW "trace [-a] <cmd>",     "Files/programs/net a cmd uses",  "trace cp a.txt /tmp/", "trace -a ls"
    HROW "sandbox [opts] <cmd>",  "No sockets; writes only in /tmp", "sandbox ./install.sh", "sandbox -w make", "sandbox"
    HROW "alias <n>=<cmd>",      "Create an alias (alone: list)",  "alias ll=ls -la", "alias gs=git status"
    HROW "unalias <name>",       "Remove an alias",                "unalias ll"

    HSEC "JOBS"
    HROW "<cmd> &",              "Run in the background",          "sleep 10 &"
    HROW "jobs",                 "List background jobs",           "jobs"
    HROW "fg [n]",               "Bring a job to the foreground",  "fg", "fg 1"
    HROW "bg [n]",               "Resume a stopped job in background", "bg", "bg 1"

    HSEC "SHELL"
    HROW "a ; b",                "Run one after another",          "echo hi ; echo bye"
    HROW "a && b",               "Run b if a succeeded",           "mkdir d && cd d"
    HROW "a || b",               "Run b if a failed",              "cd /x || echo no such dir"
    HROW "a | b",                "Pipe output into b",             "ls | grep .asm", "ls | wc -l"
    HROW "> >> <",               "Write / append / read a file",   "ls > files.txt", "echo log >> out.txt"
    HROW "$? $$ $((...))",       "Status / PID / arithmetic",      "echo $?", "echo $((1+2))"

    HSEC "SCRIPTING (ASH)"
    HROW "if / elif / else / fi", "Run code on a condition",       "if [ -f a ]; then cat a; fi"
    HROW "while / until",        "Loop while / until true",        "while true; do break; done"
    HROW "for x in ...",         "Loop over words",                "for f in a b; do echo $f; done"
    HROW "name() { ... }",       "Define a function ($1 $# $@)",   "hi() { echo hi $1; }"
    HROW "test / [ ... ]",       "-f -d -e -z -n = -eq -lt -gt",   "[ -d /tmp ] && echo yes"
    HROW "break / continue",     "Leave or skip a loop turn",      "break", "continue"

    HSEC "KEYS"
    HROW "Tab",                  "Complete file names (lists all)", "cat REA<Tab>"
    HROW "Right / End",          "Accept the grey suggestion"
    HROW "Up / Down",            "Browse history"
    HROW "Ctrl+R",               "Search history"
    HROW "Ctrl+L",               "Clear the screen"
    HROW "Ctrl+W / Ctrl+U",      "Delete word / line"
    HROW "Ctrl+C",               "Cancel input or stop a command"
    HROW "Ctrl+Z",               "Pause a command (then fg / bg)"
    db 0

section .text

; ----------------------------------------------------------------------------
; handler_help - print hp_table
; r15 = 1 when colors are on, r14 = 1 for the three-column layout
; ----------------------------------------------------------------------------
handler_help:
    push rbp
    mov rbp, rsp
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8

    xor r15d, r15d
    cmp byte [color_enabled], 0
    je .color_set
    cmp byte [redir_stdout_active], 0
    jne .color_set
    mov r15d, 1
.color_set:

    mov word [term_cols], 0
    call update_term_size
    movzx eax, word [term_cols]
    test eax, eax
    jnz .have_cols
    mov eax, 100                        ; not a terminal: assume wide
.have_cols:
    xor r14d, r14d
    cmp eax, HP_WIDE_COLS
    jb .layout_set
    mov r14d, 1
.layout_set:

    ; title
    lea rdi, [hp_title_pre]
    call print_cstring
    lea rdi, [hp_c_bold]
    call .color
    lea rdi, [hp_title_name]
    call print_cstring
    call .reset
    lea rdi, [hp_title_post]
    call print_cstring

    ; header row + rule (wide layout only)
    test r14d, r14d
    jz .rows
    call print_newline
    lea rdi, [hp_indent]
    call print_cstring
    lea rdi, [hp_c_bold]
    call .color
    lea rdi, [hp_h_cmd]
    mov esi, HP_CMD_W
    call .padded
    lea rdi, [hp_bar]
    call print_cstring
    lea rdi, [hp_h_use]
    mov esi, HP_USE_W
    call .padded
    lea rdi, [hp_bar]
    call print_cstring
    lea rdi, [hp_h_ex]
    call print_cstring
    call .reset
    call print_newline
    lea rdi, [hl_c_unknown]
    call .color
    lea rdi, [hp_rule]
    call print_cstring
    call .reset

.rows:
    lea rbx, [hp_table]
.next:
    movzx eax, byte [rbx]
    test eax, eax
    jz .footer
    inc rbx
    cmp eax, 1
    jne .row

    ; section heading
    call print_newline
    lea rdi, [hp_indent]
    call print_cstring
    lea rdi, [hp_c_section]
    call .color
    mov rdi, rbx
    call print_cstring
    call .reset
    call print_newline
    mov rdi, rbx
    call .skip_str
    mov rbx, rax
    jmp .next

.row:
    mov r12, rbx                        ; command
    mov rdi, rbx
    call .skip_str
    mov r13, rax                        ; usage
    mov rdi, rax
    call .skip_str
    mov rbx, rax                        ; first example (or "" = none)

    ; count examples and pick one at random
    xor ecx, ecx
    mov rdi, rbx
.count:
    cmp byte [rdi], 0
    je .counted
    inc ecx
    push rcx
    call .skip_str
    pop rcx
    mov rdi, rax
    jmp .count
.counted:
    lea rax, [rdi + 1]                  ; past the closing ""
    mov [rbp - 48], rax                 ; next row
    xor edx, edx
    test ecx, ecx
    jz .no_example
    mov r8d, ecx
    rdtsc
    xor edx, edx
    div r8d                             ; edx = random index
.no_example:
    mov rdi, rbx                        ; walk to example #edx
.walk:
    test edx, edx
    jz .walked
    push rdx
    call .skip_str
    pop rdx
    mov rdi, rax
    dec edx
    jmp .walk
.walked:
    mov rbx, rdi                        ; rbx = example ("" if none)

    ; command column: red when the command destroys data
    lea rdi, [hp_indent]
    call print_cstring
    call .first_word_to_hl_word
    lea rdi, [hl_word]
    lea rsi, [hl_danger_words]
    call hl_word_in_list
    lea rdi, [hl_c_ok]
    test eax, eax
    jz .cmd_color
    lea rdi, [hl_c_danger]
.cmd_color:
    call .color
    test r14d, r14d
    jnz .cmd_pad
    mov rdi, r12
    call print_cstring
    call .reset
    mov rdi, r12
    call str_len
    mov esi, HP_CMD_W
    sub esi, eax
    jg .cmd_gap
    mov esi, 1
.cmd_gap:
    lea rdi, [hp_spaces]
    call print_string_len
    lea rdi, [hp_spaces]
    mov esi, 1
    call print_string_len
    mov rdi, r13
    call print_cstring
    call print_newline
    cmp byte [rbx], 0
    je .row_done
    lea rdi, [hp_eg]
    call print_cstring
    lea rdi, [hp_c_example]
    call .color
    mov rdi, rbx
    call print_cstring
    call .reset
    call print_newline
    jmp .row_done

.cmd_pad:
    ; wide: Command | Usage | Example
    mov rdi, r12
    call print_cstring                  ; command text (colored)
    call .reset
    mov rdi, r12
    call str_len
    mov esi, HP_CMD_W
    sub esi, eax
    jle .cmd_padded
    lea rdi, [hp_spaces]
    call print_string_len
.cmd_padded:
    call .bar
    mov rdi, r13
    mov esi, HP_USE_W
    call .padded
    call .bar
    lea rdi, [hp_c_example]
    call .color
    mov rdi, rbx
    call print_cstring
    call .reset
    call print_newline

.row_done:
    mov rbx, [rbp - 48]                 ; next row
    jmp .next

.footer:
    lea rdi, [hp_footer]
    call print_cstring

    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; --- local helpers: called from 16-byte aligned code, so they sub 8 ---

; .color(rdi=escape) - print it only when colors are on
.color:
    test r15d, r15d
    jz .c_ret
    sub rsp, 8
    call print_cstring
    add rsp, 8
.c_ret:
    ret

.reset:
    test r15d, r15d
    jz .r_ret
    sub rsp, 8
    lea rdi, [hp_reset]
    call print_cstring
    add rsp, 8
.r_ret:
    ret

; .bar - print the gray column separator
.bar:
    sub rsp, 8
    lea rdi, [hl_c_unknown]
    call .color
    lea rdi, [hp_bar]
    call print_cstring
    call .reset
    add rsp, 8
    ret

; .padded(rdi=str, esi=width) - print str then spaces up to width
.padded:
    push rdi
    push rsi
    sub rsp, 8
    call print_cstring
    mov rdi, [rsp + 16]
    call str_len
    mov esi, [rsp + 8]
    sub esi, eax
    jle .p_done
    lea rdi, [hp_spaces]
    call print_string_len
.p_done:
    add rsp, 24
    ret

; .skip_str(rdi) -> rax = byte after the NUL
.skip_str:
    mov rax, rdi
.ss_loop:
    inc rax
    cmp byte [rax - 1], 0
    jne .ss_loop
    ret

; .first_word_to_hl_word - copy r12's first word into hl_word
.first_word_to_hl_word:
    xor ecx, ecx
.fw_loop:
    mov al, [r12 + rcx]
    test al, al
    jz .fw_done
    cmp al, ' '
    je .fw_done
    cmp ecx, 120
    jae .fw_done
    mov [hl_word + rcx], al
    inc ecx
    jmp .fw_loop
.fw_done:
    mov byte [hl_word + rcx], 0
    ret
