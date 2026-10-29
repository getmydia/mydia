defmodule Mydia.Indexers.Cardigann.Result.FieldsTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Result.Fields
  alias Mydia.Indexers.Cardigann.Result.Format.{Html, Json}
  alias Mydia.Indexers.Cardigann.Result.Plan
  alias Mydia.Indexers.CardigannDefinition.Parsed

  @html """
  <table>
    <tr>
      <td class="name">Lantern Harbor</td>
      <td class="platform">Quiet Orchard Console</td>
      <td><a class="dl" href="/get/1">get</a></td>
      <td class="res">720p</td>
    </tr>
  </table>
  """

  defp plan(fields, context \\ %{}) do
    search = %{rows: %{selector: "tr"}, fields: fields}
    assert {:ok, plan} = Plan.compile(%Parsed{id: "lantern", search: search}, context)
    plan
  end

  defp extract_html(fields, context \\ %{}) do
    plan = plan(fields, context)
    {:ok, doc} = Html.document(@html, plan)
    [row] = Html.rows(doc, plan.rows)
    Fields.extract(doc, row, plan, Html, context)
  end

  defp extract_json(row, fields) do
    plan = plan(fields)
    Fields.extract(row, row, plan, Json, %{})
  end

  @download %{"download" => %{selector: "a.dl", attribute: "href"}}

  describe "selector fields" do
    test "a filter sees .Result of the fields extracted before it" do
      fields =
        Map.merge(@download, %{
          "title" => %{
            selector: "td.name",
            filters: [%{name: "append", args: " - {{ .Result.platform }}"}]
          },
          "platform" => %{selector: "td.platform"}
        })

      assert {:ok, %{"title" => "Lantern Harbor - Quiet Orchard Console"}} = extract_html(fields)
    end

    test "filters run on the case result" do
      fields =
        Map.merge(@download, %{
          "title" => %{selector: "td.name"},
          "category" => %{
            case: %{"td.res:contains(\"720p\")" => "45", "*" => "1"},
            filters: [%{name: "prepend", args: "cat-"}]
          }
        })

      assert {:ok, %{"category" => "cat-45"}} = extract_html(fields)
    end

    test "an optional field falls back to its default, for JSON as well" do
      row = %{"name" => "Lantern Harbor", "link" => "magnet:?xt=urn:btih:aa"}

      fields = %{
        "title" => %{selector: "name"},
        "download" => %{selector: "link"},
        "seeders" => %{selector: "seeds", optional: true, default: "7"},
        "leechers" => %{selector: "peers", default: "3"}
      }

      assert {:ok, values} = extract_json(row, fields)
      assert values["seeders"] == "7"
      refute Map.has_key?(values, "leechers")
    end

    test "JSON honours case before filters" do
      row = %{"name" => "Lantern Harbor", "link" => "magnet:?xt=urn:btih:aa", "q" => "720p"}

      fields = %{
        "title" => %{selector: "name"},
        "download" => %{selector: "link"},
        "category" => %{
          selector: "q",
          case: %{"720p" => "45", "*" => "1"},
          filters: [%{name: "append", args: "0"}]
        }
      }

      assert {:ok, %{"category" => "450"}} = extract_json(row, fields)
    end
  end

  describe "text fields" do
    test "run after selector fields and after the text fields they read" do
      fields =
        Map.merge(@download, %{
          "a_full" => %{text: "{{ .Result.b_short }}!"},
          "b_short" => %{text: "{{ .Result.title }} ({{ .Result.res }})"},
          "title" => %{selector: "td.name"},
          "res" => %{selector: "td.res"}
        })

      assert {:ok, values} = extract_html(fields)
      assert values["b_short"] == "Lantern Harbor (720p)"
      assert values["a_full"] == "Lantern Harbor (720p)!"
    end

    test "a YAML integer text is the string form" do
      fields =
        Map.merge(@download, %{"title" => %{selector: "td.name"}, "seeders" => %{text: 1}})

      assert {:ok, %{"seeders" => "1"}} = extract_html(fields)
    end

    test "filters on a text field see .Result" do
      fields =
        Map.merge(@download, %{
          "title" => %{selector: "td.name"},
          "label" => %{text: "x", filters: [%{name: "append", args: "{{ .Result.title }}"}]}
        })

      assert {:ok, %{"label" => "xLantern Harbor"}} = extract_html(fields)
    end
  end

  describe "row requirements" do
    test "a row without a title is dropped as title" do
      assert {:drop, "title"} = extract_html(@download)
    end

    test "a row without a download or infohash is dropped as download" do
      assert {:drop, "download"} = extract_html(%{"title" => %{selector: "td.name"}})
    end

    test "title_default and magnet stand in for title and download" do
      fields = %{
        "title_default" => %{selector: "td.name"},
        "magnet" => %{selector: "a.dl", attribute: "href"}
      }

      assert {:ok, values} = extract_html(fields)
      assert values["title"] == "Lantern Harbor"
      assert values["download"] == "/get/1"
      refute Map.has_key?(values, "magnet")
    end
  end
end
