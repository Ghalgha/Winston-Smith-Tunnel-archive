@echo off
setlocal
chcp 65001 >nul
title WSTT WSL Test Runner
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0test_wsl_unified.ps1" %*
set "TEST_EXIT=%ERRORLEVEL%"
if not "%TEST_EXIT%"=="0" echo [ERROR] WSTT WSL checks failed with exit code %TEST_EXIT%.
endlocal & exit /b %TEST_EXIT%
