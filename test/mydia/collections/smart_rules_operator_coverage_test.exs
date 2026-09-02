defmodule Mydia.Collections.SmartRulesOperatorCoverageTest do
  # Guards a cross-file invariant, in the spirit of
  # test/mydia/collections/sidebar_icon_safelist_test.exs: the rules editor
  # (SmartRulesFields) advertises which operators are valid for each field,
  # but the query builder (SmartRules.build_dynamic/3) is a fixed set of
  # function clauses. SmartRules.validate/1 checks field and operator names
  # against allowlists that are not field-specific, so an operator the editor
  # offers for a field can validate cleanly and still have no matching
  # build_dynamic clause. When that happens, build_dynamic falls through to
  # its own module-level catch-all,
  # `defp build_dynamic(_field, _operator, _value), do: dynamic([m], true)`,
  # which does not raise: it silently matches every row instead of filtering,
  # or of failing loudly. This is exactly the class of bug that shipped the
  # foreign_language preset broken (see task-2-report.md).
  #
  # Detection method, verified empirically before writing this test: probed
  # both a catch-all pair and a real-clause pair through
  # `Ecto.Adapters.SQL.to_sql/3` on this project's (SQLite) test adapter.
  # A condition that falls through to the catch-all produces NO "WHERE"
  # clause at all in the rendered SQL (Ecto prunes a literal `where: true`
  # dynamic entirely, rather than emitting something like `WHERE (1)` or
  # `WHERE TRUE`), while every real build_dynamic clause produces a
  # `WHERE (...)` clause, because the base query
  # (`from(m in MediaItem)` in build_query/1) carries no filter of its own.
  # That is the signal this test asserts on, rather than looking for a
  # literal TRUE token the adapter never actually emits.
  use Mydia.DataCase, async: true

  alias Mydia.Collections.SmartRules
  alias Mydia.Collections.SmartRulesFields

  test "every field/operator pair the rules editor advertises has a real build_dynamic clause" do
    for {field, %{operators: operators}} <- SmartRulesFields.field_definitions(),
        operator <- operators do
      value = plausible_value(field, operator)

      rules = %{
        "conditions" => [
          %{"field" => field, "operator" => to_string(operator), "value" => value}
        ]
      }

      case SmartRules.query(rules) do
        {:ok, query} ->
          {sql, _params} = Ecto.Adapters.SQL.to_sql(:all, Mydia.Repo, query)

          assert sql =~ "WHERE",
                 "#{field} + #{operator} validates but produces no WHERE clause: " <>
                   "build_dynamic/3 has no clause for this pair and it silently falls " <>
                   "through to the catch-all, which matches every row instead of " <>
                   "filtering or raising"

        {:error, reason} ->
          flunk(
            "#{field} + #{operator} (probe value #{inspect(value)}) failed to validate: " <>
              "#{reason}. Fix plausible_value/2 in this test; SmartRulesFields advertises " <>
              "this pair, but the probe value chosen for it does not pass SmartRules.validate/1."
          )
      end
    end
  end

  # One plausible value per field, valid for every operator that field
  # advertises. Hand-picked per field rather than derived generically from
  # the field's declared :type, because some fields (type, category)
  # restrict values to a fixed allowlist that a generic placeholder value
  # would fail validation against.
  defp plausible_value("type", operator) when operator in [:in, :not_in], do: ["movie"]
  defp plausible_value("type", _operator), do: "movie"

  defp plausible_value("category", operator) when operator in [:in, :not_in], do: ["movie"]
  defp plausible_value("category", _operator), do: "movie"

  defp plausible_value("year", :between), do: [2010, 2020]
  defp plausible_value("year", _operator), do: 2015

  defp plausible_value("title", _operator), do: "Test"

  defp plausible_value("monitored", _operator), do: true

  defp plausible_value("metadata.vote_average", :between), do: [5.0, 8.0]
  defp plausible_value("metadata.vote_average", _operator), do: 7.0

  defp plausible_value("metadata.genres", :contains), do: "Action"
  defp plausible_value("metadata.genres", :contains_any), do: ["Action"]

  defp plausible_value("metadata.original_language", operator) when operator in [:in, :not_in],
    do: ["en"]

  defp plausible_value("metadata.original_language", _operator), do: "en"

  defp plausible_value("metadata.status", operator) when operator in [:in, :not_in],
    do: ["Ended"]

  defp plausible_value("metadata.status", _operator), do: "Ended"

  defp plausible_value("inserted_at", :within_last), do: 30
  defp plausible_value("inserted_at", _operator), do: "2020-01-01T00:00:00Z"

  defp plausible_value(field, operator) do
    flunk(
      "no plausible_value/2 clause for #{field} + #{operator}. SmartRulesFields advertises " <>
        "this pair; add a matching clause here so the coverage test actually exercises it."
    )
  end
end
