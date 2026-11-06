defmodule MydiaWeb.PersonComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Metadata.Structs.{Person, PersonCredit, SearchResult}
  alias MydiaWeb.PersonComponents

  defp credit(id, type \\ :movie),
    do: %PersonCredit{
      tmdb_id: id,
      media_type: type,
      title: "Title #{id}",
      year: 2020,
      poster_path: "/p#{id}.jpg"
    }

  defp title(id, type \\ :movie, owned \\ false),
    do:
      %SearchResult{
        provider_id: Integer.to_string(id),
        provider: :tmdb,
        media_type: type,
        title: "Title #{id}"
      }
      |> Map.put(:in_library, owned)

  defp person(attrs \\ []) do
    struct!(%Person{tmdb_id: 1, name: "Test Person", biography: "A bio."}, attrs)
  end

  defp render_modal(assigns) do
    assigns = Map.merge(%{id: "person-modal", escape_enabled: true}, Map.new(assigns))
    render_component(&PersonComponents.person_modal/1, assigns) |> LazyHTML.from_fragment()
  end

  defp text(doc, selector),
    do: doc |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  test "renders name, bio and the owned count" do
    p = person(movie_credits: [credit(1), credit(2), credit(3)])
    titles = [title(1, :movie, true), title(2, :movie, true), title(3)]
    doc = render_modal(person: p, titles: titles)

    assert text(doc, "#person-modal-name") == "Test Person"
    assert text(doc, "#person-bio") == "A bio."
    assert text(doc, "#person-owned-count") == "2 in your library"
  end

  test "an owned poster carries the check badge and an unowned one does not" do
    p = person(movie_credits: [credit(1), credit(2)])
    doc = render_modal(person: p, titles: [title(1, :movie, true), title(2)])

    assert count(doc, "#person-credit-movie-1 .badge-success") == 1
    assert count(doc, "#person-credit-movie-2 .badge-success") == 0
  end

  test "only twelve posters are visible of thirty, with a Show all button" do
    ids = Enum.to_list(1..30)
    p = person(movie_credits: Enum.map(ids, &credit/1))
    doc = render_modal(person: p, titles: Enum.map(ids, &title/1))

    assert count(doc, "#person-movies button[id^=person-credit-movie-]") == 30
    assert count(doc, "#person-movies button[id^=person-credit-movie-]:not([data-extra])") == 12
    assert text(doc, "#person-movies-show-all") == "Show all 30"

    # The hiding is the class, not the marker: assert both halves of it.
    for id <- 1..30 do
      [class] = LazyHTML.attribute(LazyHTML.query(doc, "#person-credit-movie-#{id}"), "class")
      assert String.contains?(class, "group-[:not(.expanded)]/credits:hidden") == id > 12
    end

    [click] = LazyHTML.attribute(LazyHTML.query(doc, "#person-movies-show-all"), "phx-click")
    assert click =~ "#person-movies"
    assert click =~ "expanded"
  end

  # "In library" expands the section without touching the button, so the
  # button must hide on the section's class, not on its own click.
  test "Show all hides with any expanded section and the filter marks its state" do
    ids = Enum.to_list(1..30)
    p = person(movie_credits: Enum.map(ids, &credit/1))
    doc = render_modal(person: p, titles: [title(1, :movie, true) | Enum.map(2..30, &title/1)])

    [show_all_class] = LazyHTML.attribute(LazyHTML.query(doc, "#person-movies-show-all"), "class")
    assert show_all_class =~ "group-[.expanded]/credits:hidden"

    [all_class] = LazyHTML.attribute(LazyHTML.query(doc, "#person-movies-filter-all"), "class")

    [owned_class] =
      LazyHTML.attribute(LazyHTML.query(doc, "#person-movies-filter-owned"), "class")

    assert all_class =~ "group-[:not(.owned-only)]/credits:btn-active"
    assert owned_class =~ "group-[.owned-only]/credits:btn-active"
  end

  test "no TV credits means no shows section" do
    doc = render_modal(person: person(movie_credits: [credit(1)]), titles: [title(1)])

    assert count(doc, "#person-movies") == 1
    assert count(doc, "#person-shows") == 0
  end

  test "a credit the filter removed is not rendered" do
    p = person(movie_credits: [credit(1), credit(2)])
    doc = render_modal(person: p, titles: [title(1)])

    assert count(doc, "#person-credit-movie-1") == 1
    assert count(doc, "#person-credit-movie-2") == 0
  end

  test "the bio toggle swaps its label between Read more and Show less" do
    doc = render_modal(person: person(), titles: [])

    assert text(doc, "#person-bio-toggle > span:not(.hidden)") == "Read more"
    assert text(doc, "#person-bio-toggle > span.hidden") == "Show less"

    [click] = LazyHTML.attribute(LazyHTML.query(doc, "#person-bio-toggle"), "phx-click")
    assert click =~ "#person-bio-toggle > span"
    # Expanded, the bio scrolls in a bounded box rather than growing the
    # header past the popup's height.
    assert click =~ ~s("max-h-[30vh]","overflow-y-auto")
  end

  test "opening moves focus to the close button and keeps Tab inside the popup" do
    doc = render_modal(person: person(), titles: [])

    [mounted] = LazyHTML.attribute(LazyHTML.query(doc, "#person-modal-box"), "phx-mounted")
    assert mounted =~ "#person-modal-close"

    assert LazyHTML.attribute(LazyHTML.query(doc, "#person-modal-box"), "phx-hook") == [
             "Phoenix.FocusWrap"
           ]
  end

  test "no biography renders no bio block" do
    doc = render_modal(person: person(biography: nil), titles: [])

    assert count(doc, "#person-bio-block") == 0
  end

  test "an error renders the retry button and the stub's name" do
    doc =
      render_modal(
        person: nil,
        stub: %{id: 9, name: "Stub Name", profile_path: nil},
        error: :boom
      )

    assert count(doc, "#person-modal-error") == 1
    assert count(doc, "#person-modal-retry") == 1
    assert text(doc, "#person-modal-error") =~ "Stub Name"
  end

  test "escape binding follows escape_enabled" do
    p = person()

    assert render_modal(person: p, escape_enabled: true)
           |> LazyHTML.query("#person-modal")
           |> LazyHTML.attribute("phx-window-keydown") == ["close_person"]

    assert render_modal(person: p, escape_enabled: false)
           |> LazyHTML.query("#person-modal")
           |> LazyHTML.attribute("phx-window-keydown") == []
  end

  describe "cast_person/1" do
    defp render_cast(member, event) do
      render_component(&PersonComponents.cast_person/1, member: member, event: event)
      |> LazyHTML.from_fragment()
    end

    test "nil event renders a plain card, even for a linked member" do
      doc =
        render_cast(
          %{name: "An Actor", character: "Role", profile_path: nil, tmdb_person_id: 7},
          nil
        )

      assert Enum.empty?(LazyHTML.query(doc, "button"))
      assert Enum.empty?(LazyHTML.query(doc, "[id^=cast-person-]"))
      assert LazyHTML.text(doc) =~ "An Actor"
      assert LazyHTML.text(doc) =~ "Role"
    end

    test "event with an id renders a button carrying the popup payload" do
      doc =
        render_cast(
          %{name: "An Actor", character: nil, profile_path: "/a.jpg", tmdb_person_id: 7},
          "show_person"
        )

      button = LazyHTML.query(doc, "#cast-person-7-0")
      assert LazyHTML.attribute(button, "phx-click") == ["show_person"]
      assert LazyHTML.attribute(button, "phx-value-id") == ["7"]
      assert LazyHTML.attribute(button, "phx-value-name") == ["An Actor"]
      assert LazyHTML.attribute(button, "phx-value-profile_path") == ["/a.jpg"]
    end

    test "an actor listed twice gets a distinct id per entry" do
      member = %{name: "An Actor", character: nil, profile_path: nil, tmdb_person_id: 7}

      ids =
        for index <- [0, 1] do
          render_component(&PersonComponents.cast_person/1,
            member: member,
            event: "show_person",
            index: index
          )
          |> LazyHTML.from_fragment()
          |> LazyHTML.query("button")
          |> LazyHTML.attribute("id")
        end

      assert ids == [["cast-person-7-0"], ["cast-person-7-1"]]
    end

    test "an unlinked member links to a people search for their name" do
      doc = render_cast(%{name: "An Actor", character: nil, profile_path: nil}, "show_person")
      link = LazyHTML.query(doc, "a#cast-person-search-0")

      assert search_params(link) == %{"type" => "person", "q" => "An Actor"}
      assert LazyHTML.attribute(link, "data-tip") == ["Search for An Actor"]
      assert Enum.empty?(LazyHTML.query(doc, "button"))
      assert Enum.empty?(LazyHTML.query(doc, ".opacity-60"))
    end

    test "an unlinked name with reserved characters round-trips into the search" do
      name = "Zoë & Ash #2"
      doc = render_cast(%{name: name, character: nil, profile_path: nil}, "show_person")

      assert doc |> LazyHTML.query("a#cast-person-search-0") |> search_params() ==
               %{"type" => "person", "q" => name}
    end

    defp search_params(link) do
      [href] = LazyHTML.attribute(link, "href")
      uri = URI.parse(href)
      assert uri.path == "/discover"
      URI.decode_query(uri.query)
    end
  end
end
