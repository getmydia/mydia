# Full NixOS configuration for Mydia
#
# This example shows all available options.
#
# Usage in your flake.nix:
#   inputs.mydia.url = "github:owner/mydia";
#   modules = [ mydia.nixosModules.default ./mydia.nix ];

{ config, pkgs, ... }:

{
  services.mydia = {
    enable = true;
    package = pkgs.mydia;

    # Web server configuration
    host = "mydia.example.com";
    port = 4000;
    listenAddress = "0.0.0.0";
    openFirewall = true;

    # Database and data
    databasePath = "/var/lib/mydia/mydia.db";
    dataDir = "/var/lib/mydia";

    # Service user/group (defaults shown)
    user = "mydia";
    group = "mydia";

    # Secrets (use agenix or sops-nix in production)
    secretKeyBaseFile = "/run/secrets/mydia/secret_key_base";
    guardianSecretKeyFile = "/run/secrets/mydia/guardian_secret";

    # Media libraries
    mediaLibraries = [
      "/mnt/media/movies"
      "/mnt/media/tv"
      "/mnt/media/anime"
    ];

    # Logging
    logLevel = "info";  # debug, info, warning, error

    # OIDC Authentication (optional)
    oidc = {
      enable = true;
      issuer = "https://auth.example.com/application/o/mydia/";
      clientIdFile = "/run/secrets/mydia/oidc_client_id";
      clientSecretFile = "/run/secrets/mydia/oidc_client_secret";
      scopes = [ "openid" "profile" "email" ];
      # Optional: custom discovery document URI
      # discoveryDocumentUri = "https://auth.example.com/.well-known/openid-configuration";
    };

    # Download clients
    downloadClients = {
      # qBittorrent
      qbit = {
        type = "qbittorrent";
        host = "localhost";
        port = 8080;
        username = "admin";
        passwordFile = "/run/secrets/mydia/qbittorrent_password";
        useSsl = false;
      };

      # Transmission
      transmission = {
        type = "transmission";
        host = "192.168.1.100";
        port = 9091;
        username = "transmission";
        passwordFile = "/run/secrets/mydia/transmission_password";
        useSsl = false;
      };

      # SABnzbd
      sab = {
        type = "sabnzbd";
        host = "localhost";
        port = 8085;
        passwordFile = "/run/secrets/mydia/sabnzbd_apikey";  # API key
        useSsl = false;
      };
    };

    # FlareSolverr (for bypassing Cloudflare protection)
    flareSolverr = {
      enable = true;
      url = "http://localhost:8191";
      timeout = 60000;
      maxTimeout = 120000;
    };

    # Extra environment variables
    extraEnvironment = {
      ENABLE_PLAYER = "true";
      ENABLE_CARDIGANN = "true";
    };
  };

  # Nginx reverse proxy (optional but recommended)
  services.nginx = {
    enable = true;
    virtualHosts."mydia.example.com" = {
      forceSSL = true;
      enableACME = true;
      locations."/" = {
        proxyPass = "http://127.0.0.1:4000";
        proxyWebsockets = true;
        extraConfig = ''
          proxy_set_header Host $host;
          proxy_set_header X-Real-IP $remote_addr;
          proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
          proxy_set_header X-Forwarded-Proto $scheme;
        '';
      };
    };
  };

  # ACME for Let's Encrypt certificates
  security.acme = {
    acceptTerms = true;
    defaults.email = "admin@example.com";
  };
}
