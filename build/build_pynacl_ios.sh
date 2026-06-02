#!/usr/bin/env bash
# Build PyNaCl wheel for iPhoneOS arm64 (a-Shell compatible)
# Prerequisites:
#   - libsodium built via build_libsodium_ios.sh
#   - Python 3.13 venv with cffi installed (pip install cffi)
#   - Xcode with iPhoneOS SDK
set -euo pipefail

PYNACL_VERSION="${1:-1.6.2}"
PYNACL_SRC="pynacl-${PYNACL_VERSION}"
VENV_NAME="${2:-ios-venv}"

if [ ! -d "$PYNACL_SRC" ]; then
    echo "Downloading PyNaCl ${PYNACL_VERSION}..."
    curl -L "https://pypi.io/packages/source/p/pynacl/PyNaCl-${PYNACL_VERSION}.tar.gz" -o pynacl.tar.gz
    tar xzf pynacl.tar.gz
    rm pynacl.tar.gz
fi

cd "$PYNACL_SRC"

# Create venv if missing
if [ ! -d "$VENV_NAME" ]; then
    echo "Creating virtual environment..."
    python3.13 -m venv "$VENV_NAME"
fi

source "$VENV_NAME/bin/activate"
pip install --upgrade pip setuptools wheel cffi

# Clean previous builds
rm -rf build
find . -name '*.so' -delete 2>/dev/null || true
find . -name '*.o' -delete 2>/dev/null || true

export IOS_SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
export IOS_CC="$(xcrun --sdk iphoneos --find clang)"
export CC="$IOS_CC"
export SDKROOT="$IOS_SDK"
export ARCHFLAGS="-arch arm64"
export _PYTHON_HOST_PLATFORM="ios-arm64"
export SODIUM_INSTALL=system
export SODIUMINCL="-I$PWD/../build/libsodium/include"
export SODIUMLIB="-L$PWD/../build/libsodium/lib"
export CFLAGS="-arch arm64 -isysroot $IOS_SDK -miphoneos-version-min=14.0 $SODIUMINCL"
export LDFLAGS="-arch arm64 -isysroot $IOS_SDK -miphoneos-version-min=14.0 $SODIUMLIB"

echo "=== Building PyNaCl extension ==="
python3 setup.py build_ext --inplace

echo "=== Inspecting built extension ==="
if compgen -G 'src/nacl/_sodium*.so' > /dev/null; then
    file src/nacl/_sodium*.so
    otool -l src/nacl/_sodium*.so | grep -A5 LC_BUILD_VERSION
else
    echo "ERROR: _sodium extension not built"
    exit 1
fi

echo "=== Building wheel (ios_arm64 tag) ==="
python3 setup.py bdist_wheel

echo "=== Repackaging for a-Shell (ios_14_arm64_iphoneos tag) ==="
WHEEL_FILE=$(ls dist/pynacl-*-ios_arm64.whl 2>/dev/null | head -1)
if [ -n "$WHEEL_FILE" ]; then
    REPACK_DIR=$(mktemp -d)
    python3 -m zipfile -e "$WHEEL_FILE" "$REPACK_DIR/root"

    cd "$REPACK_DIR/root"

    # Rename extension to match a-Shell's EXT_SUFFIX
    if [ -f nacl/_sodium.abi3.so ]; then
        mv nacl/_sodium.abi3.so nacl/_sodium.cpython-313-iphoneos.so
    fi

    # Pseudo-sign the extension with ldid — iOS requires a code signature
    # for dynamically loaded libraries. macOS codesign -s - creates an
    # adhoc signature that iOS rejects ("code signature invalid").
    # ldid -S creates a minimal LC_CODE_SIGNATURE that iOS accepts.
    # Install ldid via: brew install ldid
    ldid -S nacl/_sodium.cpython-313-iphoneos.so

    # Update WHEEL tag
    sed -i '' 's/Tag: cp313-cp313-ios_arm64/Tag: cp313-cp313-ios_14_arm64_iphoneos/' pynacl-*.dist-info/WHEEL

    # Update RECORD
    python3 -c "
import hashlib, os
for root, dirs, files in os.walk('.'):
    for f in files:
        path = os.path.join(root, f)
        if 'RECORD' in path:
            continue
        data = open(path, 'rb').read()
        h = hashlib.sha256(data).hexdigest()
        s = os.path.getsize(path)
        arcname = os.path.relpath(path, '.')
        print(f'{arcname},sha256={h},{s}')
" > /tmp/new_records.txt

    # Rebuild RECORD properly
    python3 << 'PYEOF'
import hashlib, os, zipfile

root = "."
record_path = None
for d in os.listdir("."):
    if d.endswith(".dist-info") and os.path.isdir(d):
        record_path = os.path.join(d, "RECORD")
        break

lines = []
for r, dirs, files in os.walk(root):
    for f in files:
        full = os.path.join(r, f)
        arcname = os.path.relpath(full, root)
        if arcname == record_path:
            lines.append(f"{record_path},,")
            continue
        data = open(full, "rb").read()
        h = hashlib.sha256(data).hexdigest()
        s = len(data)
        lines.append(f"{arcname},sha256={h},{s}")

with open(record_path, "w") as f:
    f.write("\n".join(lines) + "\n")
PYEOF

    # Repackage
    DEST="$OLDPWD/dist"
    mkdir -p "$DEST"
    python3 -c "
import zipfile, os
whl = os.path.join('$DEST', 'pynacl-${PYNACL_VERSION}-cp313-cp313-ios_14_arm64_iphoneos.whl')
with zipfile.ZipFile(whl, 'w', zipfile.ZIP_DEFLATED) as zf:
    for r, dirs, files in os.walk('.'):
        for f in files:
            full = os.path.join(r, f)
            arcname = os.path.relpath(full, '.')
            zf.write(full, arcname)
print('Created:', whl)
"
    cd "$OLDPWD"
    rm -rf "$REPACK_DIR"
fi

echo "=== Done ==="
ls -la dist/*.whl
