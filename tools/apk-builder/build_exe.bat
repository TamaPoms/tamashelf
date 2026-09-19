@echo off
setlocal
cd /d "%~dp0"

echo Installation de PyInstaller...
py -3 -m pip install --upgrade pyinstaller
if errorlevel 1 (
    python -m pip install --upgrade pyinstaller
)

echo.
echo Construction de TamaShelfApkBuilder.exe...
py -3 -m PyInstaller --onefile --windowed --name TamaShelfApkBuilder apk_builder.py
if errorlevel 1 (
    python -m PyInstaller --onefile --windowed --name TamaShelfApkBuilder apk_builder.py
)

echo.
echo Termine. L'executable se trouve dans dist\TamaShelfApkBuilder.exe
pause
