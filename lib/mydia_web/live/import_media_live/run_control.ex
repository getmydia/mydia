defmodule MydiaWeb.ImportMediaLive.RunControl do
  @moduledoc """
  Components for starting, watching, and stopping an import run.

  The run itself lives in Oban, so this panel is a view onto a database row
  plus a PubSub feed. Closing the tab does nothing to the run, and reopening
  re-attaches by reading the row.
  """
  use MydiaWeb, :html

  attr :library_paths, :list, required: true
  attr :selected_library_path_id, :string, default: nil
  attr :active_run, :map, default: nil
  attr :outcome_run, :map, default: nil
  attr :outcome_group_count, :integer, default: 0
  attr :open, :boolean, default: true

  def run_control(assigns) do
    ~H"""
    <details
      id="import-run-control"
      class="group collapse collapse-arrow bg-base-100 shadow-md border border-base-200 rounded-2xl"
      open={@open}
    >
      <summary class="collapse-title p-4 sm:p-5 cursor-pointer select-none flex items-center justify-between gap-4">
        <div class="flex items-center gap-3 min-w-0">
          <div class="w-8 h-8 rounded-lg bg-primary/10 text-primary flex items-center justify-center shrink-0">
            <.icon name="hero-arrow-down-tray" class="w-4 h-4" />
          </div>
          <div class="flex items-center gap-2.5 flex-wrap min-w-0">
            <h2 class="text-lg sm:text-xl font-bold">Import a library</h2>
            <%= cond do %>
              <% @active_run -> %>
                <span class="badge badge-primary badge-sm gap-1 font-medium">
                  <span class="loading loading-spinner loading-xs"></span>
                  {phase_label(@active_run.phase)}
                </span>
              <% @outcome_run -> %>
                <span class={["badge badge-sm font-medium", outcome_badge_class(@outcome_run.status)]}>
                  {outcome_label(@outcome_run.status)}
                </span>
              <% true -> %>
                <span class="badge badge-ghost badge-sm text-xs font-normal">New Import</span>
            <% end %>
          </div>
        </div>
      </summary>

      <div class="collapse-content px-4 pb-4 sm:px-6 sm:pb-6 flex flex-col gap-5 pt-1">
        <.run_outcome
          :if={@outcome_run}
          run={@outcome_run}
          pending_groups={@outcome_group_count}
        />

        <%= if @active_run do %>
          <.run_progress run={@active_run} />
        <% else %>
          <.start_form
            library_paths={@library_paths}
            selected_library_path_id={@selected_library_path_id}
          />
        <% end %>
      </div>
    </details>
    """
  end

  attr :library_paths, :list, required: true
  attr :selected_library_path_id, :string, default: nil

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
      phx-change="select_library"
      phx-submit="start_run"
      class="flex flex-col gap-5"
    >
      <fieldset class="flex flex-col gap-2">
        <legend class="text-sm font-semibold text-base-content/80">Select Library</legend>
        <div class="grid gap-3 sm:grid-cols-2">
          <%= for path <- @library_paths do %>
            <label class={[
              "group card card-compact bg-base-200/40 border border-base-200 cursor-pointer transition-all duration-150 rounded-xl",
              "hover:border-base-300 hover:bg-base-200/80",
              "has-checked:border-primary has-checked:bg-primary/5 has-checked:ring-1 has-checked:ring-primary"
            ]}>
              <input
                type="radio"
                name="library_path_id"
                value={path.id}
                class="sr-only"
                checked={
                  path.id == (@selected_library_path_id || default_library_path_id(@library_paths))
                }
              />
              <div class="card-body flex-row items-center gap-3.5 p-3.5">
                <div class={[
                  "flex items-center justify-center w-10 h-10 rounded-lg shrink-0 transition-transform group-hover:scale-105",
                  library_type_bg_class(path.type)
                ]}>
                  <.icon name={library_type_icon(path.type)} class="w-5 h-5" />
                </div>
                <div class="flex-1 min-w-0">
                  <span class={[
                    "badge badge-xs font-medium mb-1",
                    library_type_badge_class(path.type)
                  ]}>
                    {library_type_display(path.type)}
                  </span>
                  <p class="font-mono text-xs truncate text-base-content/70 group-has-checked:text-base-content group-has-checked:font-semibold">
                    {path.path}
                  </p>
                </div>
                <div class="shrink-0 flex items-center justify-center w-5 h-5 rounded-full border border-base-300 group-has-checked:border-primary group-has-checked:bg-primary text-primary-content transition-all">
                  <.icon
                    name="hero-check"
                    class="w-3.5 h-3.5 opacity-0 group-has-checked:opacity-100 transition-opacity"
                  />
                </div>
              </div>
            </label>
          <% end %>
        </div>
      </fieldset>

      <div class="max-w-md">
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
      </div>

      <p class="text-xs text-base-content/60 flex items-center gap-1.5">
        <.icon name="hero-information-circle" class="w-4 h-4 shrink-0 text-base-content/40" />
        <span>
          The run keeps going if you close this page. You can stop it at any point and keep
          everything it has already done.
        </span>
      </p>

      <div>
        <.button id="start-run-button" type="submit" variant="primary">
          <.icon name="hero-play" class="w-4 h-4 mr-1.5" /> Start
        </.button>
      </div>
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
    <div id="run-progress" class="flex flex-col gap-4">
      <div class="flex items-center justify-between gap-3 flex-wrap">
        <div class="flex items-center gap-2.5">
          <span class="loading loading-spinner loading-sm text-primary" />
          <span class="font-semibold text-base">{phase_label(@run.phase)}</span>
          <span :if={@run.status == :stopping} class="badge badge-warning badge-sm">Stopping</span>
        </div>
        <span class="badge badge-ghost badge-sm">{mode_label(@run.mode)} mode</span>
      </div>

      <.run_stats run={@run} />

      <div
        :if={@run.current_file}
        class="bg-base-200/50 rounded-lg px-3 py-2 text-xs font-mono text-base-content/70 truncate flex items-center gap-2 border border-base-200"
      >
        <.icon name="hero-document" class="w-3.5 h-3.5 shrink-0 opacity-50" />
        <span class="truncate">{@run.current_file}</span>
      </div>

      <div class="pt-1">
        <.button
          id="stop-run-button"
          phx-click="stop_run"
          disabled={@run.status == :stopping}
          class="btn btn-sm btn-outline btn-warning"
        >
          <.icon name="hero-stop" class="w-4 h-4 mr-1" /> Stop and keep progress
        </.button>
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
  attr :pending_groups, :integer, default: 0

  defp run_outcome(assigns) do
    ~H"""
    <div id="run-outcome" class="flex flex-col gap-4">
      <div class={[
        "alert flex items-center justify-between gap-3 py-3 px-4 shadow-sm",
        outcome_alert_class(@run.status)
      ]}>
        <div class="flex items-center gap-2.5 min-w-0">
          <.icon name={outcome_icon(@run.status)} class="w-5 h-5 shrink-0" />
          <span class="font-semibold">{outcome_label(@run.status)}</span>
          <span class="badge badge-sm badge-ghost opacity-80">{mode_label(@run.mode)}</span>
        </div>

        <.outcome_review_cta pending_groups={@pending_groups} />
      </div>

      <.run_stats run={@run} />

      <%!--
        Rendered for any status that carries an error, not only :failed. A run
        released by boot reconciliation, or by the recovery control above,
        lands on :stopped with the explanation in this field, and hiding it
        would leave the user with a bare "Import stopped" and no reason.
      --%>
      <div :if={@run.error} class="bg-error/10 border border-error/20 rounded-xl p-3.5 text-xs">
        <p class="font-semibold text-error mb-1.5 flex items-center gap-1.5">
          <.icon name="hero-exclamation-triangle" class="w-4 h-4 shrink-0" />
          {error_label(@run.status)}
        </p>
        <pre class="font-mono text-xs whitespace-pre-wrap break-all bg-base-100/90 rounded-lg p-2.5 text-base-content/90 border border-base-200">{@run.error}</pre>
      </div>
    </div>
    """
  end

  # `pending_groups` is `ImportGroups.band_counts/1`'s `:total` for this run's
  # own library path, computed once in the parent LiveView
  # (`group_count_for_outcome/1`) so this component never queries the DB from
  # its body. It is a group count, not a file count -- one group can hold a
  # whole season -- matching the "group(s)" language the rest of this page
  # uses for accept/ignore counts.
  attr :pending_groups, :integer, default: 0

  defp outcome_review_cta(assigns) do
    ~H"""
    <div :if={@pending_groups > 0} class="shrink-0">
      <.link navigate={~p"/import"} class="btn btn-xs sm:btn-sm btn-primary shadow-sm">
        <.icon name="hero-inbox-stack" class="w-4 h-4 mr-1" />
        Review {@pending_groups} group(s) that need attention
      </.link>
    </div>
    """
  end

  attr :run, :map, required: true

  defp run_stats(assigns) do
    ~H"""
    <div class="stats stats-horizontal bg-base-200/50 border border-base-200 w-full grid grid-cols-3 divide-x divide-base-200 rounded-xl overflow-hidden">
      <div class="stat px-4 py-3">
        <div class="stat-title text-xs font-medium text-base-content/60">Found</div>
        <div class="stat-value text-xl font-bold text-base-content">
          {number(@run.files_discovered)}
        </div>
      </div>
      <div class="stat px-4 py-3">
        <div class="stat-title text-xs font-medium text-base-content/60">Matched</div>
        <div class="stat-value text-xl font-bold text-base-content">{number(@run.files_matched)}</div>
      </div>
      <div class="stat px-4 py-3">
        <div class="stat-title text-xs font-medium text-base-content/60">Added</div>
        <div class="stat-value text-xl font-bold text-success">{number(@run.files_linked)}</div>
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

  defp outcome_badge_class(:done), do: "badge-success"
  defp outcome_badge_class(:failed), do: "badge-error"
  defp outcome_badge_class(:stopped), do: "badge-warning"

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
