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
  attr :outcome_run, :map, default: nil

  def run_control(assigns) do
    ~H"""
    <section id="import-run-control" class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title">Import a library</h2>

        <.run_outcome :if={@outcome_run} run={@outcome_run} />

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
    <div :if={@library_paths == []} class="alert alert-info">
      <.icon name="hero-information-circle" class="w-5 h-5 shrink-0" />
      <span>
        There is no movie or TV library to import yet. Add one under Settings, then come back.
      </span>
    </div>

    <.form
      :if={@library_paths != []}
      for={%{}}
      id="start-run-form"
      phx-submit="start_run"
      class="flex flex-col gap-4"
    >
      <.input
        id="start-run-library"
        name="library_path_id"
        type="select"
        label="Library"
        value={default_library_path_id(@library_paths)}
        options={Enum.map(@library_paths, &{&1.path, &1.id})}
        required
      />

      <.input
        id="start-run-mode"
        name="mode"
        type="select"
        label="Mode"
        value="review"
        options={[
          {"Review every match before it is added", "review"},
          {"Add confident matches automatically", "unattended"}
        ]}
      />

      <p class="text-sm opacity-70">
        The run keeps going if you close this page. You can stop it at any point and keep
        everything it has already done.
      </p>

      <.button id="start-run-button" type="submit" variant="primary">Start</.button>
    </.form>
    """
  end

  # Marks the first option as selected rather than leaving the select with no
  # value at all, so what the form submits matches what a user sees before they
  # touch it.
  defp default_library_path_id([%{id: id} | _rest]), do: id
  defp default_library_path_id(_library_paths), do: nil

  attr :run, :map, required: true

  defp run_progress(assigns) do
    ~H"""
    <div id="run-progress" class="flex flex-col gap-3">
      <div class="flex items-center gap-2">
        <span class="loading loading-spinner loading-sm" />
        <span class="font-medium">{phase_label(@run.phase)}</span>
        <span :if={@run.status == :stopping} class="badge badge-warning">Stopping</span>
      </div>

      <.run_stats run={@run} />

      <p :if={@run.current_file} class="text-sm opacity-70 truncate">{@run.current_file}</p>

      <.button
        id="stop-run-button"
        phx-click="stop_run"
        disabled={@run.status == :stopping}
        class="btn btn-outline btn-warning"
      >
        Stop and keep progress
      </.button>

      <%!--
        The escape hatch for a run whose coordinator is gone but whose row
        still says otherwise. Boot reconciliation
        (Mydia.Jobs.ImportRun.reconcile_interrupted_runs/0) covers the common
        case, a restart, but a job cancelled from the jobs page leaves no
        restart to trigger it. Without something here, recovery means editing
        the database: Start is refused for this path and Stop only writes
        :stopping, which is also active.
      --%>
      <div class="flex flex-col gap-1">
        <.button
          id="release-run-button"
          phx-click="release_run"
          data-confirm="Mark this import as not running? Everything it already added is kept, and you will be able to start a new import for this library."
          class="btn btn-ghost btn-xs self-start"
        >
          <.icon name="hero-wrench-screwdriver" class="w-3.5 h-3.5" /> Not actually running?
        </.button>
        <p class="text-xs opacity-60">
          Use this only if the import has been stuck since a restart or a crash.
        </p>
      </div>
    </div>
    """
  end

  # Shown in place of the start form once a run has reached a terminal
  # state (:done, :failed, or :stopped). The run row stays exactly as the
  # coordinator left it -- nothing here is socket state -- so this renders
  # identically whether the outcome arrived over PubSub in-session or was
  # read back from `Library.last_import_run/1` after a reload.
  attr :run, :map, required: true

  defp run_outcome(assigns) do
    ~H"""
    <div
      id="run-outcome"
      class={["alert flex-col items-start gap-3", outcome_alert_class(@run.status)]}
    >
      <div class="flex items-center gap-2 w-full">
        <.icon name={outcome_icon(@run.status)} class="w-5 h-5 shrink-0" />
        <span class="font-medium">{outcome_label(@run.status)}</span>
        <span class="badge badge-ghost">{mode_label(@run.mode)}</span>
      </div>

      <.run_stats run={@run} />

      <%!--
        Rendered for any status that carries an error, not only :failed. A run
        released by boot reconciliation, or by the recovery control above,
        lands on :stopped with the explanation in this field, and hiding it
        would leave the user with a bare "Import stopped" and no reason.
      --%>
      <div :if={@run.error} class="w-full">
        <p class="text-sm opacity-70 mb-1">{error_label(@run.status)}</p>
        <pre class="text-xs whitespace-pre-wrap break-all bg-base-100/60 rounded-lg p-2">{@run.error}</pre>
      </div>
    </div>
    """
  end

  attr :run, :map, required: true

  defp run_stats(assigns) do
    ~H"""
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
    """
  end

  defp phase_label(:scanning), do: "Finding files"
  defp phase_label(:matching), do: "Identifying files"
  defp phase_label(:finished), do: "Finished"

  defp outcome_label(:done), do: "Import finished"
  defp outcome_label(:failed), do: "Import failed"
  defp outcome_label(:stopped), do: "Import stopped"

  defp error_label(:failed), do: "Error details"
  defp error_label(_status), do: "What happened"

  defp outcome_alert_class(:done), do: "alert-success"
  defp outcome_alert_class(:failed), do: "alert-error"
  defp outcome_alert_class(:stopped), do: "alert-warning"

  defp outcome_icon(:done), do: "hero-check-circle"
  defp outcome_icon(:failed), do: "hero-exclamation-triangle"
  defp outcome_icon(:stopped), do: "hero-stop-circle"

  defp mode_label(:review), do: "Review"
  defp mode_label(:unattended), do: "Unattended"

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
