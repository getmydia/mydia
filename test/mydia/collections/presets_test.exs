defmodule Mydia.Collections.PresetsTest do
  # Guards the preset catalog against three failures that are invisible until a
  # user clicks the preset: rules that do not validate, rules that validate but
  # have no matching build_dynamic/3 clause and raise at query time, and icons
  # outside the Tailwind safelist that render as blank boxes.
  use Mydia.DataCase, async: true

  alias Mydia.Collections.Collection
  alias Mydia.Collections.Preset
  alias Mydia.Collections.Presets
  alias Mydia.Collections.SmartRules

  test "the catalog is not empty" do
    assert Presets.list() != []
  end

  test "every preset validates" do
    for %Preset{} = preset <- Presets.list() do
      assert {:ok, _} = SmartRules.validate(preset.rules),
             "preset #{preset.key} has rules that do not validate"
    end
  end

  test "every preset executes without raising" do
    # validate/1 checks the field and operator names against allowlists, but
    # build_dynamic/3 is a set of specific clauses. A field and operator pair
    # that validates without a matching clause raises FunctionClauseError only
    # when the query is built, which is when a user clicks the preset.
    for %Preset{} = preset <- Presets.list() do
      assert is_integer(SmartRules.execute_count(preset.rules)),
             "preset #{preset.key} raised when its query was built"
    end
  end

  test "keys are unique" do
    keys = Enum.map(Presets.list(), & &1.key)
    assert keys == Enum.uniq(keys)
  end

  test "every preset's group is listed in groups/0" do
    groups = Presets.groups()

    for %Preset{} = preset <- Presets.list() do
      assert preset.group in groups,
             "preset #{preset.key} has group #{inspect(preset.group)}, which groups/0 omits"
    end
  end

  test "every group in groups/0 has at least one preset" do
    used = Presets.list() |> Enum.map(& &1.group) |> Enum.uniq()

    for group <- Presets.groups() do
      assert group in used, "groups/0 lists #{inspect(group)} but no preset uses it"
    end
  end

  test "every preset icon is a valid sidebar icon" do
    # Preset icons live in lib/mydia/, outside the @source globs in app.css, so
    # Tailwind never sees the class name. Reusing the sidebar allowlist means
    # the existing safelist and its drift test already cover them.
    valid = Collection.valid_sidebar_icons()

    for %Preset{} = preset <- Presets.list() do
      assert preset.icon in valid,
             "preset #{preset.key} uses icon #{preset.icon}, which is not in Collection.valid_sidebar_icons/0"
    end
  end

  test "get/1 finds a preset by key and returns nil for an unknown key" do
    known = Presets.list() |> List.first()

    assert %Preset{} = found = Presets.get(known.key)
    assert found.key == known.key
    assert Presets.get("no_such_preset") == nil
  end
end
