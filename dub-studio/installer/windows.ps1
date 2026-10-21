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
$script:InstallerPhase = 'Preparar instalacion'

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
    $script:FFmpegDiagnostic = 'Ruta no disponible'
    if (-not $Bin) { return $false }
    foreach ($name in @('ffmpeg.exe','ffprobe.exe')) {
        $executable = Join-Path $Bin $name
        if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { $script:FFmpegDiagnostic = 'No existe ' + $executable; return $false }
        try {
            $null = & $executable -version 2>$null
            if ($LASTEXITCODE -ne 0) { $script:FFmpegDiagnostic = '{0}: codigo {1}' -f $executable,$LASTEXITCODE; return $false }
        } catch { $script:FFmpegDiagnostic = '{0}: {1}' -f $executable,$_.Exception.Message; return $false }
    }
    try {
        $encoders = (& (Join-Path $Bin 'ffmpeg.exe') -hide_banner -encoders 2>$null) -join "`n"
        $ready = ($LASTEXITCODE -eq 0 -and $encoders -match '\blibx264\b' -and $encoders -match '\baac\b')
        if (-not $ready) { $script:FFmpegDiagnostic = 'FFmpeg no ofrece los codificadores libx264 y aac' }
        return $ready
    } catch { $script:FFmpegDiagnostic = $_.Exception.Message; return $false }
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

function Test-TransientFileError($Record) {
    $exception = $Record.Exception
    while ($exception) {
        if ($exception -is [UnauthorizedAccessException]) { return $true }
        if ($exception -is [IO.IOException] -and (($exception.HResult -band 65535) -in @(5,32,33))) { return $true }
        if ($exception -is [ComponentModel.Win32Exception] -and $exception.NativeErrorCode -in @(5,32,33)) { return $true }
        $exception = $exception.InnerException
    }
    return $false
}

function Invoke-FileOperation {
    param([scriptblock]$Action, [string]$Description, [string]$Path,
        [int]$Attempts=5, [int]$DelayMilliseconds=300)
    for ($attempt=1; $attempt -le $Attempts; $attempt++) {
        try { return (& $Action) } catch {
            if (-not (Test-TransientFileError $_)) { throw }
            if ($attempt -eq $Attempts) {
                throw [IO.IOException]::new((
                    '{0}: Windows mantiene bloqueada o deniega la ruta "{1}". {2}' -f $Description,$Path,$_.Exception.Message),$_.Exception)
            }
            Write-Host ("Windows mantiene un archivo ocupado; reintentando {0} ({1}/{2})..." -f $Description,$attempt,$Attempts)
            Start-Sleep -Milliseconds ($DelayMilliseconds * $attempt)
        }
    }
}

function Remove-InstallerStaging {
    [CmdletBinding()]
    param([string]$Path, [int]$Attempts=3, [int]$DelayMilliseconds=300)
    # Cleanup must never replace the original error or invalidate a successful install.
    try {
        if (-not (Test-Path -LiteralPath $Path)) { return }
        Invoke-FileOperation -Description 'limpiar temporales' -Path $Path -Attempts $Attempts -DelayMilliseconds $DelayMilliseconds -Action {
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
        }
    } catch {
        Write-Warning ('No se pudo limpiar el temporal "{0}". Se conserva para no interrumpir la instalacion. {1}' -f $Path,$_.Exception.Message)
    }
}

function Find-ManagedFFmpeg($Item, [string]$Root) {
    $runtime = Join-Path $Root 'runtime'
    # Support existing installations, without changing files that another process may be using.
    $canonical = Join-Path $runtime ('ffmpeg-' + $Item.version + '/bin')
    if (Test-FFmpeg $canonical) { return $canonical }
    if (Test-Path -LiteralPath $runtime) {
        $pattern = '^ffmpeg-' + [Regex]::Escape($Item.version) + '-install-[a-f0-9]{32}$'
        $directories = @(Get-ChildItem -LiteralPath $runtime -Directory | Where-Object { $_.Name -match $pattern } | Sort-Object Name)
        foreach ($directory in $directories) {
            $bin = Join-Path $directory.FullName 'bin'
            if (Test-FFmpeg $bin) { return $bin }
        }
    }
    return $null
}

