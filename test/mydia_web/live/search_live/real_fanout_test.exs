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
    Mydia.IndexerMock.stub_prowlarr_indexer_status(bypass)

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

  test "the Prowlarr row names indexers Prowlarr skipped, and retests them", %{conn: conn} do
    bypass = Bypass.open()
    till = DateTime.utc_now() |> DateTime.add(600, :second) |> DateTime.to_iso8601()

    Bypass.stub(bypass, "GET", "/api/v1/search", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!([real_result_item("Fictional.Feature.2031.1080p")]))
    end)

    Mydia.IndexerMock.stub_prowlarr_indexer_status(bypass, [
      %{"indexerId" => 1, "disabledTill" => till}
    ])

    Mydia.IndexerMock.mock_prowlarr_indexers(bypass)

    Bypass.stub(bypass, "GET", "/api/v1/indexer/1", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"id" => 1}))
    end)

    Bypass.expect_once(bypass, "POST", "/api/v1/indexer/test", fn conn ->
      Plug.Conn.resp(conn, 200, "")
    end)

    config =
      indexer_config_fixture(%{
        name: "paused-reporting-indexer",
        type: :prowlarr,
        base_url: "http://localhost:#{bypass.port}"
      })

    {:ok, view, _html} = live(conn, ~p"/search")
    render_patch(view, ~p"/search?q=Fictional+Feature")

    eventually(view, fn _html -> has_element?(view, "#indexer-paused-#{config.id}") end)
    assert has_element?(view, "#indexer-paused-#{config.id}", "Fictional Tracker")

    view |> element("#indexer-retest-paused-#{config.id}") |> render_click()

    eventually(view, fn _html -> has_element?(view, "#flash-info") end)
    assert has_element?(view, "#flash-info", "Fictional Tracker recovered")
  end
end
