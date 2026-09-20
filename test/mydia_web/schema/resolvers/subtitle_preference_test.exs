defmodule MydiaWeb.Schema.Resolvers.SubtitlePreferenceTest do
  use MydiaWeb.ConnCase, async: false

  import Mydia.MediaFixtures

  alias Mydia.AccountsFixtures
  alias MydiaWeb.Schema.Resolvers.StreamingResolver

  # Invented titles: no fixture in this file may name a real film or show.
  @film_title "Emberfall Reach"
  @show_title "Harrowgate Hollow"

  @mutation """
  mutation Set($fileId: ID!, $mode: SubtitlePreferenceMode!, $language: String,
               $forced: Boolean, $hearingImpaired: Boolean, $trackTitle: String) {
    setSubtitlePreference(fileId: $fileId, mode: $mode, language: $language,
                          forced: $forced, hearingImpaired: $hearingImpaired,
                          trackTitle: $trackTitle) {
      mediaItemId
      preference { mode language forced hearingImpaired trackTitle }
    }
  }
  """

  @film_files_query """
  query Film($id: ID!) {
    movie(id: $id) {
      files { preferredSubtitle { mode language forced hearingImpaired trackTitle } }
    }
  }
  """

  @episode_files_query """
  query Episode($id: ID!) {
    episode(id: $id) {
      files { preferredSubtitle { mode language forced hearingImpaired trackTitle } }
    }
  }
  """

  defp authed_fixture(conn) do
    user = AccountsFixtures.user_fixture()
    conn = log_in_user(conn, user)

    film = media_item_fixture(%{type: "movie", title: @film_title})
    film_file = media_file_fixture(%{media_item_id: film.id})

    show = media_item_fixture(%{type: "tv_show", title: @show_title})
    episode = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})
    episode_file = media_file_fixture(%{episode_id: episode.id})

    %{
      conn: conn,
      user: user,
      media_item: film,
      media_file: film_file,
      show: show,
      episode: episode,
      episode_file: episode_file
    }
  end

  defp unauthed_fixture do
    %{media_file: media_file_fixture(%{media_item_id: media_item_fixture(%{type: "movie"}).id})}
  end

  defp graphql(conn, query, variables) do
    conn
    |> post("/api/graphql", %{"query" => query, "variables" => variables})
    |> json_response(200)
  end

  describe "setSubtitlePreference" do
    test "stores a track choice and reads it back off the media file", %{conn: conn} do
      %{conn: conn, media_file: media_file, media_item: media_item} = authed_fixture(conn)

      result =
        graphql(conn, @mutation, %{
          "fileId" => media_file.id,
          "mode" => "TRACK",
          "language" => "eng",
          "forced" => true,
          "trackTitle" => "English (Signs & Songs)"
        })

      assert result["data"]["setSubtitlePreference"]["mediaItemId"] == media_item.id

      preference = result["data"]["setSubtitlePreference"]["preference"]
      assert preference["mode"] == "TRACK"
      assert preference["language"] == "eng"
      assert preference["forced"] == true
      assert preference["hearingImpaired"] == false
      assert preference["trackTitle"] == "English (Signs & Songs)"

      # The name says read back, so it does: the same descriptor has to come
      # off the file on a later query, not just off the mutation's echo.
      assert [%{"preferredSubtitle" => stored}] =
               files_of(graphql(conn, @film_files_query, %{"id" => media_item.id}), "movie")

      assert stored == preference
    end

    test "stores an explicit off", %{conn: conn} do
      %{conn: conn, media_file: media_file} = authed_fixture(conn)

      result = graphql(conn, @mutation, %{"fileId" => media_file.id, "mode" => "OFF"})

      # A stored off carries no track, so the flags are reported as false
      # rather than left null: the contract declares them non-null.
      assert result["data"]["setSubtitlePreference"]["preference"] == %{
               "mode" => "OFF",
               "language" => nil,
               "forced" => false,
               "hearingImpaired" => false,
               "trackTitle" => nil
             }
    end

    test "stores a choice made on an episode against the show", %{conn: conn} do
      %{conn: conn, episode_file: episode_file, show: show} = authed_fixture(conn)

      result =
        graphql(conn, @mutation, %{
          "fileId" => episode_file.id,
          "mode" => "TRACK",
          "language" => "eng"
        })

      assert result["data"]["setSubtitlePreference"]["mediaItemId"] == show.id
    end

    test "returns a GraphQL error rather than crashing on a file id that is not in the library",
         %{conn: conn} do
      %{conn: conn} = authed_fixture(conn)

      result = graphql(conn, @mutation, %{"fileId" => Ecto.UUID.generate(), "mode" => "OFF"})

      assert [%{"message" => "File not found"}] = result["errors"]
    end

    test "refuses an unauthenticated caller", %{conn: conn} do
      %{media_file: media_file} = unauthed_fixture()

      result = graphql(conn, @mutation, %{"fileId" => media_file.id, "mode" => "OFF"})

      assert [%{"message" => "Authentication required"}] = result["errors"]
    end
  end

  describe "mediaFile.preferredSubtitle" do
    test "reports the stored choice on a film's file", %{conn: conn} do
      %{conn: conn, media_file: media_file, media_item: film} = authed_fixture(conn)

      graphql(conn, @mutation, %{
        "fileId" => media_file.id,
        "mode" => "TRACK",
        "language" => "eng",
        "hearingImpaired" => true
      })

      assert [file] = files_of(graphql(conn, @film_files_query, %{"id" => film.id}), "movie")

      assert file["preferredSubtitle"] == %{
               "mode" => "TRACK",
               "language" => "eng",
               "forced" => false,
               "hearingImpaired" => true,
               "trackTitle" => nil
             }
    end

    # A TV file reaches its show only through the episode, and `episode {
    # files }` loads media files without that association, so this is where a
    # missed preload shows up as a silently missing preference. A choice made
    # on one episode is the point of the feature, so it is asserted on the
    # next one rather than on the file it was made on.
    test "reports the stored choice on every episode of the show", %{conn: conn} do
      %{conn: conn, episode_file: episode_file, show: show} = authed_fixture(conn)

      later =
        episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 2})

      media_file_fixture(%{episode_id: later.id})

      graphql(conn, @mutation, %{"fileId" => episode_file.id, "mode" => "OFF"})

      assert [file] =
               files_of(graphql(conn, @episode_files_query, %{"id" => later.id}), "episode")

      assert file["preferredSubtitle"] == %{
               "mode" => "OFF",
               "language" => nil,
               "forced" => false,
               "hearingImpaired" => false,
               "trackTitle" => nil
             }
    end

    # Every root field is fail-closed on authentication, so no query can reach
    # this field without a user and the branch cannot be exercised through
    # GraphQL. Called directly instead, with the resolution-shaped argument the
    # resolver actually reads.
    test "reports null to a caller with no user in the context" do
      media_file = media_file_fixture(%{media_item_id: media_item_fixture(%{type: "movie"}).id})

      assert {:ok, nil} =
               StreamingResolver.preferred_subtitle(media_file, %{}, %{context: %{}})
    end
  end

  defp files_of(%{"data" => %{"movie" => %{"files" => files}}}, "movie"), do: files
  defp files_of(%{"data" => %{"episode" => %{"files" => files}}}, "episode"), do: files
end
