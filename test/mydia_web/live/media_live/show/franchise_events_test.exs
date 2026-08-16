defmodule MydiaWeb.MediaLive.Show.FranchiseEventsTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.AccountsFixtures
  import ExUnit.CaptureLog

  alias Mydia.Media.{Franchise, FranchiseEntry}
  alias MydiaWeb.MediaLive.Show.FranchiseEvents

  setup do
    bypass = Bypass.open()

    config = %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false}
    }

    %{bypass: bypass, config: config}
  end

  # `start_async/3` is a no-op on a socket that is not connected, so the
  # connected variant is what the dispatch tests need: it records the running
  # task under `private.live_async`, which is where a second task for the same
  # key would show up.
  defp stub_socket(assigns, opts \\ []) do
    defaults = %{
      __changed__: %{},
      flash: %{},
      franchise: nil,
      adding_franchise_tmdb_ids: MapSet.new(),
      can_create_media: true,
      current_user: user_fixture()
    }

    %Phoenix.LiveView.Socket{
      assigns: Map.merge(defaults, assigns),
      private: %{live_temp: %{}},
      transport_pid: if(opts[:connected], do: self())
    }
  end

  defp in_flight_tasks(socket), do: socket.private[:live_async] || %{}

  # Answers a TMDB movie lookup with a 404 so `perform_add/3` fails fast without
  # touching the database.
  defp stub_missing(bypass, tmdb_id) do
    Bypass.stub(bypass, "GET", "/tmdb/movies/#{tmdb_id}", fn conn ->
      Plug.Conn.resp(conn, 404, "Not Found")
    end)
  end

  defp franchise_with_missing(current_item, missing_tmdb_id) do
    %Franchise{
      name: "Test Collection",
      owned_count: 1,
      total_count: 2,
      entries: [
        %FranchiseEntry{
          tmdb_id: current_item.tmdb_id,
          title: current_item.title,
          year: current_item.year,
          release_date: ~D[2001-01-01],
          in_library?: true,
          current?: true,
          media_item_id: current_item.id
        },
        %FranchiseEntry{
          tmdb_id: missing_tmdb_id,
          title: "Missing Sequel",
          year: 2004,
          release_date: ~D[2004-01-01]
        }
      ]
    }
  end

  defp with_extra_missing(franchise, tmdb_id) do
    extra = %FranchiseEntry{
      tmdb_id: tmdb_id,
      title: "Third",
      year: 2007,
      release_date: ~D[2007-01-01]
    }

    %{franchise | entries: franchise.entries ++ [extra], total_count: franchise.total_count + 1}
  end

  # Helpers for the guest-request tests below. Deliberately not the fuller
  # `stub_socket/2` / `franchise_with_missing/2` pair above: those build a
  # socket wired for `add_franchise_movie/2`'s Bypass-backed async add, which
  # `request_franchise_movie/2` does not need.
  defp entry(attrs) do
    struct!(
      %FranchiseEntry{tmdb_id: 1, title: "Untitled", year: 2001, poster_path: "/p.jpg"},
      attrs
    )
  end

  defp guest_socket(franchise, user) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        franchise: franchise,
        current_user: user,
        flash: %{}
      }
    }
  end

  defp small_franchise(entries) do
    %Franchise{
      name: "Test Collection",
      entries: entries,
      owned_count: Enum.count(entries, & &1.in_library?),
      total_count: length(entries)
    }
  end

  describe "add_franchise_movie/2" do
    test "creates the movie inheriting profile and monitored flag",
         %{bypass: bypass, config: config} do
      profile = Mydia.SettingsFixtures.quality_profile_fixture()

      current =
        media_item_fixture(%{
          type: "movie",
          title: "First",
          year: 2001,
          tmdb_id: 1001,
          monitored: false,
          quality_profile_id: profile.id
        })

      Bypass.stub(bypass, "GET", "/tmdb/movies/1002", fn conn ->
        body = %{
          "id" => 1002,
          "title" => "Missing Sequel",
          "release_date" => "2004-01-01",
          "credits" => %{"cast" => [], "crew" => []}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      socket =
        stub_socket(%{
          media_item: current,
          metadata_config: config,
          franchise: franchise_with_missing(current, 1002)
        })

      {:noreply, socket} =
        FranchiseEvents.add_franchise_movie(%{"tmdb_id" => "1002"}, socket)

      assert MapSet.member?(socket.assigns.adding_franchise_tmdb_ids, 1002)

      # The async body is what performs the add; run it directly.
      {:ok, media_item} = FranchiseEvents.perform_add(current, 1002, config)

      assert media_item.tmdb_id == 1002
      assert media_item.title == "Missing Sequel"
      assert media_item.monitored == false
      assert media_item.quality_profile_id == profile.id
    end

    test "reports already-in-library instead of crashing on a duplicate tmdb id",
         %{bypass: bypass, config: config} do
      current =
        media_item_fixture(%{type: "movie", title: "First", year: 2001, tmdb_id: 1301})

      existing =
        media_item_fixture(%{type: "movie", title: "Missing Sequel", year: 2004, tmdb_id: 1302})

      Bypass.stub(bypass, "GET", "/tmdb/movies/1302", fn conn ->
        body = %{
          "id" => 1302,
          "title" => "Missing Sequel",
          "release_date" => "2004-01-01",
          "credits" => %{"cast" => [], "crew" => []}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      assert {:already_in_library, media_item} =
               FranchiseEvents.perform_add(current, 1302, config)

      assert media_item.id == existing.id
    end

    test "refuses without create permission", %{config: config} do
      current =
        media_item_fixture(%{type: "movie", title: "First", year: 2001, tmdb_id: 1011})

      socket =
        stub_socket(%{
          media_item: current,
          metadata_config: config,
          current_user: user_fixture(%{role: "readonly"}),
          franchise: franchise_with_missing(current, 1012)
        })

      {:noreply, socket} =
        FranchiseEvents.add_franchise_movie(%{"tmdb_id" => "1012"}, socket)

      assert MapSet.size(socket.assigns.adding_franchise_tmdb_ids) == 0
    end

    test "a repeat click on an id already in flight does not start a second task",
         %{bypass: bypass, config: config} do
      current =
        media_item_fixture(%{type: "movie", title: "First", year: 2001, tmdb_id: 1101})

      # The dispatched task runs for real on a connected socket. A 404 keeps it
      # short and off the database, so it cannot outlive the sandbox owner.
      stub_missing(bypass, 1102)

      socket =
        stub_socket(
          %{
            media_item: current,
            metadata_config: config,
            franchise: franchise_with_missing(current, 1102)
          },
          connected: true
        )

      {:noreply, socket} = FranchiseEvents.add_franchise_movie(%{"tmdb_id" => "1102"}, socket)
      first = in_flight_tasks(socket)
      assert Map.keys(first) == [{:add_franchise_movie, 1102}]

      {:noreply, socket} = FranchiseEvents.add_franchise_movie(%{"tmdb_id" => "1102"}, socket)

      # An overwritten entry would carry a different ref and pid, and the first
      # task's result would then be discarded by LiveView.
      assert in_flight_tasks(socket) == first
      assert MapSet.size(socket.assigns.adding_franchise_tmdb_ids) == 1
    end

    test "two different ids can be in flight at the same time",
         %{bypass: bypass, config: config} do
      current =
        media_item_fixture(%{type: "movie", title: "First", year: 2001, tmdb_id: 1201})

      stub_missing(bypass, 1202)
      stub_missing(bypass, 1203)

      franchise =
        current
        |> franchise_with_missing(1202)
        |> with_extra_missing(1203)

      socket =
        stub_socket(
          %{media_item: current, metadata_config: config, franchise: franchise},
          connected: true
        )

      {:noreply, socket} = FranchiseEvents.add_franchise_movie(%{"tmdb_id" => "1202"}, socket)
      first = in_flight_tasks(socket)[{:add_franchise_movie, 1202}]

      {:noreply, socket} = FranchiseEvents.add_franchise_movie(%{"tmdb_id" => "1203"}, socket)

      tasks = in_flight_tasks(socket)

      assert Enum.sort(Map.keys(tasks)) == [
               {:add_franchise_movie, 1202},
               {:add_franchise_movie, 1203}
             ]

      assert tasks[{:add_franchise_movie, 1202}] == first

      assert socket.assigns.adding_franchise_tmdb_ids == MapSet.new([1202, 1203])

      # Both results land, in either order, because each is routed by its own id.
      second_added =
        media_item_fixture(%{type: "movie", title: "Second", year: 2004, tmdb_id: 1202})

      third_added =
        media_item_fixture(%{type: "movie", title: "Third", year: 2007, tmdb_id: 1203})

      {:noreply, socket} =
        FranchiseEvents.handle_add_result(1203, {:ok, {:ok, third_added}}, socket)

      {:noreply, socket} =
        FranchiseEvents.handle_add_result(1202, {:ok, {:ok, second_added}}, socket)

      assert MapSet.size(socket.assigns.adding_franchise_tmdb_ids) == 0
      assert socket.assigns.franchise.owned_count == 3

      assert Enum.all?(socket.assigns.franchise.entries, & &1.in_library?)
    end
  end

  # Covers the guest request path for a missing franchise movie.
  #
  # The shared media rail renders a Request button for a guest on any unowned
  # card, including a franchise card. Without a handler for the event it emits,
  # the first click raises FunctionClauseError and takes the detail page down.
  describe "request_franchise_movie/2" do
    test "records a request and marks the entry" do
      user = user_fixture(%{role: "guest"})

      franchise =
        small_franchise([
          entry(%{tmdb_id: 671, in_library?: true, current?: true, media_item_id: "a"}),
          entry(%{tmdb_id: 672, title: "Chamber of Secrets", year: 2002})
        ])

      {:noreply, updated} =
        FranchiseEvents.request_franchise_movie(
          %{"tmdb_id" => "672"},
          guest_socket(franchise, user)
        )

      requested = Enum.find(updated.assigns.franchise.entries, &(&1.tmdb_id == 672))

      assert requested.request_status != nil
    end

    test "ignores an id that is not in the franchise" do
      user = user_fixture(%{role: "guest"})
      franchise = small_franchise([entry(%{tmdb_id: 671}), entry(%{tmdb_id: 672})])

      assert {:noreply, _socket} =
               FranchiseEvents.request_franchise_movie(
                 %{"tmdb_id" => "999"},
                 guest_socket(franchise, user)
               )
    end

    test "ignores a malformed id" do
      user = user_fixture(%{role: "guest"})
      franchise = small_franchise([entry(%{tmdb_id: 671}), entry(%{tmdb_id: 672})])

      assert {:noreply, _socket} =
               FranchiseEvents.request_franchise_movie(
                 %{"tmdb_id" => "not-a-number"},
                 guest_socket(franchise, user)
               )
    end

    test "ignores the event when no franchise is loaded" do
      user = user_fixture(%{role: "guest"})

      assert {:noreply, _socket} =
               FranchiseEvents.request_franchise_movie(
                 %{"tmdb_id" => "672"},
                 guest_socket(nil, user)
               )
    end

    # Regression: can_submit_request?/1 returns true only for a guest, but
    # nothing enforced that on this handler, so any authenticated user could
    # push the event over the socket and create a request row even though the
    # UI renders them no button.
    test "a non-guest user creates no request and leaves the franchise untouched" do
      user = user_fixture(%{role: "user"})

      franchise =
        small_franchise([
          entry(%{tmdb_id: 671, in_library?: true, current?: true, media_item_id: "a"}),
          entry(%{tmdb_id: 672, title: "Chamber of Secrets", year: 2002})
        ])

      {:noreply, updated} =
        FranchiseEvents.request_franchise_movie(
          %{"tmdb_id" => "672"},
          guest_socket(franchise, user)
        )

      assert updated.assigns.franchise == franchise
      assert Mydia.MediaRequests.list_requests(status: "pending") == []
    end
  end

  describe "handle_add_result/3" do
    test "flips the entry to owned and bumps the count", %{config: config} do
      current =
        media_item_fixture(%{type: "movie", title: "First", year: 2001, tmdb_id: 1021})

      added =
        media_item_fixture(%{type: "movie", title: "Missing Sequel", year: 2004, tmdb_id: 1022})

      socket =
        stub_socket(%{
          media_item: current,
          metadata_config: config,
          adding_franchise_tmdb_ids: MapSet.new([1022]),
          franchise: franchise_with_missing(current, 1022)
        })

      {:noreply, socket} = FranchiseEvents.handle_add_result(1022, {:ok, {:ok, added}}, socket)

      assert MapSet.size(socket.assigns.adding_franchise_tmdb_ids) == 0
      assert socket.assigns.franchise.owned_count == 2

      entry = Enum.find(socket.assigns.franchise.entries, &(&1.tmdb_id == 1022))
      assert entry.in_library? == true
      assert entry.media_item_id == added.id
    end

    test "already_in_library flips the entry to owned instead of flashing an error",
         %{config: config} do
      current =
        media_item_fixture(%{type: "movie", title: "First", year: 2001, tmdb_id: 1311})

      added =
        media_item_fixture(%{type: "movie", title: "Missing Sequel", year: 2004, tmdb_id: 1312})

      socket =
        stub_socket(%{
          media_item: current,
          metadata_config: config,
          adding_franchise_tmdb_ids: MapSet.new([1312]),
          franchise: franchise_with_missing(current, 1312)
        })

      {:noreply, socket} =
        FranchiseEvents.handle_add_result(1312, {:ok, {:already_in_library, added}}, socket)

      assert MapSet.size(socket.assigns.adding_franchise_tmdb_ids) == 0
      assert socket.assigns.franchise.owned_count == 2

      entry = Enum.find(socket.assigns.franchise.entries, &(&1.tmdb_id == 1312))
      assert entry.in_library? == true
      assert entry.media_item_id == added.id
      assert socket.assigns.flash["info"] =~ "already in your library"
    end

    @tag :capture_log
    test "clears the spinner on failure", %{config: config} do
      current =
        media_item_fixture(%{type: "movie", title: "First", year: 2001, tmdb_id: 1031})

      socket =
        stub_socket(%{
          media_item: current,
          metadata_config: config,
          adding_franchise_tmdb_ids: MapSet.new([1032]),
          franchise: franchise_with_missing(current, 1032)
        })

      {:noreply, socket} =
        FranchiseEvents.handle_add_result(1032, {:ok, {:error, {:metadata, :timeout}}}, socket)

      assert MapSet.size(socket.assigns.adding_franchise_tmdb_ids) == 0
      assert socket.assigns.franchise.owned_count == 1
    end

    test "the flash for a metadata failure carries no internal struct", %{config: config} do
      current =
        media_item_fixture(%{type: "movie", title: "First", year: 2001, tmdb_id: 1071})

      socket =
        stub_socket(%{
          media_item: current,
          metadata_config: config,
          adding_franchise_tmdb_ids: MapSet.new([1072]),
          franchise: franchise_with_missing(current, 1072)
        })

      error = %Mydia.Metadata.Provider.Error{type: :timeout, message: "timed out"}

      log =
        capture_log(fn ->
          {:noreply, socket} =
            FranchiseEvents.handle_add_result(1072, {:ok, {:error, {:metadata, error}}}, socket)

          flash = socket.assigns.flash["error"]
          assert flash == "Could not add that movie: the metadata service could not be reached"
          refute flash =~ "Mydia.Metadata.Provider.Error"
        end)

      # The detail is not lost, it moves to the log.
      assert log =~ "Mydia.Metadata.Provider.Error"
    end
  end

  describe "handle_load_result/2" do
    # Regression: mark_requested/3 only set request_status in memory for the
    # life of the socket. A guest who requested a missing entry then reloaded
    # the page would see an enabled Request button again, and clicking it hit
    # the duplicate-request error for a request that was already pending.
    #
    # The viewer here (the socket's current_user) is a guest: request_status
    # only ever affects the Request button, which only guests see, so the
    # enrichment now runs only for a viewer who can submit a request.
    test "stamps request_status from an outstanding request and leaves the rest nil",
         %{config: config} do
      requester = user_fixture(%{role: "guest"})

      current =
        media_item_fixture(%{
          type: "movie",
          title: "First",
          year: 2001,
          tmdb_id: System.unique_integer([:positive])
        })

      requested_tmdb_id = System.unique_integer([:positive])
      franchise = franchise_with_missing(current, requested_tmdb_id)
      franchise = with_extra_missing(franchise, System.unique_integer([:positive]))
      [_current_entry, requested_entry, untouched_entry] = franchise.entries

      {:ok, _request} =
        Mydia.MediaRequests.create_request(%{
          media_type: "movie",
          title: requested_entry.title,
          tmdb_id: requested_entry.tmdb_id,
          requester_id: requester.id
        })

      socket =
        stub_socket(%{
          media_item: current,
          metadata_config: config,
          current_user: user_fixture(%{role: "guest"})
        })

      {:noreply, socket} = FranchiseEvents.handle_load_result({:ok, {:ok, franchise}}, socket)

      entries = socket.assigns.franchise.entries
      requested = Enum.find(entries, &(&1.tmdb_id == requested_entry.tmdb_id))
      untouched = Enum.find(entries, &(&1.tmdb_id == untouched_entry.tmdb_id))

      assert requested.request_status == "pending"
      assert untouched.request_status == nil
    end

    # Regression: request_status_map/0 issued two unfiltered list_requests/1
    # queries and PR #461 ran them on every franchise load, though the value
    # only ever affects the Request button that only a guest sees. A non-guest
    # viewer must not pay for a query whose result they can never act on.
    test "a non-guest viewer sees no request_status even for an outstanding request",
         %{config: config} do
      requester = user_fixture(%{role: "guest"})

      current =
        media_item_fixture(%{
          type: "movie",
          title: "First",
          year: 2001,
          tmdb_id: System.unique_integer([:positive])
        })

      requested_tmdb_id = System.unique_integer([:positive])
      franchise = franchise_with_missing(current, requested_tmdb_id)
      [_current_entry, requested_entry] = franchise.entries

      {:ok, _request} =
        Mydia.MediaRequests.create_request(%{
          media_type: "movie",
          title: requested_entry.title,
          tmdb_id: requested_entry.tmdb_id,
          requester_id: requester.id
        })

      socket =
        stub_socket(%{
          media_item: current,
          metadata_config: config,
          current_user: user_fixture(%{role: "user"})
        })

      {:noreply, socket} = FranchiseEvents.handle_load_result({:ok, {:ok, franchise}}, socket)

      entries = socket.assigns.franchise.entries
      requested = Enum.find(entries, &(&1.tmdb_id == requested_entry.tmdb_id))

      assert requested.request_status == nil
    end

    test "assigns the franchise on success", %{config: config} do
      current =
        media_item_fixture(%{type: "movie", title: "First", year: 2001, tmdb_id: 1041})

      franchise = franchise_with_missing(current, 1042)
      socket = stub_socket(%{media_item: current, metadata_config: config})

      {:noreply, socket} = FranchiseEvents.handle_load_result({:ok, {:ok, franchise}}, socket)

      assert socket.assigns.franchise == franchise
    end

    test "leaves the franchise nil on :none", %{config: config} do
      current =
        media_item_fixture(%{type: "movie", title: "First", year: 2001, tmdb_id: 1051})

      socket = stub_socket(%{media_item: current, metadata_config: config})

      {:noreply, socket} = FranchiseEvents.handle_load_result({:ok, :none}, socket)

      assert socket.assigns.franchise == nil
    end

    @tag :capture_log
    test "leaves the franchise nil when the async task crashed", %{config: config} do
      current =
        media_item_fixture(%{type: "movie", title: "First", year: 2001, tmdb_id: 1061})

      socket = stub_socket(%{media_item: current, metadata_config: config})

      {:noreply, socket} = FranchiseEvents.handle_load_result({:exit, :boom}, socket)

      assert socket.assigns.franchise == nil
    end

    @tag :capture_log
    test "an unexpected result is ignored instead of raising in the LiveView",
         %{config: config} do
      current =
        media_item_fixture(%{type: "movie", title: "First", year: 2001, tmdb_id: 1081})

      socket = stub_socket(%{media_item: current, metadata_config: config})

      {:noreply, socket} = FranchiseEvents.handle_load_result(:something_unexpected, socket)

      assert socket.assigns.franchise == nil
    end
  end
end
