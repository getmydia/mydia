defmodule Mydia.Indexers.Cardigann.LiveCheckTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.LiveCheck

  describe "safe_dirname/1" do
    test "keeps ordinary ids" do
      assert LiveCheck.safe_dirname("my-tracker_2.v1") == "my-tracker_2.v1"
    end

    test "neutralises path separators and traversal" do
      refute LiveCheck.safe_dirname("../../etc/passwd") =~ "/"
      assert LiveCheck.safe_dirname("a/b\\c") == "a_b_c"
    end

    test "never returns a dot-only name" do
      for id <- ["", ".", "..", "..."] do
        refute LiveCheck.safe_dirname(id) in ["", ".", ".."]
      end
    end
  end

  describe "classify/1" do
    test "rows on the probe query and a magnet grab is ok" do
      assert LiveCheck.classify(%{
               search: {:ok, 3, 0, 0},
               empty: nil,
               grab: {:magnet, "magnet:?xt=urn:btih:1"}
             }) == :ok
    end

    test "rows only on the empty query is ok_empty_query" do
      assert LiveCheck.classify(%{
               search: {:ok, 0, 0, 0},
               empty: {:ok, 5, 0, 0},
               grab: {:torrent, 512}
             }) ==
               :ok_empty_query
    end

    test "rows with a failed grab is grab_failed" do
      assert LiveCheck.classify(%{
               search: {:ok, 3, 0, 0},
               empty: nil,
               grab: {:error, "no selector"}
             }) ==
               :grab_failed
    end

    test "zero rows on both queries is no_rows" do
      assert LiveCheck.classify(%{search: {:ok, 0, 0, 0}, empty: {:ok, 0, 0, 0}, grab: nil}) ==
               :no_rows
    end

    test "matched rows that were all dropped is rows_dropped" do
      assert LiveCheck.classify(%{search: {:ok, 0, 4, 0}, empty: {:ok, 0, 0, 0}, grab: nil}) ==
               :rows_dropped
    end

    test "drops alongside andmatch filtering is no_rows, not rows_dropped" do
      assert LiveCheck.classify(%{search: {:ok, 0, 1, 19}, empty: {:ok, 0, 0, 0}, grab: nil}) ==
               :no_rows
    end

    test "a cloudflare probe is cloudflare" do
      assert LiveCheck.classify(%{search: {:cloudflare, "x"}, empty: nil, grab: nil}) ==
               :cloudflare
    end

    test "error messages map to buckets" do
      cases = [
        {"Search path failed to render: \"parse error at line 1, offset 8\"", :template_error},
        {"Failed to parse HTML response: %ArgumentError{}", :parse_error},
        {"Failed to parse XML response: x", :parse_error},
        {"Failed to parse unknown response from Quiet Orchard: %RuntimeError{}", :parse_error},
        {"XML parse error: {:fatal, {:expected_element_start_tag}}", :parse_error},
        {"Failed to compile the Quiet Orchard definition: bad case value",
         :unsupported_definition},
        {"Invalid selector in the Quiet Orchard definition: invalid selector",
         :unsupported_definition},
        {"HTTP 400", :http_4xx},
        {"Request failed: {:invalid_request_target, \"/a b\"}", :http_4xx},
        {"Blocked page: 🚫 This Website is Blocked 🚫", :blocked_page},
        {"HTTP 404", :unreachable},
        {"Connection failed: :nxdomain", :unreachable},
        {"Request timeout", :unreachable}
      ]

      for {message, bucket} <- cases do
        assert LiveCheck.classify(%{search: {:error, message}, empty: nil, grab: nil}) == bucket,
               "expected #{inspect(message)} to classify as #{bucket}"
      end
    end
  end

  describe "check/2" do
    setup do
      bypass = Bypass.open()
      base = "http://localhost:#{bypass.port}"

      yaml = """
      ---
      id: livecheck-fixture
      name: LiveCheck Fixture
      description: fixture
      language: en-US
      type: public
      encoding: UTF-8
      links:
        - #{base}/
      caps:
        categories:
          1: Movies
        modes:
          search: [q]
      search:
        paths:
          - path: /search
        inputs:
          q: "{{ .Keywords }}"
        rows:
          selector: table.results tr
        fields:
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

      Bypass.stub(bypass, "GET", "/", fn conn -> Plug.Conn.resp(conn, 200, "<html></html>") end)
      %{bypass: bypass, yaml: yaml}
    end

    test "a searchable definition with a torrent download is ok", %{bypass: bypass, yaml: yaml} do
      Bypass.stub(bypass, "GET", "/search", fn conn ->
        Plug.Conn.resp(conn, 200, """
        <html><body><table class="results">
        <tr><td class="title">Copper Lantern S01E02</td><td class="download"><a href="/dl/1.torrent">get</a></td></tr>
        </table></body></html>
        """)
      end)

      Bypass.stub(bypass, "GET", "/dl/1.torrent", fn conn ->
        Plug.Conn.resp(conn, 200, "d8:announce3:url4:infod4:name4:testee")
      end)

      outcome = LiveCheck.check(yaml)
      assert outcome.bucket == :ok
      assert outcome.rows == 1
    end

    test "a download link with a non-http scheme is not fetched", %{bypass: bypass, yaml: yaml} do
      Bypass.stub(bypass, "GET", "/search", fn conn ->
        Plug.Conn.resp(conn, 200, """
        <html><body><table class="results">
        <tr><td class="title">Copper Lantern S01E02</td><td class="download"><a href="ftp://files.invalid/1.torrent">get</a></td></tr>
        </table></body></html>
        """)
      end)

      outcome = LiveCheck.check(yaml)
      assert outcome.bucket == :grab_failed
      assert outcome.grab =~ "unsupported scheme"
    end

    test "rows matched without a download link is rows_dropped", %{bypass: bypass, yaml: yaml} do
      Bypass.stub(bypass, "GET", "/search", fn conn ->
        Plug.Conn.resp(conn, 200, """
        <table class="results">
        <tr><td class="title">Copper Lantern S01E02</td></tr>
        <tr><td class="title">Paper Harbor 2031</td></tr>
        </table>
        """)
      end)

      {outcome, _log} = ExUnit.CaptureLog.with_log(fn -> LiveCheck.check(yaml) end)
      assert outcome.bucket == :rows_dropped
      assert outcome.rows == 0
      assert outcome.dropped == 2
    end

    test "rows only on the empty query is ok_empty_query", %{bypass: bypass, yaml: yaml} do
      Bypass.stub(bypass, "GET", "/search", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        body =
          if conn.query_params["q"] in [nil, ""] do
            ~s(<table class="results"><tr><td class="title">Paper Harbor 2031</td><td class="download"><a href="magnet:?xt=urn:btih:1111111111111111111111111111111111111111">m</a></td></tr></table>)
          else
            ~s(<table class="results"></table>)
          end

        Plug.Conn.resp(conn, 200, body)
      end)

      outcome = LiveCheck.check(yaml)
      assert outcome.bucket == :ok_empty_query
      assert outcome.rows == 0
      assert outcome.rows_empty_query == 1
    end
  end
end
