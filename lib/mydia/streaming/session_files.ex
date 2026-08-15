defmodule Mydia.Streaming.SessionFiles do
  @moduledoc """
  Safe access to files inside an HLS streaming session's temp directory.

  Both serving paths reach the same directory: `MydiaWeb.Api.HlsController`
  over HTTP and `Mydia.P2p.Server` over the p2p bridge. They each used to
  carry their own copy of the extension table and their own idea of path
  safety, and the two had drifted: the p2p table knew `.vtt`, the HTTP one did
  not, and only the p2p path validated against traversal at all. One module so
  a receiver gets the same answer whichever route it came in on.
  """

  @doc """
  Content type for a session file, by extension.

  `.vtt` matters specifically: a Chromecast rejects a text track served as
  `application/octet-stream`.
  """
  @spec content_type(String.t()) :: String.t()
  def content_type(path) do
    case Path.extname(path) do
      ".m3u8" -> "application/vnd.apple.mpegurl"
      ".ts" -> "video/mp2t"
      ".mp4" -> "video/mp4"
      ".m4v" -> "video/mp4"
      ".m4s" -> "video/iso.segment"
      ".mkv" -> "video/x-matroska"
      ".avi" -> "video/x-msvideo"
      ".mov" -> "video/quicktime"
      ".webm" -> "video/webm"
      ".vtt" -> "text/vtt"
      _ -> "application/octet-stream"
    end
  end

  @doc """
  Resolves `name` against `temp_dir`, refusing anything that escapes it.

  `name` is rejected outright when it is itself an absolute path: `Path.join/2`
  does not treat a leading `/` on its right argument as an override the way a
  shell or `os.path.join` would, it strips the slash and appends, so joining
  against an absolute `name` would silently land back inside `temp_dir`
  instead of failing.

  The trailing separator in the prefix check is load-bearing: comparing the
  expanded paths with a bare `String.starts_with?/2` accepts `/tmp/hls/abcdef`
  for a base of `/tmp/hls/abc`, which is how the previous p2p implementation
  could be walked into a sibling session's directory.
  """
  @spec safe_path(String.t(), String.t()) :: {:ok, String.t()} | {:error, :path_traversal}
  def safe_path(temp_dir, name) do
    base = Path.expand(temp_dir)

    if Path.type(name) == :absolute do
      {:error, :path_traversal}
    else
      candidate = Path.expand(Path.join(base, name))

      if String.starts_with?(candidate, base <> "/") do
        {:ok, candidate}
      else
        {:error, :path_traversal}
      end
    end
  end
end
