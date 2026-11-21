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

  toolchainFiles = fs.unions [
    (at "rust-toolchain.toml")
    (at "rust-lints.toml")
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

  elixirTest = at "test";

  gettext = at "priv/gettext";

  patches = at "patches";

  # A NIF or guest crate directory under native/. The p2p NIF also needs the
  # shared core crate it path-depends on.
  nativeCrate = name: fs.unions ([
    (at "native/${name}")
    toolchainFiles
  ] ++ lib.optionals (name == "mydia_p2p") [ (at "native/mydia_p2p_core") ]);

  # Plugin guests path-depend on the plugin SDK and its proc-macro crate.
  plugins = fs.unions [
    (at "plugins")
    (at "native/mydia_plugin_sdk")
    (at "native/mydia_plugin_macros")
    toolchainFiles
  ];

  # The server workspace path-depends on native/mydia_media_names.
  server = fs.unions [
    (at "server")
    (at "native/mydia_media_names")
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
  inherit elixirApp elixirTest gettext patches nativeCrate plugins server relay
    toSource nativeCrateNames;

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
