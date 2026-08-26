# deploy.ps1 — Deploy and package qub for Windows (x64 MSVC).
# Run from the project root after building in ./build/.
# Requires Qt's windeployqt and Inno Setup (ISCC) on PATH.
param(
    [string]$BuildDir = "build",
    [string]$OutDir   = "dist"
)
$ErrorActionPreference = "Stop"

$Version = (Select-String -Path CMakeLists.txt -Pattern '\d+\.\d+\.\d+' | Select-Object -First 1).Matches.Value

$StageDir = "$env:TEMP\qub-stage"
Remove-Item -Recurse -Force $StageDir -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $StageDir, $OutDir | Out-Null

# ── Copy executable ──────────────────────────────────────────────────────────
Copy-Item "$BuildDir\Release\qub.exe" "$StageDir\qub.exe"

# ── windeployqt ─────────────────────────────────────────────────────────────
& windeployqt6 `
    --no-translations `
    --no-system-d3d-compiler `
    --no-opengl-sw `
    --qmldir src\qml `
    "$StageDir\qub.exe"

if ($LASTEXITCODE -ne 0) { throw "windeployqt6 failed" }

# ── Bundle SQL driver plugins ────────────────────────────────────────────────
$QtPlugins = & qmake6 -query QT_INSTALL_PLUGINS
$DriverDst = "$StageDir\plugins\sqldrivers"
New-Item -ItemType Directory -Force -Path $DriverDst | Out-Null

foreach ($drv in @("qsqlpsql.dll", "qsqlmysql.dll", "qsqlite.dll")) {
    $src = "$QtPlugins\sqldrivers\$drv"
    if (Test-Path $src) { Copy-Item $src $DriverDst }
}

# MariaDB Connector/C runtime (LGPL — allowed to bundle)
foreach ($lib in @("libmariadb.dll", "libmariadb3.dll")) {
    $found = Get-Command $lib -ErrorAction SilentlyContinue
    if ($found) { Copy-Item $found.Source $StageDir }
}
# libpq runtime
foreach ($lib in @("libpq.dll", "libssl-3-x64.dll", "libcrypto-3-x64.dll")) {
    $found = Get-Command $lib -ErrorAction SilentlyContinue
    if ($found) { Copy-Item $found.Source $StageDir }
}

# ── Compile Inno Setup installer ─────────────────────────────────────────────
$iss = (Get-Content packaging\windows\installer.iss -Raw) `
    -replace "__VERSION__", $Version `
    -replace "__STAGE__",   $StageDir.Replace("\", "\\")
$tmpIss = "$env:TEMP\qub-installer.iss"
Set-Content -Path $tmpIss -Value $iss

& iscc $tmpIss "/O$((Get-Item $OutDir).FullName)"
if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed" }

Write-Host "Installer written to $OutDir"
