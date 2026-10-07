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

  @doc """
  Generates a 2s video with ffmpeg, uploads it under a fresh prefix and returns
  an unsaved `%MediaFile{}` pointing at it (library path preloaded). Creates the
  storage backend row when missing. Returns `{media_file, location}`; the caller
  deletes the prefix. Options: `:relative_path`, `:tmp_dir`,
  `:subtitles` (embeds a two-cue English mov_text track).
  """
  def s3_media_file!(opts \\ []) do
    relative_path = Keyword.get(opts, :relative_path, "Invented Film (2031)/film.mp4")
    tmp_dir = Keyword.get_lazy(opts, :tmp_dir, fn -> System.tmp_dir!() end)
    video = Path.join(tmp_dir, "s3-helper-#{System.unique_integer([:positive])}.mp4")

    subtitle_args =
      if Keyword.get(opts, :subtitles, false) do
        srt = Path.join(tmp_dir, "s3-helper-#{System.unique_integer([:positive])}.srt")

        File.write!(srt, """
        1
        00:00:00,000 --> 00:00:01,000
        First invented cue

        2
        00:00:01,000 --> 00:00:02,000
        Second invented cue
        """)

        ~w(-f srt -i) ++
          [srt] ++ ~w(-map 0 -map 1 -map 2 -c:s mov_text -metadata:s:s:0 language=eng)
      else
        []
      end

    {_, 0} =
      System.cmd(
        "ffmpeg",
        ~w(-y -loglevel error -f lavfi -i testsrc=duration=2:size=160x120:rate=10
           -f lavfi -i sine=duration=2) ++
          subtitle_args ++ ~w(-shortest -c:v libx264 -c:a aac) ++ [video]
      )

    backend = backend()

    unless Mydia.Settings.get_storage_backend_by_name(backend.name) do
      {:ok, _} =
        backend
        |> Map.from_struct()
        |> Map.take([
          :name,
          :endpoint,
          :region,
          :bucket,
          :access_key_id,
          :secret_access_key,
          :path_style
        ])
        |> Mydia.Settings.create_storage_backend()
    end

    loc = unique_location(backend)
    put_object!(loc, relative_path, File.read!(video))

    media_file = %Mydia.Library.MediaFile{
      id: Ecto.UUID.generate(),
      relative_path: relative_path,
      library_path: %Mydia.Settings.LibraryPath{path: String.trim_trailing(loc.uri, "/")}
    }

    {media_file, loc}
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
