# Development Setup

Set up a local development environment for Mydia.

The local developer environment is built on [devenv.sh](https://devenv.sh) (a
Nix-based, declarative dev environment) and auto-loaded per git worktree via
[direnv](https://direnv.net). The daily loop (Phoenix server, `mix test`,
`mix precommit`, Flutter codegen) runs **natively** (no Docker dev container).
Each worktree derives its own non-colliding ports and isolated state, so several
worktrees can run their full stacks at once.

> Docker is still used for the production image (`Dockerfile`), the player E2E
> stack (`compose.player-e2e.yml`), and the metadata-relay deploy, but **not**
> for day-to-day development.

## Prerequisites

- **Nix**: https://nixos.org/download (the Determinate Systems installer works well)
- **devenv**: `nix profile install nixpkgs#devenv`
- **direnv**: https://direnv.net (install + hook into your shell)
- **Git**

Your user must be a Nix **trusted user** (devenv requires it). If `devenv shell`
fails with `ignoring the client-specified setting 'system' … you are not a
trusted user`, add yourself:

```bash
echo "extra-trusted-users = $USER" | sudo tee -a /etc/nix/nix.custom.conf
sudo systemctl restart nix-daemon   # or: sudo launchctl kickstart -k system/org.nixos.nix-daemon (macOS)
```

## Quick Start

```bash
git clone https://github.com/getmydia/mydia.git
cd mydia

# Authorize direnv for this worktree (one time). This builds the toolchain and
# runs first-run setup (deps.get, asset npm install, flutter pub get). The first
# build downloads the toolchain and can take a while.
#
# Shell entry deliberately does NOT touch the development database: it must not
# boot the app or start a service. `./dev up` sets the database up before
# starting Phoenix, and `./dev db.setup` does it on demand.
direnv allow

# Start the stack (Phoenix + Flutter codegen watcher)
./dev up
```

On shell entry devenv prints this worktree's assigned URL and ports, e.g.:

```
Mydia dev environment (devenv): /home/you/mydia
  Phoenix:   http://localhost:4740
  P2P bind:  4741
  Flutter:   dev-server port 4743
```

Open the printed Phoenix URL (the port is derived from the worktree path, so it
is stable across restarts but differs between worktrees).

If you don't use direnv, run commands through `devenv shell` directly, or just
use the `./dev` wrapper (it loads the environment for each command).

## Per-worktree ports & overrides

Ports are derived deterministically by hashing the worktree's absolute path, so
two worktrees never collide and you can run both stacks simultaneously. Ports
change only if the checkout physically moves (a branch rename does not change
them).

To pin ports explicitly (escape hatch for a hash collision or a fixed port),
copy the example override (git-ignored) and edit it:

```bash
cp devenv.local.nix.example devenv.local.nix
```

## PostgreSQL (optional)

SQLite is the default adapter and needs no service. To develop against
PostgreSQL, set `DATABASE_TYPE=postgres` before entering the shell; devenv then
runs a per-worktree Postgres (data under `.devenv/state/postgres`) on a derived
port and creates `mydia_dev` / `mydia_test`.

> `initialDatabases` only runs on first init. To change it later, delete
> `.devenv/state/postgres` and re-enter the shell.

`DATABASE_TYPE` is read when devenv evaluates, so export it *before* entering
the shell. Postgres builds into `_build/postgres` rather than `_build`, because
the Ecto adapter is a compile-time setting and sharing one build root between
adapters makes Phoenix restart-loop on a compile-env mismatch. Switching back
and forth costs no recompile.

## The `./dev` Script

`./dev` is a thin wrapper over devenv that preserves the historical command
vocabulary. Run `./dev` with no arguments to see everything.

### Process lifecycle

```bash
./dev up -d        # Start the stack in the background
./dev down         # Stop background processes
./dev restart      # Restart the stack
./dev logs phoenix # Show a process's logs
./dev ps           # List managed processes
```

### Shells & mix

```bash
./dev shell        # Interactive devenv shell
./dev iex          # IEx console (iex -S mix)
./dev mix <args>   # Any mix command
./dev mix test     # Run tests
./dev mix format   # Format code
```

### Shortcuts

```bash
./dev test         # Run tests
./dev format       # Format code
./dev deps.get     # Fetch dependencies
./dev db.setup     # Create and migrate the development database
./dev ecto.migrate # Run migrations
```

`./dev up`, `./dev iex`, and `./dev phx.server` run `db.setup` for you. `./dev
test` and `./dev mix` do not need it: the `test` alias builds and migrates its
own database, and formatting, Credo, and compilation never open one.

## Code Quality

### Pre-commit checks

```bash
./dev mix precommit
```

Runs Dependencies → Compile (warnings-as-errors) → Unused deps → Format →
Database → Tests, with a compact per-step summary.

> Precommit runs against the active adapter. SQLite (the default) serializes
> async tests; `DATABASE_TYPE=postgres ./dev mix precommit` uses the warm
> Postgres and keeps async tests parallel.

### Git hooks

Pre-commit hooks are managed by devenv (`git-hooks.hooks` in `devenv.nix`) and
installed automatically when you enter the shell. They lint Rust (cargo
fmt/clippy against the pinned 1.96.0 toolchain), the WASM plugin guests, and
Elixir/Dart formatting. No `nix develop` needed. devenv owns the generated
`.pre-commit-config.yaml` (git-ignored); edit `devenv.nix` to change hooks.

## Player (Flutter)

```bash
./dev flutter <args>   # Run a flutter command in player/
./dev player setup     # Install deps + run code generation
./dev player build     # Build + deploy web assets to priv/static/player
./dev player icons     # Regenerate web icons from assets/*.svg (--check verifies)
./dev player logs      # Show recent build_runner (codegen) process logs
```

Access the player at the Phoenix URL under `/player` (e.g.
`http://localhost:4740/player`). `MydiaWeb.FlutterWatcher` rebuilds the web app
on source changes; the `flutter-codegen` process runs `build_runner watch` for
GraphQL/Riverpod codegen.

Android builds use the player's own Nix flake (not devenv):

```bash
./dev player android build   # Build release APK
./dev player android shell   # nix develop shell in player/
```

macOS app builds use the host toolchain (not devenv, not the flake): Xcode and
CocoaPods are Apple-licensed SDKs Nix cannot provide, and cargokit builds the
Rust p2p core via `rustup`:

```bash
./dev player macos run                  # Debug build + run, hot reload
./dev player macos build                # Release build
./dev player macos run --skip-codegen   # Reuse existing build_runner output
```

Requires **full Xcode** (the Command Line Tools alone cannot build app bundles),
CocoaPods (`pod`), Flutter, and rustup on the host; `./dev` preflights all four
and tells you how to fix whichever is missing. Release output lands in
`player/build/macos/Build/Products/Release/Mydia Player.app`.

## Project Structure

```
mydia/
├── assets/           # Frontend assets (JS, CSS)
├── config/           # Configuration files
├── devenv.nix        # Developer environment (toolchain, services, hooks)
├── lib/
│   ├── mydia/        # Business logic
│   └── mydia_web/    # Web layer (LiveViews, controllers)
├── priv/
│   ├── repo/         # Database migrations
│   └── static/       # Static assets
└── test/             # Test files
```

## Next Steps

- [Testing](testing.md) - Unit and integration testing
- [E2E Testing](e2e-testing.md) - Browser-based testing
- [Architecture](architecture.md) - System design overview
