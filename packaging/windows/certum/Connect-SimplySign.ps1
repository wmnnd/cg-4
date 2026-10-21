#Requires -Version 5.1
<#
.SYNOPSIS
    Logs SimplySign Desktop in to the Certum cloud so the code-signing
    certificate becomes usable by signtool, and exports its thumbprint.

.DESCRIPTION
    Certum's cloud signing has no machine credential: SimplySign Desktop asks
    for the account name and a 6-digit TOTP from the SimplySign mobile app.
    On an ephemeral CI runner we therefore compute the TOTP ourselves from the
    enrollment seed and drive the login window with keystrokes (the client
    has no CLI or API for this). Once logged in, the certificate appears in
    Cert:\CurrentUser\My backed by a virtual smart card.

    Environment (secrets):
      CERTUM_USERNAME          SimplySign account e-mail
      CERTUM_TOTP_SECRET       Base32 seed, or the full otpauth:// URI from
                               the enrollment QR code
      CERTUM_CERT_THUMBPRINT   optional: pin the certificate to use
    Environment (optional tuning, only for bare Base32 seeds):
      CERTUM_TOTP_ALGORITHM    SHA256 (Certum's default) | SHA1 | SHA512
      CERTUM_TOTP_DIGITS       6
      CERTUM_TOTP_PERIOD       30
      SIMPLYSIGN_PATH          client path (set by Install-SimplySign.ps1)

    Outputs (GITHUB_OUTPUT / GITHUB_ENV): thumbprint, subject, not-after.
#>
[CmdletBinding()]
param(
    [int]$WindowTimeoutSeconds = 30,
    [int]$CertTimeoutSeconds   = 90
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) { throw 'This script only runs on Windows.' }
if (-not $env:CERTUM_USERNAME)    { throw 'CERTUM_USERNAME is not set.' }
if (-not $env:CERTUM_TOTP_SECRET) { throw 'CERTUM_TOTP_SECRET is not set.' }

$appPath = if ($env:SIMPLYSIGN_PATH) { $env:SIMPLYSIGN_PATH } else { 'C:\Program Files\Certum\SimplySign Desktop\SimplySignDesktop.exe' }
if (-not (Test-Path -LiteralPath $appPath)) { throw "SimplySign Desktop not found at $appPath (run Install-SimplySign.ps1 first)." }

# --- TOTP parameters ----------------------------------------------------------
$otpArgs = @{ Secret = $env:CERTUM_TOTP_SECRET }
if ($env:CERTUM_TOTP_ALGORITHM) { $otpArgs.Algorithm = $env:CERTUM_TOTP_ALGORITHM }
if ($env:CERTUM_TOTP_DIGITS)    { $otpArgs.Digits    = [int]$env:CERTUM_TOTP_DIGITS }
if ($env:CERTUM_TOTP_PERIOD)    { $otpArgs.Period    = [int]$env:CERTUM_TOTP_PERIOD }
$otp = Get-OtpAuthParameters @otpArgs
$key = ConvertFrom-Base32 -Text $otp.Secret
Write-Host "TOTP: $($otp.Algorithm), $($otp.Digits) digits, $($otp.Period)s period"

# --- Native helpers -----------------------------------------------------------
if (-not ('ClipGrab.Native.User32' -as [type])) {
    Add-Type -Namespace ClipGrab.Native -Name User32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'@
}
$wshell = New-Object -ComObject WScript.Shell

function Get-SimplySignWindow {
    # The login dialog is the only top-level window the client shows; the
    # tray daemon has no main window, so MainWindowHandle filters it out.
    # Callers wrap the result in @(): PowerShell unrolls pipeline output, so an
    # empty result is $null (no .Count under strict mode) and a single hit is
    # a bare Process object.
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $_.MainWindowHandle -ne 0 -and
        ($_.ProcessName -like '*SimplySign*' -or $_.MainWindowTitle -like '*SimplySign*')
    }
}

function Set-WindowFocus {
    param([Parameter(Mandatory = $true)]$Process)
    [void][ClipGrab.Native.User32]::ShowWindow($Process.MainWindowHandle, 9)   # SW_RESTORE
    [void][ClipGrab.Native.User32]::SetForegroundWindow($Process.MainWindowHandle)
    [void]$wshell.AppActivate($Process.Id)
    Start-Sleep -Milliseconds 300
}

function Send-Text {
    # SendKeys treats + ^ % ~ ( ) { } [ ] specially; wrap them in braces.
    param([Parameter(Mandatory = $true)][string]$Text)
    $escaped = [regex]::Replace($Text, '[+^%~(){}\[\]]', { param($m) '{' + $m.Value + '}' })
    $wshell.SendKeys($escaped)
}

