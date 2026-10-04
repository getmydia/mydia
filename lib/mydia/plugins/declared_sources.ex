defmodule Mydia.Plugins.DeclaredSources do
  @moduledoc """
  Persists plugin sources declared in YAML (`plugin_sources:`) or env
  (`PLUGINS_SOURCE_<N>_*`) as `plugin_sources` rows marked `declared`, which the
  admin UI shows read-only. The declared key is authoritative on every boot.

  A row whose declaration disappeared is kept, disabled and no longer declared,
  rather than deleted, so removing a declaration never deletes the plugins
  installed from it. (A malformed declaration, such as a missing key or an http
  URL, fails config validation at boot and never reaches this module.)
  """

  import Ecto.Query

  alias Mydia.Plugins.PluginSource
  alias Mydia.Repo
  alias Mydia.Settings.RuntimeConfig

  require Logger

  @spec sync() :: :ok
  def sync do
    declared = dedupe(RuntimeConfig.get_runtime_plugin_sources())
    urls = MapSet.new(declared, & &1.url)

    Enum.each(declared, &upsert/1)

    from(s in PluginSource, where: s.declared)
    |> Repo.all()
    |> Enum.reject(&MapSet.member?(urls, &1.url))
    |> Enum.each(&release/1)

    :ok
  end

  # Keeps the first declaration of a URL; a later one with another key is dropped loudly.
  defp dedupe(declarations) do
    declarations
    |> Enum.group_by(& &1.url)
    |> Enum.each(fn {url, [first | rest]} ->
      if Enum.any?(rest, &(&1.public_key != first.public_key)),
        do:
          Logger.warning(
            "plugin source #{url} is declared twice with different keys; keeping the first"
          )
    end)

    Enum.uniq_by(declarations, & &1.url)
  end

  defp upsert(decl) do
    (Repo.get_by(PluginSource, url: decl.url) || %PluginSource{})
    |> PluginSource.changeset(%{url: decl.url, public_key: decl.public_key, enabled: true})
    |> Ecto.Changeset.put_change(:declared, true)
    |> Repo.insert_or_update()
    |> case do
      {:ok, _} -> :ok
      {:error, cs} -> Logger.warning("plugin source #{decl.url} not saved: #{inspect(cs.errors)}")
    end
  end

  defp release(source) do
    source |> Ecto.Changeset.change(declared: false, enabled: false) |> Repo.update!()
  end
end
