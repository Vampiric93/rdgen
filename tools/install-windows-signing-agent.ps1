param(
    [string]$InstallDirectory = 'E:\андрей-файлы\работа\мегабайт\rustdesk\custom client\signer',
    [string]$RemoteHost = '10.101.28.33',
    [string]$RemoteUser = 'agent'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -InstallDirectory `"$InstallDirectory`" -RemoteHost `"$RemoteHost`" -RemoteUser `"$RemoteUser`""
    Start-Process powershell.exe -Verb RunAs -ArgumentList $arguments
    exit 0
}

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

function ConvertTo-EncodedCommand {
    param([string]$Command)
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Command))
}

$rawBaseUrl = 'https://raw.githubusercontent.com/Vampiric93/rdgen/2889674/tools'
$signToolPath = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.19041.0\x64\signtool.exe'
$apiKeyFile = Join-Path $InstallDirectory 'api-key.txt'
$legacyApiKeyFile = Join-Path $InstallDirectory 'api-key.dpapi'
$sshKeyPath = Join-Path $InstallDirectory 'rdgen-signer-ed25519'

New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null
$currentUserSid = $identity.User.Value
& icacls.exe $InstallDirectory /inheritance:r /grant:r "*$($currentUserSid):(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Could not secure the local signer directory ACL'
}

if (-not (Test-Path -LiteralPath $signToolPath -PathType Leaf)) {
    throw "SignTool not found: $signToolPath"
}
foreach ($command in @('ssh.exe', 'ssh-keygen.exe')) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        throw "$command is not installed. Enable Windows OpenSSH Client."
    }
}

foreach ($fileName in @(
    'windows-signing-agent.ps1',
    'windows-signing-tunnel.ps1',
    'start-windows-signing-agent.ps1',
    'start-rdgen-signer.cmd'
)) {
    Invoke-WebRequest "$rawBaseUrl/$fileName" -OutFile (Join-Path $InstallDirectory $fileName) -UseBasicParsing
}

if (-not (Test-Path -LiteralPath $sshKeyPath -PathType Leaf)) {
    $sshKeygen = (Get-Command ssh-keygen.exe).Source
    $keygenCommand = '"{0}" -q -t ed25519 -N "" -C rdgen-signer -f "{1}"' -f $sshKeygen, $sshKeyPath
    & $env:COMSPEC /d /s /c $keygenCommand
    if ($LASTEXITCODE -ne 0) {
        throw "ssh-keygen failed with exit code $LASTEXITCODE"
    }
}

$apiKey = $null
$apiKeyRegenerated = $false
if (Test-Path -LiteralPath $apiKeyFile -PathType Leaf) {
    $apiKey = (Get-Content -LiteralPath $apiKeyFile -Raw).Trim()
} elseif (Test-Path -LiteralPath $legacyApiKeyFile -PathType Leaf) {
    try {
        $apiKey = ConvertTo-PlainText (ConvertTo-SecureString (Get-Content -LiteralPath $legacyApiKeyFile -Raw))
    }
    catch {
        Write-Warning 'The incomplete API key left by the previous run will be replaced.'
    }
}

if ([string]::IsNullOrWhiteSpace($apiKey)) {
    $randomBytes = New-Object byte[] 32
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($randomBytes)
    }
    finally {
        $rng.Dispose()
    }
    $apiKey = [Convert]::ToBase64String($randomBytes)
    $apiKeyRegenerated = $true
}
[IO.File]::WriteAllText($apiKeyFile, $apiKey, [Text.Encoding]::ASCII)
Remove-Item -LiteralPath $legacyApiKeyFile -Force -ErrorAction SilentlyContinue

$target = "$RemoteUser@$RemoteHost"
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & ssh.exe -F NUL -i $sshKeyPath -o LogLevel=ERROR -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new $target 'key-test' 2>$null
    $keyInstalled = $LASTEXITCODE -eq 0
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
}

