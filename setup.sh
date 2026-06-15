#!/usr/bin/env bash
#
# Structure Hunter — dependency setup
# Installs the Python packages needed for the LiDAR / elevation features.
# The footprint-vs-address scan works without these (Ruby standard library only).

set -e

echo "Structure Hunter — setup"
echo "------------------------"

# --- Ruby check ---
if command -v ruby >/dev/null 2>&1; then
  echo "[ok]  Ruby found: $(ruby --version)"
else
  echo "[!!]  Ruby not found."
  echo "      Install it:"
  echo "        macOS:   brew install ruby   (or use the preinstalled one)"
  echo "        Windows: https://rubyinstaller.org/"
  echo "        Linux:   sudo apt install ruby"
  exit 1
fi

# --- Python check ---
PY=""
if command -v python3 >/dev/null 2>&1; then PY="python3"
elif command -v python >/dev/null 2>&1; then PY="python"
fi

if [ -z "$PY" ]; then
  echo "[!!]  Python 3 not found. LiDAR features will be unavailable."
  echo "      Install Python 3 from https://www.python.org/ then re-run this script."
  echo
  echo "You can still run the app now (vector scan only): ruby hunter.rb"
  exit 0
fi
echo "[ok]  Python found: $($PY --version 2>&1)"

# --- Python packages ---
echo
echo "Installing Python packages for LiDAR (numpy laspy lazrs pyproj rasterio)..."

PKGS="numpy laspy lazrs pyproj rasterio"

# Try a normal install first; fall back to --break-system-packages (newer Linux)
if $PY -m pip install $PKGS 2>/dev/null; then
  echo "[ok]  Packages installed."
elif $PY -m pip install --break-system-packages $PKGS; then
  echo "[ok]  Packages installed (--break-system-packages)."
else
  echo "[!!]  Package install failed. Try manually:"
  echo "        $PY -m pip install $PKGS"
  echo "      You may need: $PY -m pip install --break-system-packages $PKGS"
  exit 1
fi

echo
echo "Setup complete. Start the app with:"
echo "    ruby hunter.rb"
echo "Then open http://localhost:8080 in your browser."
