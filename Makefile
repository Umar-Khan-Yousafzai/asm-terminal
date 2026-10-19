# ============================================================================
# ASM Terminal — Linux Build
# Requires: nasm, ld (binutils)
#
# Build targets:
#   make                 - build terminal binary
#   make clean           - remove build artifacts
#
# Install:
#   make install         - install <PREFIX>/bin/asm-terminal + asm symlink (default ~/.local)
#   make install-desktop - install binary + launcher + .desktop + icon (Linux app menu)
#   make install-gui     - run the zenity installer for interactive install
#   make uninstall       - reverse install-desktop
#
# Packaging:
#   make deb             - build a .deb package in dist/
#   make rpm             - build an .rpm package in dist/ (Fedora/RHEL/openSUSE)
#   make desktop-tarball - dist/asm-terminal-linux-desktop.tar.gz (launcher, .desktop, icons)
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

# Single source of truth: version.inc
VERSION   ?= $(shell sed -n 's/.*ASM_VERSION "\(.*\)".*/\1/p' version.inc)
export APP_VERSION ?= $(VERSION)
DIST_NAME  = asm-terminal-$(VERSION)-linux-x86_64
WIN_DIST   = asm-terminal-$(VERSION)-windows-x86_64

.PHONY: version all clean install install-desktop install-gui uninstall check-path \
        test size dist deb rpm desktop-tarball appimage zip-windows release

all: $(TARGET)

$(TARGET): $(OBJ)
	$(LD) $(OBJ) -o $(TARGET) -e _start

$(OBJ): $(SRC) version.inc $(wildcard ash/*.asm)
	$(NASM) -f elf64 $(SRC) -o $(OBJ)

version:
	@echo $(VERSION)

clean:
	rm -f $(OBJ) $(TARGET)
	rm -rf dist packaging/appimage/AppDir packaging/appimage/_tools \
	       packaging/debian/_stage packaging/rpm/_rpmbuild asm-terminal-*.AppImage

# ----------------------------------------------------------------------------
# Install (binary only)
# ----------------------------------------------------------------------------

install: $(TARGET)
	install -d "$(BINDIR)"
	install -m 0755 "$(TARGET)" "$(BINDIR)/asm-terminal"
	ln -sf asm-terminal "$(BINDIR)/$(INSTALL_NAME)"
	@echo "Installed $(BINDIR)/asm-terminal (and $(BINDIR)/$(INSTALL_NAME) -> asm-terminal)"
	@$(MAKE) --no-print-directory check-path

# ----------------------------------------------------------------------------
# Install with .desktop entry + icon + launcher wrapper (recognizable app)
# ----------------------------------------------------------------------------

ICON_SIZES = 16 24 32 48 64 128 256 512

install-desktop: install
	install -d "$(APPDIR)" "$(ICONDIR)"
	install -m 0755 packaging/linux/asm-terminal-launch           "$(BINDIR)/asm-terminal-launch"
	sed -e 's|^TryExec=.*|TryExec=$(BINDIR)/asm-terminal-launch|' \
	    -e 's|^Exec=.*|Exec=$(BINDIR)/asm-terminal-launch|' \
	    packaging/linux/asm-terminal.desktop > "$(APPDIR)/asm-terminal.desktop"
	chmod 0644 "$(APPDIR)/asm-terminal.desktop"
	install -m 0644 packaging/linux/asm-terminal.svg              "$(ICONDIR)/asm-terminal.svg"
	for s in $(ICON_SIZES); do \
		install -d "$(SHAREDIR)/icons/hicolor/$${s}x$${s}/apps"; \
		install -m 0644 "packaging/linux/icons/hicolor/$${s}x$${s}/apps/asm-terminal.png" \
		        "$(SHAREDIR)/icons/hicolor/$${s}x$${s}/apps/asm-terminal.png"; \
	done
	-update-desktop-database "$(APPDIR)" 2>/dev/null || true
	-gtk-update-icon-cache "$(SHAREDIR)/icons/hicolor" 2>/dev/null || true
	@echo "Installed ASM Terminal with desktop integration."
	@echo "Search 'ASM' in your app launcher, or run: asm-terminal"

install-gui: $(TARGET)
	bash packaging/linux/install.sh

uninstall:
	rm -f "$(BINDIR)/$(INSTALL_NAME)" "$(BINDIR)/asm-terminal"
	rm -f "$(BINDIR)/asm-terminal-launch"
	rm -f "$(APPDIR)/asm-terminal.desktop"
	rm -f "$(ICONDIR)/asm-terminal.svg"
	for s in $(ICON_SIZES); do rm -f "$(SHAREDIR)/icons/hicolor/$${s}x$${s}/apps/asm-terminal.png"; done
	-update-desktop-database "$(APPDIR)" 2>/dev/null || true
	-gtk-update-icon-cache "$(SHAREDIR)/icons/hicolor" 2>/dev/null || true
	@echo "Removed ASM Terminal."

# Warn when another program named `asm` (e.g. pwntools' /usr/bin/asm on
# Fedora) shadows ours on PATH.
check-path:
	@found="$$(command -v $(INSTALL_NAME) 2>/dev/null || true)"; \
	if [ -n "$$found" ] && [ "$$(readlink -f "$$found")" != "$$(readlink -f "$(BINDIR)/asm-terminal")" ]; then \
		echo; \
		echo "warning: '$(INSTALL_NAME)' on your PATH is $$found, not ASM Terminal."; \
		echo "  Run 'asm-terminal' instead, or put $(BINDIR) first in PATH:"; \
		echo "    echo 'export PATH=\"$(BINDIR):\$$PATH\"' >> ~/.bashrc"; \
		echo "  then open a new terminal."; \
	fi

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

rpm: $(TARGET)
	bash packaging/rpm/build-rpm.sh

# Desktop files for packaging/linux/install-release.sh (one release asset)
desktop-tarball:
	mkdir -p dist
	tar -C packaging/linux -czf dist/asm-terminal-linux-desktop.tar.gz \
	    asm-terminal-launch asm-terminal.desktop asm-terminal.svg icons

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

release: dist deb rpm desktop-tarball appimage
	@echo
	@echo "Release artifacts in dist/:"
	@ls -la dist/ 2>/dev/null || true
	@echo "If building from Windows, also run: make zip-windows"
