param([string]$WorkDirectory,[string]$ProjectDirectory)
$ErrorActionPreference = 'Stop'
$passed = New-Object 'System.Collections.Generic.List[string]'
$failed = New-Object 'System.Collections.Generic.List[string]'
$root = Join-Path $WorkDirectory ('installer-regressions-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$pwsh = (Get-Process -Id $PID).Path
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$hostKeys = @('HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\com.quiettube.companion','HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.quiettube.companion')
function Expect($Condition,[string]$Message) { if (!$Condition) { throw $Message } }
function Case([string]$Name,[hashtable]$Config,[scriptblock]$Assertions) {
    $caseRoot = Join-Path $root ([Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $caseRoot | Out-Null
    if (!$Config.ContainsKey('operation')) { $Config['operation']='Setup.ps1' }
    $configPath = Join-Path $caseRoot 'config.json'
    [IO.File]::WriteAllText($configPath, ($Config | ConvertTo-Json))
    try {
        & $pwsh -NoLogo -NoProfile -NonInteractive -File (Join-Path $ProjectDirectory 'tests/installer-fixture.ps1') -ProjectDirectory $ProjectDirectory -FixtureRoot $caseRoot -ConfigPath $configPath *> (Join-Path $caseRoot 'execution.log')
        if (!(Test-Path -LiteralPath (Join-Path $caseRoot 'result.json'))) { throw ('Fixture failed: ' + (Get-Content (Join-Path $caseRoot 'execution.log') -Raw)) }
        $r = Get-Content (Join-Path $caseRoot 'result.json') -Raw | ConvertFrom-Json
        & $Assertions $r
        Expect ($r.stageCount -eq 0) 'Staging files left behind.'
        $passed.Add($Name)
    } catch { $failed.Add($Name + ': ' + $_.Exception.Message) }
}
Case 'First install preserves unrelated startup entries and writes an ownership marker' @{} {
    param($r); Expect (!$r.failure -and $r.payload -eq 'new-payload' -and $r.markerExists -and $r.workflowExists -and $r.macSourceExists) 'Installation failed or packaged source was omitted.'
    Expect ($r.registry.$run.OtherApp -eq 'C:\OtherApp\app.exe') 'Other startup was changed.'
    Expect ($r.registry.$run.QuietTube -like '*--background') 'First install startup missing.'
}
foreach ($choice in @('on','off')) {
    Case ('Update preserves saved data and startup preference ' + $choice) @{owned=$true;startup=$choice} {
        param($r); Expect (!$r.failure -and $r.payload -eq 'new-payload') 'Update failed.'
        Expect ($r.savedData -eq 'saved-off-state') 'Saved settings lost.'
        Expect ($r.registry.$run.OtherApp -eq 'C:\OtherApp\app.exe') 'Other startup lost.'
        Expect ($r.registryBefore -eq $r.registryAfter) 'Registry/startup choices changed on update.'
        Expect ($r.backupCount -eq 0) 'Committed update retained backup.'
    }
}
Case 'Unknown pre-existing folder is rejected without changing files or registry' @{unknown=$true} {
    param($r); Expect ($r.failure -and $r.payload -eq 'old-payload' -and $r.savedData -eq 'saved-off-state') 'Unknown folder changed.'
    Expect ($r.registryBefore -eq $r.registryAfter) 'Registry changed before rejecting folder.'
}
Case 'Wrong ownership marker is rejected without changing files' @{wrongMarker=$true} {
    param($r); Expect ($r.failure -and $r.payload -eq 'old-payload') 'Wrong marker accepted.'
    Expect ($r.registryBefore -eq $r.registryAfter) 'Registry changed.'
}
foreach ($format in @('arrayMarker','stringSchema')) {
    $config = @{owned=$true}; $config[$format]=$true
    Case ('Malformed ownership marker is rejected: ' + $format) $config {
        param($r); Expect ($r.failure -and $r.payload -eq 'old-payload' -and $r.registryBefore -eq $r.registryAfter) 'Malformed marker changed installation.'
    }
}
Case 'A blank pre-existing native host default is preserved and rejected' @{blankHostDefault=$true} {
    param($r); Expect ($r.failure -and !$r.rootExists -and $r.registryBefore -eq $r.registryAfter) 'Different registration was overwritten.'
}
Case 'Linked directories inside an owned installation are rejected before traversal or deletion' @{linked=$true} {
    param($r); Expect ($r.failure -and $r.payload -eq 'old-payload' -and $r.outsideExists) 'Linked folder damaged.'
    Expect ($r.registryBefore -eq $r.registryAfter) 'Registry changed.'
}
Case 'New folder appearing during setup cannot receive or lose staged files' @{collision=$true} {
    param($r); Expect ($r.failure -and $r.foreignExists -and !$r.markerExists -and !$r.payload) 'Collision folder changed.'
    Expect ($r.registryBefore -eq $r.registryAfter) 'Registry changed.'
}
Case 'First-install shortcut failure rolls back app and own registry values' @{shortcutFailure=$true} {
    param($r); Expect ($r.failure -and !$r.rootExists -and !$r.shortcut) 'First install not rolled back.'
    Expect ($r.registryBefore -eq $r.registryAfter) 'Startup/registration rollback failed.'
}
Case 'Update failure restores old files, data, startup and exact shortcut bytes' @{owned=$true;startup='on';shortcutFailure=$true} {
    param($r); Expect ($r.failure -and $r.payload -eq 'old-payload' -and $r.savedData -eq 'saved-off-state') 'Update rollback failed.'
    Expect ($r.shortcut -like '*|old shortcut') 'Shortcut bytes not restored.'
    Expect ($r.registryBefore -eq $r.registryAfter) 'Registry rollback failed.'
}
Case 'Rollback preserves existing native host keys with unrelated values and no default' @{emptyHost=$true;shortcutFailure=$true} {
    param($r); Expect ($r.failure -and $r.registryBefore -eq $r.registryAfter) 'Pre-existing native host key lost.'
}
Case 'A blocked file rollback retains the old backup and still restores registry and shortcut' @{owned=$true;startup='on';shortcutFailure=$true;rollbackFileFailure=$true} {
    param($r); Expect ($r.failure -like '*Rollback needs repair*' -and $r.backupCount -eq 1) 'Recovery backup or repair error missing.'
    Expect ($r.registryBefore -eq $r.registryAfter -and $r.shortcut -like '*|old shortcut') 'One rollback failure skipped other restorations.'
}
Case 'Failure to launch after commit preserves the completed installation' @{launchFailure=$true} {
    param($r); Expect ($r.payload -eq 'new-payload' -and $r.markerExists) 'Committed installation erased.'
    Expect ($r.registry.$run.OtherApp -eq 'C:\OtherApp\app.exe' -and $r.registry.$run.QuietTube) 'Startup lost.'
}
Case 'Owned uninstall removes only owned files, registration, shortcut and startup' @{owned=$true;startup='on';operation='Uninstall.ps1'} {
    param($r); Expect (!$r.failure -and !$r.rootExists -and !$r.shortcut) 'Uninstall failed.'
    Expect ($r.registry.$run.OtherApp -eq 'C:\OtherApp\app.exe' -and !$r.registry.$run.QuietTube) 'Other startup changed.'
    foreach ($key in $hostKeys) { Expect (!$r.registry.$key) 'Owned registration remained.' }
}
Case 'Uninstall rejects an unknown folder before touching registrations or files' @{unknown=$true;startup='on';operation='Uninstall.ps1'} {
    param($r); Expect ($r.failure -and $r.payload -eq 'old-payload') 'Unknown uninstall changed files.'
    Expect ($r.registryBefore -eq $r.registryAfter -and $r.shortcut -like '*|old shortcut') 'Unknown uninstall changed registrations.'
}
Case 'Setup rejects a different startup command containing the expected app path' @{foreignStartup=$true} {
    param($r); Expect ($r.failure -and !$r.rootExists -and $r.registryBefore -eq $r.registryAfter) 'Different startup command was overwritten.'
}
Case 'Uninstall preserves a different startup command containing the expected app path' @{owned=$true;foreignStartup=$true;operation='Uninstall.ps1'} {
    param($r); Expect (!$r.failure -and !$r.rootExists -and $r.registry.$run.QuietTube -like 'cmd.exe*') 'Different startup command was removed.'
}
try {
    . (Join-Path $ProjectDirectory 'scripts/Install-Helpers.ps1')
    $lockRoot = Join-Path $root 'lock-target'
    $lock = Enter-QuietTubeInstallLock -InstallRoot $lockRoot
    try {
        $child = Join-Path $root 'lock-check.ps1'
        [IO.File]::WriteAllText($child, ("param([string]`$Helpers,[string]`$Root)`n. `$Helpers`ntry { `$m=Enter-QuietTubeInstallLock -InstallRoot `$Root; `$m.ReleaseMutex(); `$m.Dispose(); exit 1 } catch { if (`$_.Exception.Message -notlike 'Another QuietTube*') { throw }; exit 0 }"))
        & $pwsh -NoLogo -NoProfile -NonInteractive -File $child -Helpers (Join-Path $ProjectDirectory 'scripts/Install-Helpers.ps1') -Root $lockRoot
        Expect ($LASTEXITCODE -eq 0) 'Concurrent installer entered the same installation.'
    } finally { $lock.ReleaseMutex(); $lock.Dispose() }
    $passed.Add('Concurrent setup/uninstall processes cannot acquire the same installation lock')
} catch { $failed.Add('Install lock: ' + $_.Exception.Message) }
@{testedAtUtc=[DateTime]::UtcNow.ToString('o');version='0.1.2';platform=([Environment]::OSVersion.ToString() + '; PowerShell ' + $PSVersionTable.PSVersion.ToString());results=@($passed.ToArray());errors=@($failed.ToArray());
    method='Production setup/uninstall executed in small isolated filesystem fixtures; Windows registry, shell and process boundaries mocked.';
    limitation='Real registry/COM shortcut writes, tray shutdown and Windows file locks need Windows integration or physical-PC checks.'} | ConvertTo-Json -Depth 5
if ($failed.Count) { exit 1 }
