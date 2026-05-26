# Code Signing — Koe for Windows

Without an Authenticode signature, `koe.exe` and `Koe-Setup.exe` trigger the
SmartScreen "Windows protected your PC — Unknown publisher" prompt, which is
the single biggest install-time drop-off on Windows. This doc describes the
SignTool workflow we use (or will use) to sign both binaries.

No certificate material lives in this repository. Everything below assumes a
PFX (`.pfx`) issued by a commercial CA.

## 1. Get a code-signing certificate

Pick one of:

- **EV (Extended Validation) code-signing certificate** — required to get
  SmartScreen reputation immediately. Hardware token (USB HSM) is mandatory
  with most CAs since June 2023.
- **OV (Organisation Validation) code-signing certificate** — cheaper; the
  binary still trips SmartScreen until it builds reputation across ~3k
  installs, but warnings disappear once reputation is established.

Common vendors: Sectigo, DigiCert, SSL.com, GlobalSign.

The CA will deliver either a PFX file (OV) or pre-load it onto a USB token
(EV). For the GitHub Actions flow below we assume PFX-based OV; EV signing
generally has to run on a self-hosted runner with the token attached.

## 2. Local signing with `signtool`

`signtool` ships with the Windows 10/11 SDK
(`C:\Program Files (x86)\Windows Kits\10\bin\<version>\x64\signtool.exe`).

Sign the binary:

```powershell
signtool sign `
  /tr http://timestamp.digicert.com `
  /td sha256 `
  /fd sha256 `
  /f path\to\koe-codesign.pfx `
  /p $env:KOE_PFX_PASSWORD `
  Koe-windows\dist\koe.exe
```

Then sign the installer (after NSIS has produced it):

```powershell
signtool sign `
  /tr http://timestamp.digicert.com `
  /td sha256 `
  /fd sha256 `
  /f path\to\koe-codesign.pfx `
  /p $env:KOE_PFX_PASSWORD `
  Koe-windows\installer\Koe-Setup.exe
```

Flags:

- `/tr` — RFC 3161 timestamp server. Without `/tr`, the signature expires
  with the cert (~1 year); with it, the signature stays valid forever for
  the binary signed before the cert expired.
- `/td sha256` — timestamp digest algorithm.
- `/fd sha256` — file digest algorithm. SHA-1 is rejected by modern Windows.

## 3. Verify a signature

```powershell
signtool verify /pa /v Koe-windows\installer\Koe-Setup.exe
```

`/pa` uses the default Authenticode policy. Look for
`Successfully verified` and a populated `Signing Certificate Chain`.

## 4. CI integration outline

In GitHub Actions, store the PFX as a base64-encoded secret and decode it on
the runner before signing. Sketch:

```yaml
# .github/workflows/windows-build.yml (sign step, not yet enabled)
- name: Decode signing certificate
  if: github.event_name != 'pull_request'
  shell: pwsh
  run: |
    [IO.File]::WriteAllBytes(
      "$env:RUNNER_TEMP\koe-codesign.pfx",
      [Convert]::FromBase64String($env:KOE_PFX_BASE64)
    )
  env:
    KOE_PFX_BASE64: ${{ secrets.KOE_PFX_BASE64 }}

- name: Sign koe.exe
  if: github.event_name != 'pull_request'
  shell: pwsh
  run: |
    & "${env:ProgramFiles(x86)}\Windows Kits\10\bin\10.0.22621.0\x64\signtool.exe" `
      sign /tr http://timestamp.digicert.com /td sha256 /fd sha256 `
      /f "$env:RUNNER_TEMP\koe-codesign.pfx" `
      /p "$env:KOE_PFX_PASSWORD" `
      Koe-windows\dist\koe.exe
  env:
    KOE_PFX_PASSWORD: ${{ secrets.KOE_PFX_PASSWORD }}

# Build NSIS installer here, then sign Koe-Setup.exe with the same step.

- name: Clean up certificate
  if: always() && github.event_name != 'pull_request'
  shell: pwsh
  run: Remove-Item "$env:RUNNER_TEMP\koe-codesign.pfx" -Force -ErrorAction Ignore
```

Required GitHub Secrets:

| Secret              | Contents                                                |
| ------------------- | ------------------------------------------------------- |
| `KOE_PFX_BASE64`    | `base64 -w0 koe-codesign.pfx` output                    |
| `KOE_PFX_PASSWORD`  | the PFX export password                                 |

PRs do not get the secrets (the `if: github.event_name != 'pull_request'`
guard), so forks cannot exfiltrate the cert.

## 5. winget distribution

Once the installer is signed, publish it to winget so users can do
`winget install EnablerDAO.Koe`. Manifest spec:

https://learn.microsoft.com/en-us/windows/package-manager/package/

Workflow:

1. Host the signed `Koe-Setup.exe` on a stable URL (GitHub Releases is fine).
2. Author a manifest under `manifests/e/EnablerDAO/Koe/<version>/`.
3. Submit a PR to https://github.com/microsoft/winget-pkgs.
4. The validation pipeline downloads the installer, re-checks the
   Authenticode signature, and runs a smoke install in a VM.

## 6. Future work

- Move to EV signing on a self-hosted runner with a hardware token, so the
  SmartScreen warning vanishes from day one of the next release.
- Consider AzureSignTool + Azure Key Vault to host the cert if we move off
  PFX-on-disk.
- Add `signtool verify /pa` as a post-build CI step so a malformed sign step
  fails the workflow instead of shipping an unsigned binary.
