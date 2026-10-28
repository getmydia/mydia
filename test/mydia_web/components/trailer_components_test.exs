defmodule MydiaWeb.TrailerComponentsTest do
  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Metadata.Structs.Video
  alias MydiaWeb.TrailerComponents

  defp video(key, name), do: %Video{key: key, site: "YouTube", name: name, type: "Trailer"}

  defp render_player(videos, opts \\ []) do
    render_component(&TrailerComponents.trailer_player/1,
      id: "test-trailer",
      videos: videos,
      autoplay: Keyword.get(opts, :autoplay, false)
    )
    |> LazyHTML.from_fragment()
  end

  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  test "passes the YouTube keys to the hook in order" do
    doc =
      render_player([video("a1", "Main"), %Video{key: "v", site: "Vimeo"}, video("b2", "Teaser")])

    container = LazyHTML.query(doc, "#test-trailer")
    assert LazyHTML.attribute(container, "phx-hook") == ["TrailerPlayer"]
    assert LazyHTML.attribute(container, "phx-update") == ["ignore"]
    assert LazyHTML.attribute(container, "data-keys") == [~s(["a1","b2"])]
    assert LazyHTML.attribute(container, "data-autoplay") == ["false"]
  end

  test "renders one switcher button per video when there are two or more" do
    doc = render_player([video("a1", "Main Trailer"), video("b2", nil)])

    buttons = LazyHTML.query(doc, ~s([data-role="switcher"] button[data-index]))
    assert LazyHTML.attribute(buttons, "data-index") == ["0", "1"]
    assert LazyHTML.text(buttons) =~ "Main Trailer"
    assert LazyHTML.text(buttons) =~ "Trailer 2"
  end

  test "renders no switcher for a single video" do
    doc = render_player([video("a1", "Main")])

    assert count(doc, ~s([data-role="switcher"])) == 0
  end

  test "the unavailable message links to the first trailer on YouTube" do
    doc = render_player([video("a1", "Main"), video("b2", "Other")])

    link = LazyHTML.query(doc, ~s([data-role="unavailable"] a))
    assert LazyHTML.attribute(link, "href") == ["https://www.youtube.com/watch?v=a1"]
  end

  test "renders nothing without YouTube videos" do
    doc = render_player([%Video{key: "v", site: "Vimeo"}])

    assert count(doc, "#test-trailer") == 0
  end

  test "autoplay is forwarded" do
    doc = render_player([video("a1", "Main")], autoplay: true)

    assert LazyHTML.query(doc, "#test-trailer") |> LazyHTML.attribute("data-autoplay") == ["true"]
  end
end
