param(
    [Parameter(Mandatory = $true)]
    [string]$SshKeyPath,
    [string]$RemoteHost = '10.101.28.33',
    [string]$RemoteUser = 'agent'
)

$ErrorActionPreference = 'Continue'

while ($true) {
    & ssh.exe `
        -F NUL `
        -o BatchMode=yes `
        -o IdentitiesOnly=yes `
        -o IdentityAgent=none `
        -o ExitOnForwardFailure=yes `
        -o ConnectTimeout=10 `
        -o ServerAliveInterval=15 `
        -o ServerAliveCountMax=3 `
        -o StrictHostKeyChecking=accept-new `
        -i $SshKeyPath `
        -N `
        -R '127.0.0.1:19000:127.0.0.1:9000' `
        "$RemoteUser@$RemoteHost"

    Start-Sleep -Seconds 5
}
