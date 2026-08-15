defmodule MydiaWeb.ImportMediaLive.RunControl do
  @moduledoc """
  Components for starting, watching, and stopping an import run.

  The run itself lives in Oban, so this panel is a view onto a database row
  plus a PubSub feed. Closing the tab does nothing to the run, and reopening
  re-attaches by reading the row.
  """
  use MydiaWeb, :html

  attr :library_paths, :list, required: true
  attr :active_run, :map, default: nil

  def run_control(assigns) do
    ~H"""
    <section id="import-run-control" class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title">Import a library</h2>

        <%= if @active_run do %>
          <.run_progress run={@active_run} />
        <% else %>
          <.start_form library_paths={@library_paths} />
        <% end %>
      </div>
    </section>
    """
  end

  attr :library_paths, :list, required: true

  defp start_form(assigns) do
    ~H"""
    <form id="start-run-form" phx-submit="start_run" class="flex flex-col gap-4">
      <label class="form-control w-full">
        <span class="label-text">Library</span>
        <select name="library_path_id" class="select select-bordered" required>
          <option :for={lp <- @library_paths} value={lp.id}>{lp.path}</option>
        </select>
      </label>

      <label class="form-control w-full">
        <span class="label-text">Mode</span>
        <select name="mode" class="select select-bordered">
          <option value="review">Review every match before it is added</option>
          <option value="unattended">Add confident matches automatically</option>
        </select>
      </label>

      <p class="text-sm opacity-70">
        The run keeps going if you close this page. You can stop it at any point and keep
        everything it has already done.
      </p>

      <button id="start-run-button" type="submit" class="btn btn-primary">Start</button>
    </form>
    """
  end

  attr :run, :map, required: true

  defp run_progress(assigns) do
    ~H"""
    <div id="run-progress" class="flex flex-col gap-3">
      <div class="flex items-center gap-2">
        <span class="loading loading-spinner loading-sm" />
        <span class="font-medium">{phase_label(@run.phase)}</span>
        <span :if={@run.status == :stopping} class="badge badge-warning">Stopping</span>
      </div>

      <div class="stats stats-horizontal shadow">
        <div class="stat">
          <div class="stat-title">Found</div>
          <div class="stat-value text-2xl">{number(@run.files_discovered)}</div>
        </div>
        <div class="stat">
          <div class="stat-title">Matched</div>
          <div class="stat-value text-2xl">{number(@run.files_matched)}</div>
        </div>
        <div class="stat">
          <div class="stat-title">Added</div>
          <div class="stat-value text-2xl">{number(@run.files_linked)}</div>
        </div>
      </div>

      <p :if={@run.current_file} class="text-sm opacity-70 truncate">{@run.current_file}</p>

      <button
        id="stop-run-button"
        phx-click="stop_run"
        disabled={@run.status == :stopping}
        class="btn btn-outline btn-warning"
      >
        Stop and keep progress
      </button>
    </div>
    """
  end

  defp phase_label(:scanning), do: "Finding files"
  defp phase_label(:matching), do: "Identifying files"
  defp phase_label(:finished), do: "Finished"

  # Thousands separators, because these numbers get large enough that a bare
  # digit string stops being readable at a glance.
  defp number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map_join(",", &Enum.join/1)
    |> String.reverse()
  end

  defp number(_), do: "0"
end
