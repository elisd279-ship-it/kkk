#requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Launch,
    [string]$InstallRoot = $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'DUBStudio' } else { '' }),
    [switch]$NoShortcuts,
    [switch]$BundledOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$SourceRoot = Split-Path $PSScriptRoot -Parent

function Read-DependencyManifest([string]$Path) {
    $manifest = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    foreach ($key in @('python','ffmpeg')) {
        $item = $manifest.$key
        $uri = [Uri]$item.url
        $expectedHost = if ($key -eq 'python') { 'www.python.org' } else { 'www.gyan.dev' }
        if ($uri.Scheme -ne 'https' -or $uri.Host -ne $expectedHost -or $uri.UserInfo -or $uri.Query) {
            throw "Untrusted download destination for $key"
        }
        if ($item.sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw "Invalid checksum for $key" }
        if ($item.filename -notmatch '^[A-Za-z0-9._-]+$') { throw "Invalid filename for $key" }
    }
    return $manifest
}

function Test-FileHash([string]$Path, [string]$Expected) {
    return ((Test-Path -LiteralPath $Path -PathType Leaf) -and
        ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Expected))
}

function Get-VerifiedDownload($Item, [string]$Cache) {
    New-Item -ItemType Directory -Path $Cache -Force | Out-Null
    $target = Join-Path $Cache $Item.filename
    if (Test-FileHash $target $Item.sha256) { return $target }
    # A corrupt cached installer is never executed or trusted.
    $partial = "$target.partial"
    try {
        for ($attempt=1; $attempt -le 3; $attempt++) {
            try {
                Write-Host "Downloading $($Item.filename)..."
                Invoke-WebRequest -Uri $Item.url -OutFile $partial -UseBasicParsing -TimeoutSec 300
                break
            } catch {
                if ($attempt -eq 3) { throw }
                Start-Sleep -Seconds $attempt
            }
        }
        if (-not (Test-FileHash $partial $Item.sha256)) {
            throw "SHA256 mismatch for $($Item.filename). Installation stopped; do not use this download."
        }
        Move-Item -LiteralPath $partial -Destination $target -Force
        return $target
    } finally {
        if (Test-Path -LiteralPath $partial) { Remove-Item -LiteralPath $partial -Force }
    }
}

function Assert-PythonSignature([string]$Path) {
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Python Software Foundation(,|$)') {
        throw 'Python installer signature could not be verified. Installation stopped.'
    }
}

function Test-Python([string]$Executable) {
    if (-not $Executable -or -not (Test-Path -LiteralPath $Executable -PathType Leaf)) { return $false }
    try {
        # Avoid embedded quotes: Windows PowerShell 5.1 uses legacy native argument passing.
        & $Executable -I -c 'import sys,sqlite3,ssl,http.server; sys.exit(0 if sys.version_info >= (3,10) else 1)' 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Test-FFmpeg([string]$Bin) {
    if (-not $Bin) { return $false }
    foreach ($name in @('ffmpeg.exe','ffprobe.exe')) {
        $executable = Join-Path $Bin $name
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { return $false }
        try {
            $null = & $executable -version 2>$null
            if ($LASTEXITCODE -ne 0) { return $false }
        } catch { return $false }
    }
    try {
        $encoders = (& (Join-Path $Bin 'ffmpeg.exe') -hide_banner -encoders 2>$null) -join "`n"
        return ($LASTEXITCODE -eq 0 -and $encoders -match '\blibx264\b' -and $encoders -match '\baac\b')
    } catch { return $false }
}

function Find-Python([string]$ManagedPath) {
    if (Test-Python $ManagedPath) { return $ManagedPath }
    $launcher = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($launcher) {
        try {
            $candidate = & $launcher.Source -3 -I -c 'import sys; print(sys.executable)' 2>$null
            if ($LASTEXITCODE -eq 0 -and $candidate -is [string] -and (Test-Python $candidate)) { return $candidate }
        } catch { }
    }
    foreach ($name in @('python.exe','python3.exe')) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command -and $command.Source -notmatch '\\Microsoft\\WindowsApps\\' -and (Test-Python $command.Source)) {
            return $command.Source
        }
    }
    return $null
}

