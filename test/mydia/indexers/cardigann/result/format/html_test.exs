defmodule Mydia.Indexers.Cardigann.Result.Format.HtmlTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Result.Format.Html
  alias Mydia.Indexers.Cardigann.Result.Plan
  alias Mydia.Indexers.Cardigann.Result.Plan.Field
  alias Mydia.Indexers.CardigannDefinition.Parsed

  @html """
  <table>
    <tr><th>Name</th></tr>
    <tr data-id="a1"><td class="t"><a href="/d/1">Lantern Harbor <span class="tag">NEW</span></a></td><td class="q">1080p</td></tr>
    <tr><td class="t"><a href="/d/2">Quiet Orchard</a></td><td class="q">720p</td></tr>
  </table>
  """

  defp plan(search, encoding \\ "UTF-8") do
    assert {:ok, plan} =
             Plan.compile(%Parsed{id: "lantern", encoding: encoding, search: search}, %{})

    plan
  end

  defp doc(plan, body \\ @html) do
    assert {:ok, doc} = Html.document(body, plan)
    doc
  end

  defp field(plan, name), do: Enum.find(plan.selector_fields, &(&1.name == name))

  describe "rows/2" do
    test "returns every match of the row selector" do
      plan = plan(%{rows: %{selector: "tr"}, fields: %{}})
      assert length(Html.rows(doc(plan), plan.rows)) == 3
    end

    test "missing_attribute_equals_no_results drops rows without the attribute" do
      plan =
        plan(%{
          rows: %{selector: "tr", attribute: "data-id", missing_attribute_equals_no_results: true},
          fields: %{}
        })

      assert length(Html.rows(doc(plan), plan.rows)) == 1
    end

    test "keeps rows without the attribute when the flag is off" do
      plan = plan(%{rows: %{selector: "tr", attribute: "data-id"}, fields: %{}})
      assert length(Html.rows(doc(plan), plan.rows)) == 3
    end

    test "supports :contains() selectors" do
      plan = plan(%{rows: %{selector: "tr:contains(\"Orchard\")"}, fields: %{}})
      assert length(Html.rows(doc(plan), plan.rows)) == 1
    end
  end

  describe "raw/4" do
    setup do
      plan =
        plan(%{
          rows: %{selector: "tr"},
          fields: %{
            title: %{selector: "td.t a"},
            plain: %{selector: "td.t a", remove: ["span.tag"]},
            link: %{selector: "td.t a", attribute: "href"},
            missing: %{selector: "td.nope"}
          }
        })

      doc = doc(plan)
      [_header, row | _] = Html.rows(doc, plan.rows)
      {:ok, plan: plan, doc: doc, row: row}
    end

    test "reads trimmed text", %{plan: plan, doc: doc, row: row} do
      assert {:ok, "Lantern Harbor NEW"} = Html.raw(doc, row, field(plan, "title"))
    end

    test "remove strips matching children first", %{plan: plan, doc: doc, row: row} do
      assert {:ok, "Lantern Harbor"} = Html.raw(doc, row, field(plan, "plain"))
    end

    test "reads an attribute", %{plan: plan, doc: doc, row: row} do
      assert {:ok, "/d/1"} = Html.raw(doc, row, field(plan, "link"))
    end

    test "no match is :not_found", %{plan: plan, doc: doc, row: row} do
      assert :not_found = Html.raw(doc, row, field(plan, "missing"))
    end

    test "renders a per-row template from opts[:context]", %{doc: doc, row: row} do
      field = %Field{name: "q", selector: "td.{{ .Result.col }}"}
      ctx = %{result: %{"col" => "q"}}
      assert {:ok, "1080p"} = Html.raw(doc, row, field, context: ctx)
    end
  end

  describe "case_value/4" do
    setup do
      plan =
        plan(%{
          rows: %{selector: "tr"},
          fields: %{
            quality: %{
              selector: "td.q",
              case: %{"*" => "other", ":contains(\"1080p\")" => "hd"}
            },
            tagged: %{case: %{"span.tag" => "new"}},
            nodefault: %{selector: "td.q", case: %{":contains(\"4k\")" => "uhd"}},
            absent: %{selector: "td.nope", case: %{"*" => "x"}}
          }
        })

      doc = doc(plan)
      [_header, first, second] = Html.rows(doc, plan.rows)
      {:ok, plan: plan, doc: doc, first: first, second: second}
    end

    test "a specific key wins over the wildcard", c do
      assert {:ok, "hd"} = Html.case_value(c.doc, c.first, field(c.plan, "quality"))
    end

    test "the wildcard is the fallback", c do
      assert {:ok, "other"} = Html.case_value(c.doc, c.second, field(c.plan, "quality"))
    end

    test "an empty selector scopes to the row", c do
      assert {:ok, "new"} = Html.case_value(c.doc, c.first, field(c.plan, "tagged"))
      assert :not_found = Html.case_value(c.doc, c.second, field(c.plan, "tagged"))
    end

    test "no match and no wildcard is :not_found", c do
      assert :not_found = Html.case_value(c.doc, c.first, field(c.plan, "nodefault"))
    end

    test "an unmatched field selector is :not_found even with a wildcard", c do
      assert :not_found = Html.case_value(c.doc, c.first, field(c.plan, "absent"))
    end
  end

  test "document/2 decodes the declared charset" do
    plan = plan(%{rows: %{selector: "td"}, fields: %{}}, "windows-1251")
    body = "<table><tr><td>" <> <<0xCF, 0xF0, 0xE8, 0xE2, 0xE5, 0xF2>> <> "</td></tr></table>"
    doc = doc(plan, body)
    [td] = Html.rows(doc, plan.rows)
    assert {:ok, "Привет"} = Html.raw(doc, td, %Field{name: "x", selector: nil})
  end
end
