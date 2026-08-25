defmodule MydiaWeb.MediaRequestComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Media.MediaRequest
  alias MydiaWeb.MediaRequestComponents

  defp render_card(request, opts \\ []) do
    assigns = Enum.into(opts, %{request: request})

    render_component(&MediaRequestComponents.request_card/1, assigns)
    |> LazyHTML.from_fragment()
  end

  defp movie_request(attrs \\ %{}) do
    struct!(
      %MediaRequest{
        id: "11111111-1111-1111-1111-111111111111",
        media_type: "movie",
        title: "Stub Movie",
        year: 1999,
        status: "pending",
        tmdb_id: 550
      },
      attrs
    )
  end

  test "renders the poster at w185 when a path is stored" do
    doc = render_card(movie_request(%{poster_path: "/stub-movie-poster.jpg"}))

    assert [_ | _] =
             LazyHTML.query(
               doc,
               ~s(img[src="https://image.tmdb.org/t/p/w185/stub-movie-poster.jpg"])
             )
             |> Enum.to_list()
  end

  test "falls back to the placeholder when there is no poster" do
    doc = render_card(movie_request())

    assert [_ | _] = LazyHTML.query(doc, ~s(img[src="/images/no-poster.svg"])) |> Enum.to_list()
  end

  test "passes a full TVDB artwork URL through untouched" do
    doc = render_card(movie_request(%{poster_path: "https://artworks.thetvdb.com/p.jpg"}))

    assert [_ | _] =
             LazyHTML.query(doc, ~s(img[src="https://artworks.thetvdb.com/p.jpg"]))
             |> Enum.to_list()
  end

  test "the title is a click target for a resolvable request" do
    doc = render_card(movie_request())

    assert [_ | _] =
             LazyHTML.query(
               doc,
               ~s(button[phx-click="show_details"][phx-value-id="11111111-1111-1111-1111-111111111111"])
             )
             |> Enum.to_list()
  end

  test "an imdb-only request has no click target" do
    doc = render_card(movie_request(%{tmdb_id: nil, imdb_id: "tt0137523"}))

    assert [] = LazyHTML.query(doc, ~s(button[phx-click="show_details"])) |> Enum.to_list()
  end

  test "renders the badges, details and actions slots" do
    doc =
      render_component(&MediaRequestComponents.request_card/1, %{
        request: movie_request(),
        badges: [
          %{
            __slot__: :badges,
            inner_block: fn _, _ -> {:safe, ~s(<span id="slot-badge"></span>)} end
          }
        ],
        details: [
          %{
            __slot__: :details,
            inner_block: fn _, _ -> {:safe, ~s(<span id="slot-detail"></span>)} end
          }
        ],
        actions: [
          %{
            __slot__: :actions,
            inner_block: fn _, _ -> {:safe, ~s(<span id="slot-action"></span>)} end
          }
        ]
      })
      |> LazyHTML.from_fragment()

    assert [_] = LazyHTML.query(doc, "#slot-badge") |> Enum.to_list()
    assert [_] = LazyHTML.query(doc, "#slot-detail") |> Enum.to_list()
    assert [_] = LazyHTML.query(doc, "#slot-action") |> Enum.to_list()
  end

  test "status helpers cover every stored status" do
    assert MediaRequestComponents.status_text("pending") == "Pending Review"
    assert MediaRequestComponents.status_text("approved") == "Approved"
    assert MediaRequestComponents.status_text("rejected") == "Rejected"
    assert MediaRequestComponents.status_badge_class("pending") == "badge-warning"
    assert MediaRequestComponents.status_badge_class("approved") == "badge-success"
    assert MediaRequestComponents.status_badge_class("rejected") == "badge-error"
  end

  test "format_date handles a missing timestamp" do
    assert MediaRequestComponents.format_date(nil) == "N/A"
    assert MediaRequestComponents.format_date(~U[2026-08-24 15:04:05Z]) =~ "Aug 24, 2026"
  end
end
