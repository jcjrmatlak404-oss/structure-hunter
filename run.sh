#!/usr/bin/env bash
# Structure Hunter launcher — checks Ruby and starts the console.
set -e
if ! command -v ruby >/dev/null 2>&1; then
  echo "Ruby is not installed. See README.md (Quick start) to install it."
  exit 1
fi
echo "Starting Structure Hunter..."
echo "When it's ready, open http://localhost:8080 in your browser."
echo "Press Ctrl+C to stop."
echo
exec ruby "$(dirname "$0")/hunter.rb"
