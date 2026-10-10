param([string]$WorkDirectory, [string]$ProjectDirectory)
$ErrorActionPreference = 'Stop'
. (Join-Path $ProjectDirectory 'scripts/Install-Helpers.ps1')
$results = New-Object 'System.Collections.Generic.List[string]'
$errorsFound = New-Object 'System.Collections.Generic.List[string]'
function Check([string]$Name, [scriptblock]$Test) {
    try { & $Test; $results.Add($Name) }
    catch { $errorsFound.Add($Name + ': ' + $_.Exception.Message) }
}
function Expect-Failure([scriptblock]$Test) {
    $failed = $false
    try { & $Test | Out-Null } catch { $failed = $true }
    if (!$failed) { throw 'Expected rejection.' }
}
Check 'All installer scripts parse' {
    foreach ($file in (Get-ChildItem (Join-Path $ProjectDirectory 'scripts') -Filter '*.ps1')) {
        $tokens = $null; $parseErrors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
        if ($parseErrors.Count) { throw ($parseErrors | ForEach-Object { $_.Message } | Out-String) }
    }
}
Check 'Edge and Chrome receive two separate registry keys' {
    $keys = @(Get-QuietTubeHostKeys -HostName 'com.quiettube.companion')
    if ($keys.Count -ne 2 -or $keys[0] -ne 'HKCU:\Software\Microsoft\Edge\NativeMessagingHosts\com.quiettube.companion' -or $keys[1] -ne 'HKCU:\Software\Google\Chrome\NativeMessagingHosts\com.quiettube.companion') { throw 'Registry paths are incorrect.' }
}
$fixture = Join-Path $WorkDirectory ('installer-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture -Force | Out-Null
$required = @('bin/QuietTube.exe', 'bin/QuietTube.Host.exe', 'extension/manifest.json', 'extension-id.txt', 'scripts/Setup.ps1', 'scripts/Install-Helpers.ps1')
$entries = @()
foreach ($name in $required) {
    $file = Join-Path $fixture $name
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($file)) -Force | Out-Null
    [IO.File]::WriteAllText($file, ('fixture-' + $name))
    $entries += @{path=$name; sha256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()}
}
$checksums = Join-Path $fixture 'checksums.json'
function Write-FixtureManifest($Entries) { [IO.File]::WriteAllText($checksums, ($Entries | ConvertTo-Json -Depth 4)) }
Write-FixtureManifest $entries
Check 'Valid package files pass integrity validation' {
    $actual = @(Assert-QuietTubePackage -SourceRoot $fixture)
    if ($actual.Count -ne $required.Count) { throw 'Unexpected validated file count.' }
}
Check 'Modified payload is rejected before installation' {
    $file = Join-Path $fixture 'bin/QuietTube.exe'
    $saved = [IO.File]::ReadAllText($file)
    [IO.File]::WriteAllText($file, 'tampered')
    try { Expect-Failure { Assert-QuietTubePackage -SourceRoot $fixture } }
    finally { [IO.File]::WriteAllText($file, $saved) }
}
Check 'Missing executable is rejected' {
    Write-FixtureManifest @($entries | Where-Object { $_.path -ne 'bin/QuietTube.Host.exe' })
    try { Expect-Failure { Assert-QuietTubePackage -SourceRoot $fixture } }
    finally { Write-FixtureManifest $entries }
}
Check 'Package paths cannot escape the extracted folder' {
    Write-FixtureManifest @($entries + @{path='../outside';sha256=('0' * 64)})
    try { Expect-Failure { Assert-QuietTubePackage -SourceRoot $fixture } }
    finally { Write-FixtureManifest $entries }
}
Check 'Native-host JSON is UTF8 without a BOM and uses the exact origin' {
    $id = ([IO.File]::ReadAllText((Join-Path $ProjectDirectory 'extension-id.txt'))).Trim()
    $manifest = @{name='com.quiettube.companion';type='stdio';allowed_origins=@('chrome-extension://' + $id + '/')}
    $file = Join-Path $fixture 'native-host.json'
    [IO.File]::WriteAllText($file, ($manifest | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    $bytes = [IO.File]::ReadAllBytes($file)
    if ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) { throw 'Unexpected BOM.' }
    $parsed = [IO.File]::ReadAllText($file) | ConvertFrom-Json
    if ($parsed.allowed_origins.Count -ne 1 -or $parsed.allowed_origins[0] -ne ('chrome-extension://' + $id + '/')) { throw 'Unexpected allowed origin.' }
}
@{platform='macOS PowerShell 7.6.6';results=@($results.ToArray());errors=@($errorsFound.ToArray());limitation='Windows PowerShell 5.1, Windows registry writes, shortcuts, startup, rollback under Windows file locks, and tray UI are still physical-PC acceptance checks.'} | ConvertTo-Json -Depth 5
if ($errorsFound.Count) { exit 1 }
