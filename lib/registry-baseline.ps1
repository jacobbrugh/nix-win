# ── Registry baseline: capture, track, restore ────────────────────────
# Inlined into the system activate.ps1 (lib/activation.nix reads this file).
#
# For every value declared through dsc.resource."Microsoft.Windows/Registry",
# nix-win records what the value was before it took it over and puts that back
# when the declaration goes away -- by deletion from the configuration or by
# rolling back to a generation that does not declare it. It is nix-darwin's
# `.before-nix-darwin` for registry values.
#
# The record lives OUTSIDE the generations (a JSON file next to the rest of
# nix-win's state), for the reason NixOS keeps /var/lib/nixos/uid-map there:
# no generation can reproduce what a value held before nix-win first wrote it.
#
# Get-NixWinRegistryPlan is pure -- records + declared values + a reader in,
# records + actions out -- so every row of the capture and release tables is
# unit-tested under Linux pwsh (tests/registry-plan.ps1). The registry reads
# and writes are thin wrappers around it.
#
# A value spec is { kind; data }. kind is one of the six kinds the Registry
# resource accepts (String, ExpandString, MultiString, Binary, DWord, QWord),
# or Absent (the value does not exist), or Unknown (no recorded original).

function New-NixWinRegSpec {
    param([Parameter(Mandatory)][string]$Kind, $Data = $null)
    return [pscustomobject]@{ kind = $Kind; data = $Data }
}

# Normalise a spec read from JSON (or declared in the generation artifact) so
# two specs describing the same value compare equal.
function ConvertTo-NixWinRegSpec {
    param($Value)
    if ($null -eq $Value) { return (New-NixWinRegSpec 'Unknown') }
    $nwProps = $Value.PSObject.Properties
    if ($null -ne $nwProps['absent'] -and $nwProps['absent'].Value) {
        return (New-NixWinRegSpec 'Absent')
    }
    $nwKindProp = $nwProps['kind']
    if ($null -eq $nwKindProp -or [string]::IsNullOrEmpty([string]$nwKindProp.Value)) {
        return (New-NixWinRegSpec 'Unknown')
    }
    $nwKind = [string]$nwKindProp.Value
    $nwData = $null
    if ($null -ne $nwProps['data']) { $nwData = $nwProps['data'].Value }
    switch ($nwKind) {
        'String'       { return (New-NixWinRegSpec 'String' ([string]$nwData)) }
        'ExpandString' { return (New-NixWinRegSpec 'ExpandString' ([string]$nwData)) }
        'DWord'        { return (New-NixWinRegSpec 'DWord' ([long]$nwData)) }
        'QWord'        { return (New-NixWinRegSpec 'QWord' ([long]$nwData)) }
        'MultiString'  {
            $nwList = [System.Collections.Generic.List[string]]::new()
            foreach ($nwS in @($nwData)) { if ($null -ne $nwS) { $nwList.Add([string]$nwS) } }
            return (New-NixWinRegSpec 'MultiString' $nwList.ToArray())
        }
        'Binary'       {
            $nwBytes = [System.Collections.Generic.List[int]]::new()
            foreach ($nwB in @($nwData)) { if ($null -ne $nwB) { $nwBytes.Add([int]$nwB) } }
            return (New-NixWinRegSpec 'Binary' $nwBytes.ToArray())
        }
        'Absent'       { return (New-NixWinRegSpec 'Absent') }
        default        { return (New-NixWinRegSpec 'Unknown') }
    }
}

function Test-NixWinRegSpecEqual {
    param($A, $B)
    if ($null -eq $A -or $null -eq $B) { return $false }
    if ([string]$A.kind -cne [string]$B.kind) { return $false }
    switch ([string]$A.kind) {
        'Absent'  { return $true }
        # Two unknowns are not known to be equal.
        'Unknown' { return $false }
        { $_ -in 'String', 'ExpandString' } { return ([string]$A.data -ceq [string]$B.data) }
        { $_ -in 'DWord', 'QWord' }         { return ([long]$A.data -eq [long]$B.data) }
        default {
            $nwX = @($A.data); $nwY = @($B.data)
            if ($nwX.Count -ne $nwY.Count) { return $false }
            for ($nwI = 0; $nwI -lt $nwX.Count; $nwI++) {
                if ([string]$nwX[$nwI] -cne [string]$nwY[$nwI]) { return $false }
            }
            return $true
        }
    }
}

