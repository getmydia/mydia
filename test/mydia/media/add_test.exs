defmodule Mydia.Media.AddTest do
  use Mydia.DataCase, async: false

  alias Mydia.Media.Add

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

  describe "resolve_attrs/4" do
    test "returns movie attrs carrying the poster path" do
      bypass = Bypass.open()
      id = System.unique_integer([:positive])
      stub_tmdb_movie(bypass, id, "Poster Movie", "/poster.jpg")

      assert {:ok, attrs} = Add.resolve_attrs(id, :movie, relay_config(bypass))

      assert attrs.type == "movie"
      assert attrs.title == "Poster Movie"
      assert attrs.tmdb_id == id
      assert attrs.metadata.poster_path == "/poster.jpg"
    end

    test "returns {:error, {:metadata, reason}} when the relay is unreachable" do
      bypass = Bypass.open()
      id = System.unique_integer([:positive])
      Bypass.down(bypass)

      assert {:error, {:metadata, _reason}} = Add.resolve_attrs(id, :movie, relay_config(bypass))
    end
  end

  describe "from_provider/4" do
    test "creates a movie media item with metadata attached" do
      bypass = Bypass.open()
      id = System.unique_integer([:positive])
      stub_tmdb_movie(bypass, id, "Created Movie", "/created.jpg")

      assert {:ok, item} = Add.from_provider(id, :movie, relay_config(bypass))

      assert item.title == "Created Movie"
      assert item.tmdb_id == id
      assert item.metadata.poster_path == "/created.jpg"
    end

    test "creates nothing and reports the metadata error when the relay is down" do
      bypass = Bypass.open()
      id = System.unique_integer([:positive])
      Bypass.down(bypass)

      assert {:error, {:metadata, _reason}} = Add.from_provider(id, :movie, relay_config(bypass))
      refute Mydia.Media.get_media_item_by_tmdb(id)
    end
  end
end
