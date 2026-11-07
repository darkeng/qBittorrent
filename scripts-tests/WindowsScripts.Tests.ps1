<#
Pruebas de regresion para build.ps1 e installer.ps1.

Cada prueba copia los scripts a un directorio temporal y los ejecuta con
herramientas falsas (cmake, windeployqt, makensis) que registran sus
argumentos y pueden simular fallos. No compilan nada ni tocan el repositorio.

Uso:
    powershell -NoProfile -ExecutionPolicy Bypass -File scripts-tests\WindowsScripts.Tests.ps1
#>

$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent $PSScriptRoot
$script:failures = 0
$script:sandboxes = New-Object System.Collections.Generic.List[string]

function New-Sandbox {
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ("qbt-scripts-test-" + [guid]::NewGuid().ToString("N"))
    $sandbox = [pscustomobject]@{
        Root    = $root
        Bin     = Join-Path $root "fake-bin"
        Profile = Join-Path $root "fake-profile"
        Log     = Join-Path $root "calls.log"
    }

    New-Item -ItemType Directory -Path $sandbox.Bin -Force | Out-Null
    $toolchainDir = Join-Path $sandbox.Profile "vcpkg\scripts\buildsystems"
    New-Item -ItemType Directory -Path $toolchainDir -Force | Out-Null
    New-Item -ItemType File -Path (Join-Path $toolchainDir "vcpkg.cmake") | Out-Null
    New-Item -ItemType File -Path $sandbox.Log | Out-Null

    foreach ($name in @("build.ps1", "installer.ps1")) {
        Copy-Item (Join-Path $repoRoot $name) $root
    }

    $script:sandboxes.Add($root)
    return $sandbox
}

function Set-FakeTool {
    param(
        $Sandbox,
        [string]$Name,
        [string]$FailWhenArgsContain,
        [switch]$AlwaysFail
    )

    $lines = @(
        "@echo off",
        "echo $Name %*>>`"%FAKE_LOG%`""
    )
    if ($AlwaysFail) {
        $lines += "exit /b 1"
    }
    elseif ($FailWhenArgsContain) {
        $lines += "echo %*| findstr /L /C:`"$FailWhenArgsContain`" >nul && exit /b 1"
    }
    $lines += "exit /b 0"

    Set-Content -Path (Join-Path $Sandbox.Bin "$Name.cmd") -Value $lines -Encoding Ascii
}

function New-StaleFile {
    param($Sandbox, [string]$RelativePath)

    $path = Join-Path $Sandbox.Root $RelativePath
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    Set-Content -Path $path -Value "stale"
}

function New-FakeVcRuntime {
    param($Sandbox)

    foreach ($dll in @("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll")) {
        New-StaleFile $Sandbox "fake-crt\$dll"
    }
    return (Join-Path $Sandbox.Root "fake-crt")
}

function Invoke-ScriptUnderTest {
    param($Sandbox, [string]$Script, [string[]]$Arguments)

    $savedPath = $env:PATH
    $savedProfile = $env:USERPROFILE
    $savedPreference = $ErrorActionPreference
    try {
        $env:PATH = "$($Sandbox.Bin);$env:PATH"
        $env:USERPROFILE = $Sandbox.Profile
        $env:FAKE_LOG = $Sandbox.Log
        # Evita que la salida de error del proceso hijo se convierta en excepcion.
        $ErrorActionPreference = "Continue"

        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Sandbox.Root $Script) @Arguments 2>&1 | Out-String
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = $output
            Calls    = "$(Get-Content $Sandbox.Log -Raw)"
        }
    }
    finally {
        $ErrorActionPreference = $savedPreference
        $env:PATH = $savedPath
        $env:USERPROFILE = $savedProfile
        Remove-Item Env:FAKE_LOG -ErrorAction SilentlyContinue
    }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) {
        throw $Message
    }
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)

    try {
        & $Body
        Write-Host "[PASS] $Name" -ForegroundColor Green
    }
    catch {
        $script:failures++
        Write-Host "[FAIL] $Name" -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)"
    }
}

