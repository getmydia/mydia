defmodule MydiaWeb.Features.CollectionMobileMenuTest do
  @moduledoc """
  Verifies that the collection actions three-dot menu stays inside the mobile
  viewport on short-named smart collections (issue #1433).
  """

  use MydiaWeb.FeatureCase, async: false

  @moduletag :feature

  alias Mydia.Collections

  @tag :feature
  test "three-dot menu on a short-named smart collection fits inside mobile viewports", %{
    session: session
  } do
    user = create_admin_user()
    login(session, user.username, "password123")

    {:ok, collection} =
      Collections.create_collection(user, %{
        name: "Anime",
        type: "smart",
        visibility: "private",
        smart_rules:
          Jason.encode!(%{
            "conditions" => [
              %{"field" => "category", "operator" => "in", "value" => ["anime_movie"]}
            ]
          })
      })

    for {width, height} <- [{320, 640}, {375, 812}, {414, 896}] do
      session
      |> resize_window(width, height)
      |> visit_liveview("/collections/#{collection.id}")
      |> click(Query.css("#collection-actions-trigger"))
      |> assert_in_viewport("#collection-actions-dropdown .dropdown-content")
      |> refute_covered("#collection-actions-dropdown .dropdown-content")
    end
  end
end
