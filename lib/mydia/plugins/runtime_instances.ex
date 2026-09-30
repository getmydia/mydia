defmodule Mydia.Plugins.RuntimeInstances do
  @moduledoc """
  Persists plugin instances declared in YAML (`plugin_instances:`) or env
  (`PLUGIN_<SLUG>_<N>_<KEY>`) as DB rows, so their links, store entries and
  logs key on an ordinary instance id.

  A declared instance is identified by `(plugin, name)` through the row's
  `runtime_key`, so reordering declarations never moves links between servers.
  Declared settings are authoritative on every boot, except `token`, which is
  stored as the instance's `owner` credential rather than as a setting. A
  declared `url` becomes an approved endpoint.

  A row whose declaration disappeared is kept as a disabled, UI-managed
  instance rather than deleted, so a mistyped env var never destroys account
  links.
  """

  import Ecto.Query

  alias Mydia.Config.Schema.PluginInstanceDecl
  alias Mydia.Plugins.AccountLinks
  alias Mydia.Plugins.Instance
  alias Mydia.Plugins.Instances
  alias Mydia.Plugins.Setup
  alias Mydia.Repo
  alias Mydia.Settings.RuntimeConfig

  require Logger

  @spec sync() :: :ok
  def sync do
    declared =
      RuntimeConfig.get_runtime_plugin_instances()
      |> Enum.reduce({[], MapSet.new()}, fn decl, {kept, seen} ->
        key = {decl.plugin, decl.name}

        if MapSet.member?(seen, key) do
          Logger.warning(
            "plugin #{decl.plugin} declares instance #{inspect(decl.name)} more than once; skipping the duplicate"
          )

          {kept, seen}
        else
          {[decl | kept], MapSet.put(seen, key)}
        end
      end)
      |> elem(0)
      |> Enum.reverse()

    Enum.each(declared, &upsert/1)
    release_undeclared(declared)
    :ok
  end

  @doc "Declarations translated from the deprecated `MEDIA_SERVER_<N>_*` / `media_servers:` Plex form."
  @spec legacy_declarations() :: [PluginInstanceDecl.t()]
  def legacy_declarations do
    Enum.filter(RuntimeConfig.get_runtime_plugin_instances(), &(&1.legacy_source != nil))
  end

  defp upsert(decl) do
    declared_settings = decl.settings || %{}
    token = declared_settings["token"]
    settings = Map.delete(declared_settings, "token")
    attrs = %{name: decl.name, enabled: decl.enabled, settings: settings, runtime_key: decl.name}

    result =
      case Instances.find_runtime(decl.plugin, decl.name) do
        nil -> Instances.create(decl.plugin, attrs)
        instance -> Instances.update(instance, attrs)
      end

    case result do
      {:ok, instance} ->
        approve_url(instance, settings["url"], token)
        store_token(instance, token)

      {:error, changeset} ->
        Logger.warning(
          "could not apply declared plugin instance #{decl.plugin}/#{decl.name}: #{inspect(changeset.errors)}"
        )
    end
  end

  # A declared instance has no setup session, so a token without a url leaves
  # it with a credential but no approved endpoint to use it on.
  defp approve_url(instance, url, token) when url in [nil, ""] do
    if token not in [nil, ""] do
      Logger.warning(
        "plugin instance #{instance.plugin_slug}/#{instance.name} declares a token but no url; " <>
          "it cannot reach its server until the declaration sets one"
      )
    end

    :ok
  end

  defp approve_url(instance, url, _token) do
    case Setup.endpoint_from_url(url) do
      {:ok, endpoint} ->
        {:ok, _} = Instances.approve_endpoints(instance, [endpoint])

      :error ->
        Logger.warning(
          "plugin instance #{instance.plugin_slug}/#{instance.name} declares an unusable url #{inspect(url)}"
        )
    end
  end

  defp store_token(_instance, token) when token in [nil, ""], do: :ok

  defp store_token(instance, token) do
    {:ok, _} = AccountLinks.put_credential(instance.id, :owner, token)
    :ok
  end

  defp release_undeclared(declared) do
    keep = MapSet.new(declared, &{&1.plugin, &1.name})

    Instance
    |> where([i], not is_nil(i.runtime_key))
    |> Repo.all()
    |> Enum.reject(&MapSet.member?(keep, {&1.plugin_slug, &1.runtime_key}))
    |> Enum.each(fn instance ->
      Logger.warning(
        "plugin instance #{instance.plugin_slug}/#{instance.name} is no longer declared in config; " <>
          "keeping it disabled so its account links survive. Delete it in the admin UI if it is gone for good."
      )

      {:ok, _} = Instances.update(instance, %{runtime_key: nil, enabled: false})
    end)
  end
end
