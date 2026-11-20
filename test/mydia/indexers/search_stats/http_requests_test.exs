defmodule Mydia.Indexers.SearchStats.HttpRequestsTest do
  @moduledoc """
  `http_requests` on the `[:mydia, :indexers, :search, :stop]` event: every
  request an indexer call sent to the tracker, counted against what Bypass saw.
  """
  # Turns the Cardigann feature flag on, which is global Application config.
  use Mydia.DataCase, async: false

  import Mydia.SettingsFixtures

  alias Mydia.Indexers
  alias Mydia.Indexers.{CardigannDefinition, CardigannHealthCheck, RateLimiter}
  alias Mydia.Indexers.SearchStats.Telemetry

  setup do
    original_features = Application.get_env(:mydia, :features, [])

    Application.put_env(
      :mydia,
      :features,
      Keyword.put(original_features, :cardigann_enabled, true)
    )

    on_exit(fn -> Application.put_env(:mydia, :features, original_features) end)

    Indexers.register_adapters()
    ref = :telemetry_test.attach_event_handlers(self(), [Telemetry.event()])
    on_exit(fn -> :telemetry.detach(ref) end)

    {:ok, ref: ref, bypass: Bypass.open()}
  end

  defp event(ref) do
    assert_receive {[:mydia, :indexers, :search, :stop], ^ref, measurements, metadata}, 5_000
    {measurements, metadata}
  end

  # Every request Bypass answers is reported, whatever its path.
  defp count_hits(bypass, handler) do
    test_pid = self()

    Bypass.expect(bypass, fn conn ->
      send(test_pid, {:hit, conn.method, conn.request_path})
      handler.(conn)
    end)
  end

  defp hits do
    receive do
      {:hit, _method, _path} -> 1 + hits()
    after
      0 -> 0
    end
  end

  defp html(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("text/html")
    |> Plug.Conn.resp(200, body)
  end

  defp rows(page) do
    """
    <table class="t">
      <tr>
        <td class="title">Invented.Lantern.Story.2031.Part#{page}.1080p-FAKE</td>
        <td class="size">1 GB</td>
        <td class="seeders">5</td>
        <td class="download"><a href="/dl/#{page}.torrent">get</a></td>
      </tr>
    </table>
    """
  end

  defp insert_definition!(bypass, extra_yaml, config \\ %{}) do
    base = "http://localhost:#{bypass.port}"
    id = "fictional-pages-#{System.unique_integer([:positive])}"

    yaml = """
    id: #{id}
    name: Fictional Pages
    description: An invented tracker with two pages of results
    language: en-US
    type: public
    encoding: UTF-8
    links:
      - #{base}/
    caps:
      modes:
        search: [q]
      categories:
        1: Movies
    #{extra_yaml}
    search:
      paths:
        - path: /browse/1
        - path: /browse/2
      inputs:
        q: "{{ .Keywords }}"
      rows:
        selector: table.t tr
      fields:
        category:
          text: 1
        title:
          selector: td.title
        size:
          selector: td.size
        seeders:
          selector: td.seeders
        download:
          selector: td.download a
          attribute: href
    """

    %CardigannDefinition{}
    |> CardigannDefinition.changeset(%{
      indexer_id: id,
      name: "Fictional Pages #{id}",
      type: "public",
      links: %{"0" => base <> "/"},
      capabilities: %{},
      schema_version: "v11",
      config: config,
      definition: yaml,
      enabled: true,
      in_library: true
    })
    |> Repo.insert!()
  end

  test "a built-in Cardigann search counts both of its pages", %{ref: ref, bypass: bypass} do
    count_hits(bypass, fn conn ->
      case conn.request_path do
        "/browse/1" -> html(conn, rows(1))
        "/browse/2" -> html(conn, rows(2))
      end
    end)

    definition = insert_definition!(bypass, "")

    {:ok, %{results: results}} =
      Indexers.search_all("Invented Lantern", indexer_ids: [definition.id])

    assert length(results) == 2

    {m, md} = event(ref)
    assert md.outcome == :ok
    assert m.http_requests == 2
    assert hits() == 2
  end

  test "a login before the search counts with the search", %{ref: ref, bypass: bypass} do
    count_hits(bypass, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/takelogin.php"} ->
          conn
          |> Plug.Conn.put_resp_header("set-cookie", "sid=invented; path=/")
          |> Plug.Conn.put_resp_header("location", "/index.php")
          |> Plug.Conn.resp(302, "")

        {"GET", "/index.php"} ->
          html(conn, ~s(<a href="/logout.php">Logout</a>))

        {"GET", "/browse/" <> page} ->
          html(conn, ~s(<a href="/logout.php">Logout</a>) <> rows(page))
      end
    end)

    login = """
    settings:
      - name: username
        type: text
        label: Username
      - name: password
        type: password
        label: Password
    login:
      path: /takelogin.php
      method: post
      inputs:
        username: "{{ .Config.username }}"
        password: "{{ .Config.password }}"
      test:
        path: /index.php
        selector: a[href*=logout]
    """

    definition =
      insert_definition!(bypass, login, %{"username" => "someone", "password" => "invented"})

    {:ok, %{results: [_ | _]}} =
      Indexers.search_all("Invented Lantern", indexer_ids: [definition.id])

    {m, md} = event(ref)
    assert md.outcome == :ok
    sent = hits()
    # The login POST and its redirect, then both pages at the least.
    assert sent >= 4
    assert m.http_requests == sent
  end

  test "a Newznab search counts one request", %{ref: ref, bypass: bypass} do
    count_hits(bypass, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/xml")
      |> Plug.Conn.resp(200, """
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0"><channel></channel></rss>
      """)
    end)

    config =
      indexer_config_fixture(%{
        name: "Imaginary Usenet",
        type: :newznab,
        base_url: "http://localhost:#{bypass.port}",
        api_key: "invented"
      })

    Indexers.search_all("Invented Lantern", indexer_ids: [config.id])

    {m, md} = event(ref)
    assert md.outcome == :ok
    assert m.http_requests == 1
    assert hits() == 1
  end

  test "a search skipped for a cooldown sends nothing and says so", %{ref: ref, bypass: bypass} do
    config =
      indexer_config_fixture(%{
        name: "Imaginary Cooling Relay",
        type: :jackett,
        base_url: "http://localhost:#{bypass.port}"
      })

    RateLimiter.record_rate_limited(config.id, nil)

    Indexers.search_all("Invented Lantern", indexer_ids: [config.id])

    {m, md} = event(ref)
    assert md.outcome == :skipped_cooldown
    assert Map.get(m, :http_requests) in [nil, 0]
  end

  test "a health probe counts its homepage GET and its search", %{ref: ref, bypass: bypass} do
    count_hits(bypass, fn conn ->
      case conn.request_path do
        "/" -> html(conn, "<html>Fictional Pages</html>")
        "/browse/1" -> html(conn, rows(1))
      end
    end)

    definition = insert_definition!(bypass, "")

    assert {:ok, %{success: true}} = CardigannHealthCheck.execute_health_check(definition)

    {m, md} = event(ref)
    assert md.kind == :health
    assert m.http_requests == 2
    assert hits() == 2
  end
end
