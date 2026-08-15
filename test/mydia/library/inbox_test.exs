defmodule Mydia.Library.InboxTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library

  setup do
    lp = library_path_fixture()

    confident = orphaned_media_file_fixture(%{library_path_id: lp.id})
    unsure = orphaned_media_file_fixture(%{library_path_id: lp.id})
    unidentified = orphaned_media_file_fixture(%{library_path_id: lp.id})

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: confident.id,
        rank: 0,
        provider_type: "tmdb",
        provider_id: "1",
        title: "Confident",
        media_type: "movie",
        confidence: 0.95
      })

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: unsure.id,
        rank: 0,
        provider_type: "tmdb",
        provider_id: "2",
        title: "Unsure",
        media_type: "movie",
        confidence: 0.3
      })

    {:ok, _} =
      Library.upsert_match_candidate(%{
        media_file_id: unidentified.id,
        rank: 0,
        attempts: 1,
        last_error: "no_match"
      })

    {:ok, lp: lp, confident: confident, unsure: unsure, unidentified: unidentified}
  end

  test "lists every unresolved file with its candidate", %{lp: lp} do
    rows = Library.list_inbox_files(library_path_id: lp.id)

    assert length(rows) == 3
    assert Enum.all?(rows, &Map.has_key?(&1, :media_file))
  end

  test "excludes a file once it has been linked", %{lp: lp, confident: confident} do
    # Explicitly a movie: library_path_fixture/0 defaults to type "movies", and
    # MediaFile.changeset validates that the item type matches the library type.
    item = media_item_fixture(%{type: "movie"})
    {:ok, _} = Library.update_media_file(confident, %{media_item_id: item.id})

    assert length(Library.list_inbox_files(library_path_id: lp.id)) == 2
  end

  test "filters to unidentified files", %{lp: lp, unidentified: unidentified} do
    rows = Library.list_inbox_files(library_path_id: lp.id, filter: :unidentified)

    assert [row] = rows
    assert row.media_file.id == unidentified.id
  end

  test "filters to low confidence matches", %{lp: lp, unsure: unsure} do
    rows = Library.list_inbox_files(library_path_id: lp.id, filter: :low_confidence)

    assert [row] = rows
    assert row.media_file.id == unsure.id
  end

  test "paginates", %{lp: lp} do
    assert length(Library.list_inbox_files(library_path_id: lp.id, limit: 2)) == 2
    assert length(Library.list_inbox_files(library_path_id: lp.id, limit: 2, offset: 2)) == 1
  end

  test "counts without loading", %{lp: lp} do
    assert Library.count_inbox_files(library_path_id: lp.id) == 3
    assert Library.count_inbox_files(library_path_id: lp.id, filter: :unidentified) == 1
  end
end
