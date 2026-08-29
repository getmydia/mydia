defmodule Mydia.Collections.SmartRulesFieldsTest do
  use Mydia.DataCase, async: true

  import Mydia.MediaFixtures

  alias Mydia.Collections.SmartRulesFields

  setup do
    media_item_fixture(%{
      title: "Seeded Movie",
      metadata: %{
        genres: ["Action", "Drama"],
        original_language: "ja",
        status: "Released"
      }
    })

    :ok
  end

  test "genre_values/0 returns the distinct genres present in the library" do
    values = SmartRulesFields.genre_values()

    assert {"Action", "Action"} in values
    assert {"Drama", "Drama"} in values
  end

  test "language_values/0 maps a known code to its display name" do
    assert {"ja", "Japanese"} in SmartRulesFields.language_values()
  end

  test "status_values/0 returns the distinct statuses present in the library" do
    assert {"Released", "Released"} in SmartRulesFields.status_values()
  end

  test "every field definition with a value provider returns {value, label} pairs" do
    providers =
      for {name, %{values: fun}} <- SmartRulesFields.field_definitions(),
          is_function(fun, 0),
          do: name

    assert providers != [], "expected at least one field with a value provider"

    for name <- providers do
      values = SmartRulesFields.get_values(name)

      assert is_list(values), "#{name} did not return a list"

      for pair <- values do
        assert {value, label} = pair
        assert is_binary(value), "#{name} yielded a non-binary value: #{inspect(value)}"
        assert is_binary(label), "#{name} yielded a non-binary label: #{inspect(label)}"
      end
    end
  end

  describe "value_options/0" do
    test "returns options for every field that has a value provider" do
      options = SmartRulesFields.value_options()

      expected =
        for {name, %{values: fun}} <- SmartRulesFields.field_definitions(),
            is_function(fun, 0),
            do: name

      assert Enum.sort(Map.keys(options)) == Enum.sort(expected)
    end

    test "carries the values the individual providers return" do
      options = SmartRulesFields.value_options()

      assert {"Action", "Action"} in options["metadata.genres"]
      assert {"ja", "Japanese"} in options["metadata.original_language"]
      assert {"Released", "Released"} in options["metadata.status"]
    end

    test "omits fields that have no value provider" do
      options = SmartRulesFields.value_options()

      refute Map.has_key?(options, "year")
      refute Map.has_key?(options, "title")
      refute Map.has_key?(options, "inserted_at")
    end
  end
end
