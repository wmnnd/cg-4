#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads and silently installs Certum's SimplySign Desktop client.

.DESCRIPTION
    SimplySign Desktop is Certum's own client for "Code Signing in the Cloud":
    after login it exposes the cloud-held certificate to Windows as a virtual
    smart card so that signtool can use it. This script fetches the pinned
    MSI from Certum, checks its Authenticode signature (and, once pinned, its
    SHA256), and installs it unattended.

    Environment overrides:
      SIMPLYSIGN_VERSION      e.g. 9.4.4.92 (default below)
      SIMPLYSIGN_MSI_URL      full URL, if Certum changes the path scheme
      SIMPLYSIGN_MSI_SHA256   pin; empty = print the computed hash (see README)
#>
[CmdletBinding()]
param(
    [string]$Version = $(if ($env:SIMPLYSIGN_VERSION) { $env:SIMPLYSIGN_VERSION } else { '9.4.4.92' }),
    [string]$Url     = $env:SIMPLYSIGN_MSI_URL,
    [string]$Sha256  = $env:SIMPLYSIGN_MSI_SHA256
)

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
. (Join-Path $PSScriptRoot 'Common.ps1')

$appPath = 'C:\Program Files\Certum\SimplySign Desktop\SimplySignDesktop.exe'

if (Test-Path -LiteralPath $appPath) {
    $installed = (Get-Item -LiteralPath $appPath).VersionInfo.ProductVersion
    Write-Host "SimplySign Desktop $installed already installed at $appPath"
    Write-ActionsOutput -Name 'app-path' -Value $appPath
    Write-ActionsEnv    -Name 'SIMPLYSIGN_PATH' -Value $appPath
    exit 0
}

if (-not $Url) {
    $Url = "https://files.certum.eu/software/SimplySignDesktop/Windows/$Version/SimplySignDesktop-$Version-64-bit-en.msi"
}

$tempDir = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$msiPath = Join-Path $tempDir "SimplySignDesktop-$Version.msi"
$logPath = Join-Path $tempDir 'simplysign-install.log'

# --- Download (3 attempts) ----------------------------------------------------
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$downloaded = $false
for ($attempt = 1; $attempt -le 3 -and -not $downloaded; $attempt++) {
    try {
        Write-Host "Downloading $Url (attempt $attempt)"
        Invoke-WebRequest -Uri $Url -OutFile $msiPath -UseBasicParsing
        if ((Get-Item -LiteralPath $msiPath).Length -lt 1MB) { throw 'downloaded file is implausibly small' }
        $downloaded = $true
    } catch {
        Write-Warning "Download failed: $($_.Exception.Message)"
        Remove-Item -LiteralPath $msiPath -Force -ErrorAction SilentlyContinue
        if ($attempt -lt 3) { Start-Sleep -Seconds (3 * $attempt) }
    }
}
if (-not $downloaded) { throw "Could not download SimplySign Desktop from $Url" }

# --- Verify what we are about to run as administrator -------------------------
# 1) The MSI must carry a valid Authenticode signature from Certum / Asseco
#    (Certum is Asseco Data Systems' CA brand). This holds even before a hash
#    is pinned, so a tampered download can never be installed.
$sig = Get-AuthenticodeSignature -LiteralPath $msiPath
if ($sig.Status -ne 'Valid') {
    throw "SimplySign MSI Authenticode signature is '$($sig.Status)': $($sig.StatusMessage)"
}
$signer = $sig.SignerCertificate.Subject
if ($signer -notmatch 'Asseco|Certum') {
    throw "SimplySign MSI is signed by an unexpected publisher: $signer"
}
Write-Host "MSI signature OK: $signer"

# 2) Pinned SHA256, with the same bootstrap flow as cmake/PrepareDependencies:
#    empty pin -> print the computed value to paste into the workflow.
$computed = (Get-FileHash -LiteralPath $msiPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($Sha256) {
    if ($computed -ne $Sha256.ToLowerInvariant()) {
        throw "SimplySign MSI SHA256 mismatch: expected $Sha256, got $computed"
    }
    Write-Host 'MSI SHA256 matches the pinned value.'
} else {
    Write-Warning ("No SHA256 pinned for the SimplySign MSI. Computed: $computed`n" +
                   'Set SIMPLYSIGN_MSI_SHA256 in ci.yml to this value to enable verification.')
}

# --- Install -----------------------------------------------------------------
$msiArgs = @('/i', "`"$msiPath`"", '/qn', '/norestart', '/l*v', "`"$logPath`"")
Write-Host "msiexec $($msiArgs -join ' ')"
$proc = Start-Process -FilePath msiexec.exe -ArgumentList $msiArgs -Wait -PassThru -NoNewWindow
if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
    if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Tail 50 | Write-Host }
    throw "msiexec exited with $($proc.ExitCode)"
}

if (-not (Test-Path -LiteralPath $appPath)) {
    $alt = 'C:\Program Files (x86)\Certum\SimplySign Desktop\SimplySignDesktop.exe'
    if (Test-Path -LiteralPath $alt) { $appPath = $alt } else { throw "SimplySign Desktop not found after install (looked for $appPath)" }
}
Remove-Item -LiteralPath $msiPath -Force -ErrorAction SilentlyContinue

$installed = (Get-Item -LiteralPath $appPath).VersionInfo.ProductVersion
Write-Host "Installed SimplySign Desktop $installed at $appPath"
Write-ActionsOutput -Name 'app-path' -Value $appPath
Write-ActionsEnv    -Name 'SIMPLYSIGN_PATH' -Value $appPath
