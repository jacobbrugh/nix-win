# Unit tests for the pure planner in lib/registry-baseline.ps1: one case per
# row of the capture and release tables. Platform-neutral — the planner
# never touches the registry — so the `registry-plan` flake check runs it
# under Linux pwsh. On Windows:
#   pwsh -NoProfile -File tests/registry-plan.ps1 -Prelude lib/registry-baseline.ps1
param([Parameter(Mandatory)][string]$Prelude)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

. $Prelude

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

$Sid = 'S-1-5-21-1'
$Hklm = 'HKEY_LOCAL_MACHINE'

# A fake registry: keys that exist, values by id, hives that are not loaded.
function Reset-World {
    $script:Keys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $script:Values = @{}
    $script:Unloaded = @{}
    $script:MissingFiles = @{}
}
function Add-Key {
    param([string]$Hive, [string]$SubKey)
    $acc = ''
    foreach ($seg in ($SubKey -split '\\')) {
        $acc = if ($acc) { "$acc\$seg" } else { $seg }
        [void]$script:Keys.Add("$Hive\$acc")
    }
}
function Set-Live {
    param([string]$Hive, [string]$SubKey, [string]$Name, [string]$Kind, $Data)
    Add-Key $Hive $SubKey
    $script:Values[(Get-NixWinRegId $Hive $SubKey $Name)] = New-NixWinRegSpec $Kind $Data
}
$ReadLive = {
    param($h, $s, $v)
    $r = [pscustomobject]@{ hiveLoaded = $true; keyExists = $false; value = (New-NixWinRegSpec 'Absent'); missingFrom = $null }
    if ($h -eq 'HKEY_USERS' -and $script:Unloaded.ContainsKey(($s -split '\\', 2)[0])) { $r.hiveLoaded = $false; return $r }
    if (-not $script:Keys.Contains("$h\$s")) {
        $acc = ''
        foreach ($seg in ($s -split '\\')) {
            $acc = if ($acc) { "$acc\$seg" } else { $seg }
            if (-not $script:Keys.Contains("$h\$acc")) { $r.missingFrom = $acc; break }
        }
        return $r
    }
    $r.keyExists = $true
    $id = Get-NixWinRegId $h $s $v
    if ($script:Values.ContainsKey($id)) { $r.value = $script:Values[$id] }
    return $r
}
$TestFile = { param($p) -not $script:MissingFiles.ContainsKey($p) }

