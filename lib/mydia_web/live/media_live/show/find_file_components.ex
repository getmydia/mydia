defmodule MydiaWeb.MediaLive.Show.FindFileComponents do
  @moduledoc """
  The "Find file" dialog: import candidates ranked as files for a movie or
  episode that has none, with a path search and a review-mode rescan.
  """
  use Phoenix.Component
  import MydiaWeb.CoreComponents
  import MydiaWeb.Formatters, only: [format_file_size: 1]

  attr :title, :string, required: true
  attr :query, :string, default: ""
  attr :suggestions, :list, required: true
  attr :scanning, :list, default: []

  def find_file_modal(assigns) do
    ~H"""
    <div id="find-file-modal" class="modal modal-open">
      <div class="modal-box max-w-3xl">
        <h3 class="font-bold text-lg mb-1">Find a file for {@title}</h3>
        <p class="text-sm text-base-content/60 mb-4">
          Files in your libraries that no item owns yet, best matches first.
        </p>

        <div class="flex gap-2 mb-4">
          <form id="find-file-search" phx-change="find_file_search" class="flex-1">
            <label class="input input-bordered flex items-center gap-2 w-full">
              <.icon name="hero-magnifying-glass" class="w-4 h-4 opacity-60" />
              <input
                type="text"
                name="query"
                value={@query}
                placeholder="Search by path"
                phx-debounce="300"
                class="grow"
              />
            </label>
          </form>
          <button
            id="find-file-scan"
            type="button"
            phx-click="find_file_scan"
            class="btn btn-outline"
          >
            <.icon name="hero-arrow-path" class="w-4 h-4" /> Scan for new files
          </button>
        </div>

        <div :if={@scanning != []} id="find-file-scanning" class="alert alert-info mb-4 py-2">
          <span class="loading loading-spinner loading-sm"></span>
          <span class="text-sm">Scanning {Enum.join(@scanning, ", ")}...</span>
        </div>

        <%= if @suggestions == [] do %>
          <div id="find-file-empty" class="text-center py-10 text-base-content/60">
            <.icon name="hero-document-magnifying-glass" class="w-10 h-10 mx-auto mb-2 opacity-40" />
            <p class="text-sm">No likely files found. Try a search, or scan for new files.</p>
          </div>
        <% else %>
          <ul class="divide-y divide-base-300 max-h-[60vh] overflow-y-auto">
            <li
              :for={suggestion <- @suggestions}
              id={"find-file-candidate-#{suggestion.candidate.id}"}
              class="py-3 flex items-center gap-3 hover:bg-base-200/50 transition-colors rounded px-2"
            >
              <div class="flex-1 min-w-0">
                <div class="font-mono text-sm truncate">
                  {Path.basename(suggestion.candidate.relative_path)}
                </div>
                <div class="text-xs text-base-content/60 truncate">
                  {folder(suggestion.candidate)} · {format_file_size(suggestion.candidate.size)}
                </div>
                <div class="flex flex-wrap gap-1 mt-1">
                  <span :for={reason <- suggestion.reasons} class="badge badge-sm badge-ghost">
                    {reason_label(reason)}
                  </span>
                </div>
              </div>
              <button
                id={"find-file-attach-#{suggestion.candidate.id}"}
                type="button"
                phx-click="attach_found_file"
                phx-value-candidate-id={suggestion.candidate.id}
                class="btn btn-primary btn-sm"
              >
                Attach
              </button>
            </li>
          </ul>
        <% end %>

        <div class="modal-action">
          <button type="button" phx-click="close_find_file" class="btn btn-ghost">Close</button>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="close_find_file"></div>
    </div>
    """
  end

  defp folder(candidate) do
    dir = Path.dirname(candidate.relative_path)
    root = candidate.library_path.path
    if dir == ".", do: root, else: Path.join(root, dir)
  end

  defp reason_label(:same_provider), do: "Parked from this title"
  defp reason_label({:title, similarity}), do: "Title #{round(similarity * 100)}%"
  defp reason_label({:year, year}), do: Integer.to_string(year)
  defp reason_label({:episode, season, episode}), do: "S#{pad(season)}E#{pad(episode)}"

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")
end
