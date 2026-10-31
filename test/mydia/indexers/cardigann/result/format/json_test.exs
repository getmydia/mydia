defmodule Mydia.Indexers.Cardigann.Result.Format.JsonTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Result.Format.Json
  alias Mydia.Indexers.Cardigann.Result.Plan
  alias Mydia.Indexers.CardigannDefinition.Parsed

  @body ~s({"data":{"items":[
    {"name":"Lantern Harbor","quality":"1080p","size":1234,"meta":{"seeds":7},
     "torrents":[{"hash":"aa"},{"hash":"bb"}]},
    {"name":"Quiet Orchard","quality":"4320p","size":1.5},
    "stray scalar"
  ]}})

  defp plan(search, encoding \\ "UTF-8") do
    assert {:ok, plan} =
             Plan.compile(%Parsed{id: "lantern", encoding: encoding, search: search}, %{})

    plan
  end

  defp field(plan, name), do: Enum.find(plan.selector_fields, &(&1.name == name))

  defp loaded(search) do
    plan = plan(search)
    assert {:ok, doc} = Json.document(@body, plan)
    {plan, doc, Json.rows(doc, plan.rows)}
  end

  describe "document/2" do
    test "decodes a body with the plan's charset" do
      plan = plan(%{rows: %{selector: "$"}, fields: %{}}, "windows-1251")
      body = <<123, 34, 110, 34, 58, 34, 207, 240, 232, 226, 229, 242, 34, 125>>
      assert {:ok, %{"n" => "Привет"}} = Json.document(body, plan)
    end

    test "accepts an already decoded map or list" do
      plan = plan(%{rows: %{selector: "$"}, fields: %{}})
      assert {:ok, %{"a" => 1}} = Json.document(%{"a" => 1}, plan)
      assert {:ok, [1]} = Json.document([1], plan)
    end

    test "reports invalid JSON" do
      plan = plan(%{rows: %{selector: "$"}, fields: %{}})
      assert {:error, _} = Json.document("not json", plan)
    end
  end

  describe "rows/2" do
    test "navigates the selector and skips scalar rows" do
      {_plan, _doc, rows} = loaded(%{rows: %{selector: "data.items"}, fields: %{}})
      assert length(rows) == 2
    end

    test "a missing path yields no rows" do
      {_plan, _doc, rows} = loaded(%{rows: %{selector: "nope"}, fields: %{}})
      assert rows == []
    end

    test "attribute expands sub-arrays with a __parent link" do
      {plan, doc, rows} =
        loaded(%{
          rows: %{selector: "data.items", attribute: "torrents"},
          fields: %{"h" => %{selector: "hash"}, "n" => %{selector: "..name"}}
        })

      # the second parent has no sub-array and is kept as it is
      assert length(rows) == 3
      assert Json.raw(doc, hd(rows), field(plan, "n")) == {:ok, "Lantern Harbor"}
      assert Json.raw(doc, hd(rows), field(plan, "h")) == {:ok, "aa"}
    end

    # UNIT3D's API: `rows: {selector: data, attribute: attributes}`, where each
    # row's fields live in its `attributes` object.
    test "attribute naming an object makes that object the row" do
      plan =
        plan(%{
          rows: %{selector: "data", attribute: "attributes"},
          fields: %{"n" => %{selector: "name"}, "i" => %{selector: "..id"}}
        })

      doc = %{"data" => [%{"id" => "101", "attributes" => %{"name" => "Lantern Harbor"}}]}

      assert [row] = Json.rows(doc, plan.rows)
      assert Json.raw(doc, row, field(plan, "n")) == {:ok, "Lantern Harbor"}
      assert Json.raw(doc, row, field(plan, "i")) == {:ok, "101"}
    end

    test "a selector the response's shape cannot satisfy is an error" do
      plan = plan(%{rows: %{selector: "data.items"}, fields: %{}})
      assert {:error, message} = Json.rows(%{"data" => "scalar"}, plan.rows)
      assert message =~ "does not apply to the response"
    end
  end

  describe "raw/4" do
    setup do
      {plan, doc, rows} =
        loaded(%{
          rows: %{selector: "data.items"},
          fields: %{
            "t" => %{selector: "name"},
            "s" => %{selector: "size"},
            "d" => %{selector: "meta.seeds"},
            "m" => %{selector: "missing"}
          }
        })

      %{plan: plan, doc: doc, rows: rows}
    end

    test "reads direct keys, numbers and dotted paths as strings", ctx do
      [first, second] = ctx.rows
      assert Json.raw(ctx.doc, first, field(ctx.plan, "t")) == {:ok, "Lantern Harbor"}
      assert Json.raw(ctx.doc, first, field(ctx.plan, "s")) == {:ok, "1234"}
      assert Json.raw(ctx.doc, second, field(ctx.plan, "s")) == {:ok, "1.5"}
      assert Json.raw(ctx.doc, first, field(ctx.plan, "d")) == {:ok, "7"}
    end

    test "absent values are not found", ctx do
      assert Json.raw(ctx.doc, hd(ctx.rows), field(ctx.plan, "m")) == :not_found
    end
  end

  describe "case_value/4" do
    setup do
      {plan, doc, rows} =
        loaded(%{
          rows: %{selector: "data.items"},
          fields: %{
            "category" => %{
              selector: "quality",
              case: %{"720p" => "45", "1080p" => "44", "*" => "9"}
            }
          }
        })

      %{field: field(plan, "category"), doc: doc, rows: rows}
    end

    test "a key equal to the value wins", ctx do
      assert Json.case_value(ctx.doc, hd(ctx.rows), ctx.field) == {:ok, "44"}
    end

    test "the wildcard is the fallback", ctx do
      assert Json.case_value(ctx.doc, List.last(ctx.rows), ctx.field) == {:ok, "9"}
    end

    test "no match and no wildcard is not found" do
      {plan, doc, rows} =
        loaded(%{
          rows: %{selector: "data.items"},
          fields: %{"c" => %{selector: "quality", case: %{"720p" => "45"}}}
        })

      assert Json.case_value(doc, hd(rows), field(plan, "c")) == :not_found
    end

    test "a numeric value matches a string key" do
      {plan, doc, rows} =
        loaded(%{
          rows: %{selector: "data.items"},
          fields: %{"c" => %{selector: "size", case: %{"1234" => "hit", "*" => "miss"}}}
        })

      assert Json.case_value(doc, hd(rows), field(plan, "c")) == {:ok, "hit"}
    end

    test "the wildcard matches when nothing was extracted" do
      {plan, doc, rows} =
        loaded(%{
          rows: %{selector: "data.items"},
          fields: %{"c" => %{selector: "missing", case: %{"x" => "hit", "*" => "dflt"}}}
        })

      assert Json.case_value(doc, hd(rows), field(plan, "c")) == {:ok, "dflt"}
    end
  end
end
