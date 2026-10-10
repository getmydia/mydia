defmodule Mydia.Indexers.Structs.IndexerProgress do
  @moduledoc """
  One indexer's outcome within a `Mydia.Indexers.search_all/2` fan-out.

  Delivered incrementally through the `:on_start` and `:on_indexer_result`
  callbacks so a manual-search LiveView can render each indexer as it settles
  instead of waiting for the slowest one.

  `:on_start` emits one `:pending` entry per indexer before any request is
  made. `:on_indexer_result` emits the settled replacement, keyed by the same
  `indexer_id`.

  `results` carries the actual releases and can be large. Consumers that keep
  these structs in LiveView assigns should clear `results` after folding them
  into their own accumulator and rely on `result_count` for display.

  `paused` lists the indexers Prowlarr skipped because it has them paused
  after failures. Filled only for Prowlarr configs, and only when the caller
  passed `report_paused: true` to `search_all/2`.
  """

  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.Structs.PausedIndexer

  @type status :: :pending | :ok | :error | :timeout

  @type t :: %__MODULE__{
          indexer: String.t(),
          indexer_id: String.t() | nil,
          status: status(),
          results: [SearchResult.t()],
          result_count: non_neg_integer() | nil,
          error: String.t() | nil,
          duration_ms: non_neg_integer() | nil,
          completed: non_neg_integer() | nil,
          total: pos_integer() | nil,
          paused: [PausedIndexer.t()]
        }

  defstruct [
    :indexer,
    :indexer_id,
    :result_count,
    :error,
    :duration_ms,
    :completed,
    :total,
    status: :pending,
    results: [],
    paused: []
  ]
end
