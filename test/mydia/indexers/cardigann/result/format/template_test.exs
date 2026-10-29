defmodule Mydia.Indexers.Cardigann.Result.Format.TemplateTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Result.Format.Template

  test "renders a templated string against the context" do
    assert Template.render("td.{{ .Result.kind }}", context: %{result: %{kind: "q"}}) == "td.q"
  end

  test "leaves a string alone without a context or without a template" do
    assert Template.render("td.{{ .Result.kind }}", []) == "td.{{ .Result.kind }}"
    assert Template.render("td.q", context: %{result: %{}}) == "td.q"
  end

  test "passes non-binaries through" do
    assert Template.render(nil, context: %{a: 1}) == nil
  end
end
