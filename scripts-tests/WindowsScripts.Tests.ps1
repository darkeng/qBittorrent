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

foreach ($dir in $script:sandboxes) {
    Remove-Item $dir -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failures -gt 0) {
    Write-Host "$($script:failures) prueba(s) fallaron." -ForegroundColor Red
    exit 1
}

Write-Host "Todas las pruebas pasaron." -ForegroundColor Green
