defmodule MydiaWeb.ReviewMediaLive.Components do
  @moduledoc """
  Grouped-tree components for the Review page.

  Each grouped entry carries `.file.media_file` (a `MediaFile`) and
  `.file.candidate` (a `MatchCandidate`); the components render from those and
  address every event by `media_file.id`.
  """
  use Phoenix.Component
  import MydiaWeb.CoreComponents
  alias Mydia.Library.FileGrouper
  alias Mydia.Library.MediaFile

  attr :group, :map, required: true
  attr :collapsed_seasons, :any, required: true
  attr :batch_selected_ids, :any, required: true
  attr :editing_file_id, :string, default: nil
  attr :editing_file_name, :string, default: nil
  attr :edit_form, :map, default: nil
  attr :search_results, :list, default: []
  attr :rematching_series_key, :string, default: nil
  attr :series_search_results, :list, default: []

  def grouped_tree(assigns) do
    ~H"""
    <div class="flex flex-col gap-6">
      <.series_block
        :for={series <- @group.series}
        series={series}
        collapsed_seasons={@collapsed_seasons}
        batch_selected_ids={@batch_selected_ids}
        rematching_series_key={@rematching_series_key}
        series_search_results={@series_search_results}
      />

      <div :if={@group.movies != []} class="card bg-base-100 shadow">
        <div class="card-body">
          <h3 class="card-title text-lg">
            <.icon name="hero-film" class="w-5 h-5 text-accent" /> Movies
          </h3>
          <ul class="divide-y divide-base-300">
            <.file_row
              :for={movie <- @group.movies}
              entry={movie}
              batch_selected_ids={@batch_selected_ids}
              editing_file_id={@editing_file_id}
              editing_file_name={@editing_file_name}
              edit_form={@edit_form}
              search_results={@search_results}
            />
          </ul>
        </div>
      </div>

      <div :if={@group.wrong_library != []} class="card bg-base-100 shadow">
        <div class="card-body">
          <h3 class="card-title text-lg">
            <.icon name="hero-funnel" class="w-5 h-5 text-error" /> Wrong library
          </h3>
          <p class="text-sm text-base-content/60">
            These files were matched, but to a type this library cannot hold.
          </p>
          <ul class="divide-y divide-base-300">
            <.file_row
              :for={entry <- @group.wrong_library}
              entry={entry}
              batch_selected_ids={@batch_selected_ids}
              editing_file_id={@editing_file_id}
              editing_file_name={@editing_file_name}
              edit_form={@edit_form}
              search_results={@search_results}
            />
          </ul>
        </div>
      </div>

      <div :if={@group.unmatched != []} class="card bg-base-100 shadow">
        <div class="card-body">
          <h3 class="card-title text-lg">
            <.icon name="hero-question-mark-circle" class="w-5 h-5 text-warning" /> Unmatched
          </h3>
          <ul class="divide-y divide-base-300">
            <.file_row
              :for={entry <- @group.unmatched}
              entry={entry}
              batch_selected_ids={@batch_selected_ids}
              editing_file_id={@editing_file_id}
              editing_file_name={@editing_file_name}
              edit_form={@edit_form}
              search_results={@search_results}
            />
          </ul>
        </div>
      </div>
    </div>
    """
  end

  attr :series, :map, required: true
  attr :collapsed_seasons, :any, required: true
  attr :batch_selected_ids, :any, required: true
  attr :rematching_series_key, :string, default: nil
  attr :series_search_results, :list, default: []

  defp series_block(assigns) do
    series_key = FileGrouper.series_key(assigns.series)

    assigns = assign(assigns, :series_key, series_key)

    ~H"""
    <div class="card bg-base-100 shadow">
      <div class="card-body">
        <div class="flex items-center justify-between gap-2">
          <div>
            <h3 class="font-bold text-base">
              {@series.title}
              <span :if={@series.year} class="text-base-content/60 font-normal">
                ({@series.year})
              </span>
            </h3>
          </div>
          <button
            type="button"
            id={"rematch-#{@series.provider_id}"}
            phx-click="edit_series_rematch"
            phx-value-series_key={@series_key}
            class="btn btn-ghost btn-xs"
            title="Re-match this series"
          >
            <.icon name="hero-pencil-square" class="w-4 h-4" /> Re-match
          </button>
        </div>

        <%= if @rematching_series_key == @series_key do %>
          <div class="relative">
            <input
              type="text"
              name="query"
              value={@series.title}
              placeholder="Search for TV series..."
              class="input input-sm w-full"
              phx-change="search_series_rematch"
              phx-debounce="300"
              autofocus
            />
            <div
              :if={@series_search_results != []}
              class="absolute z-20 w-full mt-1 bg-base-100 border border-base-300 rounded-lg shadow-xl max-h-72 overflow-y-auto"
            >
              <button
                :for={result <- @series_search_results}
                type="button"
                class="w-full text-left px-3 py-2 hover:bg-info/10"
                phx-click="select_series_rematch"
                phx-value-provider_id={result.provider_id}
                phx-value-title={result.title}
              >
                <span class="font-medium text-sm">{result.title}</span>
                <span :if={result.year} class="text-xs text-base-content/60">
                  ({result.year})
                </span>
              </button>
            </div>
          </div>
        <% end %>

        <div>
          <.season_block
            :for={season <- @series.seasons}
            series_key={@series_key}
            series_provider_id={@series.provider_id}
            season={season}
            collapsed_seasons={@collapsed_seasons}
            batch_selected_ids={@batch_selected_ids}
          />
        </div>
      </div>
    </div>
    """
  end

  attr :series_key, :string, required: true
  attr :series_provider_id, :string, required: true
  attr :season, :map, required: true
  attr :collapsed_seasons, :any, required: true
  attr :batch_selected_ids, :any, required: true

  defp season_block(assigns) do
    episode_ids = Enum.map(assigns.season.episodes, & &1.file.media_file.id)

    # Use a stable key derived from series provider_id + season number rather
    # than the first episode's DB id, so collapsing survives episode approvals.
    season_id =
      "#{assigns.series_provider_id}-s#{assigns.season.season_number}"

    all_selected = Enum.all?(episode_ids, &MapSet.member?(assigns.batch_selected_ids, &1))

    some_selected =
      not all_selected and Enum.any?(episode_ids, &MapSet.member?(assigns.batch_selected_ids, &1))

    collapsed = MapSet.member?(assigns.collapsed_seasons, season_id)

    assigns =
      assigns
      |> assign(:episode_ids, episode_ids)
      |> assign(:season_id, season_id)
      |> assign(:all_selected, all_selected)
      |> assign(:some_selected, some_selected)
      |> assign(:collapsed, collapsed)

    ~H"""
    <div class="border-t border-base-300">
      <div class="flex items-center gap-2 py-2">
        <input
          type="checkbox"
          id={"season-select-#{@season_id}"}
          aria-label={"Select every episode in season #{@season.season_number}"}
          class={["checkbox checkbox-primary checkbox-sm", @some_selected && "checkbox-warning"]}
          checked={@all_selected or @some_selected}
          phx-click="toggle_season_selection"
          phx-value-ids={Enum.join(@episode_ids, ",")}
        />
        <button
          type="button"
          id={"season-toggle-#{@season_id}"}
          class="flex-1 flex items-center gap-2 text-left"
          phx-click="toggle_season_collapse"
          phx-value-season_id={@season_id}
        >
          <.icon
            name={if(@collapsed, do: "hero-chevron-right", else: "hero-chevron-down")}
            class="w-4 h-4 text-base-content/60"
          />
          <span class="font-semibold text-sm">Season {@season.season_number}</span>
          <span class="badge badge-xs">{length(@season.episodes)}</span>
        </button>
        <span :if={@some_selected} class="badge badge-warning badge-xs">Partial</span>
      </div>

      <ul :if={not @collapsed} class="divide-y divide-base-300 pb-2">
        <.file_row
          :for={episode <- @season.episodes}
          entry={episode}
          batch_selected_ids={@batch_selected_ids}
        />
      </ul>
    </div>
    """
  end

  attr :entry, :map, required: true
  attr :batch_selected_ids, :any, required: true
  attr :editing_file_id, :string, default: nil
  attr :editing_file_name, :string, default: nil
  attr :edit_form, :map, default: nil
  attr :search_results, :list, default: []

  def file_row(assigns) do
    file = assigns.entry.file.media_file
    candidate = assigns.entry.file.candidate

    assigns =
      assigns
      |> assign(:file, file)
      |> assign(:candidate, candidate)
      |> assign(:title, candidate.title || MediaFile.display_name(file))

    ~H"""
    <li class="py-2 flex items-center gap-3">
      <input
        type="checkbox"
        id={"batch-toggle-#{@file.id}"}
        aria-label={"Select #{@title}"}
        class="checkbox checkbox-primary checkbox-sm"
        checked={MapSet.member?(@batch_selected_ids, @file.id)}
        phx-click="batch_toggle_file"
        phx-value-id={@file.id}
      />

      <div class="flex-1 min-w-0">
        <p class="font-medium truncate">{@title}</p>
        <p class="text-sm opacity-70 truncate">{MediaFile.display_path(@file)}</p>
        <p
          :if={is_nil(@candidate.provider_id) and @candidate.last_error}
          class="text-xs text-error/80 mt-0.5"
        >
          {format_last_error(@candidate.last_error)}
        </p>
      </div>

      <span :if={is_nil(@candidate.provider_id)} class="badge badge-ghost">No match</span>
      <span :if={@candidate.provider_id} class={["badge", confidence_class(@candidate.confidence)]}>
        {percent(@candidate.confidence)}
      </span>

      <.button
        id={"edit-#{@file.id}"}
        type="button"
        phx-click="edit_file"
        phx-value-id={@file.id}
        class="btn btn-sm btn-ghost"
        title="Find or fix this file's match"
      >
        <.icon name="hero-magnifying-glass" class="w-4 h-4" />
      </.button>

      <.button
        id={"approve-#{@file.id}"}
        phx-click="approve_file"
        phx-value-id={@file.id}
        disabled={is_nil(@candidate.provider_id)}
        class="btn btn-sm btn-primary"
      >
        Add
      </.button>
    </li>
    """
  end

  # Turns the raw last_error string stored by the matcher into a short,
  # human-readable sentence. The atom representations that older code
  # inspect()-ed into strings are handled by pattern matching on their
  # text prefix; anything unknown is truncated and shown verbatim so a
  # new error kind is still visible rather than silently swallowed.
  defp format_last_error(nil), do: nil
  defp format_last_error("no_match"), do: "No matching title was found."
  defp format_last_error("timeout"), do: "The metadata lookup timed out."

  defp format_last_error(error) when is_binary(error) do
    cond do
      String.contains?(error, "library_type_mismatch") ->
        "Matched to the wrong library type."

      String.contains?(error, "network") or String.contains?(error, "connection") ->
        "A network error occurred during lookup."

      true ->
        # Truncate to keep the UI tidy; full detail is in server logs.
        if String.length(error) > 80,
          do: String.slice(error, 0, 80) <> "…",
          else: error
    end
  end

  defp confidence_class(nil), do: "badge-ghost"
  defp confidence_class(c) when c >= 0.8, do: "badge-success"
  defp confidence_class(c) when c >= 0.5, do: "badge-warning"
  defp confidence_class(_), do: "badge-error"

  defp percent(nil), do: "?"
  defp percent(c), do: "#{round(c * 100)}%"
end
