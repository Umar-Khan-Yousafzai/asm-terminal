# ============================================================================
# ASM Terminal v2.0 — Linux Build
# Requires: nasm, ld (binutils)
#
# Build targets:
#   make                 - build terminal binary
#   make clean           - remove build artifacts
#
# Install:
#   make install         - install as <PREFIX>/bin/asm  (default ~/.local)
#   make install-desktop - install binary + launcher + .desktop + icon (Linux app menu)
#   make install-gui     - run the zenity installer for interactive install
#   make uninstall       - reverse install-desktop
#
# Packaging:
#   make deb             - build a .deb package in dist/
#   make appimage        - build an AppImage in repo root
#   make zip-windows     - bundle terminal.exe + install.bat for Windows release
#   make dist            - tarball + README + LICENSE
#   make release         - build all (deb, appimage, tarball, windows zip)
#
# Test / introspect:
#   make test            - run tests/run_tests.sh
#   make size            - print binary size + ELF header + symbol count
# ============================================================================

NASM    ?= nasm
LD      ?= ld

TARGET  = terminal
SRC     = terminal_linux.asm
OBJ     = terminal_linux.o

PREFIX        ?= $(HOME)/.local
BINDIR        ?= $(PREFIX)/bin
SHAREDIR      ?= $(PREFIX)/share
APPDIR        ?= $(SHAREDIR)/applications
ICONDIR       ?= $(SHAREDIR)/icons/hicolor/scalable/apps
INSTALL_NAME  ?= asm

VERSION   ?= 2.0.0
DIST_NAME  = asm-terminal-$(VERSION)-linux-x86_64
WIN_DIST   = asm-terminal-$(VERSION)-windows-x86_64

.PHONY: all clean install install-desktop install-gui uninstall \
        test size dist deb appimage zip-windows release

all: $(TARGET)

$(TARGET): $(OBJ)
	$(LD) $(OBJ) -o $(TARGET) -e _start

$(OBJ): $(SRC)
	$(NASM) -f elf64 $(SRC) -o $(OBJ)

clean:
	rm -f $(OBJ) $(TARGET)
	rm -rf dist packaging/appimage/AppDir packaging/appimage/_tools \
	       packaging/debian/_stage asm-terminal-*.AppImage

# ----------------------------------------------------------------------------
# Install (binary only)
# ----------------------------------------------------------------------------

install: $(TARGET)
	install -d "$(BINDIR)"
	install -m 0755 "$(TARGET)" "$(BINDIR)/$(INSTALL_NAME)"
	@echo "Installed $(BINDIR)/$(INSTALL_NAME)"

# ----------------------------------------------------------------------------
# Install with .desktop entry + icon + launcher wrapper (recognizable app)
# ----------------------------------------------------------------------------

install-desktop: $(TARGET)
	install -d "$(BINDIR)" "$(APPDIR)" "$(ICONDIR)"
	install -m 0755 "$(TARGET)"                                  "$(BINDIR)/$(INSTALL_NAME)"
	install -m 0755 packaging/linux/asm-terminal-launch           "$(BINDIR)/asm-terminal-launch"
	install -m 0644 packaging/linux/asm-terminal.desktop          "$(APPDIR)/asm-terminal.desktop"
	install -m 0644 packaging/linux/asm-terminal.svg              "$(ICONDIR)/asm-terminal.svg"
	-update-desktop-database "$(APPDIR)" 2>/dev/null || true
	-gtk-update-icon-cache "$(SHAREDIR)/icons/hicolor" 2>/dev/null || true
	@echo "Installed ASM Terminal with desktop integration."
	@echo "Open from your app menu or run: $(INSTALL_NAME)"

install-gui: $(TARGET)
	bash packaging/linux/install.sh

uninstall:
	rm -f "$(BINDIR)/$(INSTALL_NAME)"
	rm -f "$(BINDIR)/asm-terminal-launch"
	rm -f "$(APPDIR)/asm-terminal.desktop"
	rm -f "$(ICONDIR)/asm-terminal.svg"
	-update-desktop-database "$(APPDIR)" 2>/dev/null || true
	-gtk-update-icon-cache "$(SHAREDIR)/icons/hicolor" 2>/dev/null || true
	@echo "Removed ASM Terminal."

# ----------------------------------------------------------------------------
# Tests + introspection
# ----------------------------------------------------------------------------

test: $(TARGET)
	bash tests/run_tests.sh

size: $(TARGET)
	@ls -la $(TARGET) | awk '{print "size: " $$5 " bytes"}'
	@readelf -h $(TARGET) 2>/dev/null | grep -E 'Type|Machine|Entry' || true
	@nm $(TARGET) 2>/dev/null | wc -l | awk '{print "symbol count: " $$1}'

# ----------------------------------------------------------------------------
# Packaging
# ----------------------------------------------------------------------------

dist: $(TARGET)
	mkdir -p dist/$(DIST_NAME)
	cp $(TARGET)                                dist/$(DIST_NAME)/
	cp -r packaging/linux                       dist/$(DIST_NAME)/
	-cp README.md LICENSE                       dist/$(DIST_NAME)/ 2>/dev/null || true
	tar -C dist -czf dist/$(DIST_NAME).tar.gz $(DIST_NAME)
	@sha256sum dist/$(DIST_NAME).tar.gz

deb: $(TARGET)
	bash packaging/debian/build-deb.sh

appimage: $(TARGET)
	bash packaging/appimage/build-appimage.sh

zip-windows:
	@if [ ! -f terminal.exe ]; then \
		echo "terminal.exe not present — build with build.bat on Windows or copy it in"; \
		exit 1; \
	fi
	mkdir -p dist/$(WIN_DIST)
	cp terminal.exe                                     dist/$(WIN_DIST)/
	cp packaging/windows/install.bat                    dist/$(WIN_DIST)/
	cp packaging/windows/uninstall.bat                  dist/$(WIN_DIST)/
	-cp packaging/windows/asm-terminal.ico              dist/$(WIN_DIST)/ 2>/dev/null || true
	-cp README.md                                       dist/$(WIN_DIST)/ 2>/dev/null || true
	-cp packaging/windows/README.md                     dist/$(WIN_DIST)/INSTALL.md 2>/dev/null || true
	cd dist && zip -r $(WIN_DIST).zip $(WIN_DIST)
	@sha256sum dist/$(WIN_DIST).zip

release: dist deb appimage
	@echo
	@echo "Release artifacts in dist/:"
	@ls -la dist/ 2>/dev/null || true
	@echo "If building from Windows, also run: make zip-windows"
