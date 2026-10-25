defmodule MydiaWeb.ImportMediaLive.MatchSearchModal do
  @moduledoc false
  use Phoenix.Component
  use Gettext, backend: MydiaWeb.Gettext
  import MydiaWeb.CoreComponents
  import MydiaWeb.SegmentedControl, only: [segmented_control: 1]

  alias Mydia.Metadata.{ImageUrl, TvProvider}

  @doc """
  The "Change match" / "Identify" search modal.

  `state` is `ImportMediaLive.Index`'s `@match_search` assign, described in
  `MydiaWeb.ImportMediaLive.MatchSearch`. Selecting a result submits
  `provider_id` *and* `provider` together (the result's own provider tag),
  which is what lets the handler tell two providers' ids apart rather than
  trusting `provider_id` alone to be unique.
  """
  attr :state, :any, default: nil

  def match_search_modal(assigns) do
    ~H"""
    <.modal id="match-search-modal" show={not is_nil(@state)} on_cancel="close_match_search">
      <:title>
        <div class="flex items-center gap-2">
          <.icon name="hero-magnifying-glass" class="w-5 h-5 text-primary" />
          <span>{gettext("Change match")}</span>
        </div>
      </:title>

      <form phx-change="match_search_query" id="match-search-form" class="mt-3">
        <div class="relative">
          <.icon
            name="hero-magnifying-glass"
            class="w-4 h-4 absolute left-3.5 top-1/2 -translate-y-1/2 opacity-50"
          />
          <input
            type="text"
            name="q"
            value={@state && @state.query}
            placeholder={gettext("Search by title…")}
            phx-debounce="300"
            class="input input-bordered w-full pl-10"
          />
        </div>
      </form>

      <div :if={@state && @state.library_provider} class="mt-3">
        <.segmented_control
          id="match-provider-toggle"
          value={@state.provider}
          event="match_search_provider"
          param="provider"
          label={gettext("Metadata provider")}
        >
          <:option value="tvdb" label="TVDB" id="match-provider-tvdb" />
          <:option value="tmdb" label="TMDB" id="match-provider-tmdb" />
        </.segmented_control>
      </div>

      <div
        :if={@state}
        class="mt-4 flex flex-col gap-1.5 max-h-96 overflow-y-auto"
        id="match-results"
      >
        <div :if={@state.searching} class="flex justify-center py-8">
          <span class="loading loading-spinner loading-md text-primary"></span>
        </div>

        <div :if={!@state.searching}>
          <div :if={@state.error} class="alert alert-error text-xs py-2 mb-2">
            <.icon name="hero-exclamation-triangle" class="w-4 h-4 shrink-0" />
            <span>{@state.error}</span>
          </div>

          <div
            :if={!@state.error && @state.results == []}
            class="text-sm text-base-content/60 text-center py-10"
          >
            <.icon name="hero-film" class="w-8 h-8 mx-auto mb-2 opacity-30" />
            <p>{gettext("No results found.")}</p>
          </div>

          <button
            :for={result <- @state.results}
            type="button"
            id={"match-result-#{result.provider_id}-#{result.provider}"}
            class="flex items-center gap-3.5 p-2.5 rounded-xl hover:bg-base-200 text-left w-full transition-colors border border-transparent hover:border-base-300"
            phx-click="select_match"
            phx-value-provider_id={result.provider_id}
            phx-value-provider={result.provider}
          >
            <img
              :if={result.poster_path}
              src={ImageUrl.image_url(result.poster_path, "w92")}
              class="w-12 h-16 object-cover rounded-lg shrink-0 shadow-sm"
            />
            <div
              :if={!result.poster_path}
              class="w-12 h-16 bg-base-300 rounded-lg flex items-center justify-center shrink-0"
            >
              <.icon name="hero-film" class="w-6 h-6 opacity-30" />
            </div>
            <div class="flex-1 min-w-0">
              <p class="font-semibold text-sm truncate flex items-center gap-1.5">
                <span class="truncate">{result.title}</span>
                <span
                  :if={off_library_provider?(result, @state.library_provider)}
                  class="badge badge-ghost badge-xs shrink-0"
                >
                  {TvProvider.label(result.provider)}
                </span>
              </p>
              <p class="text-xs text-base-content/60 flex items-center gap-1.5 mt-1">
                <span :if={result.year} class="font-mono">{result.year}</span>
                <span class="badge badge-ghost badge-xs font-medium">
                  {media_type_label(result.media_type)}
                </span>
              </p>
            </div>
            <.icon name="hero-chevron-right" class="w-4 h-4 opacity-40 shrink-0" />
          </button>
        </div>
      </div>

      <:actions>
        <button class="btn btn-ghost" phx-click="close_match_search">
          {gettext("Cancel")}
        </button>
      </:actions>
    </.modal>
    """
  end

  # A TV result from the provider the library does not use. `library_provider`
  # is nil outside TV searches, so movie results never get the badge.
  defp off_library_provider?(result, library_provider) do
    not is_nil(library_provider) and result.provider in [:tvdb, :tmdb] and
      result.provider != library_provider
  end

  defp media_type_label(:tv_show), do: gettext("TV Show")
  defp media_type_label(:movie), do: gettext("Movie")
  defp media_type_label(_), do: gettext("Unknown")
end
