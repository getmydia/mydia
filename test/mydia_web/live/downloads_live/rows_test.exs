defmodule MydiaWeb.DownloadsLive.RowsTest do
  use ExUnit.Case, async: true

  alias MydiaWeb.DownloadsLive.Rows

  describe "stale_status/1" do
    test "nil when every row is live" do
      assert Rows.stale_status([%{status_as_of: nil, download_client: "alpha"}]) == nil
    end

    test "the oldest last-known status among stale rows" do
      older = ~U[2031-01-01 00:00:00Z]
      newer = ~U[2031-01-01 00:05:00Z]

      rows = [
        %{status_as_of: newer, download_client: "beta"},
        %{status_as_of: older, download_client: "alpha"}
      ]

      assert Rows.stale_status(rows) == %{client: "alpha", as_of: older}
    end
  end

  describe "stream_page/2" do
    # A socket as it stands after a render: the `:downloads` stream exists
    # (a reset on a stream that was never created is a no-op, so it must) with
    # its pending ops pruned, and `stream_ids` is what was last on screen.
    defp bare_socket(stream_ids) do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, stream_ids: stream_ids},
        private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
      }

      socket = Phoenix.LiveView.stream(socket, :downloads, Enum.map(stream_ids || [], &%{id: &1}))

      update_in(socket.assigns.streams.downloads, &Phoenix.LiveView.LiveStream.prune/1)
    end

    defp pending_stream(socket), do: socket.assigns.streams.downloads

    test "rows that kept their order are patched in place, only gone rows are deleted" do
      socket = Rows.stream_page(bare_socket(["a", "b"]), [%{id: "a"}])

      stream = pending_stream(socket)
      refute stream.reset?
      assert stream.deletes == ["downloads-b"]
      assert [{"downloads-a", _at, %{id: "a"}, _limit, _update_only}] = stream.inserts
      assert socket.assigns.stream_ids == ["a"]
    end

    test "the first load resets the stream" do
      socket = Rows.stream_page(bare_socket(nil), [%{id: "a"}, %{id: "b"}])

      assert pending_stream(socket).reset?
      assert socket.assigns.stream_ids == ["a", "b"]
    end

    test "a reordered page resets the stream" do
      socket = Rows.stream_page(bare_socket(["a", "b"]), [%{id: "b"}, %{id: "a"}])

      assert pending_stream(socket).reset?
      assert socket.assigns.stream_ids == ["b", "a"]
    end
  end
end
