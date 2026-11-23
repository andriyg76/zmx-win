# Runs the Windows integration suite against zig-out\bin\zmx.exe (or -Zmx).
#   pwsh test/windows/run.ps1                   # sessions run zmx's default shell, PowerShell
#   pwsh test/windows/run.ps1 -Shell cmd.exe    # sessions run cmd
param(
    [string]$Shell,
    [string]$Zmx,
    [string]$ResultPath
)
$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion 5.5

if ($Shell) { $env:ZMX_TEST_SHELL = $Shell } else { Remove-Item Env:ZMX_TEST_SHELL -ErrorAction SilentlyContinue }
if ($Zmx) { $env:ZMX_TEST_EXE = (Resolve-Path $Zmx).Path }

$config = New-PesterConfiguration
$config.Run.Path = $PSScriptRoot
$config.Run.Exit = $true
$config.Output.Verbosity = 'Detailed'
if ($ResultPath) {
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputFormat = 'JUnitXml'
    $config.TestResult.OutputPath = $ResultPath
}
Invoke-Pester -Configuration $config
