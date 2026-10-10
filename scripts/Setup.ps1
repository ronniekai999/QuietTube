$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Install-Helpers.ps1')
$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$installRoot = Join-Path $env:LOCALAPPDATA 'QuietTube'
$hostName = 'com.quiettube.companion'
$staging = Join-Path $env:LOCALAPPDATA ('QuietTube-stage-' + [Guid]::NewGuid().ToString('N'))
$backup = Join-Path $env:LOCALAPPDATA ('QuietTube-backup-' + [Guid]::NewGuid().ToString('N'))
$promoted = $false
$hadOld = $false
$hostKeys = @(Get-QuietTubeHostKeys -HostName $hostName)
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$startupCommand = Get-QuietTubeStartupCommand -InstallRoot $installRoot
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'QuietTube.lnk'
$oldHostValues = @{}
$oldHostKeysExisted = @{}
$oldStartup = $null
$shortcutCreated = $false
$shortcutPreviouslyExisted = Test-Path -LiteralPath $shortcutPath
$shortcutBackup = $null
$registryTouched = $false
$startupTouched = $false
$committed = $false
$installLock = Enter-QuietTubeInstallLock -InstallRoot $installRoot

function Stop-QuietTubeProcesses {
    foreach ($name in @('QuietTube', 'QuietTube.Host')) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object {
            $_.Path -and ([IO.Path]::GetFullPath($_.Path)).StartsWith($installRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
        } | Stop-Process -Force
    }
}