function Install-FFmpeg($Item, [string]$Root, [string]$Cache, [switch]$BundledOnly) {
    $script:InstallerPhase = 'Comprobar FFmpeg existente'
    $existing = Find-ManagedFFmpeg $Item $Root
    if (-not $existing -and -not $BundledOnly) { $existing = Find-FFmpeg $null }
    if ($existing) { Write-Host 'Compatible FFmpeg and ffprobe found.'; return $existing }
    $script:InstallerPhase = 'Descargar FFmpeg'
    $download = Get-VerifiedDownload $Item $Cache
    $staging = Join-Path $Root ('unpack-' + [Guid]::NewGuid().ToString('N'))
    # Use a fresh destination; never rename or overwrite a previous ffmpeg.exe.
    $destination = Join-Path $Root ('runtime/ffmpeg-' + $Item.version + '-install-' + [Guid]::NewGuid().ToString('N'))
    $bin = Join-Path $destination 'bin'
    try {
        $script:InstallerPhase = 'Extraer FFmpeg'
        Invoke-FileOperation -Description 'extraer FFmpeg' -Path $staging -Action {
            Expand-Archive -LiteralPath $download -DestinationPath $staging -Force
        }
        $candidates = @(Get-ChildItem -LiteralPath $staging -Filter ffmpeg.exe -Recurse -File |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.Directory.FullName 'ffprobe.exe') })
        if ($candidates.Count -ne 1) { throw ('Estructura inesperada del ZIP de FFmpeg en "{0}".' -f $staging) }
        $sourceBin = $candidates[0].Directory.FullName
        $script:InstallerPhase = 'Comprobar FFmpeg extraido'
        $ready = $false
        for ($attempt=1; $attempt -le 4; $attempt++) {
            if (Test-FFmpeg $sourceBin) { $ready=$true; break }
            if ($attempt -lt 4) { Start-Sleep -Milliseconds (300 * $attempt) }
        }
        if (-not $ready) { throw ('Windows no permite ejecutar FFmpeg o faltan codificadores en "{0}". Detalle: {1}' -f $sourceBin,$script:FFmpegDiagnostic) }
        New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force | Out-Null
        $script:InstallerPhase = 'Guardar FFmpeg'
        $sourceDirectory = Split-Path $sourceBin -Parent
        # Atomic rename in the same volume, with bounded retries for transient file locks.
        # Retain licenses and build notices alongside the binaries.
        Invoke-FileOperation -Description 'guardar FFmpeg' -Path $destination -Action {
            [IO.Directory]::Move($sourceDirectory,$destination)
        }
    } finally { Remove-InstallerStaging $staging }
    $script:InstallerPhase = 'Comprobar FFmpeg instalado'
    if (-not (Test-FFmpeg $bin)) { throw ('No se puede ejecutar FFmpeg instalado en "{0}". Detalle: {1}' -f $bin,$script:FFmpegDiagnostic) }
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
        Remove-InstallerStaging $staging
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
        $script:InstallerPhase = 'Instalar Python'
        $python = Install-Python $manifest.python $InstallRoot $cache -BundledOnly:$BundledOnly
        $ffmpeg = Install-FFmpeg $manifest.ffmpeg $InstallRoot $cache -BundledOnly:$BundledOnly
        $script:InstallerPhase = 'Instalar aplicacion'
        $application = Install-Application $SourceRoot $InstallRoot
        if (-not $NoShortcuts) {
            try { New-AppShortcuts $application } catch { Write-Warning 'Could not create shortcuts. You can still use Iniciar.bat.' }
        }
        Write-Host ''
        Write-Host 'DUB Studio is ready.' -ForegroundColor Green
        Write-Host "Application: $application"
        Write-Host 'Projects remain in your user profile: .dubstudio'
    } finally { if ($lock) { $lock.Dispose() } }
    $script:InstallerPhase = 'Iniciar DUB Studio'
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
        Write-Host ('Fase: ' + $script:InstallerPhase)
        Write-Host ('Detalle: ' + $_.Exception.ToString())
        Write-Host ('Ubicacion: ' + $_.InvocationInfo.PositionMessage)
        Write-Host 'Cierra otras ventanas de DUB Studio y vuelve a ejecutar Instalar.bat.'
        Write-Host 'Si el error persiste, comparte las ultimas lineas del registro para identificar el bloqueo.'
        Write-Host ('Registro: ' + (Join-Path $InstallRoot 'install.log'))
        exit 1
    } finally { if ($transcript) { Stop-Transcript | Out-Null } }
}
