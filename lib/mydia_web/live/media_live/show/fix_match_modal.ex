defmodule MydiaWeb.MediaLive.Show.FixMatchModal do
  @moduledoc false
  use Phoenix.Component
  import MydiaWeb.CoreComponents
  import MydiaWeb.SegmentedControl, only: [segmented_control: 1]

  alias Mydia.Media.FixMatch
  alias MydiaWeb.MediaLive.Show.Helpers

  @doc """
  Search-then-confirm picker for re-pointing a wrongly matched item at the
  title it really is. Searches the provider in `fix_match.provider` (the
  item's own by default; a TV show can toggle to the other one) with the
  operator's query, since the stored title is the wrong one.
  """
  attr :fix_match, :map, required: true
  attr :media_item, :map, required: true

  def fix_match_modal(assigns) do
    assigns =
      assigns
      |> assign(:provider, assigns.fix_match.provider)
      |> assign(:current_id, current_id(assigns.fix_match, assigns.media_item))

    ~H"""
    <div id="fix-match-modal" class="modal modal-open">
      <div class="modal-box max-w-xl">
        <h3 class="font-bold text-lg mb-1">Fix match</h3>

        <%= if @fix_match.step == :search do %>
          <p class="text-sm opacity-75 mb-4">
            Search {provider_label(@provider)} for the title this really is.
          </p>
          <div :if={@media_item.type == "tv_show"} class="mb-3">
            <.segmented_control
              id="fix-match-provider-toggle"
              value={@provider}
              event="fix_match_provider"
              param="provider"
              label="Metadata provider"
            >
              <:option value="tvdb" label="TVDB" id="fix-match-provider-tvdb" />
              <:option value="tmdb" label="TMDB" id="fix-match-provider-tmdb" />
            </.segmented_control>
          </div>
          <.form
            for={@fix_match.form}
            id="fix-match-search-form"
            phx-submit="fix_match_search"
            class="flex gap-2 mb-4"
          >
            <div class="flex-1">
              <.input field={@fix_match.form[:query]} type="text" placeholder="Title" />
            </div>
            <div class="w-24">
              <.input
                field={@fix_match.form[:year]}
                type="text"
                inputmode="numeric"
                placeholder="Year"
              />
            </div>
            <.button
              type="submit"
              variant="primary"
              disabled={@fix_match.searching?}
              aria-label="Search"
            >
              <span :if={@fix_match.searching?} class="loading loading-spinner loading-sm"></span>
              <.icon :if={!@fix_match.searching?} name="hero-magnifying-glass" class="w-4 h-4" />
            </.button>
          </.form>

          <div :if={@fix_match.error} class="alert alert-error mb-4">
            <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
            <span>{@fix_match.error}</span>
          </div>

          <div class="space-y-2 max-h-80 overflow-y-auto">
            <button
              :for={result <- @fix_match.results}
              id={"fix-match-candidate-#{result.provider_id}"}
              type="button"
              phx-click="fix_match_pick"
              phx-value-provider_id={to_string(result.provider_id)}
              disabled={to_string(result.provider_id) == @current_id}
              class="btn btn-ghost h-auto w-full justify-start normal-case text-left p-3 rounded-lg border-2 border-base-300 hover:border-primary hover:bg-primary/5 transition-colors"
            >
              <img
                :if={result.poster_path}
                src={Mydia.Metadata.ImageUrl.poster_url(result.poster_path, "w92")}
                class="w-10 rounded"
                alt=""
              />
              <div class="flex-1">
                <div class="font-medium">
                  {result.title}
                  <span :if={result.year} class="opacity-60 font-normal">({result.year})</span>
                </div>
                <div class="text-xs opacity-50 font-mono mt-0.5">
                  {provider_label(@provider)} ID {to_string(result.provider_id)}
                </div>
              </div>
              <span :if={to_string(result.provider_id) == @current_id} class="badge badge-ghost">
                Current match
              </span>
            </button>
          </div>
        <% else %>
          <p class="mb-3">
            Change <span class="font-semibold">{@media_item.title}</span>
            <span :if={@media_item.year} class="opacity-60">({@media_item.year})</span>
            to <span class="font-semibold">{@fix_match.picked.title}</span>
            <span :if={@fix_match.picked.year} class="opacity-60">({@fix_match.picked.year})</span>?
          </p>
          <%= if @media_item.type == "tv_show" do %>
            <div class="alert alert-warning text-sm">
              <.icon name="hero-exclamation-triangle" class="w-5 h-5" />
              <span>
                Episodes are rebuilt from {provider_label(@provider)}. Files go back to Import to be matched to the new episodes. Per-episode watch history is reset.
              </span>
            </div>
          <% else %>
            <p class="text-sm opacity-75">Files stay attached.</p>
          <% end %>
        <% end %>

        <div class="modal-action">
          <button
            :if={@fix_match.step == :confirm}
            type="button"
            phx-click="fix_match_back"
            class="btn btn-ghost"
          >
            Back
          </button>
          <button type="button" phx-click="close_fix_match" class="btn btn-ghost">Cancel</button>
          <button
            :if={@fix_match.step == :confirm}
            id="fix-match-confirm"
            type="button"
            phx-click="fix_match_confirm"
            class="btn btn-primary"
            disabled={@fix_match.adopting?}
          >
            <span :if={@fix_match.adopting?} class="loading loading-spinner loading-sm"></span>
            Confirm
          </button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="close_fix_match"></div>
    </div>
    """
  end

  # An id only identifies the current match on the provider it belongs to, so
  # results from the other provider are never "current".
  defp current_id(fix_match, media_item) do
    if fix_match.provider == FixMatch.provider_for(media_item),
      do: FixMatch.current_provider_id(media_item)
  end

  defp provider_label(provider), do: Helpers.provider_label(provider)
end
