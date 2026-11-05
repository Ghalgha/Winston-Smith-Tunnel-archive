$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$ServerRoot = Join-Path $ProjectRoot "rust-server"
$ClientRoot = Join-Path $ProjectRoot "rust-client"

Write-Host "Starting simultaneous builds: rust-server and rust-client..."
$serverJob = Start-Job -ArgumentList $ServerRoot -ScriptBlock {
    param($WorkingDirectory)
    Set-Location $WorkingDirectory
    cmd.exe /c "build_linux.bat --no-tests"
    if ($LASTEXITCODE -ne 0) { throw "Linux server build failed with exit code $LASTEXITCODE" }
}
$clientJob = Start-Job -ArgumentList $ClientRoot -ScriptBlock {
    param($WorkingDirectory)
    Set-Location $WorkingDirectory
    cmd.exe /c "build_so.bat --no-tests"
    if ($LASTEXITCODE -ne 0) { throw "Android client build failed with exit code $LASTEXITCODE" }
}

$jobs = @($serverJob, $clientJob)
$jobs | Wait-Job | Out-Null
$failed = $false
foreach ($job in $jobs) {
    Write-Host ("=================== {0} BUILD LOG ===================" -f $job.Name)
    Receive-Job -Job $job -ErrorAction Continue
    if ($job.State -ne "Completed" -or $job.ChildJobs[0].JobStateInfo.State -ne "Completed" -or $job.ChildJobs[0].JobStateInfo.Reason) {
        $failed = $true
    }
}
Remove-Job -Job $jobs -Force
if ($failed) { throw "One or more parallel builds failed." }
