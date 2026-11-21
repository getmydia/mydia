# Source file sets for the CI derivations.
#
# Every CI derivation takes its `src` from one of these (through `toSource`),
# never from `../..`, so a change outside a derivation's inputs does not
# invalidate it. The `ci-fileset-coverage` check fails when a tracked file
# under a code directory belongs to none of them.
{ lib, root }:

let
  fs = lib.fileset;
  at = path: root + "/${path}";
  # Tolerates paths absent from a dirty checkout (build output, empty dirs).
  maybe = path: fs.maybeMissing (at path);

  # clippy.toml is read by clippy for every crate (it walks up from the
  # manifest), so a crate's set needs it for the lint run to match.
  toolchainFiles = fs.unions [
    (at "rust-toolchain.toml")
    (at "rust-lints.toml")
    (at "clippy.toml")
  ];

  elixirApp = fs.difference
    (fs.unions [
      (at "mix.exs")
      (at "mix.lock")
      (at ".formatter.exs")
      (at ".credo.exs")
      (at "config")
      (at "lib")
      (at "priv")
    ])
    (fs.unions [
      (maybe "priv/native")
      (maybe "priv/static/assets")
      (fs.fileFilter (file: file.hasExt "wasm") (at "priv/plugins"))
    ]);

  # What `MIX_ENV=test mix deps.compile` reads: the project and the config
  # it loads in the test env (deps compile against the app's compile-time
  # config). A subset of elixirApp, kept narrow so app edits do not rebuild
  # the dependencies.
  mixProject = fs.unions [
    (at "mix.exs")
    (at "mix.lock")
    (at "config/config.exs")
    (at "config/test.exs")
  ];

  elixirTest = at "test";

  gettext = at "priv/gettext";

  patches = at "patches";

  # Crate directories each crate path-depends on (its Cargo.toml `path =`
  # entries), so a crate's set holds everything cargo resolves.
  cratePathDeps = {
    "native/mydia_p2p" = [ "native/mydia_p2p_core" ];
    "native/mydia_plugin_sdk" = [ "native/mydia_plugin_macros" ];
    "player/rust/mydia_player_p2p" = [
      "native/mydia_media_names"
      "native/mydia_p2p_core"
      "player/rust/mydia_smb"
    ];
  };

  crateAt = dir: fs.unions ([
    (at dir)
    toolchainFiles
  ] ++ map at (cratePathDeps.${dir} or [ ]));

  # A NIF or guest crate directory under native/, with its path deps.
  nativeCrate = name: crateAt "native/${name}";

  # A player crate under player/rust/ (outside the coverage check's code
  # directories, but linted and tested by the Rust checks).
  playerCrate = name: crateAt "player/rust/${name}";

  # Plugin guests path-depend on the plugin SDK and its proc-macro crate.
  plugins = fs.unions [
    (at "plugins")
    (at "native/mydia_plugin_sdk")
    (at "native/mydia_plugin_macros")
    toolchainFiles
  ];

  # The out-of-tree plugins scripts/check-plugins.sh and scripts/test-plugins.sh
  # also cover. Not bundled, so not part of `plugins`.
  pluginsExtra = at "plugins-extra";

  # The server workspace path-depends on native/mydia_media_names, and its
  # contract tests read the player's GraphQL documents (schema.graphql there
  # is a symlink to priv/graphql/schema.graphql).
  server = fs.unions [
    (at "server")
    (at "native/mydia_media_names")
    (at "player/lib/graphql")
    (at "priv/graphql/schema.graphql")
    toolchainFiles
  ];

  relay = fs.difference (at "metadata-relay") (fs.unions [
    (maybe "metadata-relay/_build")
    (maybe "metadata-relay/deps")
  ]);

  # metadata-relay's `MIX_ENV=test mix deps.compile` inputs (nix/ci/relay.nix),
  # and what its test check reads: subsets of `relay`, leaving out
  # priv/native (an unused tracked NIF from the libp2p era) and the
  # packaging files.
  relayProject = fs.unions [
    (at "metadata-relay/mix.exs")
    (at "metadata-relay/mix.lock")
    (at "metadata-relay/config/config.exs")
    (at "metadata-relay/config/test.exs")
  ];

  relayTest = fs.unions [
    relayProject
    (at "metadata-relay/.formatter.exs")
    (at "metadata-relay/config")
    (at "metadata-relay/lib")
    (at "metadata-relay/priv/repo")
    (at "metadata-relay/test")
  ];

  # The Flutter player's platform directories, which the Linux and web
  # checks never read. Android has its own set (its build is a separate
  # check); the rest are built outside Nix (ci-player.yml's Windows and
  # macOS legs, the packaging workflows) and are listed only so coverage
  # holds.
  playerAndroid = at "player/android";

  playerOtherPlatforms = fs.unions (map (d: at "player/${d}") [
    "windows"
    "macos"
    "ios"
    "flatpak"
    "appimage"
    "windows-vm-scripts"
  ]);

  # The player as the Linux and web checks see it: pub inputs (pubspec.*,
  # the JSON form of the lock, the rust_builder and packages/ path deps),
  # the Dart sources and their codegen config, linux/ and web/. Leaves out
  # build output, the Rust crates under player/rust (playerCrate), the
  # other platforms, and generated Dart, which is gitignored and produced
  # by ciInternal.player-codegen.
  playerApp = fs.difference (at "player") (fs.unions [
    (maybe "player/build")
    (maybe "player/.dart_tool")
    (at "player/rust")
    playerAndroid
    playerOtherPlatforms
    (fs.fileFilter
      (file: lib.hasSuffix ".g.dart" file.name || lib.hasSuffix ".freezed.dart" file.name)
      (at "player"))
  ]);

  # What ciInternal.player-codegen unpacks: playerApp plus the GraphQL
  # schema that player/lib/graphql/schema.graphql symlinks to, which
  # graphql_codegen reads through the symlink.
  playerCodegen = fs.unions [
    playerApp
    (at "priv/graphql/schema.graphql")
  ];

  # Every crate directory under player/rust/, for the coverage union.
  playerCrateNames = builtins.attrNames
    (lib.filterAttrs (_: type: type == "directory") (builtins.readDir (at "player/rust")));

  toSource = set: fs.toSource { inherit root; fileset = set; };

  # Every crate directory under native/, for the coverage union.
  nativeCrateNames = builtins.attrNames
    (lib.filterAttrs (_: type: type == "directory") (builtins.readDir (at "native")));
in
{
  inherit elixirApp mixProject elixirTest gettext patches nativeCrate playerCrate plugins
    pluginsExtra server relay relayProject relayTest playerApp playerAndroid
    playerOtherPlatforms playerCodegen toSource nativeCrateNames playerCrateNames;

  # Union of everything above, for the coverage check.
  all = fs.unions ([
    elixirApp
    elixirTest
    gettext
    patches
    plugins
    server
    relay
    playerApp
    playerAndroid
    playerOtherPlatforms
  ] ++ map nativeCrate nativeCrateNames
  ++ map playerCrate playerCrateNames);
}
