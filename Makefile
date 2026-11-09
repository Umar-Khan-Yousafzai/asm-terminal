# ============================================================================
# ASM Terminal — Linux Build
# Requires: nasm, ld (binutils)
#
# Build targets:
#   make                 - build terminal binary
#   make clean           - remove build artifacts
#
# Install (all honour PREFIX, BINDIR and DESTDIR for staged package builds):
#   make install         - install <PREFIX>/bin/asm-terminal + asm symlink (default ~/.local)
#   make install-desktop - install binary + launcher + .desktop + icon (Linux app menu)
#   make install-gui     - run the zenity installer for interactive install
#   make uninstall       - reverse install-desktop
# The asm symlink is only created or removed when asm is absent or already ours;
# another program named asm (pwntools) is never overwritten.
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
# macOS (x86-64 Mach-O; runs on Apple Silicon through Rosetta 2):
#   make                 - on a Mac builds the macOS binary (needs nasm + Xcode
#                          Command Line Tools)
#   make terminal-macos  - cross-build it on Linux with ld64.lld (package lld)
#   make check-high      - link the Linux build above 4 GiB, where Mach-O loads
#                          code: fails on any absolute 32-bit address
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
DEPS    = $(SRC) version.inc $(wildcard ash/*.asm) $(wildcard platform/*)

# macOS: Mach-O, entry _start called by dyld. libSystem is linked because
# dyld requires it; the program calls nothing in it.
MACOS_MIN ?= 11.0
LD64      ?= ld64.lld
UNAME_S   := $(shell uname -s)
ifeq ($(UNAME_S),Darwin)
NASMFLAGS  = -f macho64 -DPLATFORM_MACOS
MACOS_SDK ?= $(shell xcrun --show-sdk-path 2>/dev/null)
LINK       = $(LD) -arch x86_64 -platform_version macos $(MACOS_MIN) $(MACOS_MIN) \
             -e _start -L$(MACOS_SDK)/usr/lib -lSystem
else
NASMFLAGS  = -f elf64
LINK       = $(LD) -e _start
endif

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
        test size dist deb rpm desktop-tarball appimage zip-windows release check-high

all: $(TARGET)

$(TARGET): $(OBJ)
	$(LINK) $(OBJ) -o $(TARGET)

$(OBJ): $(DEPS)
	$(NASM) $(NASMFLAGS) $(SRC) -o $(OBJ)

# Cross-build of the macOS binary on Linux. packaging/macos/libSystem.tbd
# stands in for the SDK: it only names the library dyld loads.
terminal-macos: $(DEPS) packaging/macos/libSystem.tbd
	$(NASM) -f macho64 -DPLATFORM_MACOS $(SRC) -o terminal_macos.o
	$(LD64) -arch x86_64 -platform_version macos $(MACOS_MIN) $(MACOS_MIN) \
	        -e _start -L packaging/macos -lSystem terminal_macos.o -o $@

check-high: $(DEPS)
	$(NASM) -f elf64 $(SRC) -o terminal_high.o
	$(LD) -e _start -Ttext-segment=0x200000000 terminal_high.o -o terminal-high
	@echo "OK: no absolute 32-bit addresses (terminal-high runs above 4 GiB)"

version:
	@echo $(VERSION)

clean:
	rm -f $(OBJ) $(TARGET) terminal_macos.o terminal-macos terminal_high.o terminal-high
	rm -rf dist packaging/appimage/AppDir packaging/appimage/_tools \
	       packaging/debian/_stage packaging/rpm/_rpmbuild asm-terminal-*.AppImage

# ----------------------------------------------------------------------------
# Install (binary only)
# ----------------------------------------------------------------------------

install: $(TARGET)
	install -d "$(DESTDIR)$(BINDIR)"
	install -m 0755 "$(TARGET)" "$(DESTDIR)$(BINDIR)/asm-terminal"
	@dest="$(DESTDIR)$(BINDIR)/$(INSTALL_NAME)"; \
	if [ ! -e "$$dest" ] && [ ! -L "$$dest" ]; then ours=1; \
	elif [ -L "$$dest" ]; then \
		case "$$(readlink "$$dest")" in */asm-terminal|asm-terminal) ours=1 ;; *) ours=0 ;; esac; \
	elif [ -f "$$dest" ] && grep -aq 'ASM Terminal v' "$$dest"; then ours=1; \
	else ours=0; fi; \
	if [ "$$ours" = 1 ]; then \
		ln -sf asm-terminal "$$dest"; \
		echo "Installed $(BINDIR)/asm-terminal (and $(BINDIR)/$(INSTALL_NAME) -> asm-terminal)"; \
	else \
		echo "Installed $(BINDIR)/asm-terminal"; \
		echo "note: $(BINDIR)/$(INSTALL_NAME) is another program and was left alone. Run 'asm-terminal'."; \
	fi
	@$(MAKE) --no-print-directory check-path

