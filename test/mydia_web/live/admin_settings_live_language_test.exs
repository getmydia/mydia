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
      System.put_env("DOWNLOAD_AUDIO_LANGUAGE", "ja")
      on_exit(fn -> System.delete_env("DOWNLOAD_AUDIO_LANGUAGE") end)

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
  end
end
