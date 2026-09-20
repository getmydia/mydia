defmodule MydiaWeb.AdminSettingsLive.LanguageSettingsTest do
  use Mydia.DataCase, async: false

  alias MydiaWeb.AdminSettingsLive.LanguageSettings

  test "current/0 reports both subtitle keys" do
    settings = LanguageSettings.current()

    assert Map.has_key?(settings, "downloads.subtitle_language")
    assert Map.has_key?(settings, "streaming.subtitle_language")
  end

  test "saving the playback chips writes only the playback key" do
    {:ok, written} =
      LanguageSettings.save(
        %{"_target" => ["subtitle_playback_language"], "subtitle_playback_language" => ["en"]},
        nil
      )

    assert written == ["streaming.subtitle_language"]
  end

  test "saving the acquisition chips writes only the acquisition key" do
    {:ok, written} =
      LanguageSettings.save(
        %{"_target" => ["subtitle_language"], "subtitle_language" => ["de"]},
        nil
      )

    assert written == ["downloads.subtitle_language"]
  end

  test "clearing the playback chips removes the override instead of writing an empty string" do
    {:ok, ["streaming.subtitle_language"]} =
      LanguageSettings.save(%{"subtitle_playback_language" => ["de"]}, nil)

    assert Mydia.Settings.get_config_setting_by_key("streaming.subtitle_language")

    {:ok, written} =
      LanguageSettings.save(
        %{"_target" => ["subtitle_playback_language"], "subtitle_playback_language" => [""]},
        nil
      )

    assert written == ["streaming.subtitle_language"]
    assert Mydia.Settings.get_config_setting_by_key("streaming.subtitle_language") == nil
    assert LanguageSettings.current()["streaming.subtitle_language"].value == []
  end

  test "clearing the acquisition chips is a no-op, since subtitle search needs a language" do
    assert {:ok, []} =
             LanguageSettings.save(
               %{"_target" => ["subtitle_language"], "subtitle_language" => [""]},
               nil
             )

    assert Mydia.Settings.get_config_setting_by_key("downloads.subtitle_language") == nil
  end
end