Test-Case "build.ps1 pasa a CMake la ruta real del toolchain de vcpkg" {
    $sb = New-Sandbox
    Set-FakeTool $sb "cmake"

    $result = Invoke-ScriptUnderTest $sb "build.ps1" @("-Configuration", "Release", "-SkipQtDeploy")

    $expected = "-DCMAKE_TOOLCHAIN_FILE=" + (Join-Path (Join-Path $sb.Profile "vcpkg") "scripts/buildsystems/vcpkg.cmake")
    Assert-True ($result.Calls -notmatch '\$toolchainFile') "CMake recibio el texto literal `$toolchainFile en lugar de la ruta. Llamadas: $($result.Calls)"
    Assert-True ($result.Calls.Contains($expected)) "No se encontro '$expected'. Llamadas: $($result.Calls)"
}

Test-Case "build.ps1 se detiene si falla la configuracion de CMake" {
    $sb = New-Sandbox
    Set-FakeTool $sb "cmake" -FailWhenArgsContain "-G"

    $result = Invoke-ScriptUnderTest $sb "build.ps1" @("-Configuration", "Release", "-SkipQtDeploy")

    Assert-True ($result.ExitCode -ne 0) "build.ps1 termino con codigo 0 aunque la configuracion fallo"
    Assert-True ($result.Calls -notmatch "--build") "build.ps1 siguio compilando despues de una configuracion fallida"
}

Test-Case "build.ps1 falla y no reporta 'Build OK' si la compilacion falla con un .exe viejo presente" {
    $sb = New-Sandbox
    Set-FakeTool $sb "cmake" -FailWhenArgsContain "--build"
    New-StaleFile $sb "build\Release\qbittorrent.exe"

    $result = Invoke-ScriptUnderTest $sb "build.ps1" @("-Configuration", "Release", "-SkipQtDeploy")

    Assert-True ($result.ExitCode -ne 0) "build.ps1 termino con codigo 0 aunque la compilacion fallo"
    Assert-True ($result.Output -notmatch "Build OK") "build.ps1 reporto 'Build OK' con un ejecutable viejo"
}

Test-Case "build.ps1 falla si windeployqt falla" {
    $sb = New-Sandbox
    Set-FakeTool $sb "cmake"
    Set-FakeTool $sb "windeployqt" -AlwaysFail
    New-StaleFile $sb "build\Release\qbittorrent.exe"
    New-StaleFile $sb "build\Release\platforms\qwindows.dll"

    $result = Invoke-ScriptUnderTest $sb "build.ps1" @("-Configuration", "Release")

    Assert-True ($result.ExitCode -ne 0) "build.ps1 termino con codigo 0 aunque windeployqt fallo"
    Assert-True ($result.Output -notmatch "Build OK") "build.ps1 reporto 'Build OK' aunque windeployqt fallo"
}

Test-Case "installer.ps1 falla si build.ps1 falla" {
    $sb = New-Sandbox
    Set-FakeTool $sb "cmake" -FailWhenArgsContain "--build"
    Set-FakeTool $sb "makensis"
    New-StaleFile $sb "build\Release\qbittorrent.exe"
    New-StaleFile $sb "dist\windows\qbittorrent.nsi"
    New-StaleFile $sb "dist\windows\qbittorrent_0.0.0_x64_setup.exe"

    $result = Invoke-ScriptUnderTest $sb "installer.ps1" @("-Configuration", "Release", "-SkipQtDeploy")

    Assert-True ($result.ExitCode -ne 0) "installer.ps1 termino con codigo 0 aunque la compilacion fallo"
    Assert-True ($result.Calls -notmatch "makensis") "installer.ps1 genero el instalador despues de una compilacion fallida"
}

Test-Case "installer.ps1 falla si windeployqt falla con un qwindows.dll viejo presente" {
    $sb = New-Sandbox
    Set-FakeTool $sb "windeployqt" -AlwaysFail
    Set-FakeTool $sb "makensis"
    New-StaleFile $sb "build\Release\qbittorrent.exe"
    New-StaleFile $sb "build\Release\platforms\qwindows.dll"
    New-StaleFile $sb "dist\windows\qbittorrent.nsi"

    $result = Invoke-ScriptUnderTest $sb "installer.ps1" @("-Configuration", "Release", "-SkipBuild")

    Assert-True ($result.ExitCode -ne 0) "installer.ps1 termino con codigo 0 aunque windeployqt fallo"
    Assert-True ($result.Calls -notmatch "makensis") "installer.ps1 genero el instalador aunque windeployqt fallo"
}

