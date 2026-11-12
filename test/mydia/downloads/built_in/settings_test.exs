defmodule Mydia.Downloads.BuiltIn.SettingsTest do
  use Mydia.DataCase, async: true

  import Mydia.DownloadsFixtures

  alias Mydia.Config.Schema.BuiltInTorrent
  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.BuiltIn.Config
  alias Mydia.Downloads.BuiltIn.Settings
  alias Mydia.Settings, as: AppSettings

  @no_env &__MODULE__.no_env/1
  @ok_reload &__MODULE__.ok_reload/0

  def no_env(_name), do: nil
  def ok_reload, do: {:ok, :reloaded}

  defp row(field), do: AppSettings.get_config_setting_by_key("built_in_torrent.#{field}")

  defp put_row(field, value) do
    {:ok, _} =
      AppSettings.upsert_config_setting(%{
        key: "built_in_torrent.#{field}",
        value: value,
        category: :built_in_torrent
      })
  end

  defp changeset(params, current \\ %BuiltInTorrent{}) do
    Settings.form_changeset(params, current, getenv: @no_env)
  end

  defp vpn(extra) do
    Map.merge(
      %{"vpn_enabled" => "true", "vpn_provider" => "mullvad", "vpn_type" => "openvpn"},
      extra
    )
  end

  defp creds, do: %{"vpn_openvpn_user" => "u", "vpn_openvpn_password" => "p"}

  describe "form_changeset/3" do
    test "accepts a provider with a supported type" do
      cs = changeset(vpn(creds()))
      assert cs.valid?
      assert cs.action == :validate
    end

    test "rejects a type the provider lacks" do
      cs =
        changeset(
          vpn(%{
            "vpn_provider" => "private internet access",
            "vpn_type" => "wireguard",
            "vpn_wireguard_private_key" => "k",
            "vpn_wireguard_addresses" => "10.0.0.2/32"
          })
        )

      assert Keyword.has_key?(cs.errors, :vpn_type)
    end

    test "rejects an unknown provider" do
      cs = changeset(vpn(%{"vpn_provider" => "nopevpn"}))
      assert Keyword.has_key?(cs.errors, :vpn_provider)
    end

    test "rejects port forwarding on a provider without it" do
      cs = changeset(vpn(Map.put(creds(), "vpn_port_forwarding", "true")))
      assert Keyword.has_key?(cs.errors, :vpn_port_forwarding)
    end

    test "allows port forwarding where supported" do
      cs =
        changeset(
          vpn(
            Map.merge(creds(), %{
              "vpn_provider" => "protonvpn",
              "vpn_port_forwarding" => "true"
            })
          )
        )

      assert cs.valid?
    end

    test "rejects a newline in any value" do
      cs = changeset(vpn(%{"vpn_openvpn_user" => "u", "vpn_openvpn_password" => "a\nb"}))
      assert Keyword.has_key?(cs.errors, :vpn_openvpn_password)

      cs = changeset(%{"vpn_server_cities" => "Oslo\rBerlin"})
      assert Keyword.has_key?(cs.errors, :vpn_server_cities)
    end

    test "openvpn needs a user and password when the VPN is on" do
      cs = changeset(vpn(%{}))
      assert Keyword.has_key?(cs.errors, :vpn_openvpn_user)
      assert Keyword.has_key?(cs.errors, :vpn_openvpn_password)
    end

    test "a saved password satisfies the password requirement" do
      put_row("vpn_openvpn_password", "saved")
      cs = changeset(vpn(%{"vpn_openvpn_user" => "u", "vpn_openvpn_password" => ""}))
      assert cs.valid?
    end

    test "wireguard needs a private key and addresses" do
      cs = changeset(vpn(%{"vpn_type" => "wireguard"}))
      assert Keyword.has_key?(cs.errors, :vpn_wireguard_private_key)
      assert Keyword.has_key?(cs.errors, :vpn_wireguard_addresses)

      cs =
        changeset(
          vpn(%{
            "vpn_type" => "wireguard",
            "vpn_wireguard_private_key" => "k",
            "vpn_wireguard_addresses" => "10.0.0.2/32"
          })
        )

      assert cs.valid?
    end

    test "providers that take no username skip the credential check" do
      cs = changeset(vpn(%{"vpn_provider" => "airvpn"}))
      refute Keyword.has_key?(cs.errors, :vpn_openvpn_user)
    end

    test "nothing is required while the VPN is off" do
      assert changeset(%{"vpn_enabled" => "false"}).valid?
    end

    test "env-sourced fields are not validated" do
      getenv = fn
        "MYDIA_VPN_SERVICE_PROVIDER" -> "mullvad"
        _ -> nil
      end

      cs =
        Settings.form_changeset(
          %{
            "vpn_provider" => "garbage",
            "vpn_openvpn_user" => "u",
            "vpn_openvpn_password" => "p"
          },
          %BuiltInTorrent{vpn_enabled: true, vpn_provider: "mullvad", vpn_type: "openvpn"},
          getenv: getenv
        )

      assert cs.valid?
    end

    test "rejects out-of-range ports" do
      cs = changeset(%{"listen_port" => "70000"})
      assert Keyword.has_key?(cs.errors, :listen_port)
    end

    test "enabled accepts only automatic, true or false" do
      assert changeset(%{"enabled" => "automatic"}).valid?
      assert changeset(%{"enabled" => "true"}).valid?
      refute changeset(%{"enabled" => "maybe"}).valid?
    end
  end

  describe "save/2" do
    defp save(params, opts \\ []) do
      Settings.save(params, Keyword.merge([getenv: @no_env, reload: @ok_reload], opts))
    end

    test "writes encoded values" do
      assert :ok =
               save(
                 vpn(
                   Map.merge(creds(), %{"listen_port" => "6881", "vpn_server_cities" => "Oslo"})
                 )
               )

      assert row("vpn_enabled").value == "true"
      assert row("vpn_provider").value == "mullvad"
      assert row("listen_port").value == "6881"
      assert row("vpn_server_cities").value == "Oslo"
      assert row("vpn_openvpn_password").value == "p"

      assert {:ok, [:built_in_torrent, :listen_port], 6881} =
               Mydia.Config.Schema.Paths.cast_overlay("built_in_torrent.listen_port", "6881")
    end

    test "records updated_by_id" do
      user = Mydia.AccountsFixtures.user_fixture()
      assert :ok = save(%{"listen_port" => "6881"}, updated_by_id: user.id)
      assert row("listen_port").updated_by_id == user.id
    end

    test "a blank secret keeps the stored value" do
      put_row("vpn_openvpn_password", "keepme")
      assert :ok = save(vpn(%{"vpn_openvpn_user" => "u", "vpn_openvpn_password" => ""}))
      assert row("vpn_openvpn_password").value == "keepme"
    end

    test "an env-locked field gets no row" do
      getenv = fn
        "MYDIA_TORRENT_PORT" -> "7000"
        _ -> nil
      end

      assert :ok = save(%{"listen_port" => "6881", "api_port" => "4000"}, getenv: getenv)
      assert row("listen_port") == nil
      assert row("api_port").value == "4000"
    end

    test "enabled automatic deletes the row" do
      put_row("enabled", "true")
      assert :ok = save(%{"enabled" => "automatic"})
      assert row("enabled") == nil
      assert :ok = save(%{"enabled" => "false"})
      assert row("enabled").value == "false"
    end

    test "a blank text field deletes its row" do
      put_row("vpn_server_cities", "Oslo")
      assert :ok = save(%{"vpn_server_cities" => ""})
      assert row("vpn_server_cities") == nil
    end

    test "an invalid form returns the changeset and writes nothing" do
      assert {:error, %Ecto.Changeset{}} = save(vpn(%{"vpn_provider" => "nopevpn"}))
      assert row("vpn_provider") == nil
    end

    test "a failing reload rolls back every row" do
      assert {:error, %Ecto.Changeset{}} =
               save(%{"listen_port" => "6881", "api_port" => "4000"},
                 reload: fn -> {:error, :boom} end
               )

      assert row("listen_port") == nil
      assert row("api_port") == nil
    end

    test "reload runs once after the writes" do
      parent = self()

      save(%{"listen_port" => "6881"},
        reload: fn ->
          send(parent, {:reloaded, row("listen_port")})
          {:ok, :reloaded}
        end
      )

      assert_received {:reloaded, %{value: "6881"}}
    end
  end

  describe "sources/1" do
    test "reports env, database and default" do
      put_row("api_port", "4000")

      getenv = fn
        "MYDIA_TORRENT_PORT" -> "7000"
        _ -> nil
      end

      sources = Settings.sources(getenv)
      assert sources.listen_port == :env
      assert sources.api_port == :database
      assert sources.download_path == :default
    end
  end

  describe "secret_saved?/1" do
    test "is true only for a non-blank stored value" do
      refute Settings.secret_saved?(:vpn_openvpn_password)
      put_row("vpn_openvpn_password", "x")
      assert Settings.secret_saved?(:vpn_openvpn_password)
    end
  end

  describe "active_download_count/0" do
    test "counts unfinished built-in downloads only" do
      name = BuiltIn.name()
      download_fixture(%{download_client: name})
      download_fixture(%{download_client: name, completed_at: DateTime.utc_now(:second)})
      download_fixture(%{download_client: "other"})

      assert Settings.active_download_count() == 1
    end
  end

  describe "off_reason/1" do
    test "names the cause of an off client" do
      assert Settings.off_reason(%Config{warnings: [{:reserved_name_taken}]}) == :name_taken
      assert Settings.off_reason(%Config{}, @no_env) == :automatic
      assert Settings.off_reason(nil, @no_env) == :automatic

      put_row("enabled", "false")
      assert Settings.off_reason(%Config{}, @no_env) == :ui

      env = fn
        "MYDIA_TORRENT_ENABLED" -> "false"
        _ -> nil
      end

      assert Settings.off_reason(%Config{}, env) == :env
    end
  end
end
