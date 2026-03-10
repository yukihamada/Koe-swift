# Koe for Windows — Build & Run Script
param(
    [switch]$Release,
    [switch]$Cuda,
    [switch]$Run,
    [switch]$Installer
)

Write-Host "=== Koe for Windows Build ===" -ForegroundColor Cyan

# Check Rust
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: Rust not installed. Install from https://rustup.rs" -ForegroundColor Red
    exit 1
}

# Build flags
$features = @()
$buildArgs = @("build")

if ($Release) {
    $buildArgs += "--release"
    Write-Host "Mode: Release" -ForegroundColor Green
} else {
    Write-Host "Mode: Debug" -ForegroundColor Yellow
}

if ($Cuda) {
    if (Get-Command nvcc -ErrorAction SilentlyContinue) {
        $buildArgs += "--features"
        $buildArgs += "cuda"
        Write-Host "GPU: CUDA enabled" -ForegroundColor Green
    } else {
        Write-Host "WARNING: CUDA not found, building CPU-only" -ForegroundColor Yellow
    }
} else {
    Write-Host "GPU: CPU-only (use -Cuda for GPU acceleration)" -ForegroundColor Yellow
}

# Build
Write-Host "`nBuilding..." -ForegroundColor Cyan
& cargo @buildArgs
if ($LASTEXITCODE -ne 0) {
    Write-Host "`nBuild FAILED" -ForegroundColor Red
    exit 1
}

$profile = if ($Release) { "release" } else { "debug" }
$exe = "target\$profile\koe.exe"
Write-Host "`n✓ Build successful: $exe" -ForegroundColor Green

# Create installer
if ($Installer) {
    Write-Host "`nCreating installer..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path dist | Out-Null
    Copy-Item $exe dist\
    Copy-Item README.md dist\

    if (Get-Command makensis -ErrorAction SilentlyContinue) {
        & makensis installer\koe-installer.nsi
        Write-Host "✓ Installer: installer\Koe-Setup.exe" -ForegroundColor Green
    } else {
        Write-Host "WARNING: NSIS not found. Install: choco install nsis" -ForegroundColor Yellow
    }
}

# Run
if ($Run) {
    Write-Host "`nLaunching Koe..." -ForegroundColor Cyan
    & ".\$exe"
}