function Find-FFmpeg([string]$ManagedBin) {
    if (Test-FFmpeg $ManagedBin) { return $ManagedBin }
    $command = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($command) {
        $bin = Split-Path $command.Source -Parent
        if (Test-FFmpeg $bin) { return $bin }
    }
    return $null
}

function Install-Python($Item, [string]$Root, [string]$Cache, [switch]$BundledOnly) {
    $homePath = Join-Path $Root 'runtime\python'
    $executable = Join-Path $homePath 'python.exe'
    $existing = if ($BundledOnly) { if (Test-Python $executable) { $executable } } else { Find-Python $executable }
    if ($existing) { Write-Host 'Compatible Python found.'; return $existing }
    $download = Get-VerifiedDownload $Item $Cache
    Assert-PythonSignature $download
    Write-Host 'Installing Python for the current user...'
    $arguments = @('/quiet','InstallAllUsers=0','Include_launcher=0','Include_test=0',
        'Include_pip=0','Include_doc=0','Include_tools=0','Shortcuts=0','AssociateFiles=0',
        'PrependPath=0',('TargetDir="{0}"' -f $homePath))
    $process = Start-Process -FilePath $download -ArgumentList $arguments -Wait -PassThru
    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw "Python installation failed (exit $($process.ExitCode))."
    }
    if (-not (Test-Python $executable)) {
        if ($process.ExitCode -eq 3010) { throw 'Restart Windows and run Instalar.bat again to finish Python installation.' }
        throw 'Python installed but SQLite/SSL readiness failed. See install.log.'
    }
    return $executable
}

function Install-FFmpeg($Item, [string]$Root, [string]$Cache, [switch]$BundledOnly) {
    $destination = Join-Path $Root ('runtime\ffmpeg-' + $Item.version)
    $bin = Join-Path $destination 'bin'
    $existing = if ($BundledOnly) { if (Test-FFmpeg $bin) { $bin } } else { Find-FFmpeg $bin }
    if ($existing) { Write-Host 'Compatible FFmpeg and ffprobe found.'; return $existing }
    $download = Get-VerifiedDownload $Item $Cache
    $staging = Join-Path $Root ('unpack-' + [Guid]::NewGuid().ToString('N'))
    try {
        Expand-Archive -LiteralPath $download -DestinationPath $staging
        $candidates = @(Get-ChildItem -LiteralPath $staging -Filter ffmpeg.exe -Recurse -File |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.Directory.FullName 'ffprobe.exe') })
        if ($candidates.Count -ne 1) { throw 'Unexpected FFmpeg archive layout.' }
        $sourceBin = $candidates[0].Directory.FullName
        if (-not (Test-FFmpeg $sourceBin)) { throw 'Downloaded FFmpeg cannot run on this Windows system.' }
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
        if (Test-Path -LiteralPath $destination) {
            Move-Item -LiteralPath $destination -Destination ($destination + '-backup-' + [Guid]::NewGuid().ToString('N'))
        }
        # Retain licenses and build notices alongside the binaries.
        Move-Item -LiteralPath (Split-Path $sourceBin -Parent) -Destination $destination
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    }
    if (-not (Test-FFmpeg $bin)) { throw 'FFmpeg readiness check failed.' }
    return $bin
}

function Install-Application([string]$Source, [string]$Root) {
    $destination = Join-Path $Root 'app'
    if ([IO.Path]::GetFullPath($Source).TrimEnd('\','/') -eq [IO.Path]::GetFullPath($destination).TrimEnd('\','/')) {
        return $destination
    }
    $staging = Join-Path $Root ('app-staging-' + [Guid]::NewGuid().ToString('N'))
    $backup = $null
    try {
        New-Item -ItemType Directory -Path $staging -Force | Out-Null
        # Never copy users' databases, videos, credentials, or dependency caches.
        foreach ($name in @('app.py','studio.py','dubstudio.py','AGENTS.md','README.md','Iniciar.bat','Instalar.bat','web','installer')) {
            Copy-Item -LiteralPath (Join-Path $Source $name) -Destination $staging -Recurse -Force
        }
        if (Test-Path -LiteralPath $destination) {
            $backup = Join-Path $Root ('app-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N'))
            Move-Item -LiteralPath $destination -Destination $backup
        }
        try { Move-Item -LiteralPath $staging -Destination $destination } catch {
            if ($backup) { Move-Item -LiteralPath $backup -Destination $destination }
            throw
        }
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    }
    return $destination
}

