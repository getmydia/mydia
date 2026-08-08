defmodule MydiaWeb.FlutterWatcher do
  @moduledoc """
  GenServer that watches Flutter player files and triggers production builds automatically.

  In development, this watcher monitors the player directory for changes and rebuilds
  the Flutter web app using production builds, then copies the output to Phoenix's
  static directory for serving.

  This approach is more reliable than the Flutter dev server and provides better
  dev/prod parity since we use the same serving mechanism in both environments.
  """

  use GenServer
  require Logger

  @build_output "player/build/web"
  @static_output "priv/static/player"

  # Build configuration
  @debounce_delay 300

  # File watching patterns
  @watch_paths [
    "player/lib",
    "player/web",
    "player/pubspec.yaml"
  ]

  # State structure
  defstruct [
    :pid,
    :build_in_progress,
    :debounce_timer,
    :last_build_time
  ]

  ## Public API

  @doc """
  Starts the FlutterWatcher GenServer.

  This is called automatically by Phoenix's watchers configuration in dev.exs.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  ## GenServer Callbacks

  @impl true
  def init(_opts) do
    # Only run in development
    if Application.get_env(:mydia, :dev_routes) do
      Logger.info("[FlutterWatcher] Starting Flutter file watcher...")

      case FileSystem.start_link(dirs: @watch_paths) do
        {:ok, pid} ->
          FileSystem.subscribe(pid)
          state = %__MODULE__{pid: pid, build_in_progress: false}

          # Trigger initial build
          send(self(), :build)

          {:ok, state}

        {:error, reason} ->
          Logger.error("[FlutterWatcher] Failed to start file watcher: #{inspect(reason)}")
          {:stop, reason}
      end
    else
      # In production, don't start the watcher
      :ignore
    end
  end

  @impl true
  def handle_info({:file_event, _pid, {path, _events}}, state) do
    # Ignore build output changes and generated files
    if should_trigger_build?(path) do
      Logger.debug("[FlutterWatcher] File changed: #{path}")
      state = debounce_build(state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  # Ignore file system errors
  def handle_info({:file_event, _pid, :stop}, state) do
    Logger.warning("[FlutterWatcher] File system watcher stopped")
    {:noreply, state}
  end

  # Handle debounced build trigger
  def handle_info(:build, state) do
    state = %{state | debounce_timer: nil}

    if state.build_in_progress do
      Logger.debug("[FlutterWatcher] Build already in progress, skipping...")
      {:noreply, state}
    else
      start_build_task()
      state = %{state | build_in_progress: true}
      {:noreply, state}
    end
  end

  # Handle successful build completion
  def handle_info(:build_complete, state) do
    Logger.info("[FlutterWatcher] ✓ Flutter build completed successfully")
    state = %{state | build_in_progress: false, last_build_time: System.monotonic_time(:second)}
    {:noreply, state}
  end

  # Handle build failure
  def handle_info({:build_failed, reason}, state) do
    Logger.error("[FlutterWatcher] ✗ Flutter build failed: #{reason}")
    state = %{state | build_in_progress: false}
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  ## Private Helpers

  defp start_build_task do
    Logger.info("[FlutterWatcher] Starting Flutter build...")
    parent = self()

    Task.start(fn ->
      case run_build() do
        :ok -> send(parent, :build_complete)
        {:error, reason} -> send(parent, {:build_failed, reason})
      end
    end)
  end

  defp should_trigger_build?(path) do
    # Ignore changes in build output, generated files, and hidden directories
    not (String.contains?(path, "build/") or
           String.contains?(path, ".dart_tool/") or
           String.contains?(path, ".g.dart") or
           String.contains?(path, ".freezed.dart") or
           String.contains?(path, ".graphql.dart") or
           String.ends_with?(path, "~"))
  end

  defp debounce_build(state) do
    # Cancel existing timer if any
    if state.debounce_timer do
      Process.cancel_timer(state.debounce_timer)
    end

    # Start new debounce timer
    timer = Process.send_after(self(), :build, @debounce_delay)
    %{state | debounce_timer: timer}
  end

  defp run_build do
    with :ok <- run_flutter_build(),
         :ok <- copy_build_output() do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_flutter_build do
    Logger.info("[FlutterWatcher] Running flutter build web...")

    # Run flutter build directly in the player directory.
    #
    # --pwa-strategy=none: one service worker registration per scope, and
    # player/web/sw.js needs the app's scope to serve media over p2p. Kept
    # identical across every build path so which worker ships does not depend
    # on which script produced the bundle.
    case System.cmd(
           "flutter",
           [
             "build",
             "web",
             "--base-href",
             "/player/",
             "--release",
             "--pwa-strategy=none"
           ],
           stderr_to_stdout: true,
           cd: "player"
         ) do
      {output, 0} ->
        Logger.debug("[FlutterWatcher] Build output: #{String.slice(output, -500..-1//1)}")
        :ok

      {output, exit_code} ->
        # Extract meaningful error message
        error_msg =
          output
          |> String.split("\n")
          |> Enum.filter(&(String.contains?(&1, "Error") or String.contains?(&1, "error")))
          |> Enum.take(5)
          |> Enum.join("\n")

        {:error, "Build exited with code #{exit_code}. #{error_msg}"}
    end
  end

  defp copy_build_output do
    Logger.info("[FlutterWatcher] Copying build output to #{@static_output}...")

    # Remove old files (rm_rf always succeeds)
    File.rm_rf(@static_output)

    # Copy new build
    case File.cp_r(@build_output, @static_output) do
      {:ok, _} ->
        Logger.debug("[FlutterWatcher] Build output copied successfully")
        :ok

      {:error, reason, file} ->
        {:error, "Failed to copy build output at #{file}: #{inspect(reason)}"}
    end
  end
end