# ----------------------------------------------------------------------------
# Install with .desktop entry + icon + launcher wrapper (recognizable app)
# ----------------------------------------------------------------------------

ICON_SIZES = 16 22 24 32 48 64 96 128 192 256 512

install-desktop: install
	install -d "$(DESTDIR)$(APPDIR)" "$(DESTDIR)$(ICONDIR)"
	install -m 0755 packaging/linux/asm-terminal-launch           "$(DESTDIR)$(BINDIR)/asm-terminal-launch"
	@bin='$(BINDIR)/asm-terminal-launch'; \
	while IFS= read -r line || [ -n "$$line" ]; do \
		case "$$line" in \
			TryExec=*) printf 'TryExec=%s\n' "$$bin" ;; \
			Exec=*)    printf 'Exec="%s"\n' "$$bin" ;; \
			*)         printf '%s\n' "$$line" ;; \
		esac; \
	done < packaging/linux/asm-terminal.desktop > "$(DESTDIR)$(APPDIR)/asm-terminal.desktop"
	chmod 0644 "$(DESTDIR)$(APPDIR)/asm-terminal.desktop"
	install -m 0644 packaging/linux/asm-terminal.svg              "$(DESTDIR)$(ICONDIR)/asm-terminal.svg"
	for s in $(ICON_SIZES); do \
		install -d "$(DESTDIR)$(SHAREDIR)/icons/hicolor/$${s}x$${s}/apps"; \
		install -m 0644 "packaging/linux/icons/hicolor/$${s}x$${s}/apps/asm-terminal.png" \
		        "$(DESTDIR)$(SHAREDIR)/icons/hicolor/$${s}x$${s}/apps/asm-terminal.png"; \
	done
	install -d "$(DESTDIR)$(SHAREDIR)/icons/hicolor/symbolic/apps"
	install -m 0644 packaging/linux/icons/hicolor/symbolic/apps/asm-terminal-symbolic.svg \
	        "$(DESTDIR)$(SHAREDIR)/icons/hicolor/symbolic/apps/asm-terminal-symbolic.svg"
	@if [ -z "$(DESTDIR)" ]; then \
		update-desktop-database "$(APPDIR)" 2>/dev/null || true; \
		gtk-update-icon-cache "$(SHAREDIR)/icons/hicolor" 2>/dev/null || true; \
	fi
	@echo "Installed ASM Terminal with desktop integration."
	@echo "Search 'ASM' in your app launcher, or run: asm-terminal"

install-gui: $(TARGET)
	bash packaging/linux/install.sh

uninstall:
	@dest="$(DESTDIR)$(BINDIR)/$(INSTALL_NAME)"; \
	if [ -L "$$dest" ]; then \
		case "$$(readlink "$$dest")" in */asm-terminal|asm-terminal) rm -f "$$dest" ;; esac; \
	elif [ -f "$$dest" ] && grep -aq 'ASM Terminal v' "$$dest"; then rm -f "$$dest"; fi
	rm -f "$(DESTDIR)$(BINDIR)/asm-terminal"
	rm -f "$(DESTDIR)$(BINDIR)/asm-terminal-launch"
	rm -f "$(DESTDIR)$(APPDIR)/asm-terminal.desktop"
	rm -f "$(DESTDIR)$(ICONDIR)/asm-terminal.svg"
	for s in $(ICON_SIZES); do rm -f "$(DESTDIR)$(SHAREDIR)/icons/hicolor/$${s}x$${s}/apps/asm-terminal.png"; done
	rm -f "$(DESTDIR)$(SHAREDIR)/icons/hicolor/symbolic/apps/asm-terminal-symbolic.svg"
	@if [ -z "$(DESTDIR)" ]; then \
		update-desktop-database "$(APPDIR)" 2>/dev/null || true; \
		gtk-update-icon-cache "$(SHAREDIR)/icons/hicolor" 2>/dev/null || true; \
	fi
	@echo "Removed ASM Terminal."

# Warn when another program named `asm` (e.g. pwntools' /usr/bin/asm on
# Fedora) shadows ours on PATH.
check-path:
	@[ -z "$(DESTDIR)" ] || exit 0; \
	found="$$(command -v $(INSTALL_NAME) 2>/dev/null || true)"; \
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
	cp README.md LICENSE                        dist/$(DIST_NAME)/
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
	cp LICENSE                                          dist/$(WIN_DIST)/
	-cp packaging/windows/README.md                     dist/$(WIN_DIST)/INSTALL.md 2>/dev/null || true
	cd dist && zip -r $(WIN_DIST).zip $(WIN_DIST)
	@sha256sum dist/$(WIN_DIST).zip

release: dist deb rpm desktop-tarball appimage
	@echo
	@echo "Release artifacts in dist/:"
	@ls -la dist/ 2>/dev/null || true
	@echo "If building from Windows, also run: make zip-windows"
