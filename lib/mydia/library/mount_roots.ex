defmodule Mydia.Library.MountRoots do
  @moduledoc """
  Detects the filesystem roots Mydia can plausibly search when suggesting a path
  mapping for a download it can't reach.

  Reads the container's real mounts from `/proc/mounts` and keeps the data-like
  ones that share a top-level directory with a configured library path, so
  suggestions resolve to directories the operator actually recognizes (rather
  than VM-internal binds on Docker Desktop, for example). Returns `[]` on
  non-Linux hosts, when no library paths are configured, or
  when `/proc/mounts` can't be read — in which case auto-suggestion degrades
  to plain guidance. Mount probes are time-boxed so an unresponsive network or
  FUSE mount can't stall the caller.
  """

  alias Mydia.Settings

  # Pseudo / virtual filesystems that never hold media.
  @virtual_fs ~w(
    proc sysfs tmpfs devtmpfs devpts cgroup cgroup2 mqueue
    securityfs pstore bpf debugfs tracefs configfs fusectl
    hugetlbfs autofs binfmt_misc ramfs rpc_pipefs nsfs
  )

  # System path prefixes a data mount would never legitimately live under.
  @system_prefixes ~w(/proc /sys /dev /run /etc /boot /usr /bin /sbin /lib /var)

  # Wall-clock budget for probing all candidate mounts, total rather than per
  # mount (they are probed concurrently).
  @probe_timeout_ms 250

  @doc """
  Returns the detected, operator-meaningful mount roots.

  Options (for testing):
    - `:mounts_path` — path to read mounts from (default `/proc/mounts`)
    - `:library_paths` — list of library path strings (default: configured paths)
    - `:probe_fun` — 1-arity directory check (default `&File.dir?/1`)
    - `:probe_timeout_ms` — total budget for the probes (default #{@probe_timeout_ms})
  """
  @spec detect(keyword()) :: [String.t()]
  def detect(opts \\ []) do
    mounts_path = Keyword.get(opts, :mounts_path, "/proc/mounts")

    case File.read(mounts_path) do
      {:ok, contents} ->
        contents
        |> parse_mounts()
        |> Enum.filter(&data_like?/1)
        |> Enum.map(fn {mount_point, _fstype} -> mount_point end)
        |> intersect_with_libraries(library_top_levels(opts))
        |> Enum.uniq()
        |> reachable_dirs(opts)

      _ ->
        []
    end
  end

  @doc """
  Parses `/proc/mounts`-format text into `{mount_point, fstype}` tuples.
  """
  @spec parse_mounts(String.t()) :: [{String.t(), String.t()}]
  def parse_mounts(contents) when is_binary(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, " ", trim: true) do
        [_device, mount_point, fstype | _rest] -> [{unescape_octal(mount_point), fstype}]
        _ -> []
      end
    end)
  end

  defp data_like?({mount_point, fstype}) do
    fstype not in @virtual_fs and
      mount_point != "/" and
      not Enum.any?(@system_prefixes, &under_or_equal?(mount_point, &1))
  end

  # Keep mounts whose top-level segment matches a configured library path's
  # top-level segment.
  #
  # With no library paths configured there is no mapping worth suggesting, and
  # keeping every mount would mean probing arbitrary filesystems. Degrade to
  # plain guidance instead.
  defp intersect_with_libraries(_mount_points, []), do: []

  defp intersect_with_libraries(mount_points, library_tops) do
    Enum.filter(mount_points, &(top_level(&1) in library_tops))
  end

  # A wedged NFS or FUSE mount makes File.dir?/1 block in the kernel with no
  # timeout, which would stall the caller (in production, a LiveView event).
  # Probe every candidate concurrently under one wall-clock budget and drop
  # whatever has not answered.
  #
  # Caveat: killing the task unblocks this process, not the dirty IO scheduler
  # thread the probe is stuck on, which stays blocked until the kernel gives
  # up. With the probe-everything fallback removed the candidate set is
  # typically one to three mounts, so this is bounded in practice.
  defp reachable_dirs([], _opts), do: []

  defp reachable_dirs(mount_points, opts) do
    probe = Keyword.get(opts, :probe_fun, &File.dir?/1)
    timeout = Keyword.get(opts, :probe_timeout_ms, @probe_timeout_ms)

    mount_points
    |> Task.async_stream(probe,
      max_concurrency: length(mount_points),
      timeout: timeout,
      on_timeout: :kill_task,
      ordered: true
    )
    |> Enum.zip(mount_points)
    |> Enum.flat_map(fn
      {{:ok, true}, mount_point} -> [mount_point]
      {_result, _mount_point} -> []
    end)
  end

  defp library_top_levels(opts) do
    opts
    |> Keyword.get_lazy(:library_paths, fn ->
      Settings.list_library_paths() |> Enum.map(& &1.path)
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&top_level/1)
    |> Enum.uniq()
  end

  # "/data/media/tv" => "/data"; "/data" => "/data"; "/" => "/"
  defp top_level(path) do
    case Path.split(path) do
      ["/", first | _] -> "/" <> first
      _ -> path
    end
  end

  defp under_or_equal?(path, prefix) do
    path == prefix or String.starts_with?(path, prefix <> "/")
  end

  # /proc/mounts octal-escapes spaces (\040) and similar in mount points.
  defp unescape_octal(value) do
    Regex.replace(~r/\\(\d{3})/, value, fn _, octal ->
      <<String.to_integer(octal, 8)>>
    end)
  end
end
