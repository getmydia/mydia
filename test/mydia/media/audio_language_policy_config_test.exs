defmodule Mydia.Media.AudioLanguagePolicyConfigTest do
  # Replaces the cached runtime config, which production code reads globally,
  # so this module cannot run alongside other tests.
  use ExUnit.Case, async: false

  alias Mydia.Config.Schema
  alias Mydia.Media.AudioLanguagePolicy
  alias Mydia.Media.MediaItem

  setup do
    original = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original do
        Application.put_env(:mydia, :runtime_config, original)
      else
        Application.delete_env(:mydia, :runtime_config)
      end
    end)
  end

  defp put_config(fun), do: Application.put_env(:mydia, :runtime_config, fun.(Schema.defaults()))

  test "server_language/0 reads downloads.audio_language" do
    put_config(fn config -> %{config | downloads: %{config.downloads | audio_language: "de"}} end)

    assert AudioLanguagePolicy.server_language() == "de"
  end

  test "streaming.audio_language, which picks the playback track, never reaches ranking" do
    put_config(fn config ->
      %{
        config
        | downloads: %{config.downloads | audio_language: "original"},
          streaming: %{config.streaming | audio_language: ["fr", "en"]}
      }
    end)

    item = %MediaItem{download_audio_language: nil, metadata: %{original_language: "ja"}}

    assert AudioLanguagePolicy.effective(item).languages == ["ja"]
  end
end
