defmodule Mydia.Perf.Metrics do
  @moduledoc """
  The distributions `Mydia.Perf` records. `Mydia.Perf.Keys` derives every tag.

  Durations are recorded in microseconds. Peep adds `round(value)` to a
  distribution's sum, so a millisecond unit would add 0 for every
  sub-millisecond query.

  This list is separate from `MydiaWeb.Telemetry.metrics/0`, which feeds the
  development LiveDashboard.
  """

  import Telemetry.Metrics

  alias Mydia.Perf.Keys

  @unit {:native, :microsecond}

  # One hour in microseconds. Peep's default ceiling of 1e9 (1,000 seconds) is
  # shorter than a library scan or a long HLS stream.
  @long_running [max_value: 3_600_000_000]

  @spec all() :: [Telemetry.Metrics.Distribution.t()]
  def all do
    live_view() ++ web() ++ repo() ++ oban() ++ p2p()
  end

  defp live_view do
    [
      distribution("phoenix.live_view.mount.stop.duration",
        unit: @unit,
        tags: [:view, :connected],
        tag_values: &Keys.live_view/1
      ),
      distribution("phoenix.live_view.handle_params.stop.duration",
        unit: @unit,
        tags: [:view, :connected],
        tag_values: &Keys.live_view/1
      ),
      distribution("phoenix.live_view.handle_event.stop.duration",
        unit: @unit,
        tags: [:view, :event],
        tag_values: &Keys.live_view_event/1
      ),
      distribution("phoenix.live_view.render.stop.duration",
        unit: @unit,
        tags: [:view, :component],
        tag_values: &Keys.render/1
      ),
      distribution("phoenix.live_component.handle_event.stop.duration",
        unit: @unit,
        tags: [:component, :event],
        tag_values: &Keys.component_event/1
      )
    ]
  end

  defp web do
    [
      distribution("phoenix.router_dispatch.stop.duration",
        unit: @unit,
        tags: [:route],
        tag_values: &Keys.route/1
      ),
      distribution("absinthe.execute.operation.stop.duration",
        unit: @unit,
        tags: [:operation, :source],
        tag_values: &Keys.graphql/1,
        reporter_options: @long_running
      )
    ]
  end

  defp repo do
    [
      distribution("mydia.repo.query.total_time",
        unit: @unit,
        tags: [:caller, :source],
        tag_values: &Keys.query/1
      ),
      distribution("mydia.repo.query.queue_time",
        unit: @unit,
        tags: [:caller],
        tag_values: &Keys.query/1
      )
    ]
  end

  defp oban do
    [
      distribution("oban.job.stop.duration",
        unit: @unit,
        tags: [:worker, :state],
        tag_values: &Keys.oban_job/1,
        reporter_options: @long_running
      ),
      distribution("oban.job.exception.duration",
        unit: @unit,
        tags: [:worker],
        tag_values: &Keys.oban_job/1,
        reporter_options: @long_running
      ),
      distribution("oban.job.stop.queue_time",
        unit: @unit,
        tags: [:worker],
        tag_values: &Keys.oban_job/1,
        reporter_options: @long_running
      )
    ]
  end

  defp p2p do
    [
      distribution("mydia.p2p.request.stop.duration",
        unit: @unit,
        tags: [:kind],
        tag_values: &Keys.p2p_request/1,
        reporter_options: @long_running
      )
    ]
  end
end
