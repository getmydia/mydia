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
end
