defmodule MydiaWeb.AdminSettingsLive.LanguageTest do
  # Saving reloads the cached runtime config, which is global, so this module
  # must be sync and restore it.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures

  alias Mydia.Settings
  alias MydiaWeb.AdminSettingsLive.LanguageSettings

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
    test "each subtitle row names the key it edits", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      assert has_element?(view, "#language-row-subtitles")
      assert has_element?(view, "#language-row-subtitle-playback")

      acquisition = view |> element("#language-row-subtitles") |> render()
      playback = view |> element("#language-row-subtitle-playback") |> render()

      assert acquisition =~ "downloads.subtitle_language"
      # The acquisition row must not still name the playback key, nor badge an
      # env var that controls it.
      refute acquisition =~ "streaming.subtitle_language"
      assert playback =~ "streaming.subtitle_language"
    end

    test "a change on one subtitle row never writes the other's key", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      change(view, %{
        "_target" => ["subtitle_playback_language"],
        "subtitle_language" => ["en"],
        "subtitle_playback_language" => ["de"]
      })

      assert Settings.get_config_setting_by_key("streaming.subtitle_language").value == "de"
      assert Settings.get_config_setting_by_key("downloads.subtitle_language") == nil
    end

    test "checked chips save as a list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      change(view, %{"subtitle_language" => ["en", "es"]})

      setting = Settings.get_config_setting_by_key("downloads.subtitle_language")
      assert setting.value == "en,es"
      assert Mydia.Config.get().downloads.subtitle_language == ["en", "es"]
    end

    test "More languages adds one", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      change(view, %{"subtitle_language" => ["en"], "subtitle_language_add" => "th"})

      assert Settings.get_config_setting_by_key("downloads.subtitle_language").value == "en,th"
      assert has_element?(view, "#language-subtitle_language-th[checked]")
    end

    test "the last checked chip cannot be unchecked", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      assert has_element?(view, "#language-subtitle_language-en[disabled][checked]")
    end

    test "an unrelated change never reorders a configured list", %{conn: conn} do
      {:ok, _} =
        Settings.upsert_config_setting(%{
          key: "downloads.subtitle_language",
          value: "es,en",
          category: :downloads
        })

      {:ok, _} = Mydia.Config.Loader.reload()
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      # Chips submit in display order (en before es), not preference order.
      change(view, %{"download_audio_language" => "ja", "subtitle_language" => ["en", "es"]})

      assert Settings.get_config_setting_by_key("downloads.subtitle_language").value == "es,en"
      assert Settings.get_config_setting_by_key("downloads.audio_language").value == "ja"
    end

    test "adding from More languages saves when it is the target", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      change(view, %{
        "_target" => ["subtitle_language_add"],
        "subtitle_language" => ["en"],
        "subtitle_language_add" => "th"
      })

      assert Settings.get_config_setting_by_key("downloads.subtitle_language").value == "en,th"
    end

    test "unchecking a chip saves", %{conn: conn} do
      {:ok, _} =
        Settings.upsert_config_setting(%{
          key: "downloads.subtitle_language",
          value: "en,es",
          category: :downloads
        })

      {:ok, _} = Mydia.Config.Loader.reload()
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      change(view, %{"_target" => ["subtitle_language"], "subtitle_language" => ["es"]})

      assert Settings.get_config_setting_by_key("downloads.subtitle_language").value == "es"
    end

    test "an unknown code is rejected without a write", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      html = change(view, %{"subtitle_language" => ["en", "xx"]})

      assert html =~ "Invalid value for downloads.subtitle_language"
      assert Settings.get_config_setting_by_key("downloads.subtitle_language") == nil
    end

    test "DOWNLOAD_SUBTITLE_LANGUAGE locks the acquisition row, not the playback row",
         %{conn: conn} do
      System.put_env("DOWNLOAD_SUBTITLE_LANGUAGE", "en")

      on_exit(fn -> System.delete_env("DOWNLOAD_SUBTITLE_LANGUAGE") end)

      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      assert has_element?(view, "#language-subtitle_language-es[disabled]")
      refute has_element?(view, "#language-subtitle_playback_language-es[disabled]")
    end

    test "the legacy SUBTITLE_LANGUAGE still locks the acquisition row", %{conn: conn} do
      System.put_env("SUBTITLE_LANGUAGE", "en")

      on_exit(fn -> System.delete_env("SUBTITLE_LANGUAGE") end)

      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      assert has_element?(view, "#language-subtitle_language-es[disabled]")
    end
  end

  describe "subtitle playback" do
    test "its chips write the playback key", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      change(view, %{"subtitle_playback_language" => ["de"]})

      setting = Settings.get_config_setting_by_key("streaming.subtitle_language")
      assert setting.value == "de"
      assert setting.category == :streaming
      assert Mydia.Config.get().streaming.subtitle_language == ["de"]
      assert Settings.get_config_setting_by_key("downloads.subtitle_language") == nil
    end

    test "its More languages picker routes to its own field", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      change(view, %{
        "_target" => ["subtitle_playback_language_add"],
        "subtitle_playback_language" => ["de"],
        "subtitle_playback_language_add" => "th"
      })

      assert Settings.get_config_setting_by_key("streaming.subtitle_language").value == "de,th"
      assert Settings.get_config_setting_by_key("downloads.subtitle_language") == nil
    end

    test "SUBTITLE_PLAYBACK_LANGUAGE locks it, not the acquisition row", %{conn: conn} do
      System.put_env("SUBTITLE_PLAYBACK_LANGUAGE", "de")

      on_exit(fn -> System.delete_env("SUBTITLE_PLAYBACK_LANGUAGE") end)

      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      assert has_element?(view, "#language-subtitle_playback_language-de[disabled]")
      refute has_element?(view, "#language-subtitle_language-es[disabled]")
    end

    test "is hidden with the player disabled, unlike the acquisition row", %{conn: conn} do
      disable_player()

      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      refute has_element?(view, "#language-row-subtitle-playback")
      assert has_element?(view, "#language-row-subtitles")
    end

    test "its last chip is not locked, so empty is reachable", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      change(view, %{"subtitle_playback_language" => ["de"]})

      assert has_element?(view, "#language-subtitle_playback_language-de[checked]")
      refute has_element?(view, "#language-subtitle_playback_language-de[disabled]")
    end

    test "unchecking every chip clears it to no automatic subtitle", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      change(view, %{"subtitle_playback_language" => ["de"]})
      assert Mydia.Config.get().streaming.subtitle_language == ["de"]

      # What the browser sends once the last chip is unchecked: only the
      # control's always-present empty input.
      change(view, %{
        "_target" => ["subtitle_playback_language"],
        "subtitle_playback_language" => [""]
      })

      # The clear stores the empty override rather than deleting the row:
      # deleting it let a YAML streaming.subtitle_language reassert itself on
      # the next reload, switching automatic subtitles back on. A row holding
      # "" is what reads back as no automatic subtitle.
      setting = Settings.get_config_setting_by_key("streaming.subtitle_language")
      refute is_nil(setting), "the override must be stored, not deleted"
      assert setting.value == ""
      # The stored "" is what `Paths.cast_value/2` reads as unset, so the raw
      # merged field is nil rather than a list; it read [] here before only
      # because the row was gone and the schema default applied. Every reader of
      # this list-shaped key still hands back []: `get_config/2` through its
      # default, `current/0` with `|| []`.
      assert Mydia.Config.get().streaming.subtitle_language in [nil, []]
      assert Mydia.Settings.get_config([:streaming, :subtitle_language], []) == []
      assert LanguageSettings.current()["streaming.subtitle_language"].value == []
    end

    test "each row is announced under its own name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/admin/settings")

      assert has_element?(
               view,
               "#language-row-subtitles [role='group'][aria-label='Subtitle languages']"
             )

      assert has_element?(
               view,
               "#language-row-subtitle-playback [role='group'][aria-label='Playback subtitles']"
             )
    end
  end
end
