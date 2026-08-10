param(
    [string]$ListenPrefix = 'http://127.0.0.1:9000/',
    [string]$SignToolPath = 'C:\Program Files (x86)\Windows Kits\10\bin\10.0.19041.0\x64\signtool.exe',
    [string]$CertificateThumbprint = 'bbe552fafceefa932821195f3de3bb9616ba19d3',
    [string]$TimestampUrl = 'http://timestamp.globalsign.com/tsa/r6advanced1',
    [string]$ApiKey = $env:RDGEN_SIGN_API_KEY,
    [long]$MaximumArchiveBytes = 1073741824
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Read-Secret {
    param([string]$Prompt)

    $secure = Read-Host $Prompt -AsSecureString
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function Test-ApiKey {
    param([string]$Provided, [string]$Expected)

    if ($null -eq $Provided -or $Provided.Length -ne $Expected.Length) {
        return $false
    }

    $difference = 0
    for ($index = 0; $index -lt $Expected.Length; $index++) {
        $difference = $difference -bor ([int]$Provided[$index] -bxor [int]$Expected[$index])
    }
    return $difference -eq 0
}

function Send-TextResponse {
    param(
        [System.Net.HttpListenerContext]$Context,
        [int]$StatusCode,
        [string]$Text
    )

    $payload = [Text.Encoding]::UTF8.GetBytes($Text)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = 'text/plain; charset=utf-8'
    $Context.Response.ContentLength64 = $payload.Length
    $Context.Response.OutputStream.Write($payload, 0, $payload.Length)
    $Context.Response.Close()
}

function Assert-SafeZipEntries {
    param([string]$ArchivePath, [string]$DestinationDirectory)

    $root = [IO.Path]::GetFullPath($DestinationDirectory).TrimEnd('\') + '\'
    $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
    try {
        foreach ($entry in $archive.Entries) {
            $destination = [IO.Path]::GetFullPath((Join-Path $DestinationDirectory $entry.FullName))
            if (-not $destination.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Unsafe ZIP entry: $($entry.FullName)"
            }
        }
    }
    finally {
        $archive.Dispose()
    }
}

if (-not (Test-Path -LiteralPath $SignToolPath -PathType Leaf)) {
    throw "SignTool not found: $SignToolPath"
}
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    $ApiKey = Read-Secret 'Signing API key'
}
if ([string]::IsNullOrWhiteSpace($ApiKey)) {
    throw 'Signing API key cannot be empty'
}

$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add($ListenPrefix)
$listener.Start()
Write-Host "RDGen signing agent is listening on $ListenPrefix"
Write-Host 'Keep this window open. Press Ctrl+C to stop.'

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()

        if ($context.Request.HttpMethod -eq 'GET' -and $context.Request.Url.AbsolutePath -eq '/health') {
            Send-TextResponse $context 200 'ok'
            continue
        }

        if ($context.Request.HttpMethod -ne 'POST' -or $context.Request.Url.AbsolutePath -ne '/sign/') {
            Send-TextResponse $context 404 'not found'
            continue
        }

        if (-not (Test-ApiKey $context.Request.Headers['X-API-KEY'] $ApiKey)) {
            Send-TextResponse $context 401 'unauthorized'
            continue
        }

        if ($context.Request.ContentLength64 -le 0 -or $context.Request.ContentLength64 -gt $MaximumArchiveBytes) {
            Send-TextResponse $context 413 'invalid archive size'
            continue
        }

        $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) "rdgen-sign-$([guid]::NewGuid())"
        $requestArchive = Join-Path $temporaryDirectory 'request.zip'
        $extractedDirectory = Join-Path $temporaryDirectory 'files'
        $responseArchive = Join-Path $temporaryDirectory 'signed.zip'

        try {
            New-Item -ItemType Directory -Path $extractedDirectory -Force | Out-Null
            $requestStream = [IO.File]::Create($requestArchive)
            try {
                $context.Request.InputStream.CopyTo($requestStream)
            }
            finally {
                $requestStream.Dispose()
            }

            Assert-SafeZipEntries $requestArchive $extractedDirectory
            [IO.Compression.ZipFile]::ExtractToDirectory($requestArchive, $extractedDirectory)

            $filesToSign = @(Get-ChildItem $extractedDirectory -Recurse -File | Where-Object {
                $_.Extension.ToLowerInvariant() -in '.exe', '.dll', '.msi'
            } | Sort-Object FullName)
            if ($filesToSign.Count -eq 0) {
                throw 'The archive contains no EXE, DLL, or MSI files'
            }

            foreach ($file in $filesToSign) {
                Write-Host "Signing $($file.Name)..."
                & $SignToolPath sign /a /tr $TimestampUrl /sha1 $CertificateThumbprint /td SHA256 /fd SHA256 $file.FullName
                if ($LASTEXITCODE -ne 0) {
                    throw "SignTool failed for $($file.Name) with exit code $LASTEXITCODE"
                }

                & $SignToolPath verify /pa /v $file.FullName
                if ($LASTEXITCODE -ne 0) {
                    throw "Signature verification failed for $($file.Name)"
                }
            }

            [IO.Compression.ZipFile]::CreateFromDirectory(
                $extractedDirectory,
                $responseArchive,
                [IO.Compression.CompressionLevel]::Fastest,
                $false
            )

            $responseFile = [IO.File]::OpenRead($responseArchive)
            try {
                $context.Response.StatusCode = 200
                $context.Response.ContentType = 'application/zip'
                $context.Response.ContentLength64 = $responseFile.Length
                $responseFile.CopyTo($context.Response.OutputStream)
                $context.Response.OutputStream.Close()
            }
            finally {
                $responseFile.Dispose()
                $context.Response.Close()
            }
            Write-Host "Returned $($filesToSign.Count) signed file(s)."
        }
        catch {
            Write-Error $_
            try {
                if ($context.Response.OutputStream.CanWrite) {
                    Send-TextResponse $context 500 "signing failed: $($_.Exception.Message)"
                }
            }
            catch {
                Write-Warning "Could not return the signing error to the caller: $($_.Exception.Message)"
            }
        }
        finally {
            if (Test-Path -LiteralPath $temporaryDirectory) {
                Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force
            }
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
}
