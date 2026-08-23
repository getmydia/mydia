defmodule MydiaWeb.MediaLive.Show.SubtitleModal do
  @moduledoc """
  Subtitle search modal for the MediaLive.Show page.

  Split out of `Modals` because that module had grown past three times the
  project's file-size guideline and this modal is a self-contained third of it.
  """
  use Phoenix.Component
  import MydiaWeb.CoreComponents
  import MydiaWeb.MediaLive.Show.ScoreBreakdown

  alias Mydia.Library.MediaFile
  alias Phoenix.LiveView.JS

  @doc """
  Subtitle search modal for searching and downloading subtitles.
  """
  attr :media_file, :map, required: true
  attr :subtitle_search_state, :any, default: :idle
  attr :subtitle_search_results, :list, required: true
  attr :subtitle_providers, :list, default: []
  attr :downloading_subtitle_index, :any, default: nil
  attr :selected_languages, :list, default: ["en"]

  def subtitle_search_modal(assigns) do
    common = MydiaWeb.Languages.common()
    common_codes = Enum.map(common, &elem(&1, 0))

    # A selected language always gets a visible chip, even an uncommon one, so
    # the current selection is never hidden behind the "+N more" toggle.
    extra_chips =
      assigns.selected_languages
      |> Enum.reject(&(&1 in common_codes))
      |> Enum.map(&{&1, MydiaWeb.Languages.name(&1)})

    chips = common ++ extra_chips
    chip_codes = Enum.map(chips, &elem(&1, 0))
    more = Enum.reject(MydiaWeb.Languages.all(), fn {code, _} -> code in chip_codes end)

    assigns =
      assigns
      |> assign(:language_chips, chips)
      |> assign(:more_languages, more)

    ~H"""
    <div class="modal modal-bottom sm:modal-middle modal-open" id="subtitle-search-modal">
      <div class="modal-box max-w-none sm:max-w-3xl max-h-[92dvh] sm:max-h-[85vh] flex flex-col overflow-hidden p-0">
        <%!-- Header --%>
        <div class="bg-base-100 border-b border-base-300 p-4 sm:p-6">
          <div class="flex items-start justify-between gap-4">
            <div class="min-w-0">
              <h3 class="text-xl sm:text-2xl font-bold">Search Subtitles</h3>
              <p
                class="text-sm text-base-content/70 truncate mt-1"
                title={MediaFile.display_path(@media_file)}
              >
                {MediaFile.display_name(@media_file)}
              </p>
            </div>
            <button
              type="button"
              phx-click="close_subtitle_search_modal"
              class="btn btn-ghost btn-sm btn-circle shrink-0"
              aria-label="Close"
            >
              <.icon name="hero-x-mark" class="w-6 h-6" />
            </button>
          </div>
        </div>
        <%!-- Control band --%>
        <div class="bg-base-200/50 border-b border-base-300 px-4 py-3 sm:px-6">
          <form
            id="subtitle-language-form"
            phx-change="update_subtitle_languages"
            class="flex flex-wrap items-center gap-2"
          >
            <div class="filter" role="group" aria-label="Subtitle languages">
              <button
                type="button"
                class="btn btn-sm btn-square filter-reset"
                phx-click="clear_subtitle_languages"
                aria-label="Clear selected languages"
              >
                ×
              </button>
              <input
                :for={{code, label} <- @language_chips}
                class="btn btn-sm"
                type="checkbox"
                name="languages[]"
                value={code}
                aria-label={label}
                checked={code in @selected_languages}
              />
              <input
                :for={{code, label} <- @more_languages}
                class="btn btn-sm subtitle-lang-extra hidden"
                type="checkbox"
                name="languages[]"
                value={code}
                aria-label={label}
                checked={code in @selected_languages}
              />
            </div>

            <button
              type="button"
              id="subtitle-language-more-toggle"
              class="btn btn-sm btn-ghost"
              aria-expanded="false"
              aria-controls="subtitle-language-form"
              phx-click={
                JS.toggle(to: "#subtitle-language-form .subtitle-lang-extra", display: "inline-flex")
                |> JS.toggle_attribute({"aria-expanded", "true", "false"},
                  to: "#subtitle-language-more-toggle"
                )
                |> JS.toggle(to: "#subtitle-language-more-label", display: "inline")
                |> JS.toggle(to: "#subtitle-language-fewer-label", display: "inline")
              }
            >
              <span id="subtitle-language-more-label">+{length(@more_languages)} more</span>
              <span id="subtitle-language-fewer-label" class="hidden">Show fewer</span>
              <.icon name="hero-chevron-down" class="w-4 h-4" />
            </button>

            <div class="flex-1"></div>

            <button
              type="button"
              phx-click="perform_subtitle_search"
              class="btn btn-primary btn-sm btn-block sm:w-auto"
              disabled={@subtitle_search_state == :searching or @selected_languages == []}
            >
              <%= if @subtitle_search_state == :searching do %>
                <span class="loading loading-spinner loading-sm"></span> Searching
              <% else %>
                <.icon name="hero-magnifying-glass" class="w-4 h-4" /> Search
              <% end %>
            </button>
          </form>
        </div>
        <div id="subtitle-search-body" class="flex-1 overflow-y-auto p-4 sm:p-6">
          <%= case @subtitle_search_state do %>
            <% :idle -> %>
              <div class="flex flex-col items-center justify-center py-16 text-center">
                <.icon name="hero-language" class="w-16 h-16 text-base-content/20 mb-4" />
                <h3 class="text-xl font-semibold text-base-content/70 mb-2">
                  Choose one or more languages
                </h3>
                <p class="text-base-content/50 max-w-sm">
                  Then run a search to see what your providers have for this file.
                </p>
              </div>
            <% :searching -> %>
              <div class="flex flex-col gap-3">
                <div :for={_ <- 1..5} class="skeleton h-16 w-full"></div>
              </div>
            <% {:error, reason} -> %>
              <div class="alert alert-error">
                <.icon name="hero-exclamation-circle" class="w-5 h-5 shrink-0" />
                <div class="flex-1">
                  <div class="font-medium">Search failed</div>
                  <div class="text-sm opacity-80">{search_error_message(reason)}</div>
                </div>
                <button
                  type="button"
                  phx-click="perform_subtitle_search"
                  class="btn btn-sm"
                  disabled={@selected_languages == []}
                >
                  Retry
                </button>
              </div>
            <% :loaded -> %>
              <% failed = Enum.filter(@subtitle_providers, & &1.error) %>
              <%= cond do %>
                <% @subtitle_providers == [] -> %>
                  <div class="flex flex-col items-center justify-center py-16 text-center">
                    <.icon name="hero-cog-6-tooth" class="w-16 h-16 text-base-content/20 mb-4" />
                    <h3 class="text-xl font-semibold text-base-content/70 mb-2">
                      No subtitle providers configured
                    </h3>
                    <p class="text-base-content/50 max-w-sm mb-4">
                      Add a provider before searching. Nothing is enabled and healthy right now.
                    </p>
                    <.link navigate="/admin/subtitle-providers" class="btn btn-primary btn-sm">
                      Configure providers
                    </.link>
                  </div>
                <% @subtitle_search_results == [] and Enum.all?(@subtitle_providers, & &1.error) -> %>
                  <div class="alert alert-error">
                    <.icon name="hero-exclamation-circle" class="w-5 h-5 shrink-0" />
                    <div class="flex-1">
                      <div class="font-medium">Every provider failed</div>
                      <ul class="text-sm opacity-80 mt-1">
                        <li :for={provider <- @subtitle_providers}>
                          {provider.name}: {provider.error}
                        </li>
                      </ul>
                    </div>
                    <button
                      type="button"
                      phx-click="perform_subtitle_search"
                      class="btn btn-sm"
                      disabled={@selected_languages == []}
                    >
                      Retry
                    </button>
                  </div>
                <% @subtitle_search_results == [] -> %>
                  <.subtitle_provider_failure_banner
                    failed={failed}
                    total={length(@subtitle_providers)}
                  />
                  <div class="flex flex-col items-center justify-center py-16 text-center">
                    <.icon
                      name="hero-magnifying-glass"
                      class="w-16 h-16 text-base-content/20 mb-4"
                    />
                    <h3 class="text-xl font-semibold text-base-content/70 mb-2">
                      No subtitles found
                    </h3>
                    <p class="text-base-content/50 max-w-sm">
                      Your providers answered but had nothing for this file. Try more languages.
                    </p>
                  </div>
                <% true -> %>
                  <.subtitle_provider_failure_banner
                    failed={failed}
                    total={length(@subtitle_providers)}
                  />
                  <ul class="list bg-base-100 rounded-box">
                    <li
                      :for={{result, index} <- Enum.with_index(@subtitle_search_results)}
                      class="list-row hover:bg-base-200/50 transition-colors"
                    >
                      <div class="list-col-grow min-w-0 flex flex-col sm:flex-row sm:items-center gap-3">
                        <div class="min-w-0 flex-1">
                          <div class="font-medium truncate">
                            {result.file_name || MydiaWeb.Languages.name(result.language)}
                          </div>
                          <div class="flex flex-wrap items-center gap-1.5 mt-1">
                            <span class="badge badge-sm">
                              {MydiaWeb.Languages.name(result.language)}
                            </span>
                            <span class="badge badge-ghost badge-sm">{result.format}</span>
                            <span :if={result.provider_name} class="badge badge-ghost badge-sm">
                              {result.provider_name}
                            </span>
                            <span :if={result.moviehash_match} class="badge badge-success badge-sm">
                              Exact match
                            </span>
                            <div
                              :if={result.hearing_impaired}
                              class="tooltip"
                              data-tip="Includes hearing impaired captions"
                            >
                              <span class="badge badge-outline badge-sm">HI</span>
                            </div>
                            <.score_trigger
                              id={"subtitle-score-badge-#{index}"}
                              panel_id={"subtitle-score-breakdown-#{index}"}
                              class={[
                                "badge badge-sm cursor-pointer",
                                score_badge_class(result.score)
                              ]}
                              title="Show score breakdown"
                            >
                              Score {result.score}
                            </.score_trigger>
                          </div>
                          <.score_panel id={"subtitle-score-breakdown-#{index}"}>
                            <.score_row
                              :for={factor <- result.score_breakdown}
                              label={factor.label}
                              value={factor.detail}
                              score={factor.points}
                              max={factor.max}
                              zero_is_absent={true}
                            />
                          </.score_panel>
                          <div class="text-xs text-base-content/60 mt-1 flex gap-3">
                            <span :if={result.rating}>★ {result.rating}/10</span>
                            <span :if={result.download_count}>
                              {result.download_count} downloads
                            </span>
                          </div>
                        </div>

                        <button
                          type="button"
                          phx-click="download_subtitle_result"
                          phx-value-index={index}
                          class="btn btn-primary btn-sm btn-block sm:w-auto"
                          disabled={@downloading_subtitle_index != nil}
                        >
                          <%= if @downloading_subtitle_index == index do %>
                            <span class="loading loading-spinner loading-xs"></span>
                          <% else %>
                            <.icon name="hero-arrow-down-tray" class="w-4 h-4" /> Download
                          <% end %>
                        </button>
                      </div>
                    </li>
                  </ul>
              <% end %>
          <% end %>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="close_subtitle_search_modal"></div>
    </div>
    """
  end

  # Partial-failure warning banner shared by the "results found" and "healthy
  # zero-hit" branches of the loaded subtitle search state, so a provider that
  # failed alongside others that answered is never silently dropped.
  attr :failed, :list, required: true
  attr :total, :integer, required: true

  defp subtitle_provider_failure_banner(assigns) do
    ~H"""
    <div :if={@failed != []} class="alert alert-warning mb-4">
      <.icon name="hero-exclamation-triangle" class="w-5 h-5 shrink-0" />
      <div class="flex-1">
        <div class="text-sm font-medium">
          {length(@failed)} of {@total} providers failed
        </div>
        <ul class="text-xs opacity-80 mt-1">
          <li :for={provider <- @failed}>{provider.name}: {provider.error}</li>
        </ul>
      </div>
    </div>
    """
  end

  # Provider-level failures arrive already humanized from ProviderChain. These
  # are the top-level ones search_candidates/2 can actually return, which
  # would otherwise reach the user as raw atoms.
  defp search_error_message(:media_file_not_found),
    do: "That file is no longer in the library."

  defp search_error_message(:insufficient_search_criteria),
    do: "This file has no hash or metadata IDs to search with."

  defp search_error_message(:crashed),
    do: "The search failed unexpectedly. Check the server logs for details."

  defp search_error_message(_reason),
    do: "The search could not be completed. Check the server logs for details."

  # The release block's ceiling moves with how much the file's own name
  # reveals. A name with no audio token, the very common bare naming like
  # "...1080p.BluRay.x264-AMIABLE", tops the release block at 47 instead of
  # 50, so a byte-identical match on that naming totals 97, not 100.
  # Reachable totals near the top are 100, 97, 95, 90, 88, 80, so 95 means
  # "everything matched except at most one of audio or codec" and nothing
  # weaker qualifies for green.
  defp score_badge_class(score) when score >= 95, do: "badge-success"
  defp score_badge_class(score) when score >= 75, do: "badge-warning"
  defp score_badge_class(_score), do: "badge-ghost"
end
