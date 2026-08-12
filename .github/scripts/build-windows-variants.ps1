$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = (Get-Location).Path
$rustdeskDirectory = Join-Path $repositoryRoot 'rustdesk'
$signOutputDirectory = Join-Path $repositoryRoot 'SignOutput'
$portableDirectory = Join-Path $repositoryRoot 'libs\portable'
$msiDirectory = Join-Path $repositoryRoot 'res\msi'
$cargoTargetDirectory = if ([string]::IsNullOrWhiteSpace($env:CARGO_TARGET_DIR)) {
    Join-Path $repositoryRoot 'target'
} else {
    $env:CARGO_TARGET_DIR
}

$directionSuffixes = @{
    incoming = 'incoming'
    outgoing = 'outgoing'
    both = 'full'
}

function Clear-GeneratedMsiSection {
    param(
        [Parameter(Mandatory = $true)][string]$RelativePath,
        [Parameter(Mandatory = $true)][string]$StartMarker,
        [Parameter(Mandatory = $true)][string]$EndMarker
    )

    $path = Join-Path $msiDirectory $RelativePath
    $content = [IO.File]::ReadAllText($path)
    $startIndex = $content.IndexOf($StartMarker, [StringComparison]::Ordinal)
    $endIndex = $content.IndexOf($EndMarker, [StringComparison]::Ordinal)
    if ($startIndex -lt 0 -or $endIndex -lt 0 -or $endIndex -lt $startIndex) {
        throw "MSI generation markers not found in $RelativePath"
    }

    $prefixEnd = $startIndex + $StartMarker.Length
    $cleaned = $content.Substring(0, $prefixEnd) + "`r`n" + $content.Substring($endIndex)
    [IO.File]::WriteAllText($path, $cleaned, [Text.UTF8Encoding]::new($false))
}

function Enable-UnicodeMsi {
    $packagePath = Join-Path $msiDirectory 'Package\Package.wxs'
    $content = [IO.File]::ReadAllText($packagePath)
    if ($content -notmatch '<Package\s+Codepage=') {
        $content = $content.Replace('<Package Name=', '<Package Codepage="65001" Name=')
    }
    $content = $content.Replace('Codepage="!(loc.SummaryCodepage)"', 'Codepage="1251"')
    if ($content -notmatch '<Package\s+Codepage="65001"' -or $content -notmatch '<SummaryInformation[^>]+Codepage="1251"') {
        throw 'Could not enable Unicode MSI metadata.'
    }
    [IO.File]::WriteAllText($packagePath, $content, [Text.UTF8Encoding]::new($false))
}

