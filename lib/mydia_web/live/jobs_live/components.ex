defmodule MydiaWeb.JobsLive.Components do
  @moduledoc false
  use MydiaWeb, :html

  def header_actions(assigns) do
    ~H"""
    <button id="refresh-jobs" type="button" class="btn btn-sm btn-ghost" phx-click="refresh_jobs">
      <.icon name="hero-arrow-path" class="w-4 h-4" /> {gettext("Refresh")}
    </button>
    """
  end

  attr :cron_jobs, :list, required: true
  attr :job_history, :list, required: true, doc: "{dom_id, %Oban.Job{}} tuples"
  attr :has_more, :boolean, required: true
  attr :filter_worker, :any, required: true
  attr :filter_state, :any, required: true
  attr :display, Mydia.TimeDisplay, required: true

  def jobs_tab(assigns) do
    ~H"""
    <.admin_section
      id="scheduled-jobs"
      title={gettext("Scheduled Jobs")}
      icon="hero-clock"
      count={length(@cron_jobs)}
    >
      <.admin_table id="cron-jobs" rows={@cron_jobs} row_id={&"cron-job-#{cron_job_slug(&1)}"}>
        <:col :let={job} label={gettext("Job")}>
          <div class="font-medium">{job.worker_name}</div>
          <div class="text-xs text-base-content/60">{inspect(job.worker)}</div>
        </:col>
        <:col :let={job} label={gettext("Schedule")}>
          <code class="text-xs bg-base-300 px-2 py-1 rounded">{job.schedule}</code>
        </:col>
        <:col :let={job} label={gettext("Last Run")}>
          <%= if job.latest_job do %>
            <div>{format_relative_time(job.latest_job.attempted_at)}</div>
            <div class="text-xs text-base-content/60">
              <.local_time at={job.latest_job.attempted_at} display={@display} />
            </div>
          <% else %>
            <span class="text-base-content/50">{gettext("Never")}</span>
          <% end %>
        </:col>
        <:col :let={job} label={gettext("Next Run")}>
          <%= if job.next_run do %>
            <div>{format_relative_time(job.next_run)}</div>
            <div class="text-xs text-base-content/60">
              <.local_time at={job.next_run} display={@display} />
            </div>
          <% else %>
            <span class="text-base-content/50">{gettext("N/A")}</span>
          <% end %>
        </:col>
        <:col :let={job} label={pgettext("list column", "Status")}>
          <%= if job.latest_job do %>
            <span class={["badge badge-sm", state_badge_class(job.latest_job.state)]}>
              {state_label(job.latest_job.state)}
            </span>
          <% else %>
            <span class="badge badge-sm badge-ghost">{state_label("pending")}</span>
          <% end %>
        </:col>
        <:col :let={job} label={gettext("Stats")}>
          <div class="text-sm">
            <div>{gettext("Success: %{rate}%", rate: job.stats.success_rate)}</div>
            <div class="text-xs text-base-content/60">
              {gettext("%{completed} / %{total} runs",
                completed: job.stats.completed_count,
                total: job.stats.total_executions
              )}
            </div>
            <div class="text-xs text-base-content/60">
              {gettext("Avg: %{duration}",
                duration: format_job_duration_ms(job.stats.avg_duration_ms)
              )}
            </div>
          </div>
        </:col>
        <:action :let={job}>
          <.row_action
            id={"trigger-#{cron_job_slug(job)}"}
            icon="hero-play"
            title={gettext("Trigger now")}
            phx-click="confirm_trigger_job"
            phx-value-worker={inspect(job.worker)}
          />
          <.row_action
            :if={get_route_for_job(job.worker)}
            id={"view-#{cron_job_slug(job)}"}
            icon="hero-arrow-top-right-on-square"
            title={gettext("View")}
            phx-click={view_job_click(job.worker)}
          />
        </:action>
        <:empty>{gettext("No scheduled jobs configured.")}</:empty>
      </.admin_table>
    </.admin_section>

    <.admin_section
      id="job-history-section"
      title={gettext("Job History")}
      icon="hero-queue-list"
    >
      <form
        id="jobs-filter-form"
        phx-change="filter_job_history"
        class="grid grid-cols-1 md:grid-cols-2 gap-4"
      >
        <div>
          <label class="label">
            <span class="label-text">{gettext("Filter by Job")}</span>
          </label>
          <select name="worker" class="select select-bordered w-full">
            <option value="">{gettext("All Jobs")}</option>
            <%= for job <- @cron_jobs do %>
              <option value={inspect(job.worker)} selected={@filter_worker == job.worker}>
                {job.worker_name}
              </option>
            <% end %>
          </select>
        </div>
        <div>
          <label class="label">
            <span class="label-text">{gettext("Filter by Status")}</span>
          </label>
          <select name="state" class="select select-bordered w-full">
            <option value="">{gettext("All States")}</option>
            <option value="completed" selected={@filter_state == "completed"}>
              {pgettext("job state filter", "Completed")}
            </option>
            <option value="failed" selected={@filter_state == "failed"}>
              {pgettext("job state filter", "Failed")}
            </option>
            <option value="discarded" selected={@filter_state == "discarded"}>
              {pgettext("job state filter", "Discarded")}
            </option>
            <option value="retryable" selected={@filter_state == "retryable"}>
              {pgettext("job state filter", "Retryable")}
            </option>
            <option value="executing" selected={@filter_state == "executing"}>
              {pgettext("job state filter", "Executing")}
            </option>
          </select>
        </div>
      </form>
      <.admin_table
        id="job-history"
        rows={@job_history}
        row_id={fn {dom_id, _job} -> dom_id end}
      >
        <:col :let={{_id, job}} label={gettext("Job")}>
          <div class="font-medium">
            {job.worker |> String.split(".") |> List.last()}
          </div>
          <div class="text-xs text-base-content/60">{job.worker}</div>
        </:col>
        <:col :let={{_id, job}} label={gettext("Attempted At")}>
          <div>{format_relative_time(job.attempted_at)}</div>
          <div class="text-xs text-base-content/60">
            <.local_time at={job.attempted_at} display={@display} />
          </div>
        </:col>
        <:col :let={{_id, job}} label={gettext("Completed At")}>
          <%= if job.completed_at do %>
            <div>{format_relative_time(job.completed_at)}</div>
            <div class="text-xs text-base-content/60">
              <.local_time at={job.completed_at} display={@display} />
            </div>
          <% else %>
            <span class="text-base-content/50">-</span>
          <% end %>
        </:col>
        <:col :let={{_id, job}} label={gettext("Duration")}>
          {format_job_duration(job.attempted_at, job.completed_at)}
        </:col>
        <:col :let={{_id, job}} label={gettext("State")}>
          <span class={["badge badge-sm", state_badge_class(job.state)]}>
            {state_label(job.state)}
          </span>
        </:col>
        <:col :let={{_id, job}} label={gettext("Attempt")}>
          <span class="text-sm">
            {job.attempt} / {job.max_attempts}
          </span>
        </:col>
        <:action :let={{_id, job}}>
          <.row_action
            id={"job-details-#{job.id}"}
            icon="hero-eye"
            title={gettext("Details")}
            phx-click="show_job_details"
            phx-value-id={job.id}
          />
          <.row_action
            :if={job.state in ~w(available scheduled retryable executing)}
            id={"cancel-job-#{job.id}"}
            icon="hero-x-mark"
            title={gettext("Cancel job")}
            destructive
            phx-click="cancel_job"
            phx-value-id={job.id}
            data-confirm={gettext("Cancel this job?")}
          />
        </:action>
        <:empty>{gettext("No job history found")}</:empty>
      </.admin_table>
      <div :if={@has_more and @job_history != []} class="flex justify-center">
        <button type="button" class="btn btn-outline btn-sm" phx-click="load_more_job_history">
          {gettext("Load More")}
        </button>
      </div>
    </.admin_section>
    """
  end

  attr :job, :any, required: true
  attr :display, Mydia.TimeDisplay, required: true

  def job_details_modal(assigns) do
    ~H"""
    <.admin_modal
      id="job-details-modal"
      icon="hero-document-magnifying-glass"
      title={gettext("Job Details")}
      subtitle={@job.worker}
      size={:lg}
      on_close="close_job_details_modal"
    >
      <div class="space-y-4">
        <div class="grid grid-cols-2 gap-4">
          <div>
            <div class="text-sm font-semibold text-base-content/60">{gettext("State")}</div>
            <span class={["badge", state_badge_class(@job.state)]}>
              {state_label(@job.state)}
            </span>
          </div>
          <div>
            <div class="text-sm font-semibold text-base-content/60">{gettext("Attempt")}</div>
            <div>{@job.attempt} / {@job.max_attempts}</div>
          </div>
        </div>

        <div class="grid grid-cols-2 gap-4">
          <div>
            <div class="text-sm font-semibold text-base-content/60">
              {gettext("Scheduled At")}
            </div>
            <div>
              <.local_time at={@job.scheduled_at} format={:datetime_full} display={@display} />
            </div>
          </div>
          <div>
            <div class="text-sm font-semibold text-base-content/60">
              {gettext("Attempted At")}
            </div>
            <div>
              <.local_time at={@job.attempted_at} format={:datetime_full} display={@display} />
            </div>
          </div>
        </div>

        <div class="grid grid-cols-2 gap-4">
          <div>
            <div class="text-sm font-semibold text-base-content/60">
              {gettext("Completed At")}
            </div>
            <div>
              <.local_time at={@job.completed_at} format={:datetime_full} display={@display} />
            </div>
          </div>
          <div>
            <div class="text-sm font-semibold text-base-content/60">{gettext("Duration")}</div>
            <div>
              {format_job_duration(@job.attempted_at, @job.completed_at)}
            </div>
          </div>
        </div>

        <div>
          <div class="text-sm font-semibold text-base-content/60">{gettext("Arguments")}</div>
          <pre class="bg-base-300 p-3 rounded text-xs sm:overflow-x-auto max-sm:whitespace-pre-wrap max-sm:break-all">{inspect(@job.args, pretty: true)}</pre>
        </div>

        <%= if @job.errors && @job.errors != [] do %>
          <div>
            <div class="text-sm font-semibold text-base-content/60 mb-2">{gettext("Errors")}</div>
            <%= for error <- @job.errors do %>
              <div class="alert alert-error mb-2">
                <pre class="text-xs sm:overflow-x-auto whitespace-pre-wrap max-sm:break-all">{inspect(error, pretty: true)}</pre>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>
      <:actions>
        <button type="button" class="btn" phx-click="close_job_details_modal">
          {gettext("Close")}
        </button>
      </:actions>
    </.admin_modal>
    """
  end

  attr :worker, :atom, required: true

  def trigger_job_modal(assigns) do
    ~H"""
    <.admin_modal
      id="trigger-job-modal"
      icon="hero-play"
      title={gettext("Trigger Job")}
      subtitle={gettext("Run it now, outside its schedule")}
      on_close="close_trigger_job_modal"
    >
      <div class="bg-base-300 p-3 rounded text-sm font-semibold">
        {gettext("Job: %{name}", name: inspect(@worker))}
      </div>
      <:actions>
        <button type="button" class="btn btn-ghost" phx-click="close_trigger_job_modal">
          {gettext("Cancel")}
        </button>
        <button
          type="button"
          class="btn btn-primary"
          phx-click="trigger_job"
          phx-value-worker={inspect(@worker)}
        >
          {gettext("Trigger Now")}
        </button>
      </:actions>
    </.admin_modal>
    """
  end

  defp cron_job_slug(job),
    do: job.worker |> inspect() |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

  defp format_relative_time(nil), do: gettext("Never")
  defp format_relative_time(%DateTime{} = dt), do: MydiaWeb.RelativeTime.from_now(dt)

  defp format_job_duration(nil, _), do: gettext("N/A")
  defp format_job_duration(_, nil), do: gettext("N/A")

  defp format_job_duration(%DateTime{} = attempted_at, %DateTime{} = completed_at) do
    format_job_duration_ms(DateTime.diff(completed_at, attempted_at, :millisecond))
  end

  defp format_job_duration_ms(ms) when is_integer(ms) do
    cond do
      ms >= 60_000 -> "#{Float.round(ms / 60_000, 1)}m"
      ms >= 1_000 -> "#{Float.round(ms / 1_000, 1)}s"
      true -> "#{ms}ms"
    end
  end

  defp format_job_duration_ms(_), do: gettext("N/A")

  # Oban job states shown as badges: one clause per known state, raw fallback.
  defp state_label("completed"), do: pgettext("job state", "completed")
  defp state_label("failed"), do: pgettext("job state", "failed")
  defp state_label("discarded"), do: pgettext("job state", "discarded")
  defp state_label("cancelled"), do: pgettext("job state", "cancelled")
  defp state_label("retryable"), do: pgettext("job state", "retryable")
  defp state_label("scheduled"), do: pgettext("job state", "scheduled")
  defp state_label("executing"), do: pgettext("job state", "executing")
  defp state_label("available"), do: pgettext("job state", "available")
  defp state_label("pending"), do: pgettext("job state", "pending")
  defp state_label(other), do: other

  defp state_badge_class(state) do
    case state do
      "completed" -> "badge-success"
      "failed" -> "badge-error"
      "discarded" -> "badge-error"
      "cancelled" -> "badge-warning"
      "retryable" -> "badge-warning"
      "scheduled" -> "badge-info"
      "executing" -> "badge-primary"
      _ -> "badge-ghost"
    end
  end

  defp view_job_click(worker) do
    case get_route_for_job(worker) do
      nil -> nil
      route -> JS.navigate(route)
    end
  end

  defp get_route_for_job(Mydia.Jobs.LibraryScanner), do: "/media"
  defp get_route_for_job(_worker), do: nil
end
