param(
    [string]$Quartus = 'C:/intelFPGA_lite/23.1std/quartus/bin64/quartus_sh.exe'
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$buildRoot = Join-Path $projectRoot 'build/quartus'
New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null

# Build a source snapshot so verification does not overwrite the user's
# existing Quartus database or programming outputs in the project directory.
Get-ChildItem -LiteralPath $projectRoot -File | Where-Object {
    $_.Extension -in '.v', '.vhd', '.qsf', '.qpf', '.sdc'
} | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $buildRoot -Force
}
Copy-Item -LiteralPath (Join-Path $projectRoot 'adc_qsys') -Destination $buildRoot -Recurse -Force

$substDrive = $null
$locationPushed = $false
try {
    # Quartus 23.1 can incorrectly canonicalize paths below the Windows
    # Documents known folder (dropping "Documents" and rejecting the project
    # name). Build through a temporary drive mapping so command-line builds are
    # repeatable from this repository location.
    foreach ($letter in @('Q','R','S','T','U','V','W','X','Y','Z')) {
        $candidate = "${letter}:"
        if (-not (Test-Path "${candidate}\")) {
            & subst.exe $candidate $projectRoot
            if ($LASTEXITCODE -eq 0) { $substDrive = $candidate; break }
        }
    }
    if ($null -eq $substDrive) { throw 'No free drive letter is available for the Quartus build.' }
    Push-Location "${substDrive}\build\quartus"
    $locationPushed = $true
    # Windows PowerShell turns native stderr into ErrorRecords when redirected.
    # Quartus writes diagnostics there; use its exit status to decide success.
    $ErrorActionPreference = 'Continue'
    & $Quartus --flow compile oscilloscope
    $compileExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($compileExit -ne 0) { throw "Quartus compile failed ($compileExit)." }
    Write-Host "Build reports and programming file: $buildRoot/output_files"
} finally {
    if ($locationPushed) { Pop-Location }
    if ($null -ne $substDrive) { & subst.exe $substDrive /d | Out-Null }
}
