@echo off
setlocal

where py >nul 2>nul
if %errorlevel%==0 (
    py -3 "%~dp0apk_builder.py"
    if errorlevel 1 pause
    goto :eof
)

where python >nul 2>nul
if %errorlevel%==0 (
    python "%~dp0apk_builder.py"
    if errorlevel 1 pause
    goto :eof
)

echo.
echo === Python n'a pas ete trouve sur cet ordinateur ===
echo.
echo Installe Python (avec l'option "tcl/tk" cochee, cochee par defaut) :
echo   https://www.python.org/downloads/
echo.
echo Puis relance ce fichier (lancer.bat).
echo.
pause
