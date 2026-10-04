defmodule Mydia.Plugins.DeclaredSources do
  @moduledoc """
  Persists plugin sources declared in YAML (`plugin_sources:`) or env
  (`PLUGINS_SOURCE_<N>_*`) as `plugin_sources` rows marked `declared`, which the
  admin UI shows read-only. The declared key is authoritative on every boot.

  A row whose declaration disappeared is kept, disabled and no longer declared,
  rather than deleted, so a mistyped env var never orphans installed plugins.
  """

  import Ecto.Query

  alias Mydia.Plugins.PluginSource
  alias Mydia.Repo
  alias Mydia.Settings.RuntimeConfig

  require Logger

  @spec sync() :: :ok
  def sync do
    declared = Enum.uniq_by(RuntimeConfig.get_runtime_plugin_sources(), & &1.url)
    urls = MapSet.new(declared, & &1.url)

    Enum.each(declared, &upsert/1)

    from(s in PluginSource, where: s.declared)
    |> Repo.all()
    |> Enum.reject(&MapSet.member?(urls, &1.url))
    |> Enum.each(&release/1)

    :ok
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
