#Requires -Version 5.1
<#
.SYNOPSIS
    Ends the SimplySign cloud session on this machine.

.DESCRIPTION
    Closes SimplySign Desktop (which unmounts the virtual smart card) and
    removes any Certum certificates it left in the user's personal store.
    Best-effort and never fails: it runs with `if: always()` so a failed
    signing step still tears the session down.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'SilentlyContinue'

$procs = @(Get-Process | Where-Object { $_.ProcessName -like '*SimplySign*' })
if ($procs.Count -gt 0) {
    Write-Host "Closing $($procs.Count) SimplySign process(es)"
    foreach ($p in $procs) { [void]$p.CloseMainWindow() }
    Start-Sleep -Seconds 2
    Get-Process | Where-Object { $_.ProcessName -like '*SimplySign*' } | Stop-Process -Force
} else {
    Write-Host 'No SimplySign processes running.'
}

$certs = @(Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Issuer -like '*Certum*' -or $_.Subject -like '*Certum*' })
if ($certs.Count -gt 0) {
    Write-Host "Removing $($certs.Count) Certum certificate(s) from Cert:\CurrentUser\My"
    $certs | Remove-Item -Force
}

$left = @(Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Issuer -like '*Certum*' })
if ($left.Count -gt 0) {
    Write-Warning "$($left.Count) Certum certificate(s) could not be removed."
} else {
    Write-Host 'SimplySign session closed; no Certum certificates remain in the store.'
}
exit 0
