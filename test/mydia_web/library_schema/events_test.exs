defmodule MydiaWeb.LibrarySchema.EventsTest do
  use MydiaWeb.ConnCase, async: false

  alias Mydia.Events.Event
  alias Mydia.LibraryApi.Principal
  alias Mydia.Repo

  @admin %Principal{role: "admin", source: :env}

  @events """
  query E($first: Int, $after: String, $types: [String!]) {
    events(first: $first, after: $after, types: $types) {
      edges { cursor node { id type occurredAt severity resourceType resourceId data } }
      pageInfo { hasNextPage endCursor }
    }
  }
  """

  defp run(variables, principal \\ @admin) do
    Absinthe.run(@events, MydiaWeb.LibrarySchema,
      variables: variables,
      context: %{principal: principal}
    )
  end

  # 2020 is past the settle window and older than anything the app writes while
  # the suite runs, so these rows come first.
  defp event!(type, second, attrs \\ %{}) do
    %Event{
      category: "media",
      type: type,
      severity: :info,
      metadata: %{},
      inserted_at: DateTime.add(~U[2020-01-01 00:00:00Z], second, :second)
    }
    |> struct!(attrs)
    |> Repo.insert!()
  end

  test "returns events oldest first with their fields" do
    resource_id = Ecto.UUID.generate()

    first =
      event!("media_item.added", 0, %{
        severity: :warning,
        resource_type: "media_item",
        resource_id: resource_id,
        metadata: %{"title" => "Harbor Lights"}
      })

    second = event!("media_item.removed", 5)

    assert {:ok, %{data: %{"events" => %{"edges" => [a, b]}}}} = run(%{"first" => 2})

    assert a["node"] == %{
             "id" => first.id,
             "type" => "media_item.added",
             "occurredAt" => "2020-01-01T00:00:00Z",
             "severity" => "WARNING",
             "resourceType" => "media_item",
             "resourceId" => resource_id,
             "data" => %{"title" => "Harbor Lights"}
           }

    assert b["node"]["id"] == second.id
  end

  test "pages forward with the cursor" do
    one = event!("playback.unwatched", 0)
    two = event!("playback.unwatched", 1)
    types = ["playback.unwatched"]

    assert {:ok, %{data: %{"events" => page1}}} = run(%{"first" => 1, "types" => types})
    assert [%{"node" => %{"id" => id1}}] = page1["edges"]
    assert id1 == one.id
    assert page1["pageInfo"]["hasNextPage"]

    assert {:ok, %{data: %{"events" => page2}}} =
             run(%{"first" => 1, "types" => types, "after" => page1["pageInfo"]["endCursor"]})

    assert [%{"node" => %{"id" => id2}}] = page2["edges"]
    assert id2 == two.id
  end

  test "an empty page repeats the cursor it was given" do
    event!("playback.unwatched", 0)
    types = ["playback.unwatched"]

    {:ok, %{data: %{"events" => page1}}} = run(%{"first" => 200, "types" => types})
    cursor = page1["pageInfo"]["endCursor"]

    assert {:ok, %{data: %{"events" => page2}}} =
             run(%{"first" => 200, "types" => types, "after" => cursor})

    assert page2 == %{
             "edges" => [],
             "pageInfo" => %{"hasNextPage" => false, "endCursor" => cursor}
           }
  end

  test "a type outside the catalog is INVALID_INPUT" do
    assert {:ok, %{errors: [error]}} = run(%{"types" => ["nope.nope"]})
    assert error.extensions.code == "INVALID_INPUT"
    assert error.message =~ "nope.nope"
  end

  test "a first outside 1..200 is INVALID_INPUT" do
    assert {:ok, %{errors: [error]}} = run(%{"first" => 201})
    assert error.extensions.code == "INVALID_INPUT"
  end

  test "an empty types list is INVALID_INPUT, not an empty page" do
    event!("media_item.added", 0)

    assert {:ok, %{errors: [error]}} = run(%{"types" => []})
    assert error.extensions.code == "INVALID_INPUT"
  end

  test "a non-admin is refused" do
    assert {:ok, %{errors: errors}} = run(%{}, %Principal{role: "user", source: :api_key})
    assert Enum.any?(errors, &(&1.extensions[:code] == "FORBIDDEN"))
  end
end
