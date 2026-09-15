defmodule MydiaWeb.AdminSettingsLive.LanguageTest do
  # Saving reloads the cached runtime config, which is global, so this module
  # must be sync and restore it.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  alias Mydia.Settings

  setup %{conn: conn} do
    start_supervised!(Mydia.Indexers.Health)
    original_config = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original_config do
        Application.put_env(:mydia, :runtime_config, original_config)
      else
        Application.delete_env(:mydia, :runtime_config)
      end
    end)

    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  defp change(view, params) do
    view |> element("#language-settings-form") |> render_change(params)
  end

  describe "download audio" do
    test "saves its row and applies without a restart", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      html = change(view, %{"download_audio_language" => "ja"})

      assert html =~ "Setting updated successfully"
      setting = Settings.get_config_setting_by_key("downloads.audio_language")
      assert setting.value == "ja"
      assert setting.category == :downloads
      assert Mydia.Config.get().downloads.audio_language == "ja"
    end

    test "resubmitting the value on screen writes nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      change(view, %{"download_audio_language" => "original", "metadata_language" => "en-US"})

      assert Settings.get_config_setting_by_key("downloads.audio_language") == nil
      assert Settings.get_config_setting_by_key("metadata.language") == nil
    end

    test "an unknown code is rejected without a write", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      html = change(view, %{"download_audio_language" => "xx"})

      assert html =~ "Invalid value for downloads.audio_language"
      assert Settings.get_config_setting_by_key("downloads.audio_language") == nil
    end

    test "is read-only when DOWNLOAD_AUDIO_LANGUAGE is set", %{conn: conn} do
      original = System.get_env("DOWNLOAD_AUDIO_LANGUAGE")
      System.put_env("DOWNLOAD_AUDIO_LANGUAGE", "ja")

      on_exit(fn ->
        if original do
          System.put_env("DOWNLOAD_AUDIO_LANGUAGE", original)
        else
          System.delete_env("DOWNLOAD_AUDIO_LANGUAGE")
        end
      end)

      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      assert has_element?(view, "#language-download-audio[disabled]")
    end

    test "a change only saves the field that fired it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      change(view, %{
        "_target" => ["download_audio_language"],
        "download_audio_language" => "ja",
        "metadata_language" => "de"
      })

      assert Settings.get_config_setting_by_key("downloads.audio_language").value == "ja"
      assert Settings.get_config_setting_by_key("metadata.language") == nil
    end

    test "a save that fails writes nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      html = change(view, %{"download_audio_language" => "ja", "metadata_language" => "d"})

      assert Settings.get_config_setting_by_key("downloads.audio_language") == nil
      assert Settings.get_config_setting_by_key("metadata.language") == nil
      assert html =~ "Invalid value for metadata.language"
    end
  end

  describe "metadata language" do
    test "lives in the Language section, not a Metadata section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      assert has_element?(view, "#language-metadata-language")
      refute has_element?(view, "input[phx-value-key='metadata.language']")
    end

    test "saves a new locale", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      change(view, %{"metadata_language" => "de-DE"})

      assert Settings.get_config_setting_by_key("metadata.language").value == "de-DE"
      assert Mydia.Config.get().metadata.language == "de-DE"
    end

    test "rejects a locale the config would refuse", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      change(view, %{"metadata_language" => "d"})

      assert Settings.get_config_setting_by_key("metadata.language") == nil
    end

    test "rejects a value that is not a language tag", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      html = change(view, %{"metadata_language" => "not-a-tag!"})

      assert html =~ "Invalid value for metadata.language"
      assert Settings.get_config_setting_by_key("metadata.language") == nil
    end

    test "accepts a language tag with script and region subtags", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      change(view, %{"metadata_language" => "zh-Hant-TW"})

      assert Settings.get_config_setting_by_key("metadata.language").value == "zh-Hant-TW"
    end
  end

  describe "playback audio" do
    test "writes Preferred then Fallback as one list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      change(view, %{"playback_audio" => %{"preferred" => "en", "fallback" => "original"}})

      setting = Settings.get_config_setting_by_key("streaming.audio_language")
      assert setting.value == "en,original"
      assert setting.category == :streaming
      assert Mydia.Config.get().streaming.audio_language == ["en", "original"]
    end

    test "a Fallback of None, or equal to Preferred, writes one language", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      change(view, %{"playback_audio" => %{"preferred" => "ja", "fallback" => ""}})
      assert Settings.get_config_setting_by_key("streaming.audio_language").value == "ja"

      change(view, %{"playback_audio" => %{"preferred" => "de", "fallback" => "de"}})
      assert Settings.get_config_setting_by_key("streaming.audio_language").value == "de"
    end

    test "a Fallback change saves the whole pair", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      change(view, %{
        "_target" => ["playback_audio", "fallback"],
        "playback_audio" => %{"preferred" => "ja", "fallback" => "en"}
      })

      assert Settings.get_config_setting_by_key("streaming.audio_language").value == "ja,en"
    end

    test "does not touch download audio", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      change(view, %{"playback_audio" => %{"preferred" => "en", "fallback" => "original"}})

      assert Mydia.Config.get().downloads.audio_language == "original"
      assert Settings.get_config_setting_by_key("downloads.audio_language") == nil
    end

    test "warns when a longer configured list would be cut to two", %{conn: conn} do
      {:ok, _} =
        Settings.upsert_config_setting(%{
          key: "streaming.audio_language",
          value: "original,en,fr",
          category: :streaming
        })

      {:ok, _} = Mydia.Config.Loader.reload()
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      assert has_element?(view, "#language-playback-truncation")
    end

    test "the default-track toggle saves", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      change(view, %{"prefer_default_audio_track" => "true"})

      setting = Settings.get_config_setting_by_key("streaming.prefer_default_audio_track")
      assert setting.value == "true"
      assert setting.category == :streaming

      assert Mydia.Config.get().streaming.prefer_default_audio_track == true
    end

    test "both playback rows are hidden when the player is disabled", %{conn: conn} do
      disable_player()

      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      refute has_element?(view, "#language-row-playback-audio")
      refute has_element?(view, "#language-row-default-track")
      assert has_element?(view, "#language-row-download-audio")
    end
  end

  describe "subtitle languages" do
    test "checked chips save as a list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      change(view, %{"subtitle_language" => ["en", "es"]})

      setting = Settings.get_config_setting_by_key("streaming.subtitle_language")
      assert setting.value == "en,es"
      assert Mydia.Config.get().streaming.subtitle_language == ["en", "es"]
    end

    test "More languages adds one", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      change(view, %{"subtitle_language" => ["en"], "subtitle_language_add" => "th"})

      assert Settings.get_config_setting_by_key("streaming.subtitle_language").value == "en,th"
      assert has_element?(view, "#language-subtitle-th[checked]")
    end

    test "the last checked chip cannot be unchecked", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      assert has_element?(view, "#language-subtitle-en[disabled][checked]")
    end

    test "an unrelated change never reorders a configured list", %{conn: conn} do
      {:ok, _} =
        Settings.upsert_config_setting(%{
          key: "streaming.subtitle_language",
          value: "es,en",
          category: :streaming
        })

      {:ok, _} = Mydia.Config.Loader.reload()
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      # Chips submit in display order (en before es), not preference order.
      change(view, %{"download_audio_language" => "ja", "subtitle_language" => ["en", "es"]})

      assert Settings.get_config_setting_by_key("streaming.subtitle_language").value == "es,en"
      assert Settings.get_config_setting_by_key("downloads.audio_language").value == "ja"
    end

    test "adding from More languages saves when it is the target", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      change(view, %{
        "_target" => ["subtitle_language_add"],
        "subtitle_language" => ["en"],
        "subtitle_language_add" => "th"
      })

      assert Settings.get_config_setting_by_key("streaming.subtitle_language").value == "en,th"
    end

    test "unchecking a chip saves", %{conn: conn} do
      {:ok, _} =
        Settings.upsert_config_setting(%{
          key: "streaming.subtitle_language",
          value: "en,es",
          category: :streaming
        })

      {:ok, _} = Mydia.Config.Loader.reload()
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      change(view, %{"_target" => ["subtitle_language"], "subtitle_language" => ["es"]})

      assert Settings.get_config_setting_by_key("streaming.subtitle_language").value == "es"
    end

    test "an unknown code is rejected without a write", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      html = change(view, %{"subtitle_language" => ["en", "xx"]})

      assert html =~ "Invalid value for streaming.subtitle_language"
      assert Settings.get_config_setting_by_key("streaming.subtitle_language") == nil
    end
  end
end
