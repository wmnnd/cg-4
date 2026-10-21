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
    Cert:\CurrentUser\My backed by a virtual smart card. That certificate,
    not any window state, is the success criterion.

    Diagnostics (screenshots + a UI Automation dump of the client's windows)
    are written to $RUNNER_TEMP\simplysign-diag so a failed login can be
    understood from the job artifact. Screenshots may show the account name.

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
    [int]$LoginTimeoutSeconds  = 45,
    [int]$CertTimeoutSeconds   = 60,
    [int]$MaxLoginAttempts     = 2
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

if ($PSVersionTable.PSEdition -eq 'Core' -and -not $IsWindows) { throw 'This script only runs on Windows.' }
if (-not $env:CERTUM_USERNAME)    { throw 'CERTUM_USERNAME is not set.' }
if (-not $env:CERTUM_TOTP_SECRET) { throw 'CERTUM_TOTP_SECRET is not set.' }

$appPath = if ($env:SIMPLYSIGN_PATH) { $env:SIMPLYSIGN_PATH } else { 'C:\Program Files\Certum\SimplySign Desktop\SimplySignDesktop.exe' }
if (-not (Test-Path -LiteralPath $appPath)) { throw "SimplySign Desktop not found at $appPath (run Install-SimplySign.ps1 first)." }

$diagDir = Join-Path $(if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [IO.Path]::GetTempPath() }) 'simplysign-diag'
New-Item -ItemType Directory -Force -Path $diagDir | Out-Null

# --- TOTP parameters ----------------------------------------------------------
$otpArgs = @{ Secret = $env:CERTUM_TOTP_SECRET }
if ($env:CERTUM_TOTP_ALGORITHM) { $otpArgs.Algorithm = $env:CERTUM_TOTP_ALGORITHM }
if ($env:CERTUM_TOTP_DIGITS)    { $otpArgs.Digits    = [int]$env:CERTUM_TOTP_DIGITS }
if ($env:CERTUM_TOTP_PERIOD)    { $otpArgs.Period    = [int]$env:CERTUM_TOTP_PERIOD }
$otp = Get-OtpAuthParameters @otpArgs
$key = ConvertFrom-Base32 -Text $otp.Secret
Write-Host "TOTP: $($otp.Algorithm), $($otp.Digits) digits, $($otp.Period)s period"

# --- Native / COM helpers -----------------------------------------------------
if (-not ('ClipGrab.Native.User32' -as [type])) {
    Add-Type -Namespace ClipGrab.Native -Name User32 -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
'@
}
$wshell = New-Object -ComObject WScript.Shell

function Get-SimplySignProcess {
    # All client processes (tray daemon + login window); callers wrap in @().
    Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like '*SimplySign*' }
}

