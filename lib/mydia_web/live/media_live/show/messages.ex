defmodule MydiaWeb.MediaLive.Show.Messages do
  @moduledoc """
  Translated flash text built by the media show page.
  """

  use Gettext, backend: MydiaWeb.Gettext

  @doc "Summarises an automatic search run from its stats."
  def search_completion_message(stats) do
    indexers = stats.indexers_searched
    results = stats.results_found
    picked_up = stats.downloads_initiated

    cond do
      Map.get(stats, :error) ->
        gettext("Search failed: %{reason}", reason: stats.error)

      picked_up > 0 ->
        gettext(
          "Search complete: %{indexers} indexer(s) searched, %{results} result(s) found, %{picked_up} download(s) started",
          indexers: indexers,
          results: results,
          picked_up: picked_up
        )

      results > 0 ->
        gettext(
          "Search complete: %{indexers} indexer(s) searched, %{results} result(s) found, but none matched quality criteria",
          indexers: indexers,
          results: results
        )

      true ->
        ngettext(
          "Search complete: %{count} indexer searched, no results found",
          "Search complete: %{count} indexers searched, no results found",
          indexers
        )
    end
  end
end
