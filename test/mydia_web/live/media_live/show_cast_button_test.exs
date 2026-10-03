defmodule MydiaWeb.MediaLive.ShowCastButtonTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Metadata.Structs.{CastMember, MediaMetadata}

  setup %{conn: conn} do
    {conn, _user} = register_and_log_in_user(conn)
    %{conn: conn}
  end

  test "a TV show with cast renders the Cast button", %{conn: conn} do
    item =
      media_item_fixture(%{
        type: "tv_show",
        title: "The Lantern Coast",
        metadata: %MediaMetadata{
          provider_id: "1",
          provider: :tvdb,
          media_type: :tv_show,
          cast: [%CastMember{name: "Orla Venn", character: "Captain Mara Quill", order: 0}]
        }
      })

    {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")

    assert has_element?(view, "#cast-button")
  end
end
