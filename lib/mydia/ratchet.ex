defmodule Mydia.Ratchet do
  @moduledoc """
  Diff-based quality gates: a branch may not add complexity, nesting or module size
  relative to its merge base.

  These are not exception lists. Nothing records which existing findings are
  tolerated; the merge base is the baseline, so the gate only ever tightens. See
  "Ratchets" in CONTRIBUTING.md and `Mix.Tasks.Mydia.Ratchet`, which gathers the
  inputs.

  Complexity and nesting issues are matched on `{check, function name}`, and a match
  is a regression only if its measured value (complexity or depth) went up. A
  function that got simpler is an improvement, not a new finding. File, module, line
  and column are ignored on purpose: moving an unchanged complex function into a new
  module is not a regression, which keeps splitting modules free.
  """

  @max_lines 800

  @type size_regression ::
          {:new, Path.t(), non_neg_integer()}
          | {:grew, Path.t(), non_neg_integer(), non_neg_integer()}

  @spec max_lines() :: pos_integer()
  def max_lines, do: @max_lines

  @doc "Counts newline characters, the same number `wc -l` prints."
  @spec count_lines(binary()) :: non_neg_integer()
  def count_lines(content), do: length(:binary.matches(content, "\n"))

  @doc """
  Files over `max_lines` at HEAD that are new, or have more lines than at the base.
  """
  @spec size_regressions(map(), map(), pos_integer()) :: [size_regression()]
  def size_regressions(current, base, max_lines \\ @max_lines) do
    current
    |> Enum.filter(fn {_path, lines} -> lines > max_lines end)
    |> Enum.flat_map(&size_regression(&1, base))
    |> Enum.sort_by(&elem(&1, 1))
  end

  defp size_regression({path, lines}, base) do
    case Map.fetch(base, path) do
      :error -> [{:new, path, lines}]
      {:ok, before} when lines > before -> [{:grew, path, before, lines}]
      {:ok, _before} -> []
    end
  end

  @doc "Extracts the `issues` list from `mix credo --format json` output."
  @spec parse_credo_json(binary()) :: [map()]
  def parse_credo_json(output) do
    lines = String.split(output, "\n")
    json_lines = Enum.drop_while(lines, &(not String.starts_with?(&1, "{")))

    if json_lines == [] do
      raise ArgumentError, "no credo JSON object in output:\n" <> output
    end

    decoded = Jason.decode!(Enum.join(json_lines, "\n"))
    Map.fetch!(decoded, "issues")
  end

  @spec issue_key(map()) :: {String.t(), String.t()}
  def issue_key(issue) do
    scope = issue["scope"] || ""
    function_name = scope |> String.split(".") |> List.last()

    {issue["check"], function_name}
  end

  @doc """
  The measured value in a credo message: the complexity ("cyclomatic complexity is
  14, max is 9") or the depth ("max depth is 2, was 3"). Messages with neither
  count as 0.
  """
  @spec issue_value(map()) :: non_neg_integer()
  def issue_value(issue) do
    case Regex.run(~r/(?:complexity is|was) (\d+)/, issue["message"] || "") do
      [_, value] -> String.to_integer(value)
      nil -> 0
    end
  end

  @doc """
  HEAD issues that are new or worse than the base.

  Issues are grouped per `issue_key/1`. Within a group the base and HEAD values are
  each sorted descending and paired off: a HEAD issue with no partner, or with a
  higher value than its partner, is a regression. A lower value is an improvement.
  """
  @spec complexity_regressions([map()], [map()]) :: [map()]
  def complexity_regressions(base_issues, head_issues) do
    base_values =
      base_issues
      |> Enum.group_by(&issue_key/1, &issue_value/1)
      |> Map.new(fn {key, values} -> {key, Enum.sort(values, :desc)} end)

    head_issues
    |> Enum.group_by(&issue_key/1)
    |> Enum.flat_map(fn {key, issues} ->
      issues
      |> Enum.sort_by(&issue_value/1, :desc)
      |> worse_than(Map.get(base_values, key, []))
    end)
    |> Enum.sort_by(&{&1["filename"], &1["line_no"]})
  end

  defp worse_than([], _base_values), do: []
  defp worse_than(issues, []), do: issues

  defp worse_than([issue | issues], [base_value | base_values]) do
    rest = worse_than(issues, base_values)
    if issue_value(issue) > base_value, do: [issue | rest], else: rest
  end

  @spec format_size_regression(size_regression()) :: String.t()
  def format_size_regression({:new, path, lines}) do
    "#{path}: new file with #{lines} lines (max #{@max_lines}). Split it into focused modules."
  end

  def format_size_regression({:grew, path, before, lines}) do
    "#{path}: grew from #{before} to #{lines} lines (max #{@max_lines}). " <>
      "An oversized module may only shrink; put the new code in a focused module."
  end

  @spec format_issue(map()) :: String.t()
  def format_issue(issue) do
    "#{issue["filename"]}:#{issue["line_no"]} #{issue["scope"]}: #{issue["message"]}"
  end
end
