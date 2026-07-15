param(
    [string]$ConfigPath = "$PSScriptRoot\deploy-config.psd1",
    [string]$WarPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    throw "設定ファイルが見つかりません: $ConfigPath"
}

$Config = Import-PowerShellDataFile -Path $ConfigPath

$ServerHost         = $Config.ServerHost
$ServerUser         = $Config.ServerUser
$RemoteTemporaryDir = $Config.RemoteTemporaryDir
$RemoteDeployScript = $Config.RemoteDeployScript

if ([string]::IsNullOrWhiteSpace($WarPath)) {
    $WarPath = Join-Path $PSScriptRoot $Config.WarFileName
}