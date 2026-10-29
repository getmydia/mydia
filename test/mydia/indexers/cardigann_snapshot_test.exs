defmodule Mydia.Indexers.CardigannSnapshotTest do
  @moduledoc """
  Snapshot integration tests for the Cardigann engine.

  Each test loads a real YAML definition and a captured HTML/JSON response,
  parses results through the full Cardigann pipeline, and verifies output.

  These tests exercise the engine end-to-end without network access, catching
  regressions from filter, template, or selector changes.

  Run: ./dev mix test test/mydia/indexers/cardigann_snapshot_test.exs
  """
  use ExUnit.Case, async: true

  @moduletag :snapshot

  alias Mydia.Indexers.CardigannParser
  alias Mydia.Indexers.CardigannResultParser

  import Mydia.CardigannSnapshotHelper,
    only: [run_snapshot: 2, run_download_snapshot: 1, run_download_snapshot: 2]

  @fixtures_base "test/fixtures/cardigann"

  # ============================================================================
  # Helpers
  # ============================================================================

  defp load_and_parse(indexer_id, opts \\ []) do
    fixture_dir = Path.join(@fixtures_base, indexer_id)
    definition_path = Path.join(fixture_dir, "definition.yml")

    yaml_content = File.read!(definition_path)
    {:ok, definition} = CardigannParser.parse_definition(yaml_content)

    # Load response
    {body, _type} =
      cond do
        File.exists?(Path.join(fixture_dir, "response.html")) ->
          {File.read!(Path.join(fixture_dir, "response.html")), :html}

        File.exists?(Path.join(fixture_dir, "response.json")) ->
          {File.read!(Path.join(fixture_dir, "response.json")), :json}

        true ->
          raise "No response fixture in #{fixture_dir}"
      end

    # Load metadata for query context
    metadata =
      case File.read(Path.join(fixture_dir, "metadata.json")) do
        {:ok, content} -> Jason.decode!(content)
        _ -> %{}
      end

    keywords = Keyword.get(opts, :keywords, Map.get(metadata, "query", "test"))

    # Build template context
    config =
      (definition.settings || [])
      |> Enum.reduce(%{}, fn setting, acc ->
        name = setting[:name] || setting["name"]
        default = setting[:default] || setting["default"]
        if name && default, do: Map.put(acc, name, to_string(default)), else: acc
      end)

    # Add sitelink config that many definitions use
    base_url =
      case definition.links do
        [url | _] when is_binary(url) -> url
        _ -> ""
      end

    config = Map.put_new(config, "sitelink", base_url)

    template_context = %{
      keywords: keywords,
      config: config,
      categories: [],
      settings: definition.settings || [],
      query: %{}
    }

    response = %{status: 200, body: body}

    result =
      CardigannResultParser.parse_results(
        definition,
        response,
        definition.name || definition.id,
        template_context: template_context,
        base_url: base_url
      )

    {result, definition}
  end

  # ============================================================================
  # EZTV - HTML with :contains(), :has(), andmatch
  # Note: EZTV's current site loads magnet links via JavaScript, so the
  # captured static HTML doesn't contain them. The row selector requires
  # :has(a.magnet) which correctly returns 0 rows from static HTML.
  # These tests verify the definition parses and the engine handles this
  # gracefully (returning empty results rather than crashing).
  # ============================================================================

  describe "EZTV snapshot" do
    @tag :snapshot
    test "definition parses successfully" do
      {_result, definition} = load_and_parse("eztv")
      assert definition.id == "eztv"
      assert definition.name == "EZTV"
      assert definition.search.fields != nil
      assert Map.has_key?(definition.search.fields, :title)
    end

    @tag :snapshot
    test "handles missing magnet links gracefully" do
      # EZTV's current site loads magnet links via JS. The row selector
      # :has(a.magnet) correctly yields 0 rows from static HTML capture.
      {result, _def} = load_and_parse("eztv")
      assert {:ok, results} = result
      assert is_list(results)
    end

    @tag :snapshot
    test "row selector uses enhanced pseudo-selectors" do
      {_result, definition} = load_and_parse("eztv")
      selector = definition.search.rows.selector
      assert String.contains?(selector, ":contains(")
      assert String.contains?(selector, ":has(")
    end
  end

  # ============================================================================
  # YTS - JSON with sub-array expansion (rows.attribute: torrents)
  # ============================================================================

  describe "YTS snapshot" do
    @tag :snapshot
    test "parses JSON API response" do
      {result, _def} = load_and_parse("yts", keywords: "avengers")
      assert {:ok, results} = result
      assert results != [], "YTS should return results for 'avengers'"
    end

    @tag :snapshot
    test "expands torrent sub-arrays into individual results" do
      {result, _def} = load_and_parse("yts", keywords: "avengers")
      {:ok, results} = result

      # YTS movies have multiple torrents (720p, 1080p, etc.)
      # So result count should be > movie count
      assert length(results) > 10, "Expected many expanded torrent results"
    end

    @tag :snapshot
    test "includes quality in title" do
      {result, _def} = load_and_parse("yts", keywords: "avengers")
      {:ok, results} = result

      quality_results =
        Enum.filter(results, fn r ->
          r.title =~ ~r/720p|1080p|2160p|3D/
        end)

      assert quality_results != [], "Some titles should contain quality markers"
    end

    @tag :snapshot
    test "parses size as bytes" do
      {result, _def} = load_and_parse("yts", keywords: "avengers")
      {:ok, results} = result

      sized = Enum.filter(results, &(&1.size > 0))
      assert sized != [], "Some results should have parsed sizes"
    end
  end

  # ============================================================================
  # The Pirate Bay - JSON API with info_hash
  # ============================================================================

  describe "The Pirate Bay snapshot" do
    @tag :snapshot
    test "parses JSON API response" do
      {result, _def} = load_and_parse("thepiratebay")
      assert {:ok, results} = result
      assert results != [], "TPB should return results"
    end

    @tag :snapshot
    test "extracts titles" do
      {result, _def} = load_and_parse("thepiratebay")
      {:ok, results} = result

      first = hd(results)
      assert first.title != nil and first.title != ""
      assert first.indexer == "The Pirate Bay"
    end

    @tag :snapshot
    test "parses seeders and leechers" do
      {result, _def} = load_and_parse("thepiratebay")
      {:ok, results} = result

      seeded = Enum.filter(results, &(&1.seeders > 0))
      assert seeded != [], "Some TPB results should have seeders"
    end

    @tag :snapshot
    test "parses sizes" do
      {result, _def} = load_and_parse("thepiratebay")
      {:ok, results} = result

      sized = Enum.filter(results, &(&1.size > 0))
      assert sized != [], "Some TPB results should have sizes"
    end
  end

  # ============================================================================
  # TorrentGalaxy - HTML with remove selector and timeago dates
  # ============================================================================

  describe "TorrentGalaxy snapshot" do
    @tag :snapshot
    test "parses results from captured HTML" do
      {result, _def} = load_and_parse("torrentgalaxyclone")
      assert {:ok, results} = result
      assert results != [], "TorrentGalaxy should return results"
    end

    @tag :snapshot
    test "download block resolves magnet from captured details page" do
      run_download_snapshot(Path.join(@fixtures_base, "torrentgalaxyclone"))
    end

    @tag :snapshot
    test "extracts titles from title attribute" do
      {result, _def} = load_and_parse("torrentgalaxyclone")
      {:ok, results} = result

      first = hd(results)
      assert first.title != nil and first.title != ""
      assert String.length(first.title) > 3, "Title should be meaningful: #{first.title}"
    end

    @tag :snapshot
    test "extracts sizes" do
      {result, _def} = load_and_parse("torrentgalaxyclone")
      {:ok, results} = result

      sized = Enum.filter(results, &(&1.size > 0))
      assert sized != [], "Some TorrentGalaxy results should have sizes"
    end
  end

  # ============================================================================
  # LimeTorrents - HTML with regex title extraction
  # ============================================================================

  describe "LimeTorrents snapshot" do
    @tag :snapshot
    test "parses results from captured HTML" do
      {result, _def} = load_and_parse("limetorrents")
      assert {:ok, results} = result
      assert results != [], "LimeTorrents should return results"
    end

    @tag :snapshot
    test "extracts seeders and leechers" do
      {result, _def} = load_and_parse("limetorrents")
      {:ok, results} = result

      seeded = Enum.filter(results, &(&1.seeders >= 0))
      assert seeded != [], "LimeTorrents results should have seeders"
    end
  end

  # ============================================================================
  # MagnetDownload - download before + infohash
  # ============================================================================

  describe "MagnetDownload snapshot" do
    @tag :snapshot
    test "parses search results from captured HTML" do
      run_snapshot(Path.join(@fixtures_base, "magnetdownload"), min_results: 1)
    end

    @tag :snapshot
    test "infohash block resolves magnet from captured before-response body" do
      run_download_snapshot(Path.join(@fixtures_base, "magnetdownload"))
    end
  end

  # ============================================================================
  # showRSS - XML response
  # ============================================================================

  describe "showRSS snapshot" do
    @tag :snapshot
    test "parses captured XML RSS feed without error" do
      # The capture is the global feed, a keywordless request. With the
      # metadata's query the definition's `rows.filters: andmatch` would drop
      # every row (see the next test).
      {{result, _definition}, _log} =
        ExUnit.CaptureLog.with_log(fn -> load_and_parse("showrss", keywords: "") end)

      # The feed names its title element `tv:raw_title`; the definition selects
      # it as `raw_title`, as a CSS type selector matches by local name.
      assert {:ok, [_ | _] = results} = result
      assert Enum.all?(results, &(is_binary(&1.title) and &1.title != ""))
    end

    @tag :snapshot
    test "rows.filters andmatch drops feed rows without the keywords" do
      {{result, _definition}, _log} =
        ExUnit.CaptureLog.with_log(fn -> load_and_parse("showrss", keywords: "test") end)

      assert {:ok, []} = result
    end
  end

  # ============================================================================
  # BlueRoms - allowEmptyInputs
  # ============================================================================

  describe "BlueRoms snapshot" do
    @tag :snapshot
    test "definition allows empty search inputs" do
      fixture_dir = Path.join(@fixtures_base, "blueroms")

      {:ok, definition} =
        fixture_dir
        |> Path.join("definition.yml")
        |> File.read!()
        |> CardigannParser.parse_definition()

      assert definition.search[:allow_empty_inputs] == true
    end

    @tag :snapshot
    test "parses captured search HTML" do
      {result, _def} = load_and_parse("blueroms")
      assert {:ok, _results} = result
    end
  end

  # ============================================================================
  # TorrentLT - rows.after
  # ============================================================================

  describe "TorrentLT snapshot" do
    @tag :snapshot
    test "definition exercises rows.after" do
      fixture_dir = Path.join(@fixtures_base, "torrentlt")

      {:ok, definition} =
        fixture_dir
        |> Path.join("definition.yml")
        |> File.read!()
        |> CardigannParser.parse_definition()

      assert definition.search.rows[:after] == 1
    end
  end

  # ============================================================================
  # MegaPeer - windows-1251 response body
  # ============================================================================

  describe "MegaPeer snapshot" do
    @tag :snapshot
    test "megapeer: windows-1251 page parses" do
      run_snapshot(Path.join(@fixtures_base, "megapeer"),
        min_results: 2,
        assertions: fn [first | _] -> assert String.valid?(first.title) end
      )
    end
  end

  # ============================================================================
  # Definition-only tests (no response fixture - just validate parsing)
  # ============================================================================

  describe "definition parsing" do
    for indexer_id <- ~w(1337x nyaasi kickasstorrents-to) do
      @tag :snapshot
      test "#{indexer_id} definition parses successfully" do
        fixture_dir = Path.join(@fixtures_base, unquote(indexer_id))
        definition_path = Path.join(fixture_dir, "definition.yml")

        if File.exists?(definition_path) do
          yaml_content = File.read!(definition_path)
          assert {:ok, definition} = CardigannParser.parse_definition(yaml_content)
          assert definition.id == unquote(indexer_id)
          assert definition.name != nil
          assert definition.search.fields != nil
          assert Map.has_key?(definition.search.fields, :title)
        end
      end
    end
  end

  describe "CrackingPatching snapshot" do
    @tag :snapshot
    # The definition declares `rows.filters: andmatch`, and no row title in the
    # capture contains its query ("ubuntu"), so Prowlarr keeps none of them.
    # Row parsing is exercised as a keywordless request instead.
    test "crackingpatching: search rows parse" do
      run_snapshot("test/fixtures/cardigann/crackingpatching", min_results: 2, keywords: "")
    end

    @tag :snapshot
    test "crackingpatching: rows.filters andmatch drops rows without the keywords" do
      {{result, _definition}, _log} =
        ExUnit.CaptureLog.with_log(fn ->
          load_and_parse("crackingpatching", keywords: "ubuntu")
        end)

      assert {:ok, []} = result
    end

    # The magnet in download_response.html is synthetic. This only proves that the
    # magnet selector resolves on a details page shaped like the site's. The live
    # crackingpatching page currently carries no magnet (known site drift, its
    # definition's selector cannot match), so this does not cover the live grab.
    @tag :snapshot
    test "crackingpatching: magnet selector resolves on a details page with a synthetic magnet" do
      run_download_snapshot("test/fixtures/cardigann/crackingpatching", expect: :magnet)
    end
  end

  describe "InternetArchive snapshot" do
    @tag :snapshot
    test "internetarchive: JSON text fields render .Result values" do
      run_snapshot("test/fixtures/cardigann/internetarchive",
        min_results: 2,
        assertions: fn [first, second | _] ->
          # With the infohash rendered, the magnet is preferred over the .torrent path.
          assert first.download_url =~ "magnet:?xt=urn:btih:" <> String.duplicate("1", 40)
          assert second.download_url =~ "magnet:?xt=urn:btih:" <> String.duplicate("2", 40)
          assert first.info_url =~ "/details/copper-lantern-1931"
        end
      )
    end

    @tag :snapshot
    test "internetarchive: noMagnet builds the .torrent URL from .Result values" do
      run_snapshot("test/fixtures/cardigann/internetarchive",
        min_results: 2,
        template_context: %{
          keywords: "Copper Lantern",
          config: %{"noMagnet" => true, "titleOnly" => true},
          categories: [],
          settings: [],
          query: %{}
        },
        assertions: fn [first | _] ->
          assert first.download_url =~
                   "/download/copper-lantern-1931/copper-lantern-1931_archive.torrent"
        end
      )
    end
  end

  describe "XML bare attribute selectors" do
    @tag :snapshot
    test "nekobt: torznab attributes parse" do
      run_snapshot("test/fixtures/cardigann/nekobt",
        min_results: 2,
        assertions: fn [first, second | _] ->
          assert first.seeders == 12
          assert second.seeders == 7
          assert first.leechers == 3
        end
      )
    end
  end

  # These trackers returned zero or wrong rows while the HTML path ran on Floki,
  # which builds no implied <tbody>, mis-evaluates nested :has()/:not(:has()) and
  # has no :scope. Each fixture is a reduction of a live capture.
  describe "HTML5 tree and modern CSS" do
    # Rows match for the skipped id too; the remaining cause is outside the
    # selector engine:
    # - ebookbay: the live page puts the title in div.poststuff and the download
    #   link in the sibling div.entry, but each row selector alternative matches only
    #   one of them, so no row has both (definition/site drift).
    @skipped %{
      "ebookbay" => "title and download live in sibling elements; definition drift"
    }

    for id <-
          ~w(acgrip torrentkitty rutor byrutor torrentdownloads torrentproject2 world-torrent ebookbay) do
      @id id
      if reason = @skipped[id], do: @tag(skip: reason)

      test "#{id} yields rows with a title and a download" do
        run_snapshot("test/fixtures/cardigann/#{@id}",
          min_results: 2,
          assertions: fn results ->
            for r <- results do
              assert r.title != ""
              assert is_binary(r.download_url) and r.download_url != ""
            end
          end
        )
      end
    end
  end
end
