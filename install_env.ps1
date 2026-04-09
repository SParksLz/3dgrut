# To run this script from PowerShell, navigate to the project folder, and run:
# .\install_env.ps1

param (
    [string]$CondaEnv = "3dgrut",
    [string]$CudaVersion = "auto"
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

function Normalize-CudaVersion {
    param([string]$RequestedVersion)

    if (-not $RequestedVersion) {
        return "auto"
    }

    switch -Regex ($RequestedVersion.Trim().ToLowerInvariant()) {
        "^auto$" { return "auto" }
        "^12\.4(\.0)?$" { return "12.4.0" }
        "^12\.8(\.1)?$" { return "12.8.1" }
        default {
            throw "Unsupported CUDA version '$RequestedVersion'. Supported values are auto, 12.4.0, and 12.8.1."
        }
    }
}

function Get-DetectedCudaArchCodes {
    Write-Host "Detecting NVIDIA GPU compute capability..." -ForegroundColor Yellow

    $archCodes = @()

    try {
        $computeCaps = & nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>$null
        if ($LASTEXITCODE -eq 0 -and $computeCaps) {
            foreach ($cap in $computeCaps) {
                $capText = $cap.ToString().Trim()
                if ($capText -match "^(?<major>\d+)(?:\.(?<minor>\d+))?$") {
                    $major = [int]$Matches["major"]
                    $minor = if ($Matches["minor"]) { [int]$Matches["minor"] } else { 0 }
                    $archCodes += ($major * 10 + $minor)
                }
            }
        }
    } catch {}

    if (-not $archCodes) {
        try {
            $gpuNames = & nvidia-smi --query-gpu=name --format=csv,noheader 2>$null
            if ($LASTEXITCODE -eq 0 -and $gpuNames) {
                foreach ($gpuName in $gpuNames) {
                    $gpuNameText = $gpuName.ToString().Trim()
                    if ($gpuNameText -match "Blackwell|RTX\s*50\d{2}|RTX\s*PRO\s*6000.*Blackwell") {
                        $archCodes += 120
                    }
                }
            }
        } catch {}
    }

    $archCodes = @($archCodes | Sort-Object -Unique)
    if ($archCodes.Count -gt 0) {
        Write-Host ("Detected CUDA architectures: " + ($archCodes -join ", ")) -ForegroundColor Green
    } else {
        Write-Host "Warning: Could not detect GPU compute capability from nvidia-smi; defaulting to the legacy CUDA profile." -ForegroundColor Yellow
    }

    return $archCodes
}

function Resolve-CudaInstallProfile {
    param([string]$RequestedVersion)

    $normalizedVersion = Normalize-CudaVersion $RequestedVersion
    $detectedArchCodes = Get-DetectedCudaArchCodes
    $selectionReason = $null

    if ($normalizedVersion -eq "auto") {
        if ($detectedArchCodes.Count -gt 0 -and ($detectedArchCodes | Measure-Object -Maximum).Maximum -ge 100) {
            $normalizedVersion = "12.8.1"
            $selectionReason = "Detected compute capability 10.0+ GPU; selecting the Blackwell-capable CUDA 12.8.1 profile."
        } else {
            $normalizedVersion = "12.4.0"
            $selectionReason = "Detected pre-Blackwell GPU (or no GPU info); selecting the legacy-compatible CUDA 12.4.0 profile."
        }
    } else {
        $selectionReason = "Using user-requested CUDA version $normalizedVersion."
    }

    switch ($normalizedVersion) {
        "12.4.0" {
            $torchPackages = @(
                "install",
                "torch==2.5.1",
                "torchvision==0.20.1",
                "torchaudio==2.5.1",
                "--index-url",
                "https://download.pytorch.org/whl/cu124"
            )
            $profile = @{
                CudaVersion = "12.4.0"
                CudaLabel = "12.4"
                CondaChannel = "nvidia/label/cuda-12.4.0"
                TorchPackages = $torchPackages
                TorchCudaArchList = "7.0;7.5;8.0;8.6;8.9;9.0+PTX"
                KaolinWheelUrl = "https://nvidia-kaolin.s3.us-east-2.amazonaws.com/torch-2.5.1_cu124/kaolin-0.17.0-cp311-cp311-win_amd64.whl"
            }
        }
        "12.8.1" {
            $torchPackages = @(
                "install",
                "torch",
                "torchvision",
                "torchaudio",
                "--index-url",
                "https://download.pytorch.org/whl/cu128"
            )
            $profile = @{
                CudaVersion = "12.8.1"
                CudaLabel = "12.8.1"
                CondaChannel = "nvidia/label/cuda-12.8.1"
                TorchPackages = $torchPackages
                TorchCudaArchList = "7.5;8.0;8.6;8.9;9.0;10.0;12.0+PTX"
                KaolinWheelUrl = $null
            }
        }
    }

    if ($detectedArchCodes.Count -gt 0) {
        $maxSupportedArch = if ($normalizedVersion -eq "12.8.1") { 120 } else { 90 }
        $tcnnArchCodes = @(
            $detectedArchCodes |
            Where-Object { $_ -ge 50 -and $_ -le $maxSupportedArch } |
            Sort-Object -Unique
        )
        if ($tcnnArchCodes.Count -eq 0) {
            $tcnnArchCodes = @($maxSupportedArch)
        }
        $profile["TcnnCudaArchitectures"] = ($tcnnArchCodes -join ";")
    } else {
        $profile["TcnnCudaArchitectures"] = if ($normalizedVersion -eq "12.8.1") { "120" } else { "90" }
    }

    $profile["SelectionReason"] = $selectionReason
    $profile["DetectedArchCodes"] = $detectedArchCodes
    return $profile
}

function Apply-CudaEnvironmentHints {
    param(
        [string]$EnvName,
        [hashtable]$Profile
    )

    if ($Profile.TorchCudaArchList) {
        conda env config vars set -n $EnvName TORCH_CUDA_ARCH_LIST="$($Profile.TorchCudaArchList)" | Out-Null
        $env:TORCH_CUDA_ARCH_LIST = $Profile.TorchCudaArchList
        Write-Host "Configured TORCH_CUDA_ARCH_LIST=$($Profile.TorchCudaArchList)" -ForegroundColor Green
    }

    if ($Profile.TcnnCudaArchitectures) {
        conda env config vars set -n $EnvName TCNN_CUDA_ARCHITECTURES="$($Profile.TcnnCudaArchitectures)" | Out-Null
        $env:TCNN_CUDA_ARCHITECTURES = $Profile.TcnnCudaArchitectures
        Write-Host "Configured TCNN_CUDA_ARCHITECTURES=$($Profile.TcnnCudaArchitectures)" -ForegroundColor Green
    }
}

function Configure-WindowsCudaToolchain {
    param(
        [string]$EnvName,
        [hashtable]$Profile
    )

    $cudaRoot = Join-Path $env:CONDA_PREFIX "Library"
    $cudaBin = Join-Path $cudaRoot "bin"
    $cudaLib = Join-Path $cudaRoot "lib"
    $cudaLibX64 = Join-Path $cudaLib "x64"
    $cudaInclude = Join-Path $cudaRoot "include"
    $cudaIncludeCrt = Join-Path $cudaInclude "crt"
    $cudaIncludeTargets = Join-Path $cudaInclude "targets\x64"

    $pathEntries = @($cudaBin) | Where-Object { Test-Path $_ }
    $libEntries = @($cudaLibX64, $cudaLib) | Where-Object { Test-Path $_ }
    $includeEntries = @($cudaInclude, $cudaIncludeCrt, $cudaIncludeTargets) | Where-Object { Test-Path $_ }

    if (-not (Test-Path $cudaRoot)) {
        Write-Host "Warning: CUDA root '$cudaRoot' was not found after installation." -ForegroundColor Yellow
        return
    }

    conda env config vars set -n $EnvName CUDA_HOME="$cudaRoot" CUDA_PATH="$cudaRoot" | Out-Null
    $env:CUDA_HOME = $cudaRoot
    $env:CUDA_PATH = $cudaRoot

    $versionTokens = $Profile.CudaVersion.Split(".")
    if ($versionTokens.Count -ge 2) {
        $majorMinor = "$($versionTokens[0])_$($versionTokens[1])"
        Set-Item -Path ("Env:CUDA_PATH_V$majorMinor") -Value $cudaRoot
    }

    if ($pathEntries.Count -gt 0) {
        $env:PATH = (($pathEntries + @($env:PATH)) -join ";")
    }
    if ($libEntries.Count -gt 0) {
        $existingLib = if ($env:LIB) { @($env:LIB) } else { @() }
        $env:LIB = (($libEntries + $existingLib) -join ";")
    }
    if ($includeEntries.Count -gt 0) {
        $existingInclude = if ($env:INCLUDE) { @($env:INCLUDE) } else { @() }
        $env:INCLUDE = (($includeEntries + $existingInclude) -join ";")
    }

    $activateDir = Join-Path $env:CONDA_PREFIX "etc\conda\activate.d"
    $activateScript = Join-Path $activateDir "cuda_toolchain_paths.bat"
    New-Item -ItemType Directory -Path $activateDir -Force | Out-Null

    $activateLines = @(
        "@echo off",
        "set ""CUDA_HOME=%CONDA_PREFIX%\Library""",
        "set ""CUDA_PATH=%CONDA_PREFIX%\Library"""
    )

    if ($versionTokens.Count -ge 2) {
        $activateLines += "set ""CUDA_PATH_V$majorMinor=%CONDA_PREFIX%\Library"""
    }

    $activateLines += @(
        "if exist ""%CUDA_HOME%\bin"" set ""PATH=%CUDA_HOME%\bin;%PATH%""",
        "if exist ""%CUDA_HOME%\lib\x64"" set ""LIB=%CUDA_HOME%\lib\x64;%LIB%""",
        "if exist ""%CUDA_HOME%\lib"" set ""LIB=%CUDA_HOME%\lib;%LIB%""",
        "if exist ""%CUDA_HOME%\include"" set ""INCLUDE=%CUDA_HOME%\include;%INCLUDE%""",
        "if exist ""%CUDA_HOME%\include\crt"" set ""INCLUDE=%CUDA_HOME%\include\crt;%INCLUDE%""",
        "if exist ""%CUDA_HOME%\include\targets\x64"" set ""INCLUDE=%CUDA_HOME%\include\targets\x64;%INCLUDE%"""
    )

    Set-Content -Path $activateScript -Value ($activateLines -join "`n") -Encoding ASCII

    Write-Host "Configured CUDA_HOME/CUDA_PATH for conda environment." -ForegroundColor Green
    if ($libEntries.Count -gt 0) {
        Write-Host ("Configured CUDA LIB paths: " + ($libEntries -join "; ")) -ForegroundColor Green
    }
    if ($includeEntries.Count -gt 0) {
        Write-Host ("Configured CUDA INCLUDE paths: " + ($includeEntries -join "; ")) -ForegroundColor Green
    }
    Write-Host "Created CUDA activate hook: $activateScript" -ForegroundColor Green
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

$cudaProfile = Resolve-CudaInstallProfile $CudaVersion
Write-Host ("Selected CUDA profile: " + $cudaProfile.CudaVersion) -ForegroundColor Green
Write-Host $cudaProfile.SelectionReason -ForegroundColor Cyan
Apply-CudaEnvironmentHints -EnvName $CondaEnv -Profile $cudaProfile

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

# Install CUDA toolkit (nvcc, headers, libs)
Write-Host "`nInstalling CUDA toolkit $($cudaProfile.CudaLabel) (nvcc, etc.)..." -ForegroundColor Yellow
conda install -y -c $cudaProfile.CondaChannel cuda-toolkit
Check-LastCommand "CUDA toolkit installation"

# Install PyTorch with CUDA support (CRITICAL: This must complete first)
Write-Host "`nInstalling PyTorch + CUDA $($cudaProfile.CudaLabel) (this may take several minutes)..." -ForegroundColor Yellow
& pip @($cudaProfile.TorchPackages)
Check-LastCommand "PyTorch installation"

# Verify PyTorch installation
Write-Host "Verifying PyTorch installation..." -ForegroundColor Yellow
python -c "import torch; print(f'PyTorch version: {torch.__version__}'); print(f'CUDA available: {torch.cuda.is_available()}')"
Check-LastCommand "PyTorch verification"

# Install build tools
Write-Host "Installing build tools (cmake, ninja)..." -ForegroundColor Yellow
conda install -y cmake ninja -c $cudaProfile.CondaChannel
Check-LastCommand "Build tools installation"

Configure-WindowsCudaToolchain -EnvName $CondaEnv -Profile $cudaProfile

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
$requirementsPath = Join-Path $PSScriptRoot "requirements.txt"
$effectiveRequirementsPath = $requirementsPath
$skippedPpisp = $false
if ($IsWindows) {
    $requirementsLines = Get-Content -Path $requirementsPath
    $filteredRequirements = @()
    foreach ($requirementsLine in $requirementsLines) {
        if ($requirementsLine -match '^\s*ppisp\s*@') {
            $skippedPpisp = $true
            continue
        }
        $filteredRequirements += $requirementsLine
    }

    if ($skippedPpisp) {
        $effectiveRequirementsPath = Join-Path $env:TEMP "3dgrut_requirements_windows_filtered.txt"
        Set-Content -Path $effectiveRequirementsPath -Value $filteredRequirements -Encoding ASCII
        Write-Host "Skipping optional ppisp dependency on Windows for the export-focused workflow." -ForegroundColor Yellow
    }
}

pip install --no-build-isolation -r $effectiveRequirementsPath
Check-LastCommand "Requirements installation"

# Install additional dependencies
Write-Host "Installing Cython..." -ForegroundColor Yellow
pip install cython
Check-LastCommand "Cython installation"

Write-Host "Installing Hydra-core..." -ForegroundColor Yellow
pip install hydra-core
Check-LastCommand "Hydra-core installation"

# Install Kaolin
$kaolinOk = $true
if ($cudaProfile.KaolinWheelUrl) {
    Write-Host "Installing Kaolin (this may take a while)..." -ForegroundColor Yellow
    pip install $cudaProfile.KaolinWheelUrl
    Check-LastCommand "Kaolin installation"
} else {
    $kaolinOk = $false
    Write-Host "Skipping Kaolin install: no Windows CUDA $($cudaProfile.CudaLabel) wheel is configured yet." -ForegroundColor Yellow
}

# Install project in development mode
Write-Host "Installing project in development mode..." -ForegroundColor Yellow
pip install -e .
Check-LastCommand "Project installation"

# Final success message
Write-Host "`n" -NoNewline
Write-Host "=================================================" -ForegroundColor Green
Write-Host "    INSTALLATION COMPLETED SUCCESSFULLY!" -ForegroundColor Green
Write-Host "=================================================" -ForegroundColor Green
Write-Host "Environment '$CondaEnv' is ready with the CUDA $($cudaProfile.CudaVersion) profile." -ForegroundColor Green
if (-not $libiglOk) {
    Write-Host "Note: libigl was skipped (optional; only needed for Playground .obj/.glb mesh loading)." -ForegroundColor Cyan
}
if (-not $kaolinOk) {
    Write-Host "Note: Kaolin was skipped for CUDA $($cudaProfile.CudaVersion); add a compatible wheel or source-build path if your workflow needs it." -ForegroundColor Cyan
}
Write-Host ""
Write-Host "To use the environment:" -ForegroundColor Cyan
Write-Host "  conda activate $CondaEnv" -ForegroundColor White
