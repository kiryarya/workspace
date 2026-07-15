@echo off
setlocal

cd /d "%~dp0"

call ant -f release.xml release

if errorlevel 1 (
    echo.
    echo リリースファイルの作成に失敗しました。
    exit /b 1
)

echo.
echo WARファイルを作成しました。
echo %CD%\release\application.war

endlocal