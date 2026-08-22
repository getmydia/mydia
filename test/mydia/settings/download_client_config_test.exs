defmodule Mydia.Settings.DownloadClientConfigTest do
  use Mydia.DataCase, async: true

  alias Mydia.Settings
  alias Mydia.Settings.DownloadClientConfig

  @valid_attrs %{
    name: "test-sab",
    type: :sabnzbd,
    enabled: true,
    priority: 1,
    host: "localhost",
    port: 8080,
    use_ssl: false,
    api_key: "test-api-key"
  }

  describe "rqbit client type" do
    @rqbit_attrs %{
      name: "test-rqbit",
      type: :rqbit,
      enabled: true,
      priority: 1,
      host: "localhost",
      port: 3030,
      use_ssl: false
    }

    test "a rqbit config with host and port is valid" do
      {:ok, config} = Settings.create_download_client_config(@rqbit_attrs)
      assert config.type == :rqbit
      assert config.host == "localhost"
      assert config.port == 3030
    end

    test "rqbit requires host and port (network client validation)" do
      changeset =
        DownloadClientConfig.changeset(%DownloadClientConfig{}, %{@rqbit_attrs | host: nil})

      refute changeset.valid?
      assert %{host: _} = errors_on(changeset)
    end
  end

  describe "wave-2 schema additions" do
    test "inserting with a categories map round-trips correctly" do
      categories = %{"movie" => "movies", "tv" => "tv", "music" => "music"}
      attrs = Map.put(@valid_attrs, :categories, categories)

      {:ok, config} = Settings.create_download_client_config(attrs)
      assert config.categories == categories

      # Round-trip through the DB (reload)
      reloaded = Repo.get!(DownloadClientConfig, config.id)
      assert reloaded.categories == categories
    end

    test "inserting with a priority_profile map round-trips correctly" do
      profile = %{"verylow" => -100, "low" => -50, "normal" => 0, "high" => 50, "veryhigh" => 100}
      attrs = Map.put(@valid_attrs, :priority_profile, profile)

      {:ok, config} = Settings.create_download_client_config(attrs)
      assert config.priority_profile == profile

      reloaded = Repo.get!(DownloadClientConfig, config.id)
      assert reloaded.priority_profile == profile
    end

    test "incomplete_grace_minutes defaults to 60 when not provided" do
      {:ok, config} = Settings.create_download_client_config(@valid_attrs)
      assert config.incomplete_grace_minutes == 60
    end

    test "incomplete_grace_minutes accepts a positive integer" do
      attrs = Map.put(@valid_attrs, :incomplete_grace_minutes, 30)
      {:ok, config} = Settings.create_download_client_config(attrs)
      assert config.incomplete_grace_minutes == 30
    end

    test "incomplete_grace_minutes: -1 fails validation" do
      attrs = Map.put(@valid_attrs, :incomplete_grace_minutes, -1)

      assert {:error, changeset} = Settings.create_download_client_config(attrs)
      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).incomplete_grace_minutes
    end

    test "incomplete_grace_minutes: 0 fails validation" do
      attrs = Map.put(@valid_attrs, :incomplete_grace_minutes, 0)

      assert {:error, changeset} = Settings.create_download_client_config(attrs)
      refute changeset.valid?
      assert "must be greater than 0" in errors_on(changeset).incomplete_grace_minutes
    end

    test "categories and priority_profile default to empty maps" do
      {:ok, config} = Settings.create_download_client_config(@valid_attrs)
      assert config.categories == %{}
      assert config.priority_profile == %{}
    end

    test "existing :category field still works alongside :categories map" do
      attrs =
        @valid_attrs
        |> Map.put(:category, "legacy-cat")
        |> Map.put(:categories, %{"movie" => "movies"})

      {:ok, config} = Settings.create_download_client_config(attrs)
      assert config.category == "legacy-cat"
      assert config.categories == %{"movie" => "movies"}
    end

    test "priority_profile with all 5 taxonomy keys is accepted" do
      profile = %{
        "verylow" => "-100",
        "low" => "-1",
        "normal" => "0",
        "high" => "1",
        "veryhigh" => "2"
      }

      attrs = Map.put(@valid_attrs, :priority_profile, profile)
      assert {:ok, config} = Settings.create_download_client_config(attrs)
      assert config.priority_profile == profile
    end

    test "priority_profile with unknown key is rejected" do
      profile = %{"high" => "1", "turbo" => "9"}
      attrs = Map.put(@valid_attrs, :priority_profile, profile)

      changeset = DownloadClientConfig.changeset(%DownloadClientConfig{}, attrs)
      refute changeset.valid?

      [msg | _] = errors_on(changeset).priority_profile
      assert msg =~ "unknown priority key"
      assert msg =~ "turbo"
    end

    test "priority_profile that is not a map is rejected" do
      attrs = Map.put(@valid_attrs, :priority_profile, "not-a-map")
      changeset = DownloadClientConfig.changeset(%DownloadClientConfig{}, attrs)
      refute changeset.valid?
    end
  end

  describe "debrid client validation" do
    @debrid_attrs %{
      name: "my-rd",
      type: :debrid,
      enabled: true,
      priority: 1,
      api_key: "rd-token-123",
      connection_settings: %{"provider" => "real_debrid"}
    }

    test "valid debrid config (api_key + connection_settings.provider) is accepted" do
      assert {:ok, config} = Settings.create_download_client_config(@debrid_attrs)
      assert config.type == :debrid
      assert config.api_key == "rd-token-123"
      assert config.connection_settings == %{"provider" => "real_debrid"}
    end

    test "host and port are not required for debrid (and not rejected if provided)" do
      attrs = Map.merge(@debrid_attrs, %{host: "ignored", port: 9999})
      assert {:ok, config} = Settings.create_download_client_config(attrs)
      assert config.host == "ignored"
      assert config.port == 9999
    end

    test "incomplete_grace_minutes defaults to 1440 for debrid when not provided" do
      assert {:ok, config} = Settings.create_download_client_config(@debrid_attrs)
      assert config.incomplete_grace_minutes == 1440
    end

    test "explicit incomplete_grace_minutes is preserved for debrid" do
      attrs = Map.put(@debrid_attrs, :incomplete_grace_minutes, 60)
      assert {:ok, config} = Settings.create_download_client_config(attrs)
      assert config.incomplete_grace_minutes == 60
    end

    test "missing api_key produces a blank error" do
      attrs = Map.delete(@debrid_attrs, :api_key)

      assert {:error, changeset} = Settings.create_download_client_config(attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).api_key
    end

    test "missing connection_settings.provider produces an error naming the valid choices" do
      attrs = Map.put(@debrid_attrs, :connection_settings, %{})

      assert {:error, changeset} = Settings.create_download_client_config(attrs)
      refute changeset.valid?

      [msg | _] = errors_on(changeset).connection_settings
      assert msg =~ "provider"
      assert msg =~ "real_debrid"
      assert msg =~ "all_debrid"
      assert msg =~ "premiumize"
      assert msg =~ "tor_box"
    end

    test "unknown provider value is rejected" do
      attrs = Map.put(@debrid_attrs, :connection_settings, %{"provider" => "unknown"})

      assert {:error, changeset} = Settings.create_download_client_config(attrs)
      refute changeset.valid?

      [msg | _] = errors_on(changeset).connection_settings
      assert msg =~ "unknown"
      assert msg =~ "real_debrid"
    end

    test "each of the four valid providers is accepted" do
      for provider <- ["real_debrid", "all_debrid", "premiumize", "tor_box"] do
        attrs =
          @debrid_attrs
          |> Map.put(:name, "my-#{provider}")
          |> Map.put(:connection_settings, %{"provider" => provider})

        assert {:ok, config} = Settings.create_download_client_config(attrs)
        assert config.connection_settings == %{"provider" => provider}
      end
    end

    test "debrid_providers/0 returns the four supported provider strings" do
      assert DownloadClientConfig.debrid_providers() == [
               "real_debrid",
               "all_debrid",
               "premiumize",
               "tor_box"
             ]
    end
  end

  describe "remote_fetch validation" do
    @qbittorrent_attrs %{
      name: "seedbox-qbit",
      type: :qbittorrent,
      host: "seedbox.example.com",
      port: 8080
    }

    defp put_remote_fetch(attrs, remote_fetch) do
      Map.put(attrs, :connection_settings, %{"remote_fetch" => remote_fetch})
    end

    test "remote_fetch absent does not require any fields" do
      changeset = DownloadClientConfig.changeset(%DownloadClientConfig{}, @qbittorrent_attrs)
      assert changeset.valid?
    end

    test "remote_fetch disabled does not require any fields" do
      attrs = put_remote_fetch(@qbittorrent_attrs, %{"enabled" => false})
      changeset = DownloadClientConfig.changeset(%DownloadClientConfig{}, attrs)
      assert changeset.valid?
    end

    # HTML checkboxes submit form params as strings, not real booleans: a
    # checked checkbox sends "true", not true. This mirrors what the admin
    # LiveView form (components.ex) actually posts.
    test "remote_fetch disabled as the string \"false\" does not require any fields" do
      attrs = put_remote_fetch(@qbittorrent_attrs, %{"enabled" => "false"})
      changeset = DownloadClientConfig.changeset(%DownloadClientConfig{}, attrs)
      assert changeset.valid?
    end

    test "remote_fetch enabled as the string \"true\" is validated like the boolean" do
      attrs =
        put_remote_fetch(@qbittorrent_attrs, %{
          "enabled" => "true",
          "host" => "seedbox.example.com",
          "username" => "seeduser",
          "auth_method" => "password",
          "password" => "hunter2"
        })

      assert {:ok, config} = Settings.create_download_client_config(attrs)
      assert config.connection_settings["remote_fetch"]["host"] == "seedbox.example.com"
    end

    test "remote_fetch enabled as the string \"true\" without required fields still errors" do
      attrs = put_remote_fetch(@qbittorrent_attrs, %{"enabled" => "true"})
      changeset = DownloadClientConfig.changeset(%DownloadClientConfig{}, attrs)
      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).connection_settings, &(&1 =~ "host can't be blank"))
    end

    # The admin form always renders the remote_fetch host/username/etc.
    # inputs for these client types once the section exists in the DOM,
    # regardless of whether the operator ever checks "enabled" — an
    # unchecked checkbox is simply omitted from the submitted params. A
    # save of an untouched section must not fail validation just because
    # "enabled" is absent while its sibling (irrelevant, blank) fields are
    # present.
    test "remote_fetch present without an enabled key does not require any fields" do
      attrs =
        put_remote_fetch(@qbittorrent_attrs, %{
          "host" => "",
          "username" => "",
          "auth_method" => "password",
          "password" => ""
        })

      changeset = DownloadClientConfig.changeset(%DownloadClientConfig{}, attrs)
      assert changeset.valid?
    end

    test "valid password-auth remote_fetch config round-trips through the DB" do
      attrs =
        put_remote_fetch(@qbittorrent_attrs, %{
          "enabled" => true,
          "host" => "seedbox.example.com",
          "port" => 22,
          "username" => "seeduser",
          "auth_method" => "password",
          "password" => "hunter2"
        })

      assert {:ok, config} = Settings.create_download_client_config(attrs)
      assert config.connection_settings["remote_fetch"]["host"] == "seedbox.example.com"
      assert config.connection_settings["remote_fetch"]["auth_method"] == "password"
    end

    test "valid ssh_key-auth remote_fetch config round-trips through the DB" do
      attrs =
        @qbittorrent_attrs
        |> Map.put(:name, "seedbox-qbit-key")
        |> put_remote_fetch(%{
          "enabled" => true,
          "host" => "seedbox.example.com",
          "username" => "seeduser",
          "auth_method" => "ssh_key",
          "private_key" =>
            "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----"
        })

      assert {:ok, config} = Settings.create_download_client_config(attrs)
      assert config.connection_settings["remote_fetch"]["auth_method"] == "ssh_key"
    end

    test "remote_fetch enabled on a blackhole client is rejected" do
      attrs = %{
        name: "blackhole-seedbox",
        type: :blackhole,
        connection_settings: %{
          "watch_folder" => "/watch",
          "completed_folder" => "/complete",
          "remote_fetch" => %{
            "enabled" => true,
            "host" => "x",
            "username" => "u",
            "auth_method" => "password",
            "password" => "p"
          }
        }
      }

      changeset = DownloadClientConfig.changeset(%DownloadClientConfig{}, attrs)
      refute changeset.valid?
      assert [msg] = errors_on(changeset).connection_settings
      assert msg =~ "only supported for"
    end

    test "remote_fetch enabled on a debrid client is rejected" do
      attrs = %{
        name: "debrid-seedbox",
        type: :debrid,
        api_key: "key",
        connection_settings: %{
          "provider" => "real_debrid",
          "remote_fetch" => %{
            "enabled" => true,
            "host" => "x",
            "username" => "u",
            "auth_method" => "password",
            "password" => "p"
          }
        }
      }

      changeset = DownloadClientConfig.changeset(%DownloadClientConfig{}, attrs)
      refute changeset.valid?
      assert [msg] = errors_on(changeset).connection_settings
      assert msg =~ "only supported for"
    end

    test "missing remote_fetch.host produces an error" do
      attrs =
        put_remote_fetch(@qbittorrent_attrs, %{
          "enabled" => true,
          "username" => "seeduser",
          "auth_method" => "password",
          "password" => "hunter2"
        })

      changeset = DownloadClientConfig.changeset(%DownloadClientConfig{}, attrs)
      refute changeset.valid?
      assert Enum.any?(errors_on(changeset).connection_settings, &(&1 =~ "host can't be blank"))
    end

    test "missing remote_fetch.username produces an error" do
      attrs =
        put_remote_fetch(@qbittorrent_attrs, %{
          "enabled" => true,
          "host" => "seedbox.example.com",
          "auth_method" => "password",
          "password" => "hunter2"
        })

      changeset = DownloadClientConfig.changeset(%DownloadClientConfig{}, attrs)
      refute changeset.valid?

      assert Enum.any?(
               errors_on(changeset).connection_settings,
               &(&1 =~ "username can't be blank")
             )
    end

    test "password auth_method without a password produces an error" do
      attrs =
        put_remote_fetch(@qbittorrent_attrs, %{
          "enabled" => true,
          "host" => "seedbox.example.com",
          "username" => "seeduser",
          "auth_method" => "password"
        })

      changeset = DownloadClientConfig.changeset(%DownloadClientConfig{}, attrs)
      refute changeset.valid?

      assert Enum.any?(
               errors_on(changeset).connection_settings,
               &(&1 =~ "password can't be blank")
             )
    end

    test "ssh_key auth_method without a private_key produces an error" do
      attrs =
        put_remote_fetch(@qbittorrent_attrs, %{
          "enabled" => true,
          "host" => "seedbox.example.com",
          "username" => "seeduser",
          "auth_method" => "ssh_key"
        })

      changeset = DownloadClientConfig.changeset(%DownloadClientConfig{}, attrs)
      refute changeset.valid?

      assert Enum.any?(
               errors_on(changeset).connection_settings,
               &(&1 =~ "private_key can't be blank")
             )
    end

    test "unknown auth_method value is rejected" do
      attrs =
        put_remote_fetch(@qbittorrent_attrs, %{
          "enabled" => true,
          "host" => "seedbox.example.com",
          "username" => "seeduser",
          "auth_method" => "carrier_pigeon"
        })

      changeset = DownloadClientConfig.changeset(%DownloadClientConfig{}, attrs)
      refute changeset.valid?

      assert Enum.any?(
               errors_on(changeset).connection_settings,
               &(&1 =~ "auth_method must be one of")
             )
    end

    test "remote_fetch_auth_methods/0 returns the two supported auth methods" do
      assert DownloadClientConfig.remote_fetch_auth_methods() == ["password", "ssh_key"]
    end
  end

  describe "external_torrents" do
    defp base_attrs(overrides \\ %{}) do
      Map.merge(
        %{
          name: "qbit-#{System.unique_integer([:positive])}",
          type: :qbittorrent,
          host: "localhost",
          port: 8080
        },
        overrides
      )
    end

    test "defaults to :auto" do
      changeset = DownloadClientConfig.changeset(%DownloadClientConfig{}, base_attrs())

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :external_torrents) == :auto
    end

    test "accepts every mode for a qbittorrent client" do
      for mode <- [:auto, :adopt, :category_only, :ignore] do
        changeset =
          DownloadClientConfig.changeset(
            %DownloadClientConfig{},
            base_attrs(%{external_torrents: mode})
          )

        assert changeset.valid?, "expected #{mode} to be valid"
        assert Ecto.Changeset.get_field(changeset, :external_torrents) == mode
      end
    end

    test "rejects category_only for rqbit, which has no categories" do
      changeset =
        DownloadClientConfig.changeset(
          %DownloadClientConfig{},
          base_attrs(%{type: :rqbit, external_torrents: :category_only})
        )

      refute changeset.valid?
      assert %{external_torrents: [message]} = errors_on(changeset)
      assert message =~ "rqbit"
    end

    test "accepts adopt and ignore for rqbit" do
      for mode <- [:auto, :adopt, :ignore] do
        changeset =
          DownloadClientConfig.changeset(
            %DownloadClientConfig{},
            base_attrs(%{type: :rqbit, external_torrents: mode})
          )

        assert changeset.valid?, "expected #{mode} to be valid for rqbit"
      end
    end
  end
end
