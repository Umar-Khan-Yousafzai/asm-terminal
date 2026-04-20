# ============================================================================
# ASM Terminal v2.0 - Linux Build
# Requires: nasm, ld (binutils)
# Usage: make          - build terminal
#        make clean    - remove build artifacts
# ============================================================================

NASM    = nasm
LD      = ld

TARGET  = terminal
SRC     = terminal_linux.asm
OBJ     = terminal_linux.o

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(OBJ)
	$(LD) $(OBJ) -o $(TARGET) -e _start

$(OBJ): $(SRC)
	$(NASM) -f elf64 $(SRC) -o $(OBJ)

clean:
	rm -f $(OBJ) $(TARGET)