$directions = @($env:directions -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($directions.Count -eq 0) {
    $directions = @('both')
}

$invalidDirections = @($directions | Where-Object { -not $directionSuffixes.ContainsKey($_) })
if ($invalidDirections.Count -gt 0) {
    throw "Unsupported connection type(s): $($invalidDirections -join ', ')"
}

$appName = $env:appname
if ([string]::IsNullOrWhiteSpace($appName)) {
    $appName = 'rustdesk'
}
$fileName = $env:filename
if ([string]::IsNullOrWhiteSpace($fileName)) {
    $fileName = 'rustdesk'
}
$directionSeparator = if ([string]::IsNullOrEmpty($env:RDGEN_DIRECTION_SEPARATOR)) { '-' } else { $env:RDGEN_DIRECTION_SEPARATOR }

$originalExecutable = Join-Path $rustdeskDirectory 'rustdesk.exe'
$applicationExecutable = Join-Path $rustdeskDirectory "$appName.exe"
if (-not (Test-Path $applicationExecutable) -and (Test-Path $originalExecutable)) {
    Move-Item $originalExecutable $applicationExecutable -Force
}
if (-not (Test-Path $applicationExecutable)) {
    throw "Application executable not found: $applicationExecutable"
}

$manifestPath = Join-Path $repositoryRoot 'res\manifest.xml'
$manifest = Get-Content $manifestPath
$manifest = @($manifest | Where-Object { $_ -notmatch 'dpiAware' })
[IO.File]::WriteAllLines($manifestPath, $manifest, [Text.UTF8Encoding]::new($false))

New-Item -ItemType Directory -Path $signOutputDirectory -Force | Out-Null

Push-Location $portableDirectory
try {
    python -m pip install -r requirements.txt
    if ($LASTEXITCODE -ne 0) { throw 'Failed to install portable packer requirements' }
}
finally {
    Pop-Location
}

Push-Location $msiDirectory
try {
    nuget restore msi.sln
    if ($LASTEXITCODE -ne 0) { throw 'NuGet restore failed' }
}
finally {
    Pop-Location
}

$msiAppName = $appName -replace '\s', '_'
if ($msiAppName -ne $appName) {
    Copy-Item $applicationExecutable (Join-Path $rustdeskDirectory "$msiAppName.exe") -Force
}

# preprocess.py appends generated WiX fragments, so it must run exactly once.
# The MSI reads custom_.txt from the dist directory during every rebuild.
$initialCustomVariable = "custom_$($directions[0])"
$initialCustomConfig = [Environment]::GetEnvironmentVariable($initialCustomVariable)
if ([string]::IsNullOrWhiteSpace($initialCustomConfig)) {
    throw "Missing configuration in $initialCustomVariable"
}
[IO.File]::WriteAllText(
    (Join-Path $rustdeskDirectory 'custom_.txt'),
    $initialCustomConfig,
    [Text.Encoding]::ASCII
)

Push-Location $msiDirectory
try {
    Enable-UnicodeMsi
    Clear-GeneratedMsiSection 'Package\Components\RustDesk.wxs' '<!--$AutoComonentStart$-->' '<!--$AutoComponentEnd$-->'
    Clear-GeneratedMsiSection 'Package\Includes.wxi' '<!--$PreVarsStart$-->' '<!--$PreVarsEnd$-->'
    Clear-GeneratedMsiSection 'Package\Fragments\Upgrades.wxs' '<!--$UpgradeStart$-->' '<!--$UpgradeEnd$-->'
    Clear-GeneratedMsiSection 'Package\Package.wxs' '<!--$CustomBitmapsStart$-->' '<!--$CustomBitmapsEnd$-->'
    Clear-GeneratedMsiSection 'Package\Fragments\AddRemoveProperties.wxs' '<!--$ArpStart$-->' '<!--$ArpEnd$-->'
    Clear-GeneratedMsiSection 'Package\Components\Regs.wxs' '<!--$ArpStart$-->' '<!--$ArpEnd$-->'
    Clear-GeneratedMsiSection 'Package\Fragments\AddRemoveProperties.wxs' '<!--$CustomClientPropsStart$-->' '<!--$CustomClientPropsEnd$-->'

    $msiManufacturer = $env:compname
    if ([string]::IsNullOrWhiteSpace($msiManufacturer)) { $msiManufacturer = 'Purslane Ltd' }
    $msiManufacturer = $msiManufacturer.Replace('&', '&amp;').Replace('"', '&quot;').Replace('<', '&lt;').Replace('>', '&gt;').Replace("'", '&apos;')
    python preprocess.py --app-name $msiAppName --arp --manufacturer $msiManufacturer -d ../../rustdesk
    if ($LASTEXITCODE -ne 0) { throw 'MSI preprocessing failed' }
}
finally {
    Pop-Location
}

foreach ($direction in $directions) {
    $suffix = $directionSuffixes[$direction]
    $customVariable = "custom_$direction"
    $customConfig = [Environment]::GetEnvironmentVariable($customVariable)
    if ([string]::IsNullOrWhiteSpace($customConfig)) {
        throw "Missing configuration in $customVariable"
    }

    [IO.File]::WriteAllText(
        (Join-Path $rustdeskDirectory 'custom_.txt'),
        $customConfig,
        [Text.Encoding]::ASCII
    )

    Push-Location $portableDirectory
    try {
        python ./generate.py -f ../../rustdesk/ -o . -e "../../rustdesk/$appName.exe"
        if ($LASTEXITCODE -ne 0) { throw "Portable EXE packaging failed for $direction" }
    }
    finally {
        Pop-Location
    }

    $portableOutput = Join-Path $cargoTargetDirectory 'release\rustdesk-portable-packer.exe'
    if (-not (Test-Path $portableOutput)) {
        throw "Portable EXE output was not created for $direction"
    }
    Move-Item $portableOutput (Join-Path $signOutputDirectory "$fileName$directionSeparator$suffix.exe") -Force

    Push-Location $msiDirectory
    try {
        msbuild msi.sln /t:Rebuild /p:Configuration=Release /p:Platform=x64 /p:TargetVersion=Windows10 /p:SuppressValidation=true
        if ($LASTEXITCODE -ne 0) { throw "MSI build failed for $direction" }

        $msiOutput = Join-Path $msiDirectory 'Package\bin\x64\Release\en-us\Package.msi'
        if (-not (Test-Path $msiOutput)) {
            throw "MSI output was not created for $direction"
        }
        Copy-Item $msiOutput (Join-Path $signOutputDirectory "$fileName$directionSeparator$suffix.msi") -Force
    }
    finally {
        Pop-Location
    }
}

Get-ChildItem $signOutputDirectory -File | Where-Object { $_.Extension -in '.exe', '.msi' } | ForEach-Object {
    Write-Host "Created $($_.Name) ($($_.Length) bytes)"
}
