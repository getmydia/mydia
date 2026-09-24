defmodule MydiaWeb.MetricsControllerTest do
  use MydiaWeb.ConnCase, async: false

  @prometheus_accept "application/openmetrics-text;version=1.0.0,text/plain;version=0.0.4;q=0.5,*/*;q=0.1"

  test "404 when metrics are disabled", %{conn: conn} do
    conn = get(conn, ~p"/metrics")
    assert response(conn, 404)
  end

  describe "when enabled" do
    setup do
      start_supervised!(
        {Peep, name: Mydia.Metrics.Peep, metrics: Mydia.Metrics.Definitions.all()}
      )

      :ok
    end

    test "serves Prometheus text to a Prometheus Accept header", %{conn: conn} do
      Mydia.Metrics.Measurements.vm()
      Mydia.Metrics.Measurements.downloads()

      conn =
        conn
        |> put_req_header("accept", @prometheus_accept)
        |> get(~p"/metrics")

      body = response(conn, 200)
      assert [content_type] = get_resp_header(conn, "content-type")
      assert content_type =~ "text/plain"
      assert content_type =~ "version=0.0.4"
      assert body =~ "# TYPE mydia_vm_memory_bytes gauge"
      assert body =~ ~s(mydia_downloads{state="active"})
    end

    test "labels routes by pattern, never by id, and skips its own scrape", %{conn: conn} do
      # Any route with a path parameter works; this one 401s without auth,
      # which still dispatches through the router.
      get(build_conn(), "/api/v1/media/#{Ecto.UUID.generate()}")
      get(build_conn(), ~p"/metrics")

      body = conn |> get(~p"/metrics") |> response(200)

      assert body =~ "mydia_http_request_duration_milliseconds_bucket"
      refute body =~ ~r/route="[^"]*[0-9a-f]{8}-[0-9a-f]{4}-/
      refute body =~ ~r/="\d+"/
      refute body =~ ~s(route="/metrics")
    end
  end
end
