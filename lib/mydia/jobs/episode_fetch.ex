defmodule Mydia.Jobs.EpisodeFetch do
  @moduledoc """
  Fetches the episodes of a newly added TV show in the background.

  Adding a show used to fetch every season from the metadata relay inside the
  add request. This job moves that work out: it fetches the episodes, applies
  the initial season monitoring, records the `media_item.episodes_refreshed`
  event and, when the add asked for it, queues the release search (which needs
  the episodes to exist).

  A relay failure returns `{:error, reason}` so Oban retries with backoff.

  `run/2` takes an optional relay config so tests can inject a Bypass relay.
  """

  use Oban.Worker,
    queue: :media,
    max_attempts: 3,
    unique: [
      period: :infinity,
      keys: [:media_item_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query

  require Logger

  alias Mydia.Accounts.Scope
  alias Mydia.Events
  alias Mydia.Media
  alias Mydia.Media.MediaItem
  alias Mydia.Repo

  @pending_states ~w(available scheduled executing retryable)
  @worker_name "Mydia.Jobs.EpisodeFetch"

  defmodule Args do
    @moduledoc false
    defstruct [:media_item_id, season_monitoring: "all", search_on_add: false]

    @type t :: %__MODULE__{
            media_item_id: String.t() | nil,
            season_monitoring: String.t(),
            search_on_add: boolean()
          }

    def parse(raw) when is_map(raw) do
      %__MODULE__{
        media_item_id: Map.get(raw, "media_item_id"),
        season_monitoring: Map.get(raw, "season_monitoring") || "all",
        search_on_add: Map.get(raw, "search_on_add") == true
      }
    end
  end

  @doc """
  Enqueues an episode fetch for `media_item`.

  Only one job per media item may be pending. When one already is, it is
  returned instead of inserting a second.

  ## Options

    * `:season_monitoring` - string, defaults to `"all"`
    * `:search_on_add` - boolean, defaults to `false`
  """
  @spec enqueue(MediaItem.t(), keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(%MediaItem{} = media_item, opts \\ []) do
    # Oban's unique option is not enforced in test (engine: false), and the
    # pending check keeps the guarantee identical on both adapters.
    case pending_job(media_item.id) do
      %Oban.Job{} = job ->
        {:ok, job}

      nil ->
        args =
          %{"media_item_id" => media_item.id}
          |> put_arg("season_monitoring", Keyword.get(opts, :season_monitoring))
          |> put_arg("search_on_add", Keyword.get(opts, :search_on_add, false) || nil)

        args |> new() |> Mydia.Jobs.insert()
    end
  end

  defp put_arg(args, _key, nil), do: args
  defp put_arg(args, key, value), do: Map.put(args, key, value)

  @doc "True when an episode fetch for `media_item_id` is waiting, running or retrying."
  @spec pending?(String.t()) :: boolean()
  def pending?(media_item_id), do: pending_job(media_item_id) != nil

  defp pending_job(media_item_id) do
    # Filtered in Elixir: JSON path operators differ between SQLite and PostgreSQL.
    # The pending set is expected to stay tiny (one row per in-flight add), so
    # loading it all is acceptable.
    Oban.Job
    |> where([j], j.worker == @worker_name and j.state in @pending_states)
    |> Repo.all()
    |> Enum.find(&(&1.args["media_item_id"] == media_item_id))
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: raw_args} = job) do
    run(Args.parse(raw_args), nil, final_attempt?: job.attempt >= job.max_attempts)
  end

  @doc """
  Runs the fetch.

  ## Options

    * `:final_attempt?` - when true, a partial season fetch is accepted instead
      of retried. Defaults to `true`, so direct callers never get a retry error.
  """
  @spec run(Args.t(), map() | nil, keyword()) ::
          :ok | {:discard, :not_found} | {:error, term()}
  def run(%Args{} = args, config, opts \\ []) do
    final_attempt? = Keyword.get(opts, :final_attempt?, true)

    with {:ok, item} <- load_tv_show(args.media_item_id),
         {:ok, count} <-
           Media.fetch_episodes_for_new_show(item,
             season_monitoring: args.season_monitoring,
             config: config
           ),
         :ok <- check_complete(item, final_attempt?) do
      Events.episodes_refreshed(item, count, :job, "episode_fetch")
      Mydia.Search.maybe_queue_search(item, args.search_on_add)
      :ok
    end
  end

  # EpisodeSync returns {:ok, count} even when some seasons failed, and then
  # leaves seasons_refreshed_at unstamped. Retry until the last attempt, which
  # keeps what exists so the user still gets their episodes and search.
  defp check_complete(item, final_attempt?) do
    case Repo.get(MediaItem, item.id) do
      %MediaItem{seasons_refreshed_at: nil} when final_attempt? ->
        Logger.warning(
          "Episode fetch for #{item.title} finished with failed seasons, keeping the partial result"
        )

        :ok

      %MediaItem{seasons_refreshed_at: nil} ->
        {:error, :partial_refresh}

      _ ->
        :ok
    end
  end

  defp load_tv_show(id) when is_binary(id) do
    case Media.get_media_item!(Scope.system(), id) do
      %MediaItem{type: "tv_show"} = item -> {:ok, item}
      _ -> {:discard, :not_found}
    end
  rescue
    Ecto.NoResultsError -> {:discard, :not_found}
  end

  defp load_tv_show(_), do: {:discard, :not_found}
end
