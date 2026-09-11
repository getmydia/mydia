defmodule MydiaWeb.LibrarySchema.EndpointTest do
  use MydiaWeb.ConnCase

  alias Mydia.Accounts
  alias Mydia.AccountsFixtures

  setup do
    user = AccountsFixtures.admin_user_fixture()

    {:ok, _record, plain} =
      Accounts.create_api_key(user.id, %{name: "Lib", permissions: ["admin"]})

    %{key: plain}
  end

  @profiles_query "{ qualityProfiles { id name } }"

  test "rejects a request with no key", %{} do
    conn = post(build_conn(), "/api/library/graphql", %{"query" => @profiles_query})
    assert conn.status == 401
  end

  test "answers a query with a valid key", %{key: key} do
    conn =
      build_conn()
      |> put_req_header("x-api-key", key)
      |> post("/api/library/graphql", %{"query" => @profiles_query})

    assert conn.status == 200
    assert %{"data" => %{"qualityProfiles" => profiles}} = Jason.decode!(conn.resp_body)
    assert is_list(profiles)
  end
end
