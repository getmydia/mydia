defmodule MydiaWeb.MetricsController do
  @moduledoc """
  Prometheus scrape endpoint. Unauthenticated and off unless
  `MYDIA_METRICS_ENABLED=true`; see `Mydia.Metrics`.
  """
  use MydiaWeb, :controller

  def index(conn, _params) do
    case Mydia.Metrics.export() do
      {:ok, body} ->
        conn
        |> put_resp_content_type("text/plain; version=0.0.4", "utf-8")
        |> send_resp(200, body)

      :disabled ->
        send_resp(conn, 404, "")
    end
  end
end
