{ config, lib, pkgs, ... }:

let
  cfg = config.services.mydia;
  inherit (lib) mkEnableOption mkOption mkIf types literalExpression optional optionals optionalString;

  # Download client submodule type
  downloadClientType = types.submodule {
    options = {
      type = mkOption {
        type = types.enum [ "qbittorrent" "transmission" "sabnzbd" "nzbget" ];
        description = "Type of download client";
      };
      host = mkOption {
        type = types.str;
        default = "localhost";
        description = "Host of the download client";
      };
      port = mkOption {
        type = types.port;
        description = "Port of the download client";
      };
      username = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "Username for authentication";
      };
      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to file containing the password";
      };
      useSsl = mkOption {
        type = types.bool;
        default = false;
        description = "Whether to use SSL/TLS";
      };
    };
  };
in
{
  options.services.mydia = {
    enable = mkEnableOption "Mydia media manager";

    package = mkOption {
      type = types.package;
      description = "The Mydia package to use";
      example = literalExpression "pkgs.mydia";
    };

    port = mkOption {
      type = types.port;
      default = 4000;
      description = "Port for the web interface";
    };

    host = mkOption {
      type = types.str;
      default = "localhost";
      description = "Host to bind to (used for URL generation)";
    };

    listenAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "IP address to listen on";
    };

    database = {
      type = mkOption {
        type = types.enum [ "sqlite" "postgres" ];
        default = "sqlite";
        description = "Database backend. Must match the package variant being used.";
      };

      # SQLite options
      path = mkOption {
        type = types.path;
        default = "/var/lib/mydia/mydia.db";
        description = "Path to the SQLite database file (only used when type = sqlite)";
      };

      # PostgreSQL options
      host = mkOption {
        type = types.str;
        default = "localhost";
        description = "PostgreSQL host (only used when type = postgres)";
      };

      port = mkOption {
        type = types.port;
        default = 5432;
        description = "PostgreSQL port (only used when type = postgres)";
      };

      name = mkOption {
        type = types.str;
        default = "mydia";
        description = "PostgreSQL database name (only used when type = postgres)";
      };

      user = mkOption {
        type = types.str;
        default = "mydia";
        description = "PostgreSQL user (only used when type = postgres)";
      };

      passwordFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to file containing PostgreSQL password. Not needed when using local peer auth (only used when type = postgres)";
      };

      createLocally = mkOption {
        type = types.bool;
        default = true;
        description = "Whether to configure a local PostgreSQL instance (only used when type = postgres)";
      };

      sslMode = mkOption {
        type = types.enum [ "verify" "disable" ];
        default = "disable";
        description = "SSL mode for PostgreSQL connections. Set to 'verify' for remote PostgreSQL with SSL (only used when type = postgres)";
      };
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/mydia";
      description = "Directory for Mydia data files";
    };

    mediaLibraries = mkOption {
      type = types.listOf types.path;
      default = [ ];
      description = "List of media library paths that Mydia needs read access to";
      example = [ "/mnt/media/movies" "/mnt/media/tv" ];
    };

    secretKeyBaseFile = mkOption {
      type = types.path;
      description = ''
        Path to a file containing the SECRET_KEY_BASE.
        Generate with: `mix phx.gen.secret` or `openssl rand -base64 48`
      '';
      example = "/run/secrets/mydia/secret_key_base";
    };

    guardianSecretKeyFile = mkOption {
      type = types.path;
      default = cfg.secretKeyBaseFile;
      description = ''
        Path to a file containing the GUARDIAN_SECRET_KEY for JWT tokens.

        Defaults to secretKeyBaseFile, so a single secret signs both session
        cookies and JWTs unless you point this at a separate file. Whichever
        file this resolves to is loaded and validated independently of
        secretKeyBaseFile at service start (both must be non-empty) --
        pointing it at an empty file is now a hard failure, it no longer
        silently falls back to reusing the other secret's value.
        Generate with: `mix guardian.gen.secret` or `openssl rand -base64 48`
      '';
      example = "/run/secrets/mydia/guardian_secret";
    };

    user = mkOption {
      type = types.str;
      default = "mydia";
      description = "User account under which Mydia runs";
    };

    group = mkOption {
      type = types.str;
      default = "mydia";
      description = "Group under which Mydia runs";
    };

    openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to open the firewall for the web interface";
    };

    logLevel = mkOption {
      type = types.enum [ "debug" "info" "warning" "error" ];
      default = "info";
      description = "Log level for the application";
    };

    # OIDC Authentication options
    oidc = {
      enable = mkEnableOption "OIDC authentication";

      issuer = mkOption {
        type = types.str;
        description = "OIDC issuer URL";
        example = "https://auth.example.com/application/o/mydia/";
      };

      discoveryDocumentUri = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = "OIDC discovery document URI (defaults to issuer/.well-known/openid-configuration)";
      };

      clientIdFile = mkOption {
        type = types.path;
        description = "Path to file containing the OIDC client ID";
        example = "/run/secrets/mydia/oidc_client_id";
      };

      clientSecretFile = mkOption {
        type = types.path;
        description = "Path to file containing the OIDC client secret";
        example = "/run/secrets/mydia/oidc_client_secret";
      };

      scopes = mkOption {
        type = types.listOf types.str;
        default = [ "openid" "profile" "email" ];
        description = "OIDC scopes to request";
      };
    };

    # Download client options
    downloadClients = mkOption {
      type = types.attrsOf downloadClientType;
      default = { };
      description = "Download clients configuration";
      example = literalExpression ''
        {
          main = {
            type = "qbittorrent";
            host = "localhost";
            port = 8080;
            username = "admin";
            passwordFile = "/run/secrets/mydia/qbittorrent_password";
          };
        }
      '';
    };

    # FlareSolverr options
    flareSolverr = {
      enable = mkEnableOption "FlareSolverr integration";

      url = mkOption {
        type = types.str;
        default = "http://localhost:8191";
        description = "FlareSolverr URL";
      };

      timeout = mkOption {
        type = types.int;
        default = 60000;
        description = "FlareSolverr timeout in milliseconds";
      };

      maxTimeout = mkOption {
        type = types.int;
        default = 120000;
        description = "FlareSolverr maximum timeout in milliseconds";
      };
    };

    extraEnvironment = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Extra environment variables to pass to the service";
      example = {
        ENABLE_PLAYBACK = "true";
      };
    };
  };

  config = mkIf cfg.enable {
    systemd.services.mydia = {
      description = "Mydia Media Manager";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ]
        ++ optional (cfg.database.type == "postgres" && cfg.database.createLocally) "postgresql.service";
      requires =
        optional (cfg.database.type == "postgres" && cfg.database.createLocally) "postgresql.service";

      environment = {
        PORT = toString cfg.port;
        PHX_HOST = cfg.host;
        PHX_IP = cfg.listenAddress;
        PHX_SERVER = "true";
        LOG_LEVEL = cfg.logLevel;
        RELEASE_COOKIE = "mydia_nixos";
        RELEASE_DISTRIBUTION = "none";
        HOME = cfg.dataDir;
      } // lib.optionalAttrs (cfg.database.type == "sqlite") {
        DATABASE_PATH = cfg.database.path;
      } // lib.optionalAttrs (cfg.database.type == "postgres") {
        DATABASE_HOST = cfg.database.host;
        DATABASE_PORT = toString cfg.database.port;
        DATABASE_NAME = cfg.database.name;
        DATABASE_USER = cfg.database.user;
        DATABASE_SSL_MODE = cfg.database.sslMode;
      } // lib.optionalAttrs cfg.oidc.enable {
        OIDC_ISSUER = cfg.oidc.issuer;
        OIDC_SCOPES = lib.concatStringsSep " " cfg.oidc.scopes;
      } // lib.optionalAttrs (cfg.oidc.enable && cfg.oidc.discoveryDocumentUri != null) {
        OIDC_DISCOVERY_DOCUMENT_URI = cfg.oidc.discoveryDocumentUri;
      } // lib.optionalAttrs cfg.flareSolverr.enable {
        FLARESOLVERR_ENABLED = "true";
        FLARESOLVERR_URL = cfg.flareSolverr.url;
        FLARESOLVERR_TIMEOUT = toString cfg.flareSolverr.timeout;
        FLARESOLVERR_MAX_TIMEOUT = toString cfg.flareSolverr.maxTimeout;
      } // cfg.extraEnvironment;

      path = [ cfg.package pkgs.ffmpeg pkgs.openssl ];

      serviceConfig = {
        Type = "exec";
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.dataDir;

        # Run migrations before starting
        ExecStartPre = let
          loadDbPassword = optionalString (cfg.database.type == "postgres" && cfg.database.passwordFile != null) ''
            # Load PostgreSQL password
            if [ -f "$CREDENTIALS_DIRECTORY/DATABASE_PASSWORD" ]; then
              export DATABASE_PASSWORD=$(cat "$CREDENTIALS_DIRECTORY/DATABASE_PASSWORD")
            fi
          '';
          setupSqlite = optionalString (cfg.database.type == "sqlite") ''
            # Create database directory if it doesn't exist
            mkdir -p "$(dirname "${cfg.database.path}")"
          '';
        in pkgs.writeShellScript "mydia-migrate" ''
          set -euo pipefail

          # Load secrets. -s (exists AND non-empty) rather than -f: an
          # empty credential file must be treated the same as a missing
          # one, so it surfaces as a clear boot failure in
          # Mydia.Release.Env instead of silently becoming an empty
          # SECRET_KEY_BASE/GUARDIAN_SECRET_KEY.
          if [ -s "$CREDENTIALS_DIRECTORY/SECRET_KEY_BASE" ]; then
            export SECRET_KEY_BASE=$(cat "$CREDENTIALS_DIRECTORY/SECRET_KEY_BASE")
          fi
          if [ -s "$CREDENTIALS_DIRECTORY/GUARDIAN_SECRET_KEY" ]; then
            export GUARDIAN_SECRET_KEY=$(cat "$CREDENTIALS_DIRECTORY/GUARDIAN_SECRET_KEY")
          fi

          ${setupSqlite}
          ${loadDbPassword}

          # Run migrations
          ${cfg.package}/bin/mydia eval "Mydia.Release.migrate()"
        '';

        ExecStart = let
          # Build credential loading script
          loadSecrets = ''
            # Load core secrets. -s (exists AND non-empty) rather than -f:
            # an empty credential file must be treated the same as a
            # missing one, so it surfaces as a clear boot failure in
            # Mydia.Release.Env instead of silently becoming an empty
            # SECRET_KEY_BASE/GUARDIAN_SECRET_KEY.
            if [ -s "$CREDENTIALS_DIRECTORY/SECRET_KEY_BASE" ]; then
              export SECRET_KEY_BASE=$(cat "$CREDENTIALS_DIRECTORY/SECRET_KEY_BASE")
            fi
            if [ -s "$CREDENTIALS_DIRECTORY/GUARDIAN_SECRET_KEY" ]; then
              export GUARDIAN_SECRET_KEY=$(cat "$CREDENTIALS_DIRECTORY/GUARDIAN_SECRET_KEY")
            fi
          '';

          loadDbPassword = optionalString (cfg.database.type == "postgres" && cfg.database.passwordFile != null) ''
            # Load PostgreSQL password
            if [ -f "$CREDENTIALS_DIRECTORY/DATABASE_PASSWORD" ]; then
              export DATABASE_PASSWORD=$(cat "$CREDENTIALS_DIRECTORY/DATABASE_PASSWORD")
            fi
          '';

          loadOidcSecrets = optionalString cfg.oidc.enable ''
            # Load OIDC secrets
            if [ -f "$CREDENTIALS_DIRECTORY/OIDC_CLIENT_ID" ]; then
              export OIDC_CLIENT_ID=$(cat "$CREDENTIALS_DIRECTORY/OIDC_CLIENT_ID")
            fi
            if [ -f "$CREDENTIALS_DIRECTORY/OIDC_CLIENT_SECRET" ]; then
              export OIDC_CLIENT_SECRET=$(cat "$CREDENTIALS_DIRECTORY/OIDC_CLIENT_SECRET")
            fi
          '';

          loadDownloadClientSecrets = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: client:
            optionalString (client.passwordFile != null) ''
              # Load ${name} download client password
              if [ -f "$CREDENTIALS_DIRECTORY/DOWNLOAD_CLIENT_${lib.toUpper name}_PASSWORD" ]; then
                export DOWNLOAD_CLIENT_${lib.toUpper name}_PASSWORD=$(cat "$CREDENTIALS_DIRECTORY/DOWNLOAD_CLIENT_${lib.toUpper name}_PASSWORD")
              fi
            ''
          ) cfg.downloadClients);

          # Build download client environment exports
          downloadClientEnvs = lib.concatStringsSep "\n" (lib.mapAttrsToList (name: client:
            let
              upperName = lib.toUpper name;
              proto = if client.useSsl then "https" else "http";
            in ''
              export DOWNLOAD_CLIENT_${upperName}_TYPE="${client.type}"
              export DOWNLOAD_CLIENT_${upperName}_URL="${proto}://${client.host}:${toString client.port}"
              ${optionalString (client.username != null) ''export DOWNLOAD_CLIENT_${upperName}_USERNAME="${client.username}"''}
            ''
          ) cfg.downloadClients);
        in pkgs.writeShellScript "mydia-start" ''
          set -euo pipefail

          ${loadSecrets}
          ${loadDbPassword}
          ${loadOidcSecrets}
          ${loadDownloadClientSecrets}
          ${downloadClientEnvs}

          exec ${cfg.package}/bin/mydia start
        '';

        ExecStop = "${cfg.package}/bin/mydia stop";
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStartSec = 60;

        # Secrets via LoadCredential (not stored in Nix store)
        LoadCredential =
          [
            "SECRET_KEY_BASE:${cfg.secretKeyBaseFile}"
            "GUARDIAN_SECRET_KEY:${cfg.guardianSecretKeyFile}"
          ]
          ++ optional (cfg.database.type == "postgres" && cfg.database.passwordFile != null)
            "DATABASE_PASSWORD:${cfg.database.passwordFile}"
          ++ optionals cfg.oidc.enable [
            "OIDC_CLIENT_ID:${cfg.oidc.clientIdFile}"
            "OIDC_CLIENT_SECRET:${cfg.oidc.clientSecretFile}"
          ]
          ++ lib.concatLists (lib.mapAttrsToList (name: client:
            optional (client.passwordFile != null)
              "DOWNLOAD_CLIENT_${lib.toUpper name}_PASSWORD:${client.passwordFile}"
          ) cfg.downloadClients);

        # Security hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        MemoryDenyWriteExecute = false; # Required for BEAM JIT
        LockPersonality = true;
        SystemCallArchitectures = "native";

        # Writable paths
        ReadWritePaths = [ cfg.dataDir ] ++ cfg.mediaLibraries;
        ReadOnlyPaths = cfg.mediaLibraries;

        # State directory
        StateDirectory = "mydia";
        StateDirectoryMode = "0750";
      };
    };

    # Create user and group
    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.dataDir;
      description = "Mydia service user";
    };

    users.groups.${cfg.group} = { };

    # Auto-configure local PostgreSQL when requested
    services.postgresql = mkIf (cfg.database.type == "postgres" && cfg.database.createLocally) {
      enable = true;
      ensureDatabases = [ cfg.database.name ];
      ensureUsers = [{
        name = cfg.database.user;
        ensureDBOwnership = true;
      }];
      # Allow the mydia user to connect via TCP without a password
      authentication = ''
        host ${cfg.database.name} ${cfg.database.user} 127.0.0.1/32 trust
        host ${cfg.database.name} ${cfg.database.user} ::1/128 trust
      '';
    };

    # Open firewall if requested
    networking.firewall.allowedTCPPorts = mkIf cfg.openFirewall [ cfg.port ];
  };
}
