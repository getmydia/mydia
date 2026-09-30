defmodule Mydia.Repo.Migrations.BackfillPlexLinksSeededAtTest do
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures

  alias Mydia.Jobs.MediaServerLinkSeed
  alias Mydia.Settings

  # Migration modules are not compiled into the app (priv/repo/migrations is not
  # in elixirc_paths), so load the file explicitly before referencing it. The
  # backfill is exercised through its exported `backfill/0` rather than
  # Ecto.Migrator, which deadlocks against the DataCase sandbox on PostgreSQL.
  #
  # Guarded because the `test` alias runs `ecto.migrate --quiet` in this same VM
  # first. On a database that still needed this migration that already defined
  # the module, and requiring the file again redefines it with a warning.
  unless Code.ensure_loaded?(Mydia.Repo.Migrations.BackfillPlexLinksSeededAt) do
    Code.require_file("priv/repo/migrations/20260812170000_backfill_plex_links_seeded_at.exs")
  end

  alias Mydia.Repo.Migrations.BackfillPlexLinksSeededAt

  # The migration shipped when Plex was a native type, and `Settings` no longer
  # accepts `type: :plex`, so the legacy rows are inserted schemaless.
  defp uuid(id), do: if(Mydia.DB.postgres?(), do: Ecto.UUID.dump!(id), else: id)
  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  defp plex_config(name, settings \\ %{"sync_watched" => true}) do
    id = Ecto.UUID.generate()

    Mydia.Repo.insert_all("media_server_configs", [
      %{
        id: uuid(id),
        name: name,
        type: "plex",
        url: "http://localhost:32400",
        token: "tok",
        enabled: true,
        connection_settings: Jason.encode!(settings),
        inserted_at: now(),
        updated_at: now()
      }
    ])

    %{id: id}
  end

  defp link(config) do
    Mydia.Repo.insert_all("media_server_user_links", [
      %{
        id: uuid(Ecto.UUID.generate()),
        media_server_config_id: uuid(config.id),
        user_id: uuid(user_fixture().id),
        remote_user_id: "remote-#{System.unique_integer([:positive])}",
        remote_username: "someone",
        access_token: "user-token",
        enabled: true,
        inserted_at: now(),
        updated_at: now()
      }
    ])

    :ok
  end

  defp reload(config) do
    import Ecto.Query

    raw =
      from(c in "media_server_configs",
        where: c.id == type(^config.id, :binary_id),
        select: c.connection_settings
      )
      |> Mydia.Repo.one()

    %{connection_settings: if(is_binary(raw), do: Jason.decode!(raw), else: raw)}
  end

  test "stamps a Plex server that already has mappings" do
    # Having a mapping is the evidence a seeding pass already ran on this
    # install, from before the stamp existed. Without the stamp the scheduler
    # treats the server as never seeded, so deleting every mapping has them all
    # recreated on the next tick.
    config = plex_config("Seeded Before Upgrade")
    _link = link(config)

    refute MediaServerLinkSeed.seeded_before?(reload(config))

    assert :ok = BackfillPlexLinksSeededAt.backfill()

    stamped = reload(config)
    assert MediaServerLinkSeed.seeded_before?(stamped)
    # Everything else in the map survives the read-modify-write.
    assert stamped.connection_settings["sync_watched"] == true
  end

  test "leaves a Plex server with no mappings alone" do
    # It may genuinely never have been seeded, and it should still be filled in
    # automatically the first time the scheduler looks at it.
    config = plex_config("Never Seeded")

    assert :ok = BackfillPlexLinksSeededAt.backfill()

    refute MediaServerLinkSeed.seeded_before?(reload(config))
  end

  test "leaves a Jellyfin server alone even when it has mappings" do
    {:ok, config} =
      Settings.create_media_server_config(%{
        name: "Jelly",
        type: :jellyfin,
        url: "http://localhost:8096",
        token: "api-key",
        enabled: true,
        connection_settings: %{"sync_watched" => true}
      })

    _link = link(config)

    assert :ok = BackfillPlexLinksSeededAt.backfill()

    refute MediaServerLinkSeed.seeded_before?(reload(config))
  end

  test "does not overwrite a stamp a real seeding pass already wrote" do
    config =
      plex_config("Already Stamped", %{
        "sync_watched" => true,
        "plex_links_seeded_at" => "2026-01-01T00:00:00Z"
      })

    _link = link(config)

    assert :ok = BackfillPlexLinksSeededAt.backfill()

    assert reload(config).connection_settings["plex_links_seeded_at"] == "2026-01-01T00:00:00Z"
  end

  test "is safe to run twice" do
    config = plex_config("Idempotent")
    _link = link(config)

    assert :ok = BackfillPlexLinksSeededAt.backfill()
    first = reload(config).connection_settings["plex_links_seeded_at"]

    assert :ok = BackfillPlexLinksSeededAt.backfill()
    assert reload(config).connection_settings["plex_links_seeded_at"] == first
  end
end
