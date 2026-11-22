defmodule Mydia.Media.PostersTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures

  alias Mydia.Media.MediaItem
  alias Mydia.Media.Posters
  alias Mydia.Repo

  describe "effective_path/1" do
    test "the override wins over metadata" do
      item = media_item_fixture(%{metadata: %{poster_path: "/provider.jpg"}})

      {:ok, item} =
        item
        |> MediaItem.poster_override_changeset(%{poster_override: "/chosen.jpg"})
        |> Repo.update()

      assert Posters.effective_path(item) == "/chosen.jpg"
    end

    test "nil override falls back to metadata.poster_path" do
      item = media_item_fixture(%{metadata: %{poster_path: "/provider.jpg"}})
      assert Posters.effective_path(item) == "/provider.jpg"
    end

    test "an empty override falls back to metadata" do
      item = media_item_fixture(%{metadata: %{poster_path: "/provider.jpg"}})
      assert Posters.effective_path(%{item | poster_override: ""}) == "/provider.jpg"
    end

    test "no override and no metadata is nil" do
      assert Posters.effective_path(%MediaItem{poster_override: nil, metadata: nil}) == nil
    end
  end

  describe "poster_override_changeset/2" do
    test "changeset/2 never casts poster_override" do
      item = media_item_fixture(%{})
      changeset = MediaItem.changeset(item, %{poster_override: "/x.jpg"})
      refute Map.has_key?(changeset.changes, :poster_override)
    end
  end
end
