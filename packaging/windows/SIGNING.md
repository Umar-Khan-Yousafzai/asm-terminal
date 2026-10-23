# Signing the Windows installer

Windows 10/11 SmartScreen shows a blue "Windows protected your PC" screen when
an unsigned `.exe` is downloaded from the internet. Signing the installer —
and letting it accumulate download reputation — makes that warning go away.

There is no "free instant fix". Your options rank from *most polished* to *free*:

## 1. EV code-signing certificate (instant trust, expensive)

- Issuers: DigiCert, Sectigo, GlobalSign, SSL.com
- Cost: **$250–$600/year**, ships on a HSM dongle or cloud-HSM
- SmartScreen trusts EV-signed binaries **immediately**, no reputation period
- This is what commercial vendors use

## 2. Azure Trusted Signing (cheap, cloud-HSM, no dongle)

- Microsoft's replacement for "Azure Code Signing" — GA since 2024
- **~$10/month** for the Basic tier; add DigiCert/Sectigo identity verification
- Integration: `AzureSignTool` or the GitHub Action
- SmartScreen picks up the cert quickly since it's MS-issued
- <https://learn.microsoft.com/azure/trusted-signing/overview>

## 3. SignPath.io Foundation (free for open source)

- Free tier specifically for OSS projects, sponsored by SignPath + SSL.com
- Apply: <https://signpath.org/registration>
- You keep the GitHub repo, they issue and manage the cert, builds are signed
  in their HSM. 1–2 week onboarding.
- This is the route most OSS Windows projects take.

## 4. Standard OV code-signing certificate (medium)

- Cost: **$75–$200/year** (Sectigo, SSL.com, Comodo resellers)
- Signed, but SmartScreen still warns until enough users have run the binary
  and Microsoft's reputation system warms up (weeks to months)
- Better than unsigned, not as instant as EV

## 5. Self-signed (free, but worse than unsigned)

- Create a cert with `New-SelfSignedCertificate`, sign with `signtool`
- SmartScreen flags it as "Unknown publisher". Users can still override.
- Makes the Publisher field show your name instead of "Unknown".
- Not recommended unless you're installing on machines you control.

## 6. Ship unsigned (free, current state unless the PFX secrets are set)

- SmartScreen shows the blue warning. User clicks *More info → Run anyway*
- Document this in the README so users know what to expect
- Submit the binary to <https://www.microsoft.com/en-us/wdsi/filesubmission>
  for manual analysis — if cleared, SmartScreen stops warning after some
  download activity

---

## How the build gets signed in CI

The release workflow has one signing step, and it only supports a `.pfx`
code-signing certificate. If the secrets below are not set the step is
skipped and unsigned files ship. It signs the NSIS `setup.exe` only:
`terminal.exe`, the standalone `asm-terminal-windows-x86_64.exe` and the zip
are not signed.

Add these GitHub Actions secrets (Settings, Secrets and variables, Actions):

- `CODE_SIGN_PFX_BASE64`    the `.pfx` file, base64 encoded
- `CODE_SIGN_PFX_PASSWORD`  its password

Azure Trusted Signing and SignPath (options 2 and 3 above) are not wired into
the workflow. Using either one means adding a signing step to
`.github/workflows/release.yml` (their GitHub Actions, with their own
secrets); setting `AZURE_*` or `SIGNPATH_*` secrets alone does nothing.

### Local signing with a .pfx you already own

`signtool` takes the password as plain text, so read it into a variable first
(or import the certificate into your store and select it with `/sha1`
instead of `/f` and `/p`):

```powershell
# signtool path on Win11 (the version folder differs per SDK install):
$ST = "C:\Program Files (x86)\Windows Kits\10\bin\10.0.22621.0\x64\signtool.exe"
$pw = Read-Host "Cert password"
& $ST sign `
    /fd SHA256 `
    /tr http://timestamp.digicert.com /td SHA256 `
    /f my-cert.pfx /p $pw `
    asm-terminal-<version>-windows-x86_64-setup.exe
```

On Linux, use `osslsigncode` (apt install osslsigncode):

```bash
osslsigncode sign \
    -certs my-cert.crt -key my-cert.key \
    -n "ASM Terminal" -i https://github.com/Umar-Khan-Yousafzai/asm-terminal \
    -t http://timestamp.digicert.com \
    -in  asm-terminal-<version>-windows-x86_64-setup.exe \
    -out asm-terminal-<version>-windows-x86_64-setup.signed.exe
```

## Recommendation for this project

1. **Short term**: ship unsigned. Add a section in README explaining how to
   bypass SmartScreen once ("More info → Run anyway").
2. **Medium term**: apply to SignPath Foundation. Free, legit, and the
   signed binaries start earning SmartScreen reputation from day 1.
3. **Long term**: if downloads pick up and you want zero-warning from the
   first install, move to EV cert ($250–$600/yr) or Azure Trusted Signing.

## What signing does not cover

Authenticode signing is for Windows files only. The Linux assets (the
`asm-terminal-linux-x86_64` binary that `update install` downloads, the
`install.sh` script, the packages) are not signed, and `SHA256SUMS` is
published next to them from the same release. That file detects a corrupted
download. It cannot detect a release that was replaced by someone who can
publish to the repository, because they can replace the checksums too. A
signature made with a key kept outside GitHub (minisign, cosign or GPG, with
the public key shipped in the binary or documented in the README) would close
that gap; none is set up yet.
