# Tests for functions inside pkgs/nix-win/nix-win.ps1 that touch NTFS, so
# they run on Windows only (the flake checks parse the CLI; this exercises it):
#   pwsh -NoProfile -File tests/cli-functions.ps1
#
# nix-win.ps1 is a script that runs its command on load, so it cannot be
# dot-sourced. The functions under test are lifted out of its AST instead and
# defined here, against temp directories standing in for the target roots.
param([string]$Cli = (Join-Path $PSScriptRoot '..\pkgs\nix-win\nix-win.ps1'))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

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

$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path $Cli).Path, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw "nix-win.ps1 does not parse: $($errors[0].Message)" }
$wanted = 'Write-Status', 'Sweep-StaleFiles', 'Remove-StaleFiles', 'Get-StateTable', 'Get-StateValue', 'ConvertFrom-ProfileOutput', 'Start-NixWinDeferredTasks'
foreach ($name in $wanted) {
    $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if ($null -eq $fn) { throw "function $name not found in nix-win.ps1" }
    . ([scriptblock]::Create($fn.Extent.Text))
}

$script:StoreStamp = [DateTime]::new(1970, 1, 1, 0, 0, 1, [DateTimeKind]::Utc)
$sandbox = Join-Path ([System.IO.Path]::GetTempPath()) "nix-win-cli-test-$PID"
$roots = @{}
foreach ($r in 'home', 'appdata-local', 'appdata-roaming', 'programdata', 'system-drive') {
    $roots[$r] = Join-Path $sandbox $r
    New-Item -ItemType Directory -Path $roots[$r] -Force | Out-Null
}
# Stands in for the CLI's Resolve-TargetRoot.
function Resolve-TargetRoot { param([string]$Root) return $roots[$Root] }

