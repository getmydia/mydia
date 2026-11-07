defmodule MydiaWeb.MediaLive.ShowCastButtonTest do
  @moduledoc """
  The media page's cast row, always visible under the overview, and the Crew
  dropdown beside the overview, which lists crew only.
  """

  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures

  alias Mydia.Metadata.Structs.{CastMember, CrewMember, MediaMetadata}

  setup %{conn: conn} do
    {conn, _user} = register_and_log_in_user(conn)
    %{conn: conn}
  end

  defp show(cast, crew) do
    media_item_fixture(%{
      type: "tv_show",
      title: "The Lantern Coast",
      metadata: %MediaMetadata{
        provider_id: "1",
        provider: :tvdb,
        media_type: :tv_show,
        cast: cast,
        crew: crew
      }
    })
  end

  defp actor(i),
    do: %CastMember{
      name: "Orla Venn #{i}",
      character: "Deckhand #{i}",
      order: i,
      tmdb_person_id: 900 + i
    }

  test "the cast row is visible without opening anything", %{conn: conn} do
    item = show([actor(0)], [])

    {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")

    assert has_element?(view, "#media-cast-row #media-cast-person-900-0", "Orla Venn 0")
    assert has_element?(view, "#media-cast-row #media-cast-person-900-0", "Deckhand 0")
  end

  test "the cast row holds the first 15 billed", %{conn: conn} do
    item = show(Enum.map(0..19, &actor/1), [])

    {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")

    assert has_element?(view, "#media-cast-person-914-14")
    refute has_element?(view, "#media-cast-person-915-15")
  end

  test "the Crew dropdown lists crew and no cast", %{conn: conn} do
    item =
      show([actor(0)], [
        CrewMember.new(name: "Ines Marrow", job: "Director", department: "Directing"),
        CrewMember.new(name: "Teo Valk", job: "Writer", department: "Writing")
      ])

    {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")

    assert has_element?(view, "#crew-button", "Crew")
    assert has_element?(view, "#crew-list", "Ines Marrow")
    assert has_element?(view, "#crew-list", "Teo Valk")
    refute has_element?(view, "#crew-list", "Orla Venn")
    refute has_element?(view, "#cast-button")
  end

  test "no crew means no Crew button, and no cast means no cast row", %{conn: conn} do
    item = show([actor(0)], [])
    {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")
    refute has_element?(view, "#crew-button")

    bare = show([], [CrewMember.new(name: "Ines Marrow", job: "Director")])
    {:ok, view, _html} = live(conn, ~p"/media/#{bare.id}")
    refute has_element?(view, "#media-cast-row")
    assert has_element?(view, "#crew-button")
  end
end
