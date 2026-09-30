defmodule Mydia.Plugins.DeclaredSettings do
  @moduledoc """
  Writes plugin settings declared in env (`PLUGIN_<N>_SLUG` +
  `PLUGIN_<N>_SETTINGS`) or YAML (`plugin_settings:`) onto the installed
  plugin's config row.

  A declaration only carries settings. It never installs, approves, enables or
  grants. It goes through `Mydia.Plugins.update_settings/2`, the path the admin
  settings modal uses, so the `net:http` grant, the default instance and the
  live descriptor follow. Env wins over the UI: declared keys are read-only in
  the settings modal and dropped from its saves.

  Runs at boot, after an install, and when a bundled plugin is first seeded. A
  declared slug with no installed row waits for its install. Removing a
  declaration leaves the last written value as an ordinary editable setting.
  """

  alias Mydia.Plugins
  alias Mydia.Settings
  alias Mydia.Settings.PluginConfig
  alias Mydia.Settings.RuntimeConfig

  require Logger

  @doc "Applies the declarations of every declared slug."
  @spec sync_all() :: :ok
  def sync_all do
    decls = RuntimeConfig.get_runtime_plugin_settings()

    decls
    |> Enum.frequencies_by(& &1.slug)
    |> Enum.each(fn {slug, count} ->
      if count > 1 do
        Logger.warning("plugin #{slug} has settings declared #{count} times; later keys win")
      end
    end)

    decls |> Enum.map(& &1.slug) |> Enum.uniq() |> Enum.each(&sync/1)
  end

  @doc "Applies `slug`'s declared settings to its installed row, if both exist."
  @spec sync(String.t()) :: :ok
  def sync(slug) when is_binary(slug) do
    case {Map.get(declarations(), slug), Settings.get_plugin_config_by_slug(slug)} do
      {nil, _config} ->
        :ok

      {_declared, nil} ->
        Logger.info(
          "plugin #{slug} has declared settings but is not installed; they apply on install"
        )

      {declared, config} ->
        write(config, accepted(config, declared, true))
    end

    :ok
  rescue
    error ->
      Logger.warning(
        "could not apply declared settings for plugin #{slug}: #{Exception.message(error)}"
      )

      :ok
  end

  @doc "The declared setting keys for `config` that its manifest accepts."
  @spec keys(PluginConfig.t()) :: [String.t()]
  def keys(%PluginConfig{slug: slug} = config) do
    case Map.get(declarations(), slug) do
      nil -> []
      declared -> config |> accepted(declared, false) |> Map.keys() |> Enum.sort()
    end
  end

  # Declared settings by slug. A later declaration's keys override an earlier one's.
  defp declarations do
    Enum.reduce(RuntimeConfig.get_runtime_plugin_settings(), %{}, fn decl, acc ->
      Map.update(acc, decl.slug, decl.settings || %{}, &Map.merge(&1, decl.settings || %{}))
    end)
  end

  # Keeps the declared keys the manifest's settings_schema defines and whose URL
  # values pass the modal's check. `log?` is false for UI reads.
  defp accepted(config, declared, log?) do
    schema = settings_schema(config)
    known = MapSet.new(schema, & &1["key"])

    Enum.reduce(declared, %{}, fn {key, value}, acc ->
      cond do
        not MapSet.member?(known, key) ->
          if log?,
            do:
              Logger.warning(
                "plugin #{config.slug}: ignoring declared setting #{inspect(key)}, which its manifest does not define"
              )

          acc

        match?({:error, _}, Plugins.validate_url_settings(schema, %{key => value})) ->
          if log?,
            do:
              Logger.warning(
                "plugin #{config.slug}: ignoring declared setting #{inspect(key)}: not a full http(s) URL"
              )

          acc

        true ->
          Map.put(acc, key, value)
      end
    end)
  end

  defp settings_schema(%PluginConfig{manifest: %{"settings_schema" => schema}})
       when is_list(schema),
       do: schema

  defp settings_schema(_config), do: []

  defp write(_config, accepted) when map_size(accepted) == 0, do: :ok

  defp write(config, accepted) do
    if Map.take(config.settings || %{}, Map.keys(accepted)) == accepted do
      :ok
    else
      case Plugins.update_settings(config.slug, accepted) do
        {:ok, _config} ->
          :ok

        {:error, error} ->
          Logger.warning(
            "could not apply declared settings for plugin #{config.slug}: #{inspect(error)}"
          )
      end
    end
  end
end
