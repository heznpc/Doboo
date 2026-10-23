# Dot-source this file to configure only the current PowerShell process.
[CmdletBinding()]
param(
    [string]$SwiftRoot = (Join-Path $env:LOCALAPPDATA 'Programs\Swift'),
    [string]$SwiftVersion = '6.4.1'
)

$swiftBin = Join-Path $SwiftRoot "Toolchains\$SwiftVersion+Asserts\usr\bin"
$swiftRuntime = Join-Path $SwiftRoot "Runtimes\$SwiftVersion\usr\bin"
$swiftSdk = Join-Path $SwiftRoot "Platforms\$SwiftVersion\Windows.platform\Developer\SDKs\Windows.sdk"
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'

foreach ($required in @((Join-Path $swiftBin 'swift.exe'), $swiftSdk, $vswhere)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required Swift/MSVC component is missing: $required"
    }
}

$vsInstallation = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsInstallation) {
    throw 'Install Visual Studio 2022 Build Tools with MSVC x64/x86 and a Windows 11 SDK first.'
}
Import-Module (Join-Path $vsInstallation 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $vsInstallation -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null

$env:SDKROOT = $swiftSdk
$swiftPaths = @($swiftBin)
if (Test-Path -LiteralPath $swiftRuntime) {
    $swiftPaths += $swiftRuntime
}
$env:Path = ($swiftPaths -join ';') + ';' + $env:Path
& (Join-Path $swiftBin 'swift.exe') --version
if ($LASTEXITCODE -ne 0) {
    throw 'Swift could not start. Check the toolchain and Visual C++ runtime installation.'
}
