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
lumen connect surfer
lumen disconnect surfer
```

`lumen update` checks the repository's stable version tags, builds the latest release, and reinstalls it while preserving the existing service configuration.

To remove the installed binary and service:

```sh
lumen uninstall
```

## Surfer integration (macOS)

Run `lumen connect surfer` as your desktop user (not with sudo). It detects and opens Surfer,
asks you to approve **Connect to Lumen** in Surfer, then exchanges a short-lived code using
an S256 proof. No token copying, JSON editing, or running Prism app is needed. Install a
Surfer build that supports Lumen pairing first. Cancel in Surfer to decline; an unanswered
request expires after five minutes.

The CLI receives only the code and matching state at a temporary `127.0.0.1` callback on
an OS-assigned port. The verifier stays in the CLI process; the bearer credential is returned
only by Surfer's fixed loopback token endpoint. Lumen is source-built and may be ad-hoc
signed, so this flow relies on your explicit local approval and proof possession, not a
claim of verified same-team app identity. Approve only after initiating the terminal command.

Lumen gets a separate Surfer client named **Lumen**. Its credential is stored only on this
Mac in `~/Library/Application Support/Lumen/Surfer/credential`, inside an owner-only directory
with an owner-only file. The CLI and service must run as the same user. The service reads
the file on each request: pairing and disconnect take effect without restarting Lumen.
This avoids Keychain ACL prompts tied to an unsigned CLI executable that updates itself.

`lumen status` reports installation, running state, saved-credential presence, and live
authorization when available. A saved credential alone does not mean Surfer still permits
access. Status and discovery never launch Surfer or enable automation.

`lumen disconnect surfer` asks Surfer to persistently disconnect Lumen and cancel its sessions
before deleting the local credential. If Surfer cannot confirm revocation, the command fails
and retains the credential for a retry; simply forgetting it would not revoke access. You can
also disconnect Lumen in Surfer's Agent Activity or Advanced Settings. A remote request cannot
re-pair or resume it. Only a new local approval or Resume in Surfer can restore authorization.

### Authenticated HTTP surface

All integration routes use Lumen's existing bearer authentication:

- `GET /info`: includes `surfer` on macOS, with `installed`, `running`, `credentialStored`,
  and `authorization` (`not_paired`, `unknown`, `authorized`, `disconnected`, or `disabled`).
- `GET /integrations/surfer/status`: returns that same status without starting the app.
- `POST /integrations/surfer/connect`: starts Surfer if necessary and verifies an existing
  local authorization. Initial pairing must happen through the CLI on the Mac.
- `POST|GET|DELETE /integrations/surfer/mcp`: forwards MCP traffic to the fixed
  `http://127.0.0.1:48321/mcp` endpoint, substituting Lumen's own Surfer credential.

The relay preserves session/protocol headers, response status, JSON bodies, and image blocks.
It forwards cancellation notifications without interpreting browser tools. It rejects browser
origins, follows no redirects, exposes no pairing/token endpoint, accepts no caller-supplied
upstream URL, and does not automatically retry failed actions. Requests are capped at 8 MB and
responses at 50 MB. The current Surfer transport is JSON-only; SSE is explicitly unsupported
rather than silently buffered. Credentials and browser payloads are never logged by the bridge.

Use Lumen's existing secured remote-access path (HTTPS or your private network); Surfer stays
loopback-only. The Mac must be awake/reachable and have the user's desktop session available.
Linux nodes do not advertise Surfer or register these routes; CLI connection commands explain
that the integration is macOS-only.

Native Prism discovers this capability through authenticated node `/info` and exposes
`browser_connect(target?)` for Macs reporting Surfer installed. Prism presents one selected
browser with stable `browser_*` names for both direct and relayed connections, not separate
transport-specific namespaces. A device-local target preference survives turns; tools for an
already-running, authorized browser are restored before the first model round. Explicit
connections/switches publish tools before the next round and close the previous session. The bridge does
not add a saved MCP configuration to Prism or modify its synced server registry; it uses the
existing node connection, leaving Surfer's own credential exclusively on the Mac. Initial local
pairing is still required. Electron client integration is separate from the native implementation.
