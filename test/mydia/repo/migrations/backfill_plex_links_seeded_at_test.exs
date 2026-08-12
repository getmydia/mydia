defmodule Mydia.Repo.Migrations.BackfillPlexLinksSeededAtTest do
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures

  alias Mydia.Jobs.PlexLinkSeed
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

  defp plex_config(name, settings \\ %{"sync_watched" => true}) do
    {:ok, config} =
      Settings.create_media_server_config(%{
        name: name,
        type: :plex,
        url: "http://localhost:32400",
        token: "tok",
        enabled: true,
        connection_settings: settings
      })

    config
  end

  defp link(config) do
    {:ok, link} =
      Settings.upsert_media_server_user_link(%{
        media_server_config_id: config.id,
        user_id: user_fixture().id,
        remote_user_id: "remote-#{System.unique_integer([:positive])}",
        remote_username: "someone",
        access_token: "user-token",
        enabled: true
      })

    link
  end

  defp reload(config), do: Settings.get_media_server_config!(config.id)

  test "stamps a Plex server that already has mappings" do
    # Having a mapping is the evidence a seeding pass already ran on this
    # install, from before the stamp existed. Without the stamp the scheduler
    # treats the server as never seeded, so deleting every mapping has them all
    # recreated on the next tick.
    config = plex_config("Seeded Before Upgrade")
    _link = link(config)

    refute PlexLinkSeed.seeded_before?(config)

    assert :ok = BackfillPlexLinksSeededAt.backfill()

    stamped = reload(config)
    assert PlexLinkSeed.seeded_before?(stamped)
    # Everything else in the map survives the read-modify-write.
    assert stamped.connection_settings["sync_watched"] == true
  end

  test "leaves a Plex server with no mappings alone" do
    # It may genuinely never have been seeded, and it should still be filled in
    # automatically the first time the scheduler looks at it.
    config = plex_config("Never Seeded")

    assert :ok = BackfillPlexLinksSeededAt.backfill()

    refute PlexLinkSeed.seeded_before?(reload(config))
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

    refute PlexLinkSeed.seeded_before?(reload(config))
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
