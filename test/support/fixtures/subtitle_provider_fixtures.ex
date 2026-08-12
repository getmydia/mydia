defmodule Mydia.SubtitleProviderFixtures do
  @moduledoc """
  Fixtures for subtitle provider configuration.

  `config_fixture/1` takes an `:adapter` module and stores it in
  `connection_settings`, so each test injects its own stub without mutating
  application environment and tests stay `async: true`.
  """

  alias Mydia.Repo
  alias Mydia.Settings.SubtitleProviderConfig

  def config_fixture(attrs \\ %{}) do
    {adapter, attrs} = Map.pop(attrs, :adapter)

    connection_settings =
      attrs
      |> Map.get(:connection_settings, %{})
      |> maybe_put_adapter(adapter)

    attrs =
      attrs
      |> Map.put_new(:name, "provider-#{System.unique_integer([:positive])}")
      |> Map.put_new(:type, :relay)
      |> Map.put_new(:enabled, true)
      |> Map.put_new(:priority, 0)
      |> Map.put(:connection_settings, connection_settings)

    %SubtitleProviderConfig{}
    |> SubtitleProviderConfig.changeset(attrs)
    |> Repo.insert!()
  end

  @doc """
  Replaces the adapter used for a registry-declared provider type, by inserting a
  database row of that type carrying the stub. The row outranks the registry
  default, so the registry entry is suppressed rather than duplicated.
  """
  def stub_registry_adapter(type, adapter) do
    config_fixture(%{type: type, adapter: adapter, name: "stub-#{type}"})
  end

  defp maybe_put_adapter(settings, nil), do: settings
  defp maybe_put_adapter(settings, adapter), do: Map.put(settings, "adapter", adapter)
end
