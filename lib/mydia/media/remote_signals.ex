defmodule Mydia.Media.RemoteSignals do
  @moduledoc """
  The certification and category of a title that is not in the library.

  Search, discover and list endpoints carry no certification, and TVDB search
  hits carry no genre or origin either, so `Mydia.Media.RemoteFilter` asks
  for them per title. One detail fetch with only the rating resource
  appended answers both. Results are cached for a day and shared by every
  account: a certification does not depend on who is asking.

  A failed lookup is `:error`. It is never cached as a success, but a short
  negative entry (`@failure_ttl`) stops a slow or erroring relay from blocking
  every render for the full lookup timeout. The filter treats `:error` as
  unrated, which an age limit hides.
  """

  require Logger

  alias Mydia.Media.CategoryClassifier
  alias Mydia.Media.ContentRating
  alias Mydia.Metadata
  alias Mydia.Metadata.Cache
  alias Mydia.Metadata.Ref
  alias Mydia.Metadata.Structs.SearchResult

  defstruct [:content_rating, :age, :category]

  @type t :: %__MODULE__{
          content_rating: String.t() | nil,
          age: integer() | nil,
          category: String.t() | nil
        }

  @ttl :timer.hours(24)
  @failure_ttl :timer.seconds(60)
  @unavailable :unavailable
  @max_concurrency 10
  @timeout 5_000

  @spec cache_key(Ref.t(), :movie | :tv_show) :: String.t()
  def cache_key(ref, media_type), do: "remote_signals:#{Ref.to_param(ref)}:#{media_type}"

  @spec fetch_many([SearchResult.t()], map() | nil) :: %{
          {:movie | :tv_show, Ref.t()} => t() | :error
        }
  def fetch_many([], _config), do: %{}

  def fetch_many(results, config) do
    config = config || Metadata.default_relay_config()

    keys =
      results
      |> Enum.flat_map(fn result ->
        case ref_for(result) do
          {:ok, ref} -> [{result.media_type, ref}]
          :error -> []
        end
      end)
      |> Enum.uniq()

    # Unlinked, so a lookup that crashes or times out cannot take the caller
    # (usually a LiveView) down with it.
    Mydia.TaskSupervisor
    |> Task.Supervisor.async_stream_nolink(keys, fn key -> {key, lookup(key, config)} end,
      max_concurrency: @max_concurrency,
      timeout: @timeout,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Map.new(fn
      {:ok, {key, signals}} ->
        {key, signals}

      {:exit, {{media_type, ref} = key, _reason}} ->
        remember_failure(ref, media_type)
        {key, :error}
    end)
  end

  @doc """
  The lookup ref for a search result, or `:error` when its `provider_id` is not
  a positive integer. Such a result has no signals.
  """
  @spec ref_for(SearchResult.t()) :: {:ok, Ref.t()} | :error
  def ref_for(%SearchResult{provider_id: provider_id} = result) do
    case Integer.parse(to_string(provider_id)) do
      {id, ""} when id > 0 -> {:ok, Ref.from_search_result(%{result | provider_id: id})}
      _ -> :error
    end
  end

  defp lookup({media_type, ref}, config) do
    case Cache.fetch(cache_key(ref, media_type), fn -> fetch(config, ref, media_type) end,
           ttl: @ttl
         ) do
      {:ok, @unavailable} ->
        :error

      {:ok, signals} ->
        signals

      _error ->
        remember_failure(ref, media_type)
        :error
    end
  rescue
    error ->
      Logger.debug("Remote signals lookup raised: #{Exception.message(error)}")
      remember_failure(ref, media_type)
      :error
  catch
    kind, reason ->
      Logger.debug("Remote signals lookup #{kind}: #{inspect(reason)}")
      remember_failure(ref, media_type)
      :error
  end

  defp remember_failure(ref, media_type),
    do: Cache.put(cache_key(ref, media_type), @unavailable, ttl: @failure_ttl)

  defp fetch(config, ref, media_type) do
    case Metadata.fetch_by_ref(config, ref, media_type: media_type, append_to_response: []) do
      {:ok, metadata} ->
        {:ok,
         %__MODULE__{
           content_rating: metadata.content_rating,
           age: ContentRating.min_age(metadata.content_rating),
           category:
             media_type |> CategoryClassifier.classify_from_metadata(metadata) |> to_string()
         }}

      {:error, _} = error ->
        error
    end
  end
end
