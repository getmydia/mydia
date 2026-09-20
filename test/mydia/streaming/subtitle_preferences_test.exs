defmodule Mydia.Streaming.SubtitlePreferencesTest do
  use Mydia.DataCase, async: true

  alias Mydia.Streaming.SubtitlePreferences

  setup do
    user = Mydia.AccountsFixtures.user_fixture()
    item = Mydia.MediaFixtures.media_item_fixture(%{title: "Lanterns of Verrow"})
    %{user: user, item: item}
  end

  describe "get/2" do
    test "returns nil when nothing was ever stored", %{user: user, item: item} do
      assert SubtitlePreferences.get(user.id, item.id) == nil
    end

    test "returns nil for a nil user or item", %{user: user, item: item} do
      assert SubtitlePreferences.get(nil, item.id) == nil
      assert SubtitlePreferences.get(user.id, nil) == nil
    end

    test "returns nil rather than raising on a malformed id", %{item: item} do
      assert SubtitlePreferences.get("not-a-uuid", item.id) == nil
    end
  end

  describe "put/3" do
    test "stores a track choice with its flags", %{user: user, item: item} do
      assert {:ok, _} =
               SubtitlePreferences.put(user.id, item.id, %{
                 mode: :track,
                 language: "eng",
                 forced: true,
                 hearing_impaired: false,
                 track_title: "English (Signs & Songs)"
               })

      stored = SubtitlePreferences.get(user.id, item.id)
      assert stored.mode == :track
      assert stored.language == "eng"
      assert stored.forced == true
      assert stored.hearing_impaired == false
      assert stored.track_title == "English (Signs & Songs)"
    end

    test "stores an explicit off with no language", %{user: user, item: item} do
      assert {:ok, _} = SubtitlePreferences.put(user.id, item.id, %{mode: :off})

      stored = SubtitlePreferences.get(user.id, item.id)
      assert stored.mode == :off
      assert stored.language == nil
    end

    test "replaces an earlier choice rather than inserting a second row",
         %{user: user, item: item} do
      {:ok, _} = SubtitlePreferences.put(user.id, item.id, %{mode: :track, language: "eng"})
      {:ok, _} = SubtitlePreferences.put(user.id, item.id, %{mode: :track, language: "jpn"})

      assert SubtitlePreferences.get(user.id, item.id).language == "jpn"
      assert Mydia.Repo.aggregate(Mydia.Streaming.SubtitleLanguagePreference, :count) == 1
    end

    test "rejects a track mode with no language", %{user: user, item: item} do
      assert {:error, changeset} =
               SubtitlePreferences.put(user.id, item.id, %{mode: :track, language: nil})

      assert "can't be blank" in errors_on(changeset).language
    end

    test "rejects an off mode carrying a language", %{user: user, item: item} do
      assert {:error, changeset} =
               SubtitlePreferences.put(user.id, item.id, %{mode: :off, language: "eng"})

      assert changeset.errors[:language]
    end
  end

  describe "delete/2" do
    test "forgets a stored choice and succeeds when there was none",
         %{user: user, item: item} do
      {:ok, _} = SubtitlePreferences.put(user.id, item.id, %{mode: :track, language: "eng"})

      assert :ok = SubtitlePreferences.delete(user.id, item.id)
      assert SubtitlePreferences.get(user.id, item.id) == nil
      assert :ok = SubtitlePreferences.delete(user.id, item.id)
    end
  end

  describe "media_item_id_of/1" do
    test "reads a movie file's own item and an episode file's show" do
      item_id = Ecto.UUID.generate()

      assert SubtitlePreferences.media_item_id_of(%{media_item_id: item_id}) == item_id

      assert SubtitlePreferences.media_item_id_of(%{
               media_item_id: nil,
               episode: %{media_item_id: item_id}
             }) == item_id

      assert SubtitlePreferences.media_item_id_of(%{media_item_id: nil}) == nil
      assert SubtitlePreferences.media_item_id_of(nil) == nil
    end
  end
end
