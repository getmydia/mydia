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

  test "clearing the playback chips writes nothing when the key already resolves to none" do
    # `save/2` writes only keys whose value differs from the resolved one, so a
    # clear over a key that already resolves to no language is a no-op rather
    # than a stored "": the write that records "none" happens when it overrides
    # something, the same as every other key on the page. The clear that does
    # store an override is covered by "outranks a YAML value" below.
    assert {:ok, []} =
             LanguageSettings.save(
               %{
                 "_target" => ["subtitle_playback_language"],
                 "subtitle_playback_language" => [""]
               },
               nil
             )

    assert Mydia.Settings.get_config_setting_by_key("streaming.subtitle_language") == nil
  end

  test "clearing playback subtitles outranks a YAML value" do
    # The row's own copy says "Leave empty for none". Deleting the database row
    # instead let a YAML streaming.subtitle_language reassert itself on the next
    # reload, switching automatic subtitles back on for every show nobody has
    # chosen for.
    original_runtime = Application.get_env(:mydia, :runtime_config)

    Application.put_env(:mydia, :runtime_config, %{
      Mydia.Config.Schema.defaults()
      | streaming: %{
          Mydia.Config.Schema.defaults().streaming
          | subtitle_language: ["en"]
        }
    })

    on_exit(fn ->
      if original_runtime do
        Application.put_env(:mydia, :runtime_config, original_runtime)
      else
        Application.delete_env(:mydia, :runtime_config)
      end
    end)

    assert {:ok, ["streaming.subtitle_language"]} =
             LanguageSettings.save(
               %{
                 "_target" => ["subtitle_playback_language"],
                 "subtitle_playback_language" => []
               },
               nil
             )

    setting = Mydia.Settings.get_config_setting_by_key("streaming.subtitle_language")
    refute is_nil(setting), "the override must be stored, not deleted"
    assert setting.value in ["", nil]

    # The stored row has to resolve to no language, so the merge ends at [] for
    # a key the YAML sets rather than falling back to the YAML list. Either
    # shape reads back as [], which is what the list-shaped consumers expect.
    assert {:ok, _path, value} =
             Mydia.Config.Schema.Paths.cast_overlay(setting.key, setting.value)

    assert value in [nil, []]
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
