defmodule Mydia.Repo.Migrations.MigratePlexToPlugin do
  use Ecto.Migration
  import Ecto.Query

  @moduledoc """
  Moves every native Plex server into an instance of the bundled `plex` plugin.

  For each `media_server_configs` row with `type = 'plex'` it writes:

    * a `plugin_instances` row carrying the name, enabled flag, URL and sync
      settings, with the URL and every advertised connection as approved
      endpoints;
    * an `owner` account link holding the plex.tv account token, and an
      `endpoint` link holding the server access token when that differs;
    * one `user` link per `media_server_user_links` row;
    * the store entries the plugin reads: per-item sync state keyed by Plex
      rating key (joined through `remote_item_mappings`), each user's pull
      cursor, `uses_owner` for the no-Home fallback link, and `server/info`
      with the advertised connections, so its first run is incremental and
      does not re-push old unwatches;

  and it rewrites the server's `sync_runs` onto the instance. Then it deletes
  the native rows. The mapping cache is not carried over: the plugin re-crawls
  it on its first run.

  Only table names and schemaless queries are used, so later changes to any
  schema module cannot change what this migration does.
  """

  @slug "plex"

  def up, do: migrate()

  # Irreversible. The native Plex code this would restore rows for is gone.
  def down, do: :ok

  @doc false
  def migrate do
    case plex_configs() do
      [] ->
        :ok

      configs ->
        ensure_plugin_config()
        Enum.each(configs, &migrate_config/1)
        :ok
    end
  end

  defp plex_configs do
    from(c in "media_server_configs",
      where: c.type == "plex",
      select: %{
        id: type(c.id, :binary_id),
        name: c.name,
        enabled: type(c.enabled, :boolean),
        url: c.url,
        token: c.token,
        server_access_token: c.server_access_token,
        machine_identifier: c.machine_identifier,
        connection_settings: c.connection_settings,
        connections: c.connections
      }
    )
    |> query_repo().all()
  end

  # `ensure_bundled/0` runs after migrations. A row that already exists with
  # `source_url: "bundled"` is reconciled there (manifest and grant replaced,
  # `enabled` kept), so this only has to exist and be enabled. An existing row
  # is left exactly as it is, disabled or not: `ensure_bundled/0` owns enablement.
  defp ensure_plugin_config do
    existing =
      from(p in "plugin_configs", where: p.slug == ^@slug, select: type(p.id, :binary_id))
      |> query_repo().one()

    case existing do
      nil ->
        id = Ecto.UUID.generate()
        now = now_seconds()

        query_repo().insert_all("plugin_configs", [
          %{
            id: uuid(id),
            slug: @slug,
            name: "Plex",
            settings: Jason.encode!(%{"delivery" => "durable"}),
            granted_capabilities: Jason.encode!(%{}),
            source_url: "bundled",
            inserted_at: now,
            updated_at: now
          }
        ])

        # The column defaults to false, and a schemaless boolean insert is
        # stored as the text "true" on SQLite, so set it through a typed update.
        set_enabled("plugin_configs", id, true)

        id

      id ->
        id
    end
  end

  defp migrate_config(config) do
    plugin_config_id = ensure_plugin_config()
    instance_id = Ecto.UUID.generate()
    # media_server_user_links is unique per (config, user) and (config, remote
    # account), so these links cannot collide in plugin_account_links; the
    # inserts still use on_conflict: :nothing so a boot never fails on it.
    links = native_links(config.id)
    now = now_usec()

    query_repo().insert_all("plugin_instances", [
      %{
        id: uuid(instance_id),
        plugin_config_id: uuid(plugin_config_id),
        plugin_slug: @slug,
        name: config.name,
        settings: Jason.encode!(instance_settings(config)),
        approved_endpoints: Jason.encode!(endpoints(config)),
        remote_accounts: Jason.encode!(remote_accounts(links)),
        schedule_failures: 0,
        inserted_at: now,
        updated_at: now
      }
    ])

    # `enabled` defaults to true; only a disabled server needs the typed update.
    if config.enabled == false, do: set_enabled("plugin_instances", instance_id, false)

    insert_credentials(config, instance_id, now)
    new_links = insert_user_links(links, instance_id, now)

    (server_info_rows(config) ++
       uses_owner_rows(new_links) ++
       state_rows(config.id, new_links) ++
       pull_cursor_rows(config.id, new_links))
    |> Enum.map(&finish_kv_row(&1, instance_id, plugin_config_id, now))
    |> Enum.chunk_every(500)
    |> Enum.each(&query_repo().insert_all("plugin_kv", &1, on_conflict: :nothing))

    move_sync_runs(config.id, instance_id)
    delete_native(config.id)
  end

  defp instance_settings(config) do
    settings = decode(config.connection_settings, %{})

    %{
      "sync_watched" =>
        if(Map.get(settings, "sync_watched") in [true, "true"], do: "on", else: "off"),
      "sync_watched_direction" =>
        case Map.get(settings, "sync_watched_direction") do
          dir when dir in ["import", "export"] -> dir
          _ -> "bidirectional"
        end
    }
    |> maybe_put("url", present(config.url))
  end

  defp endpoints(config) do
    [config.url | connection_uris(config)]
    |> Enum.flat_map(&endpoint/1)
    |> Enum.uniq()
  end

  defp connection_uris(config) do
    config.connections
    |> decode([])
    |> Enum.flat_map(fn
      %{"uri" => uri} when is_binary(uri) and uri != "" -> [String.trim(uri)]
      _ -> []
    end)
  end

  defp endpoint(uri) when is_binary(uri) do
    case URI.parse(String.trim(uri)) do
      %URI{scheme: scheme, host: host, port: port}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        # Lower-cased like Instances.approve_endpoints/2 stores them.
        [%{"scheme" => scheme, "host" => String.downcase(host), "port" => port}]

      _ ->
        []
    end
  end

  defp endpoint(_), do: []

  defp native_links(config_id) do
    from(l in "media_server_user_links",
      where: l.media_server_config_id == type(^config_id, :binary_id),
      select: %{
        user_id: type(l.user_id, :binary_id),
        remote_user_id: l.remote_user_id,
        remote_username: l.remote_username,
        access_token: l.access_token,
        enabled: type(l.enabled, :boolean)
      }
    )
    |> query_repo().all()
  end

  defp remote_accounts(links) do
    links
    |> Enum.filter(&is_binary(&1.remote_user_id))
    |> Enum.map(&%{"id" => &1.remote_user_id, "name" => &1.remote_username, "admin" => false})
  end

  defp insert_credentials(config, instance_id, now) do
    owner = present(config.token)
    endpoint = present(config.server_access_token)

    rows =
      [
        owner && credential_row(:owner, owner),
        endpoint && endpoint != owner && credential_row(:endpoint, endpoint)
      ]
      |> Enum.filter(& &1)
      |> Enum.map(&link_row(&1, instance_id, now))

    if rows != [],
      do: query_repo().insert_all("plugin_account_links", rows, on_conflict: :nothing)
  end

  defp credential_row(role, token) do
    %{
      role: Atom.to_string(role),
      source: "setup",
      user_id: nil,
      external_user_id: nil,
      external_username: nil,
      access_token: token,
      status: "active"
    }
  end

  # Returns one %{user_id, link_id, owner_fallback?} per native link, so store
  # entries can follow their user.
  defp insert_user_links(links, instance_id, now) do
    Enum.map(links, fn link ->
      id = Ecto.UUID.generate()

      row =
        link_row(
          %{
            id: id,
            role: "user",
            source: "admin_mapped",
            user_id: link.user_id,
            external_user_id: link.remote_user_id,
            external_username: link.remote_username,
            access_token: link.access_token,
            status: if(link.enabled == false, do: "disabled", else: "active")
          },
          instance_id,
          now
        )

      query_repo().insert_all("plugin_account_links", [row], on_conflict: :nothing)

      # Native Plex's no-Home fallback wrote a link naming no remote account
      # and carrying the admin token. The plugin expresses that as a user link
      # flagged to sync through the owner credential.
      %{user_id: link.user_id, link_id: id, owner_fallback?: is_nil(link.remote_user_id)}
    end)
  end

  # plugin_account_links carries no plugin_config_id; the instance
  # row holds that reference.
  defp link_row(attrs, instance_id, now) do
    %{
      id: uuid(Map.get(attrs, :id) || Ecto.UUID.generate()),
      instance_id: uuid(instance_id),
      plugin_slug: @slug,
      user_id: attrs.user_id && uuid(attrs.user_id),
      role: attrs.role,
      source: attrs.source,
      external_user_id: attrs.external_user_id,
      external_username: attrs.external_username,
      access_token: attrs.access_token,
      status: attrs.status,
      last_error: nil,
      meta: Jason.encode!(%{}),
      inserted_at: now,
      updated_at: now
    }
  end

  # `server/info` is where the plugin keeps the chosen server's addresses
  # (`endpoint::ServerInfo`). A server that was set up through plex.tv sign-in
  # often has no typed url at all and resolves purely from these, so without
  # them the migrated instance could not find its server.
  defp server_info_rows(config) do
    case connection_uris(config) do
      [] ->
        []

      candidates ->
        info = %{
          "machine_identifier" => present(config.machine_identifier),
          "name" => config.name,
          "candidates" => candidates
        }

        [kv_row("server/info", Jason.encode!(info))]
    end
  end

  defp uses_owner_rows(new_links) do
    for %{owner_fallback?: true, link_id: link_id} <- new_links,
        do: kv_row("link/#{link_id}/uses_owner", "1")
  end

  # Per-item state is keyed by the Plex rating key (remote_item_mappings.remote_id),
  # the one identity an item has on both sides. A state with no mapping row has
  # no rating key to live under and is dropped; the plugin's baseline rule
  # treats that item as never synced, which never pushes or pulls an unwatch.
  defp state_rows(config_id, new_links) do
    link_ids = Map.new(new_links, &{&1.user_id, &1.link_id})

    from(s in "watch_sync_states",
      join: m in "remote_item_mappings",
      on:
        m.provider == s.provider and m.provider_instance_id == s.provider_instance_id and
          ((not is_nil(s.episode_id) and m.episode_id == s.episode_id) or
             (is_nil(s.episode_id) and is_nil(m.episode_id) and
                m.media_item_id == s.media_item_id)),
      where:
        s.provider == "plex" and s.provider_instance_id == ^config_id and
          not is_nil(s.synced_at),
      select: %{
        user_id: type(s.user_id, :binary_id),
        rating_key: m.remote_id,
        watched: type(s.synced_watched, :boolean),
        position: s.synced_position_seconds,
        synced_at: type(s.synced_at, :utc_datetime),
        remote_last_watched_at: type(s.remote_last_watched_at, :utc_datetime)
      }
    )
    |> query_repo().all()
    |> newest_per_key(link_ids)
    |> Enum.flat_map(fn state ->
      case Map.fetch(link_ids, state.user_id) do
        {:ok, link_id} ->
          value = %{
            "watched" => state.watched == true,
            "position" => state.position,
            "synced_at" => iso(state.synced_at),
            "remote_last_watched_at" => iso(state.remote_last_watched_at)
          }

          [kv_row("link/#{link_id}/state/#{state.rating_key}", Jason.encode!(value))]

        :error ->
          []
      end
    end)
  end

  # remote_item_mappings.remote_id is not unique, so two local items (or two
  # mapping rows) can land on one rating key for a user. The store is unique on
  # the key: keep the newest state (synced_at is never NULL here).
  defp newest_per_key(states, link_ids) do
    states
    |> Enum.filter(&Map.has_key?(link_ids, &1.user_id))
    |> Enum.group_by(&{&1.user_id, &1.rating_key})
    |> Enum.map(fn {_key, group} -> Enum.max_by(group, & &1.synced_at, DateTime) end)
  end

  # The native engine's cursor is the newest synced_at for the user on this
  # server minus a 900 s overlap. Only the newest synced_at is stored here: the
  # guest applies the overlap when it reads the cursor. Computed over every
  # state row, mapped or not. No push cursor is written: the plugin's first tick
  # treats every local row as new, which the migrated snapshots make safe.
  defp pull_cursor_rows(config_id, new_links) do
    link_ids = Map.new(new_links, &{&1.user_id, &1.link_id})

    from(s in "watch_sync_states",
      where: s.provider == "plex" and s.provider_instance_id == ^config_id,
      group_by: s.user_id,
      select: {type(s.user_id, :binary_id), type(max(s.synced_at), :utc_datetime)}
    )
    |> query_repo().all()
    |> Enum.flat_map(fn
      {_user_id, nil} ->
        []

      {user_id, latest} ->
        case Map.fetch(link_ids, user_id) do
          {:ok, link_id} ->
            # The guest subtracts its own 900 s overlap on read; do not double it.
            cursor = DateTime.to_unix(latest)
            [kv_row("link/#{link_id}/cursor/pull", Integer.to_string(cursor))]

          :error ->
            []
        end
    end)
  end

  defp kv_row(key, value), do: %{key: key, value: value}

  # plugin_kv keeps its original NOT NULL plugin_config_id next to the
  # instance_id added by the contract 1.4 migration, and is unique on (instance_id, key).
  defp finish_kv_row(row, instance_id, plugin_config_id, now) do
    Map.merge(row, %{
      id: uuid(Ecto.UUID.generate()),
      plugin_config_id: uuid(plugin_config_id),
      instance_id: uuid(instance_id),
      plugin_slug: @slug,
      inserted_at: now,
      updated_at: now
    })
  end

  defp move_sync_runs(config_id, instance_id) do
    from(r in "sync_runs", where: r.provider == "plex" and r.provider_instance_id == ^config_id)
    |> query_repo().update_all(
      set: [provider: "plugin:#{@slug}", provider_instance_id: instance_id]
    )
  end

  defp delete_native(config_id) do
    for table <- ["remote_item_mappings", "watch_sync_states"] do
      from(r in table, where: r.provider == "plex" and r.provider_instance_id == ^config_id)
      |> query_repo().delete_all()
    end

    from(l in "media_server_user_links",
      where: l.media_server_config_id == type(^config_id, :binary_id)
    )
    |> query_repo().delete_all()

    from(c in "media_server_configs", where: c.id == type(^config_id, :binary_id))
    |> query_repo().delete_all()
  end

  # Ecto.Migration.Helpers.postgres?/0 needs a migration runner; tests call
  # migrate/0 directly, so ask the repo we actually query.
  defp set_enabled(table, id, value) do
    from(r in table,
      where: r.id == type(^id, :binary_id),
      update: [set: [enabled: type(^value, :boolean)]]
    )
    |> query_repo().update_all([])
  end

  defp uuid(id), do: if(postgres?(), do: Ecto.UUID.dump!(id), else: id)

  defp postgres?, do: query_repo().__adapter__() == Ecto.Adapters.Postgres

  defp now_usec, do: NaiveDateTime.utc_now()
  defp now_seconds, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: dt |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp present(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp present(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # A schemaless select returns the raw text column, so the JSON round trip
  # happens here. Anything unreadable becomes the empty default rather than
  # crashing the migration.
  defp decode(nil, default), do: default
  defp decode("", default), do: default

  defp decode(raw, default) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, value} when is_map(value) and is_map(default) -> value
      {:ok, value} when is_list(value) and is_list(default) -> value
      _ -> default
    end
  end

  defp decode(value, default) when is_map(value) and is_map(default), do: value
  defp decode(value, default) when is_list(value) and is_list(default), do: value
  defp decode(_value, default), do: default

  # `repo/0` from Ecto.Migration only works inside a migration runner. Tests
  # call `migrate/0` directly, so fall back to Mydia.Repo outside that context.
  defp query_repo do
    case Process.get(:ecto_migration) do
      %{runner: _} -> repo()
      _ -> Mydia.Repo
    end
  end
end
