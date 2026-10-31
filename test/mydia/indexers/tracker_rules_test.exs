defmodule Mydia.Indexers.TrackerRulesTest do
  use Mydia.DataCase, async: false

  alias Mydia.Indexers.Structs.TrackerTerms
  alias Mydia.Indexers.TrackerRules
  alias Mydia.Settings
  alias Mydia.Settings.{TrackerRuleConfig, TrackerRuleConfigs}

  defp rule(attrs), do: struct!(TrackerRuleConfig, Map.merge(%{tracker: "Velvet Lantern"}, attrs))

  describe "effective/3 precedence" do
    # {override, reported, expected} per field. Seed time overrides are in
    # minutes and the terms are in seconds.
    @ratio_cases [
      {2.0, 1.0, 2.0},
      {nil, 1.0, 1.0},
      {2.0, nil, 2.0},
      {nil, nil, nil}
    ]
    @seed_time_cases [
      {60, 7200, 3600},
      {nil, 7200, 7200},
      {60, nil, 3600},
      {nil, nil, nil}
    ]
    @private_cases [
      {true, false, true},
      {false, true, false},
      {nil, true, true},
      {true, nil, true},
      {nil, nil, nil}
    ]

    test "minimum ratio: override, then reported, then nil" do
      for {override, reported, expected} <- @ratio_cases do
        rules = [rule(%{seed_ratio: override})]
        terms = %TrackerTerms{minimum_ratio: reported}

        assert field(TrackerRules.effective(terms, "Velvet Lantern", rules), :minimum_ratio) ==
                 expected,
               "override #{inspect(override)}, reported #{inspect(reported)}"
      end
    end

    test "minimum seed time: override in minutes, then reported seconds, then nil" do
      for {override, reported, expected} <- @seed_time_cases do
        rules = [rule(%{seed_time: override})]
        terms = %TrackerTerms{minimum_seed_time: reported}

        assert field(TrackerRules.effective(terms, "Velvet Lantern", rules), :minimum_seed_time) ==
                 expected
      end
    end

    test "private: override, then reported, then nil" do
      for {override, reported, expected} <- @private_cases do
        rules = [rule(%{private: override})]
        terms = %TrackerTerms{private?: reported}

        assert field(TrackerRules.effective(terms, "Velvet Lantern", rules), :private?) ==
                 expected
      end
    end

    test "volume factors pass through untouched" do
      terms = %TrackerTerms{download_volume_factor: 0.0, upload_volume_factor: 2.0}

      assert %TrackerTerms{download_volume_factor: +0.0, upload_volume_factor: 2.0} =
               TrackerRules.effective(terms, "Velvet Lantern", [rule(%{seed_ratio: 1.0})])
    end

    test "a tracker with no rule keeps its reported terms, and nil stays nil" do
      terms = %TrackerTerms{minimum_ratio: 1.0}
      assert TrackerRules.effective(terms, "Open Reel", [rule(%{seed_ratio: 3.0})]) == terms
      assert TrackerRules.effective(nil, "Open Reel", []) == nil
    end

    test "an override alone produces terms for a tracker that reported none" do
      assert %TrackerTerms{minimum_ratio: 1.5, private?: true} =
               TrackerRules.effective(nil, "Velvet Lantern", [
                 rule(%{seed_ratio: 1.5, private: true})
               ])
    end

    test "tracker names match case-insensitively and ignore surrounding space" do
      rules = [rule(%{tracker: "  VELVET lantern ", seed_ratio: 1.5})]

      assert %TrackerTerms{minimum_ratio: 1.5} =
               TrackerRules.effective(nil, "Velvet Lantern", rules)
    end
  end

  describe "list_rules/0" do
    setup do
      original = Application.get_env(:mydia, :runtime_config)

      on_exit(fn ->
        if original,
          do: Application.put_env(:mydia, :runtime_config, original),
          else: Application.delete_env(:mydia, :runtime_config)
      end)

      runtime = %{
        Mydia.Config.Schema.defaults()
        | tracker_rules: [
            %Mydia.Config.Schema.TrackerRule{tracker: "Velvet Lantern", seed_ratio: 1.0},
            %Mydia.Config.Schema.TrackerRule{tracker: "Copper Reel", seed_time: 120}
          ]
      }

      Application.put_env(:mydia, :runtime_config, runtime)
      :ok
    end

    test "a database rule shadows a runtime rule for the same tracker in any case" do
      {:ok, _} =
        TrackerRuleConfigs.create(%{tracker: "velvet LANTERN", seed_ratio: 2.0})

      rules = TrackerRules.list_rules()

      assert [%TrackerRuleConfig{tracker: "Copper Reel", seed_time: 120} = copper] =
               Enum.filter(rules, &(&1.tracker == "Copper Reel"))

      assert Settings.runtime_config?(copper)

      assert [%TrackerRuleConfig{seed_ratio: 2.0} = velvet] =
               Enum.filter(rules, &(TrackerRules.key(&1.tracker) == "velvet lantern"))

      refute Settings.runtime_config?(velvet)
    end

    test "a database rule keeps the runtime rule's value for every field it leaves empty" do
      runtime = Application.get_env(:mydia, :runtime_config)

      Application.put_env(:mydia, :runtime_config, %{
        runtime
        | tracker_rules: [
            %Mydia.Config.Schema.TrackerRule{
              tracker: "Velvet Lantern",
              seed_ratio: 1.0,
              grab_limit: 5
            }
          ]
      })

      {:ok, _} = TrackerRuleConfigs.create(%{tracker: "velvet lantern", seed_time: 4320})

      assert [%TrackerRuleConfig{seed_time: 4320, seed_ratio: 1.0, grab_limit: 5} = velvet] =
               TrackerRules.list_rules()

      refute Settings.runtime_config?(velvet)
    end

    test "tracker names are unique case-insensitively in the database" do
      {:ok, _} = TrackerRuleConfigs.create(%{tracker: "Velvet Lantern"})

      assert {:error, changeset} =
               TrackerRuleConfigs.create(%{tracker: "VELVET LANTERN", seed_ratio: 1.0})

      assert %{tracker: [_]} = errors_on(changeset)
    end

    test "a rule needs a tracker and non-negative numbers" do
      assert {:error, changeset} =
               TrackerRuleConfigs.create(%{tracker: "", seed_ratio: -1, seed_time: -5})

      errors = errors_on(changeset)
      assert errors.tracker
      assert errors.seed_ratio
      assert errors.seed_time
    end
  end

  defp field(nil, _key), do: nil
  defp field(terms, key), do: Map.fetch!(terms, key)
end
