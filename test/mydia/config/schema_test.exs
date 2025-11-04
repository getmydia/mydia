defmodule Mydia.Config.SchemaTest do
  use ExUnit.Case, async: true

  alias Mydia.Config.Schema

  describe "changeset/2" do
    test "accepts valid configuration" do
      attrs = %{
        server: %{
          port: 4000,
          host: "0.0.0.0",
          url_scheme: "https",
          url_host: "example.com",
          secret_key_base: "test_secret",
          guardian_secret_key: "test_guardian_secret"
        },
        auth: %{
          local_enabled: true,
          oidc_enabled: false
        }
      }

      changeset = Schema.changeset(%Schema{}, attrs)

      assert changeset.valid?
    end

    test "validates server port range" do
      attrs = %{
        server: %{port: 70_000}
      }

      changeset = Schema.changeset(%Schema{}, attrs)

      refute changeset.valid?
      assert "must be less than 65536" in errors_on(changeset).server.port
    end

    test "validates server port is positive" do
      attrs = %{
        server: %{port: -1}
      }

      changeset = Schema.changeset(%Schema{}, attrs)

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).server.port
    end

    test "validates url_scheme is http or https" do
      attrs = %{
        server: %{url_scheme: "ftp"}
      }

      changeset = Schema.changeset(%Schema{}, attrs)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).server.url_scheme
    end

    test "validates database pool_size is positive" do
      attrs = %{
        database: %{pool_size: 0}
      }

      changeset = Schema.changeset(%Schema{}, attrs)

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).database.pool_size
    end

    test "validates database journal_mode" do
      attrs = %{
        database: %{journal_mode: "invalid"}
      }

      changeset = Schema.changeset(%Schema{}, attrs)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).database.journal_mode
    end

    test "validates database synchronous mode" do
      attrs = %{
        database: %{synchronous: "invalid"}
      }

      changeset = Schema.changeset(%Schema{}, attrs)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).database.synchronous
    end

    test "validates at least one auth method is enabled" do
      attrs = %{
        auth: %{
          local_enabled: false,
          oidc_enabled: false
        }
      }

      changeset = Schema.changeset(%Schema{}, attrs)

      refute changeset.valid?

      assert "at least one authentication method (local or OIDC) must be enabled" in errors_on(
               changeset
             ).auth
    end

    test "requires OIDC fields when OIDC is enabled" do
      attrs = %{
        auth: %{
          local_enabled: false,
          oidc_enabled: true
        }
      }

      changeset = Schema.changeset(%Schema{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).auth.oidc_client_id
      assert "can't be blank" in errors_on(changeset).auth.oidc_client_secret

      assert "either oidc_issuer or oidc_discovery_document_uri must be provided when OIDC is enabled" in errors_on(
               changeset
             ).auth.oidc_issuer
    end

    test "accepts OIDC config with issuer" do
      attrs = %{
        auth: %{
          local_enabled: false,
          oidc_enabled: true,
          oidc_issuer: "https://auth.example.com",
          oidc_client_id: "client",
          oidc_client_secret: "secret"
        }
      }

      changeset = Schema.changeset(%Schema{}, attrs)

      assert changeset.valid?
    end

    test "accepts OIDC config with discovery document URI" do
      attrs = %{
        auth: %{
          local_enabled: false,
          oidc_enabled: true,
          oidc_discovery_document_uri:
            "https://auth.example.com/.well-known/openid-configuration",
          oidc_client_id: "client",
          oidc_client_secret: "secret"
        }
      }

      changeset = Schema.changeset(%Schema{}, attrs)

      assert changeset.valid?
    end

    test "validates logging level" do
      attrs = %{
        logging: %{level: "invalid"}
      }

      changeset = Schema.changeset(%Schema{}, attrs)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).logging.level
    end

    test "validates media scan_interval_hours is positive" do
      attrs = %{
        media: %{scan_interval_hours: 0}
      }

      changeset = Schema.changeset(%Schema{}, attrs)

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).media.scan_interval_hours
    end

    test "validates downloads monitor_interval_minutes is positive" do
      attrs = %{
        downloads: %{monitor_interval_minutes: 0}
      }

      changeset = Schema.changeset(%Schema{}, attrs)

      refute changeset.valid?

      assert "must be greater than 0" in errors_on(changeset).downloads.monitor_interval_minutes
    end

    test "validates oban poll_interval is positive" do
      attrs = %{
        oban: %{poll_interval: 0}
      }

      changeset = Schema.changeset(%Schema{}, attrs)

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).oban.poll_interval
    end

    test "validates oban max_age_days is positive" do
      attrs = %{
        oban: %{max_age_days: 0}
      }

      changeset = Schema.changeset(%Schema{}, attrs)

      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).oban.max_age_days
    end

    test "accepts valid download client configuration" do
      attrs = %{
        download_clients: [
          %{
            name: "qBittorrent",
            type: :qbittorrent,
            enabled: true,
            priority: 1,
            host: "localhost",
            port: 8080,
            use_ssl: false,
            username: "admin",
            password: "pass"
          }
        ]
      }

      changeset = Schema.changeset(%Schema{}, attrs)

      assert changeset.valid?
    end

    test "validates download client requires name, type, host, and port" do
      attrs = %{
        download_clients: [
          %{
            enabled: true
          }
        ]
      }

      changeset = Schema.changeset(%Schema{}, attrs)

      refute changeset.valid?
      [client_errors] = errors_on(changeset).download_clients
      assert "can't be blank" in client_errors.name
      assert "can't be blank" in client_errors.type
      assert "can't be blank" in client_errors.host
      assert "can't be blank" in client_errors.port
    end

    test "validates download client type is valid" do
      attrs = %{
        download_clients: [
          %{
            name: "Test",
            type: :invalid_type,
            host: "localhost",
            port: 8080
          }
        ]
      }

      changeset = Schema.changeset(%Schema{}, attrs)

      refute changeset.valid?
      [client_errors] = errors_on(changeset).download_clients
      assert "is invalid" in client_errors.type
    end

    test "validates download client port range" do
      attrs = %{
        download_clients: [
          %{
            name: "Test",
            type: :qbittorrent,
            host: "localhost",
            port: 70_000
          }
        ]
      }

      changeset = Schema.changeset(%Schema{}, attrs)

      refute changeset.valid?
      [client_errors] = errors_on(changeset).download_clients
      assert "must be less than 65536" in client_errors.port
    end

    test "validates download client priority is positive" do
      attrs = %{
        download_clients: [
          %{
            name: "Test",
            type: :qbittorrent,
            host: "localhost",
            port: 8080,
            priority: 0
          }
        ]
      }

      changeset = Schema.changeset(%Schema{}, attrs)

      refute changeset.valid?
      [client_errors] = errors_on(changeset).download_clients
      assert "must be greater than 0" in client_errors.priority
    end

    test "accepts multiple download clients" do
      attrs = %{
        download_clients: [
          %{
            name: "qBittorrent",
            type: :qbittorrent,
            host: "localhost",
            port: 8080
          },
          %{
            name: "Transmission",
            type: :transmission,
            host: "localhost",
            port: 9091
          }
        ]
      }

      changeset = Schema.changeset(%Schema{}, attrs)

      assert changeset.valid?
    end
  end

  describe "defaults/0" do
    test "returns valid default configuration" do
      defaults = Schema.defaults()

      assert defaults.server.port == 4000
      assert defaults.server.host == "0.0.0.0"
      assert defaults.server.url_scheme == "http"
      assert defaults.database.pool_size == 5
      assert defaults.database.journal_mode == "wal"
      assert defaults.auth.local_enabled == true
      assert defaults.auth.oidc_enabled == false
      assert defaults.media.movies_path == "/media/movies"
      assert defaults.media.tv_path == "/media/tv"
      assert defaults.logging.level == "info"
      assert defaults.download_clients == []
    end
  end

  # Helper function to extract errors from changeset
  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
