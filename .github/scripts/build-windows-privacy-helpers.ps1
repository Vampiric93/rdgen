param(
    [Parameter(Mandatory = $true)][string]$SourceDirectory,
    [Parameter(Mandatory = $true)][string]$Configuration,
    [Parameter(Mandatory = $true)][string]$Platform,
    [Parameter(Mandatory = $true)][string]$TargetVersion
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = (Get-Location).Path
$sourceRoot = Join-Path $repositoryRoot $SourceDirectory
$projectPath = Join-Path $sourceRoot 'WindowInjection\WindowInjection.vcxproj'
$imageCppPath = Join-Path $sourceRoot 'WindowInjection\img.cpp'
$privacyScript = Join-Path $repositoryRoot '.github\patches\privacyScreen.py'
$assetsDirectory = $env:RDGEN_ASSETS_DIR
$outputRoot = Join-Path $repositoryRoot 'rdgen-topmost-output'

if (-not (Test-Path -LiteralPath $projectPath -PathType Leaf)) {
    throw "Privacy helper project was not found: $projectPath"
}
if (-not (Test-Path -LiteralPath $privacyScript -PathType Leaf)) {
    throw "Privacy image converter was not found: $privacyScript"
}

$brands = @()
if (-not [string]::IsNullOrWhiteSpace($env:brands_json)) {
    $brands = @($env:brands_json | ConvertFrom-Json)
}
if ($brands.Count -eq 0) {
    $brands = @([pscustomobject]@{ filename = $env:filename; privacy = '' })
}

if (Test-Path -LiteralPath $outputRoot) {
    Remove-Item -LiteralPath $outputRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

$originalImageCpp = [IO.File]::ReadAllBytes($imageCppPath)
$builtHelpers = @{}
try {
    for ($index = 0; $index -lt $brands.Count; $index++) {
        $brand = $brands[$index]
        $privacyName = if ($brand.PSObject.Properties.Name -contains 'privacy') {
            [string]$brand.privacy
        } else {
            ''
        }
        $privacyPath = ''
        $buildKey = 'default'
        if (-not [string]::IsNullOrWhiteSpace($privacyName)) {
            $privacyPath = Join-Path $assetsDirectory $privacyName
            if (-not (Test-Path -LiteralPath $privacyPath -PathType Leaf)) {
                throw "Privacy image for brand $index was not found: $privacyPath"
            }
            $buildKey = (Get-FileHash -LiteralPath $privacyPath -Algorithm SHA256).Hash
        }

        $brandOutput = Join-Path (Join-Path $outputRoot $index) 'WindowInjection.dll'
        New-Item -ItemType Directory -Path (Split-Path $brandOutput) -Force | Out-Null
        if ($builtHelpers.ContainsKey($buildKey)) {
            Copy-Item -LiteralPath $builtHelpers[$buildKey] -Destination $brandOutput -Force
            Write-Host "Reused privacy helper for brand $index."
            continue
        }

        [IO.File]::WriteAllBytes($imageCppPath, $originalImageCpp)
        if ($privacyPath) {
            Copy-Item -LiteralPath $privacyPath -Destination (Join-Path $sourceRoot 'privacy.png') -Force
            Push-Location $sourceRoot
            try {
                & python $privacyScript
                if ($LASTEXITCODE -ne 0) { throw "Could not convert privacy image for brand $index." }
                Move-Item -LiteralPath (Join-Path $sourceRoot 'img.cpp') -Destination $imageCppPath -Force
            } finally {
                Pop-Location
            }
        }

        & msbuild $projectPath /t:Rebuild "-p:Configuration=$Configuration" "-p:Platform=$Platform" "/p:TargetVersion=$TargetVersion" '-p:PlatformToolset=v143'
        if ($LASTEXITCODE -ne 0) { throw "Privacy helper build failed for brand $index." }

        $builtDll = if ($Platform -eq 'Win32') {
            Join-Path $sourceRoot "WindowInjection\$Configuration\WindowInjection.dll"
        } else {
            Join-Path $sourceRoot "WindowInjection\$Platform\$Configuration\WindowInjection.dll"
        }
        if (-not (Test-Path -LiteralPath $builtDll -PathType Leaf)) {
            throw "Built privacy helper was not found: $builtDll"
        }
        Copy-Item -LiteralPath $builtDll -Destination $brandOutput -Force
        $builtHelpers[$buildKey] = $brandOutput
        Write-Host "Built privacy helper for brand $index."
    }
} finally {
    [IO.File]::WriteAllBytes($imageCppPath, $originalImageCpp)
}

Write-Host "Prepared $($brands.Count) brand-specific privacy helper(s) from $($builtHelpers.Count) unique image(s)."
