defmodule Mydia.Settings.SubtitleProviderConfigsTest do
  use Mydia.DataCase, async: true

  alias Mydia.Settings.ServiceConfigs
  alias Mydia.SubtitleProviderFixtures

  test "returns registry defaults when nothing is configured" do
    configs = ServiceConfigs.list_subtitle_provider_configs()

    assert Enum.any?(configs, &(&1.type == :relay))
    assert Enum.all?(configs, &String.starts_with?(&1.id, "registry::"))
  end

  test "a database row of the same type replaces the registry default" do
    SubtitleProviderFixtures.config_fixture(%{name: "My Relay", type: :relay, priority: 7})

    configs = ServiceConfigs.list_subtitle_provider_configs()
    relays = Enum.filter(configs, &(&1.type == :relay))

    assert [relay] = relays
    assert relay.name == "My Relay"
    assert relay.priority == 7
  end

  test "enabled: true filters out disabled rows" do
    SubtitleProviderFixtures.config_fixture(%{
      name: "Off",
      type: :opensubtitles,
      enabled: false,
      api_key: "k",
      username: "u",
      password: "p"
    })

    names =
      [enabled: true]
      |> ServiceConfigs.list_subtitle_provider_configs()
      |> Enum.map(& &1.name)

    refute "Off" in names
  end

  test "results are ordered by priority, highest first" do
    SubtitleProviderFixtures.config_fixture(%{
      name: "Low",
      type: :subdl,
      priority: 1,
      api_key: "k"
    })

    priorities =
      ServiceConfigs.list_subtitle_provider_configs()
      |> Enum.map(& &1.priority)

    assert priorities == Enum.sort(priorities, :desc)
  end

  test "providers of equal priority are ordered alphabetically" do
    for name <- ["Zeta", "Alpha", "Mid"] do
      SubtitleProviderFixtures.config_fixture(%{name: name, type: :relay, priority: 5})
    end

    names =
      [enabled: true]
      |> ServiceConfigs.list_subtitle_provider_configs()
      |> Enum.filter(&(&1.priority == 5))
      |> Enum.map(& &1.name)

    assert names == ["Alpha", "Mid", "Zeta"]
  end
end
