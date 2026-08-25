defmodule Mydia.Collections.SmartRulesTest do
  use Mydia.DataCase

  import Ecto.Query

  alias Mydia.Accounts.Scope
  alias Mydia.Collections.SmartRules
  alias Mydia.Media.MediaItem
  alias Mydia.Repo

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  # `auto_classify_media_item/1` overwrites whatever `category` a fixture is
  # given at creation, so tests that need a specific category force it after
  # the fact, same as `Mydia.Media.RestrictionsTest` and
  # `Mydia.Collections.RestrictedCollectionsTest`.
  defp categorized(category) do
    item = media_item_fixture(%{type: "movie"})

    Repo.update_all(from(m in MediaItem, where: m.id == ^item.id),
      set: [category: to_string(category)]
    )

    Repo.get!(MediaItem, item.id)
  end

  describe "validate/1" do
    test "validates empty rules" do
      assert {:ok, %{}} = SmartRules.validate(%{})
    end

    test "validates valid rules with conditions" do
      rules = %{
        "match_type" => "all",
        "conditions" => [
          %{"field" => "type", "operator" => "eq", "value" => "movie"}
        ]
      }

      assert {:ok, ^rules} = SmartRules.validate(rules)
    end

    test "validates JSON string input" do
      json = ~s({"match_type": "all", "conditions": []})
      assert {:ok, _} = SmartRules.validate(json)
    end

    test "returns error for invalid JSON" do
      assert {:error, ["Invalid JSON"]} = SmartRules.validate("not json")
    end

    test "returns error for invalid match_type" do
      rules = %{"match_type" => "invalid"}
      assert {:error, errors} = SmartRules.validate(rules)
      assert "match_type must be 'all' or 'any'" in errors
    end

    test "returns error for invalid field" do
      rules = %{
        "conditions" => [
          %{"field" => "invalid_field", "operator" => "eq", "value" => "test"}
        ]
      }

      assert {:error, errors} = SmartRules.validate(rules)
      assert Enum.any?(errors, &String.contains?(&1, "unknown field"))
    end

    test "returns error for invalid operator" do
      rules = %{
        "conditions" => [
          %{"field" => "type", "operator" => "invalid_op", "value" => "test"}
        ]
      }

      assert {:error, errors} = SmartRules.validate(rules)
      assert Enum.any?(errors, &String.contains?(&1, "unknown operator"))
    end

    test "returns error for missing value" do
      rules = %{
        "conditions" => [
          %{"field" => "type", "operator" => "eq"}
        ]
      }

      assert {:error, errors} = SmartRules.validate(rules)
      assert Enum.any?(errors, &String.contains?(&1, "value is required"))
    end

    test "returns error when 'in' operator has non-list value" do
      rules = %{
        "conditions" => [
          %{"field" => "type", "operator" => "in", "value" => "movie"}
        ]
      }

      assert {:error, errors} = SmartRules.validate(rules)
      assert Enum.any?(errors, &String.contains?(&1, "value must be a list"))
    end

    test "returns error when 'between' operator has invalid value" do
      rules = %{
        "conditions" => [
          %{"field" => "year", "operator" => "between", "value" => [2020]}
        ]
      }

      assert {:error, errors} = SmartRules.validate(rules)
      assert Enum.any?(errors, &String.contains?(&1, "[min, max]"))
    end

    test "validates sort options" do
      rules = %{
        "sort" => %{"field" => "title", "direction" => "asc"}
      }

      assert {:ok, _} = SmartRules.validate(rules)
    end

    test "returns error for invalid sort field" do
      rules = %{
        "sort" => %{"field" => "invalid_sort", "direction" => "asc"}
      }

      assert {:error, errors} = SmartRules.validate(rules)
      assert Enum.any?(errors, &String.contains?(&1, "sort.field"))
    end

    test "validates limit" do
      assert {:ok, _} = SmartRules.validate(%{"limit" => 100})
      assert {:error, _} = SmartRules.validate(%{"limit" => -1})
      assert {:error, _} = SmartRules.validate(%{"limit" => "invalid"})
    end
  end

  describe "execute_query/2" do
    test "returns all items when no conditions" do
      movie = media_item_fixture(%{type: "movie", title: "Test Movie"})

      rules = %{"match_type" => "all", "conditions" => []}
      items = SmartRules.execute_query!(rules)

      assert Enum.any?(items, &(&1.id == movie.id))
    end

    test "filters by type with eq operator" do
      movie = media_item_fixture(%{type: "movie", title: "Test Movie"})
      _tv_show = media_item_fixture(%{type: "tv_show", title: "Test Show"})

      rules = %{
        "match_type" => "all",
        "conditions" => [
          %{"field" => "type", "operator" => "eq", "value" => "movie"}
        ]
      }

      items = SmartRules.execute_query!(rules)

      assert length(items) == 1
      assert hd(items).id == movie.id
    end

    test "filters by type with in operator" do
      movie = media_item_fixture(%{type: "movie", title: "Test Movie"})
      tv_show = media_item_fixture(%{type: "tv_show", title: "Test Show"})

      rules = %{
        "match_type" => "all",
        "conditions" => [
          %{"field" => "type", "operator" => "in", "value" => ["movie", "tv_show"]}
        ]
      }

      items = SmartRules.execute_query!(rules)
      item_ids = Enum.map(items, & &1.id)

      assert movie.id in item_ids
      assert tv_show.id in item_ids
    end

    test "filters by year with gte operator" do
      recent = media_item_fixture(%{type: "movie", year: 2023})
      _old = media_item_fixture(%{type: "movie", year: 2010})

      rules = %{
        "match_type" => "all",
        "conditions" => [
          %{"field" => "year", "operator" => "gte", "value" => 2020}
        ]
      }

      items = SmartRules.execute_query!(rules)

      assert length(items) == 1
      assert hd(items).id == recent.id
    end

    test "filters by year with between operator" do
      in_range = media_item_fixture(%{type: "movie", year: 2015})
      _too_old = media_item_fixture(%{type: "movie", year: 2005})
      _too_new = media_item_fixture(%{type: "movie", year: 2025})

      rules = %{
        "match_type" => "all",
        "conditions" => [
          %{"field" => "year", "operator" => "between", "value" => [2010, 2020]}
        ]
      }

      items = SmartRules.execute_query!(rules)

      assert length(items) == 1
      assert hd(items).id == in_range.id
    end

    test "filters by title contains" do
      match = media_item_fixture(%{type: "movie", title: "Star Wars"})
      _no_match = media_item_fixture(%{type: "movie", title: "Lord of the Rings"})

      rules = %{
        "conditions" => [
          %{"field" => "title", "operator" => "contains", "value" => "Star"}
        ]
      }

      items = SmartRules.execute_query!(rules)

      assert length(items) == 1
      assert hd(items).id == match.id
    end

    test "filters by monitored status" do
      monitored = media_item_fixture(%{type: "movie", monitored: true})
      _unmonitored = media_item_fixture(%{type: "movie", monitored: false})

      rules = %{
        "conditions" => [
          %{"field" => "monitored", "operator" => "eq", "value" => true}
        ]
      }

      items = SmartRules.execute_query!(rules)

      assert Enum.all?(items, & &1.monitored)
      assert Enum.any?(items, &(&1.id == monitored.id))
    end

    test "uses AND matching with match_type=all" do
      match = media_item_fixture(%{type: "movie", year: 2023, monitored: true})
      _wrong_type = media_item_fixture(%{type: "tv_show", year: 2023, monitored: true})
      _wrong_year = media_item_fixture(%{type: "movie", year: 2010, monitored: true})

      rules = %{
        "match_type" => "all",
        "conditions" => [
          %{"field" => "type", "operator" => "eq", "value" => "movie"},
          %{"field" => "year", "operator" => "gte", "value" => 2020}
        ]
      }

      items = SmartRules.execute_query!(rules)

      assert length(items) == 1
      assert hd(items).id == match.id
    end

    test "uses OR matching with match_type=any" do
      movie = media_item_fixture(%{type: "movie", year: 2000})
      tv_show = media_item_fixture(%{type: "tv_show", year: 2023})
      _neither = media_item_fixture(%{type: "tv_show", year: 2000})

      rules = %{
        "match_type" => "any",
        "conditions" => [
          %{"field" => "type", "operator" => "eq", "value" => "movie"},
          %{"field" => "year", "operator" => "gte", "value" => 2020}
        ]
      }

      items = SmartRules.execute_query!(rules)
      item_ids = Enum.map(items, & &1.id)

      assert movie.id in item_ids
      assert tv_show.id in item_ids
    end

    test "applies limit" do
      for _ <- 1..5, do: media_item_fixture(%{type: "movie"})

      rules = %{"limit" => 3}
      items = SmartRules.execute_query!(rules)

      assert length(items) == 3
    end

    test "opts limit overrides rules limit" do
      for _ <- 1..5, do: media_item_fixture(%{type: "movie"})

      rules = %{"limit" => 10}
      items = SmartRules.execute_query!(rules, limit: 2)

      assert length(items) == 2
    end

    test "applies sort" do
      _item1 = media_item_fixture(%{type: "movie", title: "Zebra"})
      _item2 = media_item_fixture(%{type: "movie", title: "Apple"})

      rules = %{
        "sort" => %{"field" => "title", "direction" => "asc"}
      }

      items = SmartRules.execute_query!(rules)
      titles = Enum.map(items, & &1.title)

      assert titles == Enum.sort(titles)
    end

    test "handles JSON string input" do
      media_item_fixture(%{type: "movie"})

      json =
        ~s({"match_type": "all", "conditions": [{"field": "type", "operator": "eq", "value": "movie"}]})

      items = SmartRules.execute_query!(json)

      assert items != []
    end
  end

  describe "execute_count/1" do
    test "returns count of matching items" do
      for _ <- 1..3, do: media_item_fixture(%{type: "movie"})
      for _ <- 1..2, do: media_item_fixture(%{type: "tv_show"})

      rules = %{
        "conditions" => [
          %{"field" => "type", "operator" => "eq", "value" => "movie"}
        ]
      }

      count = SmartRules.execute_count(rules)
      assert count == 3
    end

    test "handles JSON string input" do
      media_item_fixture(%{type: "movie"})

      json = ~s({"conditions": []})
      count = SmartRules.execute_count(json)

      assert count >= 1
    end
  end

  describe "preview/2" do
    test "returns limited preview of items" do
      for _ <- 1..20, do: media_item_fixture(%{type: "movie"})

      rules = %{"conditions" => []}
      items = SmartRules.preview(rules, 5)

      assert length(items) == 5
    end
  end

  describe "scope filtering (execute_query!/3, execute_count/2, preview/3)" do
    test "execute_query!/3 excludes items outside the scope's allowed categories" do
      cartoon = categorized(:cartoon_movie)
      thriller = categorized(:movie)
      scope = Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))

      ids = %{"conditions" => []} |> SmartRules.execute_query!([], scope) |> Enum.map(& &1.id)

      assert cartoon.id in ids
      refute thriller.id in ids
    end

    test "execute_query!/3 with no scope (the default) returns everything, unfiltered" do
      cartoon = categorized(:cartoon_movie)
      thriller = categorized(:movie)

      ids = %{"conditions" => []} |> SmartRules.execute_query!() |> Enum.map(& &1.id)

      assert cartoon.id in ids
      assert thriller.id in ids
    end

    test "execute_count/2 counts only what the scope allows" do
      _cartoon = categorized(:cartoon_movie)
      _thriller = categorized(:movie)
      scope = Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))

      assert SmartRules.execute_count(%{"conditions" => []}, scope) == 1
    end

    test "execute_count/2 with no scope (the default) counts everything" do
      _cartoon = categorized(:cartoon_movie)
      _thriller = categorized(:movie)

      assert SmartRules.execute_count(%{"conditions" => []}) == 2
    end

    test "preview/3 previews only what the scope allows" do
      cartoon = categorized(:cartoon_movie)
      _thriller = categorized(:movie)
      scope = Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))

      assert [%{id: id}] = SmartRules.preview(%{"conditions" => []}, 10, scope)
      assert id == cartoon.id
    end

    test "a smart collection whose rules match the whole library still respects the scope" do
      cartoon = categorized(:cartoon_movie)
      thriller = categorized(:movie)
      scope = Scope.for_user(restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))

      # An empty condition list matches every media item in the library — the
      # exact "smart collection matches the whole library" scenario this task
      # exists to close off.
      ids =
        %{"match_type" => "all", "conditions" => []}
        |> SmartRules.execute_query!([], scope)
        |> Enum.map(& &1.id)

      assert cartoon.id in ids
      refute thriller.id in ids
    end
  end

  describe "metadata field queries" do
    test "filters by metadata.vote_average" do
      high_rated =
        media_item_fixture(%{type: "movie", metadata: %{"vote_average" => 8.5}})

      _low_rated =
        media_item_fixture(%{type: "movie", metadata: %{"vote_average" => 4.0}})

      rules = %{
        "conditions" => [
          %{"field" => "metadata.vote_average", "operator" => "gte", "value" => 7.0}
        ]
      }

      items = SmartRules.execute_query!(rules)

      assert length(items) == 1
      assert hd(items).id == high_rated.id
    end

    test "filters by metadata.genres contains" do
      action =
        media_item_fixture(%{type: "movie", metadata: %{"genres" => ["Action", "Thriller"]}})

      _comedy = media_item_fixture(%{type: "movie", metadata: %{"genres" => ["Comedy"]}})

      rules = %{
        "conditions" => [
          %{"field" => "metadata.genres", "operator" => "contains", "value" => "Action"}
        ]
      }

      items = SmartRules.execute_query!(rules)

      assert length(items) == 1
      assert hd(items).id == action.id
    end

    test "filters by metadata.original_language" do
      japanese = media_item_fixture(%{type: "movie", metadata: %{"original_language" => "ja"}})
      _english = media_item_fixture(%{type: "movie", metadata: %{"original_language" => "en"}})

      rules = %{
        "conditions" => [
          %{"field" => "metadata.original_language", "operator" => "eq", "value" => "ja"}
        ]
      }

      items = SmartRules.execute_query!(rules)

      assert length(items) == 1
      assert hd(items).id == japanese.id
    end
  end

  describe "helper functions" do
    test "valid_fields/0 returns list of valid fields" do
      fields = SmartRules.valid_fields()
      assert "type" in fields
      assert "year" in fields
      assert "metadata.vote_average" in fields
    end

    test "valid_operators/0 returns list of valid operators" do
      operators = SmartRules.valid_operators()
      assert "eq" in operators
      assert "gte" in operators
      assert "contains" in operators
    end
  end
end
