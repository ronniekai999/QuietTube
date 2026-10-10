$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Install-Helpers.ps1')
$installRoot = Join-Path $env:LOCALAPPDATA 'QuietTube'
$hostName = 'com.quiettube.companion'
$extensionId = (Get-Content -LiteralPath (Join-Path $PSScriptRoot '../extension-id.txt') -Raw).Trim()
if ($extensionId -notmatch '^[a-p]{32}$') { throw 'Invalid extension ID.' }
$installLock = Enter-QuietTubeInstallLock -InstallRoot $installRoot
try {
    $owned = Assert-QuietTubeOwnedInstallation -InstallRoot $installRoot -ExtensionId $extensionId -AllowMissing
    Write-Host 'Remove QuietTube from each browser in its Extensions page first.'
    $answer = Read-Host 'Remove QuietTube app and its saved protection settings from this Windows account? Type REMOVE'
    if ($answer -cne 'REMOVE') { Write-Host 'No changes made.'; exit 0 }
    foreach ($name in @('QuietTube', 'QuietTube.Host')) {
        Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object {
            $_.Path -and ([IO.Path]::GetFullPath($_.Path)).StartsWith($installRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
        } | Stop-Process -Force
    }
    foreach ($browser in @('Microsoft\Edge', 'Google\Chrome')) {
        $path = 'HKCU:\Software\' + $browser + '\NativeMessagingHosts\' + $hostName
        if (Test-Path $path) {
            $registered = (Get-Item -LiteralPath $path).GetValue('')
            if ($registered -eq (Join-Path $installRoot 'native-host.json')) { Remove-Item -LiteralPath $path }
        }
    }
    $run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
    if (Test-Path $run) {
        $startup = (Get-Item -LiteralPath $run).GetValue('QuietTube')
        if ($startup -eq (Get-QuietTubeStartupCommand -InstallRoot $installRoot)) { Remove-ItemProperty -LiteralPath $run -Name 'QuietTube' }
    }
    $shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'QuietTube.lnk'
    if (Test-Path -LiteralPath $shortcut) {
        $shell = New-Object -ComObject WScript.Shell
        if ($shell.CreateShortcut($shortcut).TargetPath -eq (Join-Path $installRoot 'bin\QuietTube.exe')) { Remove-Item -LiteralPath $shortcut }
    }
    if ($owned) {
        Assert-QuietTubeOwnedInstallation -InstallRoot $installRoot -ExtensionId $extensionId | Out-Null
        Remove-Item -LiteralPath $installRoot -Recurse -Force
    }
    Write-Host 'QuietTube removed. Other browser extensions and Windows settings were left in place.' -ForegroundColor Green
}
finally { $installLock.ReleaseMutex(); $installLock.Dispose() }
