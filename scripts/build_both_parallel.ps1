Write-Host "Starting simultaneous builds: rust-server and rust-client..."
$serverJob = Start-Job -ScriptBlock {
    Set-Location (Join-Path $ProjectRoot "rust-server")
    cmd.exe /c "build_linux.bat --no-tests"
}
$clientJob = Start-Job -ScriptBlock {
    Set-Location (Join-Path $ProjectRoot "rust-client")
    cmd.exe /c "build_so.bat --no-tests"
}

$jobs = @($serverJob, $clientJob)
Wait-Job -Job $jobs | Out-Null

Write-Host "=================== SERVER BUILD LOG ==================="
Receive-Job -Job $serverJob
Write-Host "=================== CLIENT BUILD LOG ==================="
Receive-Job -Job $clientJob

Remove-Job -Job $jobs
