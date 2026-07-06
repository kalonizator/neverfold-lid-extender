# NeverFold Lid Extender

A standalone system-level helper for the **NeverFold** macOS app that prevents your Mac from sleeping when the laptop lid is closed.

## How It Works

The NeverFold app runs in the App Store sandbox and cannot directly manage system-level sleep settings. This extender bridges that gap:

1. **NeverFold app** downloads this extender from GitHub Releases
2. **One-time setup**: The extender installs itself as a system LaunchDaemon (requires admin password)
3. **Communication**: The app sends enable/disable commands to the running daemon via a Unix domain socket
4. **Sleep prevention**: The daemon holds an `IOPMAssertion` and runs `pmset -a disablesleep` to keep the Mac awake with the lid closed

## Manual Installation

```bash
# Download the latest release
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
┌─────────────────────┐     Unix Socket IPC     ┌──────────────────────┐
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
| Unix socket | `~/Library/Application Support/NeverFold/extender.sock` |
| LaunchDaemon plist | `/Library/LaunchDaemons/kz.kzai.neverfold.extender.plist` |
| Log file | `/tmp/neverfold-extender.log` |

## License

MIT License — see [LICENSE](LICENSE) for details.
