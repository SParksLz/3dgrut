# To run this script from PowerShell, navigate to the project folder, and run:
# .\install_env.ps1

param (
    [string]$CondaEnv = "3dgrut"
)

# Function to check if last command succeeded
function Check-LastCommand {
    param($StepName)
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Error: $StepName failed with exit code $LASTEXITCODE" -ForegroundColor Red
        exit $LASTEXITCODE
    }
    Write-Host "$StepName completed successfully" -ForegroundColor Green
}

# Function to find Visual Studio cl.exe path
function Find-VisualStudioCompiler {
    Write-Host "Searching for Visual Studio C++ compiler..." -ForegroundColor Yellow
    
    # Search paths for different VS editions and versions
    $searchPaths = @(
        "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Tools\MSVC\*\bin\Hostx64\x64",
        "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Tools\MSVC\*\bin\Hostx64\x64", 
        "C:\Program Files\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\*\bin\Hostx64\x64",
        "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\*\bin\Hostx64\x64",
        "C:\Program Files (x86)\Microsoft Visual Studio\2019\Enterprise\VC\Tools\MSVC\*\bin\Hostx64\x64",
        "C:\Program Files (x86)\Microsoft Visual Studio\2019\Professional\VC\Tools\MSVC\*\bin\Hostx64\x64",
        "C:\Program Files (x86)\Microsoft Visual Studio\2019\BuildTools\VC\Tools\MSVC\*\bin\Hostx64\x64",
        "C:\Program Files (x86)\Microsoft Visual Studio\2019\Community\VC\Tools\MSVC\*\bin\Hostx64\x64",
        # Fallback to x86 host if x64 host not available
        "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\VC\Tools\MSVC\*\bin\Hostx64\x86",
        "C:\Program Files\Microsoft Visual Studio\2022\Professional\VC\Tools\MSVC\*\bin\Hostx64\x86", 
        "C:\Program Files\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\*\bin\Hostx64\x86",
        "C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\*\bin\Hostx64\x86",
        "C:\Program Files (x86)\Microsoft Visual Studio\2022\Enterprise\VC\Tools\MSVC\*\bin\Hostx64\x86",
        "C:\Program Files (x86)\Microsoft Visual Studio\2022\Professional\VC\Tools\MSVC\*\bin\Hostx64\x86", 
        "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC\*\bin\Hostx64\x86",
        "C:\Program Files (x86)\Microsoft Visual Studio\2022\Community\VC\Tools\MSVC\*\bin\Hostx64\x86"
    )
    
    foreach ($path in $searchPaths) {
        $resolvedPaths = Get-ChildItem -Path $path -ErrorAction SilentlyContinue | Sort-Object Name -Descending
        foreach ($resolvedPath in $resolvedPaths) {
            $clExe = Join-Path $resolvedPath.FullName "cl.exe"
            if (Test-Path $clExe) {
                Write-Host "Found Visual Studio compiler at: $($resolvedPath.FullName)" -ForegroundColor Green
                return $resolvedPath.FullName
            }
        }
    }
    
    Write-Host "Warning: Could not find Visual Studio C++ compiler automatically." -ForegroundColor Yellow
    Write-Host "You may need to install Visual Studio Build Tools or add cl.exe to PATH manually." -ForegroundColor Yellow
    return $null
}

Write-Host "`nStarting Conda environment setup: $CondaEnv"

# Initialize conda for PowerShell (this enables conda commands)
Write-Host "Initializing conda for PowerShell..."
& conda init powershell
Check-LastCommand "Conda initialization"

# Refresh the current session to pick up conda changes
Write-Host "Refreshing PowerShell session..."
& powershell -Command "& {conda --version}"
Check-LastCommand "Conda verification"

Write-Host "Creating conda environment..."
conda create -n $CondaEnv python=3.11 -y
Check-LastCommand "Conda environment creation"

# Load conda PowerShell hook so "conda activate" works in this process (required when script is run with -NoProfile)
$condaRoot = $null
try {
    $condaExe = (Get-Command conda -ErrorAction Stop).Source
    if ($condaExe) { $condaRoot = Split-Path (Split-Path $condaExe -Parent) -Parent }
} catch {}
if (-not $condaRoot) {
    $baseOut = & conda info --base 2>$null
    if ($baseOut) { $condaRoot = ($baseOut | Select-Object -First 1).Trim() }
}
if ($condaRoot) {
    $condaHook = Join-Path $condaRoot "shell\condabin\conda-hook.ps1"
    if (Test-Path $condaHook) {
        . $condaHook
    }
}

Write-Host "Activating conda environment..."
conda activate $CondaEnv
Check-LastCommand "Conda environment activation"

# Verify environment is active
Write-Host "Verifying environment activation..."
$CurrentEnv = $env:CONDA_DEFAULT_ENV
if ($CurrentEnv -ne $CondaEnv) {
    Write-Host "Warning: Expected environment '$CondaEnv' but found '$CurrentEnv'" -ForegroundColor Yellow
}
Write-Host "Current environment: $CurrentEnv" -ForegroundColor Green

