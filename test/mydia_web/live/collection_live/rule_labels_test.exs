defmodule MydiaWeb.CollectionLive.RuleLabelsTest do
  use ExUnit.Case, async: true

  alias Mydia.Collections.SmartRules
  alias Mydia.Collections.SmartRulesFields
  alias MydiaWeb.CollectionLive.RuleLabels

  setup do
    Gettext.put_locale(MydiaWeb.Gettext, "en")
    :ok
  end

  describe "value_option/2" do
    test "matches the domain label for every fixed vocabulary" do
      for field <- ["type", "category", "monitored"],
          option <- SmartRulesFields.get_values(field) do
        assert RuleLabels.value_option(field, option) == option
      end
    end

    test "keeps the domain label for data-driven fields and unknown values" do
      assert RuleLabels.value_option("metadata.genres", {"Drama", "Drama"}) == {"Drama", "Drama"}

      assert RuleLabels.value_option("metadata.original_language", {"ja", "Japanese"}) ==
               {"ja", "Japanese"}

      assert RuleLabels.value_option("category", {"new_kind", "New kind"}) ==
               {"new_kind", "New kind"}
    end
  end

  describe "validation_error/1" do
    defp errors_for(rules) do
      assert {:error, errors} = SmartRules.validate(rules)
      errors
    end

    test "returns the domain sentence unchanged for every error the validator can raise" do
      cases = [
        "{not json",
        42,
        %{"match_type" => "some", "conditions" => "x", "sort" => "x", "limit" => 0},
        %{"sort" => %{"field" => "bogus", "direction" => "sideways"}},
        %{
          "conditions" => [
            "not a map",
            %{},
            %{"field" => "nope", "operator" => "nope", "value" => "x"},
            %{"field" => "year", "operator" => "in", "value" => 5},
            %{"field" => "year", "operator" => "between", "value" => [1]},
            %{"field" => "year", "operator" => "between", "value" => ["a", "b"]},
            %{"field" => "year", "operator" => "in", "value" => ["a"]},
            %{"field" => "year", "operator" => "eq", "value" => "a"},
            %{"field" => "title", "operator" => "eq", "value" => 5},
            %{"field" => "title", "operator" => "in", "value" => [5]},
            %{"field" => "monitored", "operator" => "eq", "value" => "yes"},
            %{"field" => "type", "operator" => "eq", "value" => "book"},
            %{"field" => "type", "operator" => "in", "value" => ["book"]},
            %{"field" => "year", "operator" => "within_last", "value" => 3},
            %{"field" => "inserted_at", "operator" => "within_last", "value" => -1}
          ]
        }
      ]

      errors = Enum.flat_map(cases, &errors_for/1)
      assert length(errors) > 15

      for error <- errors do
        assert RuleLabels.validation_error(error) == error
      end
    end

    test "passes an unknown error through" do
      assert RuleLabels.validation_error("something new broke") == "something new broke"

      assert RuleLabels.validation_error("conditions[0]: a new complaint") ==
               "conditions[0]: a new complaint"
    end
  end
end
