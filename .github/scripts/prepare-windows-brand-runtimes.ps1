param(
    [Parameter(Mandatory = $true)][string]$RuntimeDirectory
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = (Get-Location).Path
$sourceRuntime = Join-Path $repositoryRoot $RuntimeDirectory
$brandRoot = Join-Path $repositoryRoot '.rdgen-brands'
$signingRoot = Join-Path $repositoryRoot '.rdgen-signing-input'
$manifestPath = Join-Path $env:RUNNER_TEMP 'rdgen-windows-brands.json'
$signingMapPath = Join-Path $env:RUNNER_TEMP 'rdgen-windows-signing-map.json'
$assetsDirectory = $env:RDGEN_ASSETS_DIR
$privacyHelperRoot = Join-Path $repositoryRoot '.rdgen-topmost'
$appName = if ([string]::IsNullOrWhiteSpace($env:appname)) { 'rustdesk' } else { $env:appname }

if (-not (Test-Path -LiteralPath $sourceRuntime -PathType Container)) {
    throw "Runtime directory not found: $sourceRuntime"
}

$brands = @()
if (-not [string]::IsNullOrWhiteSpace($env:brands_json)) {
    $brands = @($env:brands_json | ConvertFrom-Json)
}
if ($brands.Count -eq 0) {
    $brands = @([pscustomobject]@{ filename = $env:filename; icon = ''; logo = ''; privacy = '' })
}

if (Test-Path -LiteralPath $brandRoot) {
    Remove-Item -LiteralPath $brandRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $brandRoot -Force | Out-Null
if (Test-Path -LiteralPath $signingRoot) {
    Remove-Item -LiteralPath $signingRoot -Recurse -Force
}
New-Item -ItemType Directory -Path $signingRoot -Force | Out-Null

# rcedit patches the icon of every brand runtime that carries one, including the
# first (see the loop below and build-windows-brand-batch.ps1, neither of which
# skip index 0). The download guard must match that, or a config whose only
# icon-bearing brand is the first leaves rcedit absent and the loop dies with
# "rcedit-x64-v2.0.0.exe is not recognized".
$requiresIconPatching = @($brands | Where-Object { $_.icon }).Count -gt 0
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

    $privacyHelper = Join-Path (Join-Path $privacyHelperRoot $index) 'WindowInjection.dll'
    if (-not (Test-Path -LiteralPath $privacyHelper -PathType Leaf)) {
        throw "Privacy helper for brand $index was not found: $privacyHelper"
    }
    Copy-Item -LiteralPath $privacyHelper -Destination (Join-Path $destination 'WindowInjection.dll') -Force

    if ($brand.logo) {
        $logoSource = Join-Path $assetsDirectory ([string]$brand.logo)
        if (-not (Test-Path -LiteralPath $logoSource -PathType Leaf)) {
            throw "Brand logo not found: $logoSource"
        }
        # Sciter independently clamps max-width and max-height on images, which
        # can distort a non-200:60 logo. Place the original, aspect-preserving
        # image on a transparent 200x60 canvas before the runtime loads it.
        $sciterLogo = Join-Path $destination 'logo.png'
        & magick.exe $logoSource -resize '200x60>' -gravity center -background none -extent '200x60' $sciterLogo
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $sciterLogo -PathType Leaf)) {
            throw "Could not prepare aspect-preserving Sciter logo for $($brand.filename)."
        }
        $logoDestination = Join-Path $destination 'data\flutter_assets\assets\logo.png'
        if ($index -gt 0 -and (Test-Path -LiteralPath (Split-Path $logoDestination) -PathType Container)) {
            Copy-Item -LiteralPath $logoSource -Destination $logoDestination -Force
        }
    }

    $iconPath = ''
    if ($brand.icon) {
        $iconSource = Join-Path $assetsDirectory ([string]$brand.icon)
        if (-not (Test-Path -LiteralPath $iconSource -PathType Leaf)) {
            throw "Brand icon not found: $iconSource"
        }
        Copy-Item -LiteralPath $iconSource -Destination (Join-Path $destination 'icon.png') -Force
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
        if ($index -gt 0 -and (Test-Path -LiteralPath $assetDirectory -PathType Container)) {
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

# Sign each distinct binary only once. The map is later used to copy the
# signed representative back over every byte-identical occurrence.
$recordsByHash = @{}
$signingRecords = [Collections.Generic.List[object]]::new()
for ($index = 0; $index -lt $prepared.Count; $index++) {
    $runtime = [string]$prepared[$index].runtime
    $files = @(Get-ChildItem -LiteralPath $runtime -Recurse -File | Where-Object { $_.Extension -in '.exe', '.dll' })
    foreach ($file in $files) {
        $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        if ($recordsByHash.ContainsKey($hash)) {
            $recordsByHash[$hash].destinations.Add($file.FullName)
            continue
        }

        $relative = [IO.Path]::GetRelativePath($runtime, $file.FullName)
        $destination = Join-Path (Join-Path $signingRoot $index) $relative
        New-Item -ItemType Directory -Path (Split-Path $destination) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $destination -Force

        $record = [pscustomobject]@{
            source = $file.FullName
            destinations = [Collections.Generic.List[string]]::new()
        }
        $record.destinations.Add($file.FullName)
        $recordsByHash[$hash] = $record
        $signingRecords.Add($record)
    }
}

$signingRecords | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $signingMapPath -Encoding UTF8
$signingCount = @(Get-ChildItem -LiteralPath $signingRoot -Recurse -File).Count
Write-Host "Prepared $($prepared.Count) branded runtime(s) and $signingCount unique signing inputs."
