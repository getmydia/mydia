defmodule Mydia.MediaServer.UserLinksTest do
  # DataCase rather than ExUnit.Case: apply_mapping/3 writes media_server_user_links.
  use Mydia.DataCase, async: true

  alias Mydia.MediaServer.UserLinks
  alias Mydia.Settings
  alias Mydia.Settings.MediaServerConfig

  setup do
    %{bypass: Bypass.open(), user: Mydia.AccountsFixtures.user_fixture(%{username: "tonix"})}
  end

  describe "list_remote_accounts/2" do
    test "normalises Jellyfin accounts", %{bypass: bypass} do
      stub_json(bypass, "GET", "/Users", [
        %{"Id" => "guid-1", "Name" => "Tonix"},
        %{"Id" => "guid-2", "Name" => "Kid"}
      ])

      assert {:ok, accounts} = UserLinks.list_remote_accounts(jellyfin_config(bypass))
      assert Enum.map(accounts, & &1.id) == ["guid-1", "guid-2"]
      assert Enum.map(accounts, & &1.name) == ["Tonix", "Kid"]
    end
  end

  describe "apply_mapping/3 on Jellyfin" do
    setup %{bypass: bypass} do
      stub_json(bypass, "GET", "/Users", [
        %{"Id" => "guid-1", "Name" => "Tonix"},
        %{"Id" => "guid-2", "Name" => "Kid"}
      ])

      {:ok, config: jellyfin_config(bypass)}
    end

    test "stores the account GUID and leaves the token nil", %{config: config, user: user} do
      # Jellyfin issues no per-user tokens, so the GUID is the whole identity and
      # a token here could only be another account's.
      assert {:ok, [link]} = UserLinks.apply_mapping(config, %{"guid-1" => user.id})

      assert link.user_id == user.id
      assert link.remote_user_id == "guid-1"
      assert link.remote_username == "Tonix"
      assert is_nil(link.access_token)
    end

    test "refuses to point two accounts at one Mydia user", %{config: config, user: user} do
      assert {:error, :duplicate_user} =
               UserLinks.apply_mapping(config, %{"guid-1" => user.id, "guid-2" => user.id})

      assert Settings.list_media_server_user_links(config.id) == []
    end

    test "an account id the server does not list is ignored", %{config: config, user: user} do
      assert {:ok, []} = UserLinks.apply_mapping(config, %{"guid-forged" => user.id})
      assert Settings.list_media_server_user_links(config.id) == []
    end

    test "swapping two users' accounts is applied, not refused", %{config: config, user: user} do
      other = Mydia.AccountsFixtures.user_fixture(%{username: "kid"})

      assert {:ok, _} =
               UserLinks.apply_mapping(config, %{"guid-1" => user.id, "guid-2" => other.id})

      # The per-row claim guard would read this as a double claim while the rows
      # it is about to overwrite are still there. What has to hold is the final
      # state, and the final state here is fine.
      assert {:ok, _} =
               UserLinks.apply_mapping(config, %{"guid-1" => other.id, "guid-2" => user.id})

      links = Settings.list_media_server_user_links(config.id)
      assert Enum.find(links, &(&1.user_id == user.id)).remote_user_id == "guid-2"
      assert Enum.find(links, &(&1.user_id == other.id)).remote_user_id == "guid-1"
    end
  end

  test "a provider without per-user accounts is refused rather than guessed at",
       %{user: user} do
    config = %MediaServerConfig{id: Ecto.UUID.generate(), name: "Other", type: nil}

    assert {:error, {:unsupported_provider, nil}} =
             UserLinks.apply_mapping(config, %{"x" => user.id})
  end

  defp jellyfin_config(bypass) do
    create_config(%{
      type: :jellyfin,
      url: "http://127.0.0.1:#{bypass.port}",
      token: "api-key"
    })
  end

  defp create_config(attrs) do
    {:ok, config} =
      Settings.create_media_server_config(
        Map.put(attrs, :name, "Server #{System.unique_integer([:positive])}")
      )

    config
  end

  # Req only decodes a body the response declares as JSON.
  defp stub_json(bypass, method, path, body) do
    Bypass.stub(bypass, method, path, fn conn -> json(conn, body) end)
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end
end
