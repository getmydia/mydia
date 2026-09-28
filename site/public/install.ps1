# Installs Mydia Player for Windows.
#
#   irm https://mydia.dev/install.ps1 | iex
#
# The installer is not code signed. A browser download carries
# Mark-of-the-Web, so SmartScreen blocks its first run. Invoke-WebRequest
# writes no Mark-of-the-Web, so running the installer from here does not
# trigger that prompt. It installs for the current user only and never asks
# for admin rights.
#
# Everything runs inside one script block so that no variables or preference
# changes leak into the caller's session through iex.

& {
    $ErrorActionPreference = 'Stop'
    # Windows PowerShell 5.1 redraws its progress bar for every chunk, which
    # makes a large download many times slower.
    $ProgressPreference = 'SilentlyContinue'
    # 5.1 on older .NET defaults to TLS 1.0/1.1, which GitHub refuses.
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $downloadUrl = 'https://mydia.dev/download/windows'
    $manualUrl = 'https://mydia.dev/download#windows'
    $installer = Join-Path $env:TEMP 'mydia-player-setup.exe'

    try {
        Write-Host 'Downloading Mydia Player...'
        # -UseBasicParsing keeps 5.1 off the Internet Explorer engine, which
        # fails where IE was never set up. PowerShell 7 ignores it.
        Invoke-WebRequest -Uri $downloadUrl -OutFile $installer -UseBasicParsing

        Write-Host 'Installing...'
        $process = Start-Process -FilePath $installer -ArgumentList '/SILENT' -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw "The installer exited with code $($process.ExitCode)."
        }

        Write-Host 'Mydia Player is installed. Open it from the Start menu.'
    }
    catch {
        throw "Mydia Player was not installed: $($_.Exception.Message)`nYou can download the installer instead from $manualUrl"
    }
    finally {
        Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
    }
}
