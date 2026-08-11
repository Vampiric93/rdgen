param(
    [Parameter(Mandatory = $true)][string]$RuntimeDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = (Get-Location).Path
$sourceRuntime = Join-Path $repositoryRoot $RuntimeDirectory
$brandRoot = Join-Path $repositoryRoot '.rdgen-brands'
$manifestPath = Join-Path $env:RUNNER_TEMP 'rdgen-windows-brands.json'
$assetsDirectory = $env:RDGEN_ASSETS_DIR
$appName = if ([string]::IsNullOrWhiteSpace($env:appname)) { 'rustdesk' } else { $env:appname }

if (-not (Test-Path -LiteralPath $sourceRuntime -PathType Container)) {
    throw "Runtime directory not found: $sourceRuntime"
}

$brands = @()
if (-not [string]::IsNullOrWhiteSpace($env:brands_json)) {
    $brands = @($env:brands_json | ConvertFrom-Json)
}
if ($brands.Count -eq 0) {
    $brands = @([pscustomobject]@{ filename = $env:filename; icon = ''; logo = '' })
}

if (Test-Path -LiteralPath $brandRoot) {
    Remove-Item -LiteralPath $brandRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $brandRoot -Force | Out-Null

$requiresIconPatching = @($brands | Select-Object -Skip 1 | Where-Object { $_.icon }).Count -gt 0
$rcEditPath = Join-Path $env:RUNNER_TEMP 'rcedit-x64-v2.0.0.exe'
if ($requiresIconPatching -and -not (Test-Path -LiteralPath $rcEditPath -PathType Leaf)) {
    Invoke-WebRequest 'https://github.com/electron/rcedit/releases/download/v2.0.0/rcedit-x64.exe' -OutFile $rcEditPath -UseBasicParsing
    $actualHash = (Get-FileHash -LiteralPath $rcEditPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $expectedHash = '3e7801db1a5edbec91b49a24a094aad776cb4515488ea5a4ca2289c400eade2a'
    if ($actualHash -ne $expectedHash) {
        throw 'rcedit checksum mismatch'
    }
}

$prepared = @()
for ($index = 0; $index -lt $brands.Count; $index++) {
    $brand = $brands[$index]
    $destination = Join-Path $brandRoot $index
    Copy-Item -LiteralPath $sourceRuntime -Destination $destination -Recurse -Force

    if ($index -gt 0 -and $brand.logo) {
        $logoSource = Join-Path $assetsDirectory ([string]$brand.logo)
        $logoDestination = Join-Path $destination 'data\flutter_assets\assets\logo.png'
        if (-not (Test-Path -LiteralPath $logoSource -PathType Leaf)) {
            throw "Brand logo not found: $logoSource"
        }
        if (Test-Path -LiteralPath (Split-Path $logoDestination) -PathType Container) {
            Copy-Item -LiteralPath $logoSource -Destination $logoDestination -Force
        } else {
            Write-Host "Runtime has no Flutter logo asset; skipping in-app logo for $($brand.filename)."
        }
    }

    $iconPath = ''
    if ($index -gt 0 -and $brand.icon) {
        $iconSource = Join-Path $assetsDirectory ([string]$brand.icon)
        if (-not (Test-Path -LiteralPath $iconSource -PathType Leaf)) {
            throw "Brand icon not found: $iconSource"
        }
        $iconPath = Join-Path $brandRoot "brand-$index.ico"
        & magick $iconSource -define icon:auto-resize=256,64,48,32,16 $iconPath
        if ($LASTEXITCODE -ne 0) { throw "Could not create icon for $($brand.filename)" }

        $applicationExecutable = Join-Path $destination "$appName.exe"
        if (-not (Test-Path -LiteralPath $applicationExecutable -PathType Leaf)) {
            $applicationExecutable = Join-Path $destination 'rustdesk.exe'
        }
        if (-not (Test-Path -LiteralPath $applicationExecutable -PathType Leaf)) {
            throw "Application executable not found in $destination"
        }
        & $rcEditPath $applicationExecutable --set-icon $iconPath
        if ($LASTEXITCODE -ne 0) { throw "Could not patch icon for $($brand.filename)" }

        $assetDirectory = Join-Path $destination 'data\flutter_assets\assets'
        if (Test-Path -LiteralPath $assetDirectory -PathType Container) {
            Copy-Item -LiteralPath $iconSource -Destination (Join-Path $assetDirectory 'icon.png') -Force
            & magick $iconSource (Join-Path $assetDirectory 'icon.svg')
            if ($LASTEXITCODE -ne 0) { throw "Could not update UI icon for $($brand.filename)" }
        }
    }

    $prepared += [pscustomobject]@{
        filename = [string]$brand.filename
        runtime = $destination
        icon = $iconPath
    }
}

$prepared | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
Write-Host "Prepared $($prepared.Count) branded runtime(s)."
