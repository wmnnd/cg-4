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
| `AppVersion`      | Version string (from `CLIPGRAB_VERSION` in `CMakeLists.txt`).  |
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

Signing runs only when the signing secrets are configured (see the repo-level
secrets below); otherwise unsigned artifacts are produced. The staged
`clipgrab.exe` is signed before packaging, and the finished installer is signed
after ISCC runs.

# Required CI secrets

All signing/notarization is **gated on these being present** — with none set,
CI still builds and uploads unsigned `.zip` / `.app` / `.exe` / raw artifacts.

## macOS (code signing + notarization)

| Secret                        | What it is                                                    |
|-------------------------------|---------------------------------------------------------------|
| `MACOS_CERTIFICATE_P12`       | base64 of the Developer ID Application cert (`.p12`).         |
| `MACOS_CERTIFICATE_PASSWORD`  | password for that `.p12`.                                     |
| `MACOS_SIGN_IDENTITY`         | e.g. `Developer ID Application: Your Name (TEAMID)`.          |
| `MACOS_NOTARY_KEY`            | base64 of the App Store Connect API key (`.p8`).             |
| `MACOS_NOTARY_KEY_ID`         | the API key ID.                                               |
| `MACOS_NOTARY_ISSUER_ID`      | the API key issuer UUID.                                       |

Signing needs the first three; notarization additionally needs the last three.
Signing without notarization is supported (the app is signed but not stapled).

## Windows (code signing)

| Secret                        | What it is                                                    |
|-------------------------------|---------------------------------------------------------------|
| `WINDOWS_CERTIFICATE_PFX`     | base64 of the code-signing cert (`.pfx`).                     |
| `WINDOWS_CERTIFICATE_PASSWORD`| password for that `.pfx`.                                     |
