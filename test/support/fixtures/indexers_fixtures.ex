defmodule Mydia.IndexersFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Mydia.Indexers` context.
  """

  alias Mydia.Indexers.CardigannDefinition
  alias Mydia.Repo

  @doc """
  Generate a Cardigann definition.
  """
  def cardigann_definition_fixture(attrs \\ %{}) do
    indexer_id = "test-indexer-#{System.unique_integer([:positive])}"

    definition_attrs =
      Enum.into(attrs, %{
        indexer_id: indexer_id,
        name: "Test Indexer #{indexer_id}",
        description: "A test indexer definition",
        language: "en-US",
        type: "public",
        encoding: "UTF-8",
        links: %{"website" => "https://example.com"},
        capabilities: %{
          "categories" => ["Movies", "TV"],
          "modes" => %{"search" => ["q"]}
        },
        definition: """
        ---
        id: #{indexer_id}
        name: Test Indexer
        description: Test indexer definition
        language: en-US
        type: public
        encoding: UTF-8
        links:
          - https://example.com
        caps:
          categories:
            1: Movies
            2: TV
          modes:
            search: [q]
        search:
          path: /search
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
        """,
        schema_version: "11",
        enabled: false,
        config: nil,
        last_synced_at: DateTime.utc_now()
      })

    %CardigannDefinition{}
    |> CardigannDefinition.changeset(definition_attrs)
    |> Repo.insert!()
  end
end
