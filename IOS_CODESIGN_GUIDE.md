# iOS Code Signing Guide for PyNaCl Native Extensions

## The Problem

On non-jailbroken iOS, `dlopen()` enforces **mandatory code signature validation** for all
loaded Mach-O images. The signature must:

1. **Chain to an Apple-trusted root certificate** (i.e., be signed with an Apple Developer
   signing identity — not ad-hoc, not `ldid` pseudo-signature)
2. **Match the app's team** unless the app has the `disable-library-validation` entitlement

a-Shell (App Store version, signed by team **AsheKube**) does **NOT** include the
`com.apple.security.cs.disable-library-validation` entitlement. This means:

- `codesign -s -` (macOS ad-hoc) → ❌ rejected: "completely unsigned" or "code signature invalid"
- `ldid -S` (pseudo-signature) → ❌ rejected: "code signature invalid"
- Signed with **your** developer cert → ❌ rejected: different team than a-Shell
- Signed with **AsheKube's** cert → ✅ but you don't have their private key

**Bottom line**: On a non-jailbroken device with the stock App Store a-Shell, it is
**impossible** to load a custom native `.so` extension via `dlopen()`. This is an iOS
security enforcement, not a build issue.

This is confirmed by a-Shell's own documentation:
> "For Python, you can install more packages with pip install packagename, but only if
> they are pure Python. The C compiler is not yet able to produce dynamic libraries that
> could be used by Python."

---

## Solutions

There are **three viable paths** to get native extensions working on iOS, in order of
practicality:

---

### Option A: Build a Custom a-Shell with `disable-library-validation` (Recommended)

This is the most practical solution. You build a-Shell from source with your own
signing identity and add the entitlement that allows loading third-party libraries.

#### Prerequisites

- Apple Developer account (you have one as VLABS, LLC)
- Xcode 15+ installed on your Mac
- Your signing identity installed in Keychain

#### Step 1: Install your signing identity

```sh
# Verify your signing identities are installed
security find-identity -v -p codesigning

# You should see something like:
# 1) ABC123... "Apple Development: your@email.com (XXXXXXXXXX)"
# 2) DEF456... "Developer ID Application: VLABS, LLC (XXXXXXXXXX)"
```

If no identities are found, install them from Xcode:
1. Open Xcode → Settings → Accounts
2. Add your Apple ID
3. Select your team → Manage Certificates → add signing certificate

#### Step 2: Clone and configure a-Shell

```sh
git clone https://github.com/holzschu/a-shell.git
cd a-shell
git submodule update --init --recursive

# Download prebuilt frameworks (saves hours of compilation)
./downloadFrameworks.sh
```

#### Step 3: Add the entitlement

Edit `a-Shell/a-Shell.entitlements` and add these two entitlements inside the
top-level `<dict>`:

```xml
<!-- Allow loading libraries signed by other teams -->
<key>com.apple.security.cs.disable-library-validation</key>
<true/>

<!-- Allow loading libraries with unsigned executable memory (needed for JIT/FFI) -->
<key>com.apple.security.cs.allow-unsigned-executable-memory</key>
<true/>
```

#### Step 4: Configure signing in Xcode

1. Open `a-Shell.xcodeproj` in Xcode
2. Select the **a-Shell** target
3. **Signing & Capabilities** tab:
   - Team: **VLABS, LLC** (your team)
   - Bundle Identifier: change to something unique, e.g., `com.vrlabs.a-Shell`
4. Repeat for the **a-Shell-Intents** and **a-Shell-IntentsUI** targets
5. For **a-Shell-mini** target (if needed), same changes

#### Step 5: Build and deploy

1. Connect your iPad
2. Select your device as the run destination
3. Product → Build (⌘B)
4. Product → Run (⌘R) — this installs on the device

#### Step 6: Sign the PyNaCl `.so` with your identity

```sh
# Extract the wheel
mkdir -p /tmp/pynacl-sign && cd /tmp/pynacl-sign
python3 -m zipfile -e /path/to/pynacl-1.6.2-cp313-cp313-ios_14_arm64_iphoneos.whl .

# Remove any existing signature
codesign --remove-signature nacl/_sodium.cpython-313-iphoneos.so

# Sign with your developer identity (use the exact identity name from Step 1)
codesign -s "Apple Development: your@email.com (XXXXXXXXXX)" \
    --force \
    --timestamp=none \
    nacl/_sodium.cpython-313-iphoneos.so

# Verify
codesign -dvvv nacl/_sodium.cpython-313-iphoneos.so

# Repackage (see build script for full RECORD update)
# ... then copy wheel to iPad and pip install
```

#### Step 7: Install on iPad

Transfer the signed wheel to your iPad and install in a-Shell:

```sh
pip install --force-reinstall pynacl-1.6.2-cp313-cp313-ios_14_arm64_iphoneos.whl
```

---

### Option B: Use the Official Python-on-iOS Framework Approach

This is the approach recommended by Python's official documentation (PEP 730 / Python 3.14+).
It wraps each `.so` into an individual `.framework` bundle and uses a custom import loader.

