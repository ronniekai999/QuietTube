function Get-QuietTubeHostKeys {
    param([string]$HostName)
    @(
        ('HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\' + $HostName)
        ('HKCU:\Software\Google\Chrome\NativeMessagingHosts\' + $HostName)
    )
}

function Get-QuietTubeStartupCommand {
    param([Parameter(Mandatory=$true)][string]$InstallRoot)
    return ('"' + (Join-Path $InstallRoot 'bin\QuietTube.exe') + '" --background')
}

function New-QuietTubeRegistryKey {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (!$Path.StartsWith('HKCU:\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Expected a per-user registry key.' }
    # CreateSubKey opens an existing key without clearing its values or children.
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($Path.Substring(6))
    if ($null -eq $key) { throw ('Could not open registry key: ' + $Path) }
    $key.Close()
}

function Remove-QuietTubeRegistryDefaultValue {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (!$Path.StartsWith('HKCU:\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Expected a per-user registry key.' }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($Path.Substring(6), $true)
    if ($null -ne $key) { try { $key.DeleteValue('', $false) } finally { $key.Close() } }
}

function Assert-QuietTubeOwnedInstallation {
    param([Parameter(Mandatory=$true)][string]$InstallRoot,
          [Parameter(Mandatory=$true)][string]$ExtensionId,
          [switch]$AllowMissing)
    if (!(Test-Path -LiteralPath $InstallRoot)) {
        if ($AllowMissing) { return $false }
        throw 'QuietTube installation is missing.'
    }
    $rootItem = Get-Item -LiteralPath $InstallRoot -Force
    if (!$rootItem.PSIsContainer -or ($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'QuietTube installation must be an ordinary directory.' }
    $markerPath = Join-Path $InstallRoot 'quiettube-install.json'
    if (!(Test-Path -LiteralPath $markerPath -PathType Leaf)) { throw 'An unrecognized QuietTube folder already exists. Move it aside before installing; no files were changed.' }
    $markerItem = Get-Item -LiteralPath $markerPath -Force
    if ($markerItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'QuietTube installation marker must be an ordinary file.' }
    try {
        $markerText = Get-Content -LiteralPath $markerPath -Raw
        # PowerShell's JSON command enumerates top-level arrays; reject them
        # before conversion, including a one-item array which appears scalar.
        if (!$markerText.TrimStart().StartsWith('{', [StringComparison]::Ordinal)) { throw 'Expected a marker object.' }
        $marker = $markerText | ConvertFrom-Json
    }
    catch { throw 'QuietTube installation marker is invalid. Preserve this folder for repair.' }
    if ($marker -isnot [PSCustomObject] -or ($marker.schemaVersion -isnot [int] -and $marker.schemaVersion -isnot [long]) -or
        $marker.schemaVersion -ne 1 -or $marker.productId -isnot [string] -or $marker.extensionId -isnot [string] -or
        $marker.productId -cne 'com.quiettube.companion' -or $marker.extensionId -cne $ExtensionId) { throw 'This folder does not belong to this QuietTube installation. No files were changed.' }
    # Do not traverse or delete junctions/symlinks inside an owned installation.
    $directories = New-Object 'System.Collections.Generic.Queue[string]'
    $directories.Enqueue($rootItem.FullName)
    while ($directories.Count -gt 0) {
        foreach ($item in (Get-ChildItem -LiteralPath $directories.Dequeue() -Force)) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'QuietTube installation contains a linked file or directory. Preserve it for repair.' }
            if ($item.PSIsContainer) { $directories.Enqueue($item.FullName) }
        }
    }
    return $true
}

function Enter-QuietTubeInstallLock {
    param([Parameter(Mandatory=$true)][string]$InstallRoot)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $digest = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($InstallRoot).ToUpperInvariant()))).Replace('-', '') }
    finally { $hash.Dispose() }
    $mutex = New-Object Threading.Mutex($false, ('QuietTube.Install.' + $digest.Substring(0, 24)))
    try {
        try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (!$acquired) { throw 'Another QuietTube setup or uninstall is running. Wait for it to finish.' }
        return $mutex
    }
    catch { $mutex.Dispose(); throw }
}

function Assert-QuietTubePackage {
    param([Parameter(Mandatory=$true)][string]$SourceRoot)
    $root = [IO.Path]::GetFullPath($SourceRoot)
    $manifestPath = Join-Path $root 'checksums.json'
    if (!(Test-Path -LiteralPath $manifestPath)) { throw 'checksums.json is missing. Extract the complete ZIP.' }
    $entries = @(Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json)
    $required = @('bin/QuietTube.exe', 'bin/QuietTube.Host.exe', 'extension/manifest.json', 'extension-id.txt', 'scripts/Setup.ps1', 'scripts/Install-Helpers.ps1')
    foreach ($name in $required) {
        if (!($entries | Where-Object { $_.path -eq $name })) { throw ('Package manifest omits required file: ' + $name) }
    }
    foreach ($entry in $entries) {
        if ($entry.sha256 -notmatch '^[a-f0-9]{64}$') { throw 'Invalid checksum format.' }
        $file = [IO.Path]::GetFullPath((Join-Path $root $entry.path))
        if (!$file.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { throw 'Invalid package path.' }
        if (!(Test-Path -LiteralPath $file -PathType Leaf)) { throw ('Missing package file: ' + $entry.path) }
        $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $entry.sha256) { throw ('Package integrity check failed: ' + $entry.path) }
    }
    return $entries
}
