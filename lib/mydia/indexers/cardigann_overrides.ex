defmodule Mydia.Indexers.CardigannOverrides do
  @moduledoc """
  Provides patches for known bugs in upstream Cardigann/Prowlarr definitions.

  This module allows shipping fixes for indexer definitions without waiting for
  upstream fixes. Patches are applied during definition parsing, before the
  YAML is converted to a Parsed struct.

  ## Adding a New Override

  1. Add a new entry to `@overrides` with the indexer ID as key
  2. Define a patch function that modifies the YAML map
  3. Document the issue and fix in the patch

  ## Example

      @overrides %{
        "example-indexer" => %{
          description: "Fix broken search path",
          issue_url: "https://github.com/Prowlarr/Prowlarr/issues/1234",
          patch: &__MODULE__.patch_example_indexer/1
        }
      }

      def patch_example_indexer(yaml_data) do
        put_in(yaml_data, ["search", "path"], "/fixed/path/")
      end
  """

  require Logger

  @type patch_entry :: %{
          description: String.t(),
          issue_url: String.t() | nil,
          added_date: String.t(),
          patch: (map() -> map())
        }

  @type overrides :: %{String.t() => patch_entry()}

  # Registry of all known overrides
  # Key: indexer_id (e.g., "1337x")
  # Value: patch metadata and function
  @overrides %{
    "1337x" => %{
      description: "Fix broken sort-search URL format - use /search/ instead",
      issue_url: nil,
      added_date: "2024-11-28",
      patch: &__MODULE__.patch_1337x/1
    }
  }

  @doc """
  Returns the list of all registered overrides.
  """
  @spec list_overrides() :: overrides()
  def list_overrides, do: @overrides

  @doc """
  Checks if an override exists for the given indexer ID.
  """
  @spec has_override?(String.t()) :: boolean()
  def has_override?(indexer_id) do
    Map.has_key?(@overrides, indexer_id)
  end

  @doc """
  Gets override metadata for an indexer (without applying the patch).
  """
  @spec get_override(String.t()) :: patch_entry() | nil
  def get_override(indexer_id) do
    Map.get(@overrides, indexer_id)
  end

  @doc """
  Applies any registered patches to the YAML data for the given indexer.

  Returns the modified YAML data, or the original if no patches exist.

  ## Parameters

  - `indexer_id` - The indexer's ID (e.g., "1337x")
  - `yaml_data` - The parsed YAML data as a map

  ## Returns

  - `{:ok, yaml_data}` - The patched YAML data
  - `{:ok, yaml_data, :patched}` - The patched YAML data with indicator
  """
  @spec apply_overrides(String.t(), map()) :: {:ok, map()} | {:ok, map(), :patched}
  def apply_overrides(indexer_id, yaml_data) when is_map(yaml_data) do
    case Map.get(@overrides, indexer_id) do
      nil ->
        {:ok, yaml_data}

      %{patch: patch_fn, description: description} ->
        Logger.info("[CardigannOverrides] Applying patch for #{indexer_id}: #{description}")

        patched_data = patch_fn.(yaml_data)
        {:ok, patched_data, :patched}
    end
  end

  @doc """
  Applies overrides and returns just the data (for pipeline usage).
  """
  @spec apply_overrides!(String.t(), map()) :: map()
  def apply_overrides!(indexer_id, yaml_data) do
    case apply_overrides(indexer_id, yaml_data) do
      {:ok, data} -> data
      {:ok, data, :patched} -> data
    end
  end

  # ============================================================================
  # Patch Functions
  # ============================================================================

  @doc """
  Patch for 1337x: Fix broken sort-search URL format.

  The upstream definition uses `/sort-search/{query}/{sort}/{order}/{page}/` which
  returns "Error something went wrong" from 1337x. The working format is
  `/search/{query}/{page}/` without sorting parameters.

  This patch replaces the complex path templates with simpler working versions.
  Note: This means sorting options will be ignored, but at least searches work.
  """
  @spec patch_1337x(map()) :: map()
  def patch_1337x(yaml_data) do
    # The original paths use sort-search which is broken on 1337x.
    # We replace them with simple /search/ paths that work.
    # Original format: sort-search/query/sort/order/page/
    # Working format: search/query/page/
    #
    # The original definition has 4 paths for different pages (1-4) to spread
    # results across categories. We preserve this structure but use /search/.
    patched_paths = [
      %{
        "path" =>
          "{{ if or .Query.Album .Query.Artist .Keywords }}search/{{ or .Query.Album .Query.Artist .Keywords }}/1/{{ else }}cat/Movies/{{ .Config.sort }}/{{ .Config.type }}/1/{{ end }}"
      },
      %{
        "path" =>
          "{{ if or .Query.Album .Query.Artist .Keywords }}search/{{ or .Query.Album .Query.Artist .Keywords }}/2/{{ else }}cat/TV/{{ .Config.sort }}/{{ .Config.type }}/1/{{ end }}"
      },
      %{
        "path" =>
          "{{ if or .Query.Album .Query.Artist .Keywords }}search/{{ or .Query.Album .Query.Artist .Keywords }}/3/{{ else }}cat/Music/{{ .Config.sort }}/{{ .Config.type }}/1/{{ end }}"
      },
      %{
        "path" =>
          "{{ if or .Query.Album .Query.Artist .Keywords }}search/{{ or .Query.Album .Query.Artist .Keywords }}/4/{{ else }}cat/Other/{{ .Config.sort }}/{{ .Config.type }}/1/{{ end }}"
      }
    ]

    put_in(yaml_data, ["search", "paths"], patched_paths)
  end
end
