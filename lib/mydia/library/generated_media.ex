defmodule Mydia.Library.GeneratedMedia do
  @moduledoc """
  Storage module for generated media content (thumbnails, sprites, previews).

  This module manages the storage of generated content using content-addressable
  storage based on MD5 checksums. Files are stored in a tiered directory structure
  to avoid having too many files in a single directory.

  ## Storage Structure

  Files are stored using the first 4 characters of the checksum as directory tiers:

      <base_path>/<type>/xx/xx/<checksum>.<ext>

  For example, a cover with checksum `abc123def456...` would be stored at:

      /data/generated/covers/ab/c1/abc123def456.jpg

  ## Content Types

  - `:cover` - Thumbnail/cover images (JPG)
  - `:sprite` - Sprite sheets for scrubber timeline (JPG)
  - `:vtt` - WebVTT files mapping timestamps to sprite coordinates
  - `:preview` - Preview video clips (MP4)
  - `:fingerprint` - Cached Chromaprint audio fingerprints (FPR)

  ## Configuration

  The base path is configurable via the `:generated_media_path` application env key.
  Defaults to `/data/generated` in production (Docker) or `priv/generated` in dev.
  """

  @type content_type :: :cover | :sprite | :vtt | :preview | :fingerprint
  @type checksum :: String.t()

  @extensions %{
    cover: ".jpg",
    sprite: ".jpg",
    vtt: ".vtt",
    preview: ".mp4",
    fingerprint: ".fpr"
  }

  # Single source of truth for the guards below. Previously each function
  # repeated this list inline, which made adding a type a six-site change and
  # any omission a runtime FunctionClauseError rather than a compile error.
  @content_types [:cover, :sprite, :vtt, :preview, :fingerprint]

  @doc """
  Stores binary content and returns the checksum.

  Computes the MD5 checksum of the content, creates the appropriate directory
  structure, and writes the file. Returns the checksum on success.

  ## Parameters
    - `type` - The content type (`:cover`, `:sprite`, `:vtt`, `:preview`, `:fingerprint`)
    - `content` - Binary content to store

  ## Returns
    - `{:ok, checksum}` on success
    - `{:error, reason}` on failure

  ## Examples

      iex> {:ok, checksum} = GeneratedMedia.store(:cover, image_binary)
      {:ok, "abc123def456..."}
  """
  @spec store(content_type(), binary()) :: {:ok, checksum()} | {:error, term()}
  def store(type, content)
      when type in @content_types and is_binary(content) do
    checksum = compute_checksum(content)
    path = build_path(type, checksum)

    # Ensure directory exists
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    case File.write(path, content) do
      :ok -> {:ok, checksum}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Stores a file from disk and returns the checksum.

  Reads the file, computes its checksum, and copies it to the storage location.
  This is useful when the content is already on disk (e.g., FFmpeg output).

  ## Parameters
    - `type` - The content type
    - `source_path` - Path to the source file

  ## Returns
    - `{:ok, checksum}` on success
    - `{:error, reason}` on failure
  """
  @spec store_file(content_type(), Path.t()) :: {:ok, checksum()} | {:error, term()}
  def store_file(type, source_path)
      when type in @content_types and is_binary(source_path) do
    case File.read(source_path) do
      {:ok, content} ->
        store(type, content)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the absolute path for a stored file.

  ## Parameters
    - `type` - The content type
    - `checksum` - The MD5 checksum of the content

  ## Returns
    - The absolute file path

  ## Examples

      iex> GeneratedMedia.get_path(:cover, "abc123def456")
      "/data/generated/covers/ab/c1/abc123def456.jpg"
  """
  @spec get_path(content_type(), checksum()) :: Path.t()
  def get_path(type, checksum) when type in @content_types do
    build_path(type, checksum)
  end

  @doc """
  Checks if a file exists in storage.

  ## Parameters
    - `type` - The content type
    - `checksum` - The MD5 checksum of the content

  ## Returns
    - `true` if the file exists, `false` otherwise
  """
  @spec exists?(content_type(), checksum()) :: boolean()
  def exists?(type, checksum) when type in @content_types do
    type
    |> get_path(checksum)
    |> File.exists?()
  end

  @doc """
  Deletes a file from storage.

  ## Parameters
    - `type` - The content type
    - `checksum` - The MD5 checksum of the content

  ## Returns
    - `:ok` on success or if file doesn't exist
    - `{:error, reason}` on failure
  """
  @spec delete(content_type(), checksum()) :: :ok | {:error, term()}
  def delete(type, checksum) when type in @content_types do
    path = get_path(type, checksum)

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the base path for generated media storage.

  In production (Docker), this defaults to `/data/generated`.
  In development, this defaults to `priv/generated` within the app directory.

  Can be configured via `:mydia, :generated_media_path` application env.
  """
  @spec base_path() :: Path.t()
  def base_path do
    Application.get_env(:mydia, :generated_media_path, default_base_path())
  end

  @doc """
  Returns the URL path for serving a generated media file.

  This is used by the web layer to generate URLs for static file serving.

  ## Parameters
    - `type` - The content type
    - `checksum` - The MD5 checksum of the content

  ## Returns
    - The URL path (e.g., "/generated/covers/ab/c1/abc123.jpg")
  """
  @spec url_path(content_type(), checksum()) :: String.t()
  def url_path(type, checksum) when type in @content_types do
    ext = Map.fetch!(@extensions, type)
    {tier1, tier2} = split_checksum_tiers(checksum)
    type_dir = type_directory(type)

    "/generated/#{type_dir}/#{tier1}/#{tier2}/#{checksum}#{ext}"
  end

  # Private functions

  defp build_path(type, checksum) do
    ext = Map.fetch!(@extensions, type)
    {tier1, tier2} = split_checksum_tiers(checksum)
    type_dir = type_directory(type)

    Path.join([base_path(), type_dir, tier1, tier2, "#{checksum}#{ext}"])
  end

  defp split_checksum_tiers(checksum) do
    tier1 = String.slice(checksum, 0, 2)
    tier2 = String.slice(checksum, 2, 2)
    {tier1, tier2}
  end

  defp type_directory(:cover), do: "covers"
  defp type_directory(:sprite), do: "sprites"
  defp type_directory(:vtt), do: "vtt"
  defp type_directory(:preview), do: "previews"
  defp type_directory(:fingerprint), do: "fingerprints"

  defp compute_checksum(content) do
    :crypto.hash(:md5, content)
    |> Base.encode16(case: :lower)
  end

  defp default_base_path do
    # In development, use priv/generated within the app directory
    Path.join([Application.app_dir(:mydia), "priv", "generated"])
  end
end
