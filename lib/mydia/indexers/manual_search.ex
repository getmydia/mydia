defmodule Mydia.Indexers.ManualSearch do
  @moduledoc """
  The search a user runs by hand, from the media page or the search page.

  Both screens stream per-indexer progress, deduplicate, and report paused
  indexers, so the options live here rather than in either LiveView.

  It is `interactive`: the built-in Cardigann engine keeps releases Prowlarr's
  validity rule would drop, as Prowlarr's interactive search does (see
  `Mydia.Indexers.Cardigann.AdapterSupport.drop_invalid_releases/3`).
  """

  alias Mydia.Indexers

  @doc """
  Runs the search, sending `{:indexer_search_started, search_id, pending}` and
  then one `{:indexer_progress, search_id, progress}` per indexer to `notify`.

  `indexer_ids` scopes the search to a subset of the enabled indexers. It
  defaults to `nil`, which searches all of them; a single-indexer retry passes
  `[indexer_id]` so retrying one failed indexer does not re-run (and re-set to
  `:pending`) every other one. `Indexers.search_all/2` treats a `nil` value the
  same as the option being absent.
  """
  @spec run(String.t(), non_neg_integer(), pid(), term(), [term()] | nil) ::
          {:ok, list(), list()}
  def run(query, min_seeders, notify, search_id, indexer_ids \\ nil) do
    opts = [
      min_seeders: min_seeders,
      deduplicate: true,
      indexer_ids: indexer_ids,
      report_paused: true,
      interactive: true,
      on_start: fn pending -> send(notify, {:indexer_search_started, search_id, pending}) end,
      on_indexer_result: fn progress -> send(notify, {:indexer_progress, search_id, progress}) end
    ]

    {:ok, %{results: results, indexer_errors: indexer_errors}} = Indexers.search_all(query, opts)

    {:ok, results, indexer_errors}
  end
end
