# Test-only substitutes for Windows registry, shell and process boundaries.
# Production filesystem, checksum, ownership, locking and rollback code still executes.
function Test-Path {
    [CmdletBinding()] param([string]$Path,[string]$LiteralPath,[string]$PathType)
    $value = if ($LiteralPath) { $LiteralPath } else { $Path }
    if ($value.StartsWith('HKCU:')) { return $global:FixtureRegistry.ContainsKey($value) }
    Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
}
function Get-Item {
    [CmdletBinding()] param([string]$Path,[string]$LiteralPath,[switch]$Force)
    $value = if ($LiteralPath) { $LiteralPath } else { $Path }
    if ($value.StartsWith('HKCU:')) {
        $item = [PSCustomObject]@{Values=$global:FixtureRegistry[$value]}
        $item | Add-Member ScriptMethod GetValue { param($name); return $this.Values[$(if ($name -eq '') { 'default' } else { $name })] }
        return $item
    }
    Microsoft.PowerShell.Management\Get-Item @PSBoundParameters
}
function New-Item {
    [CmdletBinding()] param([string]$Path,[string]$ItemType,[switch]$Force)
    if ($Path.StartsWith('HKCU:')) { throw 'Installer tried destructive registry New-Item.' }
    Microsoft.PowerShell.Management\New-Item @PSBoundParameters
}
function New-QuietTubeRegistryKey {
    param([string]$Path)
    if (!$global:FixtureRegistry.ContainsKey($Path)) { $global:FixtureRegistry[$Path]=@{} }
}
function Remove-QuietTubeRegistryDefaultValue {
    param([string]$Path)
    if ($global:FixtureRegistry.ContainsKey($Path)) { $global:FixtureRegistry[$Path].Remove('default') }
}
function Set-Item {
    [CmdletBinding()] param([string]$Path,[string]$LiteralPath,$Value)
    $key = if ($LiteralPath) { $LiteralPath } else { $Path }
    if ($key.StartsWith('HKCU:')) { $global:FixtureRegistry[$key]['default']=$Value; return }
    Microsoft.PowerShell.Management\Set-Item @PSBoundParameters
}
function New-ItemProperty {
    [CmdletBinding()] param([string]$Path,[string]$Name,$Value,[string]$PropertyType,[switch]$Force)
    $global:FixtureRegistry[$Path][$Name]=$Value
}
function Remove-ItemProperty {
    [CmdletBinding()] param([string]$Path,[string]$LiteralPath,[string]$Name)
    $key = if ($LiteralPath) { $LiteralPath } else { $Path }
    $global:FixtureRegistry[$key].Remove($Name)
}
function Remove-Item {
    [CmdletBinding()] param([string]$Path,[string]$LiteralPath,[switch]$Recurse,[switch]$Force)
    $key = if ($LiteralPath) { $LiteralPath } else { $Path }
    if ($key.StartsWith('HKCU:')) { $global:FixtureRegistry.Remove($key); return }
    if ($global:FixtureRollbackFileFailure -and $key -eq (Join-Path $env:LOCALAPPDATA 'QuietTube')) { throw 'Injected locked installation files' }
    Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
}
function Get-Process {
    [CmdletBinding()] param([string[]]$Name)
    if ($global:FixtureCollision -and $Name[0] -eq 'QuietTube') {
        $global:FixtureCollision = $false
        [IO.Directory]::CreateDirectory((Join-Path $env:LOCALAPPDATA 'QuietTube')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $env:LOCALAPPDATA 'QuietTube/foreign.txt'), 'preserve')
    }
}
function Start-Process {
    param([string]$FilePath)
    if ($global:FixtureLaunchFailure) { throw 'Injected launch failure' }
}
function Read-Host { param([string]$Prompt); return 'REMOVE' }
$global:FixtureShell = [PSCustomObject]@{}
$global:FixtureShell | Add-Member ScriptMethod CreateShortcut {
    param($path)
    $target = if ([IO.File]::Exists($path)) { [IO.File]::ReadAllText($path).Split('|')[0] } else { '' }
    $shortcut = [PSCustomObject]@{Path=$path;TargetPath=$target;WorkingDirectory='';IconLocation=''}
    $shortcut | Add-Member ScriptMethod Save {
        [IO.File]::WriteAllText($this.Path, ($this.TargetPath + '|new shortcut'))
        if ($global:FixtureShortcutFailure) { throw 'Injected shortcut failure' }
    }
    return $shortcut
}
