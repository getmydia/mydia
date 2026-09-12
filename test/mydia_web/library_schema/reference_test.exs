defmodule MydiaWeb.LibrarySchema.ReferenceTest do
  use MydiaWeb.ConnCase

  import Mydia.Factory

  alias Mydia.LibraryApi.Principal

  @admin %Principal{role: "admin", source: :api_key}

  @query """
  {
    qualityProfiles { id name }
    libraryPaths { id path type }
  }
  """

  defp run do
    Absinthe.run(@query, MydiaWeb.LibrarySchema, context: %{principal: @admin})
  end

  test "returns quality profiles" do
    profile = insert(:quality_profile)

    assert {:ok, %{data: %{"qualityProfiles" => profiles}}} = run()
    assert Enum.any?(profiles, &(&1["id"] == profile.id and &1["name"] == profile.name))
  end

  test "returns library paths with their type as an enum" do
    path = insert(:library_path, path: "/media/movies", type: :movies)

    assert {:ok, %{data: %{"libraryPaths" => paths}}} = run()

    assert Enum.any?(
             paths,
             &(&1["id"] == path.id and &1["path"] == "/media/movies" and &1["type"] == "MOVIES")
           )
  end

  test "an empty install returns empty lists, not errors" do
    assert {:ok, %{data: %{"qualityProfiles" => profiles, "libraryPaths" => paths}}} = run()
    assert is_list(profiles)
    assert is_list(paths)
  end
end
