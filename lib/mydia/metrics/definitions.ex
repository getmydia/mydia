defmodule Mydia.Metrics.Definitions do
  @moduledoc """
  The metrics `GET /metrics` exposes.

  Separate from `Mydia.Perf.Metrics` on purpose: that list is keyed for
  diagnosis (query callers, ~100 buckets per series) and would put tens of
  thousands of series on a home Prometheus. Every label here has a bounded set
  of values, and every histogram has about ten buckets.

  Durations are milliseconds: Peep stores a histogram's sum as a rounded
  integer, so a seconds unit would add 0 for every sub-second request.
  """

  import Telemetry.Metrics

  alias Mydia.Metrics.{Buckets, Tags}
  alias Mydia.Perf.Keys

  @ms {:native, :millisecond}

  @spec all() :: [Telemetry.Metrics.t()]
  def all, do: vm() ++ http() ++ oban() ++ library() ++ downloads() ++ streaming()

  defp vm do
    [
      gauge("mydia.vm.memory.bytes", :vm_memory, [:kind], "BEAM memory by kind"),
      gauge("mydia.vm.run_queue.length", :vm_run_queue, [], "Processes waiting to run"),
      gauge("mydia.vm.process.count", :vm_processes, [], "Running BEAM processes"),
      gauge("mydia.uptime.seconds", :uptime, [], "Seconds since the node started"),
      gauge("mydia.build.info", :build_info, [:version], "Always 1; the version is the label")
    ]
  end

  defp http do
    [
      distribution("mydia.http.request.duration.milliseconds",
        event_name: [:phoenix, :router_dispatch, :stop],
        measurement: :duration,
        unit: @ms,
        tags: [:route, :method, :status_class],
        tag_values: &Tags.http/1,
        keep: &Tags.keep_http?/1,
        reporter_options: [peep_bucket_calculator: Buckets.Http],
        description: "HTTP request duration by route pattern"
      ),
      counter("mydia.liveview.mounts.total",
        event_name: [:phoenix, :live_view, :mount, :stop],
        tags: [:view],
        tag_values: &Keys.live_view/1,
        description: "LiveView mounts by view"
      )
    ]
  end

  defp oban do
    [
      gauge(
        "mydia.oban.jobs",
        :oban_jobs,
        [:queue, :state],
        "Oban jobs waiting, scheduled, running or retrying, by queue and state"
      ),
      distribution("mydia.oban.job.duration.milliseconds",
        event_name: [:oban, :job, :stop],
        measurement: :duration,
        unit: @ms,
        tags: [:queue, :worker],
        tag_values: &Tags.oban_job/1,
        reporter_options: [peep_bucket_calculator: Buckets.Job],
        description: "Oban job duration"
      ),
      counter("mydia.oban.job.failures.total",
        event_name: [:oban, :job, :exception],
        tags: [:queue, :worker],
        tag_values: &Tags.oban_job/1,
        description: "Oban job attempts that raised or returned an error"
      )
    ]
  end

  defp library do
    [
      gauge("mydia.library.items", :library_items, [:type], "Movies and shows in the library"),
      gauge(
        "mydia.library.episodes",
        :library_episodes,
        [:state, :monitored],
        "Episodes by availability"
      ),
      gauge(
        "mydia.library.media_files",
        :library_media_files,
        [],
        "Media files, excluding trash"
      ),
      gauge("mydia.library.size.bytes", :library_size, [], "Bytes of media, excluding trash")
    ]
  end

  defp downloads do
    [
      gauge("mydia.downloads", :downloads, [:state], "Downloads by derived state"),
      gauge(
        "mydia.download_client.up",
        :download_client_up,
        [:client],
        "1 when the client's last health check passed"
      )
    ]
  end

  defp streaming do
    [
      gauge("mydia.hls.sessions", :hls_sessions, [:mode], "Running HLS sessions"),
      gauge(
        "mydia.direct_play.sessions",
        :direct_play_sessions,
        [:kind],
        "Running direct-play and remux sessions"
      )
    ]
  end

  # A last_value fed by Mydia.Metrics.Measurements under [:mydia, :metrics, event].
  defp gauge(name, event, tags, description) do
    last_value(name,
      event_name: [:mydia, :metrics, event],
      measurement: :value,
      tags: tags,
      description: description
    )
  end
end
