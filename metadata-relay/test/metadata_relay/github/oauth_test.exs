defmodule MetadataRelay.GitHub.OAuthTest do
  use ExUnit.Case, async: false

  import MetadataRelay.Test.GitHubHelpers

  alias MetadataRelay.GitHub.OAuth

  setup do
    previous =
      put_github_config(client_id: "cid", client_secret: "csecret", repo: "getmydia/mydia")

    on_exit(fn ->
      restore_github_config(previous)
      clear_github_adapter()
    end)

    :ok
  end

  test "configured? reflects whether both credentials are present" do
    assert OAuth.configured?()

    put_github_config(client_id: "cid", client_secret: nil)
    refute OAuth.configured?()

    put_github_config([])
    refute OAuth.configured?()
  end

  test "authorize_url carries the client id and state" do
    url = OAuth.authorize_url("random-state")
    %URI{query: query} = URI.parse(url)
    params = URI.decode_query(query)

    assert String.starts_with?(url, "https://github.com/login/oauth/authorize?")
    assert params["client_id"] == "cid"
    assert params["state"] == "random-state"
  end

  test "exchange_code returns the access token" do
    set_github_adapter(fn request ->
      assert URI.to_string(request.url) == "https://github.com/login/oauth/access_token"
      {request, Req.Response.new(status: 200, body: %{"access_token" => "gho_token"})}
    end)

    assert {:ok, "gho_token"} = OAuth.exchange_code("the-code")
  end

  test "exchange_code treats a 200 carrying an error field as a failure" do
    set_github_adapter(fn request ->
      {request,
       Req.Response.new(
         status: 200,
         body: %{
           "error" => "bad_verification_code",
           "error_description" => "The code is expired."
         }
       )}
    end)

    assert {:error, {:oauth, "The code is expired."}} = OAuth.exchange_code("stale")
  end

  test "exchange_code reports a non-200 response" do
    set_github_adapter(fn request ->
      {request, Req.Response.new(status: 500, body: "boom")}
    end)

    assert {:error, {:http, 500}} = OAuth.exchange_code("the-code")
  end

  test "exchange_code reports a transport failure" do
    set_github_adapter(fn request ->
      {request, %Req.TransportError{reason: :econnrefused}}
    end)

    assert {:error, {:transport, _}} = OAuth.exchange_code("the-code")
  end

  test "fetch_user returns the login" do
    set_github_adapter(fn request ->
      assert URI.to_string(request.url) == "https://api.github.com/user"
      assert {"authorization", "Bearer gho_token"} in flat_headers(request)
      {request, Req.Response.new(status: 200, body: %{"login" => "arsfeld", "id" => 1})}
    end)

    assert {:ok, %{login: "arsfeld"}} = OAuth.fetch_user("gho_token")
  end

  test "fetch_user reports a rejected token" do
    set_github_adapter(fn request ->
      {request, Req.Response.new(status: 401, body: %{"message" => "Bad credentials"})}
    end)

    assert {:error, {:http, 401}} = OAuth.fetch_user("nope")
  end

  defp flat_headers(request) do
    Enum.flat_map(request.headers, fn {name, values} ->
      Enum.map(List.wrap(values), &{name, &1})
    end)
  end
end
