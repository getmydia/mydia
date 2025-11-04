defmodule MydiaWeb.JobsLive.Index do
  use MydiaWeb, :live_view
  alias Mydia.Jobs

  @history_per_page 20

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe to Oban events for real-time updates
    if connected?(socket) do
      :telemetry.attach(
        "jobs-live-#{inspect(self())}",
        [:oban, :job, :stop],
        &__MODULE__.handle_oban_event/4,
        %{pid: self()}
      )
    end

    {:ok,
     socket
     |> assign(:page_title, "Background Jobs")
     |> assign(:filter_worker, nil)
     |> assign(:filter_state, nil)
     |> assign(:page, 0)
     |> assign(:has_more, true)
     |> assign(:selected_job, nil)
     |> assign(:trigger_confirmation, nil)
     |> load_cron_jobs()
     |> load_job_history(reset: true)}
  end

  @impl true
  def terminate(_reason, _socket) do
    :telemetry.detach("jobs-live-#{inspect(self())}")
    :ok
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", params, socket) do
    worker =
      case params["worker"] do
        "" -> nil
        w -> String.to_existing_atom("Elixir." <> w)
      end

    state =
      case params["state"] do
        "" -> nil
        s -> s
      end

    {:noreply,
     socket
     |> assign(:filter_worker, worker)
     |> assign(:filter_state, state)
     |> assign(:page, 0)
     |> load_job_history(reset: true)}
  end

  def handle_event("load_more", _params, socket) do
    if socket.assigns.has_more do
      {:noreply,
       socket
       |> update(:page, &(&1 + 1))
       |> load_job_history(reset: false)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("show_job_details", %{"id" => job_id}, socket) do
    job =
      socket.assigns.job_history
      |> Enum.find(fn {_dom_id, j} -> to_string(j.id) == job_id end)
      |> case do
        {_id, job} -> job
        nil -> nil
      end

    {:noreply, assign(socket, :selected_job, job)}
  end

  def handle_event("close_job_details", _params, socket) do
    {:noreply, assign(socket, :selected_job, nil)}
  end

  def handle_event("show_trigger_confirmation", %{"worker" => worker}, socket) do
    worker_atom = String.to_existing_atom("Elixir." <> worker)
    {:noreply, assign(socket, :trigger_confirmation, worker_atom)}
  end

  def handle_event("close_trigger_confirmation", _params, socket) do
    {:noreply, assign(socket, :trigger_confirmation, nil)}
  end

  def handle_event("trigger_job", %{"worker" => worker}, socket) do
    worker_atom = String.to_existing_atom("Elixir." <> worker)

    case Jobs.trigger_job(worker_atom) do
      {:ok, _job} ->
        {:noreply,
         socket
         |> assign(:trigger_confirmation, nil)
         |> put_flash(:info, "Job triggered successfully and added to queue")
         |> load_job_history(reset: true)}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> assign(:trigger_confirmation, nil)
         |> put_flash(:error, "Failed to trigger job")}
    end
  end

  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> load_cron_jobs()
     |> load_job_history(reset: true)
     |> put_flash(:info, "Refreshed")}
  end

  @impl true
  def handle_info({:job_completed, _worker}, socket) do
    # Refresh job history when a job completes
    {:noreply,
     socket
     |> load_cron_jobs()
     |> load_job_history(reset: true)}
  end

  # Telemetry handler callback
  def handle_oban_event([:oban, :job, :stop], _measurements, metadata, %{pid: pid}) do
    send(pid, {:job_completed, metadata.worker})
  end

  # Private functions

  defp load_cron_jobs(socket) do
    cron_jobs = Jobs.list_cron_jobs()

    # Enrich cron jobs with latest execution and stats
    cron_jobs_with_data =
      Enum.map(cron_jobs, fn job ->
        latest = Jobs.get_latest_job(job.worker)
        stats = Jobs.get_job_stats(job.worker)

        Map.merge(job, %{
          latest_job: latest,
          stats: stats
        })
      end)

    assign(socket, :cron_jobs, cron_jobs_with_data)
  end

  defp load_job_history(socket, opts) do
    reset? = Keyword.get(opts, :reset, false)
    page = if reset?, do: 0, else: socket.assigns.page

    query_opts = [
      worker: socket.assigns.filter_worker,
      state: socket.assigns.filter_state,
      limit: @history_per_page,
      offset: page * @history_per_page
    ]

    jobs = Jobs.list_job_history(query_opts)
    total = Jobs.count_job_history(query_opts)
    has_more = (page + 1) * @history_per_page < total

    # Create stream-compatible data
    job_history =
      if reset? do
        Enum.map(jobs, fn job -> {"job-#{job.id}", job} end)
      else
        socket.assigns.job_history ++ Enum.map(jobs, fn job -> {"job-#{job.id}", job} end)
      end

    socket
    |> assign(:job_history, job_history)
    |> assign(:has_more, has_more)
    |> assign(:job_history_empty?, reset? and jobs == [])
  end

  # View helpers

  defp format_relative_time(nil), do: "Never"

  defp format_relative_time(%DateTime{} = dt) do
    Timex.from_now(dt)
  end

  defp format_datetime(nil), do: "N/A"

  defp format_datetime(%DateTime{} = dt) do
    Timex.format!(dt, "{ISO:Extended}")
  end

  defp format_duration(nil, nil), do: "N/A"
  defp format_duration(nil, _), do: "N/A"
  defp format_duration(_, nil), do: "N/A"

  defp format_duration(%DateTime{} = attempted_at, %DateTime{} = completed_at) do
    duration = DateTime.diff(completed_at, attempted_at, :millisecond)
    format_duration_ms(duration)
  end

  defp format_duration_ms(ms) when is_integer(ms) do
    cond do
      ms >= 60_000 -> "#{Float.round(ms / 60_000, 1)}m"
      ms >= 1_000 -> "#{Float.round(ms / 1_000, 1)}s"
      true -> "#{ms}ms"
    end
  end

  defp format_duration_ms(_), do: "N/A"

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

  defp get_route_for_job(worker) do
    case worker do
      Mydia.Jobs.LibraryScanner -> "/media"
      _ -> nil
    end
  end
end
