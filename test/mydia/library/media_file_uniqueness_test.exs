defmodule Mydia.Library.MediaFileUniquenessTest do
  use Mydia.DataCase

  import Mydia.SettingsFixtures

  alias Mydia.Library
  alias Mydia.MediaFixtures

  test "a second active row at the same path is a changeset error, not an exception" do
    library_path = library_path_fixture(%{type: "movies"})
    movie = MediaFixtures.media_item_fixture(%{type: "movie"})

    attrs = %{
      relative_path: "Pale Orchard (2018)/Pale.Orchard.2018.1080p.mkv",
      library_path_id: library_path.id,
      media_item_id: movie.id,
      size: 1024
    }

    assert {:ok, _} = Library.create_media_file(attrs)
    assert {:error, changeset} = Library.create_media_file(attrs)

    assert %{relative_path: ["already tracked at this library path"]} = errors_on(changeset)
  end

  test "a trashed row does not block a new active row at the same path" do
    library_path = library_path_fixture(%{type: "movies"})
    movie = MediaFixtures.media_item_fixture(%{type: "movie"})

    attrs = %{
      relative_path: "Harrow Bay (2011)/Harrow.Bay.2011.1080p.mkv",
      library_path_id: library_path.id,
      media_item_id: movie.id,
      size: 1024
    }

    {:ok, first} = Library.create_media_file(attrs)
    {:ok, _trashed} = Library.trash_media_file(first)

    assert {:ok, _second} = Library.create_media_file(attrs)
  end
end
