param(
    [string]$InstallDirectory = 'E:\андрей-файлы\работа\мегабайт\rustdesk\custom client\signer',
    [string]$RemoteHost = '10.101.28.33',
    [string]$RemoteUser = 'agent'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$InstallDirectory = [IO.Path]::GetFullPath($InstallDirectory.Trim().Trim('"'))

function ConvertTo-PlainText {
    param([Security.SecureString]$SecureValue)

    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

$mutex = [Threading.Mutex]::new($false, 'Local\RDGenSigningAgent')
if (-not $mutex.WaitOne(0)) {
    Write-Host 'RDGen Signer is already running.' -ForegroundColor Yellow
    Start-Sleep -Seconds 3
    exit 0
}

$tunnelJob = $null
try {
    $apiKeyFile = Join-Path $InstallDirectory 'api-key.txt'
    $legacyApiKeyFile = Join-Path $InstallDirectory 'api-key.dpapi'
    $sshKeyPath = Join-Path $InstallDirectory 'rdgen-signer-ed25519'
    $agentScript = Join-Path $InstallDirectory 'windows-signing-agent.ps1'
    $tunnelScript = Join-Path $InstallDirectory 'windows-signing-tunnel.ps1'

    foreach ($requiredFile in @($sshKeyPath, $agentScript, $tunnelScript)) {
        if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) {
            throw "Missing signer file: $requiredFile. Run the installer again."
        }
    }

    if (Test-Path -LiteralPath $apiKeyFile -PathType Leaf) {
        $apiKey = (Get-Content -LiteralPath $apiKeyFile -Raw).Trim()
    } elseif (Test-Path -LiteralPath $legacyApiKeyFile -PathType Leaf) {
        $apiKey = ConvertTo-PlainText (ConvertTo-SecureString (Get-Content -LiteralPath $legacyApiKeyFile -Raw))
    } else {
        throw 'Signing API key is missing. Run the installer again.'
    }

    Write-Host 'Starting encrypted tunnel to the RDGen server...' -ForegroundColor Cyan
    $tunnelJob = Start-Job -FilePath $tunnelScript -ArgumentList $sshKeyPath, $RemoteHost, $RemoteUser
    Start-Sleep -Seconds 2
    if ($tunnelJob.State -eq 'Failed') {
        Receive-Job $tunnelJob
        throw 'Could not start the SSH tunnel'
    }

    Write-Host 'RDGen Signer is ready. Keep this window open while building.' -ForegroundColor Green
    Write-Host 'If Rutoken asks for a PIN, enter it in the token window.' -ForegroundColor Yellow
    & $agentScript -ApiKey $apiKey
}
finally {
    if ($tunnelJob) {
        Stop-Job $tunnelJob -ErrorAction SilentlyContinue
        Remove-Job $tunnelJob -Force -ErrorAction SilentlyContinue
    }
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
