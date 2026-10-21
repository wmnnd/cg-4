# Shared helpers for the Certum "Code Signing in the Cloud" (SimplySign)
# scripts in this directory. Dot-source it; it defines functions only.
#
# Kept compatible with Windows PowerShell 5.1 as well as PowerShell 7 so the
# same code runs on the CI runner and under pwsh on a developer machine.

Set-StrictMode -Version 2.0

# --- TOTP ------------------------------------------------------------------

function ConvertFrom-Base32 {
    # RFC 4648 Base32 -> bytes. Whitespace, hyphens and '=' padding are ignored.
    param([Parameter(Mandatory = $true)][string]$Text)

    $alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567'
    $clean = ($Text -replace '[\s\-=]', '').ToUpperInvariant()
    if ($clean.Length -eq 0) { throw 'Base32 input is empty.' }

    $bytes  = New-Object System.Collections.Generic.List[byte]
    $buffer = 0
    $bits   = 0
    foreach ($ch in $clean.ToCharArray()) {
        $val = $alphabet.IndexOf($ch)
        if ($val -lt 0) { throw "Invalid Base32 character '$ch'." }
        $buffer = ($buffer -shl 5) -bor $val
        $bits  += 5
        if ($bits -ge 8) {
            $bits -= 8
            $bytes.Add([byte](($buffer -shr $bits) -band 0xFF))
            $buffer = $buffer -band ((1 -shl $bits) - 1)
        }
    }
    return ,$bytes.ToArray()
}

function Get-OtpAuthParameters {
    # Accepts either a bare Base32 seed or a full otpauth://totp/...?secret=...
    # URI (as encoded in the SimplySign enrollment QR code) and returns the
    # seed plus algorithm/digits/period. Explicit -Algorithm/-Digits/-Period
    # apply to bare seeds; a URI's own parameters win.
    param(
        [Parameter(Mandatory = $true)][string]$Secret,
        [string]$Algorithm = 'SHA256',
        [int]$Digits = 6,
        [int]$Period = 30
    )

    $result = @{ Secret = $Secret.Trim(); Algorithm = $Algorithm; Digits = $Digits; Period = $Period }

    if ($result.Secret -match '^otpauth://') {
        $uri   = [System.Uri]$result.Secret
        $query = @{}
        foreach ($pair in ($uri.Query.TrimStart('?') -split '&')) {
            if ($pair -eq '') { continue }
            $kv  = $pair -split '=', 2
            $key = [System.Uri]::UnescapeDataString($kv[0]).ToLowerInvariant()
            $val = ''
            if ($kv.Count -gt 1) { $val = [System.Uri]::UnescapeDataString($kv[1]) }
            $query[$key] = $val
        }
        if (-not $query.ContainsKey('secret') -or $query['secret'] -eq '') {
            throw 'otpauth URI has no secret parameter.'
        }
        $result.Secret = $query['secret']
        if ($query.ContainsKey('algorithm')) { $result.Algorithm = $query['algorithm'] }
        if ($query.ContainsKey('digits'))    { $result.Digits    = [int]$query['digits'] }
        if ($query.ContainsKey('period'))    { $result.Period    = [int]$query['period'] }
    }

    $result.Algorithm = ($result.Algorithm -replace '[\s\-]', '').ToUpperInvariant()
    if (@('SHA1', 'SHA256', 'SHA512') -notcontains $result.Algorithm) {
        throw "Unsupported TOTP algorithm '$($result.Algorithm)' (expected SHA1, SHA256 or SHA512)."
    }
    if ($result.Digits -lt 6 -or $result.Digits -gt 10) { throw "Unsupported TOTP digit count $($result.Digits)." }
    if ($result.Period -lt 1) { throw "Invalid TOTP period $($result.Period)." }
    return $result
}

