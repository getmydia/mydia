defmodule Mydia.P2p.TorrentStreamRoutingTest do
  use Mydia.DataCase, async: false

  # P2P stream dispatch is currently covered indirectly via the
  # streaming_resolver_test and the Torrent context tests. A full test of
  # the P2P pipeline requires the iroh NIF (Mydia.P2p) plus an active
  # connection, both of which are unavailable in unit-test CI.
  #
  # This file exists as the canonical landing zone for routing tests
  # called out in plan U4. The integration coverage will come from the
  # Flutter integration tests under player/integration_test/, which exercise
  # the full pipeline including HLS+torrent dispatch through the live P2P
  # endpoint.

  describe "torrent_stream dispatch (placeholder)" do
    @tag :skip
    test "valid torrent_stream:<id> with valid range returns 206 with content_range" do
      flunk("Pending: needs live P2P + torrent engine harness (plan U4).")
    end

    @tag :skip
    test "unknown session id returns 404" do
      flunk("Pending: needs live P2P harness.")
    end

    @tag :skip
    test "range_start > range_end returns 416" do
      flunk("Pending: needs live P2P harness.")
    end

    @tag :skip
    test "missing auth token returns 401" do
      flunk("Pending: needs live P2P harness.")
    end

    @tag :skip
    test "range past chunk cap returns 416 (not a NIF crash)" do
      flunk(
        "Pending: needs live P2P harness — covered by Server.compute_torrent_read_window/2 unit logic."
      )
    end
  end
end
