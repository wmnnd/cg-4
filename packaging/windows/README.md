# Windows installer (Inno Setup)

The CI expects the Inno Setup script at **`packaging/windows/clipgrab.iss`**
(not yet committed — drop it in and the `windows` job will build + sign an
installer automatically).

## Contract between the workflow and your `.iss`

The workflow invokes the Inno Setup compiler like:

```
ISCC.exe /DAppVersion=<version> /DStageDir=<abs path> /DOutputDir=<abs path> \
         /DOutputBaseName=clipgrab-setup packaging\windows\clipgrab.iss
```

So your `.iss` should read these preprocessor defines rather than hard-coding
paths:

| Define            | Meaning                                                        |
|-------------------|---------------------------------------------------------------|
| `AppVersion`      | Version string (from `CLIPGRAB_VERSION` in `CMakeLists.txt`). May carry a pre-release suffix (e.g. `4.0.0-beta1`) — fine for `[Setup] AppVersion`, but do NOT feed it to `VersionInfoVersion`, which requires numeric `x.x.x.x`. |
| `StageDir`        | Folder containing the fully-staged app: `clipgrab.exe`, the Qt DLLs/plugins, `ffmpeg.exe`, `deno.exe`. Point `[Files]` at `{#StageDir}\*`. |
| `OutputDir`       | Where to emit the compiled installer.                         |
| `OutputBaseName`  | Base filename of the installer (no extension).                |

Minimal skeleton:

```iss
#define AppName "ClipGrab"
[Setup]
AppName={#AppName}
AppVersion={#AppVersion}
DefaultDirName={autopf}\{#AppName}
OutputDir={#OutputDir}
OutputBaseFilename={#OutputBaseName}
ArchitecturesInstallIn64BitMode=x64compatible
[Files]
Source: "{#StageDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs
[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\clipgrab.exe"
```

If the `.iss` is absent the job simply skips installer creation (and still
uploads the raw `.zip`), so this never blocks CI.

## Code signing (both the exe and the installer)

Signing runs only when the Certum secrets are configured (see the repo-level
secrets below); otherwise unsigned artifacts are produced. The staged
`clipgrab.exe` is signed before packaging, and the finished installer is signed
after ISCC runs. Do **not** add a `SignTool=` directive to the `.iss`: the
workflow signs the finished installer itself.

### How Windows signing works (Certum "Code Signing in the Cloud")

The certificate is an OV code-signing certificate whose private key lives on
Certum's cloud HSM (SimplySign). Certum provides no machine credential for it:
their SimplySign Desktop client logs in with the account e-mail plus a TOTP
code from the SimplySign mobile app, then exposes the certificate to Windows as
a virtual smart card. The scripts in `certum/` reproduce exactly that on the
runner, with no third-party actions:

| Script                      | Role                                                                 |
|-----------------------------|----------------------------------------------------------------------|
| `Install-SimplySign.ps1`    | Downloads the pinned SimplySign Desktop MSI from Certum, verifies its Certum/Asseco Authenticode signature (and the pinned SHA256 once set), installs it silently. |
| `Connect-SimplySign.ps1`    | Computes the TOTP from the seed, drives the client's login window by keystrokes, waits for the certificate to appear in `Cert:\CurrentUser\My` (the only success criterion), exports its thumbprint as a step output. On failure the `simplysign-diagnostics` job artifact holds screenshots and a UI Automation dump of the client's windows. |
| `Sign-File.ps1`             | `signtool sign /sha1 <thumbprint> /fd sha256 /tr http://time.certum.pl /td sha256`, then `signtool verify /pa`. |
| `Disconnect-SimplySign.ps1` | Closes the client and purges the certificate from the store; runs with `if: always()`. |
| `Common.ps1`                | Shared helpers (Base32, TOTP, certificate/signtool lookup). `Test-Common.ps1` checks the TOTP code against the RFC 6238 vectors and runs on any OS with `pwsh`. |

Pin the SimplySign Desktop version and MSI hash in `ci.yml`
(`SIMPLYSIGN_VERSION` / `SIMPLYSIGN_MSI_SHA256`); with an empty hash the
install step prints the computed value once so it can be pasted in, the same
bootstrap flow as `cmake/PrepareDependencies.cmake`.

