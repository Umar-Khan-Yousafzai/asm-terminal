# RPM spec for ASM Terminal (Fedora, RHEL, openSUSE).
# Repackages the prebuilt static binary, so no build dependencies.
# Built by packaging/rpm/build-rpm.sh; Version comes from version.inc.

%global debug_package %{nil}
%global __strip /bin/true
%global _missing_build_ids_terminate_build 0

Name:           asm-terminal
Version:        %{app_version}
Release:        1%{?dist}
Summary:        Shell written in x86-64 assembly (no libc, raw syscalls)
License:        MIT
URL:            https://github.com/Umar-Khan-Yousafzai/asm-terminal
ExclusiveArch:  x86_64
AutoReqProv:    no
Source0:        asm-terminal-%{app_version}-payload.tar.gz

%description
ASM Terminal is a full-featured shell written entirely in x86-64 NASM
assembly: history, tab completion, job control, pipelines, scripting,
themes. Statically linked, no libc. Installs an app-menu entry and icon.

The command is asm-terminal. The package does not install /usr/bin/asm,
because pwntools and other tools use that name; add an alias or a
~/.local/bin/asm symlink if you want it.

%prep
%setup -q -c

%install
install -Dm0755 terminal               %{buildroot}%{_bindir}/asm-terminal
install -Dm0755 asm-terminal-launch    %{buildroot}%{_bindir}/asm-terminal-launch
install -Dm0644 asm-terminal.desktop   %{buildroot}%{_datadir}/applications/asm-terminal.desktop
install -Dm0644 asm-terminal.svg       %{buildroot}%{_datadir}/icons/hicolor/scalable/apps/asm-terminal.svg
for d in icons/hicolor/*x*; do
    s="$(basename "$d")"
    install -Dm0644 "$d/apps/asm-terminal.png" %{buildroot}%{_datadir}/icons/hicolor/$s/apps/asm-terminal.png
done
install -Dm0644 icons/hicolor/symbolic/apps/asm-terminal-symbolic.svg \
    %{buildroot}%{_datadir}/icons/hicolor/symbolic/apps/asm-terminal-symbolic.svg

%files
%{_bindir}/asm-terminal
%{_bindir}/asm-terminal-launch
%{_datadir}/applications/asm-terminal.desktop
%{_datadir}/icons/hicolor/*/apps/asm-terminal.*
%{_datadir}/icons/hicolor/symbolic/apps/asm-terminal-symbolic.svg

%changelog
* Tue Oct 20 2026 Umar Khan Yousafzai <ionkhan@gmail.com> - 2.2.0-1
- Release 2.2.0, see CHANGELOG.md

* Mon Oct 19 2026 Umar Khan Yousafzai <ionkhan@gmail.com> - 2.1.0-1
- RPM packaging
