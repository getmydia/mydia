defmodule Mydia.Indexers.Cardigann.TemplateContextTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.TemplateContext
  alias Mydia.Indexers.CardigannDefinition.Parsed

  defp definition(links),
    do: %Parsed{
      id: "ctx",
      name: "Ctx",
      links: links,
      settings: [],
      search: %{keywordsfilters: []}
    }

  describe ".Config.sitelink" do
    test "is the first link, with the trailing slash Prowlarr's links carry" do
      context =
        TemplateContext.build(
          definition(["https://copper.example/", "https://mirror.example/"]),
          []
        )

      assert context.config["sitelink"] == "https://copper.example/"
    end

    test "is the active base url when there is one" do
      context =
        TemplateContext.build(definition(["https://copper.example/"]),
          base_url: "https://mirror.example"
        )

      assert context.config["sitelink"] == "https://mirror.example/"
    end

    test "yields to a setting of that name" do
      context =
        TemplateContext.build(definition(["https://copper.example/"]),
          config: %{"sitelink" => "https://own.example/"}
        )

      assert context.config["sitelink"] == "https://own.example/"
    end
  end
end
