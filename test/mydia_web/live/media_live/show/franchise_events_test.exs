defmodule MydiaWeb.MediaLive.Show.FranchiseEventsTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures

  alias Mydia.Media
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

  defp stub_socket(assigns) do
    defaults = %{
      __changed__: %{},
      flash: %{},
      franchise: nil,
      adding_franchise_tmdb_id: nil,
      can_create_media: true
    }

    %Phoenix.LiveView.Socket{
      assigns: Map.merge(defaults, assigns),
      private: %{live_temp: %{}}
    }
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

      assert socket.assigns.adding_franchise_tmdb_id == 1002

      # The async body is what performs the add; run it directly.
      {:ok, media_item} = FranchiseEvents.perform_add(current, 1002, config)

      assert media_item.tmdb_id == 1002
      assert media_item.title == "Missing Sequel"
      assert media_item.monitored == false
      assert media_item.quality_profile_id == profile.id
    end

    test "refuses without create permission", %{config: config} do
      current =
        media_item_fixture(%{type: "movie", title: "First", year: 2001, tmdb_id: 1011})

      socket =
        stub_socket(%{
          media_item: current,
          metadata_config: config,
          can_create_media: false,
          franchise: franchise_with_missing(current, 1012)
        })

      {:noreply, socket} =
        FranchiseEvents.add_franchise_movie(%{"tmdb_id" => "1012"}, socket)

      assert socket.assigns.adding_franchise_tmdb_id == nil
      assert Media.get_media_item_by_tmdb(1012) == nil
    end
  end

  describe "handle_add_result/2" do
    test "flips the entry to owned and bumps the count", %{config: config} do
      current =
        media_item_fixture(%{type: "movie", title: "First", year: 2001, tmdb_id: 1021})

      added =
        media_item_fixture(%{type: "movie", title: "Missing Sequel", year: 2004, tmdb_id: 1022})

      socket =
        stub_socket(%{
          media_item: current,
          metadata_config: config,
          adding_franchise_tmdb_id: 1022,
          franchise: franchise_with_missing(current, 1022)
        })

      {:noreply, socket} = FranchiseEvents.handle_add_result({:ok, {:ok, added}}, socket)

      assert socket.assigns.adding_franchise_tmdb_id == nil
      assert socket.assigns.franchise.owned_count == 2

      entry = Enum.find(socket.assigns.franchise.entries, &(&1.tmdb_id == 1022))
      assert entry.in_library? == true
      assert entry.media_item_id == added.id
    end

    test "clears the spinner on failure", %{config: config} do
      current =
        media_item_fixture(%{type: "movie", title: "First", year: 2001, tmdb_id: 1031})

      socket =
        stub_socket(%{
          media_item: current,
          metadata_config: config,
          adding_franchise_tmdb_id: 1032,
          franchise: franchise_with_missing(current, 1032)
        })

      {:noreply, socket} =
        FranchiseEvents.handle_add_result({:ok, {:error, {:metadata, :timeout}}}, socket)

      assert socket.assigns.adding_franchise_tmdb_id == nil
      assert socket.assigns.franchise.owned_count == 1
    end
  end

  describe "handle_load_result/2" do
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

    test "leaves the franchise nil when the async task crashed", %{config: config} do
      current =
        media_item_fixture(%{type: "movie", title: "First", year: 2001, tmdb_id: 1061})

      socket = stub_socket(%{media_item: current, metadata_config: config})

      {:noreply, socket} = FranchiseEvents.handle_load_result({:exit, :boom}, socket)

      assert socket.assigns.franchise == nil
    end
  end
end
