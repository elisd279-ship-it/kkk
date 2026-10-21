# Real Windows file-sharing regressions; no antivirus or permissions are changed.
param([string]$Cache)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'installer/windows.ps1')
if ($env:OS -ne 'Windows_NT') { throw 'Native locking checks require Windows.' }
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('dub-locks-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary | Out-Null
$held = $null
try {
    # A failed cleanup must retain the original error, not just report ffmpeg.exe.
    $staging = Join-Path $temporary 'unpack-fixture'
    New-Item -ItemType Directory -Path $staging | Out-Null
    $file = Join-Path $staging 'ffmpeg.exe'
    [IO.File]::WriteAllText($file,'locked fixture')
    $held = [IO.File]::Open($file,'Open','ReadWrite','None')
    $original = $null
    try {
        try { throw [InvalidOperationException]::new('original archive failure') }
        finally { Remove-InstallerStaging $staging -Attempts 1 -DelayMilliseconds 1 -WarningAction SilentlyContinue }
    } catch { $original = $_.Exception.Message }
    if ($original -ne 'original archive failure' -or -not (Test-Path $staging)) { throw 'Cleanup masked original error or discarded a locked file.' }
    $held.Dispose(); $held=$null
    Remove-InstallerStaging $staging
    if (Test-Path $staging) { throw 'Released temporary cannot be cleaned.' }

    # A genuine sharing violation is retried and succeeds when another thread releases it.
    Add-Type -TypeDefinition @'
using System;
using System.Threading;
using System.Threading.Tasks;
public static class DubLockRelease {
    public static void Later(IDisposable resource, int milliseconds) {
        Task.Run(() => { Thread.Sleep(milliseconds); resource.Dispose(); });
    }
}
'@
    $file = Join-Path $temporary 'transient.lock'
    [IO.File]::WriteAllText($file,'temporary lock')
    $held = [IO.File]::Open($file,'Open','ReadWrite','None')
    [DubLockRelease]::Later($held,500)
    $script:tries = 0
    Invoke-FileOperation -Description 'abrir archivo de prueba' -Path $file -Attempts 8 -DelayMilliseconds 100 -Action {
        $script:tries++
        $handle = [IO.File]::Open($file,'Open','Read','Read')
        $handle.Dispose()
    }
    $held.Dispose(); $held=$null
    if ($script:tries -lt 2) { throw 'Native sharing violation was not exercised.' }

    # Reproduce an incomplete installation whose old ffmpeg.exe cannot be touched.
    $manifest = Read-DependencyManifest (Join-Path $PSScriptRoot '../installer/dependencies.json')
    $root = Join-Path $temporary 'installation with locked ffmpeg'
    $oldBin = Join-Path $root ('runtime/ffmpeg-' + $manifest.ffmpeg.version + '/bin')
    New-Item -ItemType Directory -Path $oldBin -Force | Out-Null
    $oldFile = Join-Path $oldBin 'ffmpeg.exe'
    [IO.File]::WriteAllText($oldFile,'incomplete old runtime - keep intact')
    $held = [IO.File]::Open($oldFile,'Open','ReadWrite','None')
    # Pin the newly checked executable too, reproducing the user's post-validation
    # directory-move denial. Installation must succeed without moving that image.
    $realTestFFmpeg = ${function:Test-FFmpeg}
    $script:pinnedImage = $null
    function Test-FFmpeg([string]$Bin) {
        $valid = & $realTestFFmpeg $Bin
        if ($valid -and -not $script:pinnedImage -and $Bin.StartsWith($root)) {
            $script:pinnedImage = [IO.File]::Open((Join-Path $Bin 'ffmpeg.exe'),'Open','Read','Read')
        }
        return $valid
    }
    try {
        $newBin = Install-FFmpeg $manifest.ffmpeg $root $Cache -BundledOnly
        if (-not $script:pinnedImage) { throw 'The new executable was not pinned after validation.' }
    } finally {
        if ($script:pinnedImage) { $script:pinnedImage.Dispose() }
        Set-Item Function:Test-FFmpeg $realTestFFmpeg
    }
    if ($newBin -eq $oldBin -or -not (Test-FFmpeg $newBin)) { throw 'A locked old runtime prevented fresh FFmpeg installation.' }
    if ((Find-ManagedFFmpeg $manifest.ffmpeg $root) -ne $newBin) { throw 'Fresh FFmpeg cannot be reused.' }
    $held.Dispose(); $held=$null
    if ([IO.File]::ReadAllText($oldFile) -ne 'incomplete old runtime - keep intact') { throw 'Old executable was modified.' }
    Write-Host 'PASS: native file lock recovery, cleanup preserves primary errors, and FFmpeg installs without moving its locked image after validation.'
} finally {
    if ($held) { $held.Dispose() }
    if (Test-Path $temporary) { Remove-Item -LiteralPath $temporary -Recurse -Force }
}
