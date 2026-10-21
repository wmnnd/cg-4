#Requires -Version 5.1
<#
.SYNOPSIS
    Self-test for Common.ps1: TOTP against the RFC 6238 reference vectors,
    Base32 decoding, otpauth URI parsing. Runs on any OS with PowerShell.

.EXAMPLE
    pwsh packaging/windows/certum/Test-Common.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Common.ps1')

$failures = 0
function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    if ("$Expected" -eq "$Actual") { Write-Host "  ok    $Name" }
    else { Write-Host "  FAIL  $Name`n        expected: $Expected`n        actual:   $Actual"; $script:failures++ }
}

Write-Host 'Base32'
Assert-Equal 'decodes RFC 4648 vector'  'foobar' ([Text.Encoding]::ASCII.GetString((ConvertFrom-Base32 'MZXW6YTBOI======')))
Assert-Equal 'ignores spaces/hyphens'   'foobar' ([Text.Encoding]::ASCII.GetString((ConvertFrom-Base32 'mzxw 6ytb-oi')))
Assert-Equal 'empty byte array length'  0 ((ConvertFrom-Base32 'A=' ).Length)   # 5 bits -> no full byte

# RFC 6238 Appendix B: 8-digit codes. SHA1 seed is the ASCII "1234567890"
# repeated to 20 bytes, SHA256 to 32 bytes, SHA512 to 64 bytes.
Write-Host 'TOTP (RFC 6238 Appendix B)'
$seed = '12345678901234567890'
$k1   = [Text.Encoding]::ASCII.GetBytes($seed)
$k256 = [Text.Encoding]::ASCII.GetBytes(($seed * 2).Substring(0, 32))
$k512 = [Text.Encoding]::ASCII.GetBytes(($seed * 4).Substring(0, 64))
$vectors = @(
    @{ T = 59;          SHA1 = '94287082'; SHA256 = '46119246'; SHA512 = '90693936' },
    @{ T = 1111111109;  SHA1 = '07081804'; SHA256 = '68084774'; SHA512 = '25091201' },
    @{ T = 1111111111;  SHA1 = '14050471'; SHA256 = '67062674'; SHA512 = '99943326' },
    @{ T = 1234567890;  SHA1 = '89005924'; SHA256 = '91819424'; SHA512 = '93441116' },
    @{ T = 2000000000;  SHA1 = '69279037'; SHA256 = '90698825'; SHA512 = '38618901' },
    @{ T = 20000000000; SHA1 = '65353130'; SHA256 = '77737706'; SHA512 = '47863826' }
)
foreach ($v in $vectors) {
    Assert-Equal "SHA1   T=$($v.T)" $v.SHA1   (Get-TotpCode -Key $k1   -Algorithm SHA1   -Digits 8 -UnixTime $v.T)
    Assert-Equal "SHA256 T=$($v.T)" $v.SHA256 (Get-TotpCode -Key $k256 -Algorithm SHA256 -Digits 8 -UnixTime $v.T)
    Assert-Equal "SHA512 T=$($v.T)" $v.SHA512 (Get-TotpCode -Key $k512 -Algorithm SHA512 -Digits 8 -UnixTime $v.T)
}
Assert-Equal '6-digit truncation' '287082' (Get-TotpCode -Key $k1 -Algorithm SHA1 -Digits 6 -UnixTime 59)
Assert-Equal 'seconds remaining'  1 (Get-TotpSecondsRemaining -Period 30 -UnixTime 59)

Write-Host 'otpauth parsing'
$p = Get-OtpAuthParameters -Secret 'otpauth://totp/Certum:me%40example.com?secret=JBSWY3DPEHPK3PXP&issuer=Certum&algorithm=SHA256&digits=6&period=30'
Assert-Equal 'uri secret'    'JBSWY3DPEHPK3PXP' $p.Secret
Assert-Equal 'uri algorithm' 'SHA256' $p.Algorithm
Assert-Equal 'uri digits'    6  $p.Digits
Assert-Equal 'uri period'    30 $p.Period
$p = Get-OtpAuthParameters -Secret ' jbsw y3dp ehpk 3pxp '
Assert-Equal 'bare seed kept verbatim' 'jbsw y3dp ehpk 3pxp' $p.Secret
Assert-Equal 'bare seed default algo'  'SHA256' $p.Algorithm
$p = Get-OtpAuthParameters -Secret 'JBSWY3DPEHPK3PXP' -Algorithm 'sha-1'
Assert-Equal 'algorithm normalisation' 'SHA1' $p.Algorithm
$threw = $false
try { Get-OtpAuthParameters -Secret 'otpauth://totp/x?issuer=y' | Out-Null } catch { $threw = $true }
Assert-Equal 'uri without secret throws' $true $threw
$threw = $false
try { ConvertFrom-Base32 'not*base32' | Out-Null } catch { $threw = $true }
Assert-Equal 'invalid base32 throws' $true $threw

if ($failures -gt 0) { throw "$failures check(s) failed" }
Write-Host 'All checks passed.'
