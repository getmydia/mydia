defmodule Mydia.Indexers.Cardigann.Result.PlanTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.Result.Plan
  alias Mydia.Indexers.Cardigann.Result.Plan.{Field, RowTemplate, Rows}
  alias Mydia.Indexers.CardigannDefinition.Parsed

  defp definition(search), do: %Parsed{id: "lantern", encoding: "UTF-8", search: search}

  defp compile!(search, context \\ %{}, opts \\ []) do
    assert {:ok, plan} = Plan.compile(definition(search), context, opts)
    plan
  end

  test "defaults after to 0 and count to nil" do
    plan = compile!(%{rows: %{selector: "tr"}, fields: %{}})

    assert %Rows{selector: "tr", after: 0, count: nil, andmatch: nil, filters: []} = plan.rows
    assert plan.rows.multiple == false
    assert plan.rows.missing_attribute_equals_no_results == false
    assert plan.encoding == "UTF-8"
  end

  test "keeps integer after and count" do
    plan = compile!(%{rows: %{selector: "tr", after: 1, count: 5}, fields: %{}})
    assert plan.rows.after == 1
    assert plan.rows.count == 5
  end

  test "accepts atom and string keys for rows and fields" do
    atoms =
      compile!(%{
        rows: %{selector: "tr", after: 2},
        fields: %{title: %{selector: "a", optional: true, default: "x"}}
      })

    strings =
      compile!(%{
        "rows" => %{"selector" => "tr", "after" => 2},
        "fields" => %{"title" => %{"selector" => "a", "optional" => true, "default" => "x"}}
      })

    assert atoms == strings

    assert [%Field{name: "title", selector: "a", optional: true, default: "x"}] =
             atoms.selector_fields
  end

  test "selector fields are sorted by name" do
    plan =
      compile!(%{
        rows: %{selector: "tr"},
        fields: %{zeta: %{selector: "z"}, alpha: %{selector: "a"}}
      })

    assert Enum.map(plan.selector_fields, & &1.name) == ["alpha", "zeta"]
  end

  test "an integer text becomes a string text field" do
    plan =
      compile!(%{
        rows: %{selector: "tr"},
        fields: %{seeders: %{text: 1}, title: %{selector: "a"}}
      })

    assert [%Field{name: "seeders", text: "1"}] = plan.text_fields
    assert [%Field{name: "title", text: nil}] = plan.selector_fields
  end

  test "text fields are ordered by their .Result dependencies" do
    plan =
      compile!(%{
        rows: %{selector: "tr"},
        fields: %{
          a_final: %{text: "{{ .Result.z_base }} extra"},
          z_base: %{text: "Lantern Harbor"}
        }
      })

    assert Enum.map(plan.text_fields, & &1.name) == ["z_base", "a_final"]
  end

  test "pre-renders a config template and leaves .Result templates raw" do
    context = %{config: %{"column" => "3"}}

    plan =
      compile!(
        %{
          rows: %{selector: "tr.{{ .Config.column }}"},
          fields: %{
            title: %{
              selector: "td:nth-child({{ .Config.column }})",
              case: %{"td.{{ .Config.column }}" => "yes"},
              remove: "span.{{ .Config.column }}",
              filters: [%{name: "append", args: ["{{ .Config.column }}"]}]
            },
            raw: %{
              selector: "a.{{ .Result.title }}",
              filters: [%{name: "prepend", args: "{{ .Result.title }}"}]
            }
          }
        },
        context
      )

    assert plan.rows.selector == "tr.3"
    # `raw` reads `.Result.title`, so it follows title despite sorting first.
    [title, raw] = plan.selector_fields
    assert title.selector == "td:nth-child(3)"
    assert title.case == [{"td.3", "yes"}]
    assert title.remove == ["span.3"]
    assert title.filters == [%{name: "append", args: ["3"]}]
    assert raw.selector == "a.{{ .Result.title }}"

    assert raw.filters == [
             %{name: "prepend", args: [%RowTemplate{template: "{{ .Result.title }}"}]}
           ]
  end

  test "a non-map field config is an error naming the field" do
    assert {:error, %Error{message: message}} =
             Plan.compile(definition(%{rows: %{selector: "tr"}, fields: %{broken: "a"}}), %{}, [])

    assert message =~ "broken"
  end

  test "a missing row selector is an error" do
    assert {:error, %Error{}} = Plan.compile(definition(%{fields: %{}}), %{}, [])
  end

  test "format comes from the search path response type" do
    search = %{rows: %{selector: "tr"}, fields: %{}}

    assert compile!(search, %{}, search_path: %{response: %{type: "json"}}).format == :json
    assert compile!(search, %{}, search_path: %{"response" => %{"type" => "xml"}}).format == :xml
    assert compile!(search, %{}, search_path: %{response: %{"type" => "xml"}}).format == :xml
    assert compile!(search, %{}, search_path: %{"response" => %{type: "html"}}).format == :html
    assert compile!(search, %{}, search_path: %{path: "/"}).format == nil
    assert compile!(search).format == nil
  end

  test "text_field?/1 accepts any non-empty scalar text" do
    alias Mydia.Indexers.Cardigann.TextFields
    assert TextFields.text_field?(%{text: 1})
    assert TextFields.text_field?(%{"text" => "a"})
    refute TextFields.text_field?(%{text: ""})
    refute TextFields.text_field?(%{text: nil})
    refute TextFields.text_field?("x")
  end

  test "case keeps the * default last" do
    plan =
      compile!(%{
        rows: %{selector: "tr"},
        fields: %{quality: %{selector: "td", case: %{"*" => "1", "b" => "3", "a" => "2"}}}
      })

    [field] = plan.selector_fields
    assert field.case == [{"a", "2"}, {"b", "3"}, {"*", "1"}]
  end
end