function Get-TotpCode {
    # RFC 6238 TOTP (RFC 4226 dynamic truncation).
    param(
        [Parameter(Mandatory = $true)][byte[]]$Key,
        [string]$Algorithm = 'SHA256',
        [int]$Digits = 6,
        [int]$Period = 30,
        [long]$UnixTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    )

    $counter = [long][math]::Floor($UnixTime / $Period)
    $msg = [BitConverter]::GetBytes([long]$counter)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($msg) }

    switch ($Algorithm.ToUpperInvariant()) {
        'SHA1'   { $hmac = New-Object System.Security.Cryptography.HMACSHA1   -ArgumentList (,$Key) }
        'SHA256' { $hmac = New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList (,$Key) }
        'SHA512' { $hmac = New-Object System.Security.Cryptography.HMACSHA512 -ArgumentList (,$Key) }
        default  { throw "Unsupported TOTP algorithm '$Algorithm'." }
    }
    try {
        $hash = $hmac.ComputeHash($msg)
    } finally {
        $hmac.Dispose()
    }

    $offset = $hash[$hash.Length - 1] -band 0x0F
    $binary = (([int]$hash[$offset] -band 0x7F) -shl 24) -bor
              ([int]$hash[$offset + 1] -shl 16) -bor
              ([int]$hash[$offset + 2] -shl 8)  -bor
              [int]$hash[$offset + 3]
    $code = [int64]$binary % [int64][math]::Pow(10, $Digits)
    return ([string]$code).PadLeft($Digits, '0')
}

function Get-TotpSecondsRemaining {
    param([int]$Period = 30, [long]$UnixTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds())
    return [int]($Period - ($UnixTime % $Period))
}

# --- Certificate store / signtool -------------------------------------------

function Find-CertumCertificate {
    # The certificate SimplySign Desktop mounts into the user's personal store
    # once logged in. With -Thumbprint the match is exact; otherwise the first
    # Certum-issued code-signing certificate that has a usable private key.
    param([string]$Thumbprint)

    $certs = @(Get-ChildItem -Path Cert:\CurrentUser\My -ErrorAction SilentlyContinue)
    if ($Thumbprint) {
        $wanted = ($Thumbprint -replace '[\s:]', '').ToUpperInvariant()
        return ($certs | Where-Object { $_.Thumbprint -eq $wanted -and $_.HasPrivateKey } | Select-Object -First 1)
    }
    $candidates = @($certs | Where-Object {
        $_.HasPrivateKey -and
        $_.Issuer -like '*Certum*' -and
        @($_.EnhancedKeyUsageList | Where-Object { $_.ObjectId -eq '1.3.6.1.5.5.7.3.3' }).Count -gt 0
    })
    if ($candidates.Count -eq 0) { return $null }
    return $candidates[0]
}

function Find-SignTool {
    # Always the x64 signtool: SimplySign's virtual smart-card driver is
    # 64-bit, so the x86 and arm64 builds cannot reach the key.
    $patterns = @(
        'C:\Program Files (x86)\Windows Kits\10\bin\*\x64\signtool.exe',
        'C:\Program Files\Windows Kits\10\bin\*\x64\signtool.exe'
    )
    foreach ($pattern in $patterns) {
        $hit = @(Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue |
                 Sort-Object -Property FullName -Descending)
        if ($hit.Count -gt 0) { return $hit[0].FullName }
    }
    $cmd = Get-Command signtool.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    throw 'signtool.exe not found. Install the Windows 10/11 SDK (present on GitHub-hosted Windows runners).'
}

# --- GitHub Actions plumbing ----------------------------------------------

function Write-ActionsOutput {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$Value)
    if ($env:GITHUB_OUTPUT) { Add-Content -Path $env:GITHUB_OUTPUT -Value "$Name=$Value" }
}

function Write-ActionsEnv {
    param([Parameter(Mandatory = $true)][string]$Name, [string]$Value)
    if ($env:GITHUB_ENV) { Add-Content -Path $env:GITHUB_ENV -Value "$Name=$Value" }
}
