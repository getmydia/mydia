defmodule MydiaWeb.ImportMediaLive.RunControl do
  @moduledoc """
  Components for starting, watching, and stopping an import run.

  The run itself lives in Oban, so this panel is a view onto a database row
  plus a PubSub feed. Closing the tab does nothing to the run, and reopening
  re-attaches by reading the row.
  """
  use MydiaWeb, :html

  attr :library_path, :map, default: nil
  attr :active_run, :map, default: nil
  attr :outcome_run, :map, default: nil

  def run_control(assigns) do
    ~H"""
    <section
      id="import-run-control"
      class={[
        "bg-base-100 shadow-md border border-base-200 rounded-2xl p-4 sm:p-6",
        @active_run && "min-h-80 flex flex-col justify-center"
      ]}
    >
      <div :if={is_nil(@library_path)} class="alert alert-info">
        <.icon name="hero-information-circle" class="w-5 h-5 shrink-0" />
        <span>
          There is no movie or TV library to import yet. Add one under Settings, then come back.
        </span>
      </div>

      <%= if @library_path do %>
        <div :if={@active_run} class="flex flex-col gap-6 max-w-3xl w-full mx-auto">
          <div class="text-center">
            <div class="w-12 h-12 rounded-2xl bg-primary/10 text-primary flex items-center justify-center mx-auto mb-3">
              <span class="loading loading-spinner loading-md" />
            </div>
            <h2 class="text-2xl font-bold">Scanning {@library_path.path}</h2>
            <p class="text-sm text-base-content/60 mt-1 font-mono truncate">
              {@library_path.path}
            </p>
          </div>
          <.run_progress run={@active_run} />
        </div>

        <div :if={is_nil(@active_run)} class="flex flex-col gap-5">
          <.run_outcome :if={@outcome_run} run={@outcome_run} />
          <.start_form library_path={@library_path} />
        </div>
      <% end %>
    </section>
    """
  end

  attr :library_path, :map, required: true

  defp start_form(assigns) do
    ~H"""
    <.form
      for={%{}}
      id="start-run-form"
      phx-submit="start_run"
      class="flex flex-col sm:flex-row sm:items-center gap-4"
    >
      <input type="hidden" name="library_path_id" value={@library_path.id} />

      <div class="flex-1 min-w-0">
        <h2 class="text-lg font-bold">Scan this library</h2>
        <p class="text-xs text-base-content/60 mt-1 font-mono truncate">{@library_path.path}</p>
      </div>

      <label class="flex items-center gap-3 cursor-pointer rounded-xl border border-base-200 bg-base-200/40 px-3.5 py-2.5 hover:bg-base-200 transition-colors">
        <input
          id="auto-import-toggle"
          type="checkbox"
          name="auto_import"
          value="true"
          checked
          phx-hook="PersistedCheckbox"
          phx-update="ignore"
          class="toggle toggle-primary toggle-sm"
        />
        <span class="text-sm font-medium whitespace-nowrap">Automatically import confident matches</span>
      </label>

      <.button id="start-run-button" type="submit" variant="primary">
        <.icon name="hero-play" class="w-4 h-4 mr-1.5" /> Start scan
      </.button>
    </.form>
    """
  end

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
      </div>

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

  # Failed and stopped outcomes persist across reloads so recovery details
  # remain visible. Successful completion is transient and belongs beside
  # the review results instead of in the next scan's controls.
  attr :run, :map, required: true

  defp run_outcome(assigns) do
    ~H"""
    <div id="run-outcome" class="flex flex-col gap-3">
      <div
        :if={@run.status in [:failed, :stopped]}
        class={[
          "alert flex items-center gap-2.5 py-3 px-4 shadow-sm",
          outcome_alert_class(@run.status)
        ]}
      >
        <.icon name={outcome_icon(@run.status)} class="w-5 h-5 shrink-0" />
        <span class="font-semibold">{outcome_label(@run.status)}</span>
      </div>

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

  defp phase_label(:scanning), do: "Finding files"
  defp phase_label(:matching), do: "Identifying files"
  defp phase_label(:finished), do: "Finished"

  defp outcome_label(:failed), do: "Scan failed"
  defp outcome_label(:stopped), do: "Scan stopped"

  defp error_label(:failed), do: "Error details"
  defp error_label(_status), do: "What happened"

  defp outcome_alert_class(:failed), do: "alert-error"
  defp outcome_alert_class(:stopped), do: "alert-warning"

  defp outcome_icon(:failed), do: "hero-exclamation-triangle"
  defp outcome_icon(:stopped), do: "hero-stop-circle"
end
