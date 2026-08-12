defmodule Mydia.Indexers.CardigannResultParserTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.CardigannResultParser
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.SearchResult

  describe "parse_results/3 with HTML" do
    test "parses simple HTML table results" do
      definition = %Parsed{
        id: "test",
        name: "Test Indexer",
        search: %{
          rows: %{
            selector: "table.results tbody tr"
          },
          fields: %{
            "title" => %{selector: "td.title a"},
            "download" => %{selector: "td.download a", attribute: "href"},
            "size" => %{selector: "td.size"},
            "seeders" => %{selector: "td.seeders"},
            "leechers" => %{selector: "td.leechers"}
          }
        }
      }

      html_body = """
      <html>
        <body>
          <table class="results">
            <tbody>
              <tr>
                <td class="title"><a>Ubuntu 22.04 LTS 1080p</a></td>
                <td class="size">4.5 GB</td>
                <td class="seeders">100</td>
                <td class="leechers">50</td>
                <td class="download"><a href="magnet:?xt=urn:btih:abc123">Download</a></td>
              </tr>
              <tr>
                <td class="title"><a>Debian 12 ISO</a></td>
                <td class="size">650 MB</td>
                <td class="seeders">200</td>
                <td class="leechers">25</td>
                <td class="download"><a href="magnet:?xt=urn:btih:def456">Download</a></td>
              </tr>
            </tbody>
          </table>
        </body>
      </html>
      """

      response = %{status: 200, body: html_body}

      assert {:ok, results} = CardigannResultParser.parse_results(definition, response, "Test")
      assert length(results) == 2

      [result1, result2] = results

      assert %SearchResult{} = result1
      assert result1.title == "Ubuntu 22.04 LTS 1080p"
      assert result1.size == 4_831_838_208
      assert result1.seeders == 100
      assert result1.leechers == 50
      assert result1.download_url == "magnet:?xt=urn:btih:abc123"
      assert result1.indexer == "Test"

      assert result2.title == "Debian 12 ISO"
      assert result2.size == 681_574_400
      assert result2.seeders == 200
      assert result2.leechers == 25
    end

    test "skips header rows with 'after' configuration" do
      definition = %Parsed{
        id: "test",
        name: "Test Indexer",
        search: %{
          rows: %{
            selector: "table tr",
            after: 1
          },
          fields: %{
            "title" => %{selector: "td:nth-child(1)"},
            "download" => %{selector: "td:nth-child(2)", attribute: "data-url"},
            "size" => %{selector: "td:nth-child(3)"},
            "seeders" => %{selector: "td:nth-child(4)"},
            "leechers" => %{selector: "td:nth-child(5)"}
          }
        }
      }

      html_body = """
      <table>
        <tr>
          <th>Title</th><th>Download</th><th>Size</th><th>Seeders</th><th>Leechers</th>
        </tr>
        <tr>
          <td>Test Release</td>
          <td data-url="magnet:?xt=urn:btih:test">Link</td>
          <td>1.5 GB</td>
          <td>10</td>
          <td>5</td>
        </tr>
      </table>
      """

      response = %{status: 200, body: html_body}

      assert {:ok, results} = CardigannResultParser.parse_results(definition, response, "Test")
      assert length(results) == 1
      assert hd(results).title == "Test Release"
    end

    test "filters out rows missing required fields" do
      definition = %Parsed{
        id: "test",
        name: "Test Indexer",
        search: %{
          rows: %{selector: "div.result"},
          fields: %{
            "title" => %{selector: "div.title"},
            "download" => %{selector: "a.download", attribute: "href"},
            "size" => %{selector: "div.size"},
            "seeders" => %{selector: "div.seeders"},
            "leechers" => %{selector: "div.leechers"}
          }
        }
      }

      html_body = """
      <div class="result">
        <div class="title">Complete Release</div>
        <div class="size">1 GB</div>
        <div class="seeders">50</div>
        <div class="leechers">10</div>
        <a class="download" href="magnet:?xt=urn:btih:complete">Download</a>
      </div>
      <div class="result">
        <div class="title">Missing Download Link</div>
        <div class="size">2 GB</div>
        <div class="seeders">30</div>
        <div class="leechers">5</div>
      </div>
      <div class="result">
        <div class="size">3 GB</div>
        <div class="seeders">20</div>
        <div class="leechers">3</div>
        <a class="download" href="magnet:?xt=urn:btih:notitle">Download</a>
      </div>
      """

      response = %{status: 200, body: html_body}

      assert {:ok, results} = CardigannResultParser.parse_results(definition, response, "Test")
      assert length(results) == 1
      assert hd(results).title == "Complete Release"
    end
  end

  describe "apply_filters/2" do
    test "applies replace filter" do
      filters = [%{name: "replace", args: [" GB", ""]}]
      assert {:ok, "1.5"} = CardigannResultParser.apply_filters("1.5 GB", filters)
    end

    test "applies replace filter with string keys" do
      filters = [%{"name" => "replace", "args" => ["[", ""]}]
      assert {:ok, "test]"} = CardigannResultParser.apply_filters("[test]", filters)
    end

    test "applies re_replace filter" do
      filters = [%{name: "re_replace", args: ["\\[.*?\\]", ""]}]
      assert {:ok, " Test"} = CardigannResultParser.apply_filters("[Tag] Test", filters)
    end

    test "applies re_replace filter with string keys" do
      filters = [%{"name" => "re_replace", "args" => ["\\s+", "_"]}]
      assert {:ok, "hello_world"} = CardigannResultParser.apply_filters("hello  world", filters)
    end

    test "applies append filter" do
      filters = [%{name: "append", args: [".torrent"]}]
      assert {:ok, "file.torrent"} = CardigannResultParser.apply_filters("file", filters)
    end

    test "applies prepend filter" do
      filters = [%{name: "prepend", args: ["https://"]}]

      assert {:ok, "https://example.com"} =
               CardigannResultParser.apply_filters("example.com", filters)
    end

    test "applies trim filter" do
      filters = [%{name: "trim"}]
      assert {:ok, "test"} = CardigannResultParser.apply_filters("  test  ", filters)
    end

    test "applies multiple filters in sequence" do
      filters = [
        %{name: "trim"},
        %{name: "replace", args: [" GB", ""]},
        %{name: "append", args: [" bytes"]}
      ]

      assert {:ok, "1.5 bytes"} = CardigannResultParser.apply_filters("  1.5 GB  ", filters)
    end

    test "ignores unknown filters" do
      filters = [%{name: "unknown_filter", args: ["test"]}]
      assert {:ok, "value"} = CardigannResultParser.apply_filters("value", filters)
    end

    test "returns original value with empty filter list" do
      assert {:ok, "test"} = CardigannResultParser.apply_filters("test", [])
    end

    test "applies split filter" do
      # Split by "/" and get index 2 (0-based)
      filters = [%{name: "split", args: ["/", 2]}]
      assert {:ok, "42"} = CardigannResultParser.apply_filters("/sub/42/", filters)

      # Split by "/" and get index 0
      filters = [%{name: "split", args: ["/", 0]}]
      assert {:ok, ""} = CardigannResultParser.apply_filters("/sub/42/", filters)

      # Split by "/" and get index 1
      filters = [%{name: "split", args: ["/", 1]}]
      assert {:ok, "sub"} = CardigannResultParser.apply_filters("/sub/42/", filters)
    end

    test "applies split filter with string keys" do
      filters = [%{"name" => "split", "args" => ["/", 2]}]
      assert {:ok, "category"} = CardigannResultParser.apply_filters("/type/category/id", filters)
    end

    test "applies urldecode filter" do
      filters = [%{name: "urldecode"}]
      assert {:ok, "hello world"} = CardigannResultParser.apply_filters("hello%20world", filters)
    end

    test "applies urldecode filter with string keys" do
      filters = [%{"name" => "urldecode"}]
      assert {:ok, "hello+world"} = CardigannResultParser.apply_filters("hello%2Bworld", filters)
    end
  end

  describe "parse_size/1" do
    test "parses gigabytes" do
      assert CardigannResultParser.parse_size("1.5 GB") == 1_610_612_736
      assert CardigannResultParser.parse_size("2 GiB") == 2_147_483_648
      assert CardigannResultParser.parse_size("0.5GB") == 536_870_912
    end

    test "parses megabytes" do
      assert CardigannResultParser.parse_size("500 MB") == 524_288_000
      assert CardigannResultParser.parse_size("1024 MiB") == 1_073_741_824
      assert CardigannResultParser.parse_size("1.5MB") == 1_572_864
    end

    test "parses kilobytes" do
      assert CardigannResultParser.parse_size("1024 KB") == 1_048_576
      assert CardigannResultParser.parse_size("500 KiB") == 512_000
    end

    test "parses terabytes" do
      assert CardigannResultParser.parse_size("1.5 TB") == 1_649_267_441_664
    end

    test "parses plain bytes" do
      assert CardigannResultParser.parse_size("1024") == 1024
      assert CardigannResultParser.parse_size("500") == 500
    end

    test "handles nil and empty strings" do
      assert CardigannResultParser.parse_size(nil) == 0
      assert CardigannResultParser.parse_size("") == 0
    end

    test "handles malformed size strings" do
      assert CardigannResultParser.parse_size("invalid") == 0
      assert CardigannResultParser.parse_size("N/A") == 0
    end

    test "parses lowercase units (case-insensitive)" do
      # Lowercase gb/mb are common on some sites
      assert CardigannResultParser.parse_size("3.05Gb") == 3_274_912_563
      assert CardigannResultParser.parse_size("688Mb") == 721_420_288
      assert CardigannResultParser.parse_size("1.5 gb") == 1_610_612_736
      assert CardigannResultParser.parse_size("500 mb") == 524_288_000
    end
  end

  describe "parse_size_with_title_fallback/2" do
    test "uses raw size when available" do
      assert CardigannResultParser.parse_size_with_title_fallback("1.5 GB", "Some Title") ==
               1_610_612_736
    end

    test "extracts size from title when raw size is empty" do
      title = "HD 1080p (3.05Gb) - Some Video"
      assert CardigannResultParser.parse_size_with_title_fallback("", title) == 3_274_912_563
      assert CardigannResultParser.parse_size_with_title_fallback("0", title) == 3_274_912_563
    end

    test "extracts size from title with MB" do
      title = "Video File 720p 688Mb"
      assert CardigannResultParser.parse_size_with_title_fallback(nil, title) == 721_420_288
    end

    test "extracts size from title with various formats" do
      # Space before unit
      assert CardigannResultParser.parse_size_with_title_fallback("0", "Video 1.2 GB quality") ==
               1_288_490_188

      # No space before unit
      assert CardigannResultParser.parse_size_with_title_fallback("0", "Video 500MB download") ==
               524_288_000

      # Parentheses
      assert CardigannResultParser.parse_size_with_title_fallback("0", "Title (2.5Gb)") ==
               2_684_354_560
    end

    test "returns 0 when no size found in title" do
      assert CardigannResultParser.parse_size_with_title_fallback("", "No size here") == 0

      assert CardigannResultParser.parse_size_with_title_fallback(
               nil,
               "Just a title with #tags"
             ) == 0
    end
  end

  describe "parse_date/1" do
    test "parses ISO 8601 datetime" do
      result = CardigannResultParser.parse_date("2024-01-15T12:30:00Z")
      assert %DateTime{} = result
      assert result.year == 2024
      assert result.month == 1
      assert result.day == 15
    end

    test "handles nil and empty strings" do
      assert CardigannResultParser.parse_date(nil) == nil
      assert CardigannResultParser.parse_date("") == nil
    end

    test "handles invalid date strings gracefully" do
      assert CardigannResultParser.parse_date("invalid") == nil
      assert CardigannResultParser.parse_date("not a date") == nil
    end
  end

  describe "parse_results/3 with JSON" do
    test "parses simple JSON results" do
      definition = %Parsed{
        id: "test",
        name: "Test JSON Indexer",
        search: %{
          rows: %{selector: "$.results"},
          fields: %{
            "title" => %{selector: "name"},
            "download" => %{selector: "magnet"},
            "size" => %{selector: "bytes"},
            "seeders" => %{selector: "seeds"},
            "leechers" => %{selector: "peers"}
          }
        }
      }

      json_body = """
      {
        "results": [
          {
            "name": "Ubuntu 22.04",
            "magnet": "magnet:?xt=urn:btih:abc123",
            "bytes": "4500000000",
            "seeds": "100",
            "peers": "50"
          },
          {
            "name": "Debian 12",
            "magnet": "magnet:?xt=urn:btih:def456",
            "bytes": "650000000",
            "seeds": "200",
            "peers": "25"
          }
        ]
      }
      """

      response = %{status: 200, body: json_body}

      assert {:ok, results} =
               CardigannResultParser.parse_results(definition, response, "TestJSON")

      assert length(results) == 2

      [result1, result2] = results

      assert result1.title == "Ubuntu 22.04"
      assert result1.download_url == "magnet:?xt=urn:btih:abc123"
      assert result1.size == 4_500_000_000
      assert result1.seeders == 100
      assert result1.leechers == 50
      assert result1.indexer == "TestJSON"

      assert result2.title == "Debian 12"
      assert result2.seeders == 200
    end

    test "handles invalid JSON gracefully" do
      definition = %Parsed{
        id: "test",
        name: "Test Indexer",
        search: %{
          rows: %{selector: "$.results"},
          fields: %{
            "title" => %{selector: "name"},
            "download" => %{selector: "link"}
          }
        }
      }

      response = %{status: 200, body: "not valid json {"}

      # Invalid JSON that looks like JSON will be treated as HTML
      # and return empty results since no HTML elements match
      assert {:ok, []} = CardigannResultParser.parse_results(definition, response, "Test")
    end

    test "navigates dotted JSON paths without $. prefix" do
      # Bug: "data.movies" was treated as single key "data.movies" instead of ["data", "movies"]
      definition = %Parsed{
        id: "test",
        name: "Test Nested JSON",
        search: %{
          rows: %{selector: "data.movies"},
          fields: %{
            :title => %{selector: "name", filters: []},
            :download => %{selector: "magnet", filters: []},
            :seeders => %{selector: "seeds", filters: []},
            :leechers => %{selector: "peers", filters: []}
          }
        }
      }

      json_response = %{
        "status" => "ok",
        "data" => %{
          "movies" => [
            %{
              "name" => "Test Movie",
              "magnet" => "magnet:?xt=urn:btih:abc123",
              "seeds" => 50,
              "peers" => 10
            }
          ]
        }
      }

      response = %{status: 200, body: json_response}

      assert {:ok, [result]} =
               CardigannResultParser.parse_results(definition, response, "TestNested")

      assert result.title == "Test Movie"
      assert result.download_url == "magnet:?xt=urn:btih:abc123"
      assert result.seeders == 50
    end

    test "expands rows.attribute sub-arrays with parent access via .. prefix" do
      # Bug: YTS-style definitions have movies with nested torrents arrays.
      # Each torrent should become its own row, with parent movie fields
      # accessible via ".." prefix selectors.
      definition = %Parsed{
        id: "test",
        name: "Test Attribute Expansion",
        search: %{
          rows: %{selector: "data.movies", attribute: "torrents"},
          fields: %{
            :title => %{selector: "..title_long", filters: []},
            :download => %{selector: "url", filters: []},
            :size => %{selector: "size_bytes", filters: []},
            :seeders => %{selector: "seeds", filters: []},
            :leechers => %{selector: "peers", filters: []}
          }
        }
      }

      json_response = %{
        "data" => %{
          "movies" => [
            %{
              "title_long" => "Zootopia 2 (2025)",
              "torrents" => [
                %{
                  "url" => "https://example.com/download/720p",
                  "size_bytes" => 1_040_554_394,
                  "seeds" => 100,
                  "peers" => 50,
                  "quality" => "720p"
                },
                %{
                  "url" => "https://example.com/download/1080p",
                  "size_bytes" => 2_136_746_230,
                  "seeds" => 200,
                  "peers" => 75,
                  "quality" => "1080p"
                }
              ]
            }
          ]
        }
      }

      response = %{status: 200, body: json_response}

      assert {:ok, results} =
               CardigannResultParser.parse_results(definition, response, "TestExpand")

      # Two torrents should produce two result rows
      assert length(results) == 2

      [r720, r1080] = results

      # Both rows should have the parent movie's title
      assert r720.title == "Zootopia 2 (2025)"
      assert r1080.title == "Zootopia 2 (2025)"

      # Each row should have its own torrent-specific fields
      assert r720.download_url == "https://example.com/download/720p"
      assert r720.size == 1_040_554_394
      assert r720.seeders == 100

      assert r1080.download_url == "https://example.com/download/1080p"
      assert r1080.size == 2_136_746_230
      assert r1080.seeders == 200
    end

    test "renders .Result template variables in JSON filter args" do
      # Bug: Go templates like {{ .Result._quality }} in filter args were not
      # resolved because the JSON parser didn't build a .Result context from
      # previously extracted field values.
      definition = %Parsed{
        id: "test",
        name: "Test Result Templates",
        search: %{
          rows: %{selector: "data.movies", attribute: "torrents"},
          fields: %{
            :_quality => %{selector: "quality", filters: []},
            :_codec => %{selector: "video_codec", filters: []},
            :title => %{
              selector: "..title_long",
              filters: [
                %{
                  "name" => "append",
                  "args" => " {{ .Result._quality }} {{ .Result._codec }}"
                }
              ]
            },
            :download => %{selector: "url", filters: []},
            :seeders => %{selector: "seeds", filters: []},
            :leechers => %{selector: "peers", filters: []}
          }
        }
      }

      json_response = %{
        "data" => %{
          "movies" => [
            %{
              "title_long" => "Test Movie (2025)",
              "torrents" => [
                %{
                  "url" => "https://example.com/download/abc",
                  "quality" => "1080p",
                  "video_codec" => "x265",
                  "seeds" => 50,
                  "peers" => 10
                }
              ]
            }
          ]
        }
      }

      response = %{status: 200, body: json_response}

      template_context = %{
        config: %{"sitelink" => "https://example.com/"},
        keywords: "test"
      }

      assert {:ok, [result]} =
               CardigannResultParser.parse_results(definition, response, "TestTemplates",
                 template_context: template_context
               )

      # The title should have the quality and codec appended via template rendering
      assert result.title == "Test Movie (2025) 1080p x265"
    end

    test "renders .Config template variables in JSON filter args" do
      # Bug: {{ .Config.sitelink }} in URL filters was not resolved because
      # no template context was passed to the JSON parser.
      definition = %Parsed{
        id: "test",
        name: "Test Config Templates",
        search: %{
          rows: %{selector: "$.results"},
          fields: %{
            :title => %{selector: "name", filters: []},
            :download => %{
              selector: "download_path",
              filters: [
                %{
                  "name" => "prepend",
                  "args" => "{{ .Config.sitelink }}"
                }
              ]
            },
            :seeders => %{selector: "seeds", filters: []},
            :leechers => %{selector: "peers", filters: []}
          }
        }
      }

      json_body =
        Jason.encode!(%{
          "results" => [
            %{
              "name" => "Test Item",
              "download_path" => "torrent/download/ABC123",
              "seeds" => 10,
              "peers" => 5
            }
          ]
        })

      response = %{status: 200, body: json_body}

      template_context = %{
        config: %{"sitelink" => "https://example.com/"},
        keywords: "test"
      }

      assert {:ok, [result]} =
               CardigannResultParser.parse_results(definition, response, "TestConfig",
                 template_context: template_context
               )

      assert result.download_url == "https://example.com/torrent/download/ABC123"
    end

    test "handles multiple movies with multiple torrents each" do
      definition = %Parsed{
        id: "test",
        name: "Test Multi Expand",
        search: %{
          rows: %{selector: "data.movies", attribute: "torrents"},
          fields: %{
            :title => %{selector: "..title", filters: []},
            :download => %{selector: "url", filters: []},
            :size => %{selector: "size_bytes", filters: []},
            :seeders => %{selector: "seeds", filters: []},
            :leechers => %{selector: "peers", filters: []}
          }
        }
      }

      json_response = %{
        "data" => %{
          "movies" => [
            %{
              "title" => "Movie A",
              "torrents" => [
                %{"url" => "https://x.com/a1", "size_bytes" => 100, "seeds" => 10, "peers" => 1},
                %{"url" => "https://x.com/a2", "size_bytes" => 200, "seeds" => 20, "peers" => 2}
              ]
            },
            %{
              "title" => "Movie B",
              "torrents" => [
                %{"url" => "https://x.com/b1", "size_bytes" => 300, "seeds" => 30, "peers" => 3}
              ]
            }
          ]
        }
      }

      response = %{status: 200, body: json_response}

      assert {:ok, results} =
               CardigannResultParser.parse_results(definition, response, "TestMulti")

      # 2 torrents from Movie A + 1 from Movie B = 3 rows
      assert length(results) == 3

      titles = Enum.map(results, & &1.title)
      assert titles == ["Movie A", "Movie A", "Movie B"]

      download_urls = Enum.map(results, & &1.download_url)
      assert download_urls == ["https://x.com/a1", "https://x.com/a2", "https://x.com/b1"]
    end

    test "falls back gracefully when rows.attribute key is missing from items" do
      definition = %Parsed{
        id: "test",
        name: "Test Missing Attribute",
        search: %{
          rows: %{selector: "$.items", attribute: "children"},
          fields: %{
            :title => %{selector: "name", filters: []},
            :download => %{selector: "link", filters: []},
            :seeders => %{selector: "seeds", filters: []},
            :leechers => %{selector: "peers", filters: []}
          }
        }
      }

      json_body =
        Jason.encode!(%{
          "items" => [
            %{
              "name" => "No Children Item",
              "link" => "magnet:?xt=urn:btih:aaa",
              "seeds" => 5,
              "peers" => 1
            }
          ]
        })

      response = %{status: 200, body: json_body}

      # When attribute key doesn't exist, the parent row should be kept as-is
      assert {:ok, [result]} =
               CardigannResultParser.parse_results(definition, response, "TestFallback")

      assert result.title == "No Children Item"
      assert result.download_url == "magnet:?xt=urn:btih:aaa"
    end
  end

  describe "HTML field extraction" do
    test "extracts text content from elements" do
      definition = %Parsed{
        id: "test",
        name: "Test",
        search: %{
          rows: %{selector: "div.item"},
          fields: %{
            "title" => %{selector: "h1"},
            "download" => %{selector: "a", attribute: "href"},
            "size" => %{selector: "span.size"},
            "seeders" => %{selector: "span.seeds"},
            "leechers" => %{selector: "span.peers"}
          }
        }
      }

      html_body = """
      <div class="item">
        <h1>Test  Title  </h1>
        <span class="size">1 GB</span>
        <span class="seeds">10</span>
        <span class="peers">5</span>
        <a href="magnet:?xt=test">Download</a>
      </div>
      """

      response = %{status: 200, body: html_body}

      assert {:ok, [result]} = CardigannResultParser.parse_results(definition, response, "Test")
      assert result.title == "Test  Title"
    end

    test "extracts attributes from elements" do
      definition = %Parsed{
        id: "test",
        name: "Test",
        search: %{
          rows: %{selector: "div.item"},
          fields: %{
            "title" => %{selector: "a", attribute: "title"},
            "download" => %{selector: "a", attribute: "href"},
            "category" => %{selector: "div", attribute: "data-category"},
            "size" => %{selector: "span"},
            "seeders" => %{selector: "span"},
            "leechers" => %{selector: "span"}
          }
        }
      }

      html_body = """
      <div class="item" data-category="movies">
        <a href="magnet:?xt=test" title="Test Movie 1080p">Download</a>
        <span>1 GB</span>
      </div>
      """

      response = %{status: 200, body: html_body}

      assert {:ok, [result]} = CardigannResultParser.parse_results(definition, response, "Test")
      assert result.title == "Test Movie 1080p"
      assert result.download_url == "magnet:?xt=test"
      assert result.category == 0
    end

    test "applies filters to extracted fields" do
      definition = %Parsed{
        id: "test",
        name: "Test",
        search: %{
          rows: %{selector: "div.item"},
          fields: %{
            "title" => %{
              selector: "h1",
              filters: [
                %{name: "re_replace", args: ["\\[.*?\\]", ""]},
                %{name: "trim"}
              ]
            },
            "download" => %{selector: "a", attribute: "href"},
            "size" => %{
              selector: "span.size",
              filters: [%{name: "replace", args: [" ", ""]}]
            },
            "seeders" => %{selector: "span.seeds"},
            "leechers" => %{selector: "span.peers"}
          }
        }
      }

      html_body = """
      <div class="item">
        <h1>  [Tag] Test Movie 1080p  </h1>
        <span class="size">1.5 GB</span>
        <span class="seeds">10</span>
        <span class="peers">5</span>
        <a href="magnet:?xt=test">Download</a>
      </div>
      """

      response = %{status: 200, body: html_body}

      assert {:ok, [result]} = CardigannResultParser.parse_results(definition, response, "Test")
      assert result.title == "Test Movie 1080p"
      assert result.size == 1_610_612_736
    end
  end

  describe "quality parsing integration" do
    test "parses quality from titles" do
      definition = %Parsed{
        id: "test",
        name: "Test",
        search: %{
          rows: %{selector: "div.item"},
          fields: %{
            "title" => %{selector: "div.title"},
            "download" => %{selector: "a", attribute: "href"},
            "size" => %{selector: "div.size"},
            "seeders" => %{selector: "div.seeds"},
            "leechers" => %{selector: "div.peers"}
          }
        }
      }

      html_body = """
      <div class="item">
        <div class="title">Test.Movie.2024.1080p.BluRay.x264-GROUP</div>
        <div class="size">5 GB</div>
        <div class="seeds">100</div>
        <div class="peers">50</div>
        <a href="magnet:?xt=test">Download</a>
      </div>
      """

      response = %{status: 200, body: html_body}

      assert {:ok, [result]} = CardigannResultParser.parse_results(definition, response, "Test")
      assert result.quality != nil
      assert result.quality.resolution == "1080p"
      assert result.quality.source == "BluRay"
      assert result.quality.codec == "x264"
    end
  end

  describe "text field type with templates" do
    test "extracts category using text field referencing extracted values" do
      definition = %Parsed{
        id: "test",
        name: "Test",
        capabilities: %{
          modes: %{"search" => ["q"]},
          categorymappings: [
            %{"id" => "42", "cat" => "Movies/HD", "desc" => "HD Movies"}
          ]
        },
        search: %{
          rows: %{selector: "div.item"},
          fields: %{
            # First extract category_optional from HTML (like 1337x does)
            :category_optional => %{
              selector: "a.category",
              attribute: "href",
              optional: true,
              filters: [%{name: "split", args: ["/", 2]}]
            },
            # Then compute category using template referencing the extracted value
            :category => %{
              text:
                "{{ if .Result.category_optional }}{{ .Result.category_optional }}{{ else }}40{{ end }}"
            },
            :title => %{selector: "div.title"},
            :download => %{selector: "a.download", attribute: "href"},
            :size => %{selector: "div.size"},
            :seeders => %{selector: "div.seeds"},
            :leechers => %{selector: "div.peers"}
          }
        }
      }

      html_body = """
      <div class="item">
        <div class="title">Test Movie 1080p</div>
        <a class="category" href="/sub/42/">HD Movies</a>
        <div class="size">5 GB</div>
        <div class="seeds">100</div>
        <div class="peers">50</div>
        <a class="download" href="magnet:?xt=test">Download</a>
      </div>
      """

      response = %{status: 200, body: html_body}

      assert {:ok, [result]} = CardigannResultParser.parse_results(definition, response, "Test")
      assert result.title == "Test Movie 1080p"
      # Category should be extracted as 42, which maps to Movies/HD (2040)
      assert result.category == 2040
    end

    test "uses default value when optional field not found" do
      definition = %Parsed{
        id: "test",
        name: "Test",
        capabilities: %{
          modes: %{"search" => ["q"]},
          categorymappings: [
            %{"id" => "40", "cat" => "Other/Misc", "desc" => "Other"}
          ]
        },
        search: %{
          rows: %{selector: "div.item"},
          fields: %{
            :category_optional => %{
              selector: "a.category",
              attribute: "href",
              optional: true,
              filters: [%{name: "split", args: ["/", 2]}]
            },
            :category => %{
              text:
                "{{ if .Result.category_optional }}{{ .Result.category_optional }}{{ else }}40{{ end }}"
            },
            :title => %{selector: "div.title"},
            :download => %{selector: "a.download", attribute: "href"},
            :size => %{selector: "div.size"},
            :seeders => %{selector: "div.seeds"},
            :leechers => %{selector: "div.peers"}
          }
        }
      }

      # Note: no category link in HTML
      html_body = """
      <div class="item">
        <div class="title">Test Release</div>
        <div class="size">1 GB</div>
        <div class="seeds">50</div>
        <div class="peers">10</div>
        <a class="download" href="magnet:?xt=test">Download</a>
      </div>
      """

      response = %{status: 200, body: html_body}

      assert {:ok, [result]} = CardigannResultParser.parse_results(definition, response, "Test")
      # Should fall back to category 40 (Other/Misc = 8010)
      assert result.category == 8010
    end
  end

  describe "optional fields" do
    test "handles optional field that is not found" do
      definition = %Parsed{
        id: "test",
        name: "Test",
        search: %{
          rows: %{selector: "div.item"},
          fields: %{
            :title => %{selector: "div.title"},
            :download => %{selector: "a", attribute: "href"},
            :details => %{selector: "a.details", attribute: "href", optional: true},
            :size => %{selector: "div.size"},
            :seeders => %{selector: "div.seeds"},
            :leechers => %{selector: "div.peers"}
          }
        }
      }

      html_body = """
      <div class="item">
        <div class="title">Test</div>
        <div class="size">1 GB</div>
        <div class="seeds">10</div>
        <div class="peers">5</div>
        <a href="magnet:?xt=test">Download</a>
      </div>
      """

      response = %{status: 200, body: html_body}

      # Should parse successfully even though optional field is missing
      assert {:ok, [result]} = CardigannResultParser.parse_results(definition, response, "Test")
      assert result.title == "Test"
      assert result.info_url == nil
    end
  end

  describe "edge cases" do
    test "handles empty HTML response" do
      definition = %Parsed{
        id: "test",
        name: "Test",
        search: %{
          rows: %{selector: "div.item"},
          fields: %{
            "title" => %{selector: "div.title"},
            "download" => %{selector: "a", attribute: "href"}
          }
        }
      }

      response = %{status: 200, body: "<html><body></body></html>"}

      assert {:ok, []} = CardigannResultParser.parse_results(definition, response, "Test")
    end

    test "handles malformed HTML gracefully" do
      definition = %Parsed{
        id: "test",
        name: "Test",
        search: %{
          rows: %{selector: "div.item"},
          fields: %{
            "title" => %{selector: "div.title"},
            "download" => %{selector: "a", attribute: "href"},
            "size" => %{selector: "div.size"},
            "seeders" => %{selector: "div.seeds"},
            "leechers" => %{selector: "div.peers"}
          }
        }
      }

      html_body = """
      <div class="item">
        <div class="title">Test</div>
        <div class="size">1 GB</div>
        <div class="seeds">10</div>
        <div class="peers">5</div>
        <a href="magnet:?xt=test">Download
      </div>
      """

      response = %{status: 200, body: html_body}

      # Should still parse successfully despite unclosed tag
      assert {:ok, [result]} = CardigannResultParser.parse_results(definition, response, "Test")
      assert result.title == "Test"
    end

    test "handles missing size/seeders/leechers gracefully" do
      definition = %Parsed{
        id: "test",
        name: "Test",
        search: %{
          rows: %{selector: "div.item"},
          fields: %{
            "title" => %{selector: "div.title"},
            "download" => %{selector: "a", attribute: "href"},
            "size" => %{selector: "div.size"},
            "seeders" => %{selector: "div.seeds"},
            "leechers" => %{selector: "div.peers"}
          }
        }
      }

      html_body = """
      <div class="item">
        <div class="title">Test Release</div>
        <a href="magnet:?xt=test">Download</a>
      </div>
      """

      response = %{status: 200, body: html_body}

      assert {:ok, [result]} = CardigannResultParser.parse_results(definition, response, "Test")
      assert result.title == "Test Release"
      assert result.size == 0
      assert result.seeders == 0
      assert result.leechers == 0
    end
  end

  describe "field default" do
    defp default_definition(seeders_field) do
      %Parsed{
        id: "def-test",
        name: "Def Test",
        type: "public",
        links: ["https://example.com"],
        encoding: "UTF-8",
        capabilities: %{},
        settings: [],
        search: %{
          paths: [%{path: "/s"}],
          inputs: %{},
          headers: nil,
          keywordsfilters: [],
          rows: %{selector: "tr"},
          fields: %{
            "title" => %{selector: "td.title"},
            "download" => %{selector: "a", attribute: "href"},
            "seeders" => seeders_field
          }
        }
      }
    end

    @html "<html><body><table><tr><td class=\"title\">Ubuntu</td><a href=\"magnet:?xt=urn:btih:AAA\">d</a></tr></table></body></html>"

    test "uses the default when an optional selector misses" do
      definition = default_definition(%{selector: "td.seeders", optional: true, default: 5})

      assert {:ok, [result]} =
               CardigannResultParser.parse_results(
                 definition,
                 %{status: 200, body: @html},
                 "Def Test",
                 template_context: %{},
                 base_url: "https://example.com"
               )

      assert result.seeders == 5
    end

    test "ignores the default when the selector matches" do
      html =
        "<html><body><table><tr><td class=\"title\">Ubuntu</td><td class=\"seeders\">42</td><a href=\"magnet:?xt=urn:btih:AAA\">d</a></tr></table></body></html>"

      definition = default_definition(%{selector: "td.seeders", optional: true, default: 0})

      assert {:ok, [result]} =
               CardigannResultParser.parse_results(
                 definition,
                 %{status: 200, body: html},
                 "Def Test",
                 template_context: %{},
                 base_url: "https://example.com"
               )

      assert result.seeders == 42
    end

    test "does not apply a default to a non-optional field" do
      definition = default_definition(%{selector: "td.seeders", default: 7})

      assert {:ok, results} =
               CardigannResultParser.parse_results(
                 definition,
                 %{status: 200, body: @html},
                 "Def Test",
                 template_context: %{},
                 base_url: "https://example.com"
               )

      # A required field that matches nothing drops the row rather than
      # inheriting a default it was never given permission to use.
      assert results == [] or hd(results).seeders != 7
    end
  end

  describe "andmatch with filtered keywords" do
    test "uses filtered keywords from template context" do
      definition = %Parsed{
        id: "andmatch-kw",
        name: "Andmatch KW",
        type: "public",
        links: ["https://example.com"],
        encoding: "UTF-8",
        capabilities: %{},
        settings: [],
        search: %{
          paths: [%{path: "/s"}],
          inputs: %{},
          headers: nil,
          keywordsfilters: [],
          rows: %{selector: "tr"},
          fields: %{
            "title" => %{selector: "td.title", filters: [%{name: "andmatch"}]},
            "download" => %{selector: "a.dl", attribute: "href"}
          }
        }
      }

      html =
        "<html><body><table>" <>
          "<tr><td class=\"title\">The Matrix 1999</td><a class=\"dl\" href=\"magnet:?xt=urn:btih:AAA\">d</a></tr>" <>
          "<tr><td class=\"title\">The Matrix</td><a class=\"dl\" href=\"magnet:?xt=urn:btih:BBB\">d</a></tr>" <>
          "</table></body></html>"

      assert {:ok, filtered_results} =
               CardigannResultParser.parse_results(
                 definition,
                 %{status: 200, body: html},
                 "Andmatch KW",
                 template_context: %{keywords: "The Matrix"},
                 base_url: "https://example.com"
               )

      assert length(filtered_results) == 2

      assert {:ok, unfiltered_results} =
               CardigannResultParser.parse_results(
                 definition,
                 %{status: 200, body: html},
                 "Andmatch KW",
                 template_context: %{keywords: "The Matrix 1999"},
                 base_url: "https://example.com"
               )

      assert length(unfiltered_results) == 1
      assert hd(unfiltered_results).title == "The Matrix 1999"
    end
  end

  describe "field case" do
    defp case_definition(category_field) do
      %Parsed{
        id: "case-test",
        name: "Case Test",
        type: "public",
        links: ["https://example.com"],
        encoding: "UTF-8",
        capabilities: %{},
        settings: [],
        search: %{
          paths: [%{path: "/s"}],
          inputs: %{},
          headers: nil,
          keywordsfilters: [],
          rows: %{selector: "tr"},
          fields: %{
            "title" => %{selector: "td.title"},
            "download" => %{selector: "a.dl", attribute: "href"},
            "category" => category_field
          }
        }
      }
    end

    defp case_html(cat) do
      "<html><body><table><tr>" <>
        "<td class=\"title\">Ubuntu</td>" <>
        "<td class=\"cat\"><a href=\"/browse?cat=#{cat}\">#{cat}</a></td>" <>
        "<a class=\"dl\" href=\"magnet:?xt=urn:btih:AAA\">d</a>" <>
        "</tr></table></body></html>"
    end

    test "resolves to the value of the first matching case selector" do
      definition =
        case_definition(%{
          selector: "td.cat",
          case: %{"a[href*=\"cat=tv\"]" => "5000", "a[href*=\"cat=movies\"]" => "2000"}
        })

      assert {:ok, [result]} =
               CardigannResultParser.parse_results(
                 definition,
                 %{status: 200, body: case_html("movies")},
                 "Case Test",
                 template_context: %{},
                 base_url: "https://example.com"
               )

      assert result.category == 2000
    end

    test "falls back to the * case key" do
      definition =
        case_definition(%{
          selector: "td.cat",
          case: %{"a[href*=\"cat=tv\"]" => "5000", "*" => "8000"}
        })

      assert {:ok, [result]} =
               CardigannResultParser.parse_results(
                 definition,
                 %{status: 200, body: case_html("other")},
                 "Case Test",
                 template_context: %{},
                 base_url: "https://example.com"
               )

      assert result.category == 8000
    end

    test "case combines with optional and default" do
      definition =
        case_definition(%{
          selector: "td.cat",
          case: %{"a[href*=\"cat=tv\"]" => "5000"},
          optional: true,
          default: "8000"
        })

      assert {:ok, [result]} =
               CardigannResultParser.parse_results(
                 definition,
                 %{status: 200, body: case_html("other")},
                 "Case Test",
                 template_context: %{},
                 base_url: "https://example.com"
               )

      assert result.category == 8000
    end
  end

  describe "XML responses" do
    test "parses an RSS-shaped response" do
      xml = """
      <?xml version="1.0" encoding="UTF-8"?>
      <rss version="2.0">
        <channel>
          <item>
            <title>Ubuntu 24.04</title>
            <link>magnet:?xt=urn:btih:AAA</link>
            <size>1500000000</size>
          </item>
          <item>
            <title>Ubuntu 22.04</title>
            <link>magnet:?xt=urn:btih:BBB</link>
            <size>1400000000</size>
          </item>
        </channel>
      </rss>
      """

      definition = %Parsed{
        id: "xml-test",
        name: "XML Test",
        type: "public",
        links: ["https://example.com"],
        encoding: "UTF-8",
        capabilities: %{},
        settings: [],
        search: %{
          paths: [%{path: "/rss", response: %{type: "xml"}}],
          inputs: %{},
          headers: nil,
          keywordsfilters: [],
          rows: %{selector: "rss/channel/item"},
          fields: %{
            "title" => %{selector: "title"},
            "download" => %{selector: "link"},
            "size" => %{selector: "size"}
          }
        }
      }

      assert {:ok, results} =
               CardigannResultParser.parse_results(
                 definition,
                 %{status: 200, body: xml},
                 "XML Test",
                 template_context: %{},
                 base_url: "https://example.com"
               )

      assert length(results) == 2
      assert hd(results).title == "Ubuntu 24.04"
      assert hd(results).download_url == "magnet:?xt=urn:btih:AAA"
    end

    test "resolves field case selectors" do
      xml = """
      <?xml version="1.0"?>
      <rss>
        <channel>
          <item>
            <raw_title>Ubuntu 1080p WEB</raw_title>
            <title>Ubuntu</title>
            <link>magnet:?xt=urn:btih:DDD</link>
          </item>
        </channel>
      </rss>
      """

      definition = %Parsed{
        id: "xml-case",
        name: "XML Case",
        type: "public",
        links: ["https://example.com"],
        encoding: "UTF-8",
        capabilities: %{},
        settings: [],
        search: %{
          paths: [%{path: "/rss", response: %{type: "xml"}}],
          inputs: %{},
          headers: nil,
          keywordsfilters: [],
          rows: %{selector: "rss/channel/item"},
          fields: %{
            "title" => %{selector: "title"},
            "download" => %{selector: "link"},
            "category" => %{
              selector: "raw_title",
              case: %{":contains(\"1080p\")" => "2", "*" => "1"}
            }
          }
        }
      }

      assert {:ok, [result]} =
               CardigannResultParser.parse_results(
                 definition,
                 %{status: 200, body: xml},
                 "XML Case",
                 template_context: %{},
                 base_url: "https://example.com"
               )

      assert result.category == 2
    end

    test "reads an XML attribute" do
      xml = """
      <?xml version="1.0"?>
      <torrents>
        <torrent name="Debian 12" magnet="magnet:?xt=urn:btih:CCC" />
      </torrents>
      """

      definition = %Parsed{
        id: "xml-attr",
        name: "XML Attr",
        type: "public",
        links: ["https://example.com"],
        encoding: "UTF-8",
        capabilities: %{},
        settings: [],
        search: %{
          paths: [%{path: "/x", response: %{type: "xml"}}],
          inputs: %{},
          headers: nil,
          keywordsfilters: [],
          rows: %{selector: "torrents/torrent"},
          fields: %{
            "title" => %{selector: ".", attribute: "name"},
            "download" => %{selector: ".", attribute: "magnet"}
          }
        }
      }

      assert {:ok, [result]} =
               CardigannResultParser.parse_results(
                 definition,
                 %{status: 200, body: xml},
                 "XML Attr",
                 template_context: %{},
                 base_url: "https://example.com"
               )

      assert result.title == "Debian 12"
    end

    test "uses declared type from the selected search path" do
      xml = """
      <?xml version="1.0"?>
      <torrents>
        <torrent name="Debian 12" magnet="magnet:?xt=urn:btih:CCC" />
      </torrents>
      """

      html_path = %{
        path: "/html",
        response: %{type: "html"},
        categories: [5000]
      }

      xml_path = %{
        path: "/xml",
        response: %{type: "xml"},
        categories: [2000]
      }

      definition = %Parsed{
        id: "xml-path",
        name: "XML Path",
        type: "public",
        links: ["https://example.com"],
        encoding: "UTF-8",
        capabilities: %{},
        settings: [],
        search: %{
          paths: [html_path, xml_path],
          inputs: %{},
          headers: nil,
          keywordsfilters: [],
          rows: %{selector: "torrents/torrent"},
          fields: %{
            "title" => %{selector: ".", attribute: "name"},
            "download" => %{selector: ".", attribute: "magnet"}
          }
        }
      }

      response = %{status: 200, body: xml}

      assert {:ok, []} =
               CardigannResultParser.parse_results(
                 definition,
                 response,
                 "XML Path",
                 categories: [5000],
                 template_context: %{},
                 base_url: "https://example.com"
               )

      assert {:ok, [result]} =
               CardigannResultParser.parse_results(
                 definition,
                 response,
                 "XML Path",
                 categories: [2000],
                 template_context: %{},
                 base_url: "https://example.com"
               )

      assert result.title == "Debian 12"
    end

    test "text fields use extracted values as .Result context" do
      xml = """
      <?xml version="1.0"?>
      <torrents>
        <torrent name="Debian 12" magnet="magnet:?xt=urn:btih:CCC" />
      </torrents>
      """

      definition = %Parsed{
        id: "xml-text",
        name: "XML Text",
        type: "public",
        links: ["https://example.com"],
        encoding: "UTF-8",
        capabilities: %{},
        settings: [],
        search: %{
          paths: [%{path: "/x", response: %{type: "xml"}}],
          inputs: %{},
          headers: nil,
          keywordsfilters: [],
          rows: %{selector: "torrents/torrent"},
          fields: %{
            "_name" => %{selector: ".", attribute: "name"},
            "title" => %{text: "{{ .Result._name }} ISO"},
            "download" => %{selector: ".", attribute: "magnet"}
          }
        }
      }

      assert {:ok, [result]} =
               CardigannResultParser.parse_results(
                 definition,
                 %{status: 200, body: xml},
                 "XML Text",
                 template_context: %{},
                 base_url: "https://example.com"
               )

      assert result.title == "Debian 12 ISO"
    end
  end

  describe "rows.missingAttributeEqualsNoResults" do
    test "returns no rows instead of an error when the attribute is missing" do
      html =
        "<html><body><table><tr><td href=\"magnet:?xt=urn:btih:abc\">no attr here</td></tr></table></body></html>"

      definition = %Parsed{
        id: "manr",
        name: "MANR",
        type: "public",
        links: ["https://example.com"],
        encoding: "UTF-8",
        capabilities: %{},
        settings: [],
        search: %{
          paths: [%{path: "/s"}],
          inputs: %{},
          headers: nil,
          keywordsfilters: [],
          rows: %{
            selector: "tr",
            attribute: "data-id",
            missing_attribute_equals_no_results: true
          },
          fields: %{
            "title" => %{selector: "td"},
            "download" => %{selector: "td", attribute: "href"}
          }
        }
      }

      assert {:ok, []} =
               CardigannResultParser.parse_results(definition, %{status: 200, body: html}, "MANR",
                 template_context: %{},
                 base_url: "https://example.com"
               )
    end
  end
end
