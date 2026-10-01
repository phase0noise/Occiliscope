param(
    [string]$Quartus = 'C:/intelFPGA_lite/23.1std/quartus/bin64/quartus_sh.exe'
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot

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
    Push-Location "${substDrive}\"
    $locationPushed = $true
    # Windows PowerShell turns native stderr into ErrorRecords when redirected.
    # Quartus writes diagnostics there; use its exit status to decide success.
    $ErrorActionPreference = 'Continue'
    & $Quartus --flow compile oscilloscope
    $compileExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($compileExit -ne 0) { throw "Quartus compile failed ($compileExit)." }
    Write-Host "Programming files: $projectRoot/output_files"
} finally {
    if ($locationPushed) { Pop-Location }
    if ($null -ne $substDrive) { & subst.exe $substDrive /d | Out-Null }
}
