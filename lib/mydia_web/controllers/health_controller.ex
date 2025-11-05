defmodule MydiaWeb.HealthController do
  use MydiaWeb, :controller

  @doc """
  Health check endpoint for Docker health checks and load balancers.
  Returns 200 OK with basic system status.
  """
  def check(conn, _params) do
    json(conn, %{
      status: "ok",
      service: "mydia",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end
end