# Configure Visual Studio C++ compiler for PyTorch JIT compilation
# Use activate.d hook to PREPEND VS path to PATH (preserves your existing PATH)
Write-Host "`nConfiguring Visual Studio C++ compiler for conda environment..." -ForegroundColor Yellow
$vsCompilerPath = Find-VisualStudioCompiler
if ($vsCompilerPath) {
    # Remove PATH from conda env vars if it was set by a previous run (avoids overwriting user PATH)
    conda env config vars unset -n $CondaEnv PATH 2>$null

    # Use activate.d to prepend VS path only (does not overwrite system PATH)
    $activateDir = Join-Path $env:CONDA_PREFIX "etc\conda\activate.d"
    $activateScript = Join-Path $activateDir "vs_compiler_path.bat"
    New-Item -ItemType Directory -Path $activateDir -Force | Out-Null
    # Batch script: prepend VS path to existing PATH (use concatenation to avoid PowerShell parsing semicolon/quotes)
    $batchLine = 'set "PATH=' + $vsCompilerPath + ';%PATH%"'
    Set-Content -Path $activateScript -Value "@echo off`n$batchLine" -Encoding ASCII
    Write-Host "Created activate hook: $activateScript" -ForegroundColor Green
    Write-Host "Visual Studio compiler will be prepended to PATH when you activate the environment (your PATH is preserved)" -ForegroundColor Green

    # Apply for current session
    $env:PATH = "$vsCompilerPath;$env:PATH"

    # Verify the compiler is now accessible
    Write-Host "Verifying compiler accessibility..." -ForegroundColor Yellow
    $clTest = Get-Command cl.exe -ErrorAction SilentlyContinue
    if ($clTest) {
        Write-Host "Visual Studio compiler (cl.exe) is now accessible: $($clTest.Source)" -ForegroundColor Green
    } else {
        Write-Host "Warning: cl.exe still not found in PATH. Manual setup may be required." -ForegroundColor Yellow
    }
} else {
    Write-Host "Skipping compiler PATH setup - Visual Studio not found" -ForegroundColor Yellow
    Write-Host "You may need to install Visual Studio Build Tools and re-run this script" -ForegroundColor Yellow
}

# Install CUDA toolkit 12.4 (nvcc, headers, libs)
Write-Host "`nInstalling CUDA toolkit 12.4 (nvcc, etc.)..." -ForegroundColor Yellow
conda install -y -c nvidia/label/cuda-12.4.0 cuda-toolkit
Check-LastCommand "CUDA toolkit installation"

# Install PyTorch with CUDA support (CRITICAL: This must complete first)
Write-Host "`nInstalling PyTorch + CUDA 12.4 (this may take several minutes)..." -ForegroundColor Yellow
pip install torch==2.5.1 torchvision==0.20.1 torchaudio==2.5.1 --index-url https://download.pytorch.org/whl/cu124
Check-LastCommand "PyTorch installation"

# Verify PyTorch installation
Write-Host "Verifying PyTorch installation..." -ForegroundColor Yellow
python -c "import torch; print(f'PyTorch version: {torch.__version__}'); print(f'CUDA available: {torch.cuda.is_available()}')"
Check-LastCommand "PyTorch verification"

# Install build tools
Write-Host "Installing build tools (cmake, ninja)..." -ForegroundColor Yellow
conda install -y cmake ninja -c nvidia/label/cuda-12.4.0
Check-LastCommand "Build tools installation"

# Initialize Git submodules
Write-Host "Initializing Git submodules..." -ForegroundColor Yellow
git submodule update --init --recursive
Check-LastCommand "Git submodules initialization"

# Build backend required by some deps (e.g. polyscope); must be installed before requirements when using --no-build-isolation
Write-Host "Installing scikit-build-core (build backend for native packages)..." -ForegroundColor Yellow
pip install scikit-build-core
Check-LastCommand "scikit-build-core installation"

# Install libigl (optional: only needed for Playground mesh .obj/.glb loading; not needed for PLY->USDZ)
Write-Host "Installing libigl (optional, prebuilt wheel only)..." -ForegroundColor Yellow
$libiglOk = $true
pip install libigl --only-binary=libigl 2>&1 | Out-Host
if ($LASTEXITCODE -ne 0) {
    $libiglOk = $false
    Write-Host "Skipped: libigl (optional). Install later if needed: pip install libigl" -ForegroundColor Yellow
}

# Install Python dependencies
Write-Host "Installing Python requirements from requirements.txt..." -ForegroundColor Yellow
pip install --no-build-isolation -r requirements.txt
Check-LastCommand "Requirements installation"

# Install additional dependencies
Write-Host "Installing Cython..." -ForegroundColor Yellow
pip install cython
Check-LastCommand "Cython installation"

Write-Host "Installing Hydra-core..." -ForegroundColor Yellow
pip install hydra-core
Check-LastCommand "Hydra-core installation"

# Install Kaolin
Write-Host "Installing Kaolin (this may take a while)..." -ForegroundColor Yellow
pip install https://nvidia-kaolin.s3.us-east-2.amazonaws.com/torch-2.5.1_cu124/kaolin-0.17.0-cp311-cp311-win_amd64.whl
Check-LastCommand "Kaolin installation"

# Install project in development mode
Write-Host "Installing project in development mode..." -ForegroundColor Yellow
pip install -e .
Check-LastCommand "Project installation"

# Final success message
Write-Host "`n" -NoNewline
Write-Host "=================================================" -ForegroundColor Green
Write-Host "    INSTALLATION COMPLETED SUCCESSFULLY!" -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Green
Write-Host "Environment '$CondaEnv' is ready with all dependencies!" -ForegroundColor Green
if (-not $libiglOk) {
    Write-Host "Note: libigl was skipped (optional; only needed for Playground .obj/.glb mesh loading)." -ForegroundColor Cyan
}
Write-Host ""
Write-Host "To use the environment:" -ForegroundColor Cyan
Write-Host "  conda activate $CondaEnv" -ForegroundColor White