function Send-Keys {
    param([Parameter(Mandatory = $true)][string]$Keys, [int]$DelayMs = 200)
    $wshell.SendKeys($Keys)
    Start-Sleep -Milliseconds $DelayMs
}

# --- Launch the client and wait for its login window --------------------------
Write-Host "Starting $appPath"
# First launch starts the tray daemon; the second one brings up the login
# window. (Mirrors how the client behaves when a user double-clicks it twice.)
Start-Process -FilePath $appPath | Out-Null
Start-Sleep -Seconds 3
Start-Process -FilePath $appPath | Out-Null

$window   = $null
$deadline = (Get-Date).AddSeconds($WindowTimeoutSeconds)
while (-not $window -and (Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 2
    $found = @(Get-SimplySignWindow)
    if ($found.Count -gt 0) { $window = $found[0] } else { Start-Process -FilePath $appPath | Out-Null }
}
if (-not $window) { throw 'SimplySign Desktop login window did not appear.' }
Write-Host "Login window found: '$($window.MainWindowTitle)' (pid $($window.Id))"

# --- Log in (up to 2 attempts) --------------------------------------------------
$loggedIn = $false
for ($attempt = 1; $attempt -le 2 -and -not $loggedIn; $attempt++) {
    # Never submit a code that is about to roll over.
    $remaining = Get-TotpSecondsRemaining -Period $otp.Period
    if ($remaining -lt 10) {
        Write-Host "TOTP window ends in ${remaining}s; waiting for the next one."
        Start-Sleep -Seconds ($remaining + 1)
    }
    $code = Get-TotpCode -Key $key -Algorithm $otp.Algorithm -Digits $otp.Digits -Period $otp.Period

    Write-Host "Submitting credentials (attempt $attempt)"
    Set-WindowFocus -Process $window
    Send-Keys '^a' 100
    Send-Text $env:CERTUM_USERNAME
    Start-Sleep -Milliseconds 200
    Send-Keys '{TAB}' 200
    Send-Keys '^a' 100
    Send-Text $code
    Start-Sleep -Milliseconds 200
    Set-WindowFocus -Process $window
    Send-Keys '{ENTER}' 500
    $code = $null

    # Success == the login window goes away (the client drops to the tray).
    $closeBy = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $closeBy) {
        Start-Sleep -Seconds 2
        if (@(Get-SimplySignWindow).Count -eq 0) { $loggedIn = $true; break }
    }
    if (-not $loggedIn -and $attempt -lt 2) {
        Write-Warning 'Login window still open; dismissing any error dialog and retrying.'
        $found = @(Get-SimplySignWindow)
        if ($found.Count -gt 0) {
            $window = $found[0]
            Set-WindowFocus -Process $window
            Send-Keys '{ENTER}' 500      # closes an "Invalid user name or token" box
            Send-Keys '{ESC}' 1000
        }
        $found = @(Get-SimplySignWindow)
        if ($found.Count -eq 0) { throw 'SimplySign Desktop login window disappeared without mounting a certificate.' }
        $window = $found[0]
    }
}
[Array]::Clear($key, 0, $key.Length)
if (-not $loggedIn) { throw 'SimplySign Desktop did not accept the credentials (window never closed).' }

# --- Wait for the certificate to be mounted -----------------------------------
$cert     = $null
$deadline = (Get-Date).AddSeconds($CertTimeoutSeconds)
while (-not $cert -and (Get-Date) -lt $deadline) {
    $cert = Find-CertumCertificate -Thumbprint $env:CERTUM_CERT_THUMBPRINT
    if (-not $cert) { Start-Sleep -Seconds 3 }
}
if (-not $cert) {
    Write-Host 'Certificates currently in Cert:\CurrentUser\My:'
    Get-ChildItem Cert:\CurrentUser\My | Format-Table Thumbprint, HasPrivateKey, Subject -AutoSize | Out-String | Write-Host
    throw 'No usable Certum code-signing certificate appeared after login.'
}

Write-Host "Certificate mounted: $($cert.Subject)"
Write-Host "  thumbprint: $($cert.Thumbprint)"
Write-Host "  issuer:     $($cert.Issuer)"
Write-Host "  valid to:   $($cert.NotAfter.ToString('o'))"
if ($cert.NotAfter -lt (Get-Date).AddDays(30)) {
    Write-Warning "Certificate expires within 30 days ($($cert.NotAfter.ToString('yyyy-MM-dd')))."
}

Write-ActionsOutput -Name 'thumbprint' -Value $cert.Thumbprint
Write-ActionsOutput -Name 'subject'    -Value $cert.Subject
Write-ActionsOutput -Name 'not-after'  -Value $cert.NotAfter.ToString('o')
Write-ActionsEnv    -Name 'CERTUM_CERT_THUMBPRINT' -Value $cert.Thumbprint
