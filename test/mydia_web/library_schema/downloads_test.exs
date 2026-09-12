defmodule MydiaWeb.LibrarySchema.DownloadsTest do
  use MydiaWeb.ConnCase

  # Zero-client tests here hit History's "No download clients configured"
  # warning by design; silence it instead of drowning real failures in noise.
  @moduletag :capture_log

  import Mydia.Factory

  import Ecto.Query

  alias Mydia.LibraryApi.MediaItemRevision
  alias Mydia.LibraryApi.Principal
  alias Mydia.Repo
  alias MydiaWeb.LibrarySchema.Resolvers.Downloads

  @admin %Principal{role: "admin", source: :api_key}

  @downloads """
  query Downloads($filter: DownloadFilter) {
    downloads(filter: $filter) {
      id title status
      downloadClient { name state }
      indexer { name }
      mediaItem { id title status { state } }
      episode { id hasFile }
      addedAt
    }
  }
  """

  defp run(query, variables) do
    Absinthe.run(query, MydiaWeb.LibrarySchema,
      variables: variables,
      context: %{principal: @admin}
    )
  end

  describe "status mapping" do
    test "maps every status string the context can derive onto the enum" do
      for {value, expected} <- [
            {"queued", :queued},
            {"grabbing", :grabbing},
            {"downloading", :downloading},
            {"checking", :checking},
            {"paused", :paused},
            {"seeding", :seeding},
            {"completed", :completed},
            {"imported", :imported},
            {"failed", :failed},
            {"missing", :missing},
            {"unknown", :unknown}
          ] do
        assert Downloads.status(value) == expected
      end
    end

    test "maps unrecognised statuses to :unknown" do
      assert Downloads.status("something-new") == :unknown
      assert Downloads.status(nil) == :unknown
    end

    test "maps every client_config_state, including nil, onto the enum" do
      assert Downloads.client_state(:present) == :present
      assert Downloads.client_state(:disabled) == :disabled
      assert Downloads.client_state(:removed) == :removed
      assert Downloads.client_state(nil) == :unknown
    end
  end

  test "downloads returns rows with their client and indexer" do
    movie = insert(:media_item, type: "movie", title: "Arrival")
    insert(:download, title: "Arrival.2016.1080p", media_item: movie)

    assert {:ok, %{data: %{"downloads" => [download]}}} =
             run(@downloads, %{"filter" => "ALL"})

    assert download["title"] == "Arrival.2016.1080p"
    assert download["indexer"] == %{"name" => "test-indexer"}
    assert download["downloadClient"] == %{"name" => "transmission", "state" => "REMOVED"}
    assert download["mediaItem"]["title"] == "Arrival"
    assert is_binary(download["mediaItem"]["status"]["state"])
    assert is_binary(download["addedAt"])
  end

  test "downloads is empty when nothing matches" do
    assert {:ok, %{data: %{"downloads" => []}}} = run(@downloads, %{"filter" => "FAILED"})
  end

  test "default and explicit null filter return active rows only" do
    insert(:download, title: "Imported", imported_at: DateTime.utc_now())
    insert(:download, title: "Pending", download_client: nil, download_client_id: nil)

    for variables <- [%{}, %{"filter" => nil}] do
      assert {:ok, %{data: %{"downloads" => [download]}}} = run(@downloads, variables)
      assert download["title"] == "Pending"
      assert download["downloadClient"] == nil
    end
  end

  test "episode associations are hydrated so absent files are reported honestly" do
    show = insert(:media_item, type: "tv_show")
    episode = insert(:episode, media_item: show)
    insert(:download, media_item: nil, episode: episode)

    assert {:ok, %{data: %{"downloads" => [download]}}} =
             run(@downloads, %{"filter" => "ALL"})

    assert download["episode"] == %{"id" => episode.id, "hasFile" => false}
    assert download["mediaItem"] == nil
  end

  test "a media item deleted between the item query and the marker read reports no mediaItem" do
    movie = insert(:media_item, type: "movie", title: "Arrival")
    insert(:download, title: "Arrival.2016.1080p", media_item: movie)

    # The download's item was hydrated before a concurrent delete committed, so
    # the row is still in the batch while its marker is already a tombstone.
    Repo.update_all(
      from(r in MediaItemRevision, where: r.media_item_id == ^movie.id),
      set: [deleted: true]
    )

    assert {:ok, %{data: %{"downloads" => [download]}}} =
             run(@downloads, %{"filter" => "ALL"})

    assert download["mediaItem"] == nil
  end
end
