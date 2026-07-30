defmodule Mydia.Indexers.CardigannParserIntegrationTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.CardigannParser
  alias Mydia.Indexers.CardigannDefinition.Parsed

  @moduletag :external

  @sample_definitions [
    {"1337x",
     "https://raw.githubusercontent.com/Prowlarr/Indexers/master/definitions/v11/1337x.yml"},
    {"thepiratebay",
     "https://raw.githubusercontent.com/Prowlarr/Indexers/master/definitions/v11/thepiratebay.yml"},
    {"Bittorrentfiles",
     "https://raw.githubusercontent.com/Prowlarr/Indexers/master/definitions/v11/Bittorrentfiles.yml"}
  ]

  describe "parse_definition/1 with real definitions" do
    for {name, url} <- @sample_definitions do
      @tag :external
      test "parses #{name} definition from GitHub successfully" do
        indexer_name = unquote(name)
        url = unquote(url)

        yaml_content = fetch_definition(url)
        assert {:ok, %Parsed{} = parsed} = CardigannParser.parse_definition(yaml_content)

        # Validate basic structure
        assert is_binary(parsed.id)
        assert is_binary(parsed.name)
        assert is_binary(parsed.description)
        assert is_binary(parsed.language)
        assert parsed.type in ["public", "private", "semi-private"]
        assert is_list(parsed.links)
        assert parsed.links != []

        # Validate capabilities
        assert is_map(parsed.capabilities)
        assert is_map(parsed.capabilities.modes)
        assert Map.has_key?(parsed.capabilities.modes, "search")

        # Validate search configuration
        assert is_map(parsed.search)
        assert is_list(parsed.search.paths)
        assert parsed.search.paths != []
        assert is_map(parsed.search.fields)

        # Validate required search fields are present
        assert Map.has_key?(parsed.search.fields, :title)
        assert Map.has_key?(parsed.search.fields, :size)
        assert Map.has_key?(parsed.search.fields, :seeders)

        # Additional validation
        assert :ok = CardigannParser.validate_definition(parsed)

        # Log some info for debugging
        IO.puts("\n=== Successfully parsed #{indexer_name} ===")
        IO.puts("  ID: #{parsed.id}")
        IO.puts("  Name: #{parsed.name}")
        IO.puts("  Type: #{parsed.type}")
        IO.puts("  Links: #{Enum.join(parsed.links, ", ")}")
        IO.puts("  Search paths: #{length(parsed.search.paths)}")
        IO.puts("  Has login: #{not is_nil(parsed.login)}")
        IO.puts("  Settings: #{length(parsed.settings)}")
      end
    end
  end

  defp fetch_definition(url) do
    case Req.get(url) do
      {:ok, %{status: 200, body: body}} ->
        body

      {:ok, response} ->
        raise "Failed to fetch definition: HTTP #{response.status}"

      {:error, error} ->
        raise "Failed to fetch definition: #{inspect(error)}"
    end
  end
end
