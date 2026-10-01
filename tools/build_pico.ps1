param([string]$ArduinoCli = 'arduino-cli')
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    & powershell -NoProfile -ExecutionPolicy Bypass -File web/embed_web.ps1
    if ($LASTEXITCODE -ne 0) { throw 'Embedding the web page failed.' }
    # Explicit board/clock settings make CLI and Arduino IDE builds consistent.
    # 133 MHz stays within the RP2040 rating; core defaults can select 200 MHz.
    & $ArduinoCli compile --fqbn rp2040:rp2040:rpipicow:freq=133 --build-path .cache/pico firmware/pico_scope
    if ($LASTEXITCODE -ne 0) { throw 'Pico W compilation failed.' }
    Copy-Item -LiteralPath .cache/pico/pico_scope.ino.uf2 -Destination output_files/pico_scope.uf2
    Write-Host 'Pico W image: output_files/pico_scope.uf2'
} finally { Pop-Location }