function Format-NixWinRegSpec {
    param($Spec)
    switch ([string]$Spec.kind) {
        'Absent'      { return '(absent)' }
        'Unknown'     { return '(unknown)' }
        'MultiString' { return "[MultiString] $(@($Spec.data) -join ' | ')" }
        'Binary'      {
            $nwHex = foreach ($nwB in @($Spec.data)) { ([int]$nwB).ToString('X2') }
            return "[Binary] $($nwHex -join ' ')"
        }
        default       { return "[$($Spec.kind)] $($Spec.data)" }
    }
}

# HKCU means "whoever runs the switch", so it is pinned to that account's SID
# at capture time and addressed as HKEY_USERS\<SID> from then on. A release
# under a different account then finds the hive it recorded, or finds it not
# loaded and waits -- it never restores into the wrong profile.
function Resolve-NixWinRegPath {
    param([Parameter(Mandatory)][string]$KeyPath, [Parameter(Mandatory)][string]$Sid)
    $nwParts = $KeyPath -split '\\', 2
    $nwRest = if ($nwParts.Count -gt 1) { $nwParts[1].Trim('\') } else { '' }
    switch -Regex ($nwParts[0]) {
        '^(HKLM|HKEY_LOCAL_MACHINE)$' {
            return [pscustomobject]@{ hive = 'HKEY_LOCAL_MACHINE'; subKey = $nwRest }
        }
        '^(HKCU|HKEY_CURRENT_USER)$' {
            $nwSub = if ($nwRest) { "$Sid\$nwRest" } else { $Sid }
            return [pscustomobject]@{ hive = 'HKEY_USERS'; subKey = $nwSub }
        }
        '^(HKU|HKEY_USERS)$' {
            return [pscustomobject]@{ hive = 'HKEY_USERS'; subKey = $nwRest }
        }
    }
    return $null
}

# Registry key and value names are case-insensitive.
function Get-NixWinRegId {
    param([string]$Hive, [string]$SubKey, [string]$ValueName)
    return ("$Hive\$SubKey`n$ValueName").ToLowerInvariant()
}

# The four keys Windows reserves for policy: a value there is absent unless a
# policy put it there, so its pre-nix-win state is known without a capture.
function Test-NixWinRegPolicyKey {
    param([string]$Hive, [string]$SubKey)
    $nwSub = $SubKey
    if ($Hive -eq 'HKEY_USERS') {
        $nwSplit = $SubKey -split '\\', 2
        $nwSub = if ($nwSplit.Count -gt 1) { $nwSplit[1] } else { '' }
    }
    foreach ($nwRoot in 'Software\Policies', 'Software\Microsoft\Windows\CurrentVersion\Policies') {
        if ($nwSub -ieq $nwRoot -or
            $nwSub.StartsWith("$nwRoot\", [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    return $false
}

# A string original that names a PROGRAM which no longer exists is stale (it
# moved or was uninstalled since the original was recorded); restoring it
# would break whatever launches through the value — a service's ImagePath, a
# default shell. Only drive-rooted paths to something executable are checked:
# a data path that does not exist yet is an ordinary setting, not a hazard.
function Test-NixWinRegPathSane {
    param($Spec, [Parameter(Mandatory)][scriptblock]$TestFile)
    if ([string]$Spec.kind -notin 'String', 'ExpandString') { return $true }
    $nwText = [Environment]::ExpandEnvironmentVariables([string]$Spec.data).Trim()
    $nwProgram = $null
    if ($nwText -match '^"([A-Za-z]:\\[^"]+)"') {
        $nwProgram = $Matches[1]
    } elseif ($nwText -match '^([A-Za-z]:\\.+?\.[A-Za-z0-9]{1,4})(?=[\s,;]|$)') {
        # A command line: the program is the prefix up to its extension.
        $nwProgram = $Matches[1]
    }
    if ($null -eq $nwProgram) { return $true }
    if ($nwProgram -notmatch '\.(exe|com|bat|cmd|dll|sys|ps1|msc|scr|cpl|ocx|vbs)$') { return $true }
    $nwOk = @(& $TestFile $nwProgram)
    return ($nwOk.Count -gt 0 -and [bool]$nwOk[-1])
}

# Pure decision function.
#
#   -Records    baseline records: { hive; subKey; valueName; original; applied; createdKey }
#   -Declared   the generation's values: { keyPath; valueName; kind; data } or { …; absent = true }
#   -Originals  declared originals, same shape; consulted only when a value is
#               taken over while it already equals what is declared
#   -ReadLive   { param($hive, $subKey, $valueName) } ->
#               { hiveLoaded; keyExists; value = <spec>; missingFrom }
#   -TestFile   { param($path) } -> bool
#
# Returns { records; actions; messages }:
#   records   what to persist BEFORE any registry write (captured originals,
#             plus every record whose release is still pending)
#   actions   releases to execute: { id; op = 'set' | 'delete'; hive; subKey;
#             valueName; spec; createdKey; text }
#   messages  { level = 'info' | 'warn'; text }
function Get-NixWinRegistryPlan {
    param(
        [object[]]$Records = @(),
        [object[]]$Declared = @(),
        [object[]]$Originals = @(),
        [Parameter(Mandatory)][string]$Sid,
        [Parameter(Mandatory)][scriptblock]$ReadLive,
        [Parameter(Mandatory)][scriptblock]$TestFile
    )

    $nwOut = [System.Collections.Generic.List[object]]::new()
    $nwActions = [System.Collections.Generic.List[object]]::new()
    $nwMessages = [System.Collections.Generic.List[object]]::new()

    $nwById = @{}
    foreach ($nwR in @($Records)) {
        if ($null -eq $nwR) { continue }
        $nwById[(Get-NixWinRegId $nwR.hive $nwR.subKey $nwR.valueName)] = $nwR
    }

    $nwOriginalById = @{}
    foreach ($nwO in @($Originals)) {
        if ($null -eq $nwO) { continue }
        $nwOPath = Resolve-NixWinRegPath -KeyPath ([string]$nwO.keyPath) -Sid $Sid
        if ($null -eq $nwOPath) { continue }
        $nwOSpec = ConvertTo-NixWinRegSpec $nwO
        # An originals entry with no data means "was absent".
        if ($nwOSpec.kind -eq 'Unknown') { $nwOSpec = New-NixWinRegSpec 'Absent' }
        $nwOriginalById[(Get-NixWinRegId $nwOPath.hive $nwOPath.subKey ([string]$nwO.valueName))] = $nwOSpec
    }

    # ── Capture ───────────────────────────────────────────────────────
    $nwDeclaredIds = @{}
    foreach ($nwD in @($Declared)) {
        if ($null -eq $nwD) { continue }
        $nwPath = Resolve-NixWinRegPath -KeyPath ([string]$nwD.keyPath) -Sid $Sid
        $nwLabel = "$($nwD.keyPath)\$($nwD.valueName)"
        if ($null -eq $nwPath) {
            $nwMessages.Add([pscustomobject]@{ level = 'warn'; text = "$nwLabel`: hive is not tracked; its original is not recorded" })
            continue
        }
        $nwName = [string]$nwD.valueName
        $nwId = Get-NixWinRegId $nwPath.hive $nwPath.subKey $nwName
        $nwDesired = ConvertTo-NixWinRegSpec $nwD
        $nwLive = & $ReadLive $nwPath.hive $nwPath.subKey $nwName
        if (-not $nwLive.hiveLoaded) {
            $nwMessages.Add([pscustomobject]@{ level = 'warn'; text = "$nwLabel`: hive is not loaded; its original is not recorded" })
            continue
        }
        $nwDeclaredIds[$nwId] = $true
        $nwLiveSpec = $nwLive.value

        if (-not $nwById.ContainsKey($nwId)) {
            if (-not (Test-NixWinRegSpecEqual $nwLiveSpec $nwDesired)) {
                # The value as it stands before nix-win's first write.
                $nwOriginal = $nwLiveSpec
                $nwWhy = 'captured'
            } elseif ($nwOriginalById.ContainsKey($nwId)) {
                $nwOriginal = $nwOriginalById[$nwId]
                $nwWhy = 'declared original'
            } elseif (Test-NixWinRegPolicyKey $nwPath.hive $nwPath.subKey) {
                $nwOriginal = New-NixWinRegSpec 'Absent'
                $nwWhy = 'policy key'
            } else {
                $nwOriginal = New-NixWinRegSpec 'Unknown'
                $nwWhy = 'already at the declared value'
            }
            $nwCreated = $null
            if (-not $nwLive.keyExists -and $nwDesired.kind -ne 'Absent') { $nwCreated = $nwLive.missingFrom }
            $nwOut.Add([pscustomobject]@{
                hive = $nwPath.hive; subKey = $nwPath.subKey; valueName = $nwName
                original = $nwOriginal; applied = $nwDesired; createdKey = $nwCreated
            })
            $nwMessages.Add([pscustomobject]@{ level = 'info'; text = "$nwLabel`: now tracked, original $(Format-NixWinRegSpec $nwOriginal) ($nwWhy)" })
            continue
        }

        $nwRec = $nwById[$nwId]
        $nwApplied = ConvertTo-NixWinRegSpec $nwRec.applied
        $nwOriginal = ConvertTo-NixWinRegSpec $nwRec.original
        if (-not (Test-NixWinRegSpecEqual $nwLiveSpec $nwApplied) -and
            -not (Test-NixWinRegSpecEqual $nwLiveSpec $nwDesired)) {
            # Something other than nix-win rewrote the value since the last
            # switch. That is now the state the machine has without nix-win.
            $nwMessages.Add([pscustomobject]@{ level = 'info'; text = "$nwLabel`: changed outside nix-win to $(Format-NixWinRegSpec $nwLiveSpec); recorded as its original" })
            $nwOriginal = $nwLiveSpec
        }
        $nwOut.Add([pscustomobject]@{
            hive = $nwRec.hive; subKey = $nwRec.subKey; valueName = $nwRec.valueName
            original = $nwOriginal; applied = $nwDesired; createdKey = $nwRec.createdKey
        })
    }

    # ── Release ───────────────────────────────────────────────────────
    foreach ($nwR in @($Records)) {
        if ($null -eq $nwR) { continue }
        $nwId = Get-NixWinRegId $nwR.hive $nwR.subKey $nwR.valueName
        if ($nwDeclaredIds.ContainsKey($nwId)) { continue }
        $nwLabel = "$($nwR.hive)\$($nwR.subKey)\$($nwR.valueName)"
        $nwApplied = ConvertTo-NixWinRegSpec $nwR.applied
        $nwOriginal = ConvertTo-NixWinRegSpec $nwR.original
        $nwLive = & $ReadLive $nwR.hive $nwR.subKey $nwR.valueName

        if (-not $nwLive.hiveLoaded) {
            $nwOut.Add($nwR)
            $nwMessages.Add([pscustomobject]@{ level = 'warn'; text = "$nwLabel`: no longer declared, but its hive is not loaded; kept for a later switch" })
            continue
        }
        if (-not $nwLive.keyExists) {
            $nwMessages.Add([pscustomobject]@{ level = 'info'; text = "$nwLabel`: no longer declared and its key is gone; nothing to restore" })
            continue
        }
        if (-not (Test-NixWinRegSpecEqual $nwLive.value $nwApplied)) {
            $nwMessages.Add([pscustomobject]@{ level = 'warn'; text = "$nwLabel`: no longer declared, but it holds $(Format-NixWinRegSpec $nwLive.value), not what nix-win wrote; left as is" })
            continue
        }
        if ($nwOriginal.kind -eq 'Unknown') {
            $nwMessages.Add([pscustomobject]@{ level = 'warn'; text = "$nwLabel`: no longer declared and nix-win has no recorded original; left at $(Format-NixWinRegSpec $nwLive.value) (declare one in dsc.registryOriginals, or _exist = false, to remove it)" })
            continue
        }
        if (Test-NixWinRegSpecEqual $nwOriginal $nwApplied) { continue }
        if (-not (Test-NixWinRegPathSane -Spec $nwOriginal -TestFile $TestFile)) {
            $nwMessages.Add([pscustomobject]@{ level = 'warn'; text = "$nwLabel`: no longer declared, but its original $(Format-NixWinRegSpec $nwOriginal) names a file that no longer exists; left as is" })
            continue
        }

        # Pending until executed: persist the record so an interrupted switch
        # still knows the original.
        $nwOut.Add($nwR)
        $nwOp = if ($nwOriginal.kind -eq 'Absent') { 'delete' } else { 'set' }
        $nwActions.Add([pscustomobject]@{
            id = $nwId; op = $nwOp
            hive = $nwR.hive; subKey = $nwR.subKey; valueName = $nwR.valueName
            spec = $nwOriginal; createdKey = $nwR.createdKey
            text = "$nwLabel`: $(Format-NixWinRegSpec $nwApplied) -> $(Format-NixWinRegSpec $nwOriginal)"
        })
    }

    return [pscustomobject]@{
        records  = $nwOut.ToArray()
        actions  = $nwActions.ToArray()
        messages = $nwMessages.ToArray()
    }
}

# ── Registry access (Windows only) ────────────────────────────────────

function Get-NixWinRegRoot {
    param([Parameter(Mandatory)][string]$Hive)
    if ($Hive -eq 'HKEY_USERS') { return [Microsoft.Win32.Registry]::Users }
    return [Microsoft.Win32.Registry]::LocalMachine
}

function Read-NixWinRegLive {
    param([string]$Hive, [string]$SubKey, [string]$ValueName)
    $nwResult = [pscustomobject]@{
        hiveLoaded = $true; keyExists = $false
        value = (New-NixWinRegSpec 'Absent'); missingFrom = $null
    }
    $nwRoot = Get-NixWinRegRoot $Hive
    if ($Hive -eq 'HKEY_USERS') {
        $nwSidKey = $nwRoot.OpenSubKey(($SubKey -split '\\', 2)[0])
        if ($null -eq $nwSidKey) { $nwResult.hiveLoaded = $false; return $nwResult }
        $nwSidKey.Close()
    }
    $nwKey = $nwRoot.OpenSubKey($SubKey)
    if ($null -eq $nwKey) {
        # The topmost key that would have to be created to hold the value.
        $nwAcc = ''
        foreach ($nwSeg in ($SubKey -split '\\')) {
            $nwAcc = if ($nwAcc) { "$nwAcc\$nwSeg" } else { $nwSeg }
            $nwProbe = $nwRoot.OpenSubKey($nwAcc)
            if ($null -eq $nwProbe) { $nwResult.missingFrom = $nwAcc; break }
            $nwProbe.Close()
        }
        return $nwResult
    }
    try {
        $nwResult.keyExists = $true
        $nwMatch = $null
        foreach ($nwN in $nwKey.GetValueNames()) {
            if ($nwN -ieq $ValueName) { $nwMatch = $nwN; break }
        }
        if ($null -eq $nwMatch) { return $nwResult }
        # Read unexpanded, so REG_EXPAND_SZ round-trips with its %VAR%s.
        $nwRaw = $nwKey.GetValue($nwMatch, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        switch ($nwKey.GetValueKind($nwMatch)) {
            ([Microsoft.Win32.RegistryValueKind]::String)       { $nwResult.value = New-NixWinRegSpec 'String' ([string]$nwRaw) }
            ([Microsoft.Win32.RegistryValueKind]::ExpandString) { $nwResult.value = New-NixWinRegSpec 'ExpandString' ([string]$nwRaw) }
            ([Microsoft.Win32.RegistryValueKind]::MultiString)  { $nwResult.value = ConvertTo-NixWinRegSpec ([pscustomobject]@{ kind = 'MultiString'; data = @($nwRaw) }) }
            ([Microsoft.Win32.RegistryValueKind]::Binary)       { $nwResult.value = ConvertTo-NixWinRegSpec ([pscustomobject]@{ kind = 'Binary'; data = @($nwRaw) }) }
            # .NET hands a REG_DWORD back as a signed Int32.
            ([Microsoft.Win32.RegistryValueKind]::DWord)        { $nwResult.value = New-NixWinRegSpec 'DWord' ([long][BitConverter]::ToUInt32([BitConverter]::GetBytes([int]$nwRaw), 0)) }
            ([Microsoft.Win32.RegistryValueKind]::QWord)        { $nwResult.value = New-NixWinRegSpec 'QWord' ([long]$nwRaw) }
            # REG_NONE, REG_LINK and friends: present, but not something
            # nix-win can faithfully put back.
            default                                             { $nwResult.value = New-NixWinRegSpec 'Unknown' }
        }
    } finally {
        $nwKey.Close()
    }
    return $nwResult
}

function Set-NixWinRegValue {
    param([string]$Hive, [string]$SubKey, [string]$ValueName, $Spec)
    $nwKey = (Get-NixWinRegRoot $Hive).CreateSubKey($SubKey)
    try {
        switch ([string]$Spec.kind) {
            'String'       { $nwKey.SetValue($ValueName, [string]$Spec.data, [Microsoft.Win32.RegistryValueKind]::String) }
            'ExpandString' { $nwKey.SetValue($ValueName, [string]$Spec.data, [Microsoft.Win32.RegistryValueKind]::ExpandString) }
            'MultiString'  { $nwKey.SetValue($ValueName, [string[]]@($Spec.data), [Microsoft.Win32.RegistryValueKind]::MultiString) }
            'Binary'       {
                $nwBytes = [byte[]]::new(@($Spec.data).Count)
                for ($nwI = 0; $nwI -lt $nwBytes.Length; $nwI++) { $nwBytes[$nwI] = [byte]@($Spec.data)[$nwI] }
                $nwKey.SetValue($ValueName, $nwBytes, [Microsoft.Win32.RegistryValueKind]::Binary)
            }
            'DWord'        { $nwKey.SetValue($ValueName, [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$Spec.data), 0), [Microsoft.Win32.RegistryValueKind]::DWord) }
            'QWord'        { $nwKey.SetValue($ValueName, [long]$Spec.data, [Microsoft.Win32.RegistryValueKind]::QWord) }
            default        { throw "cannot write a value of kind '$($Spec.kind)'" }
        }
    } finally {
        $nwKey.Close()
    }
}

# Delete a value, then remove the keys nix-win created for it -- from the
# value's key up to CreatedKey -- for as long as they are empty.
function Remove-NixWinRegValue {
    param([string]$Hive, [string]$SubKey, [string]$ValueName, [string]$CreatedKey)
    $nwRoot = Get-NixWinRegRoot $Hive
    $nwKey = $nwRoot.OpenSubKey($SubKey, $true)
    if ($null -eq $nwKey) { return }
    try { $nwKey.DeleteValue($ValueName, $false) } finally { $nwKey.Close() }
    if ([string]::IsNullOrEmpty($CreatedKey)) { return }
    $nwCur = $SubKey
    while ($nwCur -and ($nwCur -ieq $CreatedKey -or
            $nwCur.StartsWith("$CreatedKey\", [System.StringComparison]::OrdinalIgnoreCase))) {
        $nwProbe = $nwRoot.OpenSubKey($nwCur)
        if ($null -eq $nwProbe) { break }
        $nwEmpty = ($nwProbe.ValueCount -eq 0 -and $nwProbe.SubKeyCount -eq 0)
        $nwProbe.Close()
        if (-not $nwEmpty) { break }
        $nwRoot.DeleteSubKey($nwCur, $false)
        $nwIdx = $nwCur.LastIndexOf('\')
        $nwCur = if ($nwIdx -gt 0) { $nwCur.Substring(0, $nwIdx) } else { '' }
    }
}

function Read-NixWinRegBaseline {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $nwRaw = Get-Content -LiteralPath $Path -Raw
    if ([string]::IsNullOrWhiteSpace($nwRaw)) { return }
    $nwDoc = $nwRaw | ConvertFrom-Json
    if ($null -eq $nwDoc -or $null -eq $nwDoc.PSObject.Properties['records']) { return }
    foreach ($nwR in @($nwDoc.records)) { if ($null -ne $nwR) { $nwR } }
}

# Temp file then rename: the baseline must never be half-written, because it
# is the only copy of what the registry held before nix-win.
function Save-NixWinRegBaseline {
    param([Parameter(Mandatory)][string]$Path, [object[]]$Records = @())
    $nwDir = Split-Path -Parent $Path
    if ($nwDir -and -not (Test-Path -LiteralPath $nwDir)) {
        New-Item -ItemType Directory -Path $nwDir -Force | Out-Null
    }
    $nwJson = [ordered]@{ version = 1; records = @($Records) } | ConvertTo-Json -Depth 8
    $nwTmp = "$Path.tmp"
    [System.IO.File]::WriteAllText($nwTmp, $nwJson)
    [System.IO.File]::Move($nwTmp, $Path, $true)
}

# The activation step: capture, persist, then release.
#   -Spec  the generation's dsc/registry-values.json, parsed:
#          { values; originals; keyDeletes }
function Invoke-NixWinRegistryBaseline {
    param($Spec, [Parameter(Mandatory)][string]$BaselinePath)

    $nwDeclared = @(); $nwOriginals = @(); $nwKeyDeletes = @()
    if ($null -ne $Spec) {
        foreach ($nwField in 'values', 'originals', 'keyDeletes') {
            $nwProp = $Spec.PSObject.Properties[$nwField]
            if ($null -eq $nwProp) { continue }
            $nwItems = @(foreach ($nwV in @($nwProp.Value)) { if ($null -ne $nwV) { $nwV } })
            switch ($nwField) {
                'values'     { $nwDeclared = $nwItems }
                'originals'  { $nwOriginals = $nwItems }
                'keyDeletes' { $nwKeyDeletes = $nwItems }
            }
        }
    }
    $nwRecords = @(Read-NixWinRegBaseline -Path $BaselinePath)
    if ($nwDeclared.Count -eq 0 -and $nwRecords.Count -eq 0 -and $nwKeyDeletes.Count -eq 0) { return }

    Write-Host "nix-win: recording registry originals..." -ForegroundColor Cyan
    foreach ($nwKd in $nwKeyDeletes) {
        Write-Host "  $nwKd`: deleting a whole key is not recorded and cannot be restored" -ForegroundColor DarkYellow
    }

    $nwSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $nwPlan = Get-NixWinRegistryPlan -Records $nwRecords -Declared $nwDeclared -Originals $nwOriginals -Sid $nwSid `
        -ReadLive { param($h, $s, $v) Read-NixWinRegLive -Hive $h -SubKey $s -ValueName $v } `
        -TestFile { param($p) Test-Path -LiteralPath $p }

    foreach ($nwM in $nwPlan.messages) {
        $nwColor = if ($nwM.level -eq 'warn') { 'Yellow' } else { 'DarkGray' }
        Write-Host "  $($nwM.text)" -ForegroundColor $nwColor
    }

    # Write-ahead: every original is on disk before the dsc phase overwrites
    # the value it describes, and before any release below.
    Save-NixWinRegBaseline -Path $BaselinePath -Records $nwPlan.records

    if ($nwPlan.actions.Count -eq 0) { return }
    $nwKeep = [System.Collections.Generic.List[object]]::new()
    $nwDone = @{}
    foreach ($nwA in $nwPlan.actions) {
        try {
            if ($nwA.op -eq 'delete') {
                Remove-NixWinRegValue -Hive $nwA.hive -SubKey $nwA.subKey -ValueName $nwA.valueName -CreatedKey ([string]$nwA.createdKey)
            } else {
                Set-NixWinRegValue -Hive $nwA.hive -SubKey $nwA.subKey -ValueName $nwA.valueName -Spec $nwA.spec
            }
            $nwDone[$nwA.id] = $true
            Write-Host "  restored $($nwA.text)" -ForegroundColor Yellow
        } catch {
            # Kept in the baseline, so the next switch tries again.
            $script:NixWinRemovalWarnings.Add("registry $($nwA.text): $($_.Exception.Message)")
            Write-Host "  RESTORE FAILED $($nwA.text): $($_.Exception.Message)" -ForegroundColor Red
        }
    }
    foreach ($nwR in $nwPlan.records) {
        if (-not $nwDone.ContainsKey((Get-NixWinRegId $nwR.hive $nwR.subKey $nwR.valueName))) { $nwKeep.Add($nwR) }
    }
    Save-NixWinRegBaseline -Path $BaselinePath -Records $nwKeep.ToArray()
}
