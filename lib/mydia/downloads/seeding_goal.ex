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

  `Mydia.Downloads.ClientRemoval.terms_met?/2` applies this before automatic
  removal, and the Downloads page shows `for_download/2`.
  """

  alias Mydia.Downloads.ObservedSeedTime
  alias Mydia.Indexers.Structs.TrackerTerms

  @type t :: %__MODULE__{
          tracker: String.t() | nil,
          private?: boolean() | nil,
          required_ratio: float() | nil,
          required_seed_time: non_neg_integer() | nil,
          ratio: float() | nil,
          seeding_time: non_neg_integer() | nil,
          met?: boolean()
        }

  defstruct [
    :tracker,
    :private?,
    :required_ratio,
    :required_seed_time,
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
  """
  @spec for_download(map(), DateTime.t()) :: t() | nil
  def for_download(download, now \\ DateTime.utc_now()) do
    terms = terms(download)

    if applies?(terms) do
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
        ratio: ratio,
        seeding_time: seeding_time,
        met?: met?(terms, ratio, seeding_time)
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
