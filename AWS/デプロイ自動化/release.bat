@echo off
setlocal

cd /d "%~dp0"

call ant -f release.xml release

if errorlevel 1 (
    echo.
    echo リリース処理に失敗しました。
    pause
    exit /b 1
)

echo.
echo リリース処理が完了しました。
pause

endlocal
