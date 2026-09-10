@echo off
setlocal
cd /d "%~dp0"

set "TARGET_URL=%~dp0index.html"
if exist "%~dp0kiosk.conf" (
    for /f "tokens=1,2 delims==" %%A in (kiosk.conf) do (
        if "%%A"=="TARGET_URL" (
            set "TARGET_URL=%%~B"
        )
    )
)

:: Try Microsoft Edge Kiosk
where msedge >nul 2>nul
if %errorlevel% equ 0 (
    start "" msedge --kiosk "%TARGET_URL%" --edge-kiosk-type=fullscreen --no-first-run
    exit /b 0
)

:: Try Google Chrome Kiosk
where chrome >nul 2>nul
if %errorlevel% equ 0 (
    start "" chrome --kiosk "%TARGET_URL%" --no-first-run --disable-infobars
    exit /b 0
)

:: Try default browser fallback
start "" "%TARGET_URL%"
exit /b 0
