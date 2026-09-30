defmodule Mydia.Plugins.Instances do
  @moduledoc """
  Plugin instances: per-instance settings, approved endpoints and proposed
  remote accounts (host contract 1.4).
  """
  # `update/2` is this module's public API; keep Ecto's query macro out of scope.
  import Ecto.Query, except: [update: 2]

  alias Mydia.Plugins.Instance
  alias Mydia.Repo
  alias Mydia.Settings

  @spec list(String.t()) :: [Instance.t()]
  def list(slug) when is_binary(slug) do
    Repo.all(
      from i in Instance,
        where: i.plugin_slug == ^slug,
        order_by: [asc: i.name, asc: i.inserted_at]
    )
    |> Enum.map(&put_source/1)
  end

  @doc "Enabled instances for a slug, DB-managed and config-declared alike."
  @spec list_enabled(String.t()) :: [Instance.t()]
  def list_enabled(slug), do: slug |> list() |> Enum.filter(& &1.enabled)

  @spec get(binary()) :: Instance.t() | nil
  def get(id) when is_binary(id) do
    case Repo.get(Instance, id) do
      nil -> nil
      instance -> put_source(instance)
    end
  end

  @spec get!(binary()) :: Instance.t()
  def get!(id) when is_binary(id), do: Instance |> Repo.get!(id) |> put_source()

  @doc "Marks an instance declared in YAML/env (it has a `runtime_key`) as `:runtime`."
  @spec put_source(Instance.t()) :: Instance.t()
  def put_source(%Instance{runtime_key: nil} = instance), do: %{instance | source: :db}
  def put_source(%Instance{} = instance), do: %{instance | source: :runtime}

  @doc "The instance a config declaration `(slug, key)` is persisted as, if any."
  @spec find_runtime(String.t(), String.t()) :: Instance.t() | nil
  def find_runtime(slug, key) do
    Instance
    |> where([i], i.plugin_slug == ^slug and i.runtime_key == ^key)
    |> Repo.one()
    |> case do
      nil -> nil
      instance -> put_source(instance)
    end
  end

  @doc """
  The first instance of a slug, created on first use. Single-instance plugins
  only ever have this one; it is named after the plugin config.
  """
  @spec default_instance(String.t()) :: Instance.t()
  def default_instance(slug) when is_binary(slug) do
    case Repo.one(
           from i in Instance,
             where: i.plugin_slug == ^slug,
             order_by: [asc: i.inserted_at],
             limit: 1
         ) do
      %Instance{} = inst ->
        put_source(inst)

      nil ->
        config = Settings.get_plugin_config_by_slug(slug)
        name = (config && config.name) || slug
        {:ok, inst} = create(slug, %{name: name, settings: (config && config.settings) || %{}})
        inst
    end
  end

  @spec create(String.t(), map()) :: {:ok, Instance.t()} | {:error, Ecto.Changeset.t()}
  def create(slug, attrs) when is_binary(slug) do
    config_id =
      case Settings.get_plugin_config_by_slug(slug) do
        %{id: id} -> id
        nil -> nil
      end

    %Instance{plugin_slug: slug, plugin_config_id: config_id}
    |> Instance.changeset(attrs)
    |> Repo.insert()
    |> put_source_result()
  end

  @spec update(Instance.t(), map()) :: {:ok, Instance.t()} | {:error, Ecto.Changeset.t()}
  def update(%Instance{} = instance, attrs) do
    instance |> Instance.changeset(attrs) |> Repo.update() |> put_source_result()
  end

  defp put_source_result({:ok, instance}), do: {:ok, put_source(instance)}
  defp put_source_result(error), do: error

  @doc "Deletes the instance; links, kv and log rows cascade in the database."
  @spec delete(Instance.t()) :: :ok
  def delete(%Instance{} = instance) do
    Repo.delete!(instance)
    :ok
  end

  @spec approve_endpoints(Instance.t(), [map()]) :: {:ok, Instance.t()}
  def approve_endpoints(%Instance{} = instance, endpoints) when is_list(endpoints) do
    merged =
      (instance.approved_endpoints ++ Enum.map(endpoints, &normalize_endpoint/1))
      |> Enum.map(&normalize_endpoint/1)
      |> Enum.uniq()

    update(instance, %{approved_endpoints: merged})
  end

  @spec remove_endpoint(Instance.t(), map()) :: {:ok, Instance.t()}
  def remove_endpoint(%Instance{} = instance, endpoint) do
    target = normalize_endpoint(endpoint)

    kept =
      instance.approved_endpoints
      |> Enum.map(&normalize_endpoint/1)
      |> Enum.reject(&(&1 == target))

    update(instance, %{approved_endpoints: kept})
  end

  @spec set_remote_accounts(Instance.t(), [map()]) :: {:ok, Instance.t()}
  def set_remote_accounts(%Instance{} = instance, accounts) when is_list(accounts) do
    normalized =
      Enum.map(accounts, fn a ->
        %{
          "id" => to_string(fetch(a, :id)),
          "name" => to_string(fetch(a, :name) || ""),
          "admin" => fetch(a, :admin) == true
        }
      end)

    update(instance, %{remote_accounts: normalized})
  end

  @doc "The config map injected into every guest call for this instance."
  @spec config_for(Instance.t()) :: map()
  def config_for(%Instance{} = instance) do
    Map.put(instance.settings || %{}, "instance_id", instance.id)
  end

  defp normalize_endpoint(e) do
    %{
      "scheme" => e |> fetch(:scheme) |> to_string() |> String.downcase(),
      "host" => e |> fetch(:host) |> to_string() |> String.downcase(),
      "port" => to_port(fetch(e, :port))
    }
  end

  defp to_port(p) when is_integer(p), do: p
  defp to_port(p) when is_binary(p), do: String.to_integer(p)

  defp fetch(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
