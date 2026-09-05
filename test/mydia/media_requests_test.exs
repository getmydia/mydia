defmodule Mydia.MediaRequestsTest do
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Mydia.SettingsFixtures

  alias Mydia.MediaRequests
  alias Mydia.{Accounts, Media, Repo}
  alias Mydia.Media.MediaItem
  alias Mydia.Media.MediaRequest

  describe "list_requests/1" do
    setup do
      user = create_user()
      %{user: user}
    end

    test "returns all requests", %{user: user} do
      request1 = create_request(user)
      request2 = create_request(user, %{title: "Another Movie"})

      requests = MediaRequests.list_requests()
      assert length(requests) == 2
      assert Enum.any?(requests, &(&1.id == request1.id))
      assert Enum.any?(requests, &(&1.id == request2.id))
    end

    test "filters by status", %{user: user} do
      pending = create_request(user)
      approved = create_request(user, %{title: "Approved Movie"})

      admin = create_user(%{role: "admin"})
      bypass = Bypass.open()
      stub_tmdb_movie(bypass, approved.tmdb_id, "Approved Movie", "/x.jpg")

      {:ok, _} =
        MediaRequests.approve_request(approved, %{approved_by_id: admin.id},
          config: relay_config(bypass)
        )

      pending_requests = MediaRequests.list_requests(status: "pending")
      assert length(pending_requests) == 1
      assert hd(pending_requests).id == pending.id

      approved_requests = MediaRequests.list_requests(status: "approved")
      assert length(approved_requests) == 1
    end

    test "filters by requester_id", %{user: user} do
      user2 = create_user()

      request1 = create_request(user)
      _request2 = create_request(user2)

      requests = MediaRequests.list_requests(requester_id: user.id)
      assert length(requests) == 1
      assert hd(requests).id == request1.id
    end

    test "preloads associations", %{user: user} do
      _request = create_request(user)

      [request] = MediaRequests.list_requests(preload: [:requester])
      assert %Ecto.Association.NotLoaded{} != request.requester
      assert request.requester.id == user.id
    end
  end

  describe "get_request!/2" do
    setup do
      user = create_user()
      request = create_request(user)
      %{user: user, request: request}
    end

    test "returns the request with given id", %{request: request} do
      found = MediaRequests.get_request!(request.id)
      assert found.id == request.id
    end

    test "raises if request does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        MediaRequests.get_request!(Ecto.UUID.generate())
      end
    end

    test "preloads associations", %{request: request} do
      found = MediaRequests.get_request!(request.id, preload: [:requester])
      assert %Ecto.Association.NotLoaded{} != found.requester
    end
  end

  describe "create_request/1" do
    setup do
      user = create_user()
      %{user: user}
    end

    test "creates a request with valid attributes", %{user: user} do
      attrs = %{
        media_type: "movie",
        title: "Test Movie",
        year: 2023,
        tmdb_id: 12345,
        requester_notes: "Please add this",
        requester_id: user.id
      }

      assert {:ok, request} = MediaRequests.create_request(attrs)
      assert request.title == "Test Movie"
      assert request.status == "pending"
      assert request.requester_id == user.id
    end

    test "requires required fields", %{user: user} do
      attrs = %{requester_id: user.id}

      assert {:error, changeset} = MediaRequests.create_request(attrs)
      assert %{media_type: ["can't be blank"], title: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires either TMDB ID, TVDB ID, or IMDB ID", %{user: user} do
      attrs = %{
        media_type: "movie",
        title: "Test Movie",
        requester_id: user.id
      }

      assert {:error, changeset} = MediaRequests.create_request(attrs)

      assert %{tmdb_id: ["either TMDB ID, TVDB ID, or IMDB ID must be provided"]} =
               errors_on(changeset)
    end

    test "prevents duplicate requests for the same TMDB ID", %{user: user} do
      attrs = %{
        media_type: "movie",
        title: "Test Movie",
        tmdb_id: 12345,
        requester_id: user.id
      }

      assert {:ok, _request} = MediaRequests.create_request(attrs)
      assert {:error, :duplicate_request} = MediaRequests.create_request(attrs)
    end

    test "prevents requests for media that already exists", %{user: user} do
      # Create a media item
      {:ok, _media_item} =
        Media.create_media_item(%{
          type: "movie",
          title: "Existing Movie",
          year: 2023,
          tmdb_id: 12345
        })

      # Try to request the same media
      attrs = %{
        media_type: "movie",
        title: "Existing Movie",
        tmdb_id: 12345,
        requester_id: user.id
      }

      assert {:error, :duplicate_media} = MediaRequests.create_request(attrs)
    end

    test "prevents duplicate requests for the same TVDB ID", %{user: user} do
      attrs = %{
        media_type: "tv_show",
        title: "Test Series",
        tvdb_id: 54321,
        requester_id: user.id
      }

      assert {:ok, _request} = MediaRequests.create_request(attrs)
      assert {:error, :duplicate_request} = MediaRequests.create_request(attrs)
    end

    test "prevents requests for media that already exists by TVDB ID", %{user: user} do
      {:ok, _media_item} =
        Media.create_media_item(
          %{type: "tv_show", title: "Existing Series", tvdb_id: 54321},
          skip_episode_refresh: true
        )

      attrs = %{
        media_type: "tv_show",
        title: "Existing Series",
        tvdb_id: 54321,
        requester_id: user.id
      }

      assert {:error, :duplicate_media} = MediaRequests.create_request(attrs)
    end

    test "accepts a tv request whose tmdb_id belongs to a movie already in the library", %{
      user: user
    } do
      tmdb_id = System.unique_integer([:positive])

      {:ok, _movie} =
        Media.create_media_item(%{
          type: "movie",
          title: "Crossed Type",
          year: 2023,
          tmdb_id: tmdb_id
        })

      assert {:ok, request} =
               MediaRequests.create_request(%{
                 media_type: "tv_show",
                 title: "Crossed Type",
                 tmdb_id: tmdb_id,
                 requester_id: user.id
               })

      assert request.media_type == "tv_show"
      assert request.tmdb_id == tmdb_id
    end
  end

  describe "approve_request/2" do
    setup do
      user = create_user()
      admin = create_user(%{role: "admin"})
      request = create_request(user)
      bypass = Bypass.open()
      stub_tmdb_movie(bypass, request.tmdb_id, request.title, "/stub.jpg")
      %{user: user, admin: admin, request: request, config: relay_config(bypass)}
    end

    test "approves request and creates media item", %{
      request: request,
      admin: admin,
      config: config
    } do
      attrs = %{
        approved_by_id: admin.id,
        admin_notes: "Looks good"
      }

      assert {:ok, %{request: updated_request, media_item: media_item}} =
               MediaRequests.approve_request(request, attrs, config: config)

      assert updated_request.status == "approved"
      assert updated_request.approved_by_id == admin.id
      assert updated_request.media_item_id == media_item.id
      assert updated_request.approved_at != nil

      # Verify media item was created correctly
      assert media_item.title == request.title
      assert media_item.tmdb_id == request.tmdb_id
      assert media_item.type == request.media_type
    end

    test "links the request to an existing media item instead of hitting the tmdb_id index", %{
      request: request,
      admin: admin,
      config: config
    } do
      # A row with the same TMDB ID was added to the library after the
      # request was filed but before it was approved.
      {:ok, existing} =
        Media.create_media_item(%{
          type: "movie",
          title: "Existing",
          year: 2023,
          tmdb_id: request.tmdb_id
        })

      attrs = %{approved_by_id: admin.id}

      assert {:ok, %{request: updated_request, media_item: media_item}} =
               MediaRequests.approve_request(request, attrs, config: config)

      assert media_item.id == existing.id
      assert updated_request.status == "approved"
      assert updated_request.media_item_id == existing.id
    end

    test "requires approved_by_id", %{request: request, config: config} do
      assert {:error, changeset} = MediaRequests.approve_request(request, %{}, config: config)
      assert %{approved_by_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "approves a tv request whose tmdb_id matches an existing movie",
         %{user: user, admin: admin} do
      bypass = Bypass.open()
      tmdb_id = System.unique_integer([:positive])

      request =
        create_request(user, %{media_type: "tv_show", title: "Crossed Type", tmdb_id: tmdb_id})

      # Filed first, so create_request/1's own duplicate check does not fire:
      # the movie lands in the library while the request sits pending.
      {:ok, movie} =
        Media.create_media_item(%{
          type: "movie",
          title: "Crossed Type",
          year: 2023,
          tmdb_id: tmdb_id
        })

      stub_tmdb_tv_show(bypass, tmdb_id, "Crossed Type")
      stub_tvdb_search_empty(bypass)

      before_count = Repo.aggregate(MediaItem, :count)

      # approve_request/3 returns {:ok, %{request: _, media_item: _}}
      # (lib/mydia/media_requests.ex:111-128).
      assert {:ok, %{request: approved, media_item: show}} =
               MediaRequests.approve_request(request, %{approved_by_id: admin.id},
                 config: relay_config(bypass)
               )

      # TMDB numbers movies and series independently, so the show and the movie
      # hold the same tmdb_id without conflicting.
      assert Repo.aggregate(MediaItem, :count) == before_count + 1

      assert approved.status == "approved"
      assert approved.media_item_id == show.id

      assert show.type == "tv_show"
      assert show.tmdb_id == tmdb_id
      refute show.id == movie.id
    end
  end

  describe "approve_request/3 configuration" do
    setup do
      user = create_user()
      admin = create_user(%{role: "admin"})
      request = create_request(user)
      bypass = Bypass.open()
      stub_tmdb_movie(bypass, request.tmdb_id, request.title, "/stub.jpg")
      %{admin: admin, request: request, config: relay_config(bypass)}
    end

    test "applies the library, quality profile and monitored flag", %{
      request: request,
      admin: admin,
      config: config
    } do
      library = library_path_fixture(%{type: "movies"})
      profile = quality_profile_fixture()

      assert {:ok, %{media_item: media_item}} =
               MediaRequests.approve_request(request, %{approved_by_id: admin.id},
                 config: config,
                 library_path_id: library.id,
                 quality_profile_id: profile.id,
                 monitored: false
               )

      assert media_item.library_path_id == library.id
      assert media_item.quality_profile_id == profile.id
      assert media_item.monitored == false
    end

    test "still defaults to monitored when no flag is given", %{
      request: request,
      admin: admin,
      config: config
    } do
      assert {:ok, %{media_item: media_item}} =
               MediaRequests.approve_request(request, %{approved_by_id: admin.id}, config: config)

      assert media_item.monitored == true
    end

    test "does not reconfigure an item that is already in the library", %{
      request: request,
      admin: admin,
      config: config
    } do
      incumbent_library = library_path_fixture(%{type: "movies"})

      {:ok, incumbent} =
        Media.create_media_item(%{
          type: "movie",
          title: request.title,
          year: request.year,
          tmdb_id: request.tmdb_id,
          library_path_id: incumbent_library.id,
          monitored: true
        })

      other_library = library_path_fixture(%{type: "movies"})

      assert {:ok, %{media_item: media_item}} =
               MediaRequests.approve_request(request, %{approved_by_id: admin.id},
                 config: config,
                 library_path_id: other_library.id,
                 monitored: false
               )

      # Linked, not reconfigured. Approving a request must not silently move or
      # unmonitor a library item somebody else set up.
      assert media_item.id == incumbent.id
      assert Repo.get!(MediaItem, incumbent.id).library_path_id == incumbent_library.id
      assert Repo.get!(MediaItem, incumbent.id).monitored == true
    end

    test "does not queue a search for an item that is already in the library", %{
      request: request,
      admin: admin,
      config: config
    } do
      incumbent_library = library_path_fixture(%{type: "movies"})

      {:ok, incumbent} =
        Media.create_media_item(%{
          type: "movie",
          title: request.title,
          year: request.year,
          tmdb_id: request.tmdb_id,
          library_path_id: incumbent_library.id,
          monitored: true
        })

      assert {:ok, %{media_item: media_item}} =
               MediaRequests.approve_request(request, %{approved_by_id: admin.id},
                 config: config,
                 search_on_add: true
               )

      assert media_item.id == incumbent.id

      # search_on_add is true, but the item was already in the library. No
      # job may be queued against a row someone else set up.
      refute_enqueued(worker: Mydia.Jobs.MovieSearch, args: %{media_item_id: incumbent.id})
      refute_enqueued(worker: Mydia.Jobs.TVShowSearch, args: %{media_item_id: incumbent.id})
    end

    test "queues an automatic search when search_on_add is set", %{
      request: request,
      admin: admin,
      config: config
    } do
      assert {:ok, %{media_item: media_item}} =
               MediaRequests.approve_request(request, %{approved_by_id: admin.id},
                 config: config,
                 search_on_add: true
               )

      assert_enqueued(
        worker: Mydia.Jobs.MovieSearch,
        args: %{mode: "specific", media_item_id: media_item.id}
      )
    end

    test "queues nothing when search_on_add is absent", %{
      request: request,
      admin: admin,
      config: config
    } do
      assert {:ok, %{media_item: media_item}} =
               MediaRequests.approve_request(request, %{approved_by_id: admin.id}, config: config)

      refute_enqueued(worker: Mydia.Jobs.MovieSearch, args: %{media_item_id: media_item.id})
    end
  end

  describe "approve_request/3 season monitoring" do
    setup do
      user = create_user()
      admin = create_user(%{role: "admin"})

      {:ok, request} =
        MediaRequests.create_request(%{
          media_type: "tv_show",
          title: "Beacons Over Ilmarry",
          tmdb_id: 771_002,
          requester_id: user.id
        })

      bypass = Bypass.open()

      # Two real seasons, so "none" (fetch nothing) and "all" (fetch
      # everything) actually diverge. `stub_tmdb_tv_show/4`'s seasons list
      # only needs to name the seasons; the episodes themselves come from the
      # per-season endpoint stubbed below.
      stub_tmdb_tv_show(bypass, request.tmdb_id, request.title, [
        %{"season_number" => 1, "episode_count" => 2},
        %{"season_number" => 2, "episode_count" => 3}
      ])

      stub_tmdb_season(bypass, request.tmdb_id, 1, 2)
      stub_tmdb_season(bypass, request.tmdb_id, 2, 3)

      # A TMDB-sourced show with no tvdb_id triggers maybe_discover_tvdb_id
      # during the episode refresh; this stub keeps that lookup off the network.
      stub_tvdb_search_empty(bypass)

      %{admin: admin, request: request, config: relay_config(bypass)}
    end

    test "creates all episodes unmonitored when season monitoring is none", %{
      request: request,
      admin: admin,
      config: config
    } do
      assert {:ok, %{media_item: media_item}} =
               MediaRequests.approve_request(request, %{approved_by_id: admin.id},
                 config: config,
                 season_monitoring: "none"
               )

      assert media_item.type == "tv_show"
      assert media_item.monitor_new_seasons == :none

      episodes =
        Repo.all(from(e in Mydia.Media.Episode, where: e.media_item_id == ^media_item.id))

      assert length(episodes) == 5
      assert Enum.all?(episodes, fn e -> not e.monitored end)
    end

    test "creates episodes for every season when season monitoring is all", %{
      request: request,
      admin: admin,
      config: config
    } do
      assert {:ok, %{media_item: media_item}} =
               MediaRequests.approve_request(request, %{approved_by_id: admin.id},
                 config: config,
                 season_monitoring: "all"
               )

      assert media_item.type == "tv_show"
      assert media_item.monitor_new_seasons == :all

      # The stub offers 2 + 3 = 5 episodes across two seasons; "all" must
      # fetch every one of them and monitor them.
      episodes =
        Repo.all(from(e in Mydia.Media.Episode, where: e.media_item_id == ^media_item.id))

      assert length(episodes) == 5
      assert Enum.all?(episodes, fn e -> e.monitored end)
    end
  end

  describe "approve_request/3 metadata" do
    setup do
      user = create_user()
      admin = create_user(%{role: "admin"})
      %{user: user, admin: admin}
    end

    test "populates the media item metadata with the provider poster", %{
      user: user,
      admin: admin
    } do
      bypass = Bypass.open()
      request = create_request(user, %{title: "Stale Request Title"})
      stub_tmdb_movie(bypass, request.tmdb_id, "Fresh Provider Title", "/approved.jpg")

      assert {:ok, %{media_item: media_item}} =
               MediaRequests.approve_request(request, %{approved_by_id: admin.id},
                 config: relay_config(bypass)
               )

      assert media_item.metadata.poster_path == "/approved.jpg"
      assert media_item.title == "Fresh Provider Title"
      assert media_item.tmdb_id == request.tmdb_id
    end

    test "leaves the request pending and creates nothing when the relay is unreachable", %{
      user: user,
      admin: admin
    } do
      bypass = Bypass.open()
      request = create_request(user)
      Bypass.down(bypass)

      assert {:error, {:metadata, _reason}} =
               MediaRequests.approve_request(request, %{approved_by_id: admin.id},
                 config: relay_config(bypass)
               )

      assert Repo.get!(MediaRequest, request.id).status == "pending"
      refute Media.find_by_external_ids(%{tmdb: request.tmdb_id})
    end

    test "reports a request with no TMDB or TVDB id rather than creating a shell", %{
      user: user,
      admin: admin
    } do
      bypass = Bypass.open()

      {:ok, request} =
        MediaRequests.create_request(%{
          media_type: "movie",
          title: "IMDB Only",
          imdb_id: "tt0000001",
          requester_id: user.id
        })

      assert {:error, {:metadata, :no_provider_id}} =
               MediaRequests.approve_request(request, %{approved_by_id: admin.id},
                 config: relay_config(bypass)
               )

      assert Repo.get!(MediaRequest, request.id).status == "pending"
    end
  end

  describe "reject_request/2" do
    setup do
      user = create_user()
      admin = create_user(%{role: "admin"})
      request = create_request(user)
      %{user: user, admin: admin, request: request}
    end

    test "rejects request with reason", %{request: request, admin: admin} do
      attrs = %{
        approved_by_id: admin.id,
        rejection_reason: "Not available in region",
        admin_notes: "Sorry"
      }

      assert {:ok, updated_request} = MediaRequests.reject_request(request, attrs)

      assert updated_request.status == "rejected"
      assert updated_request.rejection_reason == "Not available in region"
      assert updated_request.admin_notes == "Sorry"
      assert updated_request.approved_by_id == admin.id
      assert updated_request.rejected_at != nil
    end

    test "requires rejection_reason", %{request: request, admin: admin} do
      attrs = %{approved_by_id: admin.id}

      assert {:error, changeset} = MediaRequests.reject_request(request, attrs)
      assert %{rejection_reason: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires approved_by_id", %{request: request} do
      attrs = %{rejection_reason: "Test"}

      assert {:error, changeset} = MediaRequests.reject_request(request, attrs)
      assert %{approved_by_id: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "count_pending_requests/0" do
    setup do
      user = create_user()
      admin = create_user(%{role: "admin"})
      %{user: user, admin: admin}
    end

    test "returns count of pending requests", %{user: user, admin: admin} do
      assert MediaRequests.count_pending_requests() == 0

      _request1 = create_request(user)
      _request2 = create_request(user, %{title: "Another Movie"})
      assert MediaRequests.count_pending_requests() == 2

      # Approve one
      request3 = create_request(user, %{title: "Third Movie"})
      bypass = Bypass.open()
      stub_tmdb_movie(bypass, request3.tmdb_id, "Third Movie", "/x.jpg")

      MediaRequests.approve_request(request3, %{approved_by_id: admin.id},
        config: relay_config(bypass)
      )

      assert MediaRequests.count_pending_requests() == 2
    end
  end

  describe "pending_request_exists?/1" do
    setup do
      user = create_user()
      %{user: user}
    end

    test "returns true if pending request exists with TMDB ID", %{user: user} do
      _request = create_request(user, %{tmdb_id: 12345})

      assert MediaRequests.pending_request_exists?(12345) == true
      assert MediaRequests.pending_request_exists?(99999) == false
    end

    test "returns false for nil or invalid input" do
      assert MediaRequests.pending_request_exists?(nil) == false
      assert MediaRequests.pending_request_exists?("invalid") == false
    end
  end

  # Test helpers

  defp relay_config(bypass) do
    %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false}
    }
  end

  defp stub_tmdb_movie(bypass, id, title, poster_path) do
    body = %{
      "id" => id,
      "title" => title,
      "release_date" => "2021-03-04",
      "poster_path" => poster_path,
      "overview" => "x",
      "credits" => %{"cast" => [], "crew" => []},
      "genres" => []
    }

    Bypass.stub(bypass, "GET", "/tmdb/movies/#{id}", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  defp stub_tmdb_tv_show(bypass, id, title, seasons \\ []) do
    body = %{
      "id" => id,
      "name" => title,
      "first_air_date" => "2021-03-04",
      "overview" => "x",
      "credits" => %{"cast" => [], "crew" => []},
      "seasons" => seasons,
      "genres" => []
    }

    Bypass.stub(bypass, "GET", "/tmdb/tv/shows/#{id}", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  # Backs the per-season fetch `refresh_episodes_for_tv_show/2` makes for a
  # TMDB-sourced show (relay.ex's `fetch_season_tmdb/4`), independent of the
  # season list on the show-level stub above. `episode_count` episodes are
  # numbered 1.., which is all `EpisodeData.from_api_response/1` requires.
  defp stub_tmdb_season(bypass, tmdb_id, season_number, episode_count) do
    episodes =
      for episode_number <- 1..episode_count do
        %{
          "season_number" => season_number,
          "episode_number" => episode_number,
          "name" => "Episode #{episode_number}"
        }
      end

    body = %{
      "season_number" => season_number,
      "name" => "Season #{season_number}",
      "episodes" => episodes
    }

    Bypass.stub(bypass, "GET", "/tmdb/tv/shows/#{tmdb_id}/#{season_number}", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  # No TVDB cross-reference and no title-search hit, so the show resolves on
  # TMDB content alone and the attrs carry only the tmdb_id under test.
  defp stub_tvdb_search_empty(bypass) do
    Bypass.stub(bypass, "GET", "/tvdb/search", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"data" => []}))
    end)
  end

  describe "auto_approve_matching_requests/2" do
    setup do
      user = create_user()
      admin = create_user(%{role: "admin"})
      %{user: user, admin: admin}
    end

    test "auto-approves pending request matching TMDB ID", %{user: user, admin: admin} do
      request = create_request(user, %{tmdb_id: 12345, media_type: "movie", title: "Test Movie"})
      media_item = create_media_item(%{type: "movie", tmdb_id: 12345, title: "Test Movie"})

      assert {:ok, [approved]} =
               MediaRequests.auto_approve_matching_requests(media_item,
                 actor_type: :user,
                 actor_id: admin.id
               )

      assert approved.id == request.id
      assert approved.status == "approved"
      assert approved.media_item_id == media_item.id
      assert approved.approved_by_id == admin.id
      assert approved.approved_at != nil
      assert approved.admin_notes =~ "Automatically approved"

      # Verify persisted in database
      reloaded = MediaRequests.get_request!(request.id)
      assert reloaded.status == "approved"
      assert reloaded.media_item_id == media_item.id
    end

    test "auto-approves pending request matching TVDB ID", %{user: user} do
      request =
        create_request(user, %{
          tvdb_id: 99999,
          tmdb_id: nil,
          media_type: "tv_show",
          title: "Test Series"
        })

      media_item = create_media_item(%{type: "tv_show", tvdb_id: 99999, title: "Test Series"})

      assert {:ok, [approved]} = MediaRequests.auto_approve_matching_requests(media_item)

      assert approved.id == request.id
      assert approved.status == "approved"
      assert approved.media_item_id == media_item.id
      assert approved.approved_by_id == nil
      assert approved.approved_at != nil
    end

    test "does not auto-approve based on IMDB ID alone without TMDB or TVDB match", %{user: user} do
      request =
        create_request(user, %{
          imdb_id: "tt1234567",
          tmdb_id: 11111,
          media_type: "movie",
          title: "IMDB Movie"
        })

      # Item with same IMDB ID but different TMDB ID (e.g. shared remoteIds across spin-offs)
      media_item =
        create_media_item(%{
          type: "movie",
          tmdb_id: 22222,
          imdb_id: "tt1234567",
          title: "Other Movie"
        })

      assert {:ok, []} = MediaRequests.auto_approve_matching_requests(media_item)

      reloaded = MediaRequests.get_request!(request.id)
      assert reloaded.status == "pending"
    end

    test "honors exclude_request_id option", %{user: user} do
      request1 = create_request(user, %{tmdb_id: 55555, media_type: "movie"})
      media_item = create_media_item(%{type: "movie", tmdb_id: 55555, title: "Movie"})

      assert {:ok, []} =
               MediaRequests.auto_approve_matching_requests(media_item,
                 exclude_request_id: request1.id
               )

      reloaded = MediaRequests.get_request!(request1.id)
      assert reloaded.status == "pending"
    end

    test "ignores requests of different media type or already non-pending", %{user: user} do
      # TV show request with same tmdb_id as a movie media item
      request1 = create_request(user, %{tmdb_id: 77777, media_type: "tv_show"})
      media_item = create_media_item(%{type: "movie", tmdb_id: 77777, title: "Movie"})

      assert {:ok, []} = MediaRequests.auto_approve_matching_requests(media_item)

      reloaded = MediaRequests.get_request!(request1.id)
      assert reloaded.status == "pending"
    end

    test "rolls back earlier approvals when a later approval fails", %{user: user} do
      first = create_request(user, %{tmdb_id: 77888, media_type: "movie"})

      second =
        create_request(user, %{tmdb_id: nil, tvdb_id: 77888, media_type: "movie"})

      invalid_media_item = %Media.MediaItem{
        id: Ecto.UUID.generate(),
        type: "movie",
        tmdb_id: 77888,
        title: "Unavailable Media Item"
      }

      assert {:error, %Ecto.Changeset{}} =
               MediaRequests.auto_approve_matching_requests(invalid_media_item)

      assert MediaRequests.get_request!(first.id).status == "pending"
      assert MediaRequests.get_request!(second.id).status == "pending"
    end

    test "Media.create_media_item/2 triggers auto-approval of matching pending requests", %{
      user: user,
      admin: admin
    } do
      request = create_request(user, %{tmdb_id: 88888, media_type: "movie", title: "Auto Movie"})
      library = library_path_fixture(%{type: "movies"})

      {:ok, media_item} =
        Media.create_media_item(
          %{
            type: "movie",
            title: "Auto Movie",
            year: 2024,
            tmdb_id: 88888,
            library_path_id: library.id
          },
          actor_type: :user,
          actor_id: admin.id,
          skip_episode_refresh: true
        )

      reloaded = MediaRequests.get_request!(request.id)
      assert reloaded.status == "approved"
      assert reloaded.media_item_id == media_item.id
      assert reloaded.approved_by_id == admin.id
    end
  end

  defp create_user(attrs \\ %{}) do
    unique_id = System.unique_integer([:positive])

    default_attrs = %{
      email: "test#{unique_id}@example.com",
      username: "testuser#{unique_id}",
      role: "guest",
      password: "password123"
    }

    {:ok, user} =
      default_attrs
      |> Map.merge(attrs)
      |> Accounts.create_user()

    user
  end

  defp create_request(user, attrs \\ %{}) do
    default_attrs = %{
      media_type: "movie",
      title: "Test Movie",
      year: 2023,
      tmdb_id: System.unique_integer([:positive]),
      requester_id: user.id
    }

    {:ok, request} =
      default_attrs
      |> Map.merge(attrs)
      |> MediaRequests.create_request()

    request
  end

  defp create_media_item(attrs) do
    type = Map.get(attrs, :type, "movie")
    lib_type = if type == "movie", do: "movies", else: "series"
    library = library_path_fixture(%{type: lib_type})

    default_attrs = %{
      type: type,
      title: "Test Media Item",
      year: 2023,
      library_path_id: library.id,
      monitored: true
    }

    %Media.MediaItem{}
    |> Media.MediaItem.changeset(Map.merge(default_attrs, attrs))
    |> Repo.insert!()
  end
end
