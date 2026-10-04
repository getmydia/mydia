defmodule Mydia.Plugins.Sources do
  @moduledoc """
  Third-party plugin catalogs (`plugin_sources`) and where an installed plugin
  came from.

  `origin/1` is the only place that decides a plugin's origin. Updates and the
  store compare origins, so a catalog can never update or shadow a plugin it
  did not install.
  """

  import Ecto.Query

  alias Mydia.Plugins.Index
  alias Mydia.Plugins.PluginSource
  alias Mydia.Repo

  @type origin :: :bundled | :sideloaded | :official | {:source, binary()} | :removed

  @spec list_sources() :: [PluginSource.t()]
  def list_sources, do: Repo.all(from s in PluginSource, order_by: [asc: s.inserted_at])

  @spec enabled_sources() :: [PluginSource.t()]
  def enabled_sources do
    Repo.all(from s in PluginSource, where: s.enabled, order_by: [asc: s.inserted_at])
  end

  @spec get_source(binary()) :: PluginSource.t() | nil
  def get_source(id), do: Repo.get(PluginSource, id)

  @spec add_source(map(), keyword()) :: {:ok, PluginSource.t()} | {:error, Ecto.Changeset.t()}
  def add_source(attrs, opts \\ []) do
    %PluginSource{}
    |> PluginSource.changeset(attrs, Index.seam_opts(opts))
    |> Repo.insert()
  end

  @spec remove_source(PluginSource.t()) :: {:ok, PluginSource.t()} | {:error, :declared}
  def remove_source(%PluginSource{declared: true}), do: {:error, :declared}
  def remove_source(%PluginSource{} = source), do: Repo.delete(source)

  @doc "Records a fetch of source `id`. A nil id (the official index) is a no-op."
  @spec record_fetch(binary() | nil, {:ok, map()} | {:error, String.t()}) :: :ok
  def record_fetch(nil, _result), do: :ok

  def record_fetch(id, result) do
    with %PluginSource{} = source <- get_source(id) do
      source |> PluginSource.status_changeset(status_attrs(result)) |> Repo.update()
    end

    :ok
  end

  defp status_attrs({:ok, %{name: name, plugin_count: count}}) do
    %{name: name, plugin_count: count, last_error: nil, last_fetched_at: DateTime.utc_now()}
    |> Map.reject(fn {key, value} -> key == :name and is_nil(value) end)
  end

  defp status_attrs({:error, message}), do: %{last_error: message}

  @spec origin(map()) :: origin()
  def origin(%{source_url: "bundled"}), do: :bundled
  def origin(%{source_url: "file://" <> _}), do: :sideloaded
  def origin(%{plugin_source_id: id}) when is_binary(id), do: {:source, id}

  def origin(%{source_url: url}) when is_binary(url) do
    if official_host?(url), do: :official, else: :removed
  end

  def origin(_config), do: :removed

  @doc "A short human name for an origin, for store and approval copy."
  @spec origin_name(origin()) :: String.t()
  def origin_name(:official), do: "the Mydia plugin index"
  def origin_name(:bundled), do: "Mydia (bundled)"
  def origin_name(:sideloaded), do: "a sideloaded file"
  def origin_name(:removed), do: "a removed source"

  def origin_name({:source, id}) do
    case get_source(id) do
      %PluginSource{name: name, url: url} -> name || URI.parse(url).host
      nil -> "a removed source"
    end
  end

  defp official_host?(url) do
    case Index.official_index_url() do
      index_url when is_binary(index_url) and index_url != "" ->
        URI.parse(url).host == URI.parse(index_url).host

      _ ->
        false
    end
  end
end
