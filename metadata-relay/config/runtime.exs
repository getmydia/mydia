import Config

# Runtime configuration loaded at application start
# This is where environment variables are read

# Skip runtime configuration for test environment (handled in test.exs)
if config_env() != :test do
  normalize_env = fn name ->
    case System.get_env(name) do
      nil ->
        nil

      value ->
        value = String.trim(value)
        if value == "", do: nil, else: value
    end
  end

  dashboard_username =
    System.get_env("DASHBOARD_USERNAME") ||
      if config_env() == :prod do
        raise("DASHBOARD_USERNAME not set")
      else
        "admin"
      end

  dashboard_password =
    System.get_env("DASHBOARD_PASSWORD") ||
      if config_env() == :prod do
        raise("DASHBOARD_PASSWORD not set")
      else
        "admin"
      end

  config :metadata_relay,
    dashboard_auth: [username: dashboard_username, password: dashboard_password]

  # Database configuration (all environments except test)
  db_path = System.get_env("SQLITE_DB_PATH") || "./metadata_relay.db"

  config :metadata_relay, MetadataRelay.Repo,
    database: db_path,
    pool_size: 5

  # Phoenix endpoint port configuration (serves both API and dashboard)
  port = String.to_integer(System.get_env("PORT") || "4001")

  config :metadata_relay, MetadataRelayWeb.Endpoint,
    http: [port: port],
    server: true

  feedback_email_to = normalize_env.("FEEDBACK_EMAIL_TO")
  feedback_email_from = normalize_env.("FEEDBACK_EMAIL_FROM") || "metadata-relay@localhost"
  feedback_dashboard_url = normalize_env.("FEEDBACK_DASHBOARD_URL")

  if feedback_email_to do
    config :metadata_relay, MetadataRelay.Feedback.Notifier,
      recipient: feedback_email_to,
      from: feedback_email_from,
      dashboard_url: feedback_dashboard_url

    smtp_host = normalize_env.("SMTP_HOST")

    if smtp_host do
      smtp_username = normalize_env.("SMTP_USERNAME")
      smtp_password = normalize_env.("SMTP_PASSWORD")
      smtp_port = normalize_env.("SMTP_PORT") || "587"

      config :metadata_relay, MetadataRelay.Mailer,
        adapter: Swoosh.Adapters.SMTP,
        relay: smtp_host,
        port: String.to_integer(smtp_port),
        username: smtp_username,
        password: smtp_password,
        auth: if(smtp_username && smtp_password, do: :always, else: :never),
        tls: :always,
        tls_options: [
          verify: :verify_peer,
          cacerts: :public_key.cacerts_get(),
          server_name_indication: String.to_charlist(smtp_host),
          depth: 99,
          customize_hostname_check: [
            match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
          ]
        ],
        retries: 2,
        no_mx_lookups: true
    else
      if config_env() == :prod do
        raise("SMTP_HOST must be set when FEEDBACK_EMAIL_TO is configured")
      end
    end
  end

  if config_env() == :prod do
    # API keys from environment
    tmdb_api_key = System.get_env("TMDB_API_KEY")
    tvdb_api_key = System.get_env("TVDB_API_KEY")

    trakt_client_id = System.get_env("TRAKT_CLIENT_ID")
    trakt_client_secret = System.get_env("TRAKT_CLIENT_SECRET")

    config :metadata_relay,
      tmdb_api_key: tmdb_api_key,
      tvdb_api_key: tvdb_api_key,
      trakt_client_id: trakt_client_id,
      trakt_client_secret: trakt_client_secret

    config :metadata_relay,
      rendezvous_master_pepper:
        System.get_env("RENDEZVOUS_MASTER_PEPPER") ||
          raise("RENDEZVOUS_MASTER_PEPPER not set")
  end
end
