defmodule Mydia.Media.RemoteSignals do
  @moduledoc """
  The certification and category of a title that is not in the library.

  Search, discover and list endpoints carry no certification, and TVDB search
  hits carry no genre or origin either, so `Mydia.Media.RemoteFilter` asks
  for them per title. One detail fetch with only the rating resource
  appended answers both. Results are cached for a day and shared by every
  account: a certification does not depend on who is asking.

  A failed lookup is `:error` and is not cached. The filter treats it as
  unrated, which an age limit hides.
  """

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

    results
    |> Enum.map(&{&1.media_type, Ref.from_search_result(&1)})
    |> Enum.uniq()
    |> Task.async_stream(fn key -> {key, lookup(key, config)} end,
      max_concurrency: @max_concurrency,
      timeout: @timeout,
      on_timeout: :kill_task,
      zip_input_on_exit: true
    )
    |> Map.new(fn
      {:ok, {key, signals}} -> {key, signals}
      {:exit, {key, _reason}} -> {key, :error}
    end)
  end

  defp lookup({media_type, ref}, config) do
    case Cache.fetch(cache_key(ref, media_type), fn -> fetch(config, ref, media_type) end,
           ttl: @ttl
         ) do
      {:ok, signals} -> signals
      _error -> :error
    end
  end

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
