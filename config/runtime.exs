import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/mydia start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :mydia, MydiaWeb.Endpoint, server: true
end

# Database adapter is configured at compile time only
# The adapter cannot be changed at runtime - it's baked into the compiled release
# Each Docker image is built for a specific database type
compiled_adapter = Application.compile_env(:mydia, :database_adapter, Ecto.Adapters.SQLite3)

# Warn if user tries to set DATABASE_TYPE at runtime differently than compile time
if config_env() == :prod do
  runtime_database_type = System.get_env("DATABASE_TYPE")

  if runtime_database_type do
    runtime_adapter =
      case runtime_database_type do
        "postgres" -> Ecto.Adapters.Postgres
        "postgresql" -> Ecto.Adapters.Postgres
        _ -> Ecto.Adapters.SQLite3
      end

    if runtime_adapter != compiled_adapter do
      require Logger

      Logger.warning("""
      DATABASE_TYPE environment variable is set to "#{runtime_database_type}" at runtime,
      but this application was compiled with #{inspect(compiled_adapter)}.

      The database adapter is determined at compile time and cannot be changed at runtime.
      This setting will be ignored.

      To use a different database adapter:
      - For SQLite: Use the 'latest' or version-tagged Docker images (e.g., 'v0.8.0')
      - For PostgreSQL: Use the '-pg' suffixed images (e.g., 'latest-pg' or 'v0.8.0-pg')
      """)
    end
  end
end