function Plan {
    param([object[]]$Records = @(), [object[]]$Declared = @(), [object[]]$Originals = @())
    return Get-NixWinRegistryPlan -Records $Records -Declared $Declared -Originals $Originals `
        -Sid $Sid -ReadLive $ReadLive -TestFile $TestFile
}
function Decl {
    param([string]$KeyPath, [string]$Name, [string]$Kind, $Data)
    return [pscustomobject]@{ keyPath = $KeyPath; valueName = $Name; kind = $Kind; data = $Data }
}
function DeclAbsent {
    param([string]$KeyPath, [string]$Name)
    return [pscustomobject]@{ keyPath = $KeyPath; valueName = $Name; absent = $true }
}
function Rec {
    param([string]$Hive, [string]$SubKey, [string]$Name, $Original, $Applied, $CreatedKey = $null)
    return [pscustomobject]@{ hive = $Hive; subKey = $SubKey; valueName = $Name; original = $Original; applied = $Applied; createdKey = $CreatedKey }
}
function Show { param($Spec) return (Format-NixWinRegSpec (ConvertTo-NixWinRegSpec $Spec)) }
function Warns { param($Plan) return @($Plan.messages | ForEach-Object { if ($_.level -eq 'warn') { $_ } }).Count }

Write-Host "spec equality"
Assert-Equal 'DWord equal'           $true  (Test-NixWinRegSpecEqual (New-NixWinRegSpec 'DWord' 1) (New-NixWinRegSpec 'DWord' 1))
Assert-Equal 'DWord differs'         $false (Test-NixWinRegSpecEqual (New-NixWinRegSpec 'DWord' 1) (New-NixWinRegSpec 'DWord' 0))
Assert-Equal 'kind differs'          $false (Test-NixWinRegSpecEqual (New-NixWinRegSpec 'String' 'a') (New-NixWinRegSpec 'ExpandString' 'a'))
Assert-Equal 'string case matters'   $false (Test-NixWinRegSpecEqual (New-NixWinRegSpec 'String' 'a') (New-NixWinRegSpec 'String' 'A'))
Assert-Equal 'binary equal'          $true  (Test-NixWinRegSpecEqual (New-NixWinRegSpec 'Binary' @(1, 2)) (New-NixWinRegSpec 'Binary' @(1, 2)))
Assert-Equal 'binary length differs' $false (Test-NixWinRegSpecEqual (New-NixWinRegSpec 'Binary' @(1, 2)) (New-NixWinRegSpec 'Binary' @(1)))
Assert-Equal 'multistring equal'     $true  (Test-NixWinRegSpecEqual (New-NixWinRegSpec 'MultiString' @('a')) (New-NixWinRegSpec 'MultiString' @('a')))
Assert-Equal 'absent equals absent'  $true  (Test-NixWinRegSpecEqual (New-NixWinRegSpec 'Absent') (New-NixWinRegSpec 'Absent'))
Assert-Equal 'unknown never equal'   $false (Test-NixWinRegSpecEqual (New-NixWinRegSpec 'Unknown') (New-NixWinRegSpec 'Unknown'))

Write-Host "path resolution"
Assert-Equal 'HKLM' 'HKEY_LOCAL_MACHINE|SOFTWARE\X' (& { $p = Resolve-NixWinRegPath -KeyPath 'HKLM\SOFTWARE\X' -Sid $Sid; "$($p.hive)|$($p.subKey)" })
Assert-Equal 'HKCU pinned to the SID' "HKEY_USERS|$Sid\Software\X" (& { $p = Resolve-NixWinRegPath -KeyPath 'HKCU\Software\X' -Sid $Sid; "$($p.hive)|$($p.subKey)" })
Assert-Equal 'unsupported hive' $true ($null -eq (Resolve-NixWinRegPath -KeyPath 'HKCR\.txt' -Sid $Sid))
Assert-Equal 'policy key (HKLM)' $true  (Test-NixWinRegPolicyKey $Hklm 'SOFTWARE\Policies\Vendor')
Assert-Equal 'policy key (HKCU)' $true  (Test-NixWinRegPolicyKey 'HKEY_USERS' "$Sid\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer")
Assert-Equal 'not a policy key'  $false (Test-NixWinRegPolicyKey $Hklm 'SOFTWARE\PoliciesNot\X')

Write-Host "capture"
Reset-World
Set-Live $Hklm 'SOFTWARE\App' 'V' 'String' 'A'
$p = Plan -Declared @(Decl 'HKLM\SOFTWARE\App' 'V' 'String' 'B')
Assert-Equal 'new, live differs: original is the live value' '[String] A' (Show $p.records[0].original)
Assert-Equal 'new: applied is the declared value'            '[String] B' (Show $p.records[0].applied)
Assert-Equal 'new, key existed: no createdKey'               $true ($null -eq $p.records[0].createdKey)
Assert-Equal 'capture plans no registry write'               0 $p.actions.Count

Reset-World
Add-Key $Hklm 'SOFTWARE'
$p = Plan -Declared @(Decl 'HKLM\SOFTWARE\New\Deep' 'V' 'DWord' 1)
Assert-Equal 'new, key missing: original absent'             '(absent)' (Show $p.records[0].original)
Assert-Equal 'new, key missing: createdKey is the top gap'   'SOFTWARE\New' $p.records[0].createdKey

Reset-World
Set-Live $Hklm 'SOFTWARE\App' 'V' 'DWord' 1
$p = Plan -Declared @(Decl 'HKLM\SOFTWARE\App' 'V' 'DWord' 1) -Originals @(Decl 'HKLM\SOFTWARE\App' 'V' 'DWord' 0)
Assert-Equal 'already declared value: declared original used' '[DWord] 0' (Show $p.records[0].original)
$p = Plan -Declared @(Decl 'HKLM\SOFTWARE\App' 'V' 'DWord' 1) -Originals @([pscustomobject]@{ keyPath = 'HKLM\SOFTWARE\App'; valueName = 'V' })
Assert-Equal 'declared original without data means absent'    '(absent)' (Show $p.records[0].original)
$p = Plan -Declared @(Decl 'HKLM\SOFTWARE\App' 'V' 'DWord' 1)
Assert-Equal 'already declared value, no source: unknown'     '(unknown)' (Show $p.records[0].original)

Reset-World
Set-Live $Hklm 'SOFTWARE\Policies\Vendor' 'V' 'String' 'on'
$p = Plan -Declared @(Decl 'HKLM\SOFTWARE\Policies\Vendor' 'V' 'String' 'on')
Assert-Equal 'policy key: original absent'                    '(absent)' (Show $p.records[0].original)

Reset-World
Set-Live $Hklm 'SOFTWARE\App' 'V' 'String' 'A'
$p = Plan -Declared @(Decl 'HKLM\SOFTWARE\App' 'V' 'String' 'B') -Originals @(Decl 'HKLM\SOFTWARE\App' 'V' 'String' 'Z')
Assert-Equal 'a live capture beats a declared original'       '[String] A' (Show $p.records[0].original)

Reset-World
Set-Live $Hklm 'SOFTWARE\App' 'V' 'String' 'C'
$rec = Rec $Hklm 'SOFTWARE\App' 'V' (New-NixWinRegSpec 'String' 'A') (New-NixWinRegSpec 'String' 'B')
$p = Plan -Records @($rec) -Declared @(Decl 'HKLM\SOFTWARE\App' 'V' 'String' 'B')
Assert-Equal 'drift: externally rewritten value becomes the original' '[String] C' (Show $p.records[0].original)

Reset-World
Set-Live $Hklm 'SOFTWARE\App' 'V' 'String' 'B'
$p = Plan -Records @($rec) -Declared @(Decl 'HKLM\SOFTWARE\App' 'V' 'String' 'B2')
Assert-Equal 'no drift: original kept when the declaration changes' '[String] A' (Show $p.records[0].original)
Assert-Equal 'no drift: applied follows the declaration'            '[String] B2' (Show $p.records[0].applied)

Reset-World
Set-Live 'HKEY_USERS' "$Sid\Software\App" 'V' 'DWord' 5
$p = Plan -Declared @(Decl 'HKCU\Software\App' 'V' 'DWord' 6)
Assert-Equal 'HKCU record is stored under the SID' "HKEY_USERS\$Sid\Software\App" "$($p.records[0].hive)\$($p.records[0].subKey)"

Reset-World
$p = Plan -Declared @(Decl 'HKCR\.txt' 'V' 'String' 'x')
Assert-Equal 'unsupported hive: not tracked' 0 $p.records.Count
Assert-Equal 'unsupported hive: warned'      1 (Warns $p)

Reset-World
Set-Live $Hklm 'SOFTWARE\App' 'V' 'String' 'X'
$p = Plan -Declared @(DeclAbsent 'HKLM\SOFTWARE\App' 'V')
Assert-Equal 'declared absent: original is the live value' '[String] X' (Show $p.records[0].original)
Assert-Equal 'declared absent: applied is absent'          '(absent)' (Show $p.records[0].applied)

Write-Host "release"
$A = New-NixWinRegSpec 'ExpandString' '%SystemRoot%\a'
$B = New-NixWinRegSpec 'String' 'B'

Reset-World
Set-Live $Hklm 'SOFTWARE\App' 'V' 'String' 'B'
$p = Plan -Records @(Rec $Hklm 'SOFTWARE\App' 'V' $A $B)
Assert-Equal 'restore: one action'             1 $p.actions.Count
Assert-Equal 'restore: sets the original'      'set|[ExpandString] %SystemRoot%\a' "$($p.actions[0].op)|$(Show $p.actions[0].spec)"
Assert-Equal 'restore: record kept until done' 1 $p.records.Count

$p = Plan -Records @(Rec $Hklm 'SOFTWARE\App' 'V' (New-NixWinRegSpec 'Absent') $B 'SOFTWARE\App')
Assert-Equal 'original absent: delete'              'delete' $p.actions[0].op
Assert-Equal 'original absent: createdKey carried'  'SOFTWARE\App' $p.actions[0].createdKey

Reset-World
Set-Live $Hklm 'SOFTWARE\App' 'V' 'String' 'D'
$p = Plan -Records @(Rec $Hklm 'SOFTWARE\App' 'V' $A $B)
Assert-Equal 'owned elsewhere: no action'      0 $p.actions.Count
Assert-Equal 'owned elsewhere: record dropped' 0 $p.records.Count
Assert-Equal 'owned elsewhere: warned'         1 (Warns $p)

Reset-World
Add-Key $Hklm 'SOFTWARE'
$p = Plan -Records @(Rec $Hklm 'SOFTWARE\Gone' 'V' $A $B)
Assert-Equal 'key gone: no action'             0 $p.actions.Count
Assert-Equal 'key gone: record dropped'        0 $p.records.Count
Assert-Equal 'key gone: not a warning'         0 (Warns $p)

Reset-World
Set-Live $Hklm 'SOFTWARE\App' 'V' 'String' 'B'
$p = Plan -Records @(Rec $Hklm 'SOFTWARE\App' 'V' (New-NixWinRegSpec 'Unknown') $B)
Assert-Equal 'unknown original: no action'      0 $p.actions.Count
Assert-Equal 'unknown original: record dropped' 0 $p.records.Count
Assert-Equal 'unknown original: warned'         1 (Warns $p)

$p = Plan -Records @(Rec $Hklm 'SOFTWARE\App' 'V' $B $B)
Assert-Equal 'original equals applied: nothing to do' '0|0|0' "$($p.actions.Count)|$($p.records.Count)|$(Warns $p)"

Reset-World
Set-Live 'HKEY_USERS' 'S-1-5-21-9\Software\App' 'V' 'String' 'B'
$script:Unloaded['S-1-5-21-9'] = $true
$p = Plan -Records @(Rec 'HKEY_USERS' 'S-1-5-21-9\Software\App' 'V' $A $B)
Assert-Equal 'hive not loaded: no action'   0 $p.actions.Count
Assert-Equal 'hive not loaded: record kept' 1 $p.records.Count
Assert-Equal 'hive not loaded: warned'      1 (Warns $p)

Reset-World
Set-Live $Hklm 'SYSTEM\Svc' 'ImagePath' 'String' 'B'
$stale = New-NixWinRegSpec 'ExpandString' '"C:\Old\svc.exe" --run'
$script:MissingFiles['C:\Old\svc.exe'] = $true
$p = Plan -Records @(Rec $Hklm 'SYSTEM\Svc' 'ImagePath' $stale $B)
Assert-Equal 'stale path original: no action' 0 $p.actions.Count
Assert-Equal 'stale path original: warned'    1 (Warns $p)
$script:MissingFiles.Clear()
$p = Plan -Records @(Rec $Hklm 'SYSTEM\Svc' 'ImagePath' $stale $B)
Assert-Equal 'live path original: restored'   1 $p.actions.Count

Reset-World
$absent = New-NixWinRegSpec 'Absent'
Add-Key $Hklm 'SOFTWARE\App'
$p = Plan -Records @(Rec $Hklm 'SOFTWARE\App' 'V' (New-NixWinRegSpec 'DWord' 7) $absent)
Assert-Equal 'declared-absent released: value restored' 'set|[DWord] 7' "$($p.actions[0].op)|$(Show $p.actions[0].spec)"

Write-Host "path sanity"
$yes = { param($p) $true }
$no = { param($p) $false }
Assert-Equal 'non-path string passes'      $true  (Test-NixWinRegPathSane -Spec (New-NixWinRegSpec 'String' 'always') -TestFile $no)
Assert-Equal 'number passes'               $true  (Test-NixWinRegPathSane -Spec (New-NixWinRegSpec 'DWord' 1) -TestFile $no)
Assert-Equal 'missing data path passes'    $true  (Test-NixWinRegPathSane -Spec (New-NixWinRegSpec 'String' 'C:\ProgramData\app\log.txt') -TestFile $no)
Assert-Equal 'missing directory passes'    $true  (Test-NixWinRegPathSane -Spec (New-NixWinRegSpec 'String' 'D:\dumps') -TestFile $no)
Assert-Equal 'missing unquoted exe fails'  $false (Test-NixWinRegPathSane -Spec (New-NixWinRegSpec 'String' 'C:\Old\svc.exe --run') -TestFile $no)
Assert-Equal 'missing quoted path fails'   $false (Test-NixWinRegPathSane -Spec (New-NixWinRegSpec 'String' '"C:\P F\a.exe" -x') -TestFile $no)
Assert-Equal 'existing quoted path passes' $true  (Test-NixWinRegPathSane -Spec (New-NixWinRegSpec 'String' '"C:\P F\a.exe" -x') -TestFile $yes)
$onlyExe = { param($p) $p -eq 'C:\Program Files\PowerShell\7\pwsh.exe' }
Assert-Equal 'unquoted path with spaces'   $true  (Test-NixWinRegPathSane -Spec (New-NixWinRegSpec 'String' 'C:\Program Files\PowerShell\7\pwsh.exe') -TestFile $onlyExe)
$onlyUserinit = { param($p) $p -eq 'C:\WINDOWS\system32\userinit.exe' }
Assert-Equal 'trailing comma after exe'    $true  (Test-NixWinRegPathSane -Spec (New-NixWinRegSpec 'String' 'C:\WINDOWS\system32\userinit.exe,') -TestFile $onlyUserinit)

Write-Host "persistence round trip"
Reset-World
Set-Live $Hklm 'SOFTWARE\App' 'Bin' 'Binary' @(158, 44, 7)
Set-Live $Hklm 'SOFTWARE\App' 'Multi' 'MultiString' @('one')
Set-Live $Hklm 'SOFTWARE\App' 'Num' 'DWord' 4294967295
$declared = @(
    (Decl 'HKLM\SOFTWARE\App' 'Bin' 'Binary' @(1))
    (Decl 'HKLM\SOFTWARE\App' 'Multi' 'MultiString' @('two', 'three'))
    (Decl 'HKLM\SOFTWARE\App' 'Num' 'DWord' 1)
)
$p = Plan -Declared $declared
$json = [ordered]@{ version = 1; records = @($p.records) } | ConvertTo-Json -Depth 8
$back = @(($json | ConvertFrom-Json).records)
Assert-Equal 'three records survive JSON' 3 $back.Count
# The dsc phase has now written the declared values.
Set-Live $Hklm 'SOFTWARE\App' 'Bin' 'Binary' @(1)
Set-Live $Hklm 'SOFTWARE\App' 'Multi' 'MultiString' @('two', 'three')
Set-Live $Hklm 'SOFTWARE\App' 'Num' 'DWord' 1
$p2 = Plan -Records $back -Declared $declared
$originals = (@($p2.records) | ForEach-Object { Show $_.original }) -join ' ; '
Assert-Equal 'second switch sees no drift' '[Binary] 9E 2C 07 ; [MultiString] one ; [DWord] 4294967295' $originals
$p3 = Plan -Records $back
Assert-Equal 'released after a round trip: three restores' 3 $p3.actions.Count
Assert-Equal 'single-element MultiString restored as a list' '[MultiString] one' (Show $p3.actions[1].spec)

if ($script:Failed -gt 0) { Write-Host "$script:Failed test(s) failed"; exit 1 }
Write-Host "all registry-plan tests passed"