Caveats worth knowing:

- The login is driven by `SendKeys` into Certum's GUI, so a SimplySign Desktop
  update that changes the login dialog can break it. Keep the version pinned
  and bump it deliberately.
- Certum states that CI/CD use is not officially supported; this is the same
  approach the community uses, just kept in-repo.
- The TOTP seed plus the account e-mail are sufficient to sign as the company.
  Treat `CERTUM_TOTP_SECRET` like the private key: repository secrets are fine
  for a single-maintainer private repo, otherwise move the Windows signing into
  a protected GitHub Environment with required reviewers. If the seed leaks,
  re-issue the SimplySign QR code in the Certum panel (that invalidates the
  old seed) and update the secret.

# Required CI secrets

All signing/notarization is **gated on these being present** — with none set,
CI still builds and uploads unsigned `.zip` / `.dmg` / `.exe` / raw artifacts.

## macOS (code signing + notarization)

**Signing** (Developer ID Application certificate):

| Secret                        | What it is                                                    |
|-------------------------------|---------------------------------------------------------------|
| `MACOS_CERTIFICATE_P12`       | base64 of the Developer ID Application cert (`.p12`).         |
| `MACOS_CERTIFICATE_PASSWORD`  | password for that `.p12`.                                     |
| `MACOS_SIGN_IDENTITY`         | *(optional)* e.g. `Developer ID Application: Your Name (TEAMID)`. Auto-derived from the cert if omitted — only set it to override. |

**Notarization** — provide **one** of the two credential sets below (the CI
auto-detects which one is present; the API key wins if both are set):

*Option A — App Store Connect API key* (a Team Key; preferred for automation):

| Secret                        | What it is                                                    |
|-------------------------------|---------------------------------------------------------------|
| `MACOS_NOTARY_KEY`            | base64 of the App Store Connect API key (`.p8`).             |
| `MACOS_NOTARY_KEY_ID`         | the API key ID (10-char).                                     |
| `MACOS_NOTARY_ISSUER_ID`      | the API key issuer UUID.                                       |

*Option B — Apple ID + app-specific password* (no API-key enrollment needed):

| Secret                        | What it is                                                    |
|-------------------------------|---------------------------------------------------------------|
| `MACOS_NOTARY_APPLE_ID`       | the developer account email.                                  |
| `MACOS_NOTARY_APP_PASSWORD`   | an app-specific password (appleid.apple.com → Sign-In and Security). |
| `MACOS_NOTARY_TEAM_ID`        | the 10-char Developer Team ID.                                |

Signing needs the `.p12` + its password (the identity is read back from the
cert automatically); notarization additionally needs one of the two credential
sets. Signing without notarization is supported (the app is signed but the
`.dmg` isn't stapled).

## Windows (code signing, Certum SimplySign)

| Secret                        | What it is                                                    |
|-------------------------------|---------------------------------------------------------------|
| `CERTUM_USERNAME`             | the SimplySign account e-mail (the login used in the SimplySign apps). |
| `CERTUM_TOTP_SECRET`          | the TOTP seed: either the Base32 string, or the whole `otpauth://totp/...` URI encoded in the SimplySign activation QR code (the URI also carries algorithm/digits/period). Certum's seeds use SHA-256, 6 digits, 30 s. |
| `CERTUM_CERT_THUMBPRINT`      | *(optional)* SHA-1 thumbprint of the certificate to use. Auto-detected (first Certum-issued code-signing cert with a private key) if omitted; set it only if the account holds several certificates. |

Both `CERTUM_USERNAME` and `CERTUM_TOTP_SECRET` must be present for the
Windows signing steps to run; with either missing the job uploads unsigned
artifacts.

Getting the seed: during SimplySign activation Certum shows a QR code for the
mobile app. Decode that QR (any QR reader) and store the resulting
`otpauth://` URI as `CERTUM_TOTP_SECRET`. It is the same seed the phone app
uses, so the phone keeps working alongside CI. Enrolling the phone *and*
recording the URI from the same QR is the simplest way to keep a manual
fallback.
