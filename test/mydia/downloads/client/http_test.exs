defmodule Mydia.Downloads.Client.HTTPTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.Client.HTTP

  @config %{
    host: "localhost",
    port: 8080,
    username: "admin",
    password: "adminpass",
    use_ssl: false,
    options: %{}
  }

  describe "new_request/1" do
    test "creates request with HTTP scheme when SSL is disabled" do
      req = HTTP.new_request(@config)

      assert req.options[:base_url] == "http://localhost:8080"
    end

    test "creates request with HTTPS scheme when SSL is enabled" do
      config = %{@config | use_ssl: true}
      req = HTTP.new_request(config)

      assert req.options[:base_url] == "https://localhost:8080"
    end

    test "sets basic auth header when credentials provided" do
      req = HTTP.new_request(@config)

      auth_header = Req.Request.get_header(req, "authorization")
      assert auth_header != []
      assert List.first(auth_header) =~ "Basic"
    end

    test "does not set auth header when credentials missing" do
      config = Map.delete(@config, :username)
      req = HTTP.new_request(config)

      auth_header = Req.Request.get_header(req, "authorization")
      assert auth_header == []
    end

    test "uses default timeout when not specified" do
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

    test "sets retry to false" do
      req = HTTP.new_request(@config)

      assert req.options[:retry] == false
    end
  end

  describe "form_body/1" do
    test "encodes simple parameters" do
      params = %{url: "magnet:test", category: "movies"}
      body = HTTP.form_body(params)

      assert body =~ "url=magnet%3Atest"
      assert body =~ "category=movies"
    end

    test "encodes special characters" do
      params = %{message: "hello world"}
      body = HTTP.form_body(params)

      assert body == "message=hello+world"
    end

    test "handles empty map" do
      params = %{}
      body = HTTP.form_body(params)

      assert body == ""
    end

    test "encodes multiple parameters" do
      params = %{a: "1", b: "2", c: "3"}
      body = HTTP.form_body(params)

      assert body =~ "a=1"
      assert body =~ "b=2"
      assert body =~ "c=3"
    end
  end
end
