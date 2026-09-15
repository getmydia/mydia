defmodule Mydia.Media.MediaItemDownloadAudioLanguageTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures

  alias Mydia.Media
  alias Mydia.Media.MediaItem

  defp changeset(choice) do
    MediaItem.changeset(%MediaItem{type: "tv_show", title: "Kaiju Garden"}, %{
      download_audio_language: choice
    })
  end

  describe "changeset/2 download_audio_language" do
    test "canonicalizes a known code, trimming and downcasing it" do
      cs = changeset(" JPN ")

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :download_audio_language) == "ja"
    end

    test "keeps original" do
      cs = changeset("Original")

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :download_audio_language) == "original"
    end

    test "stores a blank choice as nil, meaning the server default" do
      cs = changeset("")

      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :download_audio_language) == nil
    end

    test "rejects an unknown code" do
      refute changeset("xx").valid?
    end
  end

  describe "persistence" do
    test "round-trips through update_media_item/3" do
      item = media_item_fixture(%{type: "tv_show", title: "Paper Lantern Club"})

      {:ok, updated} = Media.update_media_item(item, %{download_audio_language: "en"})
      assert Repo.get!(MediaItem, updated.id).download_audio_language == "en"

      {:ok, cleared} = Media.update_media_item(updated, %{download_audio_language: ""})
      assert Repo.get!(MediaItem, cleared.id).download_audio_language == nil
    end
  end
end