if config_env() == :prod do
  # Database configuration based on compile-time adapter
  case compiled_adapter do
    Ecto.Adapters.Postgres ->
      ssl_opt =
        if System.get_env("DATABASE_SSL_MODE") == "disable", do: [ssl: false], else: []

      config :mydia,
             Mydia.Repo,
             [
               hostname: System.get_env("DATABASE_HOST") || "localhost",
               port: String.to_integer(System.get_env("DATABASE_PORT") || "5432"),
               database: System.get_env("DATABASE_NAME") || "mydia",
               username: System.get_env("DATABASE_USER") || "postgres",
               password: System.get_env("DATABASE_PASSWORD"),
               pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
               # Increased timeout to handle long-running library scans (60 seconds)
               timeout: 60_000
             ] ++ ssl_opt

    Ecto.Adapters.SQLite3 ->
      database_path =
        System.get_env("DATABASE_PATH") ||
          raise """
          environment variable DATABASE_PATH is missing.
          For example: /etc/mydia/mydia.db
          """

      config :mydia, Mydia.Repo,
        database: database_path,
        pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
        # SQLite-specific optimizations for production
        # Increased timeout to handle long-running library scans (60 seconds)
        timeout: 60_000,
        journal_mode: :wal,
        # 64MB cache
        cache_size: -64000,
        temp_store: :memory,
        synchronous: :normal,
        foreign_keys: :on,
        # Increased busy_timeout to handle concurrent writes during library scans
        busy_timeout: 30_000
  end

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :mydia, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Configure check_origin for WebSocket connections
  # This prevents LiveView reconnection loops when accessing via IP addresses or different hostnames
  # Options:
  # - Set PHX_CHECK_ORIGIN=false to disable origin checking (useful for Docker deployments with varying IPs)
  # - Set PHX_CHECK_ORIGIN=https://example.com,https://other.com for specific allowed origins
  # - If not set, defaults to allowing the configured PHX_HOST with any scheme
  check_origin =
    case System.get_env("PHX_CHECK_ORIGIN") do
      "false" -> false
      nil -> ["//#{host}"]
      origins -> String.split(origins, ",", trim: true)
    end

  # Configure IP binding - defaults to IPv4 for Docker compatibility
  # Set PHX_IP="::" for IPv6, or PHX_IP="0.0.0.0" for explicit IPv4
  ip_tuple =
    case System.get_env("PHX_IP") do
      "::" ->
        {0, 0, 0, 0, 0, 0, 0, 0}

      "0.0.0.0" ->
        {0, 0, 0, 0}

      nil ->
        {0, 0, 0, 0}

      custom_ip ->
        custom_ip
        |> String.split(".")
        |> Enum.map(&String.to_integer/1)
        |> List.to_tuple()
    end

  # HTTPS port configuration
  # Use 4443 to avoid conflict with metadata-relay on 4001
  https_port = String.to_integer(System.get_env("HTTPS_PORT") || "4443")

  # Generate or load self-signed certificate for direct HTTPS access
  {:ok, cert_path, key_path, _fingerprint} = Mydia.RemoteAccess.Certificates.ensure_certificate()

  config :mydia, MydiaWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Bind on all interfaces using IPv4 by default (Docker compatible)
      # Set PHX_IP="::" environment variable to use IPv6
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: ip_tuple,
      port: port
    ],
    https: [
      # HTTPS endpoint using self-signed certificate
      ip: ip_tuple,
      port: https_port,
      cipher_suite: :strong,
      certfile: cert_path,
      keyfile: key_path
    ],
    secret_key_base: secret_key_base,
    check_origin: check_origin

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :mydia, MydiaWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :mydia, MydiaWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # Guardian JWT secret key
  guardian_secret_key =
    System.get_env("GUARDIAN_SECRET_KEY") ||
      raise """
      environment variable GUARDIAN_SECRET_KEY is missing.
      You can generate one by calling: mix guardian.gen.secret
      """

  config :mydia, Mydia.Auth.Guardian, secret_key: guardian_secret_key
  config :mydia, Mydia.RemoteAccess.MediaToken, secret_key: guardian_secret_key

  # Relay tunnel shared secret
  # Uses dedicated env var if provided, otherwise derives from secret_key_base
  # for zero-configuration security
  relay_tunnel_secret =
    System.get_env("RELAY_TUNNEL_SECRET") ||
      :crypto.mac(:hmac, :sha256, secret_key_base, "relay_tunnel_secret")
      |> Base.encode64()

  config :mydia, :relay_tunnel_secret, relay_tunnel_secret

  # Configure Logger level based on environment variable
  # Supports: debug, info, warning, error
  log_level =
    case System.get_env("LOG_LEVEL") do
      "debug" -> :debug
      "info" -> :info
      "warning" -> :warning
      "error" -> :error
      _ -> :info
    end

  config :logger, level: log_level

  # Feature flags configuration
  playback_enabled =
    case System.get_env("ENABLE_PLAYBACK") do
      "true" -> true
      "false" -> false
      _ -> Application.get_env(:mydia, :features)[:playback_enabled] || true
    end

  cardigann_enabled =
    case System.get_env("ENABLE_CARDIGANN") do
      "true" -> true
      "false" -> false
      _ -> Application.get_env(:mydia, :features)[:cardigann_enabled] || false
    end

  import_lists_enabled =
    case System.get_env("ENABLE_IMPORT_LISTS") do
      "true" -> true
      "false" -> false
      _ -> Application.get_env(:mydia, :features)[:import_lists_enabled] || false
    end

  remote_access_enabled =
    case System.get_env("ENABLE_REMOTE_ACCESS") do
      "true" -> true
      "false" -> false
      _ -> Application.get_env(:mydia, :features)[:remote_access_enabled] || false
    end

  config :mydia, :features,
    playback_enabled: playback_enabled,
    cardigann_enabled: cardigann_enabled,
    import_lists_enabled: import_lists_enabled,
    remote_access_enabled: remote_access_enabled

  # Enable/disable public IP detection via external services
  # Default: true (enabled)
  public_ip_enabled =
    case System.get_env("PUBLIC_IP_ENABLED") do
      "false" -> false
      "0" -> false
      _ -> true
    end

  # Manual external URL override
  external_url = System.get_env("EXTERNAL_URL")

  # Additional direct URLs (comma-separated list)
  additional_direct_urls =
    case System.get_env("ADDITIONAL_DIRECT_URLS") do
      nil -> []
      "" -> []
      urls -> String.split(urls, ",", trim: true)
    end

  # Data directory for certificate storage
  data_dir = System.get_env("MYDIA_DATA_DIR") || "priv/data"

  # Direct URLs configuration
  # Uses PORT and HTTPS_PORT directly for URL generation (no separate port variables needed)
  config :mydia, :direct_urls,
    http_port: port,
    https_port: https_port,
    public_ip_enabled: public_ip_enabled,
    external_url: external_url,
    additional_direct_urls: additional_direct_urls,
    data_dir: data_dir
end

# Trash directory (all environments). Optional: leaving it unset trashes into a
# .mydia-trash directory beside each library path, which is outside the library
# and normally on the same filesystem. Set this only to collect every library's
# trash in one place, and make sure the directory you pick is outside all of
# your library paths. See Mydia.Library.TrashStore.
case System.get_env("MYDIA_TRASH_DIR") do
  dir when is_binary(dir) and dir != "" -> config :mydia, :trash_dir, dir
  _ -> :ok
end

