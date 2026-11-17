@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

rem ===== Pull exported photos from phone to PC. Edit DEST below. =====
rem ===== Keep using the SAME DEST folder (resume/verify rely on it). =====
set "DEST=E:\projects\PhotoExport"

rem ===== Resolve Python without trusting PATH: Explorer can hold a stale
rem ===== environment after PATH changes, which makes "python" vanish here.
set "PYEXE="
set "PYARGS="
py -3 -V >nul 2>&1 && (set "PYEXE=py" & set "PYARGS=-3")
if not defined PYEXE (
  python -V >nul 2>&1 && (set "PYEXE=python")
)
if not defined PYEXE (
  for %%P in (
    "%LOCALAPPDATA%\Programs\Python\Python312\python.exe"
    "%LOCALAPPDATA%\Programs\Python\Python311\python.exe"
    "%LOCALAPPDATA%\Programs\Python\Python310\python.exe"
    "%ProgramFiles%\Python312\python.exe"
    "%ProgramFiles%\Python311\python.exe"
    "%ProgramFiles%\Python310\python.exe"
  ) do (
    if not defined PYEXE if exist "%%~P" set "PYEXE=%%~P"
  )
)
if not defined PYEXE (
  echo.
  echo [ERROR] Python 3 not found. Install Python 3 from python.org and tick
  echo         "Add python.exe to PATH", then double-click this bat again.
  pause
  exit /b 1
)

echo ==========================================
echo   Photo Export - pull from phone
echo   Dest folder: %DEST%
echo ==========================================
echo.
echo   [1] USB cable (normal pull)
echo   [2] WiFi transfer (start WiFi in the phone app first;
echo       press Enter at the address prompt to auto-discover)
echo   [3] Cable + originals comparison: FIRST on the phone share
echo       2-3 photos -\> Save to Files -\> our app, then pick 3
echo.
set /p CHOICE=Choose 1 / 2 / 3 (default 1):
if "%CHOICE%"=="2" goto wifi
if "%CHOICE%"=="3" goto compare

:data
"%PYEXE%" %PYARGS% pc\pull.py --dest "%DEST%" %*
set "RC=%ERRORLEVEL%"
goto done

:wifi
set /p WURL=App URL (Enter = auto-discover, e.g. http://192.168.1.5:8765):
"%PYEXE%" %PYARGS% pc\pull.py --wifi "%WURL%" --dest "%DEST%" %*
set "RC=%ERRORLEVEL%"
goto done

:compare
"%PYEXE%" %PYARGS% pc\pull.py --dest "%DEST%" --compare-orphans %*
set "RC=%ERRORLEVEL%"
goto done

:done
echo.
if not "%RC%"=="0" (
  echo [ERROR] pull failed with exit code %RC% - read the messages above.
) else (
  echo Done. Files and report are in %DEST%
)
pause
