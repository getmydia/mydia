defmodule Mydia.Downloads.SeedingGoal do
  @moduledoc """
  Whether a download has seeded enough for its tracker.

  The goal comes from the tracker terms frozen on the download at grab
  (`Download.metadata["tracker_terms"]`, see
  `Mydia.Indexers.Structs.TrackerTerms`). It is met when the ratio reaches
  `minimum_ratio` or the torrent has seeded for `minimum_seed_time` seconds,
  whichever comes first (the *arr convention). With only one of the two set,
  that one decides.

  - No terms, or terms that ask for nothing and are not private: met, so
    removal behaves as it did before trackers had terms.
  - Private with no known ratio or seed time: never met. Keeping a file is
    the safe wrong answer; the operator can still remove it by hand.

  Built-in client downloads are also held to the operator's seeding target
  (`Mydia.Downloads.BuiltIn.seeding_target/0`). The goal is a conjunction:
  the tracker terms above must be met and, separately, the target (by either
  its ratio or its seed time). Neither can lower the other, and a target can
  never release a private torrent whose rules are unknown. `goal_applies?/2`
  and `goal_met?/4` are the decision. The struct from `for_download/2` keeps
  the two apart for display: `required_*` are the tracker's minimums and
  `target_*` the operator's target.

  `Mydia.Downloads.ClientRemoval.terms_met?/2` applies this before automatic
  removal, `Mydia.Downloads.BuiltIn.SeedingPolicy` before pausing, and the
  Downloads page shows `for_download/2`.
  """

  alias Mydia.Downloads.{BuiltIn, ObservedSeedTime}
  alias Mydia.Indexers.Structs.TrackerTerms

  @type t :: %__MODULE__{
          tracker: String.t() | nil,
          private?: boolean() | nil,
          required_ratio: float() | nil,
          required_seed_time: non_neg_integer() | nil,
          target_ratio: float() | nil,
          target_seed_time: non_neg_integer() | nil,
          ratio: float() | nil,
          seeding_time: non_neg_integer() | nil,
          met?: boolean()
        }

  defstruct [
    :tracker,
    :private?,
    :required_ratio,
    :required_seed_time,
    :target_ratio,
    :target_seed_time,
    :ratio,
    :seeding_time,
    met?: false
  ]

  @doc "The terms frozen on a download (or any map with `:metadata`), or nil."
  @spec terms(%{required(:metadata) => map() | nil, optional(atom()) => term()}) ::
          TrackerTerms.t() | nil
  def terms(%{metadata: metadata}) when is_map(metadata) do
    (Map.get(metadata, "tracker_terms") || Map.get(metadata, :tracker_terms))
    |> TrackerTerms.from_map()
  end

  def terms(_download), do: nil

  @doc """
  True when the download has a seeding goal: its frozen tracker terms ask it
  to keep seeding (`applies?/1`), or it belongs to the built-in client and
  the operator set a seeding target. The target is `opts[:target]` when
  given, else the client's own.
  """
  @spec goal_applies?(map(), keyword()) :: boolean()
  def goal_applies?(download, opts \\ []) do
    applies?(terms(download)) or not is_nil(target(download, opts))
  end

  @doc """
  Whether `ratio` and `seeding_time` (seconds) meet the download's goal. Both
  halves must hold:

  - the tracker terms, under `met?/3` (met when they ask for nothing, never
    when the tracker is private with no known minimum), and
  - the operator's seeding target, for built-in client downloads that have
    one: met when either its ratio or its seed time is reached.

  So a tracker minimum never lowers the operator target, and the operator
  target never lowers a tracker minimum. Options as in `goal_applies?/2`.
  """
  @spec goal_met?(map(), number() | nil, non_neg_integer() | nil, keyword()) :: boolean()
  def goal_met?(download, ratio, seeding_time, opts \\ []) do
    met?(terms(download), ratio, seeding_time) and
      target_met?(target(download, opts), ratio, seeding_time)
  end

  defp target_met?(nil, _ratio, _seeding_time), do: true

  defp target_met?(%{ratio: required_ratio, seed_time: required_time}, ratio, seeding_time),
    do: reached?(ratio, required_ratio) or reached?(seeding_time, required_time)

  # Only the built-in client's downloads are held to the operator target;
  # `opts[:target]` replaces the runtime lookup (callers that already read it).
  # A target asking for nothing is no target.
  defp target(download, opts) do
    if Map.get(download, :download_client) == BuiltIn.name() do
      case Keyword.get_lazy(opts, :target, &BuiltIn.seeding_target/0) do
        %{ratio: nil, seed_time: nil} -> nil
        target -> target
      end
    end
  end

  @doc "True when the terms ask the download to keep seeding."
  @spec applies?(TrackerTerms.t() | nil) :: boolean()
  def applies?(%TrackerTerms{} = terms) do
    terms.private? == true or not is_nil(terms.minimum_ratio) or
      not is_nil(terms.minimum_seed_time)
  end

  def applies?(nil), do: false

  @doc """
  Whether `ratio` and `seeding_time` (seconds) meet the terms. Unknown
  progress (nil) never meets a requirement.
  """
  @spec met?(TrackerTerms.t() | nil, number() | nil, non_neg_integer() | nil) :: boolean()
  def met?(terms, ratio, seeding_time) do
    if applies?(terms) do
      reached?(ratio, terms.minimum_ratio) or reached?(seeding_time, terms.minimum_seed_time)
    else
      true
    end
  end

  defp reached?(value, required) when is_number(value) and is_number(required),
    do: value >= required

  defp reached?(_value, _required), do: false

  @doc """
  Seconds a torrent has seeded: what the client reports, otherwise, while
  the client says it is seeding (`seeding?`), the time since the client's
  completion or else the download's `completed_at`. Nil otherwise.

  The wall-clock fallback is only taken while seeding: for a paused, stopped,
  missing or unreachable torrent it would count time spent not seeding, and
  a seed time goal met that way would delete data the tracker still expects.
  Time paused earlier and then resumed is still counted; clients that report
  their own seed time (qBittorrent, Transmission) are exact.
  """
  @spec seeding_time(
          non_neg_integer() | nil,
          boolean(),
          DateTime.t() | nil,
          DateTime.t() | nil,
          DateTime.t()
        ) :: non_neg_integer() | nil
  def seeding_time(reported, seeding?, client_completed_at, download_completed_at, now)

  def seeding_time(reported, _seeding?, _client, _download, _now)
      when is_integer(reported) and reported >= 0,
      do: reported

  def seeding_time(_reported, true, %DateTime{} = completed_at, _download, now),
    do: since(completed_at, now)

  def seeding_time(_reported, true, nil, %DateTime{} = completed_at, now),
    do: since(completed_at, now)

  def seeding_time(_reported, _seeding?, _client, _download, _now), do: nil

  defp since(completed_at, now), do: max(DateTime.diff(now, completed_at, :second), 0)

  @doc """
  Progress toward the goal for a Downloads row (an enriched download, or any
  map with `:metadata`, `:indexer`, `:status`, `:ratio`, `:seeding_time`,
  `:client_completed_at`, `:db_completed_at` and `:in_client?`), read the same
  way as `Mydia.Downloads.ClientRemoval.terms_met?/2`. Nil when no goal applies.
  The second argument is a `DateTime` (now) or options `:now` and `:target`.
  `met?` is `goal_met?/4`. `required_ratio` and `required_seed_time` are the
  tracker's minimums (nil when it states none, as for a private tracker with
  unknown rules); `target_ratio` and `target_seed_time` are the operator's
  target for a built-in row (nil when there is none). They are never merged.
  """
  @spec for_download(map(), DateTime.t() | keyword()) :: t() | nil
  def for_download(download, opts \\ [])

  def for_download(download, %DateTime{} = now), do: for_download(download, now: now)

  def for_download(download, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    # Resolved once; every check below reuses it.
    target = target(download, Keyword.take(opts, [:target]))
    goal_opts = [target: target]

    if goal_applies?(download, goal_opts) do
      terms = terms(download) || %TrackerTerms{}

      seeding_time =
        seeding_time(
          Map.get(download, :seeding_time) || ObservedSeedTime.seconds(download),
          currently_seeding?(download),
          Map.get(download, :client_completed_at),
          Map.get(download, :db_completed_at),
          now
        )

      ratio = known_ratio(download)

      %__MODULE__{
        tracker: Map.get(download, :indexer),
        private?: terms.private?,
        required_ratio: terms.minimum_ratio,
        required_seed_time: terms.minimum_seed_time,
        target_ratio: target && target.ratio,
        target_seed_time: target && target.seed_time,
        ratio: ratio,
        seeding_time: seeding_time,
        met?: goal_met?(download, ratio, seeding_time, goal_opts)
      }
    end
  end

  @doc """
  True when a polled row shows its torrent seeding right now. A row whose
  status comes from a stale snapshot (`:status_as_of` set, the client did not
  answer this poll) does not count.
  """
  @spec currently_seeding?(map()) :: boolean()
  def currently_seeding?(row),
    do: Map.get(row, :status) == "seeding" and is_nil(Map.get(row, :status_as_of))

  # A row whose client is unreachable or no longer holds the torrent carries a
  # placeholder ratio of 0.0; nil says "unknown" instead. Rows without the key
  # (plain maps, a bare Download) are taken at their word.
  defp known_ratio(download) do
    if Map.get(download, :in_client?, true) == true, do: Map.get(download, :ratio)
  end
end
