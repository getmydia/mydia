defmodule Mydia.Indexers.CardigannHealthCheckTest do
  # probe_search/3 issues real HTTP searches through Bypass and, in the
  # "active_link promotion" test, persists through Repo from the test process.
  # async: false keeps this on the shared sandbox connection.
  use Mydia.DataCase, async: false

  alias Mydia.Indexers.CardigannHealthCheck
  alias Mydia.Indexers.CardigannDefinition
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Repo

  import Mydia.IndexersFixtures

  describe "test_connection/2" do
    test "returns error when definition not found" do
      assert {:error, "Indexer definition not found"} =
               CardigannHealthCheck.test_connection(Ecto.UUID.generate())
    end

    test "tests connection for valid public indexer" do
      # The fixture's default links point at https://example.com. Before
      # cardigann_definition_fixture/1 carried size/seeders fields,
      # CardigannParser.validate_search_fields/1 rejected that YAML before any
      # HTTP call happened, so this test never actually reached the network.
      # Now that the definition parses, it must be pointed at a local Bypass
      # server instead, or it makes a live, unmocked, un-tagged :external
      # request to example.com on every run.
      definition = cardigann_definition_fixture(%{enabled: true, type: "public"})

      bypass = Bypass.open()
      Bypass.stub(bypass, "GET", "/", fn conn -> Plug.Conn.resp(conn, 200, "<html/>") end)

      Bypass.stub(bypass, "GET", "/search", fn conn ->
        Plug.Conn.resp(
          conn,
          200,
          ~s"""
          <html><body><table class="results">
          <tr><td class="title">Some Release</td>
          <td class="download"><a href="/download/1">grab</a></td></tr>
          </table></body></html>
          """
        )
      end)

      put_link(definition, "http://localhost:#{bypass.port}")

      result = CardigannHealthCheck.test_connection(definition.id)

      assert {:ok, test_result} = result
      assert is_map(test_result)
      assert Map.has_key?(test_result, :success)
      assert Map.has_key?(test_result, :status)
      assert Map.has_key?(test_result, :message)
    end
  end

  describe "execute_health_check/2" do
    test "updates health status after successful check" do
      # See the comment on "tests connection for valid public indexer" above:
      # the unmodified fixture now parses and would otherwise reach
      # example.com over the real network.
      definition = cardigann_definition_fixture(%{enabled: true})

      bypass = Bypass.open()
      Bypass.stub(bypass, "GET", "/", fn conn -> Plug.Conn.resp(conn, 200, "<html/>") end)

      Bypass.stub(bypass, "GET", "/search", fn conn ->
        Plug.Conn.resp(
          conn,
          200,
          ~s"""
          <html><body><table class="results">
          <tr><td class="title">Some Release</td>
          <td class="download"><a href="/download/1">grab</a></td></tr>
          </table></body></html>
          """
        )
      end)

      {:ok, _result} =
        CardigannHealthCheck.execute_health_check(
          put_link(definition, "http://localhost:#{bypass.port}")
        )

      # Verify health status was updated in database
      updated_definition = Repo.get!(CardigannDefinition, definition.id)
      assert updated_definition.last_health_check_at != nil
      assert updated_definition.health_status in ["healthy", "degraded", "unhealthy", "unknown"]
    end

    test "tracks consecutive failures" do
      # A closed local port, not a real hostname, gives a deterministic
      # connection failure without touching the network (same pattern as the
      # failover tests in cardigann_search_engine_test.exs).
      definition = cardigann_definition_fixture(%{enabled: true, consecutive_failures: 2})

      bypass = Bypass.open()
      Bypass.down(bypass)

      {:ok, result} =
        CardigannHealthCheck.execute_health_check(
          put_link(definition, "http://localhost:#{bypass.port}")
        )

      # Check that consecutive failures was updated
      updated_definition = Repo.get!(CardigannDefinition, definition.id)

      if result.success do
        # If successful, consecutive failures should be reset
        assert updated_definition.consecutive_failures == 0
        assert updated_definition.last_successful_query_at != nil
      else
        # If failed, consecutive failures should increment
        assert updated_definition.consecutive_failures >= definition.consecutive_failures
      end
    end

    test "returns parsing error for invalid definition" do
      definition =
        cardigann_definition_fixture(%{
          enabled: true,
          definition: "invalid: yaml: content:"
        })

      assert {:ok, result} = CardigannHealthCheck.execute_health_check(definition)
      refute result.success
      assert result.status == "unhealthy"
      assert result.error != nil
    end
  end

  describe "probe_candidates/2" do
    setup do
      dead = Bypass.open()
      live = Bypass.open()
      Bypass.down(dead)

      {:ok,
       dead: dead,
       live: live,
       dead_url: "http://localhost:#{dead.port}",
       live_url: "http://localhost:#{live.port}"}
    end

    test "returns the first responding candidate", %{
      dead_url: dead_url,
      live_url: live_url,
      live: live
    } do
      Bypass.expect(live, "GET", "/", fn conn -> Plug.Conn.resp(conn, 200, "ok") end)
      parsed = %Parsed{links: [dead_url, live_url], legacylinks: []}

      assert {:ok, chosen, status} = CardigannHealthCheck.probe_candidates(parsed, %{})
      assert chosen == live_url
      assert status[dead_url]["ok"] == false
      assert status[live_url]["ok"] == true
    end

    test "prefers a live primary over a legacy link", %{
      live_url: live_url,
      dead_url: dead_url,
      live: live
    } do
      Bypass.expect(live, "GET", "/", fn conn -> Plug.Conn.resp(conn, 200, "ok") end)
      parsed = %Parsed{links: [live_url], legacylinks: [dead_url]}

      assert {:ok, chosen, _status} = CardigannHealthCheck.probe_candidates(parsed, %{})
      assert chosen == live_url
    end

    test "returns an error when every candidate fails", %{dead_url: dead_url} do
      parsed = %Parsed{links: [dead_url], legacylinks: []}

      assert {:error, status} = CardigannHealthCheck.probe_candidates(parsed, %{})
      assert status[dead_url]["ok"] == false
    end

    test "returns an error when there are no candidates" do
      assert {:error, status} =
               CardigannHealthCheck.probe_candidates(%Parsed{links: [], legacylinks: []}, %{})

      assert status == %{}
    end
  end

  describe "execute_health_check/2 link persistence" do
    test "stores the winning candidate as active_link" do
      dead = Bypass.open()
      live = Bypass.open()
      Bypass.down(dead)
      Bypass.expect(live, "GET", "/", fn conn -> Plug.Conn.resp(conn, 200, "ok") end)

      # The homepage answering is no longer enough to promote active_link: the
      # health check now also runs a real search, so the winning candidate's
      # search path has to answer too.
      Bypass.expect(live, "GET", "/search", fn conn ->
        Plug.Conn.resp(conn, 200, "<html><body></body></html>")
      end)

      dead_url = "http://localhost:#{dead.port}"
      live_url = "http://localhost:#{live.port}"

      {:ok, definition} =
        %CardigannDefinition{}
        |> CardigannDefinition.changeset(%{
          indexer_id: "probe-test",
          name: "Probe Test",
          type: "public",
          links: %{"0" => dead_url, "1" => live_url},
          capabilities: %{},
          schema_version: "v11",
          definition: """
          id: probe-test
          name: Probe Test
          description: d
          language: en-US
          type: public
          encoding: UTF-8
          links:
            - #{dead_url}
            - #{live_url}
          caps:
            categories:
              2000: Movies
          settings: []
          search:
            paths:
              - path: /search
            rows:
              selector: tr
            fields:
              title:
                selector: td.title
              size:
                selector: td.size
              seeders:
                selector: td.seeders
              download:
                selector: a
                attribute: href
          """
        })
        |> Repo.insert()

      assert {:ok, _result} = CardigannHealthCheck.execute_health_check(definition)

      reloaded = Repo.get!(CardigannDefinition, definition.id)
      assert reloaded.active_link == live_url
      assert reloaded.link_status[dead_url]["ok"] == false
      assert reloaded.link_status[live_url]["ok"] == true
    end

    test "preserves active_link when all candidate probes fail" do
      dead = Bypass.open()
      Bypass.down(dead)
      dead_url = "http://localhost:#{dead.port}"
      prior_active_link = "https://prior-mirror.example.com"

      {:ok, definition} =
        %CardigannDefinition{}
        |> CardigannDefinition.changeset(%{
          indexer_id: "probe-fail-preserve",
          name: "Probe Fail Preserve",
          type: "public",
          active_link: prior_active_link,
          links: %{"0" => dead_url},
          capabilities: %{},
          schema_version: "v11",
          definition: """
          id: probe-fail-preserve
          name: Probe Fail Preserve
          description: d
          language: en-US
          type: public
          encoding: UTF-8
          links:
            - #{dead_url}
          caps:
            categories:
              2000: Movies
          settings: []
          search:
            paths:
              - path: /search
            rows:
              selector: tr
            fields:
              title:
                selector: td.title
              size:
                selector: td.size
              seeders:
                selector: td.seeders
              download:
                selector: a
                attribute: href
          """
        })
        |> Repo.insert()

      assert {:ok, result} = CardigannHealthCheck.execute_health_check(definition)
      refute result.success

      reloaded = Repo.get!(CardigannDefinition, definition.id)
      assert reloaded.active_link == prior_active_link
      assert reloaded.link_status[dead_url]["ok"] == false
    end

    # Regression: the unreachable-probe branch hardcoded "unhealthy" while the
    # search-failure branch calls determine_health_status/3, which reports
    # "degraded" until consecutive_failures reaches 3. A single transient
    # network blip marked the indexer unhealthy while a search that had been
    # broken for weeks only reached degraded - backwards severity. Both
    # branches now escalate through the same three-strikes rule.
    test "an unreachable probe reports degraded, not unhealthy, before three consecutive failures" do
      dead = Bypass.open()
      Bypass.down(dead)
      dead_url = "http://localhost:#{dead.port}"

      {:ok, definition} =
        %CardigannDefinition{}
        |> CardigannDefinition.changeset(%{
          indexer_id: "probe-unreachable-severity",
          name: "Probe Unreachable Severity",
          type: "public",
          links: %{"0" => dead_url},
          capabilities: %{},
          schema_version: "v11",
          consecutive_failures: 0,
          definition: """
          id: probe-unreachable-severity
          name: Probe Unreachable Severity
          description: d
          language: en-US
          type: public
          encoding: UTF-8
          links:
            - #{dead_url}
          caps:
            categories:
              2000: Movies
          settings: []
          search:
            paths:
              - path: /search
            rows:
              selector: tr
            fields:
              title:
                selector: td.title
              size:
                selector: td.size
              seeders:
                selector: td.seeders
              download:
                selector: a
                attribute: href
          """
        })
        |> Repo.insert()

      assert {:ok, result} = CardigannHealthCheck.execute_health_check(definition)
      refute result.success
      assert result.status == "degraded"
    end
  end

  describe "check_all_enabled/0" do
    test "checks all enabled indexers" do
      # Create mix of enabled and disabled
      _enabled1 = cardigann_definition_fixture(%{enabled: true, name: "Enabled 1"})
      _enabled2 = cardigann_definition_fixture(%{enabled: true, name: "Enabled 2"})
      _disabled = cardigann_definition_fixture(%{enabled: false, name: "Disabled 1"})

      assert {:ok, results} = CardigannHealthCheck.check_all_enabled()
      assert is_map(results)
      # Should only check enabled indexers
      assert map_size(results) == 2
    end

    test "returns empty map when no indexers enabled" do
      _disabled = cardigann_definition_fixture(%{enabled: false})

      assert {:ok, results} = CardigannHealthCheck.check_all_enabled()
      assert results == %{}
    end
  end

  defp parsed_for(link, opts \\ []) do
    %Parsed{
      id: "probe-test",
      name: "Probe Test",
      description: "Test indexer",
      language: "en-US",
      type: "public",
      encoding: "UTF-8",
      links: [link],
      legacylinks: [],
      capabilities: %{modes: Keyword.get(opts, :modes, %{"search" => ["q"]})},
      follow_redirect: true,
      settings: [],
      search: %{
        paths: [%{path: Keyword.get(opts, :path, "/search")}],
        inputs: %{},
        headers: nil,
        keywordsfilters: [],
        rows: %{selector: "tr"},
        # CardigannResultParser only counts a row once it has both a title and a
        # download/infohash field (see "Only return row if we got at least
        # title and download/infohash" in cardigann_result_parser.ex), so the
        # probe fixture needs a download selector or every probe reads as zero
        # rows regardless of what the site actually returned.
        fields: %{
          title: %{selector: "td"},
          download: %{selector: "a", attribute: "href"}
        }
      },
      login: nil,
      download: nil
    }
  end

  # The stored definition YAML, not the definition's `links` column, is what
  # execute_health_check parses and probes against (see
  # test/support/fixtures/indexers_fixtures.ex). Rewriting the column alone
  # would leave the probe hitting the fixture's https://example.com default.
  # Accepts either a single URL or a list, so a test can set up more than one
  # candidate mirror in order (Links.candidates/1 preserves that order).
  defp put_link(definition, url_or_urls) do
    yaml_links =
      url_or_urls
      |> List.wrap()
      |> Enum.map_join("\n", &"  - #{&1}")

    updated_yaml =
      String.replace(
        definition.definition,
        ~r/^links:\n(?:  - .*\n?)+/m,
        "links:\n#{yaml_links}\n"
      )

    {:ok, updated} =
      definition
      |> Ecto.Changeset.change(%{definition: updated_yaml})
      |> Repo.update()

    updated
  end

  describe "probe_search/3" do
    test "reports the row count when the search returns results" do
      bypass = Bypass.open()

      Bypass.stub(bypass, "GET", "/search", fn conn ->
        Plug.Conn.resp(
          conn,
          200,
          "<html><body><table><tr><td><a href=\"/download/1\">Some Release</a></td></tr></table></body></html>"
        )
      end)

      url = "http://localhost:#{bypass.port}"

      assert {:ok, count, served_by} =
               CardigannHealthCheck.probe_search(parsed_for(url), %{}, url)

      assert count > 0
      assert served_by == url
    end

    test "reports zero rows rather than success when the search parses nothing" do
      # This is the state the reporter hit on KickassTorrents: "0 results".
      # It is not a healthy indexer and it is not an unreachable one.
      bypass = Bypass.open()

      Bypass.stub(bypass, "GET", "/search", fn conn ->
        Plug.Conn.resp(conn, 200, "<html><body><p>nothing here</p></body></html>")
      end)

      url = "http://localhost:#{bypass.port}"

      assert {:ok, 0, ^url} = CardigannHealthCheck.probe_search(parsed_for(url), %{}, url)
    end

    test "reports an error when the search 404s even though the homepage is fine" do
      # A homepage probe passes here. This is exactly the false green.
      bypass = Bypass.open()

      Bypass.stub(bypass, "GET", "/", fn conn -> Plug.Conn.resp(conn, 200, "<html/>") end)
      Bypass.stub(bypass, "GET", "/search", fn conn -> Plug.Conn.resp(conn, 404, "") end)

      url = "http://localhost:#{bypass.port}"

      assert {:error, message} = CardigannHealthCheck.probe_search(parsed_for(url), %{}, url)
      assert message =~ "404"
    end
  end

  describe "probe query selection" do
    # The definition below puts the keyword in the PATH, so the probe query is
    # observable. A definition with an empty `inputs` map and a static path
    # sends the query nowhere at all, which would make this assertion vacuous.
    defp capture_path(bypass, test_pid) do
      Bypass.stub(bypass, "GET", "/search/:term", fn conn ->
        send(test_pid, {:request_path, conn.request_path})
        Plug.Conn.resp(conn, 200, "<html><body><table><tr><td>x</td></tr></table></body></html>")
      end)
    end

    test "a movie-search indexer is probed with a film title" do
      bypass = Bypass.open()
      capture_path(bypass, self())

      url = "http://localhost:#{bypass.port}"

      parsed =
        parsed_for(url, modes: %{"movie-search" => ["q"]}, path: "/search/{{ .Keywords }}")

      assert {:ok, _, _} = CardigannHealthCheck.probe_search(parsed, %{}, url)
      assert_received {:request_path, path}
      assert path =~ "The%20Matrix"
    end

    test "a tv-search indexer is probed with a series title" do
      bypass = Bypass.open()
      capture_path(bypass, self())

      url = "http://localhost:#{bypass.port}"

      parsed = parsed_for(url, modes: %{"tv-search" => ["q"]}, path: "/search/{{ .Keywords }}")

      assert {:ok, _, _} = CardigannHealthCheck.probe_search(parsed, %{}, url)
      assert_received {:request_path, path}
      assert path =~ "Breaking%20Bad"
    end

    test "an indexer declaring neither mode falls back to a generic term" do
      bypass = Bypass.open()
      capture_path(bypass, self())

      url = "http://localhost:#{bypass.port}"
      parsed = parsed_for(url, modes: %{"search" => ["q"]}, path: "/search/{{ .Keywords }}")

      assert {:ok, _, _} = CardigannHealthCheck.probe_search(parsed, %{}, url)
      assert_received {:request_path, path}
      assert path =~ "ubuntu"
    end
  end

  describe "user config passthrough" do
    test "a user-configured setting reaches the search request instead of rendering empty" do
      # Regression: probe_search/3 originally rendered
      # config: Map.get(user_config, :config, %{}), but user_config arriving
      # here IS ALREADY the flat settings map (definition.config, see
      # perform_test_search/2), which has no nested :config key. That always
      # evaluated to %{}, so a search path or input referencing
      # {{ .Config.* }} rendered empty during the probe while rendering
      # correctly in a real search - reporting a false failure/degraded state
      # for a correctly configured indexer, the inverse of the false green
      # this task exists to remove.
      bypass = Bypass.open()
      capture_path(bypass, self())

      url = "http://localhost:#{bypass.port}"
      parsed = parsed_for(url, path: "/search/{{ .Config.apikey }}")

      assert {:ok, _, _} =
               CardigannHealthCheck.probe_search(parsed, %{"apikey" => "topsecret123"}, url)

      assert_received {:request_path, path}
      assert path =~ "topsecret123"
    end
  end

  describe "Cloudflare" do
    test "a Cloudflare challenge is reported as :cloudflare, not as a generic error" do
      # EZTV in the bug report. The operator needs to be told to configure
      # FlareSolverr, which requires distinguishing this from an ordinary
      # failure.
      bypass = Bypass.open()

      Bypass.stub(bypass, "GET", "/search", fn conn ->
        # CardigannSearchEngine.cloudflare_challenge?/1 matches on body content
        # (cf-browser-verification, "Cloudflare", etc.), not on the "server"
        # header alone, so the body needs a real indicator string to be
        # detected as a challenge rather than a bare 403.
        conn
        |> Plug.Conn.put_resp_header("server", "cloudflare")
        |> Plug.Conn.resp(
          403,
          "<html><title>Just a moment...</title><body>Checking your browser before " <>
            "accessing this site. cf-browser-verification. DDoS protection by Cloudflare." <>
            "</body></html>"
        )
      end)

      url = "http://localhost:#{bypass.port}"

      assert {:cloudflare, _message} =
               CardigannHealthCheck.probe_search(parsed_for(url), %{}, url)
    end
  end

  describe "active_link promotion" do
    test "a candidate whose homepage answers but whose search fails is not promoted" do
      # This is the YTS shape: a proxy mirror serves HTML on / and 404s on the
      # API path. Promoting it on the strength of the homepage GET is what made
      # every later search use the wrong mirror.
      definition = cardigann_definition_fixture(%{active_link: nil})

      bypass = Bypass.open()
      Bypass.stub(bypass, "GET", "/", fn conn -> Plug.Conn.resp(conn, 200, "<html/>") end)
      Bypass.stub(bypass, "GET", "/search", fn conn -> Plug.Conn.resp(conn, 404, "") end)

      {:ok, result} =
        CardigannHealthCheck.execute_health_check(
          put_link(definition, "http://localhost:#{bypass.port}")
        )

      refute result.success
      assert Mydia.Repo.reload!(definition).active_link == nil
    end

    test "the persisted active_link and message name the mirror that actually served the result" do
      # Same YTS shape as above, but with a second candidate that works: mirror
      # A's homepage answers 200 but its search 404s, so execute_search's own
      # failover (Task 5) advances past A to mirror B, which serves a real
      # row. Regression: probe_search/3 used to have no way to report that a
      # different candidate than the one it was asked to try had served the
      # response, so search_leg/6 stored and reported A - the mirror that did
      # NOT serve the result - as active_link.
      definition = cardigann_definition_fixture(%{active_link: nil})

      mirror_a = Bypass.open()
      mirror_b = Bypass.open()

      Bypass.stub(mirror_a, "GET", "/", fn conn -> Plug.Conn.resp(conn, 200, "<html/>") end)
      Bypass.stub(mirror_a, "GET", "/search", fn conn -> Plug.Conn.resp(conn, 404, "") end)

      Bypass.stub(mirror_b, "GET", "/", fn conn -> Plug.Conn.resp(conn, 200, "<html/>") end)

      Bypass.stub(mirror_b, "GET", "/search", fn conn ->
        Plug.Conn.resp(
          conn,
          200,
          ~s"""
          <html><body><table class="results">
          <tr><td class="title">Some Release</td>
          <td class="download"><a href="/download/1">grab</a></td></tr>
          </table></body></html>
          """
        )
      end)

      url_a = "http://localhost:#{mirror_a.port}"
      url_b = "http://localhost:#{mirror_b.port}"

      {:ok, result} =
        CardigannHealthCheck.execute_health_check(put_link(definition, [url_a, url_b]))

      assert result.success
      assert result.message =~ url_b
      refute result.message =~ url_a
      assert Mydia.Repo.reload!(definition).active_link == url_b
    end
  end
end
