@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

rem ===== 双击即可拉取。要改默认目录就动下面这行 =====
set "DEST=D:\相册导出"

echo ==========================================
echo   照片无损导出 · 拉取到电脑
echo   目标目录: %DEST%
echo ==========================================
echo.
echo   [1] 数据线拉取（AFC 通道；iOS 27 真机上可能失效，报 OBJECT_NOT_FOUND 就是它）
echo   [2] WiFi 直传（手机 App 首页开「WiFi 传图」，把显示的地址填进来）
echo.
set /p CHOICE=选 1 或 2（回车默认 1）:
if "%CHOICE%"=="2" goto wifi

:data
python pc\pull.py --dest "%DEST%" %*
goto done

:wifi
set /p WURL=输入 App 显示的地址（直接回车=自动搜索同一网络里的手机）:
python pc\pull.py --wifi "%WURL%" --dest "%DEST%" %*

:done
echo.
echo 结束。报告与文件都在 %DEST%
pause