# FlareSolverr configuration (all environments)
# FlareSolverr is a proxy server to bypass Cloudflare and DDoS-GUARD protection
# Used by Cardigann indexers that require browser-based challenge solving
flaresolverr_url = System.get_env("FLARESOLVERR_URL")

flaresolverr_enabled =
  case System.get_env("FLARESOLVERR_ENABLED") do
    "true" -> true
    "false" -> false
    # Auto-enable if URL is configured
    _ -> not is_nil(flaresolverr_url) and flaresolverr_url != ""
  end

flaresolverr_timeout =
  case System.get_env("FLARESOLVERR_TIMEOUT") do
    nil -> 60_000
    value -> String.to_integer(value)
  end

flaresolverr_max_timeout =
  case System.get_env("FLARESOLVERR_MAX_TIMEOUT") do
    nil -> 120_000
    value -> String.to_integer(value)
  end

config :mydia, :flaresolverr,
  enabled: flaresolverr_enabled,
  url: flaresolverr_url,
  timeout: flaresolverr_timeout,
  max_timeout: flaresolverr_max_timeout

# HTTPS configuration for development
# Matches production setup for consistent behavior with remote access and direct URLs
if config_env() == :dev do
  # Port configuration
  http_port = String.to_integer(System.get_env("PORT") || "4000")
  https_port = String.to_integer(System.get_env("HTTPS_PORT") || "4443")

  # Generate or load self-signed certificate
  {:ok, cert_path, key_path, _fingerprint} = Mydia.RemoteAccess.Certificates.ensure_certificate()

  # Configure HTTPS endpoint (HTTP is already configured in dev.exs)
  config :mydia, MydiaWeb.Endpoint,
    https: [
      ip: {0, 0, 0, 0},
      port: https_port,
      cipher_suite: :strong,
      certfile: cert_path,
      keyfile: key_path
    ]

  # Disable public IP detection in dev by default (usually not needed)
  public_ip_enabled =
    case System.get_env("PUBLIC_IP_ENABLED") do
      "true" -> true
      "1" -> true
      _ -> false
    end

  # Manual external URL override
  external_url = System.get_env("EXTERNAL_URL")

  # Additional direct URLs (comma-separated)
  additional_direct_urls =
    case System.get_env("ADDITIONAL_DIRECT_URLS") do
      nil -> []
      "" -> []
      urls -> String.split(urls, ",", trim: true)
    end

  # Direct URLs configuration
  # Uses PORT and HTTPS_PORT directly for URL generation (no separate port variables needed)
  config :mydia, :direct_urls,
    http_port: http_port,
    https_port: https_port,
    public_ip_enabled: public_ip_enabled,
    external_url: external_url,
    additional_direct_urls: additional_direct_urls,
    data_dir: "priv/data"
end

# Feature flags configuration for dev/test (reads from environment variable)
if config_env() in [:dev, :test] do
  playback_enabled =
    case System.get_env("ENABLE_PLAYBACK") do
      "true" -> true
      "false" -> false
      _ -> Application.get_env(:mydia, :features)[:playback_enabled] || true
    end

  cardigann_enabled =
    case System.get_env("ENABLE_CARDIGANN") do
      "true" -> true
      "false" -> false
      _ -> Application.get_env(:mydia, :features)[:cardigann_enabled] || false
    end

  import_lists_enabled =
    case System.get_env("ENABLE_IMPORT_LISTS") do
      "true" -> true
      "false" -> false
      _ -> Application.get_env(:mydia, :features)[:import_lists_enabled] || false
    end

  remote_access_enabled =
    case System.get_env("ENABLE_REMOTE_ACCESS") do
      "true" -> true
      "false" -> false
      _ -> Application.get_env(:mydia, :features)[:remote_access_enabled] || false
    end

  config :mydia, :features,
    playback_enabled: playback_enabled,
    cardigann_enabled: cardigann_enabled,
    import_lists_enabled: import_lists_enabled,
    remote_access_enabled: remote_access_enabled
end

# P2P bind port configuration (all environments)
# Required for hole punching when running in Docker
p2p_bind_port =
  case System.get_env("P2P_BIND_PORT") do
    nil -> nil
    "" -> nil
    value -> String.to_integer(value)
  end

if p2p_bind_port do
  config :mydia, :p2p_bind_port, p2p_bind_port
end

# P2P keypair path configuration (all environments)
# REQUIRED for persistent node identity - paired devices need this to reconnect
p2p_keypair_path =
  case System.get_env("P2P_KEYPAIR_PATH") do
    nil -> nil
    "" -> nil
    value -> value
  end

