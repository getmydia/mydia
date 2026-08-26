# Copies the Visual C++ runtime DLLs into the Flutter Windows release bundle.
#
# A release build links against the VC++ 2015-2022 runtime, which is not part of
# a clean Windows install. Without this the app dies on launch with
# "msvcp140.dll was not found" on any machine that has never had a VC++
# redistributable. Developer machines and GitHub's windows-latest runners both
# have it, so nothing catches this before a user does.
#
# Deploying the DLLs next to the executable ("app-local deployment") is the
# option that fits: installer.iss is a per-user install with
# PrivilegesRequired=lowest, so it cannot run vc_redist.x64.exe, which needs
# admin. Microsoft's redistributable rights permit app-local deployment.
#
# Run this after `flutter build windows --release` and before packaging. The
# installer's [Files] section globs the same Release directory, so both the raw
# CI artifact and the Inno Setup installer pick the DLLs up with no further
# changes.
#
#   pwsh player/tool/bundle_windows_runtime.ps1
#
# Optional -ReleaseDir overrides the default build output location.

[CmdletBinding()]
param(
    [string]$ReleaseDir
)

$ErrorActionPreference = 'Stop'

if (-not $ReleaseDir) {
    $playerRoot = Split-Path -Parent $PSScriptRoot
    $ReleaseDir = Join-Path $playerRoot 'build\windows\x64\runner\Release'
}

if (-not (Test-Path -LiteralPath $ReleaseDir)) {
    throw "Release directory not found: $ReleaseDir. Run 'flutter build windows --release' first."
}

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) {
    throw "vswhere.exe not found at $vswhere. Visual Studio with the C++ workload is required."
}

$vsPath = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if ([string]::IsNullOrWhiteSpace($vsPath)) {
    throw 'No Visual Studio installation with the C++ tools was found.'
}

# The version file is the documented way to find the current redist, but it can
# name a version whose directory was never laid down. Fall back to whatever CRT
# directories are actually present and take the newest.
$crtDir = $null
$versionFile = Join-Path $vsPath 'VC\Auxiliary\Build\Microsoft.VCRedistVersion.default.txt'
if (Test-Path -LiteralPath $versionFile) {
    $version = (Get-Content -LiteralPath $versionFile -Raw).Trim()
    $crtDir = Get-ChildItem -Path (Join-Path $vsPath "VC\Redist\MSVC\$version\x64") `
        -Filter 'Microsoft.VC*.CRT' -Directory -ErrorAction SilentlyContinue |
        Select-Object -First 1
}

if (-not $crtDir) {
    $crtDir = Get-ChildItem -Path (Join-Path $vsPath 'VC\Redist\MSVC') `
        -Filter 'Microsoft.VC*.CRT' -Directory -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match '\\x64\\' } |
        Sort-Object FullName |
        Select-Object -Last 1
}

if (-not $crtDir) {
    throw "No x64 Microsoft.VC*.CRT redistributable directory found under $vsPath."
}

Write-Host "Copying VC++ runtime from $($crtDir.FullName)"
Copy-Item -Path (Join-Path $crtDir.FullName '*.dll') -Destination $ReleaseDir -Force

# Fail loudly rather than shipping a bundle that only works on machines which
# happen to already have the runtime.
$required = @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')
$missing = $required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $ReleaseDir $_)) }
if ($missing) {
    throw "VC++ runtime missing from the bundle after copy: $($missing -join ', ')"
}

Write-Host "Bundled VC++ runtime into $ReleaseDir"
Get-ChildItem -LiteralPath $ReleaseDir -Filter '*140*.dll' | ForEach-Object { Write-Host "  $($_.Name)" }
