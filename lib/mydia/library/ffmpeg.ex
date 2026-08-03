defmodule Mydia.Library.Ffmpeg do
  @moduledoc """
  Shared invocation of the `ffmpeg` and `ffprobe` binaries.

  Before this module existed, `run_ffmpeg/1` was copy-pasted as a private
  function into `PreviewGenerator`, `SpriteGenerator`, `PhashGenerator`, and
  `ThumbnailGenerator`. All four now delegate here.

  Both binaries can be overridden for tests via application env
  (`:ffmpeg_path`, `:ffprobe_path`), which must be absolute paths; otherwise
  they are resolved from PATH.
  """

  @doc """
  Runs `ffmpeg` with `args` and returns the combined stdout/stderr output.

  By default stderr is merged into the returned output (matching the
  original behavior of three of the four generators, which write their
  result to a file and only use the returned text for error diagnostics).

  Pass `stderr_to_stdout: false` when the command writes its actual result
  to stdout (for example piping raw frame data via `-f rawvideo ... -`), so
  ffmpeg's banner and log lines on stderr don't corrupt the payload. This
  matches `PhashGenerator`'s original behavior for its pixel-extraction call.

  The output is typed `binary()` rather than `String.t()` because it is not
  always text: `PhashGenerator` reads raw grayscale pixel bytes back through
  this function.
  """
  @spec run([String.t()], keyword()) ::
          {:ok, binary()} | {:error, :ffmpeg_not_found | {:ffmpeg_error, integer(), binary()}}
  def run(args, opts \\ []) when is_list(args) do
    invoke(executable(:ffmpeg_path, "ffmpeg"), args, opts, :ffmpeg_not_found, :ffmpeg_error)
  end

  @doc """
  Runs `ffprobe` with `args` and returns the combined stdout/stderr output.
  """
  @spec probe([String.t()]) ::
          {:ok, binary()}
          | {:error, :ffprobe_not_found | {:ffprobe_error, integer(), binary()}}
  def probe(args) when is_list(args) do
    invoke(executable(:ffprobe_path, "ffprobe"), args, [], :ffprobe_not_found, :ffprobe_error)
  end

  @doc """
  Returns true when the `ffmpeg` binary is resolvable. Used by callers that want
  to degrade gracefully rather than fail per-file.

  Only `ffmpeg` is checked; the two binaries ship together in every environment
  this runs in (the nix devenv shell and the Alpine runtime image both install
  them from a single package).
  """
  @spec available?() :: boolean()
  def available?, do: not is_nil(executable(:ffmpeg_path, "ffmpeg"))

  # An application-env override is resolved the same way as a bare name.
  # System.find_executable/1 accepts an absolute path and returns nil unless it
  # names something that is actually executable, so a stale or non-executable
  # override surfaces as :ffmpeg_not_found instead of raising inside System.cmd/3.
  defp executable(env_key, default_name) do
    System.find_executable(Application.get_env(:mydia, env_key) || default_name)
  end

  defp invoke(nil, _args, _opts, not_found_reason, _error_tag), do: {:error, not_found_reason}

  defp invoke(executable, args, opts, _not_found_reason, error_tag) do
    stderr_to_stdout = Keyword.get(opts, :stderr_to_stdout, true)

    case System.cmd(executable, args, stderr_to_stdout: stderr_to_stdout) do
      {output, 0} -> {:ok, output}
      {output, exit_code} -> {:error, {error_tag, exit_code, output}}
    end
  end
end
