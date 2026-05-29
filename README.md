# omnara-nix

[Omnara](https://omnara.com) (control and remote-drive AI agent sessions)
packaged as a Nix flake, **instead of** the upstream
`curl -fsSL https://omnara.com/install.sh | bash` installer.

The flake wraps Omnara's official **standalone binary** from
`releases.omnara.com/latest` (currently **0.25.13**) — the same artifact the
upstream installer downloads. It's a self-contained, code-signed binary, so Nix
supplies no language runtime or library dependencies; it only wires the runtime
helper tools onto `PATH` and provides a managed-service integration.

> ### ⚠️ Reproducibility caveat
> Upstream serves the binary **only** from a mutating `/latest` URL — there are
> no version-stamped download URLs. This flake therefore pins each platform
> artifact **by content hash**. Consequences:
> - When Omnara ships a new build, the pinned hash stops matching and the build
>   fails until you re-pin (run `scripts/update-omnara.sh`).
> - The exact artifact for an old hash is **not archived** upstream, so a
>   from-scratch rebuild of an old pin will 404 once `/latest` has moved (builds
>   still succeed from the Nix cache / an existing store path).
>
> If you need strict, archivable version pinning, the last versioned, immutable
> distribution upstream published was the Python wheels at GitHub tag `v1.7.0`
> (a different, older CLI without the `daemon` command). This flake deliberately
> tracks the latest standalone binary instead.

## What you get

- `packages.default` / `packages.omnara` — the `omnara` CLI.
- `apps.default` — `nix run .` launches `omnara`.
- `devShells.default` — a shell with `omnara` on `PATH`.
- `overlays.default` — adds `pkgs.omnara` for consumption from other flakes.
- `homeManagerModules.default` — a user service that runs the Omnara daemon
  (see below).

Runtime tools wired onto omnara's `PATH` by the package wrapper:

- **git** — omnara tracks work per git repository/branch.
- **cloudflared** — exposes the daemon / sessions over a Cloudflare tunnel
  (this is what the upstream installer optionally `brew install`s).
- the **Claude Code** / **Codex** agents expect `claude` / `codex` to already be
  on your `PATH`.

The wrapper also sets `OMNARA_NO_UPDATE=1` by default, since the binary lives in
the read-only Nix store and cannot self-update — use Nix to update instead.
Override by exporting `OMNARA_NO_UPDATE` yourself.

Supported systems: `aarch64-darwin`, `x86_64-darwin`, `x86_64-linux`,
`aarch64-linux` (an upstream artifact exists for each).

## Usage

```bash
nix build .#omnara
./result/bin/omnara --version        # 0.25.13

# or directly
nix run github:rksm/omnara-nix -- --version
```

Authenticate, then start an agent session in a git repo:

```bash
omnara auth
omnara                 # start a session (Claude Code by default)
omnara --codex         # use the Codex agent
```

## Running the daemon

The Omnara daemon is what enables remote control / background session tracking.

```bash
omnara daemon start    # start it in the background
omnara daemon status   # show status and tracked directories
omnara daemon stop     # stop it
```

`daemon start` launches and supervises its own background process. For a
**Nix-managed** auto-starting service, use the Home Manager module below, which
runs the foreground entry point `omnara daemon run-service` under launchd /
systemd (the same command the upstream installer's service uses).

### Recommended: Home Manager module

The flake exports `homeManagerModules.default`, which defines a user service
that runs `omnara daemon run-service` and auto-starts on login (a **launchd**
agent on macOS, a **systemd** user service on Linux).

```nix
# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    home-manager.url = "github:nix-community/home-manager";
    omnara.url = "github:rksm/omnara-nix";
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
    # command = [ "daemon" "run-service" ];  # this is the default
    # path = [ pkgs.nodejs ];                 # extra tools for agents (e.g. `claude`)
    # environment = { OMNARA_BASE_URL = "https://..."; };  # NO secrets here
  };
}
```

Authenticate once (`omnara auth`, stored under `~/.omnara`) before the daemon
needs credentials — don't put API keys in `environment`, since the Nix store is
world-readable. `git` and `cloudflared` are already on the service's PATH, and
`OMNARA_NO_UPDATE=1` is set for you.

Manage it after `home-manager switch`:

```bash
# macOS
launchctl list | grep omnara
launchctl kickstart -k gui/$(id -u)/org.nix-community.home.omnara
# Linux
systemctl --user status omnara
journalctl --user -u omnara -f
```

A full standalone example is in
[`examples/home-manager-flake.nix`](examples/home-manager-flake.nix).

### Alternative: a launchd agent by hand (macOS, no Home Manager)

If you don't use Home Manager, drop a LaunchAgent in place yourself. Use a
profile path (`nix profile install .#omnara` → `~/.nix-profile/bin/omnara`) so
the path stays stable across rebuilds:

```bash
OMNARA_BIN="$HOME/.nix-profile/bin/omnara"   # or: $(nix build --no-link --print-out-paths .#omnara)/bin/omnara

mkdir -p "$HOME/.omnara/logs"
cat > "$HOME/Library/LaunchAgents/com.omnara.daemon.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>            <string>com.omnara.daemon</string>
    <key>ProgramArguments</key>
    <array>
        <string>${OMNARA_BIN}</string>
        <string>daemon</string>
        <string>run-service</string>
    </array>
    <key>RunAtLoad</key>        <true/>
    <key>KeepAlive</key>        <true/>
    <key>StandardOutPath</key>  <string>${HOME}/.omnara/logs/daemon.log</string>
    <key>StandardErrorPath</key><string>${HOME}/.omnara/logs/daemon.log</string>
    <key>WorkingDirectory</key> <string>${HOME}</string>
</dict>
</plist>
EOF

launchctl load "$HOME/Library/LaunchAgents/com.omnara.daemon.plist"
# stop / remove:
# launchctl unload "$HOME/Library/LaunchAgents/com.omnara.daemon.plist"
```

On Linux, write an analogous `~/.config/systemd/user/omnara.service` with
`ExecStart=<omnara>/bin/omnara daemon run-service` and
`systemctl --user enable --now omnara`.

## Consuming from another flake

See [`examples/consumer-flake.nix`](examples/consumer-flake.nix):

```nix
{
  inputs.omnara.url = "github:rksm/omnara-nix";
  # ...
  # add omnara.overlays.default to your nixpkgs overlays,
  # then use pkgs.omnara
}
```

## Updating

`scripts/update-omnara.sh` recomputes the content hash of each platform artifact
from `releases.omnara.com/latest`; if anything changed it discovers the new
version (by running the Linux binary) and rewrites `default.nix`. A daily GitHub
Actions workflow (`.github/workflows/update-omnara.yml`) runs it and commits any
change. Because it tracks `/latest`, an update reflects whatever upstream
currently publishes.
