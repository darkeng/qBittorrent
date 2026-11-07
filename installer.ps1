param(
    [ValidateSet("Debug", "Release")]
    [string]$Configuration = "Debug",

    [string]$BuildDir = "build",
    [string]$WindowsDistDir = "dist/windows",
    [string]$PayloadDirName = "qBittorrent",

    [ValidateSet("x64", "arm64")]
    [string]$CpuArch = "x64",

    [string]$Version,

    # Carpeta Microsoft.VC*.CRT con las DLL del runtime de Visual C++.
    # Si se omite, se busca en la instalacion de Visual Studio.
    [string]$VcRedistDir,

    [switch]$SkipBuild,
    [switch]$SkipQtDeploy,
    [switch]$CleanPayload
)

$ErrorActionPreference = "Stop"

# $ErrorActionPreference no detiene el script cuando falla un ejecutable nativo.
function Assert-LastExitCode {
    param([string]$Step)

    if ($LASTEXITCODE -ne 0) {
        throw "$Step fallo con codigo de salida $LASTEXITCODE."
    }
}

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

function Find-MakeNsis {
    $makensisCmd = Get-Command makensis -ErrorAction SilentlyContinue
    if ($makensisCmd) {
        return $makensisCmd.Source
    }

    $nsisCandidates = @(
        "C:\Program Files (x86)\NSIS\makensis.exe",
        "C:\Program Files\NSIS\makensis.exe"
    )

    foreach ($candidate in $nsisCandidates) {
        if (Test-Path $candidate) {
            return $candidate
        }
    }

    throw "No se encontro NSIS (makensis). Instala NSIS 3 y vuelve a ejecutar este script."
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

function Find-VcRuntimeDir {
    param([string]$Arch)

    $redistRoots = @()
    if ($env:VCToolsRedistDir) {
        $redistRoots += $env:VCToolsRedistDir
    }

    $vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vsPath = & $vswhere -latest -products * -property installationPath
        if (($LASTEXITCODE -eq 0) -and $vsPath) {
            $msvcRedist = Join-Path $vsPath "VC\Redist\MSVC"
            if (Test-Path $msvcRedist) {
                $redistRoots += Get-ChildItem $msvcRedist -Directory |
                    Where-Object { $_.Name -match '^\d+(\.\d+)+$' } |
                    Sort-Object { [version]$_.Name } -Descending |
                    ForEach-Object { $_.FullName }
            }
        }
    }

    foreach ($root in $redistRoots) {
        $crtDir = Get-ChildItem (Join-Path $root $Arch) -Directory -Filter "Microsoft.VC*.CRT" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($crtDir) {
            return $crtDir.FullName
        }
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
    Assert-LastExitCode "windeployqt"
}

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

$windowsDistPath = Join-Path $scriptDir $WindowsDistDir
$payloadDir = Join-Path $windowsDistPath $PayloadDirName
$nsisScript = Join-Path $windowsDistPath "qbittorrent.nsi"
$nsisPluginsZip = Join-Path $windowsDistPath "NSISPlugins.zip"
$nsisPluginsDir = Join-Path $windowsDistPath "NSISPlugins"
$nsisPluginsNestedDir = Join-Path $nsisPluginsDir "NSISPlugins"
$buildConfigDir = Join-Path (Join-Path $scriptDir $BuildDir) $Configuration

if (-not (Test-Path $nsisScript)) {
    throw "No se encontro el script NSIS: $nsisScript"
}

$makensisExe = Find-MakeNsis

if (-not $SkipBuild) {
    $buildScript = Join-Path $scriptDir "build.ps1"
    if (-not (Test-Path $buildScript)) {
        throw "No se encontro build.ps1 en la raiz del repositorio."
    }

    Write-Host "==> Compilando qBittorrent ($Configuration)"
    & $buildScript -Configuration $Configuration
}

if (-not (Test-Path $buildConfigDir)) {
    throw "No se encontro la salida de build: $buildConfigDir"
}

$buildExePath = Join-Path $buildConfigDir "qbittorrent.exe"
if (-not (Test-Path $buildExePath)) {
    throw "No se encontro qbittorrent.exe en: $buildExePath"
}

if (-not $SkipQtDeploy) {
    $windeployqtExe = Find-WindeployQt
    if (-not $windeployqtExe) {
        throw "No se encontro windeployqt. Instala Qt tools o usa -SkipQtDeploy si quieres omitir este paso."
    }

    Write-Host "==> Desplegando runtime de Qt para el ejecutable"
    Deploy-QtRuntime -WindeployQtExe $windeployqtExe -ExePath $buildExePath -BuildConfiguration $Configuration -OutputDir $buildConfigDir

    $qwindowsDll = Join-Path $buildConfigDir "platforms/qwindows.dll"
    if (-not (Test-Path $qwindowsDll)) {
        throw "No se encontro qwindows.dll despues de windeployqt: $qwindowsDll"
    }
}

if ($CleanPayload -and (Test-Path $payloadDir)) {
    Remove-Item $payloadDir -Recurse -Force
}

New-Item -Path $payloadDir -ItemType Directory -Force | Out-Null

Write-Host "==> Copiando payload a $payloadDir"
Copy-Item (Join-Path $buildConfigDir "*") $payloadDir -Recurse -Force

if (-not (Test-Path (Join-Path $payloadDir "qbittorrent.exe"))) {
    throw "No se encontro qbittorrent.exe en el payload: $payloadDir"
}

# El build enlaza el runtime de Visual C++ de forma dinamica; sin estas DLL
# qBittorrent no arranca en equipos sin el Visual C++ Redistributable.
if (-not $VcRedistDir) {
    $VcRedistDir = Find-VcRuntimeDir -Arch $CpuArch
}
if ((-not $VcRedistDir) -or (-not (Test-Path (Join-Path $VcRedistDir "vcruntime140.dll")))) {
    throw "No se encontro el runtime de Visual C++ (Microsoft.VC*.CRT\vcruntime140.dll). Instala las herramientas MSVC de Visual Studio o indica la carpeta con -VcRedistDir."
}

Write-Host "==> Copiando runtime de Visual C++ desde $VcRedistDir"
Copy-Item (Join-Path $VcRedistDir "*.dll") $payloadDir -Force

if ((Test-Path $nsisPluginsZip) -and (-not (Test-Path $nsisPluginsDir))) {
    Write-Host "==> Extrayendo NSISPlugins.zip"
    Expand-Archive $nsisPluginsZip $nsisPluginsDir -Force
}

$nsisPluginsDefine = "NSISPlugins"
if (Test-Path (Join-Path $nsisPluginsNestedDir "FindProcDLL.dll")) {
    $nsisPluginsDefine = "NSISPlugins/NSISPlugins"
}

Write-Host "==> Generando instalador con NSIS"
Push-Location $windowsDistPath
try {
    $nsisArgs = @()

    if ($Version) {
        $nsisArgs += "/DQBT_VERSION=$Version"
    }

    $nsisArgs += "/DQBT_CPU_ARCH=$CpuArch"
    $nsisArgs += "/DQBT_DIST_DIR=$PayloadDirName"
    $nsisArgs += "/DQBT_NSIS_PLUGINS_DIR=$nsisPluginsDefine"
    $nsisArgs += "qbittorrent.nsi"

    & $makensisExe @nsisArgs
    Assert-LastExitCode "makensis"
}
finally {
    Pop-Location
}

$generatedInstaller = Get-ChildItem -Path $windowsDistPath -Filter "qbittorrent_*_setup.exe" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1

if ($generatedInstaller) {
    Write-Host "Installer OK: $($generatedInstaller.FullName)"
}
else {
    Write-Warning "No se detecto automaticamente el .exe del instalador en: $windowsDistPath"
}
