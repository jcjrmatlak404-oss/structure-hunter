@echo off
REM Structure Hunter - dependency setup (Windows)
REM Installs the Python packages needed for the LiDAR / elevation features.

echo Structure Hunter - setup
echo ------------------------

where ruby >nul 2>nul
if %errorlevel%==0 (
  echo [ok]  Ruby found
  ruby --version
) else (
  echo [!!]  Ruby not found. Install from https://rubyinstaller.org/
  exit /b 1
)

where python >nul 2>nul
if %errorlevel%==0 (
  echo [ok]  Python found
  python --version
) else (
  echo [!!]  Python 3 not found. LiDAR features will be unavailable.
  echo       Install from https://www.python.org/
  echo       You can still run the vector scan: ruby hunter.rb
  exit /b 0
)

echo.
echo Installing Python packages for LiDAR (numpy laspy lazrs pyproj rasterio)...
python -m pip install numpy laspy lazrs pyproj rasterio
if %errorlevel%==0 (
  echo [ok]  Packages installed.
) else (
  echo [!!]  Install failed. Try manually:
  echo       python -m pip install numpy laspy lazrs pyproj rasterio
  exit /b 1
)

echo.
echo Setup complete. Start the app with:
echo     ruby hunter.rb
echo Then open http://localhost:8080 in your browser.
