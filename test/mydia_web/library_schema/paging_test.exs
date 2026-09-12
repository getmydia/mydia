defmodule MydiaWeb.LibrarySchema.PagingTest do
  use MydiaWeb.ConnCase

  alias Mydia.LibraryApi.Principal
  alias MydiaWeb.LibrarySchema.Paging

  describe "page_size/3" do
    test "nil takes the default and 1..cap passes" do
      assert Paging.page_size(nil, 50, 200) == {:ok, 50}
      assert Paging.page_size(1, 50, 200) == {:ok, 1}
      assert Paging.page_size(200, 50, 200) == {:ok, 200}
    end

    test "outside 1..cap is INVALID_INPUT, not clamped" do
      assert {:error, %{extensions: %{code: "INVALID_INPUT"}, message: message}} =
               Paging.page_size(0, 50, 200)

      assert message == "first must be between 1 and 200, got 0"
      assert {:error, %{extensions: %{code: "INVALID_INPUT"}}} = Paging.page_size(201, 50, 200)
    end
  end

  describe "decode_cursor/1" do
    test "nil passes through and garbage is INVALID_INPUT" do
      assert Paging.decode_cursor(nil) == {:ok, nil}

      assert {:error, %{message: "Invalid cursor", extensions: %{code: "INVALID_INPUT"}}} =
               Paging.decode_cursor("not a cursor")
    end
  end

  describe "cost/4" do
    test "prices first clamped to 1..cap" do
      assert Paging.cost(%{}, 50, 200, 3) == 150
      assert Paging.cost(%{first: 10}, 50, 200, 3) == 30
      assert Paging.cost(%{first: 10_000}, 50, 200, 3) == 600
      assert Paging.cost(%{first: -5}, 50, 200, 3) == 3
    end
  end

  test "mediaItems repeats the cursor it was given on an empty page" do
    insert(:media_item)
    admin = %Principal{role: "admin", source: :env}

    page = fn variables ->
      {:ok, %{data: %{"mediaItems" => connection}}} =
        Absinthe.run(
          """
          query P($after: String) {
            mediaItems(first: 200, after: $after) { edges { node { id } } pageInfo { endCursor } }
          }
          """,
          MydiaWeb.LibrarySchema,
          variables: variables,
          context: %{principal: admin}
        )

      connection
    end

    cursor = page.(%{})["pageInfo"]["endCursor"]
    assert is_binary(cursor)

    assert page.(%{"after" => cursor}) == %{"edges" => [], "pageInfo" => %{"endCursor" => cursor}}
  end
end