This is only viable if you are building your **own** iOS app that embeds Python — it does
not work with the App Store version of a-Shell.

#### How it works

1. Each `.so` is converted to a framework: `Frameworks/nacl._sodium.framework/nacl._sodium`
2. Each framework has an `Info.plist` with `CFBundleExecutable` and `CFBundleIdentifier`
3. The original `.so` location gets a `.fwork` text file pointing to the framework
4. Python's `AppleFrameworkLoader` reads `.fwork` files and loads from Frameworks/
5. All frameworks are signed with the app's signing identity during the Xcode build

#### Quick reference

```sh
# Create framework structure
FRAMEWORK_NAME="nacl._sodium"
FRAMEWORK_DIR="Frameworks/${FRAMEWORK_NAME}.framework"
mkdir -p "${FRAMEWORK_DIR}"

# Copy the binary
cp nacl/_sodium.cpython-313-iphoneos.so "${FRAMEWORK_DIR}/${FRAMEWORK_NAME}"

# Create Info.plist
cat > "${FRAMEWORK_DIR}/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>nacl._sodium</string>
  <key>CFBundleIdentifier</key>
  <string>com.vrlabs.nacl._sodium</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundlePackageType</key>
  <string>FMWK</string>
  <key>CFBundleVersion</key>
  <string>1.0.0</string>
</dict>
</plist>
EOF

# Create .fwork marker file at the original .so location
echo "Frameworks/${FRAMEWORK_NAME}.framework/${FRAMEWORK_NAME}" \
    > nacl/_sodium.cpython-313-iphoneos.fwork

# Create .origin file in the framework
echo "../../nacl/_sodium.cpython-313-iphoneos.fwork" \
    > "${FRAMEWORK_DIR}/nacl._sodium.origin"
```

Then add the framework to your Xcode project with "Embed & Sign", and add a build phase
that processes Python libraries (see Python 3.14 docs for details).

---

### Option C: Jailbroken Device

On a jailbroken device, the kernel's code signature enforcement is patched out, so
`ldid -S` pseudo-signatures work fine. No Xcode or developer certificate needed.

```sh
# On the build Mac, sign with ldid and repackage
ldid -S nacl/_sodium.cpython-313-iphoneos.so
```

This is the simplest approach but requires a jailbreak, which most users don't have.

---

## Summary

| Approach | Works with stock a-Shell? | Requires jailbreak? | Requires Xcode? | Complexity |
|----------|--------------------------|--------------------|-----------------|------------|
| **A: Custom a-Shell** | No (use custom build) | No | Yes | Medium |
| **B: Framework wrapping** | No (own app only) | No | Yes | High |
| **C: Jailbreak + ldid** | Yes | Yes | No | Low |

**Recommendation**: If you want to use PyNaCl in a-Shell on your iPad, **Option A**
(building a custom a-Shell with `disable-library-validation`) is the most practical
path. It gives you a fully functional terminal with native Python extension support,
signed with your own VLABS identity.

---

## Why Previous Attempts Failed

| Signing method | Signature type | iOS verdict | Reason |
|---------------|---------------|-------------|--------|
| None | Unsigned | "completely unsigned" | No LC_CODE_SIGNATURE at all |
| `codesign -s -` | Adhoc (flags=0x2) | "code signature invalid" | Adhoc doesn't chain to Apple root |
| `ldid -S` | Pseudo (flags=0x0) | "code signature invalid" | No Apple-trusted certificate chain |
| Apple Dev cert | Valid CA-chained | ✅ passes signature check | Chains to Apple root CA |
| Apple Dev cert (different team) | Valid but wrong team | ❌ "library validation" | Missing disable-library-validation |

The first three all fail at step 1 (signature validation). Even if we fix step 1 with
a real developer cert, step 2 (library validation) blocks loading unless the app has
the `disable-library-validation` entitlement.

---

## Quick-Start: Sign with VLABS Identity

Once you have your signing identity installed on the build Mac:

```sh
# 1. Find your identity
SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "VLABS" | head -1 | sed 's/.*"\(.*\)"/\1/')
echo "Using identity: $SIGN_IDENTITY"

# 2. Extract, strip, sign, repackage
WHL="/path/to/pynacl-1.6.2-cp313-cp313-ios_14_arm64_iphoneos.whl"
TMPDIR=$(mktemp -d)
python3 -m zipfile -e "$WHL" "$TMPDIR/root"
cd "$TMPDIR/root"

codesign --remove-signature nacl/_sodium.cpython-313-iphoneos.so
codesign -s "$SIGN_IDENTITY" --force --timestamp=none nacl/_sodium.cpython-313-iphoneos.so
codesign -v nacl/_sodium.cpython-313-iphoneos.so

# 3. Update RECORD and repackage (use the build script's repackaging logic)
# ... then install on device
```

This wheel will only load in an app signed by the **same team** (VLABS) or in an app
with `disable-library-validation` entitlement.
