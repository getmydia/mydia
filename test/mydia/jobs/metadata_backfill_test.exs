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
          poster_path: "/p.jpg"
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
          title: "Both Ids"
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
          external_ids: %{tmdb: nil, tvdb: nil, imdb: nil}
        }
      })

    assert :ok = perform_job(MetadataBackfill, %{})

    refute_enqueued(worker: MetadataRefresh, args: %{media_item_id: item.id})
  end
end
