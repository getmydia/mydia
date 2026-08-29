defmodule Mydia.Indexers.CardigannPathCorpusTest do
  @moduledoc """
  Renders every `search.paths` entry shipped under test/fixtures/cardigann
  against a query containing the two characters that broke 1337x, and asserts
  the result is a legal URI.

  This test earns its keep only because it renders the REAL path templates with
  a REALISTIC query. Compare the ReleaseParser parity and corpus suites, which
  stayed green through six rounds of a broken feature because they exercised the
  unbound form of the function under test and were structurally blind to the
  behavior in question. A version of this test that asserted on the parsed
  definition structure instead of on rendered output would stay green through
  exactly the bug it exists to catch.

  URI.new/1 is the assertion because it rejects precisely what Mint rejects:
  URI.new("search/a b/1/") returns {:error, " "} while
  URI.new("search/a%20b/1/") succeeds, and it splits an inline query string
  (KickassTorrents ships "search/?q={{ .Keywords }}") rather than tripping on
  the reserved characters inside it.
  """
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.TemplateContext
  alias Mydia.Indexers.{CardigannParser, CardigannTemplate}

  # Space broke 1337x. Colon and the hyphen come from the same reported title.
  @query "Spider-Man: Brand New Day 2026"

  definition_files =
    "test/fixtures/cardigann/*/definition.yml"
    |> Path.wildcard()
    |> Enum.sort()

  # Fail loudly rather than vacuously passing if the fixture layout ever moves.
  test "the fixture corpus is not empty" do
    assert Path.wildcard("test/fixtures/cardigann/*/definition.yml") != []
  end

  for file <- definition_files do
    @definition_file file
    @indexer_name file |> Path.dirname() |> Path.basename()

    test "every search path in #{@indexer_name} renders to a legal URI" do
      yaml = File.read!(@definition_file)

      assert {:ok, parsed} = CardigannParser.parse_definition(yaml),
             "#{@definition_file} failed to parse"

      context =
        TemplateContext.build(parsed, query: @query, categories: [2000], config: %{})

      parsed.search
      |> Map.get(:paths, [])
      |> Enum.with_index()
      |> Enum.each(fn {search_path, index} ->
        template = Map.get(search_path, :path) || Map.get(search_path, "path")

        assert is_binary(template),
               "#{@indexer_name} path #{index} has no path template"

        assert {:ok, rendered} = CardigannTemplate.render(template, context),
               "#{@indexer_name} path #{index} failed to render: #{inspect(template)}"

        assert {:ok, _uri} = URI.new(rendered),
               "#{@indexer_name} path #{index} rendered an illegal URI: " <>
                 "#{inspect(rendered)} (from #{inspect(template)})"
      end)
    end
  end
end
