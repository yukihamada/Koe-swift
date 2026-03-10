@echo off
echo Building Koe for Windows...

REM Check for Rust
where cargo >nul 2>&1 || (
    echo ERROR: Rust not installed. Install from https://rustup.rs
    exit /b 1
)

REM Check for CUDA (optional but recommended)
where nvcc >nul 2>&1 && (
    echo CUDA detected — GPU acceleration enabled
) || (
    echo WARNING: CUDA not found. GPU acceleration will be disabled.
    echo Install CUDA Toolkit from https://developer.nvidia.com/cuda-downloads
)

REM Build release
cargo build --release

if %ERRORLEVEL% EQU 0 (
    echo.
    echo ✓ Build successful!
    echo Binary: target\release\koe.exe
    echo.
    echo Run: target\release\koe.exe
) else (
    echo.
    echo ✗ Build failed
    exit /b 1
)
