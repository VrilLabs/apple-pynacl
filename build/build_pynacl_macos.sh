#!/usr/bin/env bash
# Build PyNaCl wheel for macOS x86_64
# Prerequisites:
#   - Python 3.14 with pip
#   - Xcode command line tools
set -euo pipefail

PYNACL_VERSION="${1:-1.6.2}"
PYNACL_SRC="pynacl-${PYNACL_VERSION}"

if [ ! -d "$PYNACL_SRC" ]; then
    echo "Downloading PyNaCl ${PYNACL_VERSION}..."
    curl -L "https://pypi.io/packages/source/p/pynacl/PyNaCl-${PYNACL_VERSION}.tar.gz" -o pynacl.tar.gz
    tar xzf pynacl.tar.gz
    rm pynacl.tar.gz
fi

cd "$PYNACL_SRC"

# Create venv if missing
if [ ! -d "macos-venv" ]; then
    echo "Creating virtual environment..."
    python3.14 -m venv macos-venv
fi

source macos-venv/bin/activate
pip install --upgrade pip setuptools wheel cffi

# Clean previous builds
rm -rf build dist
find . -name '*.so' -delete 2>/dev/null || true

# Build with bundled libsodium (default)
echo "=== Building PyNaCl for macOS ==="
python3 setup.py bdist_wheel

echo "=== Done ==="
ls -la dist/*.whl
