# Lumen

Lumen is a lightweight server that enables the Prism app to run CLI commands on any macOS or Linux host.

## Install

You can install Lumen by either cloning the repo or using [Mint](https://github.com/yonaskolb/Mint), a convenient way to install Swift packages without needing to clone repos directly. Lumen will detect and reuse any existing install configurations.

To install directly:

```sh
git clone https://github.com/dannystewart/lumen
cd lumen
swift run lumen install
```

Or via Mint:

```sh
mint install dannystewart/lumen
lumen install
```

Lumen will walk you through install location and port selection (default: 9069). It generates an API key for you automatically, unless you provide an existing one you may be using for other nodes.

The Lumen binary will be located in `~/.local/bin/lumen`. If `lumen` isn’t available from anywhere in your shell yet, add that directory to your `PATH`. On Linux, you can also install Lumen as a system service, which may be preferable for servers without active user sessions.

## Manage

Once installed, use:

```sh
lumen update
lumen start
lumen stop
lumen restart
lumen status
```

`lumen update` checks the repository's stable version tags, builds the latest release, and reinstalls it while preserving the existing service configuration.

To remove the installed binary and service:

```sh
lumen uninstall
```
