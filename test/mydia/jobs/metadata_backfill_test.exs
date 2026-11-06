defmodule Mydia.Jobs.MetadataBackfillTest do
  use Mydia.DataCase, async: false

  use Oban.Testing, repo: Mydia.Repo

  import Mydia.MediaFixtures

  alias Mydia.Jobs.MetadataBackfill
  alias Mydia.Jobs.MetadataRefresh
  alias Mydia.Metadata.Structs.MediaMetadata

  setup do
    # The app skips Oban in test (engine: false), so Oban.insert cannot be
    # resolved from inside the job. Start an isolated, manual-mode instance so
    # enqueues land somewhere assert_enqueued can see them.
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})
    :ok
  end

  test "enqueues a refresh for each media item with no metadata" do
    shell = media_item_fixture(%{type: "movie", title: "No Metadata", year: 2024})

    assert :ok = perform_job(MetadataBackfill, %{})

    assert_enqueued(worker: MetadataRefresh, args: %{"media_item_id" => shell.id})
  end

  test "leaves items that already have metadata alone" do
    populated =
      media_item_fixture(%{
        type: "movie",
        title: "Has Metadata",
        year: 2024,
        metadata: %MediaMetadata{
          provider_id: "1",
          provider: :tmdb,
          media_type: :movie,
          title: "Has Metadata",
          poster_path: "/p.jpg",
          schema_version: MediaMetadata.schema_version()
        }
      })

    assert :ok = perform_job(MetadataBackfill, %{})

    refute_enqueued(worker: MetadataRefresh, args: %{"media_item_id" => populated.id})
  end

  test "enqueues a refresh for a TV show holding only one provider id" do
    item =
      media_item_fixture(%{
        type: "tv_show",
        title: "One Id Only",
        tvdb_id: 121_361,
        metadata: %MediaMetadata{
          provider_id: "121361",
          provider: :tvdb,
          media_type: :tv_show,
          title: "One Id Only"
        }
      })

    assert :ok = perform_job(MetadataBackfill, %{})

    assert_enqueued(worker: MetadataRefresh, args: %{media_item_id: item.id})
  end

  test "enqueues a refresh for a TV show missing both persisted provider ids" do
    # Metadata is present and carries a provider_id, but neither id column is
    # populated. Why it matters, not what this test asserts: Discover reads the
    # tmdb_id column, so such a row is offered for adding all over again.
    item =
      media_item_fixture(%{
        type: "tv_show",
        title: "No Ids At All",
        metadata: %MediaMetadata{
          provider_id: "121364",
          provider: :tvdb,
          media_type: :tv_show,
          title: "No Ids At All"
        }
      })

    assert :ok = perform_job(MetadataBackfill, %{})

    assert_enqueued(worker: MetadataRefresh, args: %{media_item_id: item.id})
  end

  test "skips a TV show that already carries both provider ids" do
    item =
      media_item_fixture(%{
        type: "tv_show",
        title: "Both Ids",
        tvdb_id: 121_362,
        tmdb_id: 1400,
        metadata: %MediaMetadata{
          provider_id: "121362",
          provider: :tvdb,
          media_type: :tv_show,
          title: "Both Ids",
          schema_version: MediaMetadata.schema_version()
        }
      })

    assert :ok = perform_job(MetadataBackfill, %{})

    refute_enqueued(worker: MetadataRefresh, args: %{media_item_id: item.id})
  end

  test "skips a TV show already known to have no cross-reference" do
    item =
      media_item_fixture(%{
        type: "tv_show",
        title: "No Cross Reference",
        tvdb_id: 121_363,
        metadata: %MediaMetadata{
          provider_id: "121363",
          provider: :tvdb,
          media_type: :tv_show,
          title: "No Cross Reference",
          external_ids: %{tmdb: nil, tvdb: nil, imdb: nil},
          schema_version: MediaMetadata.schema_version()
        }
      })

    assert :ok = perform_job(MetadataBackfill, %{})

    refute_enqueued(worker: MetadataRefresh, args: %{media_item_id: item.id})
  end

  defp tvdb_show(title, tvdb_id, metadata_overrides \\ %{}) do
    media_item_fixture(%{
      type: "tv_show",
      title: title,
      tvdb_id: tvdb_id,
      tmdb_id: tvdb_id + 500_000,
      metadata:
        struct!(
          %MediaMetadata{
            provider_id: to_string(tvdb_id),
            provider: :tvdb,
            media_type: :tv_show,
            title: title,
            cast: [],
            external_ids: %{tmdb: tvdb_id + 500_000, tvdb: tvdb_id, imdb: nil}
          },
          metadata_overrides
        )
    })
  end

  defp tmdb_show(title, tmdb_id, version) do
    media_item_fixture(%{
      type: "tv_show",
      title: title,
      tmdb_id: tmdb_id,
      tvdb_id: tmdb_id + 1,
      metadata_source: :tmdb,
      metadata: %MediaMetadata{
        provider_id: to_string(tmdb_id),
        provider: :tmdb,
        media_type: :tv_show,
        title: title,
        schema_version: version,
        external_ids: %{tmdb: tmdb_id, tvdb: tmdb_id + 1, imdb: nil}
      }
    })
  end

  defp tmdb_movie(title, tmdb_id, version) do
    media_item_fixture(%{
      type: "movie",
      title: title,
      tmdb_id: tmdb_id,
      metadata: %MediaMetadata{
        provider_id: to_string(tmdb_id),
        provider: :tmdb,
        media_type: :movie,
        title: title,
        schema_version: version
      }
    })
  end

  describe "outdated metadata" do
    test "enqueues a metadata-only refresh for a TVDB show stored before the current version" do
      item = tvdb_show("Harbor Lights", 881_001)

      assert :ok = perform_job(MetadataBackfill, %{})

      assert_enqueued(
        worker: MetadataRefresh,
        args: %{media_item_id: item.id, fetch_episodes: false}
      )
    end

    test "keys the required version by the resolved provider, not the blob's provider field" do
      # tvdb_id set and no metadata_source: resolve_provider/1 answers :tvdb
      # even though the blob says :tmdb.
      item = tvdb_show("Harbor Lights", 881_003, %{provider: :tmdb})

      assert :ok = perform_job(MetadataBackfill, %{})

      assert_enqueued(
        worker: MetadataRefresh,
        args: %{media_item_id: item.id, fetch_episodes: false}
      )
    end

    test "skips a current TVDB show even when its cast is empty" do
      item =
        tvdb_show("Harbor Lights", 881_002, %{schema_version: MediaMetadata.schema_version()})

      assert :ok = perform_job(MetadataBackfill, %{})

      refute_enqueued(worker: MetadataRefresh, args: %{media_item_id: item.id})
    end

    test "enqueues TMDB shows and movies stored at version 1, skips them at version 2" do
      old_show = tmdb_show("Paper Orchard", 77_001, 1)
      old_movie = tmdb_movie("Quiet Meridian", 77_003, 1)
      new_show = tmdb_show("Salt Lantern", 77_011, 2)
      new_movie = tmdb_movie("Hollow Tide", 77_013, 2)

      assert :ok = perform_job(MetadataBackfill, %{})

      for item <- [old_show, old_movie] do
        assert_enqueued(
          worker: MetadataRefresh,
          args: %{media_item_id: item.id, fetch_episodes: false}
        )
      end

      refute_enqueued(worker: MetadataRefresh, args: %{media_item_id: new_show.id})
      refute_enqueued(worker: MetadataRefresh, args: %{media_item_id: new_movie.id})
    end

    test "a no-metadata item keeps the full refresh with episodes" do
      shell = media_item_fixture(%{type: "tv_show", title: "Shell Show"})

      assert :ok = perform_job(MetadataBackfill, %{})

      [job] = all_enqueued(worker: MetadataRefresh, args: %{media_item_id: shell.id})
      refute Map.has_key?(job.args, "fetch_episodes")
    end
  end

  describe "staggering" do
    test "spaces successive refreshes 15 seconds apart" do
      tvdb_show("Alder Signal", 881_010)
      tvdb_show("Birch Signal", 881_011)

      assert :ok = perform_job(MetadataBackfill, %{})

      [first, second] =
        all_enqueued(worker: MetadataRefresh) |> Enum.sort_by(& &1.scheduled_at, DateTime)

      assert DateTime.diff(second.scheduled_at, first.scheduled_at, :millisecond) in 15_000..15_999
    end

    test "a second run while refreshes are still scheduled queues no duplicates" do
      item = tvdb_show("Harbor Lights", 881_020)

      assert :ok = perform_job(MetadataBackfill, %{})
      assert :ok = perform_job(MetadataBackfill, %{})

      assert [_one] = all_enqueued(worker: MetadataRefresh, args: %{media_item_id: item.id})
    end
  end
end
