defmodule Mydia.Indexers.CardigannDefinitionTest do
  use Mydia.DataCase, async: true

  alias Mydia.Indexers.CardigannDefinition
  alias Mydia.Indexers

  describe "flaresolverr_changeset/2" do
    setup do
      definition =
        insert_cardigann_definition(%{
          indexer_id: "test-indexer-#{System.unique_integer()}",
          name: "Test Indexer",
          type: "public",
          links: %{"homepage" => "https://example.com"},
          capabilities: %{},
          definition: "test: definition",
          schema_version: "v1"
        })

      %{definition: definition}
    end

    test "updates flaresolverr_required", %{definition: definition} do
      changeset =
        CardigannDefinition.flaresolverr_changeset(definition, %{flaresolverr_required: true})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :flaresolverr_required) == true
    end

    test "updates flaresolverr_enabled", %{definition: definition} do
      changeset =
        CardigannDefinition.flaresolverr_changeset(definition, %{flaresolverr_enabled: true})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :flaresolverr_enabled) == true
    end

    test "updates both fields together", %{definition: definition} do
      changeset =
        CardigannDefinition.flaresolverr_changeset(definition, %{
          flaresolverr_required: true,
          flaresolverr_enabled: true
        })

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :flaresolverr_required) == true
      assert Ecto.Changeset.get_change(changeset, :flaresolverr_enabled) == true
    end
  end

  describe "use_flaresolverr?/1" do
    test "returns true when required and enabled" do
      definition = %CardigannDefinition{
        flaresolverr_required: true,
        flaresolverr_enabled: true
      }

      assert CardigannDefinition.use_flaresolverr?(definition) == true
    end

    test "returns false when required but explicitly disabled" do
      definition = %CardigannDefinition{
        flaresolverr_required: true,
        flaresolverr_enabled: false
      }

      assert CardigannDefinition.use_flaresolverr?(definition) == false
    end

    test "returns false when not required" do
      definition = %CardigannDefinition{
        flaresolverr_required: false,
        flaresolverr_enabled: true
      }

      assert CardigannDefinition.use_flaresolverr?(definition) == false
    end

    test "returns false when neither required nor enabled" do
      definition = %CardigannDefinition{
        flaresolverr_required: false,
        flaresolverr_enabled: false
      }

      assert CardigannDefinition.use_flaresolverr?(definition) == false
    end
  end

  describe "Indexers.update_flaresolverr_settings/2" do
    setup do
      definition =
        insert_cardigann_definition(%{
          indexer_id: "fs-test-#{System.unique_integer()}",
          name: "FS Test Indexer",
          type: "public",
          links: %{"homepage" => "https://example.com"},
          capabilities: %{},
          definition: "test: definition",
          schema_version: "v1"
        })

      %{definition: definition}
    end

    test "updates flaresolverr settings", %{definition: definition} do
      {:ok, updated} =
        Indexers.update_flaresolverr_settings(definition, %{
          flaresolverr_required: true,
          flaresolverr_enabled: true
        })

      assert updated.flaresolverr_required == true
      assert updated.flaresolverr_enabled == true
    end
  end

  describe "Indexers.set_flaresolverr_required/2" do
    setup do
      definition =
        insert_cardigann_definition(%{
          indexer_id: "fs-req-#{System.unique_integer()}",
          name: "FS Required Test",
          type: "public",
          links: %{"homepage" => "https://example.com"},
          capabilities: %{},
          definition: "test: definition",
          schema_version: "v1"
        })

      %{definition: definition}
    end

    test "sets flaresolverr_required to true", %{definition: definition} do
      {:ok, updated} = Indexers.set_flaresolverr_required(definition, true)
      assert updated.flaresolverr_required == true
    end

    test "sets flaresolverr_required to false", %{definition: definition} do
      # First set to true
      {:ok, updated} = Indexers.set_flaresolverr_required(definition, true)
      assert updated.flaresolverr_required == true

      # Then set to false
      {:ok, updated2} = Indexers.set_flaresolverr_required(updated, false)
      assert updated2.flaresolverr_required == false
    end
  end

  describe "Indexers.list_flaresolverr_enabled_definitions/0" do
    test "returns only definitions with flaresolverr_enabled" do
      # Create a definition with FlareSolverr enabled
      _enabled =
        insert_cardigann_definition(%{
          indexer_id: "fs-enabled-#{System.unique_integer()}",
          name: "FS Enabled",
          type: "public",
          links: %{"homepage" => "https://example.com"},
          capabilities: %{},
          definition: "test: definition",
          schema_version: "v1",
          flaresolverr_enabled: true
        })

      # Create a definition without FlareSolverr enabled
      _disabled =
        insert_cardigann_definition(%{
          indexer_id: "fs-disabled-#{System.unique_integer()}",
          name: "FS Disabled",
          type: "public",
          links: %{"homepage" => "https://example.com"},
          capabilities: %{},
          definition: "test: definition",
          schema_version: "v1",
          flaresolverr_enabled: false
        })

      results = Indexers.list_flaresolverr_enabled_definitions()

      assert Enum.any?(results, &(&1.name == "FS Enabled"))
      refute Enum.any?(results, &(&1.name == "FS Disabled"))
    end
  end

  describe "Indexers.list_flaresolverr_required_definitions/0" do
    test "returns only definitions with flaresolverr_required" do
      # Create a definition with FlareSolverr required
      _required =
        insert_cardigann_definition(%{
          indexer_id: "fs-required-#{System.unique_integer()}",
          name: "FS Required",
          type: "public",
          links: %{"homepage" => "https://example.com"},
          capabilities: %{},
          definition: "test: definition",
          schema_version: "v1",
          flaresolverr_required: true
        })

      # Create a definition without FlareSolverr required
      _not_required =
        insert_cardigann_definition(%{
          indexer_id: "fs-not-required-#{System.unique_integer()}",
          name: "FS Not Required",
          type: "public",
          links: %{"homepage" => "https://example.com"},
          capabilities: %{},
          definition: "test: definition",
          schema_version: "v1",
          flaresolverr_required: false
        })

      results = Indexers.list_flaresolverr_required_definitions()

      assert Enum.any?(results, &(&1.name == "FS Required"))
      refute Enum.any?(results, &(&1.name == "FS Not Required"))
    end
  end

  describe "changeset/2" do
    test "casts active_link and link_status" do
      attrs = %{
        indexer_id: "link-test",
        name: "Link Test",
        type: "public",
        links: %{"0" => "https://a.example.com"},
        capabilities: %{},
        definition: "id: link-test",
        schema_version: "v11",
        active_link: "https://b.example.com",
        link_status: %{
          "https://a.example.com" => %{"ok" => false, "checked_at" => "2026-08-12T00:00:00Z"},
          "https://b.example.com" => %{"ok" => true, "checked_at" => "2026-08-12T00:00:00Z"}
        }
      }

      changeset = CardigannDefinition.changeset(%CardigannDefinition{}, attrs)

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :active_link) == "https://b.example.com"
      assert map_size(Ecto.Changeset.get_field(changeset, :link_status)) == 2
    end

    test "active_link and link_status are optional" do
      attrs = %{
        indexer_id: "link-test-2",
        name: "Link Test 2",
        type: "public",
        links: %{"0" => "https://a.example.com"},
        capabilities: %{},
        definition: "id: link-test-2",
        schema_version: "v11"
      }

      changeset = CardigannDefinition.changeset(%CardigannDefinition{}, attrs)
      assert changeset.valid?
    end
  end

  # Helper function to insert a Cardigann definition
  defp insert_cardigann_definition(attrs) do
    %CardigannDefinition{}
    |> CardigannDefinition.changeset(attrs)
    |> Mydia.Repo.insert!()
  end
end
