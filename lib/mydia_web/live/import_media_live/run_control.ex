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
  attr :outcome_inbox_count, :integer, default: 0

  def run_control(assigns) do
    ~H"""
    <section id="import-run-control" class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title">Import a library</h2>

        <.run_outcome :if={@outcome_run} run={@outcome_run} unresolved={@outcome_inbox_count} />

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
      <fieldset class="flex flex-col gap-2">
        <legend class="text-sm font-medium opacity-80">Library</legend>
        <div class="grid gap-3">
          <%= for path <- @library_paths do %>
            <label class={[
              "group card card-compact bg-base-100 border border-base-300 cursor-pointer transition-all duration-200",
              "hover:border-primary hover:shadow-lg",
              "has-checked:border-primary has-checked:bg-primary/5 has-checked:ring-2 has-checked:ring-primary/40"
            ]}>
              <input
                type="radio"
                name="library_path_id"
                value={path.id}
                class="sr-only"
                checked={path.id == default_library_path_id(@library_paths)}
              />
              <div class="card-body flex-row items-center gap-4">
                <div class={[
                  "flex items-center justify-center w-12 h-12 rounded-lg shrink-0 transition-transform group-hover:scale-105",
                  library_type_bg_class(path.type)
                ]}>
                  <.icon name={library_type_icon(path.type)} class="w-6 h-6" />
                </div>
                <div class="flex-1 min-w-0">
                  <span class={["badge badge-sm mb-1", library_type_badge_class(path.type)]}>
                    {library_type_display(path.type)}
                  </span>
                  <p class="font-mono text-sm truncate text-base-content/80 group-has-checked:text-base-content">
                    {path.path}
                  </p>
                </div>
                <.icon
                  name="hero-check"
                  class="w-5 h-5 text-primary shrink-0 opacity-0 group-has-checked:opacity-100 transition-opacity"
                />
              </div>
            </label>
          <% end %>
        </div>
      </fieldset>

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
    </div>
    """
  end

  # Shown in place of the start form once a run has reached a terminal
  # state (:done, :failed, or :stopped). The run row stays exactly as the
  # coordinator left it -- nothing here is socket state -- so this renders
  # identically whether the outcome arrived over PubSub in-session or was
  # read back from `Library.last_import_run/1` after a reload.
  attr :run, :map, required: true
  attr :unresolved, :integer, default: 0

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

      <.outcome_review_cta unresolved={@unresolved} />

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

  attr :unresolved, :integer, default: 0

  defp outcome_review_cta(assigns) do
    ~H"""
    <div :if={@unresolved > 0} class="w-full">
      <.link navigate={~p"/review"} class="btn btn-sm btn-outline">
        <.icon name="hero-inbox-stack" class="w-4 h-4" />
        Review {@unresolved} file(s) that need attention
      </.link>
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

  # Icon, badge and accent styling per library type, mirroring the old
  # wizard's path-selection cards. `LibraryPath` only knows :movies, :series
  # and :mixed today; the fallbacks exist so a new type degrades visibly
  # instead of crashing the template.
  defp library_type_icon(:series), do: "hero-tv"
  defp library_type_icon(:movies), do: "hero-film"
  defp library_type_icon(:mixed), do: "hero-square-3-stack-3d"
  defp library_type_icon(_), do: "hero-folder"

  defp library_type_bg_class(:series), do: "bg-info/10 text-info"
  defp library_type_bg_class(:movies), do: "bg-accent/10 text-accent"
  defp library_type_bg_class(:mixed), do: "bg-secondary/10 text-secondary"
  defp library_type_bg_class(_), do: "bg-base-200 text-base-content/70"

  defp library_type_badge_class(:series), do: "badge-info"
  defp library_type_badge_class(:movies), do: "badge-accent"
  defp library_type_badge_class(:mixed), do: "badge-secondary"
  defp library_type_badge_class(_), do: "badge-ghost"

  defp library_type_display(:series), do: "TV Series"
  defp library_type_display(:movies), do: "Movies"
  defp library_type_display(:mixed), do: "Mixed"
  defp library_type_display(type), do: to_string(type)
end