Write-Host 'QuietTube - Windows 11 private test build' -ForegroundColor Green
Write-Host 'Installs for your Windows account. Administrator access is not required.'
Write-Host 'No proxy, root certificate, browser policy, or DNS setting is installed.'
try {
    Assert-QuietTubePackage -SourceRoot $sourceRoot | Out-Null
    $extensionId = (Get-Content -LiteralPath (Join-Path $sourceRoot 'extension-id.txt') -Raw).Trim()
    if ($extensionId -notmatch '^[a-p]{32}$') { throw 'Invalid extension ID.' }
    $ownedOld = Assert-QuietTubeOwnedInstallation -InstallRoot $installRoot -ExtensionId $extensionId -AllowMissing
    if ($ownedOld -and (Get-Process -Name msedge,chrome -ErrorAction SilentlyContinue)) {
        Write-Host 'Please close Edge and Chrome before updating QuietTube.' -ForegroundColor Yellow
        Read-Host 'Press Enter once both browsers are closed' | Out-Null
        if (Get-Process -Name msedge,chrome -ErrorAction SilentlyContinue) { throw 'Browsers are still running. Close them and run setup again.' }
    }
    foreach ($keyPath in $hostKeys) {
        $oldHostKeysExisted[$keyPath] = Test-Path $keyPath
        $oldHostValues[$keyPath] = if ($oldHostKeysExisted[$keyPath]) { (Get-Item -LiteralPath $keyPath).GetValue('') } else { $null }
        if ($null -ne $oldHostValues[$keyPath] -and $oldHostValues[$keyPath] -ne (Join-Path $installRoot 'native-host.json')) { throw 'A native host with this name has a different registration. No existing registration was changed.' }
    }
    if (Test-Path $run) { $oldStartup = (Get-Item -LiteralPath $run).GetValue('QuietTube') }
    if ($null -ne $oldStartup -and $oldStartup -ne $startupCommand) { throw 'A different QuietTube startup entry already exists. No existing entry was changed.' }
    if (Test-Path -LiteralPath $shortcutPath) {
        $existingShell = New-Object -ComObject WScript.Shell
        if ($existingShell.CreateShortcut($shortcutPath).TargetPath -ne (Join-Path $installRoot 'bin\QuietTube.exe')) { throw 'A different QuietTube shortcut already exists.' }
        $shortcutBackup = [IO.File]::ReadAllBytes($shortcutPath)
    }
    New-Item -ItemType Directory -Path $staging | Out-Null
    foreach ($name in @('bin', 'extension', 'scripts', 'src', 'assets', 'extension-overlay', 'tests')) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot $name) -Destination $staging -Recurse
    }
    # Keep the complete source, notices, and verification receipts together.
    foreach ($file in (Get-ChildItem -LiteralPath $sourceRoot -File -Force)) {
        Copy-Item -LiteralPath $file.FullName -Destination $staging
    }
    $marker = @{schemaVersion=1; productId='com.quiettube.companion'; extensionId=$extensionId}
    [IO.File]::WriteAllText((Join-Path $staging 'quiettube-install.json'), ($marker | ConvertTo-Json), (New-Object Text.UTF8Encoding($false)))
    Stop-QuietTubeProcesses
    # Hold QuietTube writers before copying its state into the staged update.
    if (Test-Path (Join-Path $installRoot 'data')) { Copy-Item -LiteralPath (Join-Path $installRoot 'data') -Destination $staging -Recurse }
    if ($ownedOld) {
        Assert-QuietTubeOwnedInstallation -InstallRoot $installRoot -ExtensionId $extensionId | Out-Null
        [IO.Directory]::Move($installRoot, $backup); $hadOld = $true
    }
    # Directory.Move refuses an existing destination instead of nesting staging
    # inside a folder which appeared after preflight.
    [IO.Directory]::Move($staging, $installRoot)
    $promoted = $true
    $hostManifest = @{
        name = $hostName; description = 'QuietTube Windows companion';
        path = (Join-Path $installRoot 'bin\QuietTube.Host.exe'); type = 'stdio';
        allowed_origins = @('chrome-extension://' + $extensionId + '/')
    }
    $hostManifestPath = Join-Path $installRoot 'native-host.json'
    # PowerShell 5.1's UTF8 writer adds a BOM; use UTF8 without a BOM for Chrome/Edge.
    [IO.File]::WriteAllText($hostManifestPath, ($hostManifest | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    $registryTouched = $true
    foreach ($registryPath in $hostKeys) {
        New-QuietTubeRegistryKey -Path $registryPath
        Set-Item -Path $registryPath -Value $hostManifestPath
    }
    New-QuietTubeRegistryKey -Path $run
    # First installation enables startup. Updates preserve the user's choice.
    if (!$hadOld) {
        $startupTouched = $true
        New-ItemProperty -Path $run -Name 'QuietTube' -Value $startupCommand -PropertyType String -Force | Out-Null
    }
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = Join-Path $installRoot 'bin\QuietTube.exe'
    $shortcut.WorkingDirectory = $installRoot
    $shortcut.IconLocation = $shortcut.TargetPath
    $shortcutCreated = $true
    $shortcut.Save()
    $committed = $true
    # Once committed, a failure to launch the UI must not erase installed files or state.
    if ($hadOld) { Remove-Item -LiteralPath $backup -Recurse -Force -ErrorAction SilentlyContinue }
    Start-Process -FilePath (Join-Path $installRoot 'bin\QuietTube.exe')
    Start-Process -FilePath (Join-Path $installRoot 'START-HERE.html')
    Write-Host ''
    Write-Host 'Windows app installed. Connect Edge once:' -ForegroundColor Green
    Write-Host '1. Open edge://extensions'
    Write-Host '2. Turn on Developer mode, then choose Load unpacked'
    Write-Host ('3. Select this folder: ' + (Join-Path $installRoot 'extension'))
    Write-Host '4. Pin QuietTube, open its popup, and look for Windows app connected'
    Write-Host '5. Reload YouTube and test playback'
    Write-Host ('Extension ID: ' + $extensionId)
}
catch {
    if ($committed) {
        Write-Host ('QuietTube is installed, but it could not launch automatically: ' + $_.Exception.Message) -ForegroundColor Yellow
        Write-Host ('Open this app manually: ' + (Join-Path $installRoot 'bin\QuietTube.exe'))
        exit 1
    }
    $installFailure = $_
    $rollbackErrors = New-Object 'System.Collections.Generic.List[string]'
    function Invoke-QuietTubeRollbackStep([string]$Name, [scriptblock]$Action) {
        try { & $Action } catch { $rollbackErrors.Add($Name + ': ' + $_.Exception.Message) }
    }
    if ($promoted) {
        Invoke-QuietTubeRollbackStep 'Remove staged installation' {
            Stop-QuietTubeProcesses
            Assert-QuietTubeOwnedInstallation -InstallRoot $installRoot -ExtensionId $extensionId | Out-Null
            Remove-Item -LiteralPath $installRoot -Recurse -Force
        }
    }
    if ($hadOld -and (Test-Path $backup)) {
        Invoke-QuietTubeRollbackStep 'Restore old installation' { [IO.Directory]::Move($backup, $installRoot) }
    }
    if ($registryTouched) {
        foreach ($keyPath in $oldHostValues.Keys) {
            Invoke-QuietTubeRollbackStep ('Restore registration ' + $keyPath) {
                if ($null -ne $oldHostValues[$keyPath]) { Set-Item -LiteralPath $keyPath -Value $oldHostValues[$keyPath] }
                elseif ($oldHostKeysExisted[$keyPath]) { Remove-QuietTubeRegistryDefaultValue -Path $keyPath }
                elseif (Test-Path $keyPath) { Remove-Item -LiteralPath $keyPath }
            }
        }
    }
    if ($startupTouched) {
        Invoke-QuietTubeRollbackStep 'Restore startup choice' {
            if ($null -ne $oldStartup) { New-ItemProperty -Path $run -Name 'QuietTube' -Value $oldStartup -PropertyType String -Force | Out-Null }
            elseif ((Test-Path $run) -and $null -ne (Get-Item -LiteralPath $run).GetValue('QuietTube')) { Remove-ItemProperty -LiteralPath $run -Name 'QuietTube' }
        }
    }
    if ($shortcutCreated) {
        Invoke-QuietTubeRollbackStep 'Restore shortcut' {
            if ($shortcutPreviouslyExisted) { [IO.File]::WriteAllBytes($shortcutPath, $shortcutBackup) }
            elseif (Test-Path -LiteralPath $shortcutPath) { Remove-Item -LiteralPath $shortcutPath }
        }
    }
    if ($rollbackErrors.Count) {
        if (Test-Path $backup) { Write-Host ('Old installation and settings preserved at: ' + $backup) -ForegroundColor Yellow }
        throw ('Setup failed: ' + $installFailure.Exception.Message + '. Rollback needs repair: ' + ($rollbackErrors -join '; '))
    }
    Write-Error $installFailure
    exit 1
}
finally {
    try { if (Test-Path $staging) { Remove-Item -LiteralPath $staging -Recurse -Force } }
    finally { $installLock.ReleaseMutex(); $installLock.Dispose() }
}
