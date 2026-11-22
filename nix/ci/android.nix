# Build / Android's two cache entries. The APK build itself stays outside
# the sandbox (.github/ci.md, "Build / Android runs when its inputs
# change"); these let ci.yml skip it when nothing it reads changed, and
# fetch most of its toolchain instead of assembling it.
#
#   ciAndroid.shell   devShells.android's inputDerivation: every store path
#                     `nix develop .#android` needs. The job realises it, then
#                     pushes its direct inputs except the Android SDK
#                     composition, which is unfree and must not reach the
#                     public cache (scripts/ci-android-shell-push.sh).
#   ciAndroid.stamp   a marker naming the shell and the files the APK build
#                     reads, with no store references. Build / Android pushes it after the APK builds
#                     and passes its ABI check; ci-plan.sh reports `android`
#                     true while the cache lacks it, so a run whose Android
#                     inputs already built once skips the job.
#
# Neither is a check or a ciInternal entry: the checks matrix would build
# the stamp without the APK, and scripts/nix-cache-push.sh pushes every
# ciInternal output, which would both fake the stamp and upload the SDK.
{ ... }:

{
  perSystem = { pkgs, lib, config, ci, ... }:
    let
      fs = lib.fileset;
      root = ../..;
      at = path: root + "/${path}";

      shell = config.devShells.android.inputDerivation;

      # What the job reads besides the toolchain: the Flutter app (Dart,
      # pub inputs, rust_builder, packages/), player/android, the p2p crate
      # cargokit cross-compiles with its path deps, the GraphQL schema
      # build_runner reads through player/lib/graphql's symlink, the ABI
      # check, and the workflow that defines the steps. Markdown is left out
      # (player/docs, READMEs): no pubspec asset or build step reads it.
      inputs = fs.difference
        (fs.unions [
          ci.sources.playerApp
          ci.sources.playerAndroid
          (ci.sources.playerCrate "mydia_player_p2p")
          (at "priv/graphql/schema.graphql")
          (at "scripts/check-apk-abis.sh")
          (at ".github/workflows/ci.yml")
        ])
        (fs.fileFilter (file: file.hasExt "md") root);

      # Identity only. The source path and the shell's .drv are written as
      # plain strings, so the stamp neither builds them nor references them:
      # pushing or pinning it uploads one small file, never the shell's
      # closure with the unfree SDK. Either string changing changes the
      # stamp's derivation, which is the point. runCommand rather than
      # writeText, which sets allowSubstitutes = false.
      stamp = pkgs.runCommand "android-apk-stamp"
        {
          src = builtins.unsafeDiscardStringContext "${ci.sources.toSource inputs}";
          shell = builtins.unsafeDiscardStringContext shell.drvPath;
        }
        ''
          printf 'src %s\nshell %s\n' "$src" "$shell" > $out
        '';
    in
    {
      ciAndroid = { inherit shell stamp; };
    };
}
