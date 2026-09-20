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
end
