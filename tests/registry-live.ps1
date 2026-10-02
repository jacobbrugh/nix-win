# End-to-end test of the registry baseline against the REAL registry, so it
# runs on Windows only:
#   pwsh -NoProfile -File tests/registry-live.ps1
#
# Everything happens under a scratch key, HKCU\Software\nix-win-selftest-<pid>,
# and a baseline file in the temp directory; both are removed afterwards. The
# planner's decisions are covered row by row in registry-plan.ps1 — this
# checks that the reads, writes, kinds and key pruning around it do what the
# plan says on an actual hive.
param([string]$Lib = (Join-Path $PSScriptRoot '..\lib'))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. (Join-Path $Lib 'removal-prelude.ps1')
. (Join-Path $Lib 'registry-baseline.ps1')

$script:Failed = 0
function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    if ("$Expected" -ceq "$Actual") {
        Write-Host "  ok   $Name"
    } else {
        $script:Failed++
        Write-Host "  FAIL $Name`n         expected: $Expected`n         actual:   $Actual"
    }
}

$Sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$Scratch = "Software\nix-win-selftest-$PID"
$Baseline = Join-Path ([System.IO.Path]::GetTempPath()) "nix-win-selftest-$PID.json"

function Live {
    param([string]$SubKey, [string]$Name)
    return (Format-NixWinRegSpec (Read-NixWinRegLive -Hive 'HKEY_USERS' -SubKey "$Sid\$Scratch\$SubKey" -ValueName $Name).value)
}
function KeyExists {
    param([string]$SubKey)
    $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$Scratch\$SubKey")
    if ($null -eq $k) { return $false }
    $k.Close(); return $true
}
# Stands in for the dsc phase, and for anything else writing the value.
function Write-Value {
    param([string]$SubKey, [string]$Name, [string]$Kind, $Data)
    Set-NixWinRegValue -Hive 'HKEY_USERS' -SubKey "$Sid\$Scratch\$SubKey" -ValueName $Name -Spec (New-NixWinRegSpec $Kind $Data)
}
function Decl {
    param([string]$SubKey, [string]$Name, [string]$Kind, $Data)
    return [pscustomobject]@{ keyPath = "HKCU\$Scratch\$SubKey"; valueName = $Name; kind = $Kind; data = $Data }
}
# One activation: baseline step, then "dsc" applies every declared value.
function Switch-To {
    param([object[]]$Values = @(), [object[]]$Originals = @())
    $spec = [pscustomobject]@{ values = @($Values); originals = @($Originals); keyDeletes = @() }
    Invoke-NixWinRegistryBaseline -Spec $spec -BaselinePath $Baseline 6>$null
    foreach ($v in $Values) {
        $sub = ([string]$v.keyPath).Substring("HKCU\$Scratch\".Length)
        Write-Value $sub $v.valueName $v.kind $v.data
    }
}
function RecordCount { return @(Read-NixWinRegBaseline -Path $Baseline).Count }

try {
    [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($Scratch).Close()

    Write-Host "value in a key that does not exist"
    Switch-To -Values @(Decl 'New\Deep' 'V' 'DWord' 1)
    Assert-Equal 'created'                        '[DWord] 1' (Live 'New\Deep' 'V')
    Assert-Equal 'tracked'                        1 (RecordCount)
    Switch-To
    Assert-Equal 'value gone'                     '(absent)' (Live 'New\Deep' 'V')
    Assert-Equal 'keys nix-win created are gone'  $false (KeyExists 'New')
    Assert-Equal 'pre-existing parent survives'   $true ([Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Scratch) -ne $null)
    Assert-Equal 'record released'                0 (RecordCount)

    Write-Host "pre-existing value, every kind"
    Write-Value 'Kinds' 'Expand' 'ExpandString' '%SystemRoot%\x'
    Write-Value 'Kinds' 'Multi' 'MultiString' @('one')
    Write-Value 'Kinds' 'Bin' 'Binary' @(158, 44, 7, 128)
    Write-Value 'Kinds' 'Big' 'DWord' 4294967295
    Write-Value 'Kinds' 'Q' 'QWord' 5000000000
    Write-Value 'Kinds' 'Str' 'String' 'before'
    $all = @(
        (Decl 'Kinds' 'Expand' 'String' 'B')
        (Decl 'Kinds' 'Multi' 'MultiString' @('two', 'three'))
        (Decl 'Kinds' 'Bin' 'Binary' @(1))
        (Decl 'Kinds' 'Big' 'DWord' 1)
        (Decl 'Kinds' 'Q' 'QWord' 1)
        (Decl 'Kinds' 'Str' 'String' 'after')
    )
    Switch-To -Values $all
    Switch-To -Values $all
    Assert-Equal 'declared value applied'          '[String] B' (Live 'Kinds' 'Expand')
    Switch-To
    Assert-Equal 'ExpandString restored unexpanded' '[ExpandString] %SystemRoot%\x' (Live 'Kinds' 'Expand')
    Assert-Equal 'single-element MultiString'       '[MultiString] one' (Live 'Kinds' 'Multi')
    Assert-Equal 'Binary'                           '[Binary] 9E 2C 07 80' (Live 'Kinds' 'Bin')
    Assert-Equal 'DWord above 2^31'                 '[DWord] 4294967295' (Live 'Kinds' 'Big')
    Assert-Equal 'QWord'                            '[QWord] 5000000000' (Live 'Kinds' 'Q')
    Assert-Equal 'String'                           '[String] before' (Live 'Kinds' 'Str')
    Assert-Equal 'key that pre-existed survives'    $true (KeyExists 'Kinds')
    Assert-Equal 'all records released'             0 (RecordCount)

    Write-Host "value rewritten by something else while managed"
    Write-Value 'Drift' 'V' 'String' 'A'
    $d = @(Decl 'Drift' 'V' 'String' 'B')
    Switch-To -Values $d
    Write-Value 'Drift' 'V' 'String' 'C'
    Switch-To -Values $d
    Assert-Equal 're-asserted'                      '[String] B' (Live 'Drift' 'V')
    Switch-To
    Assert-Equal 'restored to the later value'      '[String] C' (Live 'Drift' 'V')

    Write-Host "value owned by something else at release"
    $o = @(Decl 'Owned' 'V' 'String' 'B')
    Switch-To -Values $o
    Write-Value 'Owned' 'V' 'String' 'D'
    Switch-To
    Assert-Equal 'left as found'                    '[String] D' (Live 'Owned' 'V')
    Assert-Equal 'no longer tracked'                0 (RecordCount)

    Write-Host "already at the declared value"
    Write-Value 'Same' 'V' 'DWord' 1
    Switch-To -Values @(Decl 'Same' 'V' 'DWord' 1)
    Switch-To
    Assert-Equal 'no recorded original: left alone' '[DWord] 1' (Live 'Same' 'V')

    Switch-To -Values @(Decl 'Same' 'V' 'DWord' 1) -Originals @(Decl 'Same' 'V' 'DWord' 0)
    Switch-To
    Assert-Equal 'declared original restored'       '[DWord] 0' (Live 'Same' 'V')

    Write-Value 'Same' 'W' 'DWord' 1
    Switch-To -Values @(Decl 'Same' 'W' 'DWord' 1) -Originals @([pscustomobject]@{ keyPath = "HKCU\$Scratch\Same"; valueName = 'W' })
    Switch-To
    Assert-Equal 'declared-absent original: deleted' '(absent)' (Live 'Same' 'W')

    Write-Host "rollback between generations"
    Write-Value 'Roll' 'V' 'String' 'orig'
    $gen1 = @()
    $gen2 = @(Decl 'Roll' 'V' 'String' 'g2')
    Switch-To -Values $gen1
    Switch-To -Values $gen2
    Assert-Equal 'generation 2 applied'             '[String] g2' (Live 'Roll' 'V')
    Switch-To -Values $gen1
    Assert-Equal 'rolled back to generation 1'      '[String] orig' (Live 'Roll' 'V')
    Switch-To -Values $gen2
    Switch-To -Values @(Decl 'Roll' 'V' 'String' 'g3')
    Switch-To -Values $gen2
    Assert-Equal 'rollback to another declaring generation' '[String] g2' (Live 'Roll' 'V')
    Switch-To
    Assert-Equal 'original survives all of that'    '[String] orig' (Live 'Roll' 'V')

    Assert-Equal 'no removal warnings'              0 $script:NixWinRemovalWarnings.Count
} finally {
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($Scratch, $false)
    Remove-Item -LiteralPath $Baseline -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath "$Baseline.tmp" -Force -ErrorAction SilentlyContinue
}

if ($script:Failed -gt 0) { Write-Host "$script:Failed test(s) failed"; exit 1 }
Write-Host "all registry-live tests passed"
