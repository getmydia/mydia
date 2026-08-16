defmodule MydiaWeb.SearchLive.RealFanoutTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.SettingsFixtures

  setup %{conn: conn} do
    {conn, _user} = register_and_log_in_user(conn)
    %{conn: conn}
  end

  defp real_result_item(title) do
    %{
      "title" => title,
      "size" => 8_000_000_000,
      "seeders" => 100,
      "leechers" => 5,
      "magnetUrl" => "magnet:?xt=urn:btih:#{:erlang.phash2(title)}",
      "indexer" => "upstream"
    }
  end

  defp eventually(view, assertion, retries \\ 100) do
    if retries == 0 do
      flunk("timed out waiting for assertion")
    else
      html = render(view)

      if assertion.(html),
        do: html,
        else: Process.sleep(50) && eventually(view, assertion, retries - 1)
    end
  end

  test "a real search_all fan-out renders results on /search", %{conn: conn} do
    bypass = Bypass.open()

    Bypass.expect(bypass, "GET", "/api/v1/search", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!([real_result_item("Dune.2021.1080p.BluRay")]))
    end)

    indexer_config_fixture(%{
      name: "real-indexer",
      type: :prowlarr,
      base_url: "http://localhost:#{bypass.port}"
    })

    {:ok, view, _html} = live(conn, ~p"/search")
    render_patch(view, ~p"/search?q=Dune")

    html = eventually(view, fn html -> html =~ "search-results-count" end)
    assert html =~ "Dune.2021.1080p.BluRay"
  end
end