function Get-SimplySignWindow {
    # Processes that currently own a top-level window; callers wrap in @().
    # PowerShell unrolls pipeline output, so an empty result is $null (no
    # .Count under strict mode) and a single hit is a bare Process object.
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
    $fg = [ClipGrab.Native.User32]::GetForegroundWindow()
    if ($fg -ne $Process.MainWindowHandle) {
        Write-Warning "Foreground window is not the SimplySign window (hwnd $fg vs $($Process.MainWindowHandle)); keystrokes may go elsewhere."
    }
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

# --- Diagnostics (best effort, via Windows PowerShell 5.1 for WinForms/UIA) ---
function Invoke-WinPS {
    param([Parameter(Mandatory = $true)][string]$Script)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded 2>&1
}

function Save-Screenshot {
    param([Parameter(Mandatory = $true)][string]$Name)
    $file = Join-Path $diagDir ('{0:HHmmss}-{1}.png' -f (Get-Date), $Name)
    $out = Invoke-WinPS @"
try {
    Add-Type -AssemblyName System.Drawing, System.Windows.Forms
    `$b = [System.Windows.Forms.SystemInformation]::VirtualScreen
    `$bmp = New-Object System.Drawing.Bitmap `$b.Width, `$b.Height
    `$g = [System.Drawing.Graphics]::FromImage(`$bmp)
    `$g.CopyFromScreen(`$b.Left, `$b.Top, 0, 0, `$bmp.Size)
    `$bmp.Save('$file', [System.Drawing.Imaging.ImageFormat]::Png)
    `$g.Dispose(); `$bmp.Dispose()
    'saved'
} catch { "screenshot failed: `$(`$_.Exception.Message)" }
"@
    Write-Host "  screenshot '$Name': $out"
}

function Write-WindowReport {
    # Lists every top-level window of the client's processes with their
    # control tree (UI Automation), so the log shows e.g. an error dialog's
    # text or the real layout of the login form. Also appended to the diag
    # directory. Values typed into fields are not read, only control names.
    param([Parameter(Mandatory = $true)][string]$Name)
    $pids = @(Get-SimplySignProcess | ForEach-Object { $_.Id })
    Write-Host "  SimplySign processes: $(if ($pids.Count) { $pids -join ', ' } else { 'none' })"
    if ($pids.Count -eq 0) { return }
    $pidList = $pids -join ','
    $out = Invoke-WinPS @"
try {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    `$root = [System.Windows.Automation.AutomationElement]::RootElement
    `$all  = [System.Windows.Automation.Condition]::TrueCondition
    foreach (`$p in @($pidList)) {
        `$cond = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ProcessIdProperty, [int]`$p)
        foreach (`$w in `$root.FindAll([System.Windows.Automation.TreeScope]::Children, `$cond)) {
            `$c = `$w.Current
            "WINDOW pid=`$p name='`$(`$c.Name)' class='`$(`$c.ClassName)' rect=`$(`$c.BoundingRectangle)"
            foreach (`$e in `$w.FindAll([System.Windows.Automation.TreeScope]::Descendants, `$all)) {
                `$d = `$e.Current
                "  `$(`$d.ControlType.ProgrammaticName -replace '^ControlType\.','') name='`$(`$d.Name)' id='`$(`$d.AutomationId)' class='`$(`$d.ClassName)' focusable=`$(`$d.IsKeyboardFocusable) enabled=`$(`$d.IsEnabled) focused=`$(`$d.HasKeyboardFocus)"
            }
        }
    }
    `$fg = [System.Windows.Automation.AutomationElement]::FocusedElement
    if (`$fg) { "FOCUS pid=`$(`$fg.Current.ProcessId) `$(`$fg.Current.ControlType.ProgrammaticName) name='`$(`$fg.Current.Name)'" }
} catch { "ui dump failed: `$(`$_.Exception.Message)" }
"@
    $text = ($out | Out-String)
    Write-Host "  --- window report '$Name' ---"
    Write-Host $text
    Add-Content -Path (Join-Path $diagDir 'windows.log') -Value ("==== {0:HH:mm:ss} {1}`n{2}" -f (Get-Date), $Name, $text)
}

# --- Desktop prep --------------------------------------------------------------
# Hosted Windows images occasionally show a "System Properties" (paging file)
# dialog at session start; anything in the foreground would swallow our keys.
try { (New-Object -ComObject Shell.Application).MinimizeAll() } catch { }
if ($wshell.AppActivate('System Properties')) { Send-Keys '{ENTER}' 500 }

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
if (-not $window) {
    Save-Screenshot 'no-window'
    Write-WindowReport 'no-window'
    throw 'SimplySign Desktop login window did not appear.'
}
Write-Host "Login window found: '$($window.MainWindowTitle)' (pid $($window.Id), hwnd $($window.MainWindowHandle))"
Save-Screenshot 'login-window'
Write-WindowReport 'login-window'

# --- Log in ----------------------------------------------------------------------
$cert = $null
for ($attempt = 1; $attempt -le $MaxLoginAttempts -and -not $cert; $attempt++) {
    $found = @(Get-SimplySignWindow)
    if ($found.Count -eq 0) {
        # No window to type into: either the previous submit is still being
        # processed or the client dropped to the tray already. Let the
        # certificate poll below decide.
        Write-Host "No login window visible before attempt $attempt; checking the certificate store instead."
    } else {
        $window = $found[0]

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
        Save-Screenshot "attempt$attempt-filled"
        Set-WindowFocus -Process $window
        Send-Keys '{ENTER}' 500
        $code = $null
    }

    # Success == the certificate shows up in the store. The window closing is
    # only a hint: the client may keep a window open while it connects, or
    # close it on an error, so neither state is trusted on its own.
    $loginBy = (Get-Date).AddSeconds($LoginTimeoutSeconds)
    $snapped = $false
    while (-not $cert -and (Get-Date) -lt $loginBy) {
        Start-Sleep -Seconds 3
        $cert = Find-CertumCertificate -Thumbprint $env:CERTUM_CERT_THUMBPRINT
        if (-not $cert -and -not $snapped) { Save-Screenshot "attempt$attempt-after-submit"; $snapped = $true }
    }
    if ($cert) { break }

    Write-Warning "No certificate mounted $LoginTimeoutSeconds s after attempt $attempt."
    Save-Screenshot "attempt$attempt-timeout"
    Write-WindowReport "attempt$attempt-timeout"

    if ($attempt -lt $MaxLoginAttempts) {
        # Clear a possible error box ("Invalid user name or token") and
        # re-open the login window if the client dropped it.
        $found = @(Get-SimplySignWindow)
        if ($found.Count -gt 0) {
            Set-WindowFocus -Process $found[0]
            Send-Keys '{ENTER}' 500
            Send-Keys '{ESC}' 1000
        }
        if (@(Get-SimplySignWindow).Count -eq 0) {
            Start-Process -FilePath $appPath | Out-Null
            Start-Sleep -Seconds 3
        }
        # Give the next attempt a fresh code.
        Start-Sleep -Seconds ((Get-TotpSecondsRemaining -Period $otp.Period) + 1)
    }
}
[Array]::Clear($key, 0, $key.Length)

# --- Final grace period for a slow mount ------------------------------------------
if (-not $cert) {
    $deadline = (Get-Date).AddSeconds($CertTimeoutSeconds)
    while (-not $cert -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        $cert = Find-CertumCertificate -Thumbprint $env:CERTUM_CERT_THUMBPRINT
    }
}
if (-not $cert) {
    Save-Screenshot 'failure'
    Write-WindowReport 'failure'
    Write-Host 'Certificates currently in Cert:\CurrentUser\My:'
    Get-ChildItem Cert:\CurrentUser\My | Format-Table Thumbprint, HasPrivateKey, Subject -AutoSize | Out-String | Write-Host
    throw "SimplySign Desktop did not mount a usable Certum code-signing certificate. See the simplysign-diagnostics artifact ($diagDir)."
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
