defmodule Mydia.Repo.Migrations.BackfillPlexLinksSeededAt do
  use Ecto.Migration
  import Ecto.Query

  @moduledoc """
  Stamps `connection_settings["plex_links_seeded_at"]` on Plex servers that
  already have user mappings.

  The watched-sync scheduler uses that key to tell a Plex server nobody has ever
  seeded from one whose mappings the operator paused or deleted, and re-seeds
  only the first. `Mydia.Jobs.PlexLinkSeed` writes it, so without this backfill
  every server seeded before this release carries no stamp: on those installs,
  deleting every mapping still had the scheduler recreate them on the next tick,
  which is the behaviour the key was added to stop. Nothing writes the stamp
  until something happens to save that config, so it would stay broken.

  Having at least one mapping is the evidence a pass already ran. A Plex server
  with no mappings at all is left alone, because it may genuinely never have
  been seeded and should still be filled in automatically.

  `connection_settings` is a text column holding JSON (`Mydia.Settings.JsonMapType`)
  on both SQLite and PostgreSQL, so this reads, decodes, merges and writes back
  in Elixir rather than reaching for either adapter's JSON functions.
  """

  @key "plex_links_seeded_at"

  def up, do: backfill()

  # Irreversible by design. Removing the key would put every install back to
  # re-seeding servers whose mappings were deliberately removed, and there is no
  # way to tell a stamp this migration wrote from one PlexLinkSeed wrote after.
  def down, do: :ok

  @doc false
  def backfill do
    linked = MapSet.new(linked_config_ids())
    stamped_at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    plex_configs()
    |> Enum.filter(fn {id, _settings} -> MapSet.member?(linked, id) end)
    |> Enum.each(fn {id, raw} -> stamp(id, raw, stamped_at) end)

    :ok
  end

  defp linked_config_ids do
    from(l in "media_server_user_links",
      distinct: true,
      select: type(l.media_server_config_id, :binary_id)
    )
    |> query_repo().all()
  end

  # Every Plex config, filtered in Elixir against the id set above. Media server
  # rows number in the handful, and an `IN` over a binary_id list needs an
  # explicit cast on PostgreSQL that buys nothing at this size.
  defp plex_configs do
    from(c in "media_server_configs",
      where: c.type == "plex",
      select: {type(c.id, :binary_id), c.connection_settings}
    )
    |> query_repo().all()
  end

  defp stamp(id, raw, stamped_at) do
    settings = decode(raw)

    # An install that already ran a post-upgrade seed has the real timestamp.
    # Overwriting it with "now" would be a lie, and it changes nothing.
    unless Map.has_key?(settings, @key) do
      encoded = Jason.encode!(Map.put(settings, @key, stamped_at))

      query_repo().update_all(
        from(c in "media_server_configs", where: c.id == type(^id, :binary_id)),
        set: [connection_settings: encoded]
      )
    end
  end

  # A schemaless select returns the raw column, so the JsonMapType round trip
  # has to happen here. Anything unreadable is treated as empty rather than
  # crashing the migration: the worst case is a stamp on top of settings that
  # could not be parsed anyway.
  defp decode(nil), do: %{}
  defp decode(""), do: %{}

  defp decode(raw) when is_binary(raw) do
    case Jason.decode(raw) do
      {:ok, %{} = map} -> map
      _ -> %{}
    end
  end

  defp decode(%{} = map), do: map
  defp decode(_raw), do: %{}

  # `repo/0` from Ecto.Migration only works inside a migration runner. Tests
  # call `backfill/0` directly, so fall back to Mydia.Repo outside that context.
  defp query_repo do
    case Process.get(:ecto_migration) do
      %{runner: _} -> repo()
      _ -> Mydia.Repo
    end
  end
end
