#!/bin/bash
set -e

# Build the binary
echo "Building neverfold-lid-extender (release mode)..."
swift build -c release

# Prepare a root directory for the pkg
echo "Preparing package payload..."
PKG_ROOT="/tmp/neverfold-lid-extender-pkg-root"
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT/usr/local/bin"

# Copy the built binary into the payload
cp ".build/release/neverfold-lid-extender" "$PKG_ROOT/usr/local/bin/neverfold-lid-extender"

# Create a postinstall script that runs the built-in 'install' command
SCRIPTS_DIR="/tmp/neverfold-lid-extender-scripts"
rm -rf "$SCRIPTS_DIR"
mkdir -p "$SCRIPTS_DIR"

cat << 'SCRIPT_EOF' > "$SCRIPTS_DIR/postinstall"
#!/bin/bash
/usr/local/bin/neverfold-lid-extender install
exit 0
SCRIPT_EOF

chmod +x "$SCRIPTS_DIR/postinstall"

# Build the .pkg
PKG_OUTPUT="neverfold-lid-extender.pkg"
echo "Building the $PKG_OUTPUT installer..."
pkgbuild --root "$PKG_ROOT" \
         --identifier "kz.kzai.neverfold.extender" \
         --version "1.0.0" \
         --scripts "$SCRIPTS_DIR" \
         --install-location "/" \
         "$PKG_OUTPUT"

echo "✅ Done! $PKG_OUTPUT has been created in this folder."
echo "You can now upload $PKG_OUTPUT to your GitHub Releases."
