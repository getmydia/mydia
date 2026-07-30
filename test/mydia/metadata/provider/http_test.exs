defmodule Mydia.Metadata.Provider.HTTPTest do
  use ExUnit.Case, async: true

  alias Mydia.Metadata.Provider.HTTP

  @config %{
    type: :tmdb,
    api_key: "test_api_key",
    base_url: "https://api.themoviedb.org/3",
    options: %{}
  }

  describe "new_request/1" do
    test "creates request with base URL" do
      req = HTTP.new_request(@config)

      assert req.options[:base_url] == "https://api.themoviedb.org/3"
    end

    test "sets default timeout when not specified" do
      req = HTTP.new_request(@config)

      assert req.options[:receive_timeout] == 30_000
    end

    test "uses custom timeout when specified in options" do
      config = put_in(@config, [:options, :timeout], 60_000)
      req = HTTP.new_request(config)

      assert req.options[:receive_timeout] == 60_000
    end

    test "uses custom connect timeout when specified" do
      config = put_in(@config, [:options, :connect_timeout], 10_000)
      req = HTTP.new_request(config)

      assert req.options[:connect_options][:timeout] == 10_000
    end

    test "sets retry to transient with max retries" do
      req = HTTP.new_request(@config)

      assert req.options[:retry] == :transient
      assert req.options[:max_retries] == 3
    end

    test "registers a request step to inject the API key" do
      req = HTTP.new_request(@config)

      # Only a smoke check that the step is wired up. Asserting the key's
      # presence on the unsent struct is what hid the original bug, so the
      # behaviour is covered by the request-level tests further down instead.
      assert Keyword.has_key?(req.request_steps, :mydia_api_key)
    end

    test "adds API key as bearer token when auth_method is :bearer" do
      config = put_in(@config, [:options, :auth_method], :bearer)
      req = HTTP.new_request(config)

      auth_header = Req.Request.get_header(req, "authorization")
      assert auth_header != []
      assert List.first(auth_header) == "Bearer test_api_key"
    end

    test "adds API key as custom header when auth_method is :header" do
      config =
        @config
        |> put_in([:options, :auth_method], :header)
        |> put_in([:options, :api_key_header], "x-api-key")

      req = HTTP.new_request(config)

      api_key_header = Req.Request.get_header(req, "x-api-key")
      assert api_key_header != []
      assert List.first(api_key_header) == "test_api_key"
    end

    test "adds default accept and user-agent headers" do
      req = HTTP.new_request(@config)

      # Headers are stored in the request struct by Req
      accept_header = Req.Request.get_header(req, "accept")
      user_agent_header = Req.Request.get_header(req, "user-agent")

      assert accept_header == ["application/json"]
      # User-agent is dynamic: "Mydia/<version> (<architecture>)"
      assert [user_agent] = user_agent_header
      assert user_agent =~ ~r/^Mydia\/[\d.]+[\w-]* \(.+\)$/
    end

    test "raises error when base_url is missing" do
      config = Map.delete(@config, :base_url)

      assert_raise RuntimeError, "base_url is required", fn ->
        HTTP.new_request(config)
      end
    end
  end

  describe "build_image_url/2" do
    test "combines base URL with file path" do
      url = HTTP.build_image_url("https://image.tmdb.org/t/p/w500", "/poster.jpg")

      assert url == "https://image.tmdb.org/t/p/w500/poster.jpg"
    end

    test "handles file path without leading slash" do
      url = HTTP.build_image_url("https://image.tmdb.org/t/p/w500", "poster.jpg")

      assert url == "https://image.tmdb.org/t/p/w500/poster.jpg"
    end

    test "handles base URL with trailing slash" do
      url = HTTP.build_image_url("https://image.tmdb.org/t/p/w500/", "/poster.jpg")

      assert url == "https://image.tmdb.org/t/p/w500/poster.jpg"
    end

    test "returns nil when file path is nil" do
      url = HTTP.build_image_url("https://image.tmdb.org/t/p/w500", nil)

      assert url == nil
    end

    test "returns nil when file path is empty string" do
      url = HTTP.build_image_url("https://image.tmdb.org/t/p/w500", "")

      assert url == nil
    end
  end

  describe "authentication on an actual request" do
    # The new_request/1 tests above assert on the request struct before it is
    # sent. That is not enough: Req.merge/2 replaces request.url wholesale when
    # a :url option is given, so anything written directly into url.query at
    # construction time is discarded the moment get/2 or post/2 supplies a path.
    # These tests drive a real request through Bypass and assert on what the
    # server actually receives.

    setup do
      bypass = Bypass.open()

      config = fn overrides ->
        Map.merge(
          %{
            type: :tmdb,
            api_key: "test_api_key",
            base_url: "http://localhost:#{bypass.port}",
            options: %{}
          },
          overrides
        )
      end

      {:ok, bypass: bypass, config: config}
    end

    defp echo_query(bypass, path, test_pid) do
      Bypass.expect_once(bypass, "GET", path, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        send(test_pid, {:query_params, conn.query_params})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, ~s({"results": []}))
      end)
    end

    test "sends the API key as a query parameter by default", %{
      bypass: bypass,
      config: config
    } do
      echo_query(bypass, "/movie/603", self())

      req = HTTP.new_request(config.(%{}))
      assert {:ok, %Req.Response{status: 200}} = HTTP.get(req, "/movie/603")

      assert_receive {:query_params, params}
      assert params["api_key"] == "test_api_key"
    end

    test "keeps the API key alongside per-request params", %{
      bypass: bypass,
      config: config
    } do
      echo_query(bypass, "/search/movie", self())

      req = HTTP.new_request(config.(%{}))

      assert {:ok, %Req.Response{status: 200}} =
               HTTP.get(req, "/search/movie", params: [query: "Matrix", language: "en-US"])

      assert_receive {:query_params, params}
      assert params["api_key"] == "test_api_key"
      assert params["query"] == "Matrix"
      assert params["language"] == "en-US"
    end

    test "honours a custom api_key_param name", %{bypass: bypass, config: config} do
      echo_query(bypass, "/series/1396", self())

      req =
        config.(%{options: %{auth_method: :query, api_key_param: "apikey"}})
        |> HTTP.new_request()

      assert {:ok, %Req.Response{status: 200}} = HTTP.get(req, "/series/1396")

      assert_receive {:query_params, params}
      assert params["apikey"] == "test_api_key"
      refute Map.has_key?(params, "api_key")
    end

    test "accepts an arbitrary api_key_param without interning it as an atom", %{
      bypass: bypass,
      config: config
    } do
      # A name that no atom table would already contain. This passes only
      # because the param name stays a string end to end; converting it with
      # String.to_atom/1 would work here too but grows the atom table without
      # bound, and String.to_existing_atom/1 would raise.
      param = "x-mydia-provider-key-9f3c"
      refute_atom_exists = fn -> String.to_existing_atom(param) end
      assert_raise ArgumentError, refute_atom_exists

      echo_query(bypass, "/movie/603", self())

      req =
        config.(%{options: %{auth_method: :query, api_key_param: param}})
        |> HTTP.new_request()

      assert {:ok, %Req.Response{status: 200}} = HTTP.get(req, "/movie/603")

      assert_receive {:query_params, params}
      assert params[param] == "test_api_key"
    end

    test "lets a per-request param override the configured API key", %{
      bypass: bypass,
      config: config
    } do
      echo_query(bypass, "/movie/603", self())

      req = HTTP.new_request(config.(%{}))

      assert {:ok, %Req.Response{status: 200}} =
               HTTP.get(req, "/movie/603", params: [api_key: "per_request_key"])

      assert_receive {:query_params, params}
      assert params["api_key"] == "per_request_key"
    end

    test "sends a bearer token on an actual request", %{bypass: bypass, config: config} do
      test_pid = self()

      Bypass.expect_once(bypass, "GET", "/movie/603", fn conn ->
        send(test_pid, {:auth_header, Plug.Conn.get_req_header(conn, "authorization")})
        Plug.Conn.resp(conn, 200, ~s({}))
      end)

      req = HTTP.new_request(config.(%{options: %{auth_method: :bearer}}))
      assert {:ok, %Req.Response{status: 200}} = HTTP.get(req, "/movie/603")

      assert_receive {:auth_header, ["Bearer test_api_key"]}
    end

    test "omits auth entirely when no API key is configured", %{
      bypass: bypass,
      config: config
    } do
      echo_query(bypass, "/movie/603", self())

      req = config.(%{}) |> Map.delete(:api_key) |> HTTP.new_request()
      assert {:ok, %Req.Response{status: 200}} = HTTP.get(req, "/movie/603")

      assert_receive {:query_params, params}
      refute Map.has_key?(params, "api_key")
    end
  end
end
