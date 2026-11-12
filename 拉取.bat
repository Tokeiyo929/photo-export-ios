@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

rem ===== Pull exported photos from phone to PC. Edit DEST below. =====
rem ===== Keep using the SAME DEST folder (resume/verify rely on it). =====
set "DEST=E:\projects\PhotoExport"

echo ==========================================
echo   Photo Export - pull from phone
echo   Dest folder: %DEST%
echo ==========================================
echo.
echo   [1] USB cable (AFC; may be broken on this iOS 27 device)
echo   [2] WiFi transfer (start WiFi in the phone app first;
echo       press Enter at the address prompt to auto-discover)
echo.
set /p CHOICE=Choose 1 or 2 (default 1):
if "%CHOICE%"=="2" goto wifi

:data
python pc\pull.py --dest "%DEST%" %*
goto done

:wifi
set /p WURL=App URL (Enter = auto-discover, e.g. http://192.168.1.5:8765):
python pc\pull.py --wifi "%WURL%" --dest "%DEST%" %*

:done
echo.
echo Done. Files and report are in %DEST%
pause
