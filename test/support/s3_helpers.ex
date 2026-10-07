defmodule Mydia.S3Helpers do
  @moduledoc "Helpers for tests tagged :s3, run against the devenv RustFS server."

  alias Mydia.Settings.StorageBackend
  alias Mydia.Storage.Location
  alias Mydia.Storage.S3.Request

  def backend do
    with endpoint when is_binary(endpoint) <- System.get_env("MYDIA_TEST_S3_ENDPOINT") do
      %StorageBackend{
        name: "test",
        endpoint: endpoint,
        region: "us-east-1",
        bucket: System.get_env("MYDIA_TEST_S3_BUCKET", "mydia-test"),
        access_key_id: System.fetch_env!("MYDIA_TEST_S3_ACCESS_KEY_ID"),
        secret_access_key: System.fetch_env!("MYDIA_TEST_S3_SECRET_ACCESS_KEY"),
        path_style: true
      }
    end
  end

  @doc "True when an endpoint is configured and accepts TCP connections."
  def available? do
    with %StorageBackend{endpoint: endpoint} <- backend(),
         %URI{host: host, port: port} <- URI.parse(endpoint),
         {:ok, socket} <- :gen_tcp.connect(String.to_charlist(host), port, [], 500) do
      :gen_tcp.close(socket)
      true
    else
      _ -> false
    end
  end

  @doc "Creates the test bucket. 409 (already exists/owned) counts as success."
  def ensure_bucket! do
    b = backend()

    case Req.request(Request.new(b), method: :put, url: Request.bucket_url(b)) do
      {:ok, %{status: status}} when status in [200, 409] -> :ok
      other -> raise "could not create test bucket #{b.bucket}: #{inspect(other)}"
    end
  end

  def unique_location(backend) do
    prefix = "t-#{System.unique_integer([:positive])}/"
    Location.s3(backend, prefix, "s3://#{backend.name}/#{prefix}")
  end

  def put_object!(%Location{backend: b} = loc, rel, body) do
    {:ok, %{status: 200}} =
      Req.request(Request.new(b),
        method: :put,
        url: Request.object_url(b, Location.key(loc, rel)),
        body: body
      )

    :ok
  end

  def delete_prefix!(%Location{backend: b, prefix: prefix} = loc) do
    {:ok, entries} = Mydia.Storage.list(loc)

    for e <- entries do
      Req.request!(Request.new(b),
        method: :delete,
        url: Request.object_url(b, prefix <> e.relative_path)
      )
    end

    :ok
  end
end
