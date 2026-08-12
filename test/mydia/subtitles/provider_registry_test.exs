defmodule Mydia.Subtitles.ProviderRegistryTest do
  use ExUnit.Case, async: true

  alias Mydia.Settings.SubtitleProviderConfig
  alias Mydia.Subtitles.ProviderRegistry

  test "declares the relay as enabled by default so a fresh install works" do
    relay = Enum.find(ProviderRegistry.builtins(), &(&1.type == :relay))

    assert relay.default_enabled == true
    assert relay.requires_credentials == false
  end

  test "declares credentialed providers as disabled by default" do
    open_subtitles = Enum.find(ProviderRegistry.builtins(), &(&1.type == :opensubtitles))

    assert open_subtitles.default_enabled == false
    assert open_subtitles.requires_credentials == true
  end

  test "default_configs returns only the enabled-by-default providers" do
    types = Enum.map(ProviderRegistry.default_configs(), & &1.type)

    assert :relay in types
    refute :opensubtitles in types
  end

  test "default_configs are marked as registry-sourced ids" do
    config = Enum.find(ProviderRegistry.default_configs(), &(&1.type == :relay))

    assert String.starts_with?(config.id, "registry::")
  end

  test "adapter_for resolves from the config type" do
    config = %SubtitleProviderConfig{type: :relay}

    assert ProviderRegistry.adapter_for(config) == Mydia.Subtitles.Provider.Relay
  end

  test "adapter_for honours a per-config adapter override" do
    config = %SubtitleProviderConfig{
      type: :relay,
      connection_settings: %{"adapter" => Some.Stub.Adapter}
    }

    assert ProviderRegistry.adapter_for(config) == Some.Stub.Adapter
  end

  # connection_settings is a JSON column, so an atom written there comes back as
  # a string. Without this the override silently falls through to the real
  # adapter and a test that thought it was using a stub is not.
  test "adapter_for resolves an override that survived a JSON round-trip as a string" do
    config = %SubtitleProviderConfig{
      type: :relay,
      connection_settings: %{"adapter" => to_string(Mydia.Subtitles.Provider.Relay)}
    }

    assert ProviderRegistry.adapter_for(config) == Mydia.Subtitles.Provider.Relay
  end

  test "adapter_for ignores a named module that is not a provider adapter" do
    config = %SubtitleProviderConfig{
      type: :relay,
      connection_settings: %{"adapter" => to_string(Enum)}
    }

    assert ProviderRegistry.adapter_for(config) == Mydia.Subtitles.Provider.Relay
  end

  test "adapter_for ignores an override naming a module that does not exist" do
    config = %SubtitleProviderConfig{
      type: :relay,
      connection_settings: %{"adapter" => "Elixir.Definitely.Not.Loaded"}
    }

    assert ProviderRegistry.adapter_for(config) == Mydia.Subtitles.Provider.Relay
  end
end
