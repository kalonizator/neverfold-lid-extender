# NeverFold Lid Extender

A standalone system-level helper for the **NeverFold** macOS app that prevents your Mac from sleeping when the laptop lid is closed.

## ⚡️ Quick Start Installation

To use the "Lid-close prevention" feature in the NeverFold app, you must install this helper daemon:

1. **[Download the latest Installer (.pkg)](https://github.com/kalonizator/neverfold-lid-extender/releases/latest/download/neverfold-lid-extender.pkg)**
2. Open the downloaded `.pkg` file.
3. If macOS warns you that the developer is unverified, open **System Settings > Privacy & Security** and click **Open Anyway**.
4. Follow the standard installation steps (requires an administrator password).
5. Once installation finishes, **return to the NeverFold app**. It will automatically detect the extender and connect!

---

## How It Works

The NeverFold app runs in the App Store sandbox and cannot directly manage system-level sleep settings. This extender bridges that gap:

1. **One-time setup**: The extender installs itself as a system LaunchDaemon (requires admin password).
2. **Communication**: The app sends enable/disable commands to the running daemon via a Unix domain socket or local TCP port.
3. **Sleep prevention**: The daemon holds an `IOPMAssertion` and runs `pmset -a disablesleep` to keep the Mac awake with the lid closed.

## Manual Terminal Installation (Optional)

```bash
# Download the latest release binary
curl -LO https://github.com/kalonizator/neverfold-lid-extender/releases/latest/download/neverfold-lid-extender

# Make executable
chmod +x neverfold-lid-extender

# Install (will prompt for admin password)
./neverfold-lid-extender install
```

## Usage

```bash
# Enable lid-close sleep prevention
neverfold-lid-extender enable

# Disable lid-close sleep prevention
neverfold-lid-extender disable

# Check status
neverfold-lid-extender status

# Uninstall
neverfold-lid-extender uninstall
```

## Building from Source

Requires Swift 5.9+ and macOS 13+.

```bash
swift build -c release
```

The built binary will be at `.build/release/neverfold-lid-extender`.

### Universal Binary (Intel + Apple Silicon)

```bash
swift build -c release --arch arm64 --arch x86_64
```

## Architecture

```
┌─────────────────────┐     TCP / Socket IPC    ┌──────────────────────┐
│   NeverFold App     │ ◄──────────────────────► │  Lid Extender Daemon │
│   (App Store)       │    enable/disable/status  │  (LaunchDaemon)      │
│   Sandboxed         │                           │  Root privileges     │
└─────────────────────┘                           └──────────────────────┘
                                                          │
                                                          ▼
                                                  ┌──────────────┐
                                                  │  IOPMAssertion │
                                                  │  pmset         │
                                                  └──────────────┘
```

## File Locations

| File | Path |
|------|------|
| Extender binary | `~/Library/Application Support/NeverFold/neverfold-lid-extender` |
| TCP Port | `127.0.0.1:52734` |
| LaunchDaemon plist | `/Library/LaunchDaemons/kz.kzai.neverfold.extender.plist` |
| Log file | `/tmp/neverfold-extender.log` |

## License

MIT License — see [LICENSE](LICENSE) for details.
