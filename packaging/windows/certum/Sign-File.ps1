#Requires -Version 5.1
<#
.SYNOPSIS
    Authenticode-signs one or more files with the mounted Certum certificate
    and verifies the result.

.DESCRIPTION
    Requires a prior Connect-SimplySign.ps1 in the same session (the key lives
    on Certum's HSM and is reachable only through SimplySign's virtual smart
    card). Signs by thumbprint with SHA-256 digests and an RFC 3161 timestamp
    from Certum, then runs `signtool verify /pa` so an unverifiable signature
    fails the build instead of shipping.

.EXAMPLE
    ./Sign-File.ps1 -Path stage/clipgrab/clipgrab.exe, dist/clipgrab-setup.exe
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string[]]$Path,
    [string]$Thumbprint   = $env:CERTUM_CERT_THUMBPRINT,
    [string]$Description  = 'ClipGrab',
    [string]$Url          = 'https://clipgrab.org',
    [string]$TimestampUrl = 'http://time.certum.pl'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

if (-not $Thumbprint) { throw 'No certificate thumbprint: pass -Thumbprint or run Connect-SimplySign.ps1 first.' }
$Thumbprint = ($Thumbprint -replace '[\s:]', '').ToUpperInvariant()
if (-not (Find-CertumCertificate -Thumbprint $Thumbprint)) {
    throw "Certificate $Thumbprint is not in Cert:\CurrentUser\My with a private key. Is SimplySign Desktop logged in?"
}

$signtool = Find-SignTool
Write-Host "Using $signtool"

foreach ($file in $Path) {
    if (-not (Test-Path -LiteralPath $file)) { throw "File not found: $file" }
    $full = (Resolve-Path -LiteralPath $file).Path

    # Timestamping needs Certum's TSA; retry a few times before giving up so a
    # momentary hiccup does not fail an otherwise good release build.
    $signed = $false
    for ($attempt = 1; $attempt -le 3 -and -not $signed; $attempt++) {
        Write-Host "Signing $full (attempt $attempt)"
        & $signtool sign /sha1 $Thumbprint /fd sha256 /tr $TimestampUrl /td sha256 `
            /d $Description /du $Url /v $full
        if ($LASTEXITCODE -eq 0) { $signed = $true }
        elseif ($attempt -lt 3) { Start-Sleep -Seconds (5 * $attempt) }
    }
    if (-not $signed) { throw "signtool sign failed for $full" }

    & $signtool verify /pa /v $full
    if ($LASTEXITCODE -ne 0) { throw "signtool verify failed for $full" }

    $sig = Get-AuthenticodeSignature -LiteralPath $full
    Write-Host "Signed: $full"
    Write-Host "  status:    $($sig.Status)"
    Write-Host "  signer:    $($sig.SignerCertificate.Subject)"
    Write-Host "  timestamp: $(if ($sig.TimeStamperCertificate) { $sig.TimeStamperCertificate.Subject } else { 'none' })"
}
