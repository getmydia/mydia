defmodule Mydia.Streaming.SubtitlePreferencesTest do
  # put_operator_languages/1 rewrites the cached runtime config, which
  # production code reads globally, so this module cannot run alongside other
  # tests.
  use Mydia.DataCase, async: false

  alias Mydia.Streaming.SubtitlePreferences

  setup do
    user = Mydia.AccountsFixtures.user_fixture()
    item = Mydia.MediaFixtures.media_item_fixture(%{title: "Lanterns of Verrow"})

    original_config = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original_config do
        Application.put_env(:mydia, :runtime_config, original_config)
      else
        Application.delete_env(:mydia, :runtime_config)
      end
    end)

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

  describe "resolve/2" do
    setup %{user: user, item: item} do
      media_file = %Mydia.Library.MediaFile{
        id: Ecto.UUID.generate(),
        media_item_id: item.id,
        metadata: %Mydia.Library.Structs.FileMetadata{
          streams: [
            %Mydia.Library.Structs.StreamInfo{
              index: 2,
              type: :subtitle,
              codec: "subrip",
              language: "eng",
              title: "English",
              is_forced: false,
              is_hearing_impaired: false
            },
            %Mydia.Library.Structs.StreamInfo{
              index: 3,
              type: :subtitle,
              codec: "subrip",
              language: "ger",
              title: "German",
              is_forced: false,
              is_hearing_impaired: false
            }
          ]
        }
      }

      %{user: user, item: item, media_file: media_file}
    end

    test "returns nil with no stored row and no operator default",
         %{user: user, media_file: media_file} do
      assert SubtitlePreferences.resolve(user.id, media_file) == nil
    end

    test "returns the stored track choice", %{user: user, item: item, media_file: media_file} do
      {:ok, _} =
        SubtitlePreferences.put(user.id, item.id, %{
          mode: :track,
          language: "eng",
          forced: true,
          hearing_impaired: false,
          track_title: "English (Signs & Songs)"
        })

      assert %{
               mode: :track,
               language: "eng",
               forced: true,
               hearing_impaired: false,
               track_title: "English (Signs & Songs)"
             } = SubtitlePreferences.resolve(user.id, media_file)
    end

    test "a stored off beats the operator default",
         %{user: user, item: item, media_file: media_file} do
      put_operator_languages(["en"])
      {:ok, _} = SubtitlePreferences.put(user.id, item.id, %{mode: :off})

      assert %{mode: :off} = SubtitlePreferences.resolve(user.id, media_file)
    end

    test "falls back to the first operator language the file actually carries",
         %{user: user, media_file: media_file} do
      put_operator_languages(["fr", "en"])

      assert %{mode: :track, language: "en", forced: false, hearing_impaired: false} =
               SubtitlePreferences.resolve(user.id, media_file)
    end

    test "an operator code matches the 639-2/B tag Matroska writes",
         %{user: user, media_file: media_file} do
      # The German track carries what Matroska writes, "ger", while an
      # operator writes "de". Comparing the two as strings finds nothing, so
      # this pins the equivalence table rather than exact equality.
      put_operator_languages(["de"])

      assert %{mode: :track, language: "de"} =
               SubtitlePreferences.resolve(user.id, media_file)
    end

    test "returns nil when no operator language is on the file",
         %{user: user, media_file: media_file} do
      put_operator_languages(["fr"])

      assert SubtitlePreferences.resolve(user.id, media_file) == nil
    end

    test "returns nil for an anonymous viewer even with an operator default",
         %{media_file: media_file} do
      put_operator_languages(["en"])

      assert SubtitlePreferences.resolve(nil, media_file) == nil
    end

    test "returns nil for a file attached to neither an item nor an episode",
         %{user: user} do
      put_operator_languages(["en"])

      assert SubtitlePreferences.resolve(user.id, orphan_file()) == nil
    end

    test "returns nil for an orphan file even when it carries a matching track",
         %{user: user} do
      # The file's own tracks must not let the operator default through: with
      # no item there is no row to store an override against, exactly as for an
      # anonymous viewer, so a subtitle selected here could never be turned off.
      orphan = orphan_file([subtitle_stream("eng")])

      put_operator_languages(["en"])

      assert SubtitlePreferences.resolve(user.id, orphan) == nil
    end
  end

  # A file attached to neither an item nor an episode: a null media_item_id and
  # no episode, which is how a file awaiting a match arrives.
  defp orphan_file(streams \\ []) do
    %Mydia.Library.MediaFile{
      id: Ecto.UUID.generate(),
      media_item_id: nil,
      metadata: %Mydia.Library.Structs.FileMetadata{streams: streams}
    }
  end

  defp subtitle_stream(language) do
    %Mydia.Library.Structs.StreamInfo{
      index: 2,
      type: :subtitle,
      codec: "subrip",
      language: language
    }
  end

  # The operator default is stored the way the admin settings page stores it:
  # a config_settings row holding the comma-joined codes, reloaded into the
  # cached runtime config. See MydiaWeb.AdminSettingsLive.LanguageSettings.
  defp put_operator_languages(languages) do
    {:ok, _} =
      Mydia.Settings.upsert_config_setting(%{
        key: "streaming.subtitle_language",
        value: Enum.join(languages, ","),
        category: :streaming
      })

    # Matched rather than ignored: a reload that failed validation would leave
    # resolve/2 reading the previous config and quietly prove nothing.
    {:ok, _} = Mydia.Config.Loader.reload()
    :ok
  end
end
