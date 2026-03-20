param(
    [string]$VcpkgRoot = "$env:USERPROFILE\vcpkg",
    [string]$Triplet = "x64-windows",
    [switch]$CheckOnly
)

$ErrorActionPreference = "Stop"

function Test-GitInstalled {
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if (-not $gitCmd) {
        throw "No se encontro git en PATH. Instala Git for Windows para continuar."
    }
}

function Get-VcpkgExecutable {
    param(
        [string]$RootPath
    )

    $vcpkgExe = Join-Path $RootPath "vcpkg.exe"
    if (Test-Path $vcpkgExe) {
        return $vcpkgExe
    }

    Test-GitInstalled

    if (-not (Test-Path $RootPath)) {
        Write-Host "==> Clonando vcpkg en $RootPath"
        git clone https://github.com/microsoft/vcpkg.git $RootPath
    }

    $bootstrapBat = Join-Path $RootPath "bootstrap-vcpkg.bat"
    if (-not (Test-Path $bootstrapBat)) {
        throw "No se encontro bootstrap-vcpkg.bat en $RootPath"
    }

    Write-Host "==> Bootstrapeando vcpkg"
    & $bootstrapBat -disableMetrics

    if (-not (Test-Path $vcpkgExe)) {
        throw "No se pudo generar vcpkg.exe en $RootPath"
    }

    return $vcpkgExe
}

function Test-VcpkgPackageInstalled {
    param(
        [string]$VcpkgExe,
        [string]$Package,
        [string]$TripletName
    )

    $spec = "$Package`:$TripletName"
    $output = & $VcpkgExe list $spec | Out-String
    return $output -match "(?m)^$([regex]::Escape($spec))\s"
}

$requiredPackages = @(
    "boost-circular-buffer",
    "boost-stacktrace",
    "openssl",
    "zlib",
    "qtbase",
    "qtsvg",
    "qttools",
    "libtorrent"
)

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

$vcpkgExe = Get-VcpkgExecutable -RootPath $VcpkgRoot

$missing = New-Object System.Collections.Generic.List[string]
foreach ($pkg in $requiredPackages) {
    if (Test-VcpkgPackageInstalled -VcpkgExe $vcpkgExe -Package $pkg -TripletName $Triplet) {
        Write-Host ("[OK] {0}:{1}" -f $pkg, $Triplet)
    }
    else {
        Write-Host ("[MISSING] {0}:{1}" -f $pkg, $Triplet)
        [void]$missing.Add(("{0}:{1}" -f $pkg, $Triplet))
    }
}

if ($missing.Count -eq 0) {
    Write-Host "Todas las dependencias requeridas ya estan instaladas."
    exit 0
}

if ($CheckOnly) {
    Write-Warning "Hay dependencias faltantes. Ejecuta sin -CheckOnly para instalarlas."
    exit 1
}

Write-Host "==> Instalando dependencias faltantes con vcpkg"
& $vcpkgExe install @missing

Write-Host "==> Verificacion final"
$stillMissing = @()
foreach ($spec in $missing) {
    $parts = $spec.Split(":")
    if (-not (Test-VcpkgPackageInstalled -VcpkgExe $vcpkgExe -Package $parts[0] -TripletName $parts[1])) {
        $stillMissing += $spec
    }
}

if ($stillMissing.Count -gt 0) {
    throw "Fallo la instalacion de: $($stillMissing -join ', ')"
}

Write-Host "Dependencias instaladas correctamente."
