# Parse every file given with PowerShell's own parser and fail on the first
# syntax error. Run by the `parse-powershell` flake check over the GENERATED
# activation scripts (PowerShell assembled from Nix strings, which nothing
# else ever parses before it runs elevated on a real machine) and over the
# CLI and prelude sources.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$failed = 0
foreach ($path in $args) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors.Count -eq 0) {
        Write-Host "ok   $path"
        continue
    }
    $failed++
    Write-Host "FAIL $path"
    foreach ($e in $errors) {
        Write-Host "  line $($e.Extent.StartLineNumber): $($e.Message)"
    }
}
if ($failed -gt 0) { exit 1 }
