# omnara-nix

[Omnara](https://github.com/omnara-ai/omnara) (control and remote-drive AI agent
sessions) packaged as a Nix flake, **instead of** the upstream
`curl -fsSL https://omnara.com/install.sh | bash` installer.

The flake builds the package from the **versioned, immutable GitHub release
wheel** (currently `v1.7.0`) rather than the `releases.omnara.com/latest`
standalone binary, so the build is reproducible and pinned. All runtime
dependencies are supplied by Nix.

## What you get

- `packages.default` / `packages.omnara` — the `omnara` CLI.
- `apps.default` — `nix run .` launches `omnara`.
- `devShells.default` — a shell with `omnara` on `PATH`.
- `overlays.default` — adds `pkgs.omnara` for consumption from other flakes.

Runtime tools are wired in automatically:

- **git** — omnara operates inside git repositories.
- **cloudflared** — used to expose local sessions over a Cloudflare tunnel
  (this is what the upstream installer optionally `brew install`s).
- the **Codex** agent uses a `codex` helper bundled inside the wheel.
- the **Claude Code** agent expects `claude` to already be on your `PATH`.

Supported systems (an upstream wheel exists for each):
`aarch64-darwin`, `x86_64-darwin`, `x86_64-linux`.
There is no upstream wheel for `aarch64-linux` or musl, so those are unsupported.

## Usage

Build and run:

```bash
nix build .#omnara
./result/bin/omnara --version

# or directly
nix run github:<you>/omnara-nix -- --version
```

Authenticate, then start an agent session in a git repo:

```bash
omnara --auth
omnara                 # default: Claude Code agent
omnara --agent codex   # uses the bundled codex helper
```

## Running the long-running server ("daemon")

> **Version note.** The current `install.sh` sets up a background service via
> `omnara daemon run-service`. That daemon architecture is **newer** than the
> last versioned release wheel (`v1.7.0`) and only ships in the
> `releases.omnara.com/latest` standalone binary. In `v1.7.0` the equivalent
> long-running process is **`omnara serve`** — a webhook server that, by
> default, exposes itself through a Cloudflare tunnel.

Start it manually in the foreground:

```bash
omnara serve                 # webhook server on :6662, via Cloudflare tunnel
omnara serve --no-tunnel     # local only, no tunnel
omnara serve --port 6662     # choose the port
```

### Recommended: Home Manager module

The flake exports `homeManagerModules.default`, which defines a user service
that runs `omnara serve` and auto-starts on login (a **launchd** agent on
macOS, a **systemd** user service on Linux).

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager.url = "github:nix-community/home-manager";
    omnara.url = "github:<you>/omnara-nix";
  };
  # ...
}
```

```nix
# your home configuration
{ inputs, pkgs, ... }:
{
  imports = [ inputs.omnara.homeManagerModules.default ];

  services.omnara = {
    enable = true;
    # command = [ "serve" "--no-tunnel" "--port" "6662" ];  # default: [ "serve" ]
    # path = [ pkgs.nodejs ];   # extra tools for agents (e.g. the `claude` CLI)
    # environment = { OMNARA_BASE_URL = "https://..."; };  # NO secrets here
  };
}
```

Authenticate once (`omnara --auth`, stored under `~/.omnara`) before the service
needs credentials — don't put API keys in `environment`, since the Nix store is
world-readable. `git` and `cloudflared` are already on the service's PATH via the
package wrapper.

Manage it after `home-manager switch`:

```bash
# macOS
launchctl list | grep omnara
launchctl kickstart -k gui/$(id -u)/org.nix-community.home.omnara
# Linux
systemctl --user status omnara
journalctl --user -u omnara -f
```

### Alternative: a launchd agent by hand (macOS, no Home Manager)

If you don't use Home Manager, drop a LaunchAgent in place yourself. Adjust the
binary path to the built store path (or a profile/`nix profile install` path
that stays stable):

```bash
OMNARA_BIN="$(nix build --no-link --print-out-paths .#omnara)/bin/omnara"

cat > "$HOME/Library/LaunchAgents/com.omnara.serve.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>            <string>com.omnara.serve</string>
    <key>ProgramArguments</key>
    <array>
        <string>${OMNARA_BIN}</string>
        <string>serve</string>
    </array>
    <key>RunAtLoad</key>        <true/>
    <key>KeepAlive</key>        <true/>
    <key>StandardOutPath</key>  <string>${HOME}/.omnara/logs/serve.log</string>
    <key>StandardErrorPath</key><string>${HOME}/.omnara/logs/serve.log</string>
    <key>WorkingDirectory</key> <string>${HOME}</string>
</dict>
</plist>
EOF

mkdir -p "$HOME/.omnara/logs"
launchctl load "$HOME/Library/LaunchAgents/com.omnara.serve.plist"
# stop / remove:
# launchctl unload "$HOME/Library/LaunchAgents/com.omnara.serve.plist"
```

On Linux, write an analogous `~/.config/systemd/user/omnara.service` with
`ExecStart=<store-path>/bin/omnara serve` and `systemctl --user enable --now`.

## Consuming from another flake

See [`examples/consumer-flake.nix`](examples/consumer-flake.nix):

```nix
{
  inputs.omnara.url = "github:<you>/omnara-nix";
  # ...
  # add omnara.overlays.default to your nixpkgs overlays,
  # then use pkgs.omnara
}
```

## Updating

`scripts/update-omnara.sh` bumps the pinned version and refreshes all wheel
hashes from the latest GitHub release that still publishes wheels. Note that
upstream has been moving toward `/latest`-only standalone binaries, so a newer
release may not ship wheels at all — in that case the script fails loudly rather
than producing a broken pin.
