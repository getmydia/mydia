defmodule MydiaWeb.MobileLayoutSeed do
  @moduledoc """
  Data for the mobile layout sweep. Every value is long or unbroken on
  purpose: empty pages render empty-state alerts, which never overflow, so a
  sweep over an empty database proves nothing. All titles are invented.
  """

  import Ecto.Query

  alias Mydia.Downloads.Download

  alias Mydia.{
    AccountsFixtures,
    CollectionsFixtures,
    DownloadsFixtures,
    IndexersFixtures,
    MediaFixtures,
    Repo,
    SettingsFixtures
  }

  @long_movie "The Quiet Harbor of the Fictional Salt Meridian Archipelago: An Extended Edition"
  @long_show "Westmarch Lanterns and the Considerably Longer Fictional Series Title"
  @long_release "The.Quiet.Harbor.S01E01.2160p.WEB-DL.DDP5.1.Atmos.DV.HDR10.H.265-FICTIONALGRP"
  @long_error String.duplicate("The remote client reported a fictional failure. ", 5)
  @long_client "fictional-qbittorrent-seedbox-under-the-salt-meridian-archive-basement"
  @library_root "/fictional-mobile-layout-sweep-library"
  @long_path "/remote/very/long/path/to/the/fictional/downloads/directory/" <> @long_release

  @doc """
  Inserts the awkward data and returns the ids the manifest builds URLs from.

  The collection and the smart collection (the "section") belong to `admin`,
  the user the sweep logs in as, because collections are per user.
  """
  def insert!(admin) do
    # The Issues tab suggests a path mapping by walking every mount that shares
    # a top-level directory with a library path. The fixture's default library
    # paths sit under System.tmp_dir!(), which is a real mount on some hosts,
    # and walking it stalled the page for over a minute. A top-level directory
    # that does not exist is never a mount, so nothing is walked.
    movies_path =
      SettingsFixtures.library_path_fixture(%{path: "#{@library_root}/movies", type: "movies"})

    series_path =
      SettingsFixtures.library_path_fixture(%{path: "#{@library_root}/series", type: "series"})

    movie = MediaFixtures.media_item_fixture(%{type: "movie", title: @long_movie, year: 2021})

    for n <- 1..3 do
      MediaFixtures.media_file_fixture(%{
        media_item_id: movie.id,
        library_path_id: movies_path.id,
        relative_path: "Fictional/#{@long_release}.part#{n}.mkv"
      })
    end

    show = MediaFixtures.media_item_fixture(%{type: "tv_show", title: @long_show, year: 2019})

    for season <- 1..2, ep <- 1..3 do
      episode =
        MediaFixtures.episode_fixture(%{
          media_item_id: show.id,
          season_number: season,
          episode_number: ep,
          title: "An Unusually Long Fictional Episode Title Number #{season}x#{ep}"
        })

      if ep == 1,
        do:
          MediaFixtures.media_file_fixture(%{
            episode_id: episode.id,
            library_path_id: series_path.id
          })
    end

    seed_downloads()
    seed_admin_rows()

    collection =
      CollectionsFixtures.collection_fixture(%{
        user: admin,
        name: "A Collection With A Long Fictional Name For Wrapping"
      })

    CollectionsFixtures.collection_item_fixture(%{collection: collection, media_item: movie})

    section =
      CollectionsFixtures.smart_collection_fixture(%{
        user: admin,
        name: "A Smart Collection With A Long Fictional Name For Wrapping"
      })

    %{movie: movie.id, show: show.id, collection: collection.id, section: section.id}
  end

  # One download per Issues kind, matching downloads_issues_mobile_test.exs.
  # The fixture owns creation, then Repo.update_all forces the issue columns so
  # changeset rules cannot refuse them.
  defp seed_downloads do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    [
      [],
      [match_status: "unresolved_files"],
      [import_failed_at: now, import_last_error: @long_error],
      [
        import_failed_at: now,
        import_last_error: @long_error,
        import_failure_reason: "path_mapping_mismatch",
        import_reported_path: @long_path
      ],
      [error_message: @long_error],
      [removal_error: @long_error],
      [
        download_client: @long_client,
        error_message: "Download client '#{@long_client}' is no longer configured in Mydia.",
        import_failure_reason: "no_client"
      ]
    ]
    |> Enum.with_index()
    |> Enum.each(fn {changes, i} ->
      item = MediaFixtures.media_item_fixture()

      download =
        DownloadsFixtures.download_fixture(%{
          media_item_id: item.id,
          title: "#{@long_release}.#{i}"
        })

      if changes != [],
        do: Repo.update_all(from(d in Download, where: d.id == ^download.id), set: changes)
    end)
  end

  # At least one row on each admin list page, with the long values the
  # admin mobile tests already use.
  defp seed_admin_rows do
    AccountsFixtures.user_fixture(%{
      username: "alexandria.longusername",
      email: "alexandria.longusername@example.test"
    })

    Repo.insert!(%Mydia.Downloads.ReleaseBlacklist{
      indexer: "Fictional Usenet Indexer With A Long Name",
      guid: "https://indexer.example/details/" <> String.duplicate("a1b2c3", 6),
      title: @long_release,
      failure_reason: "Import failed: sample file detected, archive password protected",
      inserted_at: DateTime.utc_now()
    })

    IndexersFixtures.cardigann_definition_fixture(%{
      indexer_id: "fictional-tracker-one",
      name: "The Fictional Lantern Mirror Network"
    })

    SettingsFixtures.quality_profile_fixture(%{
      name: "A Fictional Quality Profile With A Long Name"
    })

    SettingsFixtures.custom_format_fixture(%{
      name: "Fictional Custom Format With A Long Name"
    })

    # Not @long_client: the orphaned-client download above must stay orphaned.
    # Disabled, so no page polls it: the fixture's localhost:8080 can be a real
    # service on the machine running the sweep.
    SettingsFixtures.download_client_config_fixture(%{
      name: "fictional-transmission-seedbox-under-the-westmarch-lantern-archive",
      enabled: false
    })

    # The Indexers page health-checks every indexer on mount. Port 1 refuses
    # at once, so the row renders the same unhealthy badge on every machine.
    SettingsFixtures.indexer_config_fixture(%{
      name: "Fictional Indexer Config With A Long Name",
      base_url: "http://127.0.0.1:1"
    })

    :ok
  end
end
