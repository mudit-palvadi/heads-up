<#
.SYNOPSIS
    Builds the Heads Up APK with the size-critical flags applied.

.DESCRIPTION
    Two flags here are load-bearing and easy to forget. Both were added after
    measuring the APK:

      --target-platform android-arm64
        Flutter injects the engine's .so files from the extracted engine
        artifact, which BYPASSES `abiFilters` in build.gradle.kts. Building
        without this flag ships libflutter.so for x86_64 and armeabi-v7a as
        well — 67 MB of code that can never run on the target device.
        Measured: 281.1 MB (with) vs 124.6 MB (arm64-only, release).

      --release
        Debug builds ship Dart as kernel_blob.bin (69 MB) instead of an AOT
        snapshot. The hand-over APK must be a release build.

    R8/minification is deliberately OFF. flutter_secure_storage 11.2.0 depends
    on Tink and ships no consumer ProGuard rules, so minifying risks silently
    breaking the one thing that must never fail: storing the IMAP app
    password. R8 would only shrink the ~27 MB of dex anyway, not the ~120 MB
    of native LiteRT-LM libraries. See README "App size".

.PARAMETER DebugBuild
    Build a debug APK instead. Same size-critical flags still apply.

    Not named -Debug: that is one of PowerShell's built-in common parameters,
    so [CmdletBinding()] already defines it and a script-level switch of the
    same name fails to load at all.

.PARAMETER Analyze
    Print a per-library size breakdown after building.

.EXAMPLE
    ./tool/build_apk.ps1
    ./tool/build_apk.ps1 -DebugBuild -Analyze
#>
[CmdletBinding()]
param(
    [switch]$DebugBuild,
    [switch]$Analyze
)

$ErrorActionPreference = 'Stop'

Set-Location (Join-Path $PSScriptRoot '..')

$mode = if ($DebugBuild) { '--debug' } else { '--release' }
$target = [ordered]@{
    Mode            = $mode
    TargetPlatform  = 'android-arm64 (see tool/build_apk.ps1 header)'
}

Write-Host 'Heads Up build' -ForegroundColor Cyan
foreach ($key in $target.Keys) {
    Write-Host ("  {0,-15} {1}" -f $key, $target[$key])
}

# Not $args: that is an automatic variable in every PowerShell scope.
$flutterArgs = @('build', 'apk', $mode, '--target-platform', 'android-arm64')
if ($Analyze) { $flutterArgs += '--analyze-size' }

& flutter @flutterArgs
if ($LASTEXITCODE -ne 0) {
    throw "flutter build failed with exit code $LASTEXITCODE"
}

$apkName = if ($DebugBuild) { 'app-debug.apk' } else { 'app-release.apk' }
$apkPath = Join-Path 'build\app\outputs\flutter-apk' $apkName

if (-not (Test-Path $apkPath)) {
    throw "Expected APK at $apkPath but it was not produced."
}

$sizeMb = [math]::Round((Get-Item $apkPath).Length / 1MB, 1)
Write-Host ''
Write-Host ("Built {0} ({1} MB)" -f $apkName, $sizeMb) -ForegroundColor Green

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::OpenRead((Resolve-Path $apkPath))
try {
    # Measure bytes per ABI rather than just listing which ones are present.
    # The manifest still declares all three ABIs, and every plugin contributes a
    # couple of tiny JNI stubs to armeabi-v7a/x86_64, so presence alone always
    # looks like a failure. Only the payload size tells you whether
    # --target-platform actually took effect.
    $byAbi = $zip.Entries |
        Where-Object { $_.FullName -like 'lib/*' } |
        Group-Object { ($_.FullName -split '/')[1] } |
        ForEach-Object {
            [pscustomobject]@{
                Abi   = $_.Name
                Files = $_.Count
                Mb    = [math]::Round(($_.Group | Measure-Object Length -Sum).Sum / 1MB, 1)
            }
        } |
        Sort-Object Mb -Descending

    Write-Host ''
    Write-Host 'Native payload by ABI:'
    foreach ($entry in $byAbi) {
        $colour = if ($entry.Abi -eq 'arm64-v8a') { 'Green' } else { 'DarkGray' }
        Write-Host ("  {0,7} MB  {1,3} files  {2}" -f $entry.Mb, $entry.Files, $entry.Abi) -ForegroundColor $colour
    }

    # Anything over 1 MB in a non-target ABI means the engine leaked in.
    $leaked = $byAbi | Where-Object { $_.Abi -ne 'arm64-v8a' -and $_.Mb -gt 1 }
    if ($leaked) {
        Write-Host ''
        Write-Host 'FAIL: non-target ABI carries real code — --target-platform did not apply.' -ForegroundColor Red
        $leaked | ForEach-Object {
            Write-Host ("  {0} MB wasted in {1}" -f $_.Mb, $_.Abi) -ForegroundColor Red
        }
        throw 'Unwanted ABI payload in a release APK.'
    }
    $residue = $byAbi | Where-Object { $_.Abi -ne 'arm64-v8a' }
    if ($residue) {
        Write-Host ''
        Write-Host ("  OK: {0} MB of JNI stubs in non-target ABIs (expected; see phases.md)." -f (
            [math]::Round(($residue | Measure-Object Mb -Sum).Sum, 1))) -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host 'Largest native libraries:'
    $zip.Entries |
        Where-Object { $_.FullName -like 'lib/*' } |
        Sort-Object Length -Descending |
        Select-Object -First 6 |
        ForEach-Object {
            Write-Host ("  {0,7} MB  {1}" -f [math]::Round($_.Length / 1MB, 1), $_.FullName)
        }
}
finally {
    $zip.Dispose()
}