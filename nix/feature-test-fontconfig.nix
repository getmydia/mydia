# The fonts.conf the Wallaby feature tests render with, as a store path.
# devenv.nix sets it as MYDIA_FEATURE_TEST_FONTCONFIG for `./dev
# feature-test`, and nix/ci/tests.nix for the e2e-browser check;
# scripts/run-feature-tests.sh exports it as FONTCONFIG_FILE for the test
# browser only.
#
# It offers only Liberation and DejaVu from the nix store, with Liberation
# Sans as the sans-serif (and the stand-in for Inter, Arial, Helvetica and
# system-ui) and DejaVu kept for glyph fallback and the serif and monospace
# defaults. That is what Ubuntu's CI runner resolved the app's font stack
# to, and DejaVu Sans alone is wide enough to squeeze layouts the browser
# tests hold to a floor. The mobile layout sweep measures text widths, and
# system fonts differ between dev hosts and the CI runner, so the same page
# wrapped and overflowed differently on each.
#
# Not pkgs.makeFontsConf: that also includes /etc/fonts/conf.d and the
# host's font directories (/usr/share/fonts, ~/.nix-profile, xdg), so a
# host's own fonts (Inter on a dev machine) still won. This file reads
# fontconfig's stock rules from the store, minus 50-user.conf and
# 51-local.conf, which pull in per-user and per-host configuration. The
# rules are listed rather than read from the directory, which would make
# evaluation build fontconfig first (import from derivation).
{ pkgs, lib }:

let
  confd = "${pkgs.fontconfig.out}/etc/fonts/conf.d";
  rules = [
    "10-hinting-slight.conf"
    "10-scale-bitmap-fonts.conf"
    "10-sub-pixel-none.conf"
    "10-yes-antialias.conf"
    "11-lcdfilter-default.conf"
    "20-unhint-small-vera.conf"
    "30-metric-aliases.conf"
    "40-nonlatin.conf"
    "45-generic.conf"
    "45-latin.conf"
    "48-guessfamily.conf"
    "48-spacing.conf"
    "49-sansserif.conf"
    "60-generic.conf"
    "60-latin.conf"
    "65-fonts-persian.conf"
    "65-nonlatin.conf"
    "69-unifont.conf"
    "70-no-bitmaps-except-emoji.conf"
    "80-delicious.conf"
    "90-synthetic.conf"
  ];
in
pkgs.writeText "mydia-feature-test-fonts.conf" ''
  <?xml version="1.0"?>
  <!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
  <fontconfig>
    <dir>${pkgs.liberation_ttf}/share/fonts</dir>
    <dir>${pkgs.dejavu_fonts}/share/fonts</dir>
    <cachedir prefix="xdg">mydia-feature-test-fontconfig</cachedir>
    ${lib.concatMapStrings (f: "<include ignore_missing=\"yes\">${confd}/${f}</include>\n") rules}
    <!-- After the stock rules, which put DejaVu Sans first for
         sans-serif and add sans-serif to any family they do not
         know: every sans request resolves to Liberation Sans. -->
    <match target="pattern">
      <test name="family"><string>sans-serif</string></test>
      <edit name="family" mode="prepend_first" binding="strong">
        <string>Liberation Sans</string>
      </edit>
    </match>
    <match target="pattern">
      <test name="family"><string>system-ui</string></test>
      <edit name="family" mode="prepend_first" binding="strong">
        <string>Liberation Sans</string>
      </edit>
    </match>
  </fontconfig>
''
