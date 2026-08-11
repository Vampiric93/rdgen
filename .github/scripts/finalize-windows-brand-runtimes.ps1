$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$signingMapPath = Join-Path $env:RUNNER_TEMP 'rdgen-windows-signing-map.json'
$records = @(Get-Content -LiteralPath $signingMapPath -Raw | ConvertFrom-Json)
$copyCount = 0

foreach ($record in $records) {
    $source = [string]$record.source
    foreach ($destinationValue in @($record.destinations)) {
        $destination = [string]$destinationValue
        if ($destination -eq $source) {
            continue
        }
        Copy-Item -LiteralPath $source -Destination $destination -Force
        $copyCount++
    }
}

Write-Host "Restored $copyCount duplicate binaries from their signed representatives."