if p2p_keypair_path do
  config :mydia, :p2p_keypair_path, p2p_keypair_path
end

# Ueberauth OIDC configuration (all environments)
# This runs at application startup, so environment variables are available
# NOTE: This will also reconfigure OIDC for dev/test if env vars change at runtime,
# which is useful for testing and Docker deployments where env vars are set at startup.
# Support both OIDC_ISSUER and OIDC_DISCOVERY_DOCUMENT_URI
oidc_issuer =
  System.get_env("OIDC_ISSUER") ||
    case System.get_env("OIDC_DISCOVERY_DOCUMENT_URI") do
      nil ->
        nil

      discovery_uri ->
        # Extract issuer from discovery document URI
        # e.g., "https://auth.example.com/.well-known/openid-configuration" -> "https://auth.example.com"
        discovery_uri
        |> String.replace(~r/\/\.well-known\/openid-configuration$/, "")
    end

oidc_client_id = System.get_env("OIDC_CLIENT_ID")
oidc_client_secret = System.get_env("OIDC_CLIENT_SECRET")
oidc_redirect_uri = System.get_env("OIDC_REDIRECT_URI")

if oidc_issuer && oidc_client_id && oidc_client_secret do
  # Only log OIDC configuration in non-CLI mode
  cli_mode? = System.get_env("MYDIA_CLI_MODE") == "true"
  require Logger

  unless cli_mode? do
    Logger.info("Configuring Ueberauth with OIDC for production")
    Logger.info("Issuer: #{oidc_issuer}")
    Logger.info("Client ID: #{oidc_client_id}")
    Logger.info("Redirect URI: #{oidc_redirect_uri || "(auto-generated)"}")
  end

  # Configure oidcc library settings
  config :oidcc, :provider_configuration_opts, %{request_opts: %{transport_opts: []}}

  # Step 1: Configure the OIDC issuer (required by ueberauth_oidcc)
  config :ueberauth_oidcc, :issuers, [
    %{
      name: :default_issuer,
      issuer: oidc_issuer,
      # Workaround for Authelia 4.39+ JAR strictness (RFC 9101 cross-jwt-
      # confusion mitigation): Authelia rejects request objects whose JWT
      # header lacks `typ` (`JWT` or `oauth-authz-req+jwt`). Erlef oidcc up
      # to and including v3.7.2 signs JARs without setting that header, so
      # any flow that builds one fails with `invalid_request_object`.
      #
      # Patch the discovery doc so oidcc believes the issuer supports
      # neither PAR nor the `request` parameter; that short-circuits
      # `oidcc_authorization:attempt_request_object/3` and falls back to a
      # plain query-param authorize redirect. Drop these overrides once
      # upstream oidcc sets `typ` on signed request objects.
      provider_configuration_opts: %{
        quirks: %{
          document_overrides: %{
            "pushed_authorization_request_endpoint" => :undefined,
            "request_parameter_supported" => false
          }
        }
      }
    }
  ]

  # Step 2: Configure Ueberauth provider with optimal compatibility settings
  # Build the base OIDC options
  oidc_opts = [
    issuer: :default_issuer,
    client_id: oidc_client_id,
    client_secret: oidc_client_secret,
    scopes: ["openid", "profile", "email"],
    callback_path: "/auth/oidc/callback",
    userinfo: true,
    uid_field: "sub",
    # Use standard OAuth2 auth methods for maximum compatibility
    # Works with all OIDC providers without requiring special client configuration
    preferred_auth_methods: [:client_secret_post, :client_secret_basic],
    # Use standard OAuth2 response mode (universally supported)
    response_mode: "query"
  ]

  # Add redirect_uri and callback_url if configured
  # redirect_uri is used by ueberauth_oidcc for the OIDC flow
  # callback_url is used by Ueberauth's helpers to generate URLs (important for reverse proxy setups)
  oidc_opts =
    if oidc_redirect_uri do
      oidc_opts
      |> Keyword.put(:redirect_uri, oidc_redirect_uri)
      |> Keyword.put(:callback_url, oidc_redirect_uri)
    else
      oidc_opts
    end

  config :ueberauth, Ueberauth,
    providers: [
      oidc: {Ueberauth.Strategy.Oidcc, oidc_opts}
    ]

  unless cli_mode?, do: Logger.info("Ueberauth OIDC configured successfully!")
else
  require Logger
  Logger.info("OIDC not configured - missing environment variables")
end
