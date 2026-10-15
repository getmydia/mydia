defmodule Mydia.Indexers.Cardigann.SearchPagesTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.SearchPages
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.SearchResult

  defp result(title, url) do
    %SearchResult{
      title: title,
      size: 1,
      seeders: 1,
      leechers: 0,
      download_url: url,
      indexer: "Test"
    }
  end

  describe "collect/7 paging deadline" do
    test "requests no later page once the deadline has passed" do
      parsed = %Parsed{id: "pages-deadline", name: "Pages Deadline"}
      parent = self()

      parse = fn _path, _response ->
        send(parent, :parsed)
        {:ok, [result("never", "https://example.test/never")]}
      end

      past = System.monotonic_time(:millisecond) - 1

      assert [] ==
               SearchPages.collect(
                 parsed,
                 [%{path: "/p2"}, %{path: "/p3"}],
                 [paging_deadline: past],
                 %{},
                 %{},
                 "http://127.0.0.1:1",
                 parse
               )

      refute_received :parsed
    end

    test "a page started near the deadline cannot outlast the time remaining" do
      # A server that accepts the connection and never answers: only the
      # request's own receive timeout can end the wait.
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listener)
      on_exit(fn -> :gen_tcp.close(listener) end)

      parsed = %Parsed{
        id: "pages-timeout",
        name: "Pages Timeout",
        links: ["http://localhost:#{port}"],
        search: %{paths: [%{path: "/p2"}], inputs: %{}}
      }

      parse = fn _path, _response -> flunk("the slow page must not be parsed") end
      deadline = System.monotonic_time(:millisecond) + 100

      {{elapsed_us, rows}, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          :timer.tc(fn ->
            SearchPages.collect(
              parsed,
              [%{path: "/p2"}],
              [paging_deadline: deadline],
              %{},
              %{},
              "http://localhost:#{port}",
              parse
            )
          end)
        end)

      assert rows == []
      # Without the cap the request waits the engine's full 30 s receive timeout.
      assert elapsed_us < 2_000_000
    end
  end

  describe "collect/7 requestDelay against the paging budget" do
    test "a later page whose throttle wait outlasts the budget is not requested" do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listener)
      on_exit(fn -> :gen_tcp.close(listener) end)

      parsed = %Parsed{
        id: "pages-delay-#{System.unique_integer([:positive])}",
        name: "Pages Delay",
        links: ["http://localhost:#{port}"],
        request_delay: 5,
        search: %{paths: [%{path: "/p2"}], inputs: %{}}
      }

      # Page 1 took the first slot; the next one is 5 s away.
      :ok = Mydia.Indexers.RateLimiter.throttle("cardigann:" <> parsed.id, 5_000)

      parse = fn _path, _response -> flunk("the throttled page must not be parsed") end
      deadline = System.monotonic_time(:millisecond) + 300

      {{elapsed_us, rows}, log} =
        ExUnit.CaptureLog.with_log(fn ->
          :timer.tc(fn ->
            SearchPages.collect(
              parsed,
              [%{path: "/p2"}],
              [paging_deadline: deadline],
              %{},
              %{},
              "http://localhost:#{port}",
              parse
            )
          end)
        end)

      assert rows == []
      assert elapsed_us < 1_000_000
      assert log =~ "requestDelay"
      # Nothing connected to the server.
      assert {:error, :timeout} = :gen_tcp.accept(listener, 0)
    end
  end

  describe "dedupe/1" do
    test "keeps every row that has no download url" do
      rows = [result("one", nil), result("two", nil), result("three", "")]

      assert SearchPages.dedupe(rows) == rows
    end

    test "still drops a repeated url and a repeated info hash" do
      a = result("a", "https://example.test/a.torrent")
      b = result("b", "magnet:?xt=urn:btih:ABC123&dn=b")

      rows = [
        a,
        b,
        result("a again", "https://example.test/a.torrent"),
        result("b again", "magnet:?xt=urn:btih:abc123")
      ]

      assert SearchPages.dedupe(rows) == [a, b]
    end
  end
end
