param([string]$WorkDirectory, [string]$ProjectDirectory, [string]$ResultsPath)
$ErrorActionPreference = 'Stop'
if ($env:GITHUB_ACTIONS -ne 'true' -or [Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Run this integration test only on a disposable Windows GitHub Actions runner.' }
$passed = New-Object 'System.Collections.Generic.List[string]'
$failed = New-Object 'System.Collections.Generic.List[string]'
function Expect($Condition, [string]$Message) { if (!$Condition) { throw $Message } }
function Check([string]$Name, [scriptblock]$Test) {
    try { & $Test; $passed.Add($Name) }
    catch { $failed.Add($Name + ': ' + $_.Exception.Message) }
}
$root = Join-Path $WorkDirectory ('native Windows ' + [Guid]::NewGuid().ToString('N'))
$package = Join-Path $root 'package'
$local = Join-Path $root 'local'
$installed = Join-Path $local 'QuietTube'
$originalLocal = $env:LOCALAPPDATA
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$seedName = 'QuietTubeTestOtherApp-' + [Guid]::NewGuid().ToString('N')
$seedValue = 'C:\Other App\app.exe'
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Programs')) 'QuietTube.lnk'
$hostKeys = @('HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\com.quiettube.companion', 'HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.quiettube.companion')
foreach ($key in $hostKeys) { if (Test-Path $key) { throw 'Runner already has a QuietTube registration.' } }
if ((Test-Path $shortcutPath) -or ((Test-Path $run) -and $null -ne (Get-Item $run).GetValue('QuietTube'))) { throw 'Runner already has QuietTube startup or shortcut state.' }
if (Get-Process -Name msedge,chrome -ErrorAction SilentlyContinue) { throw 'Runner must have its browsers closed.' }
foreach ($dir in @('bin','extension','scripts','src','assets','extension-overlay','tests')) {
    New-Item -ItemType Directory -Path (Join-Path $package $dir) -Force | Out-Null
}
New-Item -ItemType Directory -Path $local -Force | Out-Null
foreach ($name in @('Setup.ps1','Uninstall.ps1','Install-Helpers.ps1')) { Copy-Item (Join-Path $ProjectDirectory ('scripts/' + $name)) (Join-Path $package ('scripts/' + $name)) }
Copy-Item (Join-Path $ProjectDirectory 'extension-id.txt') (Join-Path $package 'extension-id.txt')
$id = ([IO.File]::ReadAllText((Join-Path $package 'extension-id.txt'))).Trim()
# A real, short-lived Windows executable exercises Start-Process. This fixture
# tests the installer, not the .NET tray app or the filtering extension.
Add-Type -TypeDefinition 'public class InstallerProcessFixture { public static void Main() {} }' -OutputAssembly (Join-Path $package 'bin/QuietTube.exe') -OutputType WindowsApplication
Copy-Item (Join-Path $package 'bin/QuietTube.exe') (Join-Path $package 'bin/QuietTube.Host.exe')
[IO.File]::WriteAllText((Join-Path $package 'extension/manifest.json'), '{}')
[IO.File]::WriteAllText((Join-Path $package 'START-HERE.html'), '<html><body>Installer fixture</body></html>')
$entries = @(Get-ChildItem $package -File -Recurse | ForEach-Object {
    @{path=$_.FullName.Substring($package.Length + 1).Replace('\','/');sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
})
[IO.File]::WriteAllText((Join-Path $package 'checksums.json'), (ConvertTo-Json -InputObject $entries -Depth 4))
. (Join-Path $package 'scripts/Install-Helpers.ps1')
New-QuietTubeRegistryKey -Path $run
New-ItemProperty -LiteralPath $run -Name $seedName -Value $seedValue -PropertyType String | Out-Null
$env:LOCALAPPDATA = $local
# Avoid opening the instructions page during CI. Executables still use the
# real Windows process API, and registry and WScript.Shell are not substituted.
function Start-Process {
    param([string]$FilePath)
    if (!$FilePath.EndsWith('.html', [StringComparison]::OrdinalIgnoreCase)) { Microsoft.PowerShell.Management\Start-Process -FilePath $FilePath }
}
function Read-Host { param([string]$Prompt); return 'REMOVE' }
try {
    Check 'PowerShell 5.1 reproduces the original ChildPath array error' {
        $legacy = @('[{"path":"a"},{"path":"b"}]' | ConvertFrom-Json)
        $message = $null
        try { Join-Path $package $legacy[0].path | Out-Null } catch { $message = $_.Exception.Message }
        Expect ($legacy.Count -eq 1 -and $message -like '*System.Object[]*ChildPath*') 'The original Windows failure was not reproduced.'
    }
    Check 'Production setup installs successfully with Windows PowerShell 5.1' {
        & (Join-Path $package 'scripts/Setup.ps1') | Out-Host
        Expect ((Test-Path (Join-Path $installed 'bin/QuietTube.exe')) -and (Assert-QuietTubeOwnedInstallation -InstallRoot $installed -ExtensionId $id)) 'Installed payload or ownership marker missing.'
    }
    Check 'Both real browser registry registrations point to the BOM-free native host' {
        $manifestPath = Join-Path $installed 'native-host.json'
        foreach ($key in $hostKeys) { Expect ((Get-Item $key).GetValue('') -eq $manifestPath) 'Native host registration incorrect.' }
        $bytes = [IO.File]::ReadAllBytes($manifestPath)
        Expect (!($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191)) 'Native host JSON has a BOM.'
        $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
        Expect ($manifest.allowed_origins.Count -eq 1 -and $manifest.allowed_origins[0] -eq ('chrome-extension://' + $id + '/')) 'Native host origin incorrect.'
    }
    Check 'Real COM creates the Start menu shortcut with the correct target' {
        $shell = New-Object -ComObject WScript.Shell
        $shortcut = $shell.CreateShortcut($shortcutPath)
        Expect ($shortcut.TargetPath -eq (Join-Path $installed 'bin/QuietTube.exe') -and $shortcut.WorkingDirectory -eq $installed) 'Shortcut target or working directory incorrect.'
    }
    Check 'First install preserves an unrelated real Windows startup value' {
        Expect ((Get-Item $run).GetValue($seedName) -eq $seedValue) 'Unrelated startup value lost.'
        Expect ((Get-Item $run).GetValue('QuietTube') -eq (Get-QuietTubeStartupCommand -InstallRoot $installed)) 'QuietTube startup command incorrect.'
    }
    Check 'A real Windows update preserves saved data and disabled startup' {
        Remove-ItemProperty -LiteralPath $run -Name 'QuietTube'
        New-Item -ItemType Directory -Path (Join-Path $installed 'data') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $installed 'data/settings.json'), 'saved-settings')
        & (Join-Path $package 'scripts/Setup.ps1') | Out-Host
        Expect ([IO.File]::ReadAllText((Join-Path $installed 'data/settings.json')) -eq 'saved-settings') 'Saved settings lost.'
        Expect ($null -eq (Get-Item $run).GetValue('QuietTube') -and (Get-Item $run).GetValue($seedName) -eq $seedValue) 'Startup preference or unrelated value changed.'
    }
    Check 'Production uninstall removes owned Windows state and preserves unrelated startup' {
        & (Join-Path $installed 'scripts/Uninstall.ps1') | Out-Host
        Expect (!(Test-Path $installed) -and !(Test-Path $shortcutPath)) 'Installed files or shortcut remained.'
        foreach ($key in $hostKeys) { Expect (!(Test-Path $key)) 'Native host registration remained.' }
        Expect ((Get-Item $run).GetValue($seedName) -eq $seedValue) 'Unrelated startup value removed.'
    }
    Check 'Damaged package is rejected before Windows installation writes' {
        [IO.File]::WriteAllText((Join-Path $package 'extension/manifest.json'), 'tampered')
        $message = $null
        try { & (Join-Path $package 'scripts/Setup.ps1') | Out-Host } catch { $message = $_.Exception.Message }
        Expect ($message -like '*Package integrity check failed*' -and !(Test-Path $installed) -and !(Test-Path $shortcutPath)) 'Damaged package was accepted or wrote installed state.'
        foreach ($key in $hostKeys) { Expect (!(Test-Path $key)) 'Rejected package wrote registry state.' }
    }
} finally {
    if (Test-Path $installed) { & (Join-Path $installed 'scripts/Uninstall.ps1') | Out-Host }
    Remove-ItemProperty -LiteralPath $run -Name $seedName -ErrorAction SilentlyContinue
    $env:LOCALAPPDATA = $originalLocal
    Remove-Item -LiteralPath $root -Recurse -Force
}
$report = @{testedAtUtc=[DateTime]::UtcNow.ToString('o');platform=([Environment]::OSVersion.ToString() + '; PowerShell ' + $PSVersionTable.PSVersion.ToString());results=@($passed.ToArray());errors=@($failed.ToArray());
    method='Production setup/update/uninstall with real HKCU registry, WScript.Shell shortcuts, and Windows process launch in an isolated fixture.';
    limitation='Fixture executables and extension do not test the tray UI, browser connection, filtering, or reboot.'} | ConvertTo-Json -Depth 5
if ($ResultsPath) { [IO.File]::WriteAllText($ResultsPath, $report, (New-Object Text.UTF8Encoding($false))) }
$report
if ($failed.Count) { exit 1 }
