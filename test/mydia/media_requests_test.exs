defmodule Mydia.MediaRequestsTest do
  use Mydia.DataCase, async: false

  import ExUnit.CaptureLog

  alias Mydia.Accounts.Scope
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
        MediaRequests.approve_request(Scope.unrestricted(), approved, %{approved_by_id: admin.id},
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

      assert {:ok, request} = MediaRequests.create_request(Scope.unrestricted(), attrs)
      assert request.title == "Test Movie"
      assert request.status == "pending"
      assert request.requester_id == user.id
    end

    test "requires required fields", %{user: user} do
      attrs = %{requester_id: user.id}

      assert {:error, changeset} = MediaRequests.create_request(Scope.unrestricted(), attrs)
      assert %{media_type: ["can't be blank"], title: ["can't be blank"]} = errors_on(changeset)
    end

    test "requires either TMDB ID, TVDB ID, or IMDB ID", %{user: user} do
      attrs = %{
        media_type: "movie",
        title: "Test Movie",
        requester_id: user.id
      }

      assert {:error, changeset} = MediaRequests.create_request(Scope.unrestricted(), attrs)

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

      assert {:ok, _request} = MediaRequests.create_request(Scope.unrestricted(), attrs)

      assert {:error, :duplicate_request} =
               MediaRequests.create_request(Scope.unrestricted(), attrs)
    end

    test "prevents requests for media that already exists", %{user: user} do
      # Create a media item
      {:ok, _media_item} =
        Media.create_media_item(Scope.unrestricted(), %{
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

      assert {:error, :duplicate_media} =
               MediaRequests.create_request(Scope.unrestricted(), attrs)
    end
  end

  describe "create_request/3 with a restricted scope" do
    setup do
      user = create_user()
      %{user: user}
    end

    test "refuses a request for a title out of the account's bounds", %{user: user} do
      restricted = create_user(%{role: "user"})
      {:ok, _} = Accounts.upsert_access_restriction(restricted, %{allowed_categories: ["movie"]})
      scope = Scope.for_user(Accounts.get_user!(restricted.id))

      bypass = Bypass.open()
      tmdb_id = System.unique_integer([:positive])
      stub_tmdb_movie_rated(bypass, tmdb_id, "Animated Feature", ["Animation"], "US", "G")

      attrs = %{
        media_type: "movie",
        title: "Animated Feature",
        tmdb_id: tmdb_id,
        requester_id: user.id
      }

      assert {:error, :restricted} =
               MediaRequests.create_request(scope, attrs, config: relay_config(bypass))

      refute MediaRequests.pending_request_exists?(tmdb_id)
    end

    test "allows a request for a title within the account's bounds", %{user: user} do
      restricted = create_user(%{role: "user"})
      {:ok, _} = Accounts.upsert_access_restriction(restricted, %{allowed_categories: ["movie"]})
      scope = Scope.for_user(Accounts.get_user!(restricted.id))

      bypass = Bypass.open()
      tmdb_id = System.unique_integer([:positive])
      stub_tmdb_movie_rated(bypass, tmdb_id, "Live Action Thriller", ["Thriller"], "US", "R")

      attrs = %{
        media_type: "movie",
        title: "Live Action Thriller",
        tmdb_id: tmdb_id,
        requester_id: user.id
      }

      assert {:ok, request} =
               MediaRequests.create_request(scope, attrs, config: relay_config(bypass))

      assert request.status == "pending"
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
               MediaRequests.approve_request(Scope.unrestricted(), request, attrs, config: config)

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
        Media.create_media_item(Scope.unrestricted(), %{
          type: "movie",
          title: "Existing",
          year: 2023,
          tmdb_id: request.tmdb_id
        })

      attrs = %{approved_by_id: admin.id}

      assert {:ok, %{request: updated_request, media_item: media_item}} =
               MediaRequests.approve_request(Scope.unrestricted(), request, attrs, config: config)

      assert media_item.id == existing.id
      assert updated_request.status == "approved"
      assert updated_request.media_item_id == existing.id
    end

    test "requires approved_by_id", %{request: request, config: config} do
      assert {:error, changeset} =
               MediaRequests.approve_request(Scope.unrestricted(), request, %{}, config: config)

      assert %{approved_by_id: ["can't be blank"]} = errors_on(changeset)
    end

    # `Add.from_attrs/3`'s pre-flight is scoped to the request's own media type,
    # while the unique index on tmdb_id is global. A movie holding the id is
    # therefore invisible to the lookup and only the index catches it, which is
    # the one path left that reaches insert_approval/4's media_item rollback.
    # Pinning the behaviour here: closing the cross-type gap needs a composite
    # (type, tmdb_id) index and so a migration.
    test "rolls back and leaves the request pending when the other media type owns the tmdb_id",
         %{user: user, admin: admin} do
      bypass = Bypass.open()
      tmdb_id = System.unique_integer([:positive])

      request =
        create_request(user, %{media_type: "tv_show", title: "Crossed Type", tmdb_id: tmdb_id})

      # Filed first, so create_request/1's own duplicate check does not fire:
      # the movie lands in the library while the request sits pending.
      {:ok, movie} =
        Media.create_media_item(Scope.unrestricted(), %{
          type: "movie",
          title: "Crossed Type",
          year: 2023,
          tmdb_id: tmdb_id
        })

      stub_tmdb_tv_show(bypass, tmdb_id, "Crossed Type")
      stub_tvdb_search_empty(bypass)

      before_count = Repo.aggregate(MediaItem, :count)

      log =
        capture_log(fn ->
          assert {:error, %Ecto.Changeset{} = changeset} =
                   MediaRequests.approve_request(
                     Scope.unrestricted(),
                     request,
                     %{approved_by_id: admin.id},
                     config: relay_config(bypass)
                   )

          assert %{tmdb_id: ["has already been taken"]} = errors_on(changeset)
        end)

      assert log =~ "Failed to create media item for request #{request.id}"

      reloaded = Repo.get!(MediaRequest, request.id)
      assert reloaded.status == "pending"
      assert is_nil(reloaded.media_item_id)

      assert Repo.aggregate(MediaItem, :count) == before_count
      assert Media.get_media_item_by_tmdb(Scope.unrestricted(), tmdb_id).id == movie.id
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
               MediaRequests.approve_request(
                 Scope.unrestricted(),
                 request,
                 %{approved_by_id: admin.id},
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
               MediaRequests.approve_request(
                 Scope.unrestricted(),
                 request,
                 %{approved_by_id: admin.id},
                 config: relay_config(bypass)
               )

      assert Repo.get!(MediaRequest, request.id).status == "pending"
      refute Media.get_media_item_by_tmdb(Scope.unrestricted(), request.tmdb_id)
    end

    test "reports a request with no TMDB or TVDB id rather than creating a shell", %{
      user: user,
      admin: admin
    } do
      bypass = Bypass.open()

      {:ok, request} =
        MediaRequests.create_request(Scope.unrestricted(), %{
          media_type: "movie",
          title: "IMDB Only",
          imdb_id: "tt0000001",
          requester_id: user.id
        })

      assert {:error, {:metadata, :no_provider_id}} =
               MediaRequests.approve_request(
                 Scope.unrestricted(),
                 request,
                 %{approved_by_id: admin.id},
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

      MediaRequests.approve_request(Scope.unrestricted(), request3, %{approved_by_id: admin.id},
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

  defp stub_tmdb_movie_rated(bypass, id, title, genres, country, certification) do
    body = %{
      "id" => id,
      "title" => title,
      "release_date" => "2021-03-04",
      "poster_path" => "/x.jpg",
      "overview" => "x",
      "credits" => %{"cast" => [], "crew" => []},
      "genres" => Enum.map(genres, &%{"name" => &1}),
      "release_dates" => %{
        "results" => [
          %{
            "iso_3166_1" => country,
            "release_dates" => [%{"certification" => certification}]
          }
        ]
      }
    }

    Bypass.stub(bypass, "GET", "/tmdb/movies/#{id}", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  defp stub_tmdb_tv_show(bypass, id, title) do
    body = %{
      "id" => id,
      "name" => title,
      "first_air_date" => "2021-03-04",
      "overview" => "x",
      "credits" => %{"cast" => [], "crew" => []},
      "seasons" => [],
      "genres" => []
    }

    Bypass.stub(bypass, "GET", "/tmdb/tv/shows/#{id}", fn conn ->
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
      MediaRequests.create_request(Scope.unrestricted(), Map.merge(default_attrs, attrs))

    request
  end
end
