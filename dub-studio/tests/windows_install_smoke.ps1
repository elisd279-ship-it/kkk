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
    Write-Host 'PASS: native Python install/signature, FFmpeg install/codecs, repeat installation, Windows PowerShell 5.1 contracts, application suite, shortcuts and installed application HTTP readiness.'
} finally {
    if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    $env:PATH = $previousPath
    # Keep test logs until the disposable CI machine is removed.
    Write-Host "Integration test directory: $root"
}
