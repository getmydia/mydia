# Test / Player E2E: the Flutter player's integration tests against a real
# server and metadata-relay, as three VMs on the test VLAN (no internet).
#
#   relay    packages.metadata-relay, with a test-only environment, on
#            port 4001.
#   server   the NixOS module (nix/module.nix) on packages.default, in E2E
#            configuration. mydia-e2e-seed, a oneshot after mydia.service,
#            runs scripts/e2e/seed.sh and then writes /run/mydia-e2e-seeded.
#   client   `flutter test -d linux integration_test/all_tests.dart` under
#            Xvfb, through scripts/e2e/run-tests.sh, on a copy of
#            player-codegen with the crane-built p2p library.
#
# iroh: the player connects to the server directly over the VLAN (the
# "Spike 2, iroh between VM nodes" section of
# design/plans/2026-11-21-nix-ci-phase-2.md). Discovery and
# the default relays stay configured but unreachable, as for a real player
# with no internet. The server binds iroh to a fixed UDP port so the
# firewall can open it; without P2P_BIND_PORT iroh picks a random port and
# the NixOS firewall drops it. With no relay reachable, the server reports
# Ready, and so mints pairing claims carrying its addresses, only after
# iroh's 30 s relay wait (RELAY_WAIT in native/mydia_p2p_core); run-tests.sh
# retries claim-code generation for 60 s, which covers it.
#
# Readiness is capped at 300 s from boot: relay /health, server /health,
# the seeded marker and scripts/e2e/assert-seeded.sh. Any failure prints the
# journals of both services (and the seed unit). On success the journals and
# the client's log are copied into $out.
{ pkgs, lib, mydiaPackage, relayPackage, ciPlayer }:

let
  # scripts/e2e as a store directory: seed.sh runs assert-seeded.sh beside it.
  e2eScripts = lib.fileset.toSource {
    root = ../../scripts/e2e;
    fileset = lib.fileset.unions [
      ../../scripts/e2e/seed.sh
      ../../scripts/e2e/assert-seeded.sh
      ../../scripts/e2e/run-tests.sh
    ];
  };

  adminEmail = "admin@test.local";
  adminPassword = "testpassword123";
  p2pPort = 4100;

  # The client builds the Linux app outside the sandbox, so it has none of
  # stdenv's setup hooks (PKG_CONFIG_PATH for gtk3 and its propagated
  # inputs, the cc-wrapper's flags, the flutter shim first on PATH). This
  # captures that environment from a derivation with player-linux's inputs,
  # minus the sandbox-specific variables, for the client to source.
  # NIX_ENFORCE_PURITY goes too: the cc-wrapper's purity check would reject
  # /build paths, which in the sandbox are NIX_BUILD_TOP.
  clientEnv = pkgs.stdenv.mkDerivation {
    name = "player-e2e-client-env";
    nativeBuildInputs = [ ciPlayer.flutterShim ciPlayer.flutter ]
      ++ ciPlayer.linuxBuildInputs
      # ffmpeg writes the clips playback_test.dart plays.
      ++ [ pkgs.curl pkgs.jq pkgs.xvfb-run pkgs.ffmpeg ];
    buildCommand = ''
      envFile=$out
      unset HOME TMPDIR TMP TEMP TEMPDIR NIX_BUILD_TOP NIX_BUILD_CORES \
        NIX_ENFORCE_PURITY NIX_LOG_FD NIX_SSL_CERT_FILE SSL_CERT_FILE \
        PWD OLDPWD SHLVL out outputs builder buildCommand name system \
        TERM TZ
      export -p > "$envFile"
    '';
  };

  # The server and relay by VLAN address, not host name: the app under test
  # resolves MYDIA_URL's host through glibc and the guest's nscd, which once
  # answered `server` with EAI_AGAIN mid-suite (.github/ci-flakes.md).
  mkClientRun = { serverIp, relayIp }: pkgs.writeShellScript "player-e2e-client" ''
    set -euo pipefail
    source ${clientEnv}
    # The VM's own tools (sh, coreutils) after the captured ones.
    export PATH="$PATH:/run/current-system/sw/bin"
    # GLib finds compiled schemas under XDG_DATA_DIRS only (the job
    # wrapGAppsHook does for an installed app); without GTK's, the app aborts
    # at startup.
    export XDG_DATA_DIRS="$GSETTINGS_SCHEMAS_PATH:$XDG_DATA_DIRS"
    export HOME=/build/home TMPDIR=/build/tmp
    mkdir -p "$HOME" "$TMPDIR"
    # The suite runs out of descriptors at the default soft limit of 1024,
    # and GLib aborts the app on EMFILE mid-suite. Likely a descriptor leak
    # across the suite's repeated app boots that the old Docker run's higher
    # default limit hid, so read this as a workaround, not a requirement.
    ulimit -n "$(ulimit -Hn)"

    ${ciPlayer.setupPlayerTree { }}
    export MYDIA_PLAYER_P2P_PREBUILT=${ciPlayer.p2pPrebuilt}

    export MYDIA_URL=http://${serverIp}:4000
    export RELAY_URL=http://${relayIp}:4001
    export E2E_ADMIN_EMAIL=${adminEmail}
    export E2E_ADMIN_PASSWORD=${adminPassword}
    export E2E_TEST_TARGET=integration_test/all_tests.dart
    exec bash ${e2eScripts}/run-tests.sh
  '';

  # clientRun's output, live on the serial console (so in the build log as
  # it happens) and in /tmp/player-e2e.log for $out. stdin is /dev/null: the
  # flutter tool switches terminal echo on the tty it is given, which is the
  # test driver's shell, and the driver then reads its own echoed commands
  # back as the exit status.
  mkClientRunLogged = ips: pkgs.writeShellScript "player-e2e-client-logged" ''
    set -o pipefail
    ${mkClientRun ips} < /dev/null 2>&1 | tee /tmp/player-e2e.log > /dev/ttyS0
  '';
