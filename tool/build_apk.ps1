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

.PARAMETER Debug
    Build a debug APK instead. Same size-critical flags still apply.

.PARAMETER Analyze
    Print a per-library size breakdown after building.

.EXAMPLE
    ./tool/build_apk.ps1
    ./tool/build_apk.ps1 -Debug -Analyze
#>
[CmdletBinding()]
param(
    [switch]$Debug,
    [switch]$Analyze
)

$ErrorActionPreference = 'Stop'

Set-Location (Join-Path $PSScriptRoot '..')

$mode = if ($Debug) { '--debug' } else { '--release' }
$target = [ordered]@{
    Mode            = $mode
    TargetPlatform  = 'android-arm64 (see tool/build_apk.ps1 header)'
}

Write-Host 'Heads Up build' -ForegroundColor Cyan
foreach ($key in $target.Keys) {
    Write-Host ("  {0,-15} {1}" -f $key, $target[$key])
}

$args = @('build', 'apk', $mode, '--target-platform', 'android-arm64')
if ($Analyze) { $args += '--analyze-size' }

& flutter @args
if ($LASTEXITCODE -ne 0) {
    throw "flutter build failed with exit code $LASTEXITCODE"
}

$apkName = if ($Debug) { 'app-debug.apk' } else { 'app-release.apk' }
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
    $abis = $zip.Entries |
        Where-Object { $_.FullName -like 'lib/*' } |
        ForEach-Object { ($_.FullName -split '/')[1] } |
        Sort-Object -Unique
    Write-Host ("ABIs packaged: {0}" -f ($abis -join ', ')) -ForegroundColor Yellow
    if ($abis.Count -gt 1) {
        Write-Host '  NOTE: more than one ABI is packaged — check --target-platform.' -ForegroundColor Yellow
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