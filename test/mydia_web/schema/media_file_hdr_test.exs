defmodule MydiaWeb.Schema.MediaFileHdrTest do
  @moduledoc """
  Regression coverage for the `MediaFile.hdrFormat` wire format (Task 10).

  `media_files.hdr_format` is an `Ecto.Enum` atom internally (`:hdr10`,
  `:dolby_vision`-shaped profiles via `dolby_vision_profile`, etc). Self-hosted
  installs have no coordinated deploy order, so a shipped Flutter player built
  months ago can reach a server running this code. That player reads
  `hdrFormat` as a human display string ("HDR10", "Dolby Vision", "HLG"), so
  the GraphQL resolver must always convert through `Mydia.Library.Hdr.display/1`
  rather than echoing the raw enum atom.
  """

  use MydiaWeb.ConnCase, async: false

  import Mydia.MediaFixtures

  @query """
  query ($id: ID!) {
    movie(id: $id) {
      files {
        hdrFormat
        dolbyVisionProfile
        dolbyVisionBlCompatId
      }
    }
  }
  """

  setup %{conn: conn} do
    {user, token} = create_user_and_token()

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> put_req_header("content-type", "application/json")

    %{conn: conn, user: user}
  end

  defp run_query(conn, movie) do
    conn = post(conn, "/api/graphql", %{query: @query, variables: %{"id" => movie.id}})
    %{"data" => %{"movie" => %{"files" => [file]}}} = json_response(conn, 200)
    file
  end

  describe "MediaFile HDR fields" do
    test "a Dolby Vision profile 8 file reports the display string and raw profile fields", %{
      conn: conn
    } do
      # Guards against the wire format regressing to the raw Ecto.Enum atom
      # ("hdr10") rather than the compatibility-contract display string
      # ("Dolby Vision"). Every DV profile, including 8.1 (HDR10-compatible
      # base), must render as "Dolby Vision", never the base alone.
      movie = media_item_fixture(%{type: "movie"})

      media_file_fixture(%{
        media_item_id: movie.id,
        hdr_format: :hdr10,
        dolby_vision_profile: 8,
        dolby_vision_bl_compat_id: 1
      })

      file = run_query(conn, movie)

      assert file["hdrFormat"] == "Dolby Vision"
      assert file["dolbyVisionProfile"] == 8
      assert file["dolbyVisionBlCompatId"] == 1
    end

    test "a plain HDR10 file (no Dolby Vision) reports the HDR10 display string", %{conn: conn} do
      movie = media_item_fixture(%{type: "movie"})

      media_file_fixture(%{
        media_item_id: movie.id,
        hdr_format: :hdr10,
        dolby_vision_profile: nil,
        dolby_vision_bl_compat_id: nil
      })

      file = run_query(conn, movie)

      assert file["hdrFormat"] == "HDR10"
      assert file["dolbyVisionProfile"] == nil
      assert file["dolbyVisionBlCompatId"] == nil
    end

    test "an SDR file reports null for every HDR field", %{conn: conn} do
      movie = media_item_fixture(%{type: "movie"})

      media_file_fixture(%{
        media_item_id: movie.id,
        hdr_format: nil,
        dolby_vision_profile: nil,
        dolby_vision_bl_compat_id: nil
      })

      file = run_query(conn, movie)

      assert file["hdrFormat"] == nil
      assert file["dolbyVisionProfile"] == nil
    end

    test "a Dolby Vision profile 5 file (no HDR10-compatible base) still reports Dolby Vision",
         %{conn: conn} do
      # Profile 5 has no HDR10-compatible base layer, so hdr_format (base) is
      # nil by design. hdr_format == nil must NOT be read as SDR here.
      movie = media_item_fixture(%{type: "movie"})

      media_file_fixture(%{
        media_item_id: movie.id,
        hdr_format: nil,
        dolby_vision_profile: 5,
        dolby_vision_bl_compat_id: 0
      })

      file = run_query(conn, movie)

      assert file["hdrFormat"] == "Dolby Vision"
      assert file["dolbyVisionProfile"] == 5
    end
  end
end
