defmodule Mydia.Indexers.Cardigann.Wasm.EngineTest do
  # Runs the real guest under Wasmex against Bypass. Expectations come from
  # native/cardigann_guest/tests/CardigannGuest.Tests/FixtureTests.cs, which runs
  # the same fixtures through the same upstream code on plain .NET.
  use ExUnit.Case, async: false

  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.Cardigann.Wasm.{Artifact, Engine}

  @moduletag :cardigann_wasm
  @moduletag timeout: 120_000
  @fixtures Path.expand("../../../../support/fixtures/cardigann_wasm", __DIR__)
  @empty %{cookies: %{}, expires_at: nil}
  @call_timeout 30_000

  setup do
    :ok = Engine.ensure_started()

    # The application starts the engine only under CARDIGANN_ENGINE=prowlarr.
    on_exit(fn ->
      Supervisor.terminate_child(Mydia.Supervisor, Engine)
      Supervisor.delete_child(Mydia.Supervisor, Engine)
    end)

    unless Engine.available?() do
      flunk(
        "cardigann.wasm unavailable (#{inspect(Artifact.load())}): " <>
          "run mix mydia.cardigann_guest fetch or native/cardigann_guest/build.sh wasm"
      )
    end

    bypass = Bypass.open()

    ctx = %{
      definition_id: "t#{System.unique_integer([:positive])}",
      request_delay_ms: 0,
      flaresolverr: nil,
      gate_opts: [allow_private_except_link_local: true]
    }

    {:ok, bypass: bypass, ctx: ctx}
  end

  defp yaml(name, bypass) do
    @fixtures
    |> Path.join(name)
    |> File.read!()
    |> String.replace(~r{https://[a-z]+\.invalid/}, "http://localhost:#{bypass.port}/")
  end

  defp body(name), do: File.read!(Path.join(@fixtures, name))

  # A response body that names the invented host, pointed at Bypass.
  defp body(name, bypass),
    do:
      String.replace(body(name), ~r{https://[a-z]+\.invalid/}, "http://localhost:#{bypass.port}/")

  defp q(term, kind \\ :search),
    do: %{
      kind: kind,
      term: term,
      categories: [],
      imdb_id: nil,
      tmdb_id: nil,
      tvdb_id: nil,
      season: nil,
      episode: nil,
      limit: nil,
      offset: nil
    }

  defp search(name, bypass, ctx, term \\ "x", settings \\ %{}, session \\ @empty),
    do: Engine.call({:search, yaml(name, bypass), settings, q(term), session}, ctx, @call_timeout)

  defp respond(bypass, method, path, status, resp_body, headers \\ []) do
    Bypass.stub(bypass, method, path, fn conn ->
      conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_resp_header(c, k, v) end)
      Plug.Conn.resp(conn, status, resp_body)
    end)
  end

  describe "search" do
    test "html rows", %{bypass: b, ctx: ctx} do
      respond(b, "GET", "/search", 200, body("lantern-search.html"))
      ctx = Map.put(ctx, :indexer_name, "Lantern")

      assert {:ok, %{releases: [first, second]}} = search("lantern-public.yml", b, ctx, "harbor")

      assert %SearchResult{
               title: "Paper Harbor 2031 1080p WEB-DL x264",
               size: 1_610_612_736,
               seeders: 42,
               leechers: 3,
               indexer: "Lantern",
               category: 2000,
               published_at: ~U[2031-04-02 00:00:00Z]
             } = first

      assert first.download_url == "http://localhost:#{b.port}/dl/101.torrent"

      assert %{
               title: "Glass Orchard S02E05 720p HDTV x264",
               seeders: 7,
               published_at: ~U[2031-04-01 00:00:00Z]
             } = second
    end

    test "json response", %{bypass: b, ctx: ctx} do
      respond(b, "GET", "/api/search", 200, body("ember-search.json"), [
        {"content-type", "application/json"}
      ])

      assert {:ok, %{releases: [release]}} = search("ember-json.yml", b, ctx, "meadow")

      assert %SearchResult{
               title: "Tin Meadow 2032 1080p BluRay x265",
               size: 2_147_483_648,
               seeders: 11,
               leechers: 3
             } = release

      assert release.download_url == "http://localhost:#{b.port}/dl/9.torrent"
    end

    test "xml response", %{bypass: b, ctx: ctx} do
      respond(b, "GET", "/feed.xml", 200, body("slate-search.xml", b), [
        {"content-type", "application/xml"}
      ])

      assert {:ok, %{releases: [first, second]}} = search("slate-xml.yml", b, ctx, "salt")

      assert %{
               title: "Salt Meridian 2033 720p WEB-DL x264",
               size: 1_073_741_824,
               seeders: 25,
               leechers: 4
             } = first

      assert first.download_url == "http://localhost:#{b.port}/dl/31.torrent"
      assert second.title == "Hollow Pines S01E02 1080p WEB-DL x264"
    end

    test "every search path is requested", %{bypass: b, ctx: ctx} do
      respond(b, "GET", "/movies", 200, body("fern-movies.html"))
      respond(b, "GET", "/shows", 200, body("fern-shows.html"))

      assert {:ok, %{releases: releases}} = search("fern-paged.yml", b, ctx)

      assert Enum.map(releases, & &1.title) == [
               "Reed Lighthouse 2034 1080p BluRay x264",
               "Quartz Valley S03E01 720p HDTV x264"
             ]
    end

    test "keywordsfilters rewrite the query before it is sent", %{bypass: b, ctx: ctx} do
      test_pid = self()

      Bypass.stub(b, "GET", "/search", fn conn ->
        send(test_pid, {:query, conn.query_string})
        Plug.Conn.resp(conn, 200, "<html></html>")
      end)

      assert {:ok, %{releases: []}} =
               search("birch-keywordsfilters.yml", b, ctx, "Cedar's Edge: Part Two!")

      assert_received {:query, "q=cedars+edge+part+two"}
    end

    test "regex filters have .NET semantics", %{bypass: b, ctx: ctx} do
      # A balancing group (nested parentheses) and a lookbehind with a named
      # group. PCRE rejects the former, so this proves the .NET regex engine.
      respond(b, "GET", "/search", 200, body("alder-search.html"))

      assert {:ok, %{releases: [release]}} = search("alder-dotnet-regex.yml", b, ctx, "birch")

      assert release.title == "Birch Hollow 1080p BluRay x264"
      assert release.size == 2_684_354_560
    end

    test "a header the server repeats is read as one value", %{bypass: b, ctx: ctx} do
      # The guest's Cloudflare detection reads Vary on every response from a
      # Cloudflare or DDoS-Guard server and used to throw on a second Vary.
      Bypass.stub(b, "GET", "/search", fn conn ->
        conn
        |> Plug.Conn.prepend_resp_headers([
          {"server", "cloudflare"},
          {"vary", "Accept-Encoding"},
          {"vary", "Cookie"}
        ])
        |> Plug.Conn.resp(200, body("lantern-search.html"))
      end)

      assert {:ok, %{releases: [_, _]}} = search("lantern-public.yml", b, ctx, "harbor")
    end

    test "a windows-1251 tracker is read in that encoding", %{bypass: b, ctx: ctx} do
      # Erlang has no windows-1251 codec: "Привет Мир" spelled out in that code page.
      # (The query is ASCII: Bypass's router rejects the percent-encoded
      # windows-1251 bytes of a Cyrillic term as invalid UTF-8. The .NET fixture
      # test covers the encoded query.)
      cp1251 = <<0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2, 0x20, 0xCC, 0xE8, 0xF0>>

      respond(
        b,
        "GET",
        "/search",
        200,
        String.replace(body("willow-search.html"), "Привет Мир", cp1251)
      )

      assert {:ok, %{releases: [release]}} = search("willow-1251.yml", b, ctx, "x")

      assert release.title == "Привет Мир 2031 1080p WEB-DL x264"
    end

    test "a definition with a byte order mark loads", %{bypass: b, ctx: ctx} do
      respond(b, "GET", "/search", 200, body("lantern-search.html"))
      yaml = "﻿" <> yaml("lantern-public.yml", b)

      assert {:ok, %{releases: [_, _]}} =
               Engine.call({:search, yaml, %{}, q("harbor"), @empty}, ctx, @call_timeout)
    end

    test "a stored session skips login", %{bypass: b, ctx: ctx} do
      test_pid = self()

      # Only /search is stubbed: a request to /login.php fails the test.
      Bypass.expect(b, "GET", "/search", fn conn ->
        send(test_pid, {:cookie, Plug.Conn.get_req_header(conn, "cookie")})
        Plug.Conn.resp(conn, 200, body("quill-search.html"))
      end)

      session = %{
        cookies: %{"sid" => "abc123"},
        expires_at: DateTime.add(DateTime.utc_now(), 86_400)
      }

      settings = %{"username" => "reader", "password" => "secret"}

      assert {:ok, %{releases: [release]}} =
               search("quill-login.yml", b, ctx, "copper", settings, session)

      assert release.title == "Copper Lantern Society 2030 2160p WEB-DL"
      assert_received {:cookie, [cookie]}
      assert cookie =~ "sid=abc123"
    end
  end

  describe "login" do
    test "a captcha round trip", %{bypass: b, ctx: ctx} do
      test_pid = self()
      yaml = yaml("quill-captcha.yml", b)
      settings = %{"username" => "reader", "password" => "secret"}

      Bypass.expect(b, "GET", "/login.php", fn conn ->
        send(test_pid, :login_page)

        conn
        |> Plug.Conn.put_resp_header("set-cookie", "sid=pre1; Path=/")
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.resp(200, body("quill-captcha-page.html"))
      end)

      Bypass.expect(b, "GET", "/captcha.png", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "image/png")
        |> Plug.Conn.resp(200, <<1, 2, 3>>)
      end)

      Bypass.expect(b, "POST", "/takelogin.php", fn conn ->
        {:ok, form, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:post, form, Plug.Conn.get_req_header(conn, "cookie")})

        conn
        |> Plug.Conn.put_resp_header("set-cookie", "sid=post2; Path=/")
        |> Plug.Conn.put_resp_content_type("text/html")
        |> Plug.Conn.resp(200, ~s(<a href="logout.php">logout</a>))
      end)

      assert {:ok, {:captcha, %{image: <<1, 2, 3>>, content_type: "image/png", state: state}}} =
               Engine.call({:login, yaml, settings, @empty, nil}, ctx, @call_timeout)

      assert_received :login_page

      answer = %{answer: "7KQ2", state: state}

      assert {:ok, {:ok, %{cookies: %{"sid" => "post2"}}}} =
               Engine.call(
                 {:login, yaml, settings, %{cookies: %{"sid" => "pre1"}, expires_at: nil},
                  answer},
                 ctx,
                 @call_timeout
               )

      assert_received {:post, form, [cookie]}
      assert form =~ "captcha=7KQ2"
      assert form =~ "token=t0k"
      assert cookie =~ "sid=pre1"
      # The answering call does not refetch the login page.
      refute_received :login_page
    end

    test "a wrong password is an authentication failure", %{bypass: b, ctx: ctx} do
      respond(b, "GET", "/login.php", 200, body("quill-login-page.html"))
      respond(b, "POST", "/takelogin.php", 200, ~s(<div class="error">Bad password</div>))
      settings = %{"username" => "reader", "password" => "wrong"}

      assert {:error, %{type: :authentication_failed, message: message}} =
               Engine.call(
                 {:login, yaml("quill-login.yml", b), settings, @empty, nil},
                 ctx,
                 @call_timeout
               )

      assert message =~ "Bad password"
    end
  end

  describe "download" do
    @torrent "d4:infod6:lengthi5e4:name1:a12:piece lengthi16384e6:pieces20:AAAAAAAAAAAAAAAAAAAAee"

    test "a torrent comes back as bytes", %{bypass: b, ctx: ctx} do
      respond(b, "GET", "/dl/101.torrent", 200, @torrent, [
        {"content-type", "application/x-bittorrent"}
      ])

      link = "http://localhost:#{b.port}/dl/101.torrent"

      assert {:ok, %{payload: {:bytes, @torrent}}} =
               Engine.call(
                 {:download, yaml("lantern-public.yml", b), %{}, link, @empty},
                 ctx,
                 @call_timeout
               )
    end

    test "a redirect to a magnet comes back as a link", %{bypass: b, ctx: ctx} do
      magnet = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Paper+Harbor"
      respond(b, "GET", "/dl/101.torrent", 302, "", [{"location", magnet}])
      link = "http://localhost:#{b.port}/dl/101.torrent"

      assert {:ok, %{payload: {:link, ^magnet}}} =
               Engine.call(
                 {:download, yaml("lantern-public.yml", b), %{}, link, @empty},
                 ctx,
                 @call_timeout
               )
    end

    test "download.before is requested ahead of the download", %{bypass: b, ctx: ctx} do
      test_pid = self()

      Bypass.expect_once(b, "GET", "/before", fn conn ->
        send(test_pid, {:hit, "/before"})
        Plug.Conn.resp(conn, 200, "ok")
      end)

      Bypass.expect_once(b, "GET", "/dl/1.torrent", fn conn ->
        send(test_pid, {:hit, "/dl/1.torrent"})
        Plug.Conn.resp(conn, 200, @torrent)
      end)

      link = "http://localhost:#{b.port}/dl/1.torrent"

      assert {:ok, %{payload: {:bytes, @torrent}}} =
               Engine.call(
                 {:download, yaml("moss-download-before.yml", b), %{}, link, @empty},
                 ctx,
                 @call_timeout
               )

      assert_received {:hit, first}
      assert_received {:hit, second}
      assert [first, second] == ["/before", "/dl/1.torrent"]
    end
  end

  describe "capabilities and test" do
    test "capabilities decode as JSON", %{bypass: b, ctx: ctx} do
      assert {:ok, %{"SearchAvailable" => true, "Categories" => categories}} =
               Engine.call({:capabilities, yaml("lantern-public.yml", b)}, ctx, @call_timeout)

      assert %{"Id" => 2000, "Name" => "Movies"} in Enum.map(
               categories,
               &Map.take(&1, ["Id", "Name"])
             )
    end
  end

  describe "failure" do
    test "a guest that never answers is killed at the timeout", %{bypass: b, ctx: ctx} do
      Bypass.stub(b, "GET", "/search", fn conn ->
        Process.sleep(2_000)
        Plug.Conn.resp(conn, 200, "")
      end)

      started = System.monotonic_time(:millisecond)

      assert {:error, %{type: :timeout}} =
               Engine.call(
                 {:search, yaml("lantern-public.yml", b), %{}, q("x"), @empty},
                 ctx,
                 500
               )

      assert System.monotonic_time(:millisecond) - started < 1_800
    end

    test "a response that cannot be read yields no releases, as upstream does", %{
      bypass: b,
      ctx: ctx
    } do
      # Upstream logs a parse failure during search and returns an empty page;
      # the plain .NET run of the same fixture (FixtureTests.cs) agrees.
      respond(b, "GET", "/api/search", 200, "{not json", [{"content-type", "application/json"}])

      assert {:ok, %{releases: []}} = search("ember-json.yml", b, ctx)
    end

    test "a downloaded HTML page is a network error, not a torrent", %{bypass: b, ctx: ctx} do
      respond(b, "GET", "/dl/1.torrent", 200, "<html>login</html>", [
        {"content-type", "text/html"}
      ])

      link = "http://localhost:#{b.port}/dl/1.torrent"

      assert {:error, %{type: :network_error, message: message}} =
               Engine.call(
                 {:download, yaml("lantern-public.yml", b), %{}, link, @empty},
                 ctx,
                 @call_timeout
               )

      assert message =~ "html content"
    end

    for {label, bencode} <- [
          {"without pieces", "d4:infod6:lengthi5e4:name1:a12:piece lengthi16384eee"},
          {"with a pieces length that is not a multiple of 20",
           "d4:infod6:lengthi5e4:name1:a12:piece lengthi16384e6:pieces19:AAAAAAAAAAAAAAAAAAAee"}
        ] do
      test "a torrent #{label} is a parse error", %{bypass: b, ctx: ctx} do
        respond(b, "GET", "/dl/1.torrent", 200, unquote(bencode), [
          {"content-type", "application/x-bittorrent"}
        ])

        link = "http://localhost:#{b.port}/dl/1.torrent"

        assert {:error, %{type: :parse_error}} =
                 Engine.call(
                   {:download, yaml("lantern-public.yml", b), %{}, link, @empty},
                   ctx,
                   @call_timeout
                 )
      end
    end

    test "a downloaded body that is not a torrent is a parse error", %{bypass: b, ctx: ctx} do
      respond(b, "GET", "/dl/1.torrent", 200, "not a torrent", [
        {"content-type", "application/x-bittorrent"}
      ])

      link = "http://localhost:#{b.port}/dl/1.torrent"

      assert {:error, %{type: :parse_error, message: message}} =
               Engine.call(
                 {:download, yaml("lantern-public.yml", b), %{}, link, @empty},
                 ctx,
                 @call_timeout
               )

      assert message =~ "Invalid torrent file contents"
    end

    test "malformed YAML is an error, not a crash", %{ctx: ctx} do
      assert {:error, %{type: type}} =
               Engine.call(
                 {:search, "id: [unterminated", %{}, q("x"), @empty},
                 ctx,
                 @call_timeout
               )

      assert type in [:parse_error, :engine_error]
    end
  end

  # Task 6 proved only `connect` through a real guest call. These push each
  # `http-error` case across the boundary and read what the guest reports.
  describe "host http errors" do
    # A failed exchange during `search` is swallowed by upstream, which logs it
    # and returns an empty page (the plain .NET run does the same), so these go
    # through `download`, where upstream lets the failure out.
    defp download(ctx, bypass, link),
      do:
        Engine.call(
          {:download, yaml("lantern-public.yml", bypass), %{}, link, @empty},
          ctx,
          @call_timeout
        )

    test "connect: nothing is listening", %{bypass: b, ctx: ctx} do
      link = "http://localhost:#{b.port}/dl/1.torrent"
      Bypass.down(b)

      assert {:error, %{type: :connection_failed, message: message}} = download(ctx, b, link)
      assert message =~ "connect:"
    end

    test "blocked: the SSRF gate refuses a link-local address", %{bypass: b, ctx: ctx} do
      assert {:error, %{type: :network_error, message: message, details: %{kind: :blocked}}} =
               download(ctx, b, "http://169.254.169.254/dl/1.torrent")

      assert message =~ "blocked:"
    end

    test "timeout: the host request outlasts its own deadline", %{bypass: b, ctx: ctx} do
      previous = Application.fetch_env(:mydia, :cardigann_http_timeout_ms)
      Application.put_env(:mydia, :cardigann_http_timeout_ms, 200)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:mydia, :cardigann_http_timeout_ms, value)
          :error -> Application.delete_env(:mydia, :cardigann_http_timeout_ms)
        end
      end)

      # A listener that accepts connections and never answers. (A Bypass handler
      # that sleeps is killed with the closed socket and fails the test.)
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(listener)
      on_exit(fn -> :gen_tcp.close(listener) end)

      assert {:error, %{type: :timeout, message: message}} =
               download(ctx, b, "http://localhost:#{port}/dl/1.torrent")

      assert message =~ "timeout:"
    end

    test "other: a response past the size cap", %{bypass: b, ctx: ctx} do
      respond(b, "GET", "/dl/1.torrent", 200, "d4:infod4:name1:aee")
      ctx = Map.update!(ctx, :gate_opts, &Keyword.put(&1, :max_bytes, 10))

      assert {:error, %{type: :network_error, message: message, details: %{kind: :other}}} =
               download(ctx, b, "http://localhost:#{b.port}/dl/1.torrent")

      assert message =~ "exceeded"
    end
  end

  describe "process isolation" do
    # An instance's memory stays resident while the process that created the
    # store and instance is alive (the resources hang off its heap), so the
    # guest work runs in a process that ends with the call.
    test "the guest work runs in a short-lived process, not the caller", %{bypass: b, ctx: ctx} do
      test_pid = self()
      Application.put_env(:mydia, :cardigann_wasm_guest_probe, &send(test_pid, {:guest, &1}))
      on_exit(fn -> Application.delete_env(:mydia, :cardigann_wasm_guest_probe) end)

      assert {:ok, _} =
               Engine.call({:capabilities, yaml("lantern-public.yml", b)}, ctx, @call_timeout)

      assert_receive {:guest, guest}
      assert guest != self()
      refute Process.alive?(guest)
    end

    test "respects the calling process's $callers in the guest process", %{bypass: b, ctx: ctx} do
      test_pid = self()

      Application.put_env(:mydia, :cardigann_wasm_guest_probe, fn _ ->
        send(test_pid, {:callers, Process.get(:"$callers")})
      end)

      on_exit(fn -> Application.delete_env(:mydia, :cardigann_wasm_guest_probe) end)

      assert {:ok, _} =
               Engine.call({:capabilities, yaml("lantern-public.yml", b)}, ctx, @call_timeout)

      assert_receive {:callers, callers}
      assert self() in callers
    end
  end

  describe "telemetry" do
    test "every call emits duration and network time", %{bypass: b, ctx: ctx} do
      respond(b, "GET", "/search", 200, body("lantern-search.html"))
      id = "t7-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        id,
        [:mydia, :cardigann, :wasm, :call],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      assert {:ok, _} = search("lantern-public.yml", b, ctx)

      assert_receive {:telemetry, %{duration: duration, network: network, queue: queue},
                      %{export: :search, outcome: :ok}}

      assert queue == 0
      assert network > 0
      assert duration >= network
    end

    test "a call that waits out its timeout for a slot times out and reports the queue time",
         %{ctx: ctx} do
      alias Mydia.Indexers.Cardigann.Wasm.Slots

      # The application may already run the server (max 2); hold every slot.
      unless GenServer.whereis(Slots), do: start_supervised!({Slots, max: 2})
      max = :sys.get_state(Slots).max
      test_pid = self()

      holders =
        for _ <- 1..max do
          spawn_link(fn ->
            Slots.run(5_000, fn ->
              send(test_pid, :held)
              receive do: (:release -> :ok)
            end)
          end)
        end

      for _ <- 1..max, do: assert_receive(:held)
      id = "t7q-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        id,
        [:mydia, :cardigann, :wasm, :call],
        fn _event, measurements, metadata, _ ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)

      assert {:error, %{type: :timeout}} = Engine.call({:capabilities, "id: x"}, ctx, 200)

      assert_receive {:telemetry, %{queue: queue}, %{outcome: :timeout}}
      assert System.convert_time_unit(queue, :native, :millisecond) > 0
      Enum.each(holders, &send(&1, :release))
    end
  end
end
