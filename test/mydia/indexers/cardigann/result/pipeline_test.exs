defmodule Mydia.Indexers.Cardigann.Result.PipelineTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.ParseStats
  alias Mydia.Indexers.Cardigann.Result.{Context, Pipeline, Plan}
  alias Mydia.Indexers.Cardigann.Result.Format.Html
  alias Mydia.Indexers.CardigannDefinition.Parsed

  @html """
  <table>
    <tr><th>header</th></tr>
    <tr><td class="t">Lantern Harbor 1080p</td><td><a href="/d/1">d</a></td></tr>
    <tr><td class="t">Quiet Orchard 720p</td><td><a href="/d/2">d</a></td></tr>
    <tr><td class="t">Lantern Harbor 720p</td><td><a href="/d/3">d</a></td></tr>
  </table>
  """

  @fields %{
    "title" => %{selector: "td.t"},
    "download" => %{selector: "a", attribute: "href"}
  }

  defp run(rows, body, format, opts \\ []) do
    fields = Keyword.get(opts, :fields, @fields)
    keywords = Keyword.get(opts, :keywords, "")
    search = %{rows: rows, fields: fields}
    context = %{keywords: keywords}

    {:ok, plan} = Plan.compile(%Parsed{id: "lantern", search: search}, context)

    ctx = %Context{
      indexer_name: "Lantern",
      template_context: context,
      base_url: "https://lantern.invalid",
      search: search
    }

    Pipeline.run(%{plan | format: format}, body, ctx)
  end

  defp titles(results), do: Enum.map(results, & &1.title)

  describe "row slicing" do
    test "after and count apply to HTML rows" do
      assert {:ok, results, %ParseStats{matched: 1}} =
               run(%{selector: "tr", after: 2, count: 1}, @html, :html)

      assert titles(results) == ["Quiet Orchard 720p"]
    end

    test "after and count apply to JSON rows" do
      items = for n <- 1..4, do: %{"name" => "Lantern Harbor #{n}", "link" => "/d/#{n}"}
      body = Jason.encode!(%{"items" => items})

      fields = %{"title" => %{selector: "name"}, "download" => %{selector: "link"}}

      assert {:ok, results, _stats} =
               run(%{selector: "items", after: 1, count: 2}, body, :json, fields: fields)

      assert titles(results) == ["Lantern Harbor 2", "Lantern Harbor 3"]
    end
  end

  describe "andmatch" do
    test "rows.filters andmatch drops rows whose title lacks a keyword" do
      rows = %{selector: "tr", after: 1, filters: [%{name: "andmatch"}]}

      assert {:ok, results, %ParseStats{matched: 3, filtered: 1, dropped: 0}} =
               run(rows, @html, :html, keywords: "lantern harbor")

      assert titles(results) == ["Lantern Harbor 1080p", "Lantern Harbor 720p"]
    end

    test "rows.filters andmatch reaches the plan from a YAML definition" do
      yaml = """
      id: lantern
      name: Lantern
      description: Lantern Harbor test tracker
      language: en-US
      encoding: UTF-8
      type: public
      links: [https://lantern.invalid/]
      caps:
        categorymappings: []
      search:
        paths: [{path: /}]
        rows:
          selector: tr
          filters:
            - name: andmatch
        fields:
          title: {selector: td.t}
          download: {selector: a, attribute: href}
          size: {text: 1 GB}
          seeders: {text: 1}
      """

      {:ok, definition} = Mydia.Indexers.CardigannParser.parse_definition(yaml)
      {:ok, plan} = Plan.compile(definition, %{})
      assert [%{"name" => "andmatch"}] = plan.rows.filters
    end

    test "a field-level andmatch filter drops rows whose title lacks a keyword" do
      fields = put_in(@fields, ["title", :filters], [%{name: "andmatch"}])

      assert {:ok, results, _stats} =
               run(%{selector: "tr", after: 1}, @html, :html, keywords: "720p", fields: fields)

      assert titles(results) == ["Quiet Orchard 720p", "Lantern Harbor 720p"]
    end

    test "without keywords every row is kept" do
      fields = put_in(@fields, ["title", :filters], [%{name: "andmatch"}])

      assert {:ok, results, _stats} =
               run(%{selector: "tr", after: 1}, @html, :html, fields: fields)

      assert length(results) == 3
    end
  end

  describe "errors" do
    test "a JSON row selector the response cannot satisfy is a search error" do
      assert {:error, %Error{} = error} =
               run(%{selector: "data.items"}, ~s({"data": "flat"}), :json)

      assert Exception.message(error) =~ "does not apply to the response"
    end

    test "invalid JSON names the decode error" do
      assert {:error, %Error{} = error} = run(%{selector: "items"}, "{nope", :json)
      assert Exception.message(error) =~ "Invalid JSON"
    end

    test "a selector lexbor rejects is an invalid selector in the definition" do
      capture_log(fn ->
        assert {:error, %Error{} = error} = run(%{selector: "tr["}, @html, :html)
        assert Exception.message(error) =~ "Invalid selector in the Lantern definition"
      end)
    end

    test "malformed XML is reported as an XML parse error" do
      assert {:error, %Error{} = error} = run(%{selector: "item"}, "<rss><item>", :xml)
      assert Exception.message(error) =~ "XML parse error"
    end
  end

  test "an empty row match is an empty result, with the HTML shape for the debug log" do
    assert {:ok, [], %ParseStats{matched: 0}} = run(%{selector: "li"}, @html, :html)

    {:ok, plan} = Plan.compile(%Parsed{id: "lantern", search: %{rows: "li", fields: %{}}}, %{})
    {:ok, doc} = Html.document(@html, plan)
    assert Html.empty_rows_diagnostics(doc) =~ "4 tr elements, 1 tables"
  end

  test "a plan with no format reports an error instead of raising" do
    ctx = %Context{
      indexer_name: "Lantern",
      template_context: %{},
      base_url: "https://lantern.invalid"
    }

    assert {:error, %Error{type: :search_failed, message: message}} =
             Pipeline.run(%Plan{format: nil}, @html, ctx)

    assert message =~ "Lantern"
  end
end
