defmodule Mydia.CI.WorkflowTriggersTest do
  use ExUnit.Case, async: true

  @required_pull_request_types ~w(opened synchronize reopened ready_for_review)
  @workflow_patterns [".github/workflows/*.yml", ".github/workflows/*.yaml"]

  test "pull request workflows run for every required activity type" do
    workflow_paths =
      @workflow_patterns
      |> Enum.flat_map(&Path.wildcard(repo_path(&1)))
      |> Enum.filter(&pull_request_workflow?/1)

    assert workflow_paths != [], "expected to find at least one pull request workflow"

    Enum.each(workflow_paths, fn workflow_path ->
      workflow = read_workflow!(workflow_path)
      configured_types = pull_request_types(workflow)
      missing_types = @required_pull_request_types -- configured_types
      relative_path = Path.relative_to(workflow_path, repo_path("."))

      assert missing_types == [],
             "#{relative_path} is missing pull_request types: #{Enum.join(missing_types, ", ")}"
    end)
  end

  defp pull_request_workflow?(workflow_path) do
    workflow = read_workflow!(workflow_path)
    triggers = triggers(workflow)

    cond do
      is_map(triggers) ->
        Map.has_key?(triggers, "pull_request")

      is_list(triggers) ->
        "pull_request" in triggers

      is_binary(triggers) ->
        triggers == "pull_request"

      true ->
        false
    end
  end

  defp pull_request_types(workflow) do
    triggers = triggers(workflow)

    if is_map(triggers) do
      case Map.get(triggers, "pull_request") do
        %{} = pr_config -> Map.get(pr_config, "types", [])
        _ -> []
      end
    else
      []
    end
  end

  # YAML 1.1 parsers resolve the unquoted GitHub Actions `on` key as a boolean.
  defp triggers(workflow) do
    Map.get(workflow, "on") || Map.get(workflow, true) || %{}
  end

  defp read_workflow!(workflow_path) do
    case YamlElixir.read_from_file(workflow_path) do
      {:ok, workflow} -> workflow
      {:error, reason} -> raise "failed to parse #{workflow_path}: #{inspect(reason)}"
    end
  end

  defp repo_path(path), do: Path.expand(Path.join([__DIR__, "../..", path]))
end
