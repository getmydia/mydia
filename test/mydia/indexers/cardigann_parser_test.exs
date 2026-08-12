defmodule Mydia.Indexers.CardigannParserTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.CardigannParser
  alias Mydia.Indexers.CardigannDefinition.Parsed

  @minimal_public_indexer """
  id: testindexer
  name: Test Indexer
  description: A test indexer for unit tests
  language: en-US
  type: public
  encoding: UTF-8
  links:
    - https://test.example.com/

  caps:
    modes:
      search:
        q: q
    categories:
      1000: Movies

  search:
    path: /search
    inputs:
      q: "{{ .Keywords }}"
    rows:
      selector: table.results tbody tr
    fields:
      title:
        selector: td.title a
      size:
        selector: td.size
      seeders:
        selector: td.seeders
      leechers:
        selector: td.leechers
      download:
        selector: td.download a
        attribute: href
  """

  @private_indexer_with_login """
  id: privatetest
  name: Private Test Indexer
  description: A private test indexer with login
  language: en-US
  type: private
  encoding: UTF-8
  links:
    - https://private.example.com/

  caps:
    modes:
      search:
        q: search
      tv-search:
        q: search
        season: season
        ep: episode
    categorymappings:
      - id: 1
        cat: Movies
        desc: Movies

  login:
    method: form
    path: /login
    submitpath: /login
    inputs:
      username: "{{ .Config.username }}"
      password: "{{ .Config.password }}"
    error:
      - selector: div.error
    test:
      path: /
      selector: a[href="/logout"]

  search:
    paths:
      - path: /browse
        categories: [1]
      - path: /search
    inputs:
      search: "{{ .Keywords }}"
    headers:
      X-Requested-With: XMLHttpRequest
    rows:
      selector: div.torrent-row
    fields:
      title:
        selector: div.title
        filters:
          - name: re_replace
            args: ["\\[.*?\\]", ""]
      category:
        selector: div.category
        attribute: data-id
      details:
        selector: a.details
        attribute: href
      download:
        selector: a.download
        attribute: href
      size:
        selector: div.size
      date:
        selector: div.date
      seeders:
        selector: div.seeders
      leechers:
        selector: div.leechers
      grabs:
        selector: div.grabs
  """

  @indexer_with_download_config """
  id: downloadtest
  name: Download Config Test
  description: Test indexer with download configuration
  language: en-US
  type: public
  encoding: UTF-8
  links:
    - https://download.example.com/

  caps:
    modes:
      search:
        q: q
    categories:
      2000: TV

  download:
    selectors:
      - selector: a.download
        attribute: href
    method: get
    infohash:
      selector: div.hash

  search:
    path: /search
    inputs:
      q: "{{ .Keywords }}"
    rows:
      selector: tr.result
    fields:
      title:
        selector: td:nth-child(1)
      size:
        selector: td:nth-child(2)
      seeders:
        selector: td:nth-child(3)
      leechers:
        selector: td:nth-child(4)
      magnet:
        selector: a.magnet
        attribute: href
  """

  @indexer_with_settings """
  id: settingstest
  name: Settings Test Indexer
  description: Test indexer with settings
  language: en-US
  type: semi-private
  encoding: UTF-8
  links:
    - https://settings.example.com/

  caps:
    modes:
      search:
        q: search
    categories:
      3000: Audio

  settings:
    - name: username
      type: text
      label: Username
    - name: apikey
      type: text
      label: API Key
    - name: freeleech
      type: checkbox
      label: Freeleech Only
      default: false
    - name: sort
      type: select
      label: Sort By
      default: created
      options:
        created: Date Added
        seeders: Seeders
        size: Size

  search:
    path: /api/search
    inputs:
      q: "{{ .Keywords }}"
      apikey: "{{ .Config.apikey }}"
    rows:
      selector: items item
    fields:
      title:
        selector: title
      size:
        selector: size
      seeders:
        selector: seeders
      leechers:
        selector: leechers
      download:
        selector: link
  """

  describe "parse_definition/1" do
    test "parses minimal public indexer successfully" do
      assert {:ok, %Parsed{} = parsed} = CardigannParser.parse_definition(@minimal_public_indexer)
      assert parsed.id == "testindexer"
      assert parsed.name == "Test Indexer"
      assert parsed.description == "A test indexer for unit tests"
      assert parsed.language == "en-US"
      assert parsed.type == "public"
      assert parsed.encoding == "UTF-8"
      assert parsed.links == ["https://test.example.com/"]
      assert is_nil(parsed.login)
    end

    test "parses private indexer with login configuration" do
      assert {:ok, %Parsed{} = parsed} =
               CardigannParser.parse_definition(@private_indexer_with_login)

      assert parsed.type == "private"
      assert parsed.login.method == "form"
      assert parsed.login.path == "/login"
      assert parsed.login.submitpath == "/login"
      assert is_map(parsed.login.inputs)
      assert is_list(parsed.login.error)
      assert length(parsed.login.error) == 1
      assert is_map(parsed.login.test)
    end

    test "parses indexer with download configuration" do
      assert {:ok, %Parsed{} = parsed} =
               CardigannParser.parse_definition(@indexer_with_download_config)

      assert parsed.download != nil
      assert parsed.download.method == "get"
      assert is_list(parsed.download.selectors)
      assert length(parsed.download.selectors) == 1
      assert is_map(parsed.download.infohash)
    end

    test "preserves the nested selectors of an infohash block" do
      assert {:ok, %Parsed{} = parsed} =
               "test/fixtures/cardigann/magnetdownload.yml"
               |> File.read!()
               |> CardigannParser.parse_definition()

      assert parsed.download.infohash.usebeforeresponse == true
      assert parsed.download.infohash.hash.selector == ":root"
      assert parsed.download.infohash.title.selector == ":root"
      assert [%{"name" => "regexp"} | _] = parsed.download.infohash.hash.filters
    end

    test "parses the before-request of a download block" do
      assert {:ok, %Parsed{} = parsed} =
               "test/fixtures/cardigann/magnetdownload.yml"
               |> File.read!()
               |> CardigannParser.parse_definition()

      assert parsed.download.before.path == "api/json_info"
      assert parsed.download.before.inputs["hashes"] =~ "re_replace"
    end

    test "parses indexer with settings" do
      assert {:ok, %Parsed{} = parsed} =
               CardigannParser.parse_definition(@indexer_with_settings)

      assert parsed.type == "semi-private"
      assert length(parsed.settings) == 4

      [username, apikey, freeleech, sort] = parsed.settings
      assert username.name == "username"
      assert username.type == "text"
      assert apikey.name == "apikey"
      assert freeleech.type == "checkbox"
      assert freeleech.default == false
      assert sort.type == "select"
      assert is_map(sort.options)
    end

    test "returns error for invalid YAML" do
      invalid_yaml = "this is: not: valid: yaml: [unclosed"
      assert {:error, _} = CardigannParser.parse_definition(invalid_yaml)
    end

    test "returns error for missing required fields" do
      incomplete_yaml = """
      id: test
      name: Test
      """

      assert {:error, _} = CardigannParser.parse_definition(incomplete_yaml)
    end
  end

  describe "parse_search_config/1" do
    test "extracts search configuration with single path" do
      yaml_data = %{
        "search" => %{
          "path" => "/search",
          "inputs" => %{"q" => "{{ .Keywords }}"},
          "rows" => %{"selector" => "tr"},
          "fields" => %{
            "title" => %{"selector" => "td.title"},
            "size" => %{"selector" => "td.size"},
            "seeders" => %{"selector" => "td.seeders"}
          }
        }
      }

      assert {:ok, search} = CardigannParser.parse_search_config(yaml_data)
      assert length(search.paths) == 1
      assert hd(search.paths).path == "/search"
      assert is_map(search.inputs)
      assert is_map(search.rows)
      assert is_map(search.fields)
    end

    test "extracts search configuration with multiple paths" do
      yaml_data = %{
        "search" => %{
          "paths" => [
            %{"path" => "/browse", "categories" => [1, 2]},
            %{"path" => "/search", "method" => "post"}
          ],
          "inputs" => %{},
          "rows" => "tr",
          "fields" => %{
            "title" => "td:nth-child(1)",
            "size" => "td:nth-child(2)",
            "seeders" => "td:nth-child(3)"
          }
        }
      }

      assert {:ok, search} = CardigannParser.parse_search_config(yaml_data)
      assert length(search.paths) == 2
      assert Enum.at(search.paths, 0).categories == [1, 2]
      assert Enum.at(search.paths, 1).method == "post"
    end

    test "returns error when search path is missing" do
      yaml_data = %{
        "search" => %{
          "inputs" => %{},
          "rows" => "tr",
          "fields" => %{}
        }
      }

      assert {:error, :missing_search_path} = CardigannParser.parse_search_config(yaml_data)
    end

    test "returns error when rows selector is missing" do
      yaml_data = %{
        "search" => %{
          "path" => "/search",
          "inputs" => %{},
          "fields" => %{}
        }
      }

      assert {:error, :missing_rows_selector} = CardigannParser.parse_search_config(yaml_data)
    end

    test "returns error when fields are missing" do
      yaml_data = %{
        "search" => %{
          "path" => "/search",
          "inputs" => %{},
          "rows" => "tr"
        }
      }

      assert {:error, :missing_fields} = CardigannParser.parse_search_config(yaml_data)
    end
  end

  describe "parse_selectors/1" do
    test "parses simple string selectors" do
      fields = %{
        "title" => "div.title",
        "size" => "span.size"
      }

      assert {:ok, selectors} = CardigannParser.parse_selectors(fields)
      assert selectors.title.selector == "div.title"
      assert selectors.size.selector == "span.size"
    end

    test "parses complex selector objects with attributes" do
      fields = %{
        "download" => %{
          "selector" => "a.download",
          "attribute" => "href"
        },
        "category" => %{
          "selector" => "div.cat",
          "attribute" => "data-id",
          "filters" => [%{"name" => "trim"}]
        }
      }

      assert {:ok, selectors} = CardigannParser.parse_selectors(fields)
      assert selectors.download.selector == "a.download"
      assert selectors.download.attribute == "href"
      assert selectors.category.attribute == "data-id"
      assert is_list(selectors.category.filters)
    end

    test "handles selectors with filters" do
      fields = %{
        "title" => %{
          "selector" => "div.title",
          "filters" => [
            %{"name" => "trim"},
            %{"name" => "re_replace", "args" => ["pattern", "replacement"]}
          ]
        }
      }

      assert {:ok, selectors} = CardigannParser.parse_selectors(fields)
      assert length(selectors.title.filters) == 2
    end
  end

  describe "parse_login_config/1" do
    test "returns nil for public indexers without login" do
      yaml_data = %{"type" => "public"}
      assert {:ok, nil} = CardigannParser.parse_login_config(yaml_data)
    end

    test "parses form-based login configuration" do
      yaml_data = %{
        "login" => %{
          "method" => "form",
          "path" => "/login",
          "submitpath" => "/authenticate",
          "inputs" => %{
            "username" => "{{ .Config.username }}",
            "password" => "{{ .Config.password }}"
          },
          "error" => [%{"selector" => "div.error"}],
          "test" => %{"path" => "/", "selector" => "a.logout"}
        }
      }

      assert {:ok, login} = CardigannParser.parse_login_config(yaml_data)
      assert login.method == "form"
      assert login.path == "/login"
      assert login.submitpath == "/authenticate"
      assert is_map(login.inputs)
      assert is_list(login.error)
      assert is_map(login.test)
    end

    test "parses cookie-based login" do
      yaml_data = %{
        "login" => %{
          "method" => "cookie",
          "cookies" => ["session_id", "auth_token"]
        }
      }

      assert {:ok, login} = CardigannParser.parse_login_config(yaml_data)
      assert login.method == "cookie"
      assert login.cookies == ["session_id", "auth_token"]
    end

    test "returns error when login method is missing" do
      yaml_data = %{
        "login" => %{
          "path" => "/login"
        }
      }

      assert {:error, :missing_login_method} = CardigannParser.parse_login_config(yaml_data)
    end
  end

  describe "validate_definition/1" do
    test "validates successfully for complete definition" do
      assert {:ok, parsed} = CardigannParser.parse_definition(@minimal_public_indexer)
      assert :ok = CardigannParser.validate_definition(parsed)
    end

    test "returns error when required fields are missing" do
      parsed = %Parsed{
        id: "test",
        name: nil,
        description: "",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        links: [],
        capabilities: %{modes: %{}},
        search: %{
          paths: [],
          inputs: %{},
          rows: %{},
          fields: %{title: %{}, size: %{}, seeders: %{}}
        }
      }

      assert {:error, {:missing_required_fields, _}} =
               CardigannParser.validate_definition(parsed)
    end

    test "returns error when required search fields are missing" do
      assert {:ok, parsed} = CardigannParser.parse_definition(@minimal_public_indexer)

      # Remove required search field
      invalid_parsed = %{
        parsed
        | search: %{parsed.search | fields: %{title: %{selector: "div"}}}
      }

      assert {:error, {:missing_search_fields, missing}} =
               CardigannParser.validate_definition(invalid_parsed)

      assert :size in missing
      assert :seeders in missing
    end

    test "returns error when capabilities modes are missing" do
      assert {:ok, parsed} = CardigannParser.parse_definition(@minimal_public_indexer)
      invalid_parsed = %{parsed | capabilities: %{}}

      assert {:error, :missing_capabilities_modes} =
               CardigannParser.validate_definition(invalid_parsed)
    end
  end

  describe "complex selector parsing" do
    test "handles case transformations" do
      fields = %{
        "title" => %{
          "selector" => "div.title",
          "case" => "lower"
        }
      }

      assert {:ok, selectors} = CardigannParser.parse_selectors(fields)
      assert selectors.title.case == "lower"
    end

    test "handles remove parameter" do
      fields = %{
        "title" => %{
          "selector" => "div.title",
          "remove" => "span.tag"
        }
      }

      assert {:ok, selectors} = CardigannParser.parse_selectors(fields)
      assert selectors.title.remove == "span.tag"
    end

    test "handles all optional field types" do
      fields = %{
        "title" => "div.title",
        "size" => "div.size",
        "seeders" => "div.seed",
        "leechers" => "div.leech",
        "category" => "div.cat",
        "details" => %{"selector" => "a", "attribute" => "href"},
        "download" => %{"selector" => "a.dl", "attribute" => "href"},
        "magnet" => %{"selector" => "a.magnet", "attribute" => "href"},
        "date" => "div.date",
        "grabs" => "div.grabs",
        "imdb" => "div.imdb",
        "poster" => %{"selector" => "img", "attribute" => "src"}
      }

      assert {:ok, selectors} = CardigannParser.parse_selectors(fields)
      assert Map.has_key?(selectors, :title)
      assert Map.has_key?(selectors, :category)
      assert Map.has_key?(selectors, :details)
      assert Map.has_key?(selectors, :imdb)
      assert Map.has_key?(selectors, :poster)
    end
  end
end