in
pkgs.testers.nixosTest {
  name = "player-e2e";

  nodes.relay = { ... }: {
    systemd.services.metadata-relay = {
      description = "metadata-relay";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      environment = {
        PORT = "4001";
        SQLITE_DB_PATH = "/var/lib/relay/relay.db";
        DASHBOARD_USERNAME = "admin";
        DASHBOARD_PASSWORD = "admin";
        RENDEZVOUS_MASTER_PEPPER = "test-pepper-not-for-production";
        RELEASE_COOKIE = "metadata-relay-e2e";
        RELEASE_DISTRIBUTION = "none";
        RELEASE_TMP = "/var/lib/relay/tmp";
        HOME = "/var/lib/relay";
      };
      # As the Dockerfile's docker-entrypoint.sh: migrate, then start.
      serviceConfig = {
        Type = "exec";
        DynamicUser = true;
        StateDirectory = "relay";
        ExecStartPre = "${relayPackage}/bin/metadata_relay eval MetadataRelay.Release.migrate()";
        ExecStart = "${relayPackage}/bin/metadata_relay start";
      };
    };
    networking.firewall.allowedTCPPorts = [ 4001 ];
    virtualisation.memorySize = 1024;
  };

  nodes.server = { config, nodes, ... }:
    let
      # `bin/mydia rpc` against the running node, for seed.sh and
      # assert-seeded.sh, which call it by this name. The module's distribution is
      # switched on below so rpc can reach it.
      mydiaCli = pkgs.writeShellScriptBin "mydia-e2e-cli" ''
        export RELEASE_COOKIE=${config.systemd.services.mydia.environment.RELEASE_COOKIE}
        export RELEASE_DISTRIBUTION=sname RELEASE_NODE=mydia
        exec ${mydiaPackage}/bin/mydia "$@"
      '';
    in
    {
      imports = [ ../module.nix ];

      services.mydia = {
        enable = true;
        package = mydiaPackage;
        host = "server";
        listenAddress = "0.0.0.0";
        secretKeyBaseFile = pkgs.writeText "e2e-secret-key-base"
          "E2ETestSecretKeyBase123456789012345678901234567890123456789012345";
        guardianSecretKeyFile = pkgs.writeText "e2e-guardian-secret-key"
          "E2ETestGuardianSecretKey12345678901234567890123456789012345678";
        extraEnvironment = {
          ENABLE_REMOTE_ACCESS = "true";
          # By address, as the client's URLs (mkClientRun).
          METADATA_RELAY_URL = "http://${nodes.relay.networking.primaryIPAddress}:4001";
          PUBLIC_IP_ENABLED = "false";
          DIRECT_URLS_USE_HTTP = "true";
          EXTERNAL_PORT = "4000";
          PHX_CHECK_ORIGIN = "false";
          E2E_ADMIN_EMAIL = adminEmail;
          E2E_ADMIN_PASSWORD = adminPassword;
          P2P_BIND_PORT = toString p2pPort;
          # The module runs with distribution off; rpc needs it on.
          RELEASE_DISTRIBUTION = "sname";
          RELEASE_NODE = "mydia";
        };
      };

      systemd.services.mydia-e2e-seed = {
        description = "Seed the E2E fixtures into mydia";
        wantedBy = [ "multi-user.target" ];
        after = [ "mydia.service" ];
        requires = [ "mydia.service" ];
        path = [ mydiaCli pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.curl pkgs.ffmpeg ];
        environment = {
          E2E_ADMIN_EMAIL = adminEmail;
          E2E_ADMIN_PASSWORD = adminPassword;
        };
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        # Wait for health, seed, and mark success only when seed.sh (which
        # ends with assert-seeded.sh) returns 0.
        script = ''
          rm -f /run/mydia-e2e-seeded
          until curl -sf http://localhost:4000/health >/dev/null; do sleep 2; done
          sh ${e2eScripts}/seed.sh
          touch /run/mydia-e2e-seeded
        '';
      };

      environment.systemPackages = [ mydiaCli ];
      networking.firewall.allowedTCPPorts = [ 4000 ];
      networking.firewall.allowedUDPPorts = [ p2pPort ];
      virtualisation.memorySize = 2048;
      virtualisation.cores = 2;
    };

  nodes.client = { ... }: {
    # Mesa for the Flutter engine's GL under Xvfb.
    hardware.graphics.enable = true;
    virtualisation.memorySize = 6144;
    virtualisation.cores = 4;
    # The copied project tree and the Linux build output.
    virtualisation.diskSize = 8192;
  };

  testScript = { nodes, ... }:
    let
      clientRunLogged = mkClientRunLogged {
        serverIp = nodes.server.networking.primaryIPAddress;
        relayIp = nodes.relay.networking.primaryIPAddress;
      };
    in
    ''
    import time

    def dump_journals():
        for machine, unit in [
            (relay, "metadata-relay"),
            (server, "mydia"),
            (server, "mydia-e2e-seed"),
        ]:
            _, out = machine.execute(f"journalctl -u {unit}.service --no-pager")
            print(f"===== journal of {unit} on {machine.name} =====")
            print(out)

    start_all()
    try:
        # 300 s from here for everything the client needs.
        deadline = time.monotonic() + 300

        def left():
            return max(1, int(deadline - time.monotonic()))

        with subtest("relay healthy"):
            relay.wait_until_succeeds("curl -sf http://localhost:4001/health", timeout=left())
        with subtest("server healthy"):
            server.wait_until_succeeds("curl -sf http://localhost:4000/health", timeout=left())
        with subtest("server seeded"):
            # Stops waiting as soon as the seed unit fails, too.
            server.wait_until_succeeds(
                "test -f /run/mydia-e2e-seeded || systemctl is-failed --quiet mydia-e2e-seed.service",
                timeout=left(),
            )
            server.succeed("test -f /run/mydia-e2e-seeded")
            server.succeed(
                "E2E_ADMIN_EMAIL=${adminEmail} sh ${e2eScripts}/assert-seeded.sh"
            )
        client.wait_for_unit("multi-user.target", timeout=left())

        with subtest("player integration tests"):
            # The suite takes about 150 s after a few minutes of app build;
            # a hang costs 20 minutes, not an hour.
            rc, _ = client.execute("${clientRunLogged}", timeout=1200)
            assert rc == 0, f"player integration tests failed (exit {rc})"
    except Exception:
        dump_journals()
        # Crashes of the app under test land in the client's journal.
        _, out = client.execute("journalctl -b --no-pager -p warning | tail -n 200")
        print("===== client journal (warnings) =====")
        print(out)
        raise

    relay.succeed("journalctl -u metadata-relay.service --no-pager > /tmp/metadata-relay.log")
    relay.copy_from_machine("/tmp/metadata-relay.log")
    server.succeed("journalctl -u mydia.service -u mydia-e2e-seed.service --no-pager > /tmp/mydia.log")
    server.copy_from_machine("/tmp/mydia.log")
    client.copy_from_machine("/tmp/player-e2e.log")
  '';
}
