param(
    [switch]$PatchMsiOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = (Get-Location).Path
$rustdeskDirectory = Join-Path $repositoryRoot 'Release'
$signOutputDirectory = Join-Path $repositoryRoot 'SignOutput'
$portableDirectory = Join-Path $repositoryRoot 'libs\portable'
$msiDirectory = Join-Path $repositoryRoot 'res\msi'

$directionSuffixes = @{
    incoming = 'incoming'
    outgoing = 'outgoing'
    both = 'full'
}

function Copy-XmlConfiguration {
    param(
        [Parameter(Mandatory = $true)][System.Xml.XmlNode]$Source,
        [Parameter(Mandatory = $true)][System.Xml.XmlNode]$Parent,
        [Parameter(Mandatory = $true)][string]$OldValue,
        [Parameter(Mandatory = $true)][string]$NewValue
    )

    $clone = $Source.CloneNode($true)
    foreach ($attribute in @($clone.Attributes)) {
        $attribute.Value = $attribute.Value.Replace($OldValue, $NewValue)
    }
    foreach ($node in @($clone.SelectNodes('.//*'))) {
        foreach ($attribute in @($node.Attributes)) {
            $attribute.Value = $attribute.Value.Replace($OldValue, $NewValue)
        }
        if (-not $node.HasChildNodes -or ($node.ChildNodes.Count -eq 1 -and $node.FirstChild.NodeType -eq 'Text')) {
            $node.InnerText = $node.InnerText.Replace($OldValue, $NewValue)
        }
    }
    [void]$Parent.InsertAfter($clone, $Source)
}

function Enable-X86MsiBuild {
    $customActionsPath = Join-Path $msiDirectory 'CustomActions\CustomActions.vcxproj'
    [xml]$customActions = Get-Content -LiteralPath $customActionsPath -Raw
    $namespace = [Xml.XmlNamespaceManager]::new($customActions.NameTable)
    $namespace.AddNamespace('m', 'http://schemas.microsoft.com/developer/msbuild/2003')
    $x64Condition = '''$(Configuration)|$(Platform)''==''Release|x64'''

    if (-not $customActions.SelectSingleNode("//m:ProjectConfiguration[@Include='Release|Win32']", $namespace)) {
        $configuration = $customActions.SelectSingleNode("//m:ProjectConfiguration[@Include='Release|x64']", $namespace)
        Copy-XmlConfiguration $configuration $configuration.ParentNode 'x64' 'Win32'

        foreach ($elementName in @('PropertyGroup', 'ImportGroup', 'ItemDefinitionGroup')) {
            $source = @($customActions.SelectNodes("//m:$elementName", $namespace) |
                Where-Object { $_.Attributes['Condition'] -and $_.Attributes['Condition'].Value -eq $x64Condition })[0]
            Copy-XmlConfiguration $source $source.ParentNode 'x64' 'Win32'
        }

        $pch = $customActions.SelectSingleNode("//m:ClCompile[@Include='pch.cpp']", $namespace)
        $pchSetting = @($pch.SelectNodes('m:PrecompiledHeader', $namespace) |
            Where-Object { $_.Attributes['Condition'] -and $_.Attributes['Condition'].Value -eq $x64Condition })[0]
        Copy-XmlConfiguration $pchSetting $pchSetting.ParentNode 'x64' 'Win32'
        $customActions.Save($customActionsPath)
    }

    $wixProjectPath = Join-Path $msiDirectory 'Package\Package.wixproj'
    $wixProject = [IO.File]::ReadAllText($wixProjectPath)
    if ($wixProject -notmatch '<Platforms>[^<]*x86') {
        $wixProject = $wixProject.Replace('<Platforms>x64;ARM64</Platforms>', '<Platforms>x86;x64;ARM64</Platforms>')
        [IO.File]::WriteAllText($wixProjectPath, $wixProject, [Text.UTF8Encoding]::new($false))
    }

    $solutionPath = Join-Path $msiDirectory 'msi.sln'
    $solution = [IO.File]::ReadAllText($solutionPath)
    if ($solution -notmatch '(?m)^\s*Release\|x86 = Release\|x86\s*$') {
        $configurationRegex = [regex]::new('(?m)^(\s*)Release\|x64 = Release\|x64\s*$')
        $solution = $configurationRegex.Replace($solution, "`$1Release|x86 = Release|x86`r`n`$0", 1)

        $packageGuid = [regex]::Match($solution, '(?m)^Project\("\{[^}]+\}"\) = "Package",.*"(\{[^}]+\})"\s*$').Groups[1].Value
        $customActionsGuid = [regex]::Match($solution, '(?m)^Project\("\{[^}]+\}"\) = "CustomActions",.*"(\{[^}]+\})"\s*$').Groups[1].Value
        if (-not $packageGuid -or -not $customActionsGuid) {
            throw 'Could not identify MSI project GUIDs in msi.sln'
        }

        $packageMapping = "`t`t$packageGuid.Release|x86.ActiveCfg = Release|x86`r`n`t`t$packageGuid.Release|x86.Build.0 = Release|x86`r`n"
        $customActionsMapping = "`t`t$customActionsGuid.Release|x86.ActiveCfg = Release|Win32`r`n`t`t$customActionsGuid.Release|x86.Build.0 = Release|Win32`r`n"
        $mappingMarker = "`t`t$packageGuid.Release|x64.ActiveCfg = Release|x64"
        $solution = $solution.Replace($mappingMarker, $packageMapping + $customActionsMapping + $mappingMarker)
        [IO.File]::WriteAllText($solutionPath, $solution, [Text.UTF8Encoding]::new($false))
    }
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

Enable-X86MsiBuild
if ($PatchMsiOnly) {
    Write-Host 'MSI projects are configured for x86.'
    exit 0
}

$directions = @($env:directions -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($directions.Count -eq 0) {
    $directions = @('both')
}

$invalidDirections = @($directions | Where-Object { -not $directionSuffixes.ContainsKey($_) })
if ($invalidDirections.Count -gt 0) {
    throw "Unsupported connection type(s): $($invalidDirections -join ', ')"
}

$appName = if ([string]::IsNullOrWhiteSpace($env:appname)) { 'rustdesk' } else { $env:appname }
$fileName = if ([string]::IsNullOrWhiteSpace($env:filename)) { 'rustdesk' } else { $env:filename }
$directionSeparator = if ([string]::IsNullOrEmpty($env:RDGEN_DIRECTION_SEPARATOR)) { '-' } else { $env:RDGEN_DIRECTION_SEPARATOR }
$originalExecutable = Join-Path $rustdeskDirectory 'rustdesk.exe'
$applicationExecutable = Join-Path $rustdeskDirectory "$appName.exe"

if (-not (Test-Path -LiteralPath $applicationExecutable) -and (Test-Path -LiteralPath $originalExecutable)) {
    Move-Item -LiteralPath $originalExecutable -Destination $applicationExecutable -Force
}
if (-not (Test-Path -LiteralPath $applicationExecutable -PathType Leaf)) {
    throw "Application executable not found: $applicationExecutable"
}

$manifestPath = Join-Path $repositoryRoot 'res\manifest.xml'
$manifest = @(Get-Content -LiteralPath $manifestPath | Where-Object { $_ -notmatch 'dpiAware' })
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
    Copy-Item -LiteralPath $applicationExecutable -Destination (Join-Path $rustdeskDirectory "$msiAppName.exe") -Force
}

$initialCustomVariable = "custom_$($directions[0])"
$initialCustomConfig = [Environment]::GetEnvironmentVariable($initialCustomVariable)
if ([string]::IsNullOrWhiteSpace($initialCustomConfig)) {
    throw "Missing configuration in $initialCustomVariable"
}
[IO.File]::WriteAllText((Join-Path $rustdeskDirectory 'custom.txt'), $initialCustomConfig, [Text.Encoding]::ASCII)

Push-Location $msiDirectory
try {
    Clear-GeneratedMsiSection 'Package\Components\RustDesk.wxs' '<!--$AutoComonentStart$-->' '<!--$AutoComponentEnd$-->'
    Clear-GeneratedMsiSection 'Package\Includes.wxi' '<!--$PreVarsStart$-->' '<!--$PreVarsEnd$-->'
    Clear-GeneratedMsiSection 'Package\Fragments\Upgrades.wxs' '<!--$UpgradeStart$-->' '<!--$UpgradeEnd$-->'
    Clear-GeneratedMsiSection 'Package\Package.wxs' '<!--$CustomBitmapsStart$-->' '<!--$CustomBitmapsEnd$-->'
    Clear-GeneratedMsiSection 'Package\Fragments\AddRemoveProperties.wxs' '<!--$ArpStart$-->' '<!--$ArpEnd$-->'
    Clear-GeneratedMsiSection 'Package\Components\Regs.wxs' '<!--$ArpStart$-->' '<!--$ArpEnd$-->'
    Clear-GeneratedMsiSection 'Package\Fragments\AddRemoveProperties.wxs' '<!--$CustomClientPropsStart$-->' '<!--$CustomClientPropsEnd$-->'

    python preprocess.py --app-name $msiAppName --arp -d ../../Release
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

    [IO.File]::WriteAllText((Join-Path $rustdeskDirectory 'custom.txt'), $customConfig, [Text.Encoding]::ASCII)

    Push-Location $portableDirectory
    try {
        python ./generate.py -f ../../Release/ -o . -e "../../Release/$appName.exe"
        if ($LASTEXITCODE -ne 0) { throw "Portable EXE packaging failed for $direction" }
    }
    finally {
        Pop-Location
    }

    $portableOutput = Join-Path $repositoryRoot 'target\release\rustdesk-portable-packer.exe'
    if (-not (Test-Path -LiteralPath $portableOutput -PathType Leaf)) {
        throw "Portable EXE output was not created for $direction"
    }
    Move-Item -LiteralPath $portableOutput -Destination (Join-Path $signOutputDirectory "$fileName$directionSeparator$suffix.exe") -Force

    Push-Location $msiDirectory
    try {
        msbuild msi.sln /t:Rebuild /p:Configuration=Release /p:Platform=x86 /p:TargetVersion=Windows10 /p:SuppressValidation=true
        if ($LASTEXITCODE -ne 0) { throw "MSI build failed for $direction" }

        $msiOutput = Get-ChildItem -LiteralPath (Join-Path $msiDirectory 'Package\bin') -Filter Package.msi -Recurse -File |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1
        if (-not $msiOutput) {
            throw "MSI output was not created for $direction"
        }
        Copy-Item -LiteralPath $msiOutput.FullName -Destination (Join-Path $signOutputDirectory "$fileName$directionSeparator$suffix.msi") -Force
    }
    finally {
        Pop-Location
    }
}

$artifactPrefix = "$fileName$directionSeparator"
$artifacts = @(Get-ChildItem -LiteralPath $signOutputDirectory -File | Where-Object {
    $_.Extension -in '.exe', '.msi' -and $_.BaseName.StartsWith($artifactPrefix, [StringComparison]::OrdinalIgnoreCase)
})
$expectedCount = $directions.Count * 2
if ($artifacts.Count -ne $expectedCount) {
    throw "Expected $expectedCount x86 artifacts, found $($artifacts.Count)"
}
$artifacts | ForEach-Object { Write-Host "Created $($_.Name) ($($_.Length) bytes)" }
