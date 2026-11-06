[CmdletBinding()]
param(
    [string[]]$Distros = @("Ubuntu-24.04", "Debian"),
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
)
$ErrorActionPreference = "Stop"
$installed = @(& wsl.exe --list --quiet 2>$null | ForEach-Object { $_.Replace([char]0, '').Trim() } | Where-Object { $_ })
if ($LASTEXITCODE -ne 0 -or $installed.Count -eq 0) { throw "Unable to find installed WSL distributions." }

$results = [ordered]@{}
$tested = 0
foreach ($distro in $Distros) {
    Write-Host ">>> WSTT checks: $distro" -ForegroundColor Cyan
    if ($installed -notcontains $distro) {
        $results[$distro] = "NOT_INSTALLED"
        Write-Host "[SKIP] Not installed" -ForegroundColor DarkYellow
        continue
    }
    $tested++
    $rootOut = @(& wsl.exe -d $distro --exec wslpath -u $ProjectRoot 2>&1)
    $pathCode = $LASTEXITCODE
    if ($pathCode -ne 0 -or $rootOut.Count -eq 0) {
        $results[$distro] = "FAILED_PATH"
        Write-Host ($rootOut -join [Environment]::NewLine) -ForegroundColor Red
        continue
    }
    $script = "$(([string]$rootOut[-1]).Trim())/scripts/run_wsl_checks.sh"
    $output = @(& wsl.exe -d $distro --exec bash $script 2>&1)
    $code = $LASTEXITCODE
    foreach ($line in $output) {
        $s = [string]$line
        if ($s -match '^\[SKIP\]|^STATUS: PASS_WITH') { Write-Host $s -ForegroundColor DarkYellow }
        elseif ($s -match '^\[PASS\]|^STATUS: PASS') { Write-Host $s -ForegroundColor Green }
        elseif ($s -match '^\[FAIL\]|error|failed') { Write-Host $s -ForegroundColor Red }
        else { Write-Host $s }
    }
    if ($code -ne 0) { $results[$distro] = "FAILED ($code)" }
    elseif (($output | Where-Object { ([string]$_) -match '^\[SKIP\]|^STATUS: PASS_WITH' }).Count -gt 0) { $results[$distro] = "PASSED_WITH_SKIPS" }
    else { $results[$distro] = "PASSED" }
}
Write-Host ""
Write-Host "WSL test matrix:"
foreach ($distro in $results.Keys) {
    $status = $results[$distro]
    $color = if ($status -eq "PASSED") { "Green" } elseif ($status -in @("NOT_INSTALLED", "PASSED_WITH_SKIPS")) { "DarkYellow" } else { "Red" }
    Write-Host ("{0,-16} {1}" -f $distro, $status) -ForegroundColor $color
}
if ($tested -eq 0 -or @($results.Values | Where-Object { $_ -notin @("PASSED", "PASSED_WITH_SKIPS", "NOT_INSTALLED") }).Count -gt 0) { exit 1 }
