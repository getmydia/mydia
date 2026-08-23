defmodule MetadataRelay.GitHub.ClientTest do
  use ExUnit.Case, async: false

  import MetadataRelay.Test.GitHubHelpers

  alias MetadataRelay.GitHub.Client

  @attrs %{title: "Playback stalls", body: "It broke", labels: ["bug"]}

  setup do
    previous =
      put_github_config(client_id: "cid", client_secret: "csecret", repo: "getmydia/mydia")

    on_exit(fn ->
      restore_github_config(previous)
      clear_github_adapter()
    end)

    :ok
  end

  test "create_issue posts the draft and returns the number and URL" do
    set_github_adapter(fn request ->
      assert URI.to_string(request.url) == "https://api.github.com/repos/getmydia/mydia/issues"
      assert request.method == :post

      body = request.body |> IO.iodata_to_binary() |> Jason.decode!()
      assert body["title"] == "Playback stalls"
      assert body["body"] == "It broke"
      assert body["labels"] == ["bug"]

      {request,
       Req.Response.new(
         status: 201,
         body: %{"number" => 123, "html_url" => "https://github.com/getmydia/mydia/issues/123"}
       )}
    end)

    assert {:ok, %{number: 123, html_url: "https://github.com/getmydia/mydia/issues/123"}} =
             Client.create_issue(@attrs, "gho_token")
  end

  test "create_issue sends the caller's token" do
    set_github_adapter(fn request ->
      headers =
        Enum.flat_map(request.headers, fn {name, values} ->
          Enum.map(List.wrap(values), &{name, &1})
        end)

      assert {"authorization", "Bearer gho_token"} in headers
      assert {"x-github-api-version", "2022-11-28"} in headers

      {request, Req.Response.new(status: 201, body: %{"number" => 1, "html_url" => "u"})}
    end)

    assert {:ok, _} = Client.create_issue(@attrs, "gho_token")
  end

  test "create_issue maps a rejected token" do
    stub_status(401, %{"message" => "Bad credentials"})

    assert {:error, {:unauthorized, message}} = Client.create_issue(@attrs, "stale")
    # Case-insensitive: the copy says "Sign in again", and pinning exact
    # capitalisation would make this test churn every time the wording changes.
    assert message =~ ~r/sign in/i
  end

  test "create_issue maps a forbidden response the same way" do
    stub_status(403, %{"message" => "Forbidden"})

    assert {:error, {:unauthorized, _}} = Client.create_issue(@attrs, "stale")
  end

  test "create_issue maps a missing repository" do
    stub_status(404, %{"message" => "Not Found"})

    assert {:error, {:not_found, message}} = Client.create_issue(@attrs, "gho_token")
    assert message =~ "Repository"
  end

  test "create_issue surfaces a 422 message verbatim" do
    stub_status(422, %{"message" => "Validation Failed: label does not exist"})

    assert {:error, {:unprocessable, "Validation Failed: label does not exist"}} =
             Client.create_issue(@attrs, "gho_token")
  end

  test "create_issue maps a server error" do
    stub_status(500, %{"message" => "boom"})

    assert {:error, {:server_error, message}} = Client.create_issue(@attrs, "gho_token")
    assert message =~ "unreachable"
  end

  test "create_issue maps a transport failure" do
    set_github_adapter(fn request ->
      {request, %Req.TransportError{reason: :econnrefused}}
    end)

    assert {:error, {:transport, message}} = Client.create_issue(@attrs, "gho_token")
    assert message =~ "unreachable"
  end

  test "create_issue accepts an IssueDraft struct" do
    set_github_adapter(fn request ->
      {request, Req.Response.new(status: 201, body: %{"number" => 7, "html_url" => "u"})}
    end)

    draft = %MetadataRelay.Feedback.IssueDraft{title: "T", body: "B", labels: ["bug"]}

    assert {:ok, %{number: 7}} = Client.create_issue(draft, "gho_token")
  end

  defp stub_status(status, body) do
    set_github_adapter(fn request ->
      {request, Req.Response.new(status: status, body: body)}
    end)
  end
end
