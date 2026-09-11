defmodule Mydia.LibraryApi.EventFeedTest do
  use Mydia.DataCase, async: false

  alias Mydia.Events.Event
  alias Mydia.LibraryApi.Cursor
  alias Mydia.LibraryApi.EventFeed
  alias Mydia.Repo

  # Far in the past, so nothing the app writes while the suite runs sorts
  # between these rows.
  @now ~U[2020-01-01 12:00:00Z]

  defp event!(type, seconds_ago, attrs \\ %{}) do
    %Event{
      category: "media",
      type: type,
      severity: :info,
      metadata: %{},
      inserted_at: DateTime.add(@now, -seconds_ago, :second)
    }
    |> struct!(attrs)
    |> Repo.insert!()
  end

  defp ids({:ok, events}), do: Enum.map(events, & &1.id)

  test "returns events oldest first, ties broken by id" do
    oldest = event!("media_item.added", 60)
    tie_a = event!("media_item.updated", 30)
    tie_b = event!("media_item.removed", 30)

    [first_tie, second_tie] = Enum.sort([tie_a.id, tie_b.id])

    assert ids(EventFeed.list(limit: 10, now: @now)) == [oldest.id, first_tie, second_tie]
  end

  test "withholds events younger than the settle window" do
    settled = event!("media_item.added", EventFeed.settle_seconds() + 1)
    _fresh = event!("media_item.added", EventFeed.settle_seconds() - 5)

    assert ids(EventFeed.list(limit: 10, now: @now)) == [settled.id]
  end

  test "resumes strictly after the cursor, including within one second" do
    rows =
      for type <- ~w(media_item.added media_item.updated media_item.removed), do: event!(type, 30)

    [first, second, third] = Enum.sort_by(rows, & &1.id)

    assert {:ok, [^first]} = EventFeed.list(limit: 1, now: @now)

    {:ok, cursor} = first.inserted_at |> Cursor.encode(first.id) |> Cursor.decode()

    assert ids(EventFeed.list(limit: 10, after: cursor, now: @now)) == [second.id, third.id]
  end

  test "defaults to the plugin event catalog" do
    listed = event!("media_item.added", 30)
    _unlisted = event!("library.scan.finished", 30)

    assert ids(EventFeed.list(limit: 10, now: @now)) == [listed.id]
  end

  test "filters to the requested types" do
    _added = event!("media_item.added", 30)
    removed = event!("media_item.removed", 30)

    assert ids(EventFeed.list(limit: 10, types: ["media_item.removed"], now: @now)) ==
             [removed.id]
  end

  test "refuses a type outside the catalog" do
    assert EventFeed.list(limit: 10, types: ["media_item.added", "nope.nope"], now: @now) ==
             {:error, {:unknown_types, ["nope.nope"]}}
  end
end
