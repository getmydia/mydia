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
end
