defmodule MydiaWeb.Api.IndexerControllerTest do
  use MydiaWeb.ConnCase, async: true

  setup %{conn: conn} do
    {_admin, token} = MydiaWeb.AuthHelpers.create_user_and_token(%{role: "admin"})
    {:ok, conn: put_req_header(conn, "authorization", "Bearer #{token}")}
  end

  # The race between show/2's config lookup and Health's own lookup cannot be
  # forced from a test; both paths end in the same 404 helper, so this covers
  # the shared response for an id that names nothing.
  describe "GET /api/v1/indexers/:id" do
    test "returns 404 for an unknown indexer", %{conn: conn} do
      conn = get(conn, "/api/v1/indexers/#{Ecto.UUID.generate()}")

      assert %{"error" => "Indexer not found"} = json_response(conn, 404)
    end
  end

  describe "POST /api/v1/indexers/:id/test" do
    test "returns 404 for an unknown indexer", %{conn: conn} do
      conn = post(conn, "/api/v1/indexers/#{Ecto.UUID.generate()}/test")

      assert %{"error" => "Indexer not found"} = json_response(conn, 404)
    end
  end
end
