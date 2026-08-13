defmodule MydiaWeb.PlayerAssets do
  @moduledoc """
  Content-addressed etags for the built Flutter web player.

  Flutter does not content-hash its web output, so every build overwrites
  `main.dart.js` at the same URL and the bundle can only be cached against a
  validator. `Plug.Static`'s default validator is `phash2({size, mtime})`,
  which is wrong for this tree in a way that only shows up in production: a
  container image stamps a fresh mtime on every file it ships, so each deploy
  invalidates the whole player, including the canvaskit blobs and fonts whose
  bytes have not changed since the Flutter SDK was last bumped. The browser
  re-downloads several megabytes to learn that nothing moved.

  Hashing the bytes instead means the validator tracks content, so a redeploy
  costs one conditional request per asset and re-transfers only what actually
  changed. Paired with `cache-control: no-cache` on the same tree, the result
  is a bundle that is always correct and almost never re-sent.

  The hash is memoized against the file's size and mtime, so it is computed
  once per file per deploy rather than per request, and a dev rebuild is
  picked up without a restart. A file the clock says is still settling is
  hashed outright, because mtime only has one-second resolution and a rewrite
  inside that second at the same byte count is otherwise invisible.
  """

  require Logger

  @doc """
  Builds the etag `Plug.Static` sends for `path`.

  Wired in as `:etag_generation`, which is why this returns the header value
  complete with its quotes rather than a bare digest.
  """
  @spec etag(Path.t()) :: binary()
  def etag(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{size: size, mtime: mtime}} ->
        cached_or_hash(path, size, mtime)

      {:error, reason} ->
        # Plug.Static only calls this after its own stat has decided the file
        # is servable, so a failure here means it moved underneath us and the
        # send that follows is going to fail regardless of what we return.
        # A validator that cannot match is simply the honest answer.
        Logger.warning(
          "Player asset vanished while building its etag: #{path} (#{inspect(reason)})"
        )

        quoted(Base.encode16(:crypto.strong_rand_bytes(8), case: :lower))
    end
  end

  # A file whose mtime is younger than @settle_seconds may be rewritten again
  # inside the same second at the same byte count, which {size, mtime} cannot
  # tell apart from no change at all. Hash those outright and only memoize a
  # file that has stopped moving. Anything shipped in a container image is
  # settled the moment the process starts, so this costs nothing in production
  # and keeps a dev rebuild honest.
  @settle_seconds 2

  defp cached_or_hash(path, size, mtime) do
    age = System.os_time(:second) - mtime

    # `age >= 0` matters as much as the upper bound. A file dated in the future
    # is not unsettled, it is a clock disagreement: a NAS whose RTC has not
    # caught up with NTP, or an image built minutes ahead of the host pulling
    # it. Testing only the upper bound would put every asset on that host in
    # the re-hash branch permanently, turning each anonymous GET of a 4.5MB
    # bundle into a full read and sha256.
    if age >= 0 and age < @settle_seconds do
      hash(path)
    else
      memoized(path, size, mtime)
    end
  end

  defp memoized(path, size, mtime) do
    key = {__MODULE__, path}

    case :persistent_term.get(key, nil) do
      {^size, ^mtime, etag} ->
        etag

      _ ->
        etag = hash(path)
        # Written once per file per deploy. The global scan a put costs is
        # affordable at that rate and buys a hash-free steady state.
        :persistent_term.put(key, {size, mtime, etag})
        etag
    end
  end

  defp hash(path) do
    path
    |> File.stream!(2_097_152)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
    # A prefix, because an etag is compared for equality and never inverted.
    |> binary_part(0, 32)
    |> quoted()
  end

  defp quoted(digest), do: <<?", digest::binary, ?">>
end
