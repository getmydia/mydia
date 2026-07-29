defmodule Mydia.Downloads.Client.Debrid.ProviderJob do
  @moduledoc """
  Canonical internal representation of a debrid provider's view of a
  submitted release.

  The four provider modules each parse their service's native job/torrent
  payload into a `ProviderJob` so the dispatch adapter (`Debrid`) and the
  per-download `Fetcher` GenServer can speak a single vocabulary regardless
  of which debrid service the operator picked.

  See `t:state/0` for the unified state taxonomy.

  Terminal jobs (`state: :error`) also carry `:failure_category` and
  `:failure_detail` — the provider's own answer to *why*, normalised into
  the shared vocabulary in `Mydia.Downloads.Client.FailureCategory`. Both
  are `nil` for every non-terminal state and for terminal states a provider
  has not mapped.
  """

  alias Mydia.Downloads.Client.FailureCategory

  @type state :: :queued | :downloading | :finalizing | :ready | :error

  @enforce_keys [:provider_id, :state]
  defstruct [
    :provider_id,
    :state,
    :progress,
    :name,
    :total_bytes,
    :files,
    :hoster_links,
    :raw_status,
    :failure_category,
    :failure_detail
  ]

  @type file_entry :: %{
          required(:id) => term(),
          optional(:name) => String.t(),
          optional(:size) => non_neg_integer(),
          optional(:mime_type) => String.t() | nil,
          optional(:path) => String.t()
        }

  @type t :: %__MODULE__{
          provider_id: String.t(),
          state: state(),
          progress: float() | nil,
          name: String.t() | nil,
          total_bytes: non_neg_integer() | nil,
          files: [file_entry()] | nil,
          hoster_links: [String.t()] | nil,
          raw_status: term() | nil,
          failure_category: FailureCategory.t() | nil,
          failure_detail: String.t() | nil
        }

  @doc """
  Creates a new `ProviderJob`.

  `:provider_id` and `:state` are required; everything else is optional and
  may be omitted by providers that don't surface that detail.
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    struct!(__MODULE__, attrs)
  end

  @doc """
  The canonical state vocabulary, in order from earliest to terminal.
  """
  @spec states() :: [state()]
  def states, do: [:queued, :downloading, :finalizing, :ready, :error]
end
