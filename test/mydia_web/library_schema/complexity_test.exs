defmodule MydiaWeb.LibrarySchema.ComplexityTest do
  use MydiaWeb.ConnCase

  alias Mydia.LibraryApi.Principal

  @admin %Principal{role: "admin", source: :api_key}
  @page """
  query Page($first: Int) {
    mediaItems(first: $first) {
      edges { node { id title status { state } } }
      pageInfo { hasNextPage endCursor }
    }
  }
  """

  # Stop before execution: measuring lookup and downloads must never contact
  # the relay or configured download clients.
  defp complexity(query, variables) do
    pipeline =
      MydiaWeb.LibrarySchema
      |> Absinthe.Pipeline.for_document(analyze_complexity: true, variables: variables)
      |> Absinthe.Pipeline.before(Absinthe.Phase.Document.Execution.Resolution)

    {:ok, blueprint, _phases} = Absinthe.Pipeline.run(query, pipeline)
    blueprint.operations |> hd() |> Map.fetch!(:complexity)
  end

  test "cost scales with first, so a page size is not free" do
    ten = complexity(@page, %{"first" => 10})
    hundred = complexity(@page, %{"first" => 100})
    assert is_integer(ten) and ten > 0
    assert hundred > ten * 9
    assert hundred < ten * 11
  end

  test "omitting first applies the documented default of 50" do
    without_first = """
    {
      mediaItems {
        edges { node { id title status { state } } }
        pageInfo { hasNextPage endCursor }
      }
    }
    """

    assert complexity(without_first, %{}) == complexity(@page, %{"first" => 50})
  end

  test "a first larger than the cap is priced at the cap" do
    assert complexity(@page, %{"first" => 10_000}) == complexity(@page, %{"first" => 200})
  end

  # Analysis runs before any resolver, so a zero or negative page must not lower
  # the document's total: that would let expensive siblings such as downloads,
  # which contacts every client, through a budget they exceed.
  test "a non-positive first is priced as a page of one" do
    assert complexity(@page, %{"first" => 0}) == complexity(@page, %{"first" => 1})
    assert complexity(@page, %{"first" => -10_000}) == complexity(@page, %{"first" => 1})
  end

  test "a negative first cannot pay for sibling downloads calls" do
    query = """
    {
      a: downloads { id }
      b: downloads { id }
      c: downloads { id }
      offset: mediaItems(first: -10000) { edges { node { id } } }
    }
    """

    assert complexity(query, %{}) > complexity("{ downloads { id } }", %{}) * 3
  end

  test "downloads and lookup are per-call costs" do
    assert complexity("{ downloads { id } }", %{}) >= 50
    assert complexity(~s|{ lookup(query: "x", type: MOVIE) { providerId } }|, %{}) >= 20
  end

  @enforced """
  {
    mediaItems(first: 200) {
      edges { node { id title status { state } } }
    }
  }
  """

  test "a document over the budget is refused" do
    cost = complexity(@enforced, %{})
    assert is_integer(cost) and cost > 1

    assert {:ok, %{errors: errors}} =
             Absinthe.run(@enforced, MydiaWeb.LibrarySchema,
               context: %{principal: @admin},
               analyze_complexity: true,
               max_complexity: cost - 1
             )

    assert Enum.any?(errors, &String.contains?(to_string(&1.message), "complexity"))
  end

  test "the same document at exactly the budget is not refused for complexity" do
    assert {:ok, %{data: %{"mediaItems" => _}} = result} =
             Absinthe.run(@enforced, MydiaWeb.LibrarySchema,
               context: %{principal: @admin},
               analyze_complexity: true,
               max_complexity: complexity(@enforced, %{})
             )

    refute Enum.any?(Map.get(result, :errors, []), fn error ->
             String.contains?(to_string(error.message), "complexity")
           end)
  end

  test "the HTTP budget accepts a capped page with cursors" do
    result = post_query(@page, %{"first" => 200})
    assert %{"data" => %{"mediaItems" => %{"edges" => []}}} = result
    refute Map.has_key?(result, "errors")
  end

  test "the HTTP budget rejects multiple large pages" do
    query = """
    {
      one: mediaItems(first: 200) { edges { node { id title status { state } } } }
      two: mediaItems(first: 200) { edges { node { id title status { state } } } }
    }
    """

    assert %{"errors" => errors} = post_query(query, %{})
    assert Enum.any?(errors, &String.contains?(&1["message"], "complexity"))
  end

  defp post_query(query, variables) do
    user = Mydia.AccountsFixtures.admin_user_fixture()

    {:ok, _record, key} =
      Mydia.Accounts.create_api_key(user.id, %{name: "Complexity", permissions: ["admin"]})

    build_conn()
    |> put_req_header("x-api-key", key)
    |> post("/api/library/graphql", %{query: query, variables: variables})
    |> json_response(200)
  end
end