function New-Deployed {
    param([string]$Path, [switch]$Modified)
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [System.IO.File]::WriteAllText($Path, 'x')
    if (-not $Modified) { [System.IO.File]::SetLastWriteTimeUtc($Path, $script:StoreStamp) }
}
function Key { param([string]$Path) return $Path.Replace('\', '/') }
function Table {
    param([string[]]$Paths)
    $t = [hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($p in $Paths) { $t[(Key $p)] = @{ status = 'managed' } }
    return $t
}

try {
    $home_ = $roots['home']

    Write-Host "Remove-StaleFiles"
    $kept = Join-Path $home_ 'cfg\kept.txt'
    $gone = Join-Path $home_ 'cfg\deep\tree\gone.txt'
    $edited = Join-Path $home_ 'cfg\edited.txt'
    $moved = Join-Path $home_ 'moved\other-scope.txt'
    $cased = Join-Path $home_ 'Case\File.txt'
    New-Deployed $kept; New-Deployed $gone; New-Deployed $edited -Modified; New-Deployed $moved; New-Deployed $cased

    $carry = Remove-StaleFiles `
        -PrevFiles (Table @($kept, $gone, $edited, $moved, $cased, (Join-Path $home_ 'never\existed.txt'))) `
        -NewFiles (Table @($kept, $cased.ToLower())) `
        -ProtectedFiles (Table @($moved)) 3>$null

    Assert-Equal 'still-declared file kept'           $true  (Test-Path -LiteralPath $kept)
    Assert-Equal 'removed file deleted'               $false (Test-Path -LiteralPath $gone)
    Assert-Equal 'its empty parents pruned'           $false (Test-Path -LiteralPath (Join-Path $home_ 'cfg\deep'))
    Assert-Equal 'non-empty parent kept'              $true  (Test-Path -LiteralPath (Join-Path $home_ 'cfg'))
    Assert-Equal 'modified file left in place'        $true  (Test-Path -LiteralPath $edited)
    Assert-Equal 'file the other scope manages kept'  $true  (Test-Path -LiteralPath $moved)
    Assert-Equal 'case-only difference is not stale'  $true  (Test-Path -LiteralPath $cased)
    Assert-Equal 'nothing carried over'               0 $carry.Count

    Write-Host "pruning boundaries"
    $only = Join-Path $home_ 'solo\only.txt'
    New-Deployed $only
    [void](Remove-StaleFiles -PrevFiles (Table @($only)) -NewFiles (Table @()))
    Assert-Equal 'last file gone, directory pruned'   $false (Test-Path -LiteralPath (Join-Path $home_ 'solo'))
    Assert-Equal 'the target root itself survives'    $true  (Test-Path -LiteralPath $home_)

    $nested = Join-Path $roots['appdata-local'] 'tool\bin\t.exe'
    New-Deployed $nested
    [void](Remove-StaleFiles -PrevFiles (Table @($nested)) -NewFiles (Table @()))
    Assert-Equal 'a different root also survives'     $true  (Test-Path -LiteralPath $roots['appdata-local'])

    $hiddenDir = Join-Path $home_ 'withhidden'
    $hiddenGone = Join-Path $hiddenDir 'gone.txt'
    New-Deployed $hiddenGone
    $ini = Join-Path $hiddenDir 'desktop.ini'
    [System.IO.File]::WriteAllText($ini, 'x')
    (Get-Item -LiteralPath $ini -Force).Attributes = 'Hidden'
    [void](Remove-StaleFiles -PrevFiles (Table @($hiddenGone)) -NewFiles (Table @()))
    Assert-Equal 'directory with a hidden file is not pruned' $true (Test-Path -LiteralPath $hiddenDir)

    $target = Join-Path $sandbox 'junction-target'
    New-Item -ItemType Directory -Path $target -Force | Out-Null
    $junction = Join-Path $home_ 'linked'
    New-Item -ItemType Junction -Path $junction -Target $target | Out-Null
    $viaJunction = Join-Path $junction 'f.txt'
    New-Deployed $viaJunction
    [void](Remove-StaleFiles -PrevFiles (Table @($viaJunction)) -NewFiles (Table @()))
    Assert-Equal 'file under a junction deleted'      $false (Test-Path -LiteralPath $viaJunction)
    Assert-Equal 'the junction itself is not pruned'  $true  (Test-Path -LiteralPath $junction)

    Write-Host "locked file"
    $locked = Join-Path $home_ 'busy\held.bin'
    New-Deployed $locked
    $handle = [System.IO.File]::Open($locked, 'Open', 'Read', 'None')
    try {
        $carry = Remove-StaleFiles -PrevFiles (Table @($locked)) -NewFiles (Table @()) 3>$null
    } finally { $handle.Close() }
    Assert-Equal 'locked file survives'               $true (Test-Path -LiteralPath $locked)
    Assert-Equal 'locked file carried for a retry'    'removing' $carry[(Key $locked)].status
    $carry = Remove-StaleFiles -PrevFiles $carry -NewFiles (Table @())
    Assert-Equal 'retry removes it once released'     $false (Test-Path -LiteralPath $locked)

    Write-Host "Get-StateTable / Get-StateValue"
    $state = '{"storePath":"/nix/store/x","files":{"C:/A/b.txt":{"status":"managed"}}}' | ConvertFrom-Json -AsHashtable
    $files = Get-StateTable $state 'files'
    Assert-Equal 'lookup ignores case'                $true ($files.ContainsKey('c:/a/B.TXT'))
    Assert-Equal 'missing table is empty'             0 (Get-StateTable $state 'links').Count
    Assert-Equal 'present value'                      '/nix/store/x' (Get-StateValue $state 'storePath' '')
    Assert-Equal 'missing value falls back'           7 (Get-StateValue $state 'currentGeneration' 7)

    Write-Host "ConvertFrom-ProfileOutput"
    $r = ConvertFrom-ProfileOutput @('switching profile from version 3 to 2', 'nix-win-system-2-link', '/nix/store/abc-win-system')
    Assert-Equal 'generation number'                  2 $r.Generation
    Assert-Equal 'store path'                         '/nix/store/abc-win-system' $r.StorePath
    $threw = $false
    try { [void](ConvertFrom-ProfileOutput @('error: no profile version older than the current (1) exists')) } catch { $threw = $true }
    Assert-Equal 'unparseable output throws'          $true $threw

    Write-Host "Start-NixWinDeferredTasks"
    # Functions shadow the ScheduledTasks cmdlets, so nothing real is touched.
    $script:TaskCalls = [System.Collections.Generic.List[string]]::new()
    function Enable-ScheduledTask { param($TaskPath, $TaskName, $ErrorAction) $script:TaskCalls.Add("enable $TaskName") }
    function Start-ScheduledTask {
        param($TaskPath, $TaskName, $ErrorAction)
        if ($TaskName -eq 'Broken') { throw 'no such task' }
        $script:TaskCalls.Add("start $TaskName")
    }
    # Written the way the scheduledTasks activation step writes it.
    $deferFile = Join-Path $sandbox 'deferred-task-starts.json'
    ConvertTo-Json -InputObject ([string[]]@('First Task', 'Broken', 'Last Task')) | Set-Content -LiteralPath $deferFile -Encoding utf8
    Start-NixWinDeferredTasks -Path $deferFile 3> $null
    Assert-Equal 'each task enabled then started, a failure skipped' `
        'enable First Task|start First Task|enable Broken|enable Last Task|start Last Task' ($script:TaskCalls -join '|')
    Assert-Equal 'the list is consumed'               $false (Test-Path -LiteralPath $deferFile)
    $script:TaskCalls.Clear()
    ConvertTo-Json -InputObject ([string[]]@('Solo')) | Set-Content -LiteralPath $deferFile -Encoding utf8
    Start-NixWinDeferredTasks -Path $deferFile
    Assert-Equal 'a one-task list'                    'enable Solo|start Solo' ($script:TaskCalls -join '|')
    $script:TaskCalls.Clear()
    Start-NixWinDeferredTasks -Path $deferFile
    Assert-Equal 'no list, nothing started'           0 $script:TaskCalls.Count
} finally {
    if (Test-Path -LiteralPath $sandbox) { Remove-Item -LiteralPath $sandbox -Recurse -Force }
}

if ($script:Failed -gt 0) { Write-Host "$script:Failed test(s) failed"; exit 1 }
Write-Host "all cli-functions tests passed"
