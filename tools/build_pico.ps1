param(
    [string]$ArduinoCli,
    [string]$Port,
    [string]$Uf2Drive
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
if ($Port -and $Uf2Drive) { throw 'Choose either a serial Port or a BOOTSEL Uf2Drive.' }
if (-not $ArduinoCli) {
    $cliCommand = Get-Command arduino-cli -ErrorAction SilentlyContinue
    if ($cliCommand) { $ArduinoCli = $cliCommand.Source }
    else {
        $bundledCli = Join-Path $env:LOCALAPPDATA 'Programs/Arduino IDE/resources/app/lib/backend/resources/arduino-cli.exe'
        if (Test-Path -LiteralPath $bundledCli) { $ArduinoCli = $bundledCli }
        else { throw 'Arduino CLI was not found. Install it or pass -ArduinoCli with its path.' }
    }
}
$fqbn = 'rp2040:rp2040:rpipicow:freq=133'
Push-Location $projectRoot
try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File web/embed_web.ps1
    if ($LASTEXITCODE -ne 0) { throw 'Embedding the web page failed.' }
    # Explicit board/clock settings make CLI and Arduino IDE builds consistent.
    # 133 MHz stays within the RP2040 rating; core defaults can select 200 MHz.
    & $ArduinoCli compile --fqbn $fqbn --build-path .cache/pico firmware/pico_scope
    if ($LASTEXITCODE -ne 0) { throw 'Pico W compilation failed.' }
    Copy-Item -LiteralPath .cache/pico/pico_scope.ino.uf2 -Destination output_files/pico_scope.uf2
    Write-Host 'Pico W image: output_files/pico_scope.uf2'
    if ($Port) {
        & $ArduinoCli upload --fqbn $fqbn --port $Port --input-dir .cache/pico firmware/pico_scope
        if ($LASTEXITCODE -ne 0) { throw 'Upload failed. Hold BOOTSEL while connecting USB, then copy output_files/pico_scope.uf2 to RPI-RP2.' }
    }
    if ($Uf2Drive) {
        $driveRoot = (Resolve-Path -LiteralPath $Uf2Drive).ProviderPath
        $infoPath = Join-Path $driveRoot 'INFO_UF2.TXT'
        if (-not (Test-Path -LiteralPath $infoPath) -or
            (Get-Content -LiteralPath $infoPath -Raw) -notmatch '(?m)^Board-ID:\s*RPI-RP2\s*$') {
            throw 'Uf2Drive must be the RPI-RP2 BOOTSEL drive of an RP2040 Pico W.'
        }
        Copy-Item -LiteralPath output_files/pico_scope.uf2 -Destination (Join-Path $driveRoot 'pico_scope.uf2')
        Write-Host 'UF2 copied. The Pico should reboot and create PicoScope.'
    }
} finally { Pop-Location }