function New-AppShortcuts([string]$Application) {
    $shell = New-Object -ComObject WScript.Shell
    $menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'DUB Studio'
    New-Item -ItemType Directory -Path $menu -Force | Out-Null
    foreach ($folder in @([Environment]::GetFolderPath('Desktop'),$menu)) {
        if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { continue }
        $shortcut = $shell.CreateShortcut((Join-Path $folder 'DUB Studio.lnk'))
        $shortcut.TargetPath = Join-Path $Application 'Iniciar.bat'
        $shortcut.WorkingDirectory = $Application
        $shortcut.Description = 'DUB Studio - revision y adaptacion para doblaje'
        $shortcut.Save()
    }
}

function Start-Studio([string]$Python, [string]$FFmpegBin, [string]$Application) {
    $oldPath = $env:PATH
    try {
        $env:PATH = $FFmpegBin + [IO.Path]::PathSeparator + $oldPath
        Push-Location -LiteralPath $Application
        try {
            & $Python (Join-Path $Application 'app.py') --open-browser
            if ($LASTEXITCODE -ne 0) { throw "DUB Studio exited with code $LASTEXITCODE" }
        } finally { Pop-Location }
    } finally { $env:PATH = $oldPath }
}

function Invoke-Installer {
    if ($env:OS -ne 'Windows_NT') { throw 'This installer is for Windows 10/11 x64.' }
    $architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    if ($architecture -ne 'AMD64') { throw 'This package requires Windows x64. ARM and 32-bit systems are not supported.' }
    if (-not $InstallRoot) { throw 'LOCALAPPDATA is unavailable.' }
    # Enable TLS 1.2 on Windows PowerShell 5.1 without disabling certificate checks.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    $lock = $null
    try {
        $lock = [IO.File]::Open((Join-Path $InstallRoot 'installer.lock'), 'OpenOrCreate', 'ReadWrite', 'None')
    } catch { throw 'Another DUB Studio installer is running. Close it and try again.' }
    try {
        $manifest = Read-DependencyManifest (Join-Path $PSScriptRoot 'dependencies.json')
        $cache = Join-Path $InstallRoot 'downloads'
        $python = Install-Python $manifest.python $InstallRoot $cache -BundledOnly:$BundledOnly
        $ffmpeg = Install-FFmpeg $manifest.ffmpeg $InstallRoot $cache -BundledOnly:$BundledOnly
        $application = Install-Application $SourceRoot $InstallRoot
        if (-not $NoShortcuts) {
            try { New-AppShortcuts $application } catch { Write-Warning 'Could not create shortcuts. You can still use Iniciar.bat.' }
        }
        Write-Host ''
        Write-Host 'DUB Studio is ready.' -ForegroundColor Green
        Write-Host "Application: $application"
        Write-Host 'Projects remain in your user profile: .dubstudio'
    } finally { if ($lock) { $lock.Dispose() } }
    if ($Launch) { Start-Studio $python $ffmpeg $application }
}

if ($MyInvocation.InvocationName -ne '.') {
    $transcript = $false
    try {
        if ($InstallRoot) {
            New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
            Start-Transcript -Path (Join-Path $InstallRoot 'install.log') -Append | Out-Null
            $transcript = $true
        }
        Invoke-Installer
    } catch {
        Write-Host ''
        Write-Host ('ERROR: ' + $_.Exception.Message) -ForegroundColor Red
        Write-Host 'Check your connection and available disk space, then run Instalar.bat again.'
        exit 1
    } finally { if ($transcript) { Stop-Transcript | Out-Null } }
}
