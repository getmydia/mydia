defmodule Mydia.Indexers.CardigannGoldenDefinitionsTest do
  @moduledoc """
  Golden definition tests for popular public trackers.

  Fetches definitions for well-known indexers from upstream and validates
  that our parser handles them correctly, checking specific structural
  properties that we know should be present.

  Tagged as :external since it requires GitHub API access.
  """
  use ExUnit.Case

  @moduletag :external

  alias Mydia.Indexers.DefinitionSync
  alias Mydia.Indexers.CardigannParser

  @github_raw_base "https://raw.githubusercontent.com/Prowlarr/Indexers/main/definitions/v11"

  # Popular public trackers we want to ensure work
  @golden_definitions [
    {"1337x.yml", "1337x",
     %{type: "public", language: "en-US", has_download: true, min_fields: 5}},
    {"thepiratebay.yml", "thepiratebay",
     %{type: "public", language: "en-US", has_download: true, min_fields: 4}},
    {"nyaasi.yml", "nyaasi",
     %{type: "public", language: "en-US", has_download: true, min_fields: 4}},
    {"eztv.yml", "eztv", %{type: "public", language: "en-US", has_download: true, min_fields: 4}},
    {"limetorrents.yml", "limetorrents",
     %{type: "public", language: "en-US", has_download: true, min_fields: 4}},
    {"yts.yml", "yts", %{type: "public", language: "en-US", has_download: true, min_fields: 4}},
    {"torrentgalaxy.yml", "torrentgalaxy",
     %{type: "public", language: "en-US", has_download: true, min_fields: 5}},
    {"kickasstorrents-ws.yml", "kickasstorrents-ws",
     %{type: "public", language: "en-US", has_download: true, min_fields: 4}},
    {"solidtorrents.yml", "solidtorrents",
     %{type: "public", language: "en-US", has_download: true, min_fields: 4}},
    {"glodls.yml", "glodls",
     %{type: "public", language: "en-US", has_download: true, min_fields: 4}},
    {"anidex.yml", "anidex",
     %{type: "public", language: "en-US", has_download: true, min_fields: 4}},
    {"bitsearch.yml", "bitsearch",
     %{type: "public", language: "en-US", has_download: true, min_fields: 4}}
  ]

  for {filename, id, expectations} <- @golden_definitions do
    @tag timeout: 30_000
    test "#{id} definition parses correctly" do
      filename = unquote(filename)
      expected_id = unquote(id)
      expectations = unquote(Macro.escape(expectations))

      url = "#{@github_raw_base}/#{filename}"

      case DefinitionSync.fetch_definition_file(url) do
        {:ok, yaml} ->
          case CardigannParser.parse_definition(yaml) do
            {:ok, parsed} ->
              # Verify basic identity
              assert parsed.id == expected_id,
                     "Expected id #{expected_id}, got #{parsed.id}"

              # Verify type
              assert parsed.type == expectations.type,
                     "Expected type #{expectations.type}, got #{parsed.type}"

              # Verify language
              assert parsed.language == expectations.language,
                     "Expected language #{expectations.language}, got #{parsed.language}"

              # Verify search fields exist
              field_count = map_size(parsed.search.fields)

              assert field_count >= expectations.min_fields,
                     "Expected >= #{expectations.min_fields} search fields, got #{field_count}: #{inspect(Map.keys(parsed.search.fields))}"

              # Verify essential search fields
              assert Map.has_key?(parsed.search.fields, :title),
                     "Missing :title field"

              assert Map.has_key?(parsed.search.fields, :seeders),
                     "Missing :seeders field"

              # Verify search paths exist
              assert parsed.search.paths != [],
                     "No search paths configured"

              # Verify rows selector exists
              assert parsed.search.rows != nil,
                     "No rows selector configured"

              assert Map.has_key?(parsed.search.rows, :selector),
                     "Rows selector missing :selector"

              # Verify download config if expected
              if expectations.has_download do
                assert parsed.download != nil or
                         Map.has_key?(parsed.search.fields, :download),
                       "Expected download configuration"
              end

              # Verify capabilities
              assert parsed.capabilities != nil, "Missing capabilities"
              assert Map.has_key?(parsed.capabilities, :modes), "Missing capabilities modes"

            {:error, reason} ->
              flunk("Failed to parse #{filename}: #{inspect(reason)}")
          end

        {:error, reason} ->
          IO.puts("Skipping #{filename}: fetch failed - #{inspect(reason)}")
      end
    end
  end
end
