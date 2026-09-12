defmodule MydiaWeb.Schema.SubtitleTest do
  use MydiaWeb.ConnCase

  alias Mydia.Accounts.Scope
  alias Mydia.MediaFixtures
  alias Mydia.AccountsFixtures

  @movie_with_subtitles_query """
  query Movie($id: ID!) {
    movie(id: $id) {
      id
      title
      files {
        id
        resolution
        subtitles {
          trackId
          language
          title
          format
          embedded
          url(format: VTT)
        }
      }
    }
  }
  """

  @episode_with_subtitles_query """
  query Episode($id: ID!) {
    episode(id: $id) {
      id
      title
      files {
        id
        subtitles {
          trackId
          language
          title
          format
          embedded
          url(format: SRT)
        }
      }
    }
  }
  """

  describe "media file subtitles field" do
    setup do
      user = AccountsFixtures.user_fixture()
      %{user: user}
    end

    test "returns empty list when media file has no subtitles", %{user: user} do
      # Create a movie with a media file
      media_item = MediaFixtures.media_item_fixture(%{type: "movie", title: "Test Movie"})
      media_file = MediaFixtures.media_file_fixture(%{media_item_id: media_item.id})

      variables = %{"id" => media_item.id}
      result = run_query(@movie_with_subtitles_query, variables, user)

      assert {:ok, %{data: %{"movie" => movie}}} = result
      assert movie["title"] == "Test Movie"
      assert length(movie["files"]) == 1

      [file] = movie["files"]
      assert file["id"] == media_file.id
      # Empty list since the test file doesn't exist and has no embedded subtitles
      assert file["subtitles"] == []
    end

    test "includes subtitles field for episode files", %{user: user} do
      # Create an episode with a media file
      media_item = MediaFixtures.media_item_fixture(%{type: "tv_show", title: "Test Show"})

      episode =
        MediaFixtures.episode_fixture(%{media_item_id: media_item.id, title: "Test Episode"})

      media_file = MediaFixtures.media_file_fixture(%{episode_id: episode.id})

      variables = %{"id" => episode.id}
      result = run_query(@episode_with_subtitles_query, variables, user)

      assert {:ok, %{data: %{"episode" => episode_data}}} = result
      assert episode_data["title"] == "Test Episode"
      assert length(episode_data["files"]) == 1

      [file] = episode_data["files"]
      assert file["id"] == media_file.id
      assert file["subtitles"] == []
    end
  end

  describe "subtitle track type fields" do
    test "subtitle track has all required fields" do
      # Verify the schema has the expected types by introspection
      query = """
      {
        __type(name: "SubtitleTrack") {
          fields {
            name
            type {
              name
              kind
              ofType {
                name
                kind
              }
            }
          }
        }
      }
      """

      result = run_query(query, %{})

      assert {:ok, %{data: %{"__type" => type}}} = result
      assert type != nil

      fields = type["fields"]
      field_names = Enum.map(fields, & &1["name"])

      assert "trackId" in field_names
      assert "language" in field_names
      assert "title" in field_names
      assert "format" in field_names
      assert "embedded" in field_names
      assert "url" in field_names
    end
  end

  describe "subtitle format enum" do
    test "subtitle format enum has all expected values" do
      query = """
      {
        __type(name: "SubtitleFormat") {
          enumValues {
            name
          }
        }
      }
      """

      result = run_query(query, %{})

      assert {:ok, %{data: %{"__type" => type}}} = result
      assert type != nil

      values = Enum.map(type["enumValues"], & &1["name"])

      assert "SRT" in values
      assert "VTT" in values
      assert "ASS" in values
      assert "PGS" in values
    end
  end

  # Helper function to run GraphQL queries
  defp run_query(query, variables, user \\ nil) do
    context =
      if user, do: %{current_user: user, current_scope: Scope.for_user(user)}, else: %{}

    Absinthe.run(query, MydiaWeb.Schema, variables: variables, context: context)
  end
end
