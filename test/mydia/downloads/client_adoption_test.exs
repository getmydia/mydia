defmodule Mydia.Downloads.ClientAdoptionTest do
  @moduledoc """
  The adoption rule is deliberately conservative: exactly one claimant, and
  only among torrent-type clients.

  Two clients can legitimately hold the same info hash (the same release
  seeded in two places). Since commit 96d75b00 scoped every client to its own
  files, adopting onto the wrong claimant means importing from the wrong
  save_path. Usenet and debrid IDs are client-local or provider-scoped, so a
  cross-client match on either is coincidence rather than identity.
  """
  use ExUnit.Case, async: true

  alias Mydia.Downloads.ClientAdoption

  defp torrent(id), do: %{id: id, state: "downloading", progress: 42.0}

  describe "find_claimant/3" do
    test "adopts when exactly one torrent client holds the id" do
      statuses = %{"new-qbit" => {:reachable, %{"hash-a" => torrent("hash-a")}}}
      types = %{"new-qbit" => :qbittorrent}

      assert {:ok, "new-qbit"} = ClientAdoption.find_claimant("hash-a", statuses, types)
    end

    test "refuses when two clients hold the same id" do
      statuses = %{
        "qbit-one" => {:reachable, %{"hash-a" => torrent("hash-a")}},
        "qbit-two" => {:reachable, %{"hash-a" => torrent("hash-a")}}
      }

      types = %{"qbit-one" => :qbittorrent, "qbit-two" => :transmission}

      assert :none = ClientAdoption.find_claimant("hash-a", statuses, types)
    end

    test "refuses a usenet claimant because nzo ids are client-local" do
      statuses = %{"sab" => {:reachable, %{"SABnzbd_nzo_1" => torrent("SABnzbd_nzo_1")}}}
      types = %{"sab" => :sabnzbd}

      assert :none = ClientAdoption.find_claimant("SABnzbd_nzo_1", statuses, types)
    end

    test "refuses a debrid claimant because ids are provider-scoped" do
      statuses = %{"torbox" => {:reachable, %{"job-7" => torrent("job-7")}}}
      types = %{"torbox" => :debrid}

      assert :none = ClientAdoption.find_claimant("job-7", statuses, types)
    end

    test "adopts the single torrent claimant while ignoring a usenet collision" do
      statuses = %{
        "qbit" => {:reachable, %{"shared-id" => torrent("shared-id")}},
        "sab" => {:reachable, %{"shared-id" => torrent("shared-id")}}
      }

      types = %{"qbit" => :qbittorrent, "sab" => :sabnzbd}

      assert {:ok, "qbit"} = ClientAdoption.find_claimant("shared-id", statuses, types)
    end

    test "ignores unreachable clients entirely" do
      statuses = %{
        "qbit" => {:reachable, %{"hash-a" => torrent("hash-a")}},
        "down" => :unreachable
      }

      types = %{"qbit" => :qbittorrent, "down" => :qbittorrent}

      assert {:ok, "qbit"} = ClientAdoption.find_claimant("hash-a", statuses, types)
    end

    test "returns :none when no client holds the id" do
      statuses = %{"qbit" => {:reachable, %{"hash-b" => torrent("hash-b")}}}
      types = %{"qbit" => :qbittorrent}

      assert :none = ClientAdoption.find_claimant("hash-a", statuses, types)
    end

    test "returns :none for a nil client id" do
      statuses = %{"qbit" => {:reachable, %{"hash-a" => torrent("hash-a")}}}
      types = %{"qbit" => :qbittorrent}

      assert :none = ClientAdoption.find_claimant(nil, statuses, types)
    end

    test "returns :none when the claimant has no known type" do
      statuses = %{"mystery" => {:reachable, %{"hash-a" => torrent("hash-a")}}}

      assert :none = ClientAdoption.find_claimant("hash-a", statuses, %{})
    end

    test "adoptable_types excludes every non-torrent client type" do
      types = ClientAdoption.adoptable_types()

      assert :qbittorrent in types
      assert :transmission in types
      assert :rqbit in types
      assert :rtorrent in types

      refute :sabnzbd in types
      refute :nzbget in types
      refute :debrid in types
      refute :blackhole in types
    end
  end
end
