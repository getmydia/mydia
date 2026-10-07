defmodule Mydia.Storage.S3.Request do
  @moduledoc false
  # URL building, signing and response decoding for Mydia.Storage.S3.

  import SweetXml, only: [sigil_x: 2, xpath: 2, xpath: 3]

  alias Mydia.Settings.StorageBackend
  alias Mydia.Storage.Error

  @presign_seconds 12 * 60 * 60

  @spec new(StorageBackend.t(), keyword()) :: Req.Request.t()
  def new(%StorageBackend{} = b, opts \\ []) do
    [
      aws_sigv4: [
        access_key_id: b.access_key_id,
        secret_access_key: b.secret_access_key,
        region: b.region,
        service: :s3
      ],
      retry: :transient,
      max_retries: 3,
      receive_timeout: 30_000,
      decode_body: false
    ]
    |> Keyword.merge(opts)
    |> Req.new()
  end

  @doc """
  `:ok` when the backend's endpoint is a plain http(s)://host[:port] URL, else a
  `:misconfigured` error. Req raises on a URL without a scheme or host.
  """
  @spec check(StorageBackend.t()) :: :ok | {:error, Error.t()}
  def check(%StorageBackend{} = b) do
    uri = URI.parse(StorageBackend.endpoint_url(b))

    if uri.scheme in ["http", "https"] and uri.host not in [nil, ""] and is_nil(uri.userinfo),
      do: :ok,
      else: {:error, Error.new(:misconfigured, "invalid endpoint for storage backend #{b.name}")}
  end

  @spec bucket_url(StorageBackend.t()) :: String.t()
  def bucket_url(%StorageBackend{path_style: true} = b),
    do: StorageBackend.endpoint_url(b) <> "/" <> b.bucket

  def bucket_url(%StorageBackend{} = b) do
    uri = URI.parse(StorageBackend.endpoint_url(b))
    URI.to_string(%URI{uri | host: "#{b.bucket}.#{uri.host}", path: nil})
  end

  @spec object_url(StorageBackend.t(), String.t()) :: String.t()
  def object_url(b, key), do: bucket_url(b) <> "/" <> encode_key(key)

  @doc "The `x-amz-copy-source` value for an object in the same bucket."
  @spec copy_source(StorageBackend.t(), String.t()) :: String.t()
  def copy_source(%StorageBackend{bucket: bucket}, key),
    do: "/" <> bucket <> "/" <> encode_key(key)

  @spec delete_objects_body([String.t()]) :: String.t()
  def delete_objects_body(keys) do
    objects = Enum.map_join(keys, fn key -> "<Object><Key>#{xml_escape(key)}</Key></Object>" end)
    ~s(<?xml version="1.0" encoding="UTF-8"?><Delete><Quiet>true</Quiet>#{objects}</Delete>)
  end

  @spec xml_escape(String.t()) :: String.t()
  def xml_escape(text) do
    text
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  @doc """
  CopyObject, UploadPartCopy, CompleteMultipartUpload and a quiet
  DeleteObjects can all answer 200 with an `<Error>` in the body.
  """
  @spec error_body?(term()) :: boolean()
  def error_body?(body) when is_binary(body), do: String.contains?(body, "<Error>")
  def error_body?(_), do: false

  @spec parse_upload_id(binary()) :: String.t() | nil
  def parse_upload_id(body), do: xml_text(body, ~x"//UploadId/text()"s)

  @doc "The ETag from a CopyObjectResult or CopyPartResult body."
  @spec parse_etag(binary()) :: String.t() | nil
  def parse_etag(body), do: xml_text(body, ~x"//ETag/text()"s)

  @spec complete_body([{pos_integer(), String.t()}]) :: String.t()
  def complete_body(parts) do
    inner =
      Enum.map_join(parts, fn {n, etag} ->
        "<Part><PartNumber>#{n}</PartNumber><ETag>#{xml_escape(etag)}</ETag></Part>"
      end)

    "<CompleteMultipartUpload>#{inner}</CompleteMultipartUpload>"
  end

  defp xml_text(body, path) when is_binary(body) and body != "" do
    case xpath(SweetXml.parse(body, quiet: true), path) do
      "" -> nil
      text -> text
    end
  catch
    _, _ -> nil
  end

  defp xml_text(_, _), do: nil

  @spec content_md5(iodata()) :: String.t()
  def content_md5(body), do: :md5 |> :crypto.hash(body) |> Base.encode64()

  @spec encode_key(String.t()) :: String.t()
  def encode_key(key), do: URI.encode(key, &(URI.char_unreserved?(&1) or &1 == ?/))

  @spec presign(StorageBackend.t(), String.t(), keyword()) :: String.t()
  def presign(b, key, opts \\ []) do
    [
      access_key_id: b.access_key_id,
      secret_access_key: b.secret_access_key,
      region: b.region,
      service: "s3",
      method: :get,
      url: object_url(b, key),
      expires: Keyword.get(opts, :expires, @presign_seconds),
      datetime: DateTime.utc_now()
    ]
    |> Req.Utils.aws_sigv4_url()
    |> to_string()
  end

  @spec head_bucket(StorageBackend.t()) :: :ok | {:error, Error.t()}
  def head_bucket(%StorageBackend{} = b) do
    case Req.request(new(b), method: :head, url: bucket_url(b)) do
      {:ok, %Req.Response{status: 200}} -> :ok
      other -> {:error, map_error(other, "bucket #{b.bucket}")}
    end
  end

  @spec map_error({:ok, Req.Response.t()} | {:error, Exception.t()}, String.t()) :: Error.t()
  def map_error({:ok, %Req.Response{status: 404}}, what),
    do: Error.new(:not_found, "not found: #{what}")

  def map_error({:ok, %Req.Response{status: s}}, what) when s in [401, 403],
    do: Error.new(:forbidden, "access denied: #{what}")

  def map_error({:ok, %Req.Response{status: s, body: body}}, what),
    do: Error.new(:provider, "S3 #{s} #{error_code(body)} for #{what}")

  def map_error({:error, %Req.TransportError{reason: reason}}, what),
    do: Error.new(:unreachable, "cannot reach storage (#{inspect(reason)}) for #{what}")

  def map_error({:error, exception}, what),
    do: Error.new(:unreachable, "#{Exception.message(exception)} for #{what}")

  @spec parse_list(binary()) :: {[map()], String.t() | nil}
  def parse_list(xml) do
    doc = SweetXml.parse(xml, quiet: true)

    contents =
      xpath(doc, ~x"//Contents"l,
        key: ~x"./Key/text()"s,
        size: ~x"./Size/text()"i,
        last_modified: ~x"./LastModified/text()"s
      )

    token =
      if xpath(doc, ~x"//IsTruncated/text()"s) == "true",
        do: xpath(doc, ~x"//NextContinuationToken/text()"s),
        else: nil

    {contents, token}
  end

  @spec parse_time(String.t() | nil) :: DateTime.t()
  def parse_time(nil), do: DateTime.from_unix!(0)

  def parse_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _} ->
        DateTime.truncate(dt, :second)

      _ ->
        case :httpd_util.convert_request_date(String.to_charlist(value)) do
          {{_, _, _}, {_, _, _}} = erl ->
            erl |> NaiveDateTime.from_erl!() |> DateTime.from_naive!("Etc/UTC")

          _ ->
            DateTime.from_unix!(0)
        end
    end
  end

  defp error_code(body) when is_binary(body) and body != "" do
    xpath(SweetXml.parse(body, quiet: true), ~x"//Error/Code/text()"s)
  catch
    _, _ -> ""
  end

  defp error_code(_), do: ""
end
