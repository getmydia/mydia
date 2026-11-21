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

  toSource = set: fs.toSource { inherit root; fileset = set; };

  # Every crate directory under native/, for the coverage union.
  nativeCrateNames = builtins.attrNames
    (lib.filterAttrs (_: type: type == "directory") (builtins.readDir (at "native")));
in
{
  inherit elixirApp mixProject elixirTest gettext patches nativeCrate playerCrate plugins
    pluginsExtra server relay toSource nativeCrateNames;

  # Union of everything above, for the coverage check.
  all = fs.unions ([
    elixirApp
    elixirTest
    gettext
    patches
    plugins
    server
    relay
  ] ++ map nativeCrate nativeCrateNames);
}
