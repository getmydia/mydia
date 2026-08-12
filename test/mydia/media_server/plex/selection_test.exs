defmodule Mydia.MediaServer.Plex.SelectionTest do
  use ExUnit.Case, async: true

  alias Mydia.MediaServer.Plex.Selection
  alias Mydia.Settings.MediaServerConfig

  defp server(name, opts \\ []) do
    %{
      name: name,
      client_identifier: Keyword.get(opts, :id, name),
      machine_identifier: Keyword.get(opts, :id, name),
      access_token: Keyword.get(opts, :access_token, "srv-#{name}"),
      provides: "server",
      owned: Keyword.get(opts, :owned, false),
      presence: Keyword.get(opts, :presence, true),
      connections: Keyword.get(opts, :connections, [%{uri: "http://127.0.0.1:32400"}])
    }
  end

  describe "auto_select/1" do
    test "an empty account is an error, not an empty picker" do
      assert {:error, :no_servers} = Selection.auto_select([])
    end

    test "a single owned server is chosen" do
      s = server("Storage", owned: true)
      assert {:ok, ^s} = Selection.auto_select([s])
    end

    test "a single shared server is chosen, because it is still unambiguous" do
      s = server("Friend's Box", owned: false)
      assert {:ok, ^s} = Selection.auto_select([s])
    end

    test "exactly one owned server wins over any number of shared ones" do
      mine = server("Storage", owned: true)
      theirs = [server("Alice"), server("Bob"), server("Carol")]

      assert {:ok, ^mine} = Selection.auto_select(theirs ++ [mine])
    end

    test "several owned servers are ambiguous" do
      a = server("Attic", owned: true)
      b = server("Basement", owned: true)

      assert {:ambiguous, ranked} = Selection.auto_select([a, b])
      assert length(ranked) == 2
    end

    test "several shared servers with none owned are ambiguous" do
      assert {:ambiguous, ranked} = Selection.auto_select([server("Alice"), server("Bob")])
      assert length(ranked) == 2
    end

    test "the ambiguous list is returned ranked" do
      offline_owned = server("Zeta", owned: true, presence: false)
      online_owned = server("Alpha", owned: true)
      shared = server("Aardvark", owned: false)

      assert {:ambiguous, [first, second, third]} =
               Selection.auto_select([shared, offline_owned, online_owned])

      assert first.name == "Alpha"
      assert second.name == "Zeta"
      assert third.name == "Aardvark"
    end
  end

  describe "rank/1" do
    test "orders owned first, then online, then by name" do
      servers = [
        server("Yak", owned: false, presence: true),
        server("Bison", owned: true, presence: false),
        server("Antelope", owned: true, presence: true),
        server("Zebra", owned: true, presence: true)
      ]

      assert ["Antelope", "Zebra", "Bison", "Yak"] = Enum.map(Selection.rank(servers), & &1.name)
    end
  end

  describe "config_attrs/3" do
    test "builds attrs that leave url nil so discovery stays in charge" do
      now = ~U[2026-08-11 12:00:00Z]
      s = server("Storage", owned: true, id: "machine-1", access_token: "server-token")

      attrs = Selection.config_attrs(s, "account-token", now)

      assert attrs.name == "Storage"
      assert attrs.type == :plex
      assert is_nil(attrs.url)
      assert attrs.token == "account-token"
      assert attrs.machine_identifier == "machine-1"
      assert attrs.server_access_token == "server-token"
      assert attrs.connections == s.connections
      assert attrs.connections_refreshed_at == now
      assert attrs.enabled == true
    end

    test "truncates the timestamp to seconds for :utc_datetime" do
      now = DateTime.from_naive!(~N[2026-08-11 12:00:00.123456], "Etc/UTC")

      attrs = Selection.config_attrs(server("Storage"), "tok", now)

      assert attrs.connections_refreshed_at == ~U[2026-08-11 12:00:00Z]
    end
  end

  describe "merge_discovery/2" do
    defp discovery do
      Selection.config_attrs(
        server("Storage", owned: true),
        "acct-token",
        ~U[2026-08-12 00:00:00Z]
      )
    end

    defp form_params(overrides \\ %{}) do
      Map.merge(%{"name" => "Storage", "type" => "plex", "url" => ""}, overrides)
    end

    test "nil discovery leaves params untouched" do
      params = form_params()
      assert Selection.merge_discovery(params, nil) == params
    end

    test "discovery-owned fields are restored onto form params" do
      merged = Selection.merge_discovery(form_params(), discovery())

      assert merged["machine_identifier"] == "Storage"
      assert merged["server_access_token"] == "srv-Storage"
      assert merged["token"] == "acct-token"
      assert merged["connections_refreshed_at"] == ~U[2026-08-12 00:00:00Z]
      assert [%{uri: "http://127.0.0.1:32400"}] = merged["connections"]
    end

    test "operator edits to form fields win over discovery" do
      merged = Selection.merge_discovery(form_params(%{"name" => "Renamed"}), discovery())

      assert merged["name"] == "Renamed"
    end

    test "the merged map stays entirely string-keyed, because cast/3 rejects mixed keys" do
      merged = Selection.merge_discovery(form_params(), discovery())

      assert Enum.all?(Map.keys(merged), &is_binary/1)
    end

    test "switching the type away from Plex drops discovery entirely" do
      params = form_params(%{"type" => "jellyfin", "url" => "http://box:8096"})

      assert Selection.merge_discovery(params, discovery()) == params
    end

    # The regression this whole change exists to prevent: the wizard leaves url
    # nil on purpose, so without the merge there is nothing left to address the
    # server by and the changeset rejects a config the operator just authorised.
    test "merged params build a valid changeset even with a blank url" do
      merged = Selection.merge_discovery(form_params(), discovery())
      changeset = MediaServerConfig.changeset(%MediaServerConfig{}, merged)

      assert changeset.valid?
    end

    test "the same params without the merge are rejected" do
      changeset = MediaServerConfig.changeset(%MediaServerConfig{}, form_params())

      refute changeset.valid?

      assert {"is required until a Plex server is discovered", _} =
               changeset.errors[:url]
    end
  end
end
