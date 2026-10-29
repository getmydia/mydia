defmodule Mydia.Indexers.Cardigann.Result.Format.XmlTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Result.Format.Xml
  alias Mydia.Indexers.Cardigann.Result.Plan
  alias Mydia.Indexers.CardigannDefinition.Parsed

  @xml """
  <?xml version="1.0" encoding="UTF-8"?>
  <rss xmlns:tv="http://example.invalid/tv" xmlns:torznab="http://example.invalid/torznab">
    <channel>
      <item>
        <title>Lantern Harbor</title>
        <tv:raw_title>Lantern.Harbor.1080p</tv:raw_title>
        <enclosure url="http://example.invalid/d/1" length="1048576"/>
        <torznab:attr name="seeders" value="12"/>
        <torznab:attr name="category" value="2040"/>
      </item>
      <item>
        <title>Quiet Orchard</title>
        <torznab:attr name="seeders" value="3"/>
      </item>
    </channel>
  </rss>
  """

  defp plan(search) do
    assert {:ok, plan} = Plan.compile(%Parsed{id: "lantern", search: search}, %{})
    plan
  end

  defp field(plan, name), do: Enum.find(plan.selector_fields, &(&1.name == name))

  defp loaded(fields) do
    plan = plan(%{rows: %{selector: "rss > channel > item"}, fields: fields})
    assert {:ok, doc} = Xml.document(@xml, plan)
    {plan, doc, Xml.rows(doc, plan.rows)}
  end

  test "document/2 reports malformed XML" do
    plan = plan(%{rows: %{selector: "item"}, fields: %{}})
    assert {:error, _} = Xml.document("<a><b></a>", plan)
  end

  test "rows/2 lists every row" do
    {_plan, _doc, rows} = loaded(%{})
    assert length(rows) == 2
  end

  describe "raw/4" do
    setup do
      {plan, doc, rows} =
        loaded(%{
          "title" => %{selector: "title"},
          "raw" => %{selector: "raw_title"},
          "url" => %{selector: "enclosure", attribute: "url"},
          "seeders" => %{selector: "torznab|attr[name=seeders]", attribute: "value"},
          "seeders2" => %{selector: "[name=seeders]", attribute: "value"},
          "gone" => %{selector: "nothing"}
        })

      %{plan: plan, doc: doc, rows: rows}
    end

    test "reads element text and attributes", ctx do
      first = hd(ctx.rows)
      assert Xml.raw(ctx.doc, first, field(ctx.plan, "title")) == {:ok, "Lantern Harbor"}

      assert Xml.raw(ctx.doc, first, field(ctx.plan, "url")) ==
               {:ok, "http://example.invalid/d/1"}
    end

    test "attribute predicates match namespaced elements", ctx do
      assert Xml.raw(ctx.doc, hd(ctx.rows), field(ctx.plan, "seeders2")) == {:ok, "12"}
    end

    test "a plain element name finds a namespaced element", ctx do
      assert Xml.raw(ctx.doc, hd(ctx.rows), field(ctx.plan, "raw")) ==
               {:ok, "Lantern.Harbor.1080p"}
    end

    test "missing elements are not found", ctx do
      assert Xml.raw(ctx.doc, hd(ctx.rows), field(ctx.plan, "gone")) == :not_found
      assert Xml.raw(ctx.doc, List.last(ctx.rows), field(ctx.plan, "raw")) == :not_found
    end
  end

  test "the . selector reads the row's own attribute" do
    plan =
      plan(%{
        rows: %{selector: "enclosure"},
        fields: %{"u" => %{selector: ".", attribute: "url"}}
      })

    assert {:ok, doc} = Xml.document(@xml, plan)
    [row] = Xml.rows(doc, plan.rows)
    assert Xml.raw(doc, row, field(plan, "u")) == {:ok, "http://example.invalid/d/1"}
  end

  describe "case_value/4" do
    setup do
      {plan, doc, rows} =
        loaded(%{
          "kind" => %{
            selector: "title",
            case: %{":contains(\"lantern\")" => "movie", "*" => "other"}
          }
        })

      %{field: field(plan, "kind"), doc: doc, rows: rows}
    end

    test "a :contains key matches case-insensitively", ctx do
      assert Xml.case_value(ctx.doc, hd(ctx.rows), ctx.field) == {:ok, "movie"}
    end

    test "falls back to the wildcard", ctx do
      assert Xml.case_value(ctx.doc, List.last(ctx.rows), ctx.field) == {:ok, "other"}
    end

    test "a :contains miss with no wildcard is not found" do
      {plan, doc, rows} =
        loaded(%{"k" => %{selector: "title", case: %{":contains(\"zzz\")" => "x"}}})

      assert Xml.case_value(doc, hd(rows), field(plan, "k")) == :not_found
    end

    test "an element-name key matches when that child element exists" do
      {plan, doc, rows} =
        loaded(%{"k" => %{selector: "", case: %{"title" => "titled", "*" => "none"}}})

      assert Xml.case_value(doc, hd(rows), field(plan, "k")) == {:ok, "titled"}
    end

    test "an element-name key tests presence, so an empty element matches" do
      {plan, doc, [first, _second]} =
        loaded(%{"k" => %{selector: "", case: %{"enclosure" => "has-file"}}})

      assert Xml.case_value(doc, first, field(plan, "k")) == {:ok, "has-file"}
    end

    test "an element-name key does not match a row without that element" do
      {plan, doc, [_first, second]} =
        loaded(%{"k" => %{selector: "", case: %{"enclosure" => "has-file"}}})

      assert Xml.case_value(doc, second, field(plan, "k")) == :not_found
    end
  end
end
