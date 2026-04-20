# ============================================================================
# ASM Terminal v2.0 — Linux Build
# Requires: nasm, ld (binutils)
#
# Targets:
#   make          - build terminal
#   make clean    - remove build artifacts
#   make install  - install terminal as 'asm' into PREFIX/bin (default ~/.local)
#   make uninstall- remove the installed 'asm'
#   make test     - build then run smoke test harness
#   make dist     - produce tarball in dist/ for release
#   make size     - show binary size + symbol count
# ============================================================================

NASM    ?= nasm
LD      ?= ld

TARGET  = terminal
SRC     = terminal_linux.asm
OBJ     = terminal_linux.o

PREFIX  ?= $(HOME)/.local
BINDIR  ?= $(PREFIX)/bin
INSTALL_NAME ?= asm

VERSION ?= 2.0.0
DIST_NAME = asm-terminal-$(VERSION)-linux-x86_64

.PHONY: all clean install uninstall test dist size

all: $(TARGET)

$(TARGET): $(OBJ)
	$(LD) $(OBJ) -o $(TARGET) -e _start

$(OBJ): $(SRC)
	$(NASM) -f elf64 $(SRC) -o $(OBJ)

clean:
	rm -f $(OBJ) $(TARGET)
	rm -rf dist

install: $(TARGET)
	install -d "$(BINDIR)"
	install -m 0755 "$(TARGET)" "$(BINDIR)/$(INSTALL_NAME)"
	@echo "Installed $(BINDIR)/$(INSTALL_NAME)"
	@echo "Ensure $(BINDIR) is on your PATH to run with: $(INSTALL_NAME)"

uninstall:
	rm -f "$(BINDIR)/$(INSTALL_NAME)"
	@echo "Removed $(BINDIR)/$(INSTALL_NAME)"

test: $(TARGET)
	bash tests/run_tests.sh

size: $(TARGET)
	@ls -la $(TARGET) | awk '{print "size: " $$5 " bytes"}'
	@readelf -h $(TARGET) | grep 'Type\|Machine\|Entry'
	@nm $(TARGET) 2>/dev/null | wc -l | awk '{print "symbol count: " $$1}'

dist: $(TARGET)
	mkdir -p dist/$(DIST_NAME)
	cp $(TARGET) dist/$(DIST_NAME)/
	cp README.md dist/$(DIST_NAME)/ 2>/dev/null || true
	cp LICENSE dist/$(DIST_NAME)/ 2>/dev/null || true
	tar -C dist -czf dist/$(DIST_NAME).tar.gz $(DIST_NAME)
	@sha256sum dist/$(DIST_NAME).tar.gz
