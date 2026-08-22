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
      pull_request = triggers(workflow)["pull_request"] || %{}
      configured_types = Map.get(pull_request, "types", [])
      missing_types = @required_pull_request_types -- configured_types
      relative_path = Path.relative_to(workflow_path, repo_path("."))

      assert missing_types == [],
             "#{relative_path} is missing pull_request types: #{Enum.join(missing_types, ", ")}"
    end)
  end

  defp pull_request_workflow?(workflow_path) do
    workflow_path
    |> read_workflow!()
    |> triggers()
    |> Map.has_key?("pull_request")
  end

  # YAML 1.1 parsers resolve the unquoted GitHub Actions `on` key as a boolean.
  defp triggers(workflow), do: Map.get(workflow, "on") || Map.fetch!(workflow, true)

  defp read_workflow!(workflow_path) do
    case YamlElixir.read_from_file(workflow_path) do
      {:ok, workflow} -> workflow
      {:error, reason} -> raise "failed to parse #{workflow_path}: #{inspect(reason)}"
    end
  end

  defp repo_path(path), do: Path.expand(Path.join([__DIR__, "../..", path]))
end
