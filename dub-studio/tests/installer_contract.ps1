# No Pester dependency. Run using Windows PowerShell 5.1 or PowerShell 7.
param([string]$PythonPath)
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'installer/windows.ps1')
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('dub-installer-test-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary | Out-Null
$script:checks = 0
function Assert-True($Condition, [string]$Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
    $script:checks++
}
function Assert-Throws([scriptblock]$Operation,[string]$Message) {
    $failed = $false
    try { & $Operation | Out-Null } catch { $failed = $true }
    Assert-True $failed $Message
}
try {
    $manifest = Read-DependencyManifest (Join-Path $SourceRoot 'installer/dependencies.json')
    Assert-True ($manifest.python.version -eq '3.14.8') 'Pinned Python manifest loads'
    $bad = Join-Path $temporary 'bad.json'
    $changed = Get-Content (Join-Path $SourceRoot 'installer/dependencies.json') -Raw | ConvertFrom-Json
    $changed.python.url = 'https://example.org/installer.exe'
    $changed | ConvertTo-Json -Depth 5 | Set-Content $bad
    Assert-Throws { Read-DependencyManifest $bad } 'Foreign download host rejected'
    $changed.python.url = $manifest.python.url
    $changed.ffmpeg.sha256 = 'incorrect'
    $changed | ConvertTo-Json -Depth 5 | Set-Content $bad
    Assert-Throws { Read-DependencyManifest $bad } 'Invalid checksum rejected'

    $cache = Join-Path $temporary 'downloads'
    New-Item -ItemType Directory -Path $cache | Out-Null
    $fixture = Join-Path $cache 'fixture.zip'
    [IO.File]::WriteAllText($fixture,'verified fixture')
    $hash = (Get-FileHash $fixture -Algorithm SHA256).Hash
    $item = [PSCustomObject]@{filename='fixture.zip';sha256=$hash;url='https://www.gyan.dev/not-requested'}
    $script:downloadCount = 0
    function Invoke-WebRequest { param($Uri,$OutFile,[switch]$UseBasicParsing,$TimeoutSec)
        $script:downloadCount++
        [IO.File]::WriteAllText($OutFile,'corrupted fixture')
    }
    Assert-True ((Get-VerifiedDownload $item $cache) -eq $fixture) 'Verified cached download reused'
    Assert-True ($script:downloadCount -eq 0) 'Valid cache needs no Internet'
    [IO.File]::WriteAllText($fixture,'bad cache')
    Assert-Throws { Get-VerifiedDownload $item $cache } 'Corrupt download rejected'
    Assert-True ($script:downloadCount -eq 1) 'A mismatch does not loop downloads'
    Assert-True (-not (Test-Path "$fixture.partial")) 'Partial download cleaned'
    Remove-Item Function:Invoke-WebRequest

    function Get-AuthenticodeSignature { param($LiteralPath)
        return [PSCustomObject]@{Status=$script:sigStatus;SignerCertificate=[PSCustomObject]@{Subject=$script:subject}}
    }
    $script:sigStatus='Valid';$script:subject='CN=Python Software Foundation, O=Python Software Foundation, C=US'
    Assert-PythonSignature $fixture
    Assert-True $true 'Valid PSF signature accepted'
    $script:sigStatus='NotTrusted'
    Assert-Throws { Assert-PythonSignature $fixture } 'Untrusted signature rejected'
    $script:sigStatus='Valid';$script:subject='CN=Other, O=Other, C=US'
    Assert-Throws { Assert-PythonSignature $fixture } 'Different publisher rejected'
    Remove-Item Function:Get-AuthenticodeSignature

    if ($PythonPath) { Assert-True (Test-Python $PythonPath) 'Existing Python includes SQLite and TLS' }
    Assert-True (-not (Test-Python (Join-Path $temporary 'missing.exe'))) 'Missing Python rejected'

    $root = Join-Path $temporary 'install with spaces'
    New-Item -ItemType Directory -Path (Join-Path $root 'runtime') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $root 'runtime/keep.txt'),'keep')
    $app = Install-Application $SourceRoot $root
    Assert-True (Test-Path (Join-Path $app 'app.py')) 'Application installed with spaces in path'
    Assert-True (Test-Path (Join-Path $app 'installer/dependencies.json')) 'Installer included for later launches'
    Assert-True (-not (Test-Path (Join-Path $app '.dubstudio'))) 'User databases never copied'
    Assert-True (Test-Path (Join-Path $root 'runtime/keep.txt')) 'Runtime files preserved'
    $database = Join-Path $app '.dubstudio'
    New-Item -ItemType Directory -Path $database | Out-Null
    [IO.File]::WriteAllText((Join-Path $database 'user.sqlite3'),'preserve user project')
    $null = Install-Application $SourceRoot $root
    $backups = @(Get-ChildItem $root -Directory -Filter 'app-backup-*')
    Assert-True ($backups.Count -eq 1) 'Previous application retained on update'
    Assert-True (([IO.File]::ReadAllText((Join-Path $backups[0].FullName '.dubstudio/user.sqlite3'))) -eq 'preserve user project') 'Existing projects remain recoverable'
    $null = Install-Application $app $root
    Assert-True (@(Get-ChildItem $root -Directory -Filter 'app-backup-*').Count -eq 1) 'Launching installed application is idempotent'
    Assert-True (@(Get-ChildItem $root -Directory -Filter 'app-staging-*').Count -eq 0) 'Staging files cleaned'

    # Bounded retry policy: sharing/access errors only, with useful final context.
    $script:attempts = 0
    $result = Invoke-FileOperation -Description 'fixture lock' -Path $temporary -Attempts 3 -DelayMilliseconds 1 -Action {
        $script:attempts++
        if ($script:attempts -lt 3) { throw [ComponentModel.Win32Exception]::new(32,'fixture sharing violation') }
        return 'released'
    }
    Assert-True ($result -eq 'released' -and $script:attempts -eq 3) 'Transient file lock is retried successfully'
    $script:attempts = 0
    Assert-Throws {
        Invoke-FileOperation -Description 'fixture permanent lock' -Path $temporary -Attempts 2 -DelayMilliseconds 1 -Action {
            $script:attempts++
            throw [UnauthorizedAccessException]::new('fixture denied')
        }
    } 'Persistent access denial remains an error'
    Assert-True ($script:attempts -eq 2) 'Retries stop at the configured limit'
    $script:attempts = 0
    Assert-Throws {
        Invoke-FileOperation -Description 'fixture other failure' -Path $temporary -Attempts 3 -DelayMilliseconds 1 -Action {
            $script:attempts++
            throw [InvalidOperationException]::new('fixture unrelated failure')
        }
    } 'Non-file errors propagate'
    Assert-True ($script:attempts -eq 1) 'Unrelated failures are never retried'

    # Simulate cleanup denial on every platform; preserve the primary exception.
    $lockedTemporary = Join-Path $temporary 'locked-staging'
    New-Item -ItemType Directory -Path $lockedTemporary | Out-Null
    function Remove-Item {
        param($LiteralPath,[switch]$Recurse,[switch]$Force,$ErrorAction)
        if ($LiteralPath -eq $lockedTemporary) { throw [UnauthorizedAccessException]::new('fixture cleanup denied') }
        Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
    }
    $primary = $null
    try {
        try { throw [InvalidOperationException]::new('original extraction failure') }
        finally { Remove-InstallerStaging $lockedTemporary -Attempts 1 -DelayMilliseconds 1 -WarningAction SilentlyContinue }
    } catch { $primary = $_.Exception.Message }
    Microsoft.PowerShell.Management\Remove-Item Function:Remove-Item
    Assert-True ($primary -eq 'original extraction failure') 'Cleanup cannot mask the original failure'
    Assert-True (Test-Path $lockedTemporary) 'Locked temporaries are left intact'
    Remove-InstallerStaging $lockedTemporary
    Assert-True (-not (Test-Path $lockedTemporary)) 'Cleanup can succeed once the lock clears'

    # Exercise the actual Expand-Archive and installation paths with a tiny fixture.
    $ffFixture = Join-Path $temporary 'ff-fixture/build/bin'
    New-Item -ItemType Directory -Path $ffFixture -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $ffFixture 'ffmpeg.exe'),'ffmpeg fixture')
    [IO.File]::WriteAllText((Join-Path $ffFixture 'ffprobe.exe'),'ffprobe fixture')
    [IO.File]::WriteAllText((Join-Path (Split-Path $ffFixture -Parent) 'LICENSE'),'fixture license')
    $zip = Join-Path $cache 'tiny-ffmpeg.zip'
    Compress-Archive -Path (Join-Path $temporary 'ff-fixture/build') -DestinationPath $zip
    $ffItem = [PSCustomObject]@{version='fixture';filename='tiny-ffmpeg.zip';url='https://www.gyan.dev/not-requested';sha256=(Get-FileHash $zip -Algorithm SHA256).Hash}
    function Test-FFmpeg([string]$Bin) {
        return ($Bin -and (Test-Path (Join-Path $Bin 'ffmpeg.exe')) -and (Test-Path (Join-Path $Bin 'ffprobe.exe')))
    }
    $canonical = Join-Path $root ('runtime/ffmpeg-' + $ffItem.version + '/bin')
    New-Item -ItemType Directory -Path $canonical -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $canonical 'ffmpeg.exe'),'old incomplete installation')
    $bin = Install-FFmpeg $ffItem $root $cache -BundledOnly
    Assert-True ($bin -ne $canonical) 'Fresh FFmpeg destination avoids the previous executable'
    Assert-True (([IO.File]::ReadAllText((Join-Path $canonical 'ffmpeg.exe'))) -eq 'old incomplete installation') 'Old FFmpeg installation is never overwritten'
    Assert-True (Test-FFmpeg $bin) 'Both FFmpeg executables installed'
    Assert-True (Test-Path (Join-Path (Split-Path $bin -Parent) 'LICENSE')) 'FFmpeg license retained'
    Assert-True ((Find-ManagedFFmpeg $ffItem $root) -eq $bin) 'Fresh installation is discovered on later launches'
    $readyMarker = Join-Path (Split-Path (Split-Path $bin -Parent) -Parent) 'ready.json'
    $readyContent = Get-Content -LiteralPath $readyMarker -Raw
    Remove-Item -LiteralPath $readyMarker
    Assert-True (-not (Find-ManagedFFmpeg $ffItem $root)) 'Unfinished nested installation is never reused'
    $badMarker = $readyContent | ConvertFrom-Json
    $badMarker.sha256 = 'mismatched release'
    $badMarker | ConvertTo-Json | Set-Content -LiteralPath $readyMarker
    Assert-True (-not (Find-ManagedFFmpeg $ffItem $root)) 'Marker must match the verified release'
    $badMarker.sha256 = $ffItem.sha256
    $unrelated = Join-Path $root 'runtime/bin'
    New-Item -ItemType Directory -Path $unrelated -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $unrelated 'ffmpeg.exe'),'unrelated executable')
    [IO.File]::WriteAllText((Join-Path $unrelated 'ffprobe.exe'),'unrelated executable')
    $badMarker.relativeBin = '../bin'
    $badMarker | ConvertTo-Json | Set-Content -LiteralPath $readyMarker
    Assert-True (-not (Find-ManagedFFmpeg $ffItem $root)) 'Marker cannot escape the runtime directory'
    [IO.File]::WriteAllText($readyMarker,$readyContent)
    Assert-True ((Install-FFmpeg $ffItem $root $cache -BundledOnly) -eq $bin) 'FFmpeg installation is repeatable'
    Assert-True (@(Get-ChildItem $root -Directory -Filter 'unpack-*').Count -eq 0) 'Archive staging cleaned'
    Write-Host "PASS: $script:checks installer contract checks (native Windows installation tested separately)."
} finally {
    if (Test-Path $temporary) { Remove-Item $temporary -Recurse -Force }
}
