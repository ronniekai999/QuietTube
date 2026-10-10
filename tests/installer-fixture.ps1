param([string]$ProjectDirectory,[string]$FixtureRoot,[string]$ConfigPath)
$ErrorActionPreference = 'Stop'
$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$package = Join-Path $FixtureRoot 'package'
$local = Join-Path $FixtureRoot 'local'
$programs = Join-Path $FixtureRoot 'programs'
foreach ($p in @($package,$local,$programs)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
foreach ($dir in @('bin','extension','scripts','src','assets','extension-overlay','tests')) { New-Item -ItemType Directory -Path (Join-Path $package $dir) | Out-Null }
Copy-Item (Join-Path $ProjectDirectory 'scripts/Install-Helpers.ps1') (Join-Path $package 'scripts/Install-Helpers.ps1')
$boundary = Join-Path $ProjectDirectory 'tests/installer-boundaries.ps1'
foreach ($name in @('Setup.ps1','Uninstall.ps1')) {
    $source = [IO.File]::ReadAllText((Join-Path $ProjectDirectory ('scripts/' + $name)))
    $load = ". (Join-Path `$PSScriptRoot 'Install-Helpers.ps1')"
    if (!$source.Contains($load)) { throw 'Installer helper entry point changed; review fixture adaptation.' }
    $source = $source.Replace($load, ($load + [Environment]::NewLine + ". '$($boundary.Replace("'","''"))'"))
    $source = $source.Replace("([Environment]::GetFolderPath('Programs'))", '$global:FixturePrograms')
    $source = $source.Replace('New-Object -ComObject WScript.Shell', '$global:FixtureShell')
    [IO.File]::WriteAllText((Join-Path $package ('scripts/' + $name)), $source)
}
$id = ([IO.File]::ReadAllText((Join-Path $ProjectDirectory 'extension-id.txt'))).Trim()
foreach ($file in @('bin/QuietTube.exe','bin/QuietTube.Host.exe','extension/manifest.json','START-HERE.html')) {
    [IO.File]::WriteAllText((Join-Path $package $file), 'new-payload')
}
[IO.File]::WriteAllText((Join-Path $package 'extension-id.txt'), $id)
$entries = @(Get-ChildItem -LiteralPath $package -File -Recurse | ForEach-Object {
    @{path=$_.FullName.Substring($package.Length+1).Replace('\','/');sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
})
[IO.File]::WriteAllText((Join-Path $package 'checksums.json'), ($entries | ConvertTo-Json -Depth 4))
$env:LOCALAPPDATA = $local
$global:FixturePrograms = $programs
$root = Join-Path $local 'QuietTube'
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$global:FixtureRegistry = @{$run=@{OtherApp='C:\OtherApp\app.exe'}}
$global:FixtureCollision = $config.collision -eq $true
$global:FixtureShortcutFailure = $config.shortcutFailure -eq $true
$global:FixtureLaunchFailure = $config.launchFailure -eq $true
$global:FixtureRollbackFileFailure = $config.rollbackFileFailure -eq $true
$hostKeys = @('HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\com.quiettube.companion','HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.quiettube.companion')
if ($config.owned -or $config.unknown -or $config.wrongMarker -or $config.linked) {
    New-Item -ItemType Directory -Path (Join-Path $root 'bin') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $root 'data') | Out-Null
    [IO.File]::WriteAllText((Join-Path $root 'bin/QuietTube.exe'),'old-payload')
    [IO.File]::WriteAllText((Join-Path $root 'data/settings.json'),'saved-off-state')
    if (!$config.unknown) {
        $marker = @{schemaVersion=1;productId='com.quiettube.companion';extensionId=$(if ($config.wrongMarker) {'b'*32} else {$id})}
        if ($config.stringSchema) { $marker.schemaVersion='1' }
        $markerJson = $marker | ConvertTo-Json
        if ($config.arrayMarker) { $markerJson='[' + $markerJson + ']' }
        [IO.File]::WriteAllText((Join-Path $root 'quiettube-install.json'), $markerJson)
    }
    if ($config.linked) {
        [IO.Directory]::CreateDirectory((Join-Path $FixtureRoot 'outside')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $FixtureRoot 'outside/keep.txt'), 'preserve')
        $linkType = if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) { 'Junction' } else { 'SymbolicLink' }
        New-Item -ItemType $linkType -Path (Join-Path $root 'data/link') -Target (Join-Path $FixtureRoot 'outside') | Out-Null
    }
    if ($config.startup -eq 'on') { $global:FixtureRegistry[$run]['QuietTube']='"' + (Join-Path $root 'bin/QuietTube.exe') + '" --background' }
    foreach ($key in $hostKeys) { $global:FixtureRegistry[$key]=@{default=(Join-Path $root 'native-host.json')} }
    [IO.File]::WriteAllText((Join-Path $programs 'QuietTube.lnk'), ((Join-Path $root 'bin/QuietTube.exe') + '|old shortcut'))
}
if ($config.emptyHost) { foreach ($key in $hostKeys) { $global:FixtureRegistry[$key]=@{OtherValue='preserve'} } }
if ($config.blankHostDefault) { foreach ($key in $hostKeys) { $global:FixtureRegistry[$key]=@{default='';OtherValue='preserve'} } }
if ($config.foreignStartup) { $global:FixtureRegistry[$run]['QuietTube']='cmd.exe /c echo "' + (Join-Path $root 'bin/QuietTube.exe') + '" --background' }
$before = $global:FixtureRegistry | ConvertTo-Json -Depth 5 -Compress
$failure = $null
$exitCode = 0
try { & (Join-Path $package ('scripts/' + $config.operation)); $exitCode = $LASTEXITCODE }
catch { $failure = $_.Exception.Message; $exitCode = 1 }
# Scripts containing exit return to this caller; persist observations in either path.
$after = $global:FixtureRegistry | ConvertTo-Json -Depth 5 -Compress
$result = @{failure=$failure;exitCode=$exitCode;registryBefore=$before;registryAfter=$after;registry=$global:FixtureRegistry;
    rootExists=[IO.Directory]::Exists($root);markerExists=[IO.File]::Exists((Join-Path $root 'quiettube-install.json'));
    payload=$(if ([IO.File]::Exists((Join-Path $root 'bin/QuietTube.exe'))) {[IO.File]::ReadAllText((Join-Path $root 'bin/QuietTube.exe'))} else {$null});
    savedData=$(if ([IO.File]::Exists((Join-Path $root 'data/settings.json'))) {[IO.File]::ReadAllText((Join-Path $root 'data/settings.json'))} else {$null});
    shortcut=$(if ([IO.File]::Exists((Join-Path $programs 'QuietTube.lnk'))) {[IO.File]::ReadAllText((Join-Path $programs 'QuietTube.lnk'))} else {$null});
    foreignExists=[IO.File]::Exists((Join-Path $root 'foreign.txt'));outsideExists=[IO.File]::Exists((Join-Path $FixtureRoot 'outside/keep.txt'));
    backupCount=@(Get-ChildItem -LiteralPath $local -Directory -Filter 'QuietTube-backup-*').Count;
    stageCount=@(Get-ChildItem -LiteralPath $local -Directory -Filter 'QuietTube-stage-*').Count}
[IO.File]::WriteAllText((Join-Path $FixtureRoot 'result.json'), ($result | ConvertTo-Json -Depth 6))