Test-Case "installer.ps1 falla y no reporta un instalador viejo si makensis falla" {
    $sb = New-Sandbox
    Set-FakeTool $sb "makensis" -AlwaysFail
    New-StaleFile $sb "build\Release\qbittorrent.exe"
    New-StaleFile $sb "dist\windows\qbittorrent.nsi"
    New-StaleFile $sb "dist\windows\qbittorrent_0.0.0_x64_setup.exe"

    $crtDir = New-FakeVcRuntime $sb

    $result = Invoke-ScriptUnderTest $sb "installer.ps1" @("-Configuration", "Release", "-SkipBuild", "-SkipQtDeploy", "-VcRedistDir", $crtDir)

    Assert-True ($result.ExitCode -ne 0) "installer.ps1 termino con codigo 0 aunque makensis fallo"
    Assert-True ($result.Output -notmatch "Installer OK") "installer.ps1 reporto un instalador viejo como resultado"
}

Test-Case "installer.ps1 incluye el runtime de Visual C++ en el payload" {
    $sb = New-Sandbox
    Set-FakeTool $sb "makensis"
    New-StaleFile $sb "build\Release\qbittorrent.exe"
    New-StaleFile $sb "dist\windows\qbittorrent.nsi"
    $crtDir = New-FakeVcRuntime $sb

    $result = Invoke-ScriptUnderTest $sb "installer.ps1" @("-Configuration", "Release", "-SkipBuild", "-SkipQtDeploy", "-VcRedistDir", $crtDir)

    Assert-True ($result.ExitCode -eq 0) "installer.ps1 fallo: $($result.Output)"
    foreach ($dll in @("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll")) {
        Assert-True (Test-Path (Join-Path $sb.Root "dist\windows\qBittorrent\$dll")) "Falta $dll en el payload"
    }
}

Test-Case "installer.ps1 falla si no encuentra el runtime de Visual C++" {
    $sb = New-Sandbox
    Set-FakeTool $sb "makensis"
    New-StaleFile $sb "build\Release\qbittorrent.exe"
    New-StaleFile $sb "dist\windows\qbittorrent.nsi"

    $result = Invoke-ScriptUnderTest $sb "installer.ps1" @("-Configuration", "Release", "-SkipBuild", "-SkipQtDeploy", "-VcRedistDir", (Join-Path $sb.Root "no-existe"))

    Assert-True ($result.ExitCode -ne 0) "installer.ps1 termino con codigo 0 sin runtime de Visual C++"
    Assert-True ($result.Calls -notmatch "makensis") "installer.ps1 genero el instalador sin runtime de Visual C++"
}

Test-Case "uninstaller.nsh elimina todo lo que installer.ps1 empaqueta" {
    # Contenido de primer nivel del payload que arma installer.ps1 (windeployqt de Qt 6 + runtime de Visual C++).
    $payloadFiles = @(
        "qbittorrent.exe", "qbittorrent.pdb", "Qt6Core.dll", "Qt6Gui.dll", "Qt6Network.dll", "Qt6Sql.dll",
        "Qt6Svg.dll", "Qt6Widgets.dll", "Qt6Xml.dll", "D3Dcompiler_47.dll", "torrent-rasterbar.dll",
        "libcrypto-3-x64.dll", "libssl-3-x64.dll", "zlib1.dll", "icuuc78.dll", "msvcp140.dll", "vcruntime140.dll"
    )
    $payloadDirs = @(
        "generic", "iconengines", "imageformats", "networkinformation", "platforms", "sqldrivers", "styles",
        "tls", "translations"
    )

    $uninstaller = Get-Content (Join-Path $repoRoot "dist\windows\uninstaller.nsh") -Raw
    $deletePatterns = [regex]::Matches($uninstaller, '(?m)^\s*Delete\s+"\$INSTDIR\\([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
    $removedDirs = [regex]::Matches($uninstaller, '(?m)^\s*RMDir\s+/r\s+"\$INSTDIR\\([^"]+)"') | ForEach-Object { $_.Groups[1].Value }

    $leftovers = @()
    foreach ($file in $payloadFiles) {
        if (-not ($deletePatterns | Where-Object { $file -like $_ })) {
            $leftovers += $file
        }
    }
    foreach ($dir in $payloadDirs) {
        if ($removedDirs -notcontains $dir) {
            $leftovers += "$dir\"
        }
    }

    Assert-True ($leftovers.Count -eq 0) "El desinstalador dejaria: $($leftovers -join ', ')"
}

foreach ($dir in $script:sandboxes) {
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failures -gt 0) {
    Write-Host "$($script:failures) prueba(s) fallaron." -ForegroundColor Red
    exit 1
}

Write-Host "Todas las pruebas pasaron." -ForegroundColor Green
