# Run on a disposable Windows x64 test machine. Installs private dependencies.
$ErrorActionPreference = 'Stop'
$source = Split-Path $PSScriptRoot -Parent
$root = Join-Path ([IO.Path]::GetTempPath()) ('DUB integration with spaces ' + [Guid]::NewGuid().ToString('N'))
$installer = Join-Path $source 'installer/windows.ps1'
$application = Join-Path $root 'app'
$process = $null
$previousPath = $env:PATH
try {
    & $installer -InstallRoot $root -NoShortcuts -BundledOnly
    if ($LASTEXITCODE -ne 0) { throw 'Installation failed' }
    $second = (& $installer -InstallRoot $root -NoShortcuts -BundledOnly | Out-String)
    if ($second -match 'Downloading') { throw 'Repeat installation downloaded dependencies again' }
    . $installer
    $manifest = Read-DependencyManifest (Join-Path $source 'installer/dependencies.json')
    $python = Join-Path $root 'runtime/python/python.exe'
    $bin = Find-ManagedFFmpeg $manifest.ffmpeg $root
    if (-not (Test-Python $python) -or -not (Test-FFmpeg $bin)) { throw 'Native readiness failed' }
    $env:PATH = $bin + [IO.Path]::PathSeparator + $previousPath
    Push-Location $source
    try {
        & $python -m unittest discover -s tests -v
        if ($LASTEXITCODE -ne 0) { throw 'Application tests failed with the installed dependencies' }
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $source 'tests/installer_contract.ps1') -PythonPath $python
        if ($LASTEXITCODE -ne 0) { throw 'Installer contract tests failed on Windows PowerShell 5.1' }
    } finally { Pop-Location }
    New-AppShortcuts $application
    $menu = Join-Path ([Environment]::GetFolderPath('Programs')) 'DUB Studio/DUB Studio.lnk'
    if (-not (Test-Path $menu)) { throw 'Start menu shortcut missing' }
    $shell = New-Object -ComObject WScript.Shell
    if ($shell.CreateShortcut($menu).TargetPath -ne (Join-Path $application 'Iniciar.bat')) { throw 'Shortcut points to the wrong application' }
    $stdout = Join-Path $root 'app-out.log'
    $stderr = Join-Path $root 'app-error.log'
    $arguments = @(('"{0}"' -f (Join-Path $application 'app.py')), '--data', ('"{0}"' -f (Join-Path $root 'test-data')), '--port','18765')
    $process = Start-Process -FilePath $python -ArgumentList $arguments -WorkingDirectory $application -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $ready = $false
    for ($attempt=0; $attempt -lt 40; $attempt++) {
        if ($process.HasExited) { throw ('Application exited: ' + (Get-Content $stderr -Raw)) }
        try {
            $response = Invoke-WebRequest -Uri 'http://127.0.0.1:18765/api/state' -UseBasicParsing -TimeoutSec 2
            $state = $response.Content | ConvertFrom-Json
            if ($response.StatusCode -eq 200 -and $state.chapters.Count -eq 0) { $ready=$true; break }
        } catch { Start-Sleep -Milliseconds 250 }
    }
    if (-not $ready) { throw 'Application HTTP readiness timed out' }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $source 'tests/windows_lock_smoke.ps1') -Cache (Join-Path $root 'downloads')
    if ($LASTEXITCODE -ne 0) { throw 'Native locking regressions failed' }
    # Launch from a short-lived PowerShell process, then import after it has exited.
    # This reproduces closing the installer/console while keeping the browser open.
    $starter = Join-Path $root 'detached-start.ps1'
    $started = Join-Path $root 'started.json'
    $launchData = Join-Path $root 'detached-data'
    @'
param($Installer,$Python,$FFmpeg,$Application,$DataRoot,$Result)
$ErrorActionPreference='Stop'
. $Installer
Start-Studio $Python $FFmpeg $Application -DataRoot $DataRoot -PreferredPort 18766 -NoBrowser | ConvertTo-Json | Set-Content -LiteralPath $Result
'@ | Set-Content -LiteralPath $starter -Encoding UTF8
    $starterArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $starter),
        '-Installer',('"{0}"' -f $installer),'-Python',('"{0}"' -f $python),'-FFmpeg',('"{0}"' -f $bin),
        '-Application',('"{0}"' -f $application),'-DataRoot',('"{0}"' -f $launchData),'-Result',('"{0}"' -f $started))
    $parent = Start-Process powershell.exe -ArgumentList $starterArgs -Wait -PassThru
    if ($parent.ExitCode -ne 0) { throw 'Detached launcher failed' }
    $running = Get-Content -LiteralPath $started -Raw | ConvertFrom-Json
    $health = Get-StudioHealth $running.port
    if (-not $health) { throw 'Application died when its launcher exited' }
    $url = $running.url
    $state = Invoke-RestMethod -Uri ($url+'/api/state')
    $headers = @{'X-DUB-Token'=$state.token}
    $sample = "1`n00:00:15,120 --> 00:00:15,760`nWhat?`n`n2`n00:00:17,160 --> 00:00:18,120`nThe deputy had an accident?"
    $body = @{name='User SRT regression';srt=$sample} | ConvertTo-Json
    $chapter = Invoke-RestMethod -Uri ($url+'/api/chapter') -Method Post -Headers $headers -ContentType 'application/json' -Body ([Text.Encoding]::UTF8.GetBytes($body))
    $fixture = Join-Path $root 'video-upload.mp4'
    & (Join-Path $bin 'ffmpeg.exe') -hide_banner -loglevel error -y -f lavfi -i 'color=c=green:s=160x120:r=10' -f lavfi -i 'sine=frequency=440:sample_rate=16000' -t 2 -c:v libx264 -pix_fmt yuv420p -c:a aac $fixture
    if ($LASTEXITCODE -ne 0) { throw 'Upload fixture generation failed' }
    $video = Invoke-RestMethod -Uri ($url+"/api/video?chapter=$($chapter.id)&offset=00%3A00%3A15%2C000&name=part.mp4") -Method Post -Headers $headers -ContentType 'application/octet-stream' -Body ([IO.File]::ReadAllBytes($fixture))
    $state = Invoke-RestMethod -Uri ($url+"/api/state?chapter=$($chapter.id)")
    if ($state.lines.Count -ne 2 -or $state.lines[0].start -ne '00:00:15,120' -or $state.videos.Count -ne 1) { throw 'Detached application imports changed or lost user data' }
    $reused = Start-Studio $python $bin $application -DataRoot $launchData -NoBrowser
    if (-not $reused.reused -or $reused.instance -ne $health.instance) { throw 'Launcher duplicated a healthy application' }
    Stop-ManagedStudio $root $application
    if (Get-StudioHealth $running.port) { throw 'Authenticated shutdown failed' }
    Write-Host 'PASS: application survives launcher exit; user SRT and video import succeed afterwards; healthy launch is reused; authenticated shutdown works.'
    Write-Host 'PASS: native Python install/signature, FFmpeg install/codecs, repeat installation, Windows PowerShell 5.1 contracts, application suite, shortcuts and installed application HTTP readiness.'
} finally {
    try { Stop-ManagedStudio $root $application } catch { }
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    $env:PATH = $previousPath
    # Keep test logs until the disposable CI machine is removed.
    Write-Host "Integration test directory: $root"
}
