@echo off
setlocal

cd /d "%~dp0"

powershell.exe ^
  -NoProfile ^
  -ExecutionPolicy Bypass ^
  -File "%~dp0deploy.ps1" ^
  -ConfigPath "%~dp0deploy-config.psd1"

if errorlevel 1 (
    echo.
    echo デプロイに失敗しました。
    pause
    exit /b 1
)

echo.
echo デプロイが完了しました。
pause

endlocal