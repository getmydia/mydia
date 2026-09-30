defmodule Mydia.Repo.Migrations.MigratePlexToPluginTest do
  # Runs on whichever adapter the suite uses; CI runs it on both. The migration
  # is exercised through its exported migrate/0, because Ecto.Migrator deadlocks
  # against the DataCase sandbox on PostgreSQL.
  use Mydia.DataCase, async: false

  import Ecto.Query
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Plugins.AccountLinks
  alias Mydia.Plugins.Instances
  alias Mydia.Repo
  alias Mydia.Settings
  alias Mydia.Sync

  unless Code.ensure_loaded?(Mydia.Repo.Migrations.MigratePlexToPlugin) do
    Code.require_file("priv/repo/migrations/20260929141855_migrate_plex_to_plugin.exs")
  end

  alias Mydia.Repo.Migrations.MigratePlexToPlugin

  defp uuid(id), do: if(Mydia.DB.postgres?(), do: Ecto.UUID.dump!(id), else: id)
  # A schemaless boolean is stored as the text "true" on SQLite, which the
  # typed read then takes for false. Real rows hold 1/0.
  defp bool(value) when is_boolean(value) do
    cond do
      Mydia.DB.postgres?() -> value
      value -> 1
      true -> 0
    end
  end

  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  # Schemaless on purpose: :plex leaves MediaServerConfig's enum in Task 19, and
  # this test has to keep describing the rows old installs actually hold.
  defp insert_plex_config!(attrs) do
    id = Ecto.UUID.generate()

    row =
      Map.merge(
        %{
          id: uuid(id),
          name: "Glass Orchard Server",
          type: "plex",
          url: "http://192.168.1.20:32400",
          token: "account-token",
          server_access_token: "server-token",
          connection_settings:
            Jason.encode!(%{"sync_watched" => true, "sync_watched_direction" => "import"}),
          connections:
            Jason.encode!([
              %{"uri" => "https://a1b2.plex.direct:32400", "local" => true, "relay" => false}
            ]),
          inserted_at: now(),
          updated_at: now()
        },
        attrs
      )

    Repo.insert_all("media_server_configs", [row])
    id
  end

  defp insert_link!(config_id, user, attrs) do
    id = Ecto.UUID.generate()

    Repo.insert_all("media_server_user_links", [
      Map.merge(
        %{
          id: uuid(id),
          media_server_config_id: uuid(config_id),
          user_id: uuid(user.id),
          remote_user_id: "101",
          remote_username: "harbor_kid",
          access_token: "profile-token",
          inserted_at: now(),
          updated_at: now()
        },
        attrs
      )
    ])

    id
  end

  defp insert_state!(config_id, user, attrs) do
    Repo.insert_all("watch_sync_states", [
      Map.merge(
        %{
          id: uuid(Ecto.UUID.generate()),
          user_id: uuid(user.id),
          provider: "plex",
          provider_instance_id: config_id,
          synced_watched: bool(true),
          synced_position_seconds: nil,
          synced_at: ~N[2026-09-01 12:00:00],
          remote_last_watched_at: ~N[2026-09-01 11:59:00],
          inserted_at: now(),
          updated_at: now()
        },
        attrs
      )
    ])
  end

  defp insert_mapping!(config_id, attrs) do
    Repo.insert_all("remote_item_mappings", [
      Map.merge(
        %{
          id: uuid(Ecto.UUID.generate()),
          provider: "plex",
          provider_instance_id: config_id,
          last_seen_at: now(),
          inserted_at: now(),
          updated_at: now()
        },
        attrs
      )
    ])
  end

  defp kv(instance_id, key) do
    from(k in "plugin_kv",
      where: k.instance_id == type(^instance_id, :binary_id) and k.key == ^key,
      select: k.value
    )
    |> Repo.one()
  end

  defp kv_keys(instance_id) do
    from(k in "plugin_kv",
      where: k.instance_id == type(^instance_id, :binary_id),
      select: k.key
    )
    |> Repo.all()
    |> Enum.sort()
  end

  defp count(table, provider) do
    from(r in table, where: r.provider == ^provider, select: count()) |> Repo.one()
  end

  setup do
    user = user_fixture()
    other = user_fixture()
    movie = media_item_fixture(%{title: "The Glass Orchard", type: "movie"})
    unmapped = media_item_fixture(%{title: "Harbor Lights", type: "movie"})
    config_id = insert_plex_config!(%{})
    _link_id = insert_link!(config_id, user, %{})
    insert_mapping!(config_id, %{media_item_id: uuid(movie.id), remote_id: "5001"})
    insert_state!(config_id, user, %{media_item_id: uuid(movie.id)})
    # A state whose item has no rating key has no key to live under and is
    # dropped, but its synced_at still counts toward the pull cursor.
    insert_state!(config_id, user, %{
      media_item_id: uuid(unmapped.id),
      synced_at: ~N[2026-09-02 08:00:00]
    })

    # A state for a user with no link has nowhere to go and is dropped.
    insert_state!(config_id, other, %{media_item_id: uuid(movie.id)})

    {:ok, run} =
      Sync.start_run(%{provider: "plex", provider_instance_id: config_id, direction: :import})

    {:ok, jellyfin} =
      Settings.create_media_server_config(%{
        name: "Harbor Lights Jellyfin",
        type: :jellyfin,
        url: "http://192.168.1.30:8096",
        token: "api-key"
      })

    %{user: user, movie: movie, config_id: config_id, run: run, jellyfin: jellyfin}
  end

  test "moves a Plex server into a plex plugin instance", ctx do
    :ok = MigratePlexToPlugin.migrate()

    [instance] = Instances.list("plex")
    assert instance.name == "Glass Orchard Server"
    assert instance.enabled

    assert instance.settings == %{
             "url" => "http://192.168.1.20:32400",
             "sync_watched" => "on",
             "sync_watched_direction" => "import"
           }

    assert %{"scheme" => "http", "host" => "192.168.1.20", "port" => 32400} in instance.approved_endpoints

    assert %{"scheme" => "https", "host" => "a1b2.plex.direct", "port" => 32400} in instance.approved_endpoints

    assert instance.remote_accounts == [
             %{"id" => "101", "name" => "harbor_kid", "admin" => false}
           ]

    assert AccountLinks.credential(instance.id, :owner).access_token == "account-token"
    assert AccountLinks.credential(instance.id, :endpoint).access_token == "server-token"

    [link] = Enum.filter(AccountLinks.list(instance.id), &(&1.role == :user))
    assert link.user_id == ctx.user.id
    assert link.external_user_id == "101"
    assert link.external_username == "harbor_kid"
    assert link.access_token == "profile-token"
    assert link.source == :admin_mapped
    assert link.status == :active

    assert Jason.decode!(kv(instance.id, "link/#{link.id}/state/5001")) == %{
             "watched" => true,
             "position" => nil,
             "synced_at" => "2026-09-01T12:00:00Z",
             "remote_last_watched_at" => "2026-09-01T11:59:00Z"
           }

    # The newest synced_at across all of the user's states, mapped or not. Not
    # rewound: the guest applies its own 900 s overlap when it reads the cursor.
    expected_cursor = DateTime.to_unix(~U[2026-09-02 08:00:00Z])
    assert kv(instance.id, "link/#{link.id}/cursor/pull") == Integer.to_string(expected_cursor)

    assert Jason.decode!(kv(instance.id, "server/info")) == %{
             "machine_identifier" => nil,
             "name" => "Glass Orchard Server",
             "candidates" => ["https://a1b2.plex.direct:32400"]
           }

    # Exactly these keys: one state (the unmapped movie and the unlinked
    # user are dropped), one pull cursor, server/info, and no push cursor.
    assert kv_keys(instance.id) ==
             Enum.sort([
               "link/#{link.id}/state/5001",
               "link/#{link.id}/cursor/pull",
               "server/info"
             ])

    assert Sync.last_run("plugin:plex", instance.id).id == ctx.run.id
    assert Sync.last_run("plex", ctx.config_id) == nil
  end

  test "the no-Home owner fallback link syncs through the owner credential", ctx do
    fallback_user = user_fixture()

    _ =
      insert_link!(ctx.config_id, fallback_user, %{
        remote_user_id: nil,
        remote_username: nil,
        access_token: "account-token"
      })

    :ok = MigratePlexToPlugin.migrate()

    [instance] = Instances.list("plex")

    [fallback] =
      instance.id
      |> AccountLinks.list()
      |> Enum.filter(&(&1.role == :user and &1.user_id == fallback_user.id))

    assert fallback.external_user_id == nil
    assert kv(instance.id, "link/#{fallback.id}/uses_owner") == "1"
  end

  test "an episode state maps through the episode's rating key", ctx do
    # episode_fixture/1 creates its own tv_show media item.
    episode = episode_fixture(%{season_number: 1, episode_number: 2})
    insert_mapping!(ctx.config_id, %{episode_id: uuid(episode.id), remote_id: "7702"})

    insert_state!(ctx.config_id, ctx.user, %{
      episode_id: uuid(episode.id),
      synced_watched: bool(false)
    })

    :ok = MigratePlexToPlugin.migrate()

    [instance] = Instances.list("plex")
    [link] = Enum.filter(AccountLinks.list(instance.id), &(&1.role == :user))

    assert %{"watched" => false} = Jason.decode!(kv(instance.id, "link/#{link.id}/state/7702"))
  end

  test "removes the native Plex rows and leaves Jellyfin alone", ctx do
    :ok = MigratePlexToPlugin.migrate()

    assert from(c in "media_server_configs", where: c.type == "plex", select: count())
           |> Repo.one() == 0

    assert count("watch_sync_states", "plex") == 0
    assert count("remote_item_mappings", "plex") == 0
    assert from(l in "media_server_user_links", select: count()) |> Repo.one() == 0
    assert Settings.get_media_server_config!(ctx.jellyfin.id).type == :jellyfin
  end

  test "pre-creates a bundled plex plugin config row" do
    :ok = MigratePlexToPlugin.migrate()

    assert %{source_url: "bundled", enabled: true} = Settings.get_plugin_config_by_slug("plex")
  end

  test "an endpoint credential equal to the account token is not duplicated", ctx do
    Repo.update_all(
      from(c in "media_server_configs", where: c.id == type(^ctx.config_id, :binary_id)),
      set: [server_access_token: "account-token"]
    )

    :ok = MigratePlexToPlugin.migrate()

    [instance] = Instances.list("plex")
    assert AccountLinks.credential(instance.id, :endpoint) == nil
  end

  test "a disabled link keeps its paused status", ctx do
    # Typed: a schemaless boolean literal is stored as text on SQLite.
    Repo.update_all(
      from(l in "media_server_user_links", update: [set: [enabled: type(^false, :boolean)]]),
      []
    )

    :ok = MigratePlexToPlugin.migrate()

    [instance] = Instances.list("plex")
    [link] = Enum.filter(AccountLinks.list(instance.id), &(&1.role == :user))
    assert link.status == :disabled
    assert ctx.user.id == link.user_id
  end

  test "running it twice changes nothing the second time" do
    :ok = MigratePlexToPlugin.migrate()
    :ok = MigratePlexToPlugin.migrate()

    assert length(Instances.list("plex")) == 1
  end

  test "an install without Plex gets no plex plugin row" do
    Repo.delete_all(from(c in "media_server_configs", where: c.type == "plex"))
    :ok = MigratePlexToPlugin.migrate()

    assert Settings.get_plugin_config_by_slug("plex") == nil
    assert Instances.list("plex") == []
  end

  test "ensure_bundled reconciles the pre-created row" do
    :ok = MigratePlexToPlugin.migrate()
    :ok = Mydia.Plugins.ensure_bundled()

    config = Settings.get_plugin_config_by_slug("plex")
    assert config.enabled
    assert config.manifest["slug"] == "plex"
  end
end
