defmodule Mydia.Streaming.AudioPreferencesTest do
  use Mydia.DataCase, async: true

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Repo
  alias Mydia.Streaming.AudioPreferences

  setup do
    %{user: user_fixture()}
  end

  describe "get/2 and put/3" do
    test "returns nil before anything is chosen", %{user: user} do
      item = media_item_fixture()

      assert AudioPreferences.get(user.id, item.id) == nil
    end

    test "reads back what was written", %{user: user} do
      item = media_item_fixture()

      assert {:ok, _} = AudioPreferences.put(user.id, item.id, "eng")
      assert AudioPreferences.get(user.id, item.id) == "eng"
    end

    test "replaces an earlier choice rather than failing on the unique index", %{user: user} do
      item = media_item_fixture()

      assert {:ok, _} = AudioPreferences.put(user.id, item.id, "eng")
      assert {:ok, _} = AudioPreferences.put(user.id, item.id, "jpn")

      assert AudioPreferences.get(user.id, item.id) == "jpn"
    end

    test "keeps one row per viewer per item across repeated writes", %{user: user} do
      # The upsert is what makes two devices choosing at once safe. If it
      # degraded into insert-on-conflict-nothing, or into a second row, this
      # count would drift.
      item = media_item_fixture()

      for language <- ["eng", "jpn", "deu", "eng"] do
        assert {:ok, _} = AudioPreferences.put(user.id, item.id, language)
      end

      assert Repo.aggregate(Mydia.Streaming.AudioLanguagePreference, :count) == 1
    end

    test "keeps viewers independent", %{user: user} do
      other = user_fixture()
      item = media_item_fixture()

      assert {:ok, _} = AudioPreferences.put(user.id, item.id, "eng")
      assert {:ok, _} = AudioPreferences.put(other.id, item.id, "rus")

      assert AudioPreferences.get(user.id, item.id) == "eng"
      assert AudioPreferences.get(other.id, item.id) == "rus"
    end

    test "keeps items independent", %{user: user} do
      one = media_item_fixture()
      two = media_item_fixture()

      assert {:ok, _} = AudioPreferences.put(user.id, one.id, "eng")

      assert AudioPreferences.get(user.id, two.id) == nil
    end

    test "rejects a language that is not plausibly a language tag", %{user: user} do
      item = media_item_fixture()

      assert {:error, changeset} = AudioPreferences.put(user.id, item.id, "e")
      assert %{language: _} = errors_on(changeset)

      assert AudioPreferences.get(user.id, item.id) == nil
    end

    test "treats a nil user or item as no preference rather than raising", %{user: user} do
      item = media_item_fixture()

      assert AudioPreferences.get(nil, item.id) == nil
      assert AudioPreferences.get(user.id, nil) == nil
    end
  end

  describe "delete/2" do
    test "forgets the choice", %{user: user} do
      item = media_item_fixture()
      assert {:ok, _} = AudioPreferences.put(user.id, item.id, "eng")

      assert :ok = AudioPreferences.delete(user.id, item.id)
      assert AudioPreferences.get(user.id, item.id) == nil
    end

    test "succeeds when there was nothing to forget", %{user: user} do
      item = media_item_fixture()

      assert :ok = AudioPreferences.delete(user.id, item.id)
    end
  end

  describe "for_media_file/2" do
    test "finds a movie's preference through media_item_id", %{user: user} do
      item = media_item_fixture(%{type: "movie"})
      file = media_file_fixture(%{media_item_id: item.id})

      assert {:ok, _} = AudioPreferences.put(user.id, item.id, "eng")

      assert AudioPreferences.for_media_file(user.id, file) == ["eng"]
    end

    test "finds a TV file's preference through the episode", %{user: user} do
      # The trap this guards: a TV media_file has a NULL media_item_id and
      # names its show only through the episode. Reading media_item_id alone
      # returns nil for every episode, which silently disables the whole
      # feature for TV while movies keep working.
      show = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(%{media_item_id: show.id})
      file = media_file_fixture(%{episode_id: episode.id})

      assert file.media_item_id == nil

      assert {:ok, _} = AudioPreferences.put(user.id, show.id, "jpn")

      file = Repo.preload(file, :episode)
      assert AudioPreferences.for_media_file(user.id, file) == ["jpn"]
    end

    test "a preference set on one episode applies to another of the same show", %{user: user} do
      # The point of storing this at all: pick English on episode 3, get
      # English on episode 4 without picking again.
      show = media_item_fixture(%{type: "tv_show"})
      third = episode_fixture(%{media_item_id: show.id, episode_number: 3})
      fourth = episode_fixture(%{media_item_id: show.id, episode_number: 4})

      third_file = Repo.preload(media_file_fixture(%{episode_id: third.id}), :episode)
      fourth_file = Repo.preload(media_file_fixture(%{episode_id: fourth.id}), :episode)

      assert {:ok, _} =
               AudioPreferences.put(
                 user.id,
                 AudioPreferences.media_item_id_of(third_file),
                 "eng"
               )

      assert AudioPreferences.for_media_file(user.id, fourth_file) == ["eng"]
    end

    test "returns an empty list, not nil, when nothing was chosen", %{user: user} do
      # AudioTrackSelector.resolve_preferences/1 spells "no opinion" as [], so
      # a nil here would have to be normalised at every call site.
      file = media_file_fixture()

      assert AudioPreferences.for_media_file(user.id, file) == []
    end

    test "returns an empty list for a nil user or file", %{user: user} do
      assert AudioPreferences.for_media_file(nil, media_file_fixture()) == []
      assert AudioPreferences.for_media_file(user.id, nil) == []
    end
  end

  describe "media_item_id_of/1" do
    test "prefers the direct column when both are present" do
      item = media_item_fixture(%{type: "movie"})

      assert AudioPreferences.media_item_id_of(%{media_item_id: item.id}) == item.id
    end

    test "falls through to the episode when the column is null" do
      show = media_item_fixture(%{type: "tv_show"})

      assert AudioPreferences.media_item_id_of(%{
               media_item_id: nil,
               episode: %{media_item_id: show.id}
             }) == show.id
    end

    test "returns nil for a file attached to neither" do
      assert AudioPreferences.media_item_id_of(%{media_item_id: nil, episode: nil}) == nil
      assert AudioPreferences.media_item_id_of(%{}) == nil
    end
  end
end
