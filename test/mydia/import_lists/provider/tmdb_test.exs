defmodule Mydia.ImportLists.Provider.TMDBTest do
  @moduledoc """
  Bypass-backed tests for the TMDB import list provider.

  These tests mutate the global `:mydia, :metadata_relay_url` application env
  to point at a Bypass server, so the module runs `async: false` (see
  `test/README.md`, "To test any path reaching `default_config/1`...").
  """
  use ExUnit.Case, async: false

  alias Mydia.ImportLists.ImportList
  alias Mydia.ImportLists.Provider.TMDB

  setup do
    bypass = Bypass.open()
    previous_metadata_relay_url = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      case previous_metadata_relay_url do
        nil -> Application.delete_env(:mydia, :metadata_relay_url)
        value -> Application.put_env(:mydia, :metadata_relay_url, value)
      end
    end)

    %{bypass: bypass}
  end

  ## Helpers

  defp import_list(type, media_type, config \\ %{}) do
    %ImportList{
      id: Ecto.UUID.generate(),
      name: "Test #{type}/#{media_type}",
      type: type,
      media_type: media_type,
      config: config
    }
  end

  # A single raw TMDB result. Carries both "title"/"release_date" and
  # "name"/"first_air_date" so the same fixture works for movie and TV
  # endpoints alike; parse_result/2 only reads whichever pair applies.
  defp raw_item(id) do
    %{
      "id" => id,
      "title" => "Fictional Title #{id}",
      "name" => "Fictional Title #{id}",
      "release_date" => "2024-05-01",
      "first_air_date" => "2024-05-01",
      "poster_path" => "/poster#{id}.jpg"
    }
  end

  defp page_body(results, opts \\ []) do
    body = %{"page" => Keyword.get(opts, :page, 1), "results" => results}

    case Keyword.fetch(opts, :total_pages) do
      {:ok, total_pages} -> Map.put(body, "total_pages", total_pages)
      :error -> body
    end
  end

  defp list_body(items, opts \\ []) do
    body = %{"items" => items}

    case Keyword.fetch(opts, :total_pages) do
      {:ok, total_pages} -> Map.put(body, "total_pages", total_pages)
      :error -> body
    end
  end

  defp json_response(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end

  defp page_param(conn) do
    conn = Plug.Conn.fetch_query_params(conn)
    conn.query_params["page"]
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  ## Endpoint mapping (bug 1)

  describe "fetch_items/1 - valid type/media_type endpoint mapping" do
    @valid_pairs [
      {"tmdb_trending", "movie", "/tmdb/movies/trending"},
      {"tmdb_trending", "tv_show", "/tmdb/tv/trending"},
      {"tmdb_popular", "movie", "/tmdb/movies/popular"},
      {"tmdb_popular", "tv_show", "/tmdb/tv/popular"},
      {"tmdb_upcoming", "movie", "/tmdb/movies/upcoming"},
      {"tmdb_now_playing", "movie", "/tmdb/movies/now_playing"},
      {"tmdb_on_the_air", "tv_show", "/tmdb/tv/on_the_air"},
      {"tmdb_airing_today", "tv_show", "/tmdb/tv/airing_today"}
    ]

    test "each valid pair hits its documented endpoint", %{bypass: bypass} do
      for {type, media_type, endpoint} <- @valid_pairs do
        Bypass.expect_once(bypass, "GET", endpoint, fn conn ->
          json_response(conn, 200, page_body([raw_item(1)], total_pages: 1))
        end)

        assert {:ok, [item]} = TMDB.fetch_items(import_list(type, media_type))
        assert item.tmdb_id == 1
        assert item.media_type == media_type
      end
    end
  end

  describe "fetch_items/1 - invalid type/media_type combination" do
    @invalid_pairs [
      {"tmdb_upcoming", "tv_show"},
      {"tmdb_now_playing", "tv_show"},
      {"tmdb_on_the_air", "movie"},
      {"tmdb_airing_today", "movie"}
    ]

    test "returns a descriptive error and performs no HTTP request" do
      # No Bypass stub is registered for this describe block. Bypass fails
      # the owning test if any request reaches it with no matching
      # expectation, so a passing test here also proves no HTTP call was
      # made.
      for {type, media_type} <- @invalid_pairs do
        assert {:error, reason} = TMDB.fetch_items(import_list(type, media_type))
        assert reason =~ "Invalid TMDB list type/media_type combination"
        assert reason =~ type
        assert reason =~ media_type
      end
    end
  end

  ## Pagination (bug 2) - preset endpoint path

  describe "fetch_items/1 - preset endpoint pagination" do
    test "concatenates pages and stops once a page is shorter than the previous one", %{
      bypass: bypass
    } do
      Bypass.expect(bypass, "GET", "/tmdb/movies/trending", fn conn ->
        case page_param(conn) do
          "1" -> json_response(conn, 200, page_body([raw_item(1), raw_item(2), raw_item(3)]))
          "2" -> json_response(conn, 200, page_body([raw_item(4)]))
          other -> flunk("unexpected page requested: #{inspect(other)}")
        end
      end)

      assert {:ok, items} = TMDB.fetch_items(import_list("tmdb_trending", "movie"))
      assert Enum.map(items, & &1.tmdb_id) == [1, 2, 3, 4]
    end

    test "stops once the response's total_pages is reached", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/tmdb/movies/trending", fn conn ->
        assert page_param(conn) == "1"
        json_response(conn, 200, page_body([raw_item(1), raw_item(2)], total_pages: 1))
      end)

      assert {:ok, items} = TMDB.fetch_items(import_list("tmdb_trending", "movie"))
      assert length(items) == 2
    end

    test "stops after an empty page", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/tmdb/movies/trending", fn conn ->
        case page_param(conn) do
          "1" -> json_response(conn, 200, page_body([raw_item(1), raw_item(2)], total_pages: 5))
          "2" -> json_response(conn, 200, page_body([], total_pages: 5))
          other -> flunk("unexpected page requested: #{inspect(other)}")
        end
      end)

      assert {:ok, items} = TMDB.fetch_items(import_list("tmdb_trending", "movie"))
      assert Enum.map(items, & &1.tmdb_id) == [1, 2]
    end

    test "never requests more than the page cap", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/tmdb/movies/trending", fn conn ->
        case page_param(conn) do
          page when page in ["1", "2", "3", "4", "5"] ->
            id = String.to_integer(page)
            json_response(conn, 200, page_body([raw_item(id), raw_item(id + 100)]))

          other ->
            flunk("unexpected page requested: #{inspect(other)}")
        end
      end)

      assert {:ok, items} = TMDB.fetch_items(import_list("tmdb_trending", "movie"))
      assert length(items) == 10
    end

    test "returns items gathered so far when a later page fails", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/tmdb/movies/trending", fn conn ->
        case page_param(conn) do
          "1" ->
            json_response(
              conn,
              200,
              page_body([raw_item(1), raw_item(2), raw_item(3)], total_pages: 5)
            )

          "2" ->
            Plug.Conn.resp(conn, 500, "boom")

          other ->
            flunk("unexpected page requested: #{inspect(other)}")
        end
      end)

      assert {:ok, items} = TMDB.fetch_items(import_list("tmdb_trending", "movie"))
      assert Enum.map(items, & &1.tmdb_id) == [1, 2, 3]
    end

    test "returns an error when the first page fails", %{bypass: bypass} do
      # HTTP.new_request/1 configures retry: :transient, so a 500 is retried
      # a few times by Req before this stub's caller sees the failure; use
      # expect/4 (any number of calls) rather than expect_once/4.
      Bypass.expect(bypass, "GET", "/tmdb/movies/trending", fn conn ->
        Plug.Conn.resp(conn, 500, "boom")
      end)

      assert {:error, _reason} = TMDB.fetch_items(import_list("tmdb_trending", "movie"))
    end
  end

  ## Pagination (bug 2) - tmdb_list user-list path

  describe "fetch_items/1 - tmdb_list user list" do
    test "fetches, filters by media_type, and parses items", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/tmdb/list/4242", fn conn ->
        items = [
          Map.put(raw_item(1), "media_type", "movie"),
          Map.put(raw_item(2), "media_type", "tv")
        ]

        json_response(conn, 200, list_body(items))
      end)

      list = import_list("tmdb_list", "movie", %{"list_url" => "4242"})

      assert {:ok, [item]} = TMDB.fetch_items(list)
      assert item.tmdb_id == 1
      assert item.media_type == "movie"
    end

    test "does not request a second page when the response has no pagination metadata", %{
      bypass: bypass
    } do
      Bypass.expect_once(bypass, "GET", "/tmdb/list/4242", fn conn ->
        json_response(conn, 200, list_body([raw_item(1), raw_item(2)]))
      end)

      list = import_list("tmdb_list", "movie", %{"list_url" => "4242"})

      assert {:ok, items} = TMDB.fetch_items(list)
      assert length(items) == 2
    end

    test "paginates when the response reports total_pages", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/tmdb/list/4242", fn conn ->
        case page_param(conn) do
          "1" -> json_response(conn, 200, list_body([raw_item(1), raw_item(2)], total_pages: 2))
          "2" -> json_response(conn, 200, list_body([raw_item(3)], total_pages: 2))
          other -> flunk("unexpected page requested: #{inspect(other)}")
        end
      end)

      list = import_list("tmdb_list", "movie", %{"list_url" => "4242"})

      assert {:ok, items} = TMDB.fetch_items(list)
      assert Enum.map(items, & &1.tmdb_id) == [1, 2, 3]
    end

    test "returns a not-found error for an unknown list id", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/tmdb/list/9999", fn conn ->
        Plug.Conn.resp(conn, 404, "")
      end)

      list = import_list("tmdb_list", "movie", %{"list_url" => "9999"})

      assert {:error, reason} = TMDB.fetch_items(list)
      assert reason =~ "not found"
    end

    test "returns an error when no list ID is configured" do
      list = import_list("tmdb_list", "movie", %{})

      assert {:error, "No list ID configured"} = TMDB.fetch_items(list)
    end
  end

  ## Changeset validation (bug 1, storage layer)

  describe "changeset/2 - media_type/type compatibility" do
    @movie_only ~w(tmdb_upcoming tmdb_now_playing)
    @tv_only ~w(tmdb_on_the_air tmdb_airing_today)
    @both_types ~w(tmdb_trending tmdb_popular)

    test "rejects a movie-only type paired with tv_show" do
      for type <- @movie_only do
        changeset =
          ImportList.changeset(%ImportList{}, %{name: "Test", type: type, media_type: "tv_show"})

        refute changeset.valid?
        assert Enum.any?(errors_on(changeset).media_type, &(&1 =~ "is not supported"))
      end
    end

    test "rejects a tv-only type paired with movie" do
      for type <- @tv_only do
        changeset =
          ImportList.changeset(%ImportList{}, %{name: "Test", type: type, media_type: "movie"})

        refute changeset.valid?
        assert Enum.any?(errors_on(changeset).media_type, &(&1 =~ "is not supported"))
      end
    end

    test "accepts a movie-only type paired with movie" do
      for type <- @movie_only do
        changeset =
          ImportList.changeset(%ImportList{}, %{name: "Test", type: type, media_type: "movie"})

        assert changeset.valid?
      end
    end

    test "accepts a tv-only type paired with tv_show" do
      for type <- @tv_only do
        changeset =
          ImportList.changeset(%ImportList{}, %{name: "Test", type: type, media_type: "tv_show"})

        assert changeset.valid?
      end
    end

    test "accepts types compatible with both media types, for both media types" do
      for type <- @both_types, media_type <- ~w(movie tv_show) do
        changeset =
          ImportList.changeset(%ImportList{}, %{name: "Test", type: type, media_type: media_type})

        assert changeset.valid?
      end
    end

    test "compatible_media_types/1 and supports_media_type?/2 agree with the changeset rule" do
      for type <- @movie_only do
        assert ImportList.compatible_media_types(type) == ["movie"]
        assert ImportList.supports_media_type?(type, "movie")
        refute ImportList.supports_media_type?(type, "tv_show")
      end

      for type <- @tv_only do
        assert ImportList.compatible_media_types(type) == ["tv_show"]
        assert ImportList.supports_media_type?(type, "tv_show")
        refute ImportList.supports_media_type?(type, "movie")
      end

      for type <- @both_types do
        assert ImportList.compatible_media_types(type) == ["movie", "tv_show"]
        assert ImportList.supports_media_type?(type, "movie")
        assert ImportList.supports_media_type?(type, "tv_show")
      end
    end
  end
end
