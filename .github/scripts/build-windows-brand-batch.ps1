param(
    [Parameter(Mandatory = $true)][string]$RuntimeDirectory,
    [Parameter(Mandatory = $true)][string]$VariantScript
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = (Get-Location).Path
$activeRuntime = Join-Path $repositoryRoot $RuntimeDirectory
$manifestPath = Join-Path $env:RUNNER_TEMP 'rdgen-windows-brands.json'
$brands = @(Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json)
if ($brands.Count -eq 0) { throw 'No branded runtimes were prepared.' }

for ($index = 0; $index -lt $brands.Count; $index++) {
    $brand = $brands[$index]
    if (Test-Path -LiteralPath $activeRuntime) {
        Remove-Item -LiteralPath $activeRuntime -Recurse -Force
    }
    Copy-Item -LiteralPath ([string]$brand.runtime) -Destination $activeRuntime -Recurse -Force
    $env:filename = [string]$brand.filename
    $env:RDGEN_DIRECTION_SEPARATOR = if ($index -eq 0) { '-' } else { '_' }

    & $VariantScript
    if ($LASTEXITCODE -ne 0) {
        throw "Packaging failed for $($brand.filename)"
    }

    if ($brand.icon) {
        $rcEditPath = Join-Path $env:RUNNER_TEMP 'rcedit-x64-v2.0.0.exe'
        Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'SignOutput') -Filter "$($brand.filename)$($env:RDGEN_DIRECTION_SEPARATOR)*.exe" -File |
            ForEach-Object {
                & $rcEditPath $_.FullName --set-icon ([string]$brand.icon)
                if ($LASTEXITCODE -ne 0) { throw "Could not patch portable icon: $($_.Name)" }
            }
    }
}

$artifacts = @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'SignOutput') -File |
    Where-Object { $_.Extension -in '.exe', '.msi' })
Write-Host "Created $($artifacts.Count) artifacts for $($brands.Count) brand(s)."
