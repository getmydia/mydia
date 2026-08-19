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

  secret_key_base =
    case normalize_env.("SECRET_KEY_BASE") do
      nil ->
        IO.puts(
          :stderr,
          "[metadata_relay] SECRET_KEY_BASE is not set. Generating a random key for this boot. " <>
            "Dashboard sessions will not survive a restart."
        )

        48 |> :crypto.strong_rand_bytes() |> Base.encode64()

      value when byte_size(value) < 64 ->
        raise("SECRET_KEY_BASE must be at least 64 bytes")

      value ->
        value
    end

  dashboard_github_org = normalize_env.("DASHBOARD_GITHUB_ORG")

  # Basic auth credentials are only required when GitHub sign-in is not
  # configured. The two modes are mutually exclusive, so demanding unused
  # basic-auth credentials from a GitHub-only deployment would be busywork.
  github_dashboard? = dashboard_github_org != nil

  require_dashboard_credential = fn name ->
    cond do
      github_dashboard? -> nil
      config_env() == :prod -> raise("#{name} not set, and DASHBOARD_GITHUB_ORG is empty")
      true -> "admin"
    end
  end

  dashboard_username =
    System.get_env("DASHBOARD_USERNAME") || require_dashboard_credential.("DASHBOARD_USERNAME")

  dashboard_password =
    System.get_env("DASHBOARD_PASSWORD") || require_dashboard_credential.("DASHBOARD_PASSWORD")

  config :metadata_relay,
    dashboard_auth: [username: dashboard_username, password: dashboard_password],
    dashboard_github_org: dashboard_github_org

  # Database configuration (all environments except test)
  db_path = System.get_env("SQLITE_DB_PATH") || "./metadata_relay.db"

  config :metadata_relay, MetadataRelay.Repo,
    database: db_path,
    pool_size: 5

  # Phoenix endpoint port configuration (serves both API and dashboard)
  port = String.to_integer(System.get_env("PORT") || "4001")

  config :metadata_relay, MetadataRelayWeb.Endpoint,
    http: [port: port],
    server: true,
    secret_key_base: secret_key_base

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

  config :metadata_relay, MetadataRelay.GitHub,
    client_id: normalize_env.("GITHUB_APP_CLIENT_ID"),
    client_secret: normalize_env.("GITHUB_APP_CLIENT_SECRET"),
    repo: normalize_env.("FEEDBACK_GITHUB_REPO") || "getmydia/mydia"

  if config_env() == :prod do
    # API keys from environment
    tmdb_api_key = System.get_env("TMDB_API_KEY")
    tvdb_api_key = System.get_env("TVDB_API_KEY")

    config :metadata_relay,
      tmdb_api_key: tmdb_api_key,
      tvdb_api_key: tvdb_api_key

    config :metadata_relay,
      rendezvous_master_pepper:
        System.get_env("RENDEZVOUS_MASTER_PEPPER") ||
          raise("RENDEZVOUS_MASTER_PEPPER not set")
  end
end
