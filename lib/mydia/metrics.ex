defmodule Mydia.Metrics do
  @moduledoc """
  The Prometheus endpoint at `GET /metrics`.

  Off unless `MYDIA_METRICS_ENABLED=true`. `Mydia.Metrics.Supervisor` runs a
  Peep instance with `Mydia.Metrics.Definitions.all/0` and two pollers that
  feed its gauges. The endpoint is unauthenticated, which is why it is opt-in.
  Independent of `Mydia.Perf`: either can be on without the other.
  """

  @peep Mydia.Metrics.Peep

  @doc "Whether this node serves metrics: the `:enabled` config, and not a `mydia-cli` invocation."
  @spec enabled?() :: boolean()
  def enabled? do
    enabled?(
      Application.get_env(:mydia, __MODULE__, []),
      System.get_env("MYDIA_CLI_MODE") == "true"
    )
  end

  @doc false
  @spec enabled?(keyword(), boolean()) :: boolean()
  def enabled?(config, cli_mode?), do: Keyword.get(config, :enabled, false) and not cli_mode?

  @doc "The Prometheus text exposition, or `:disabled` when nothing is recording."
  @spec export() :: {:ok, iodata()} | :disabled
  def export do
    if Process.whereis(@peep) do
      {:ok, @peep |> Peep.get_all_metrics() |> Peep.Prometheus.export()}
    else
      :disabled
    end
  end
end