if (-not $keyInstalled -or $apiKeyRegenerated) {
    Write-Host ''
    Write-Host "Enter the password for $target once. It will not be saved." -ForegroundColor Yellow
$bootstrapCommand = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$payload = [Console]::In.ReadToEnd() | ConvertFrom-Json
$key = [string]$payload.publicKey
$apiKey = [string]$payload.apiKey
if ([string]::IsNullOrWhiteSpace($key) -or -not $key.StartsWith('ssh-ed25519 ')) { throw 'Invalid SSH public key' }
if ([string]::IsNullOrWhiteSpace($apiKey)) { throw 'Empty signing API key' }
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$currentPrincipal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
$administratorsSid = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
if ($currentPrincipal.IsInRole($administratorsSid)) {
    $sshDirectory = Join-Path $env:ProgramData 'ssh'
    $authorizedKeys = Join-Path $sshDirectory 'administrators_authorized_keys'
} else {
    $sshDirectory = Join-Path $env:USERPROFILE '.ssh'
    $authorizedKeys = Join-Path $sshDirectory 'authorized_keys'
}
New-Item -ItemType Directory -Path $sshDirectory -Force | Out-Null
$keyBlob = $key.Split(' ')[1]
$existingKeys = if (Test-Path $authorizedKeys) { @(Get-Content $authorizedKeys) } else { @() }
$existingKeys = @($existingKeys | Where-Object { $_ -notmatch [regex]::Escape($keyBlob) })
$restrictedKey = 'command="cmd /c exit 0",restrict,port-forwarding,permitlisten="127.0.0.1:19000" ' + $key
[IO.File]::WriteAllLines($authorizedKeys, @($existingKeys + $restrictedKey), [Text.Encoding]::ASCII)
if ($currentPrincipal.IsInRole($administratorsSid)) {
    & icacls.exe $authorizedKeys /inheritance:r /grant:r '*S-1-5-18:F' '*S-1-5-32-544:F' | Out-Null
} else {
    $userSid = $currentIdentity.User.Value
    & icacls.exe $authorizedKeys /inheritance:r /grant:r "*$($userSid):F" '*S-1-5-18:F' | Out-Null
}
if ($LASTEXITCODE -ne 0) { throw 'Could not secure the SSH directory ACL' }

$signingDirectory = 'C:\rdgen-signing'
$apiKeyPath = Join-Path $signingDirectory 'api-key.txt'
New-Item -ItemType Directory -Path $signingDirectory -Force | Out-Null
[IO.File]::WriteAllText($apiKeyPath, $apiKey, [Text.UTF8Encoding]::new($false))
$userSid = $currentIdentity.User.Value
& icacls.exe $signingDirectory /inheritance:r /grant:r "*$($userSid):(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-20:(OI)(CI)R' | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Could not secure the signing configuration ACL' }
'Signing bridge bootstrapped'
'@
    $encodedCommand = ConvertTo-EncodedCommand $bootstrapCommand
    $bootstrapPayload = @{
        publicKey = (Get-Content -LiteralPath "$sshKeyPath.pub" -Raw).Trim()
        apiKey = $apiKey
    } | ConvertTo-Json -Compress
    $ErrorActionPreference = 'Continue'
    try {
        $bootstrapPayload |
            & ssh.exe -o LogLevel=ERROR -o StrictHostKeyChecking=accept-new $target powershell.exe -NoProfile -EncodedCommand $encodedCommand
        $bootstrapExitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($bootstrapExitCode -ne 0) {
        throw 'Could not bootstrap the signing bridge on the server'
    }
}

$ErrorActionPreference = 'Continue'
try {
    & ssh.exe -F NUL -i $sshKeyPath -o LogLevel=ERROR -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new $target 'key-test' 2>$null
    $keyTestExitCode = $LASTEXITCODE
}
finally {
    $ErrorActionPreference = $previousErrorActionPreference
}
if ($keyTestExitCode -ne 0) {
    throw 'SSH key authentication test failed'
}

& netsh.exe http delete urlacl url=http://127.0.0.1:9000/ 2>$null | Out-Null
& netsh.exe http add urlacl url=http://127.0.0.1:9000/ "user=$($identity.Name)" | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Could not reserve the local signing-agent URL'
}

$desktop = [Environment]::GetFolderPath('Desktop')
$shortcutPath = Join-Path $desktop 'RDGen Signer.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = Join-Path $InstallDirectory 'start-rdgen-signer.cmd'
$shortcut.WorkingDirectory = $InstallDirectory
$shortcut.IconLocation = "$env:SystemRoot\System32\shell32.dll,44"
$shortcut.Save()

Write-Host ''
Write-Host "Installed in: $InstallDirectory" -ForegroundColor Green
Write-Host 'From now on, double-click the RDGen Signer shortcut before starting a build.' -ForegroundColor Green
Start-Process -FilePath (Join-Path $InstallDirectory 'start-rdgen-signer.cmd') -WorkingDirectory $InstallDirectory
