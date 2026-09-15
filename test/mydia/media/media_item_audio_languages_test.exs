defmodule Mydia.Media.MediaItemAudioLanguagesTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures

  alias Mydia.Media
  alias Mydia.Media.AudioLanguagePolicy
  alias Mydia.Media.MediaItem

  defp changeset(languages) do
    MediaItem.changeset(%MediaItem{type: "tv_show", title: "Kaiju Garden"}, %{
      audio_languages: languages
    })
  end

  describe "changeset/2 audio_languages" do
    test "canonicalizes, trims and deduplicates while keeping order" do
      cs = changeset([" JPN ", "en", "ja", "original"])

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :audio_languages) == ["ja", "en", "original"]
    end

    test "stores an empty selection as nil, meaning inherit" do
      assert Ecto.Changeset.get_change(changeset(["", ""]), :audio_languages) == nil
      assert Ecto.Changeset.get_change(changeset([]), :audio_languages) == nil
    end

    test "rejects more than three languages" do
      refute changeset(["en", "ja", "fr", "de"]).valid?
    end

    test "rejects an unknown code" do
      refute changeset(["en", "xx"]).valid?
    end
  end

  describe "persistence" do
    test "round-trips through update_media_item/3" do
      item = media_item_fixture(%{type: "tv_show", title: "Paper Lantern Club"})

      {:ok, updated} = Media.update_media_item(item, %{audio_languages: ["en", "original"]})
      assert Repo.get!(MediaItem, updated.id).audio_languages == ["en", "original"]

      {:ok, cleared} = Media.update_media_item(updated, %{audio_languages: []})
      assert Repo.get!(MediaItem, cleared.id).audio_languages == nil
    end
  end

  # Mydia.Metadata.Structs.MediaMetadata enforces :provider_id, :provider and
  # :media_type via @enforce_keys, so a fresh struct here must supply them
  # explicitly. Same pattern as test/mydia/db_test.exs and test/mydia/media_test.exs.
  defp metadata(original_language) do
    %Mydia.Metadata.Structs.MediaMetadata{
      provider_id: "1",
      provider: :metadata_relay,
      media_type: :tv_show,
      original_language: original_language
    }
  end

  describe "AudioLanguagePolicy.effective/2" do
    test "uses the show override when one is set" do
      item = %MediaItem{
        audio_languages: ["en"],
        metadata: metadata("jpn")
      }

      policy = AudioLanguagePolicy.effective(item, server_languages: ["original"])

      assert policy.source == :show
      assert policy.languages == ["en"]
      assert policy.original_language == "ja"
    end

    test "falls back to the server list, resolving original from metadata" do
      item = %MediaItem{
        audio_languages: nil,
        metadata: metadata("jpn")
      }

      policy = AudioLanguagePolicy.effective(item, server_languages: ["original", "en"])

      assert policy.source == :server
      assert policy.languages == ["ja", "en"]
    end

    test "reads streaming.audio_language when no server list is passed" do
      item = %MediaItem{audio_languages: nil, metadata: nil}

      assert AudioLanguagePolicy.effective(item).source == :server
      assert AudioLanguagePolicy.server_languages() == Mydia.Config.get().streaming.audio_language
    end
  end
end
