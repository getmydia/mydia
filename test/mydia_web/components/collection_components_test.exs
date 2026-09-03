defmodule MydiaWeb.CollectionComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MydiaWeb.CollectionComponents

  test "a collection with multiple posters renders a DaisyUI hover gallery" do
    collection = %{
      id: "collection-1",
      name: "Midnight Movies",
      type: "manual",
      visibility: "private",
      is_system: false
    }

    html =
      render_component(&CollectionComponents.collection_card/1,
        collection: collection,
        href: "/collections/collection-1",
        poster_paths: ["/first.jpg", "/second.jpg", "/third.jpg"]
      )

    fragment = LazyHTML.from_fragment(html)
    galleries = LazyHTML.query(fragment, ".hover-gallery")
    posters = LazyHTML.query(fragment, ".hover-gallery > img")

    assert Enum.count(galleries) == 1
    assert Enum.count(posters) == 3

    assert LazyHTML.attribute(posters, "src")
           |> Enum.map(&URI.decode/1)
           |> Enum.map(&Path.basename/1) == ["first.jpg", "second.jpg", "third.jpg"]

    refute html =~ "group-hover:scale-105"
  end
end
