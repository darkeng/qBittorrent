param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",

    [string]$BuildDir = "build",

    [switch]$Clean,
    [switch]$SkipQtDeploy,
    [switch]$Run
)

$ErrorActionPreference = "Stop"

function Find-CMake {
    $cmakeCmd = Get-Command cmake -ErrorAction SilentlyContinue
    if ($cmakeCmd) {
        return $cmakeCmd.Source
    }

    $vsCandidates = @(
        "C:\Program Files\Microsoft Visual Studio\2022\Community\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
        "C:\Program Files\Microsoft Visual Studio\2022\Professional\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe",
        "C:\Program Files\Microsoft Visual Studio\2022\Enterprise\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe"
    )

    foreach ($candidate in $vsCandidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    throw "No se encontro cmake. Instala CMake o Visual Studio 2022 con C++ workload."
}

function Find-WindeployQt {
    $windeployqtCmd = Get-Command windeployqt -ErrorAction SilentlyContinue
    if ($windeployqtCmd) {
        return $windeployqtCmd.Source
    }

    $vcpkgCandidate = Join-Path $env:USERPROFILE "vcpkg\installed\x64-windows\tools\Qt6\bin\windeployqt.exe"
    if (Test-Path $vcpkgCandidate) {
        return $vcpkgCandidate
    }

    return $null
}

function Deploy-QtRuntime {
    param(
        [string]$WindeployQtExe,
        [string]$ExePath,
        [string]$BuildConfiguration,
        [string]$OutputDir
    )

    $modeArg = if ($BuildConfiguration -eq "Release") { "--release" } else { "--debug" }
    & $WindeployQtExe $modeArg --dir $OutputDir $ExePath
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

$cmakeExe = Find-CMake
$vcpkgRoot = Join-Path $env:USERPROFILE "vcpkg"
$toolchainFile = Join-Path $vcpkgRoot "scripts/buildsystems/vcpkg.cmake"

if (-not (Test-Path $toolchainFile)) {
    throw "No se encontro vcpkg en $vcpkgRoot. Instala/bootstrapea vcpkg primero."
}

if ($Clean) {
    $cacheFile = Join-Path $BuildDir "CMakeCache.txt"
    $cmakeFilesDir = Join-Path $BuildDir "CMakeFiles"

    if (Test-Path $cacheFile) {
        Remove-Item $cacheFile -Force
    }

    if (Test-Path $cmakeFilesDir) {
        Remove-Item $cmakeFilesDir -Recurse -Force
    }
}

Write-Host "==> Configurando con CMake"
& $cmakeExe -B $BuildDir -G "Visual Studio 17 2022" -A x64 -T host=x64 -DCMAKE_TOOLCHAIN_FILE=$toolchainFile -DVCPKG_TARGET_TRIPLET=x64-windows

Write-Host "==> Compilando ($Configuration)"
& $cmakeExe --build $BuildDir --config $Configuration

$exePath = Join-Path $BuildDir "$Configuration/qbittorrent.exe"
if (Test-Path $exePath) {
    if (-not $SkipQtDeploy) {
        $windeployqtExe = Find-WindeployQt
        if ($windeployqtExe) {
            Write-Host "==> Desplegando runtime de Qt con windeployqt"
            Deploy-QtRuntime -WindeployQtExe $windeployqtExe -ExePath $exePath -BuildConfiguration $Configuration -OutputDir (Join-Path $BuildDir $Configuration)

            $qwindowsDll = Join-Path $BuildDir "$Configuration/platforms/qwindows.dll"
            if (-not (Test-Path $qwindowsDll)) {
                Write-Warning "No se encontro qwindows.dll despues de windeployqt: $qwindowsDll"
            }
        }
        else {
            Write-Warning "No se encontro windeployqt. El ejecutable puede no iniciar fuera del entorno de compilacion."
        }
    }

    Write-Host "Build OK: $exePath"

    if ($Run) {
        Write-Host "==> Ejecutando qBittorrent"
        & $exePath
    }
}
else {
    Write-Warning "Build completado, pero no se encontro el ejecutable esperado en: $exePath"
}
