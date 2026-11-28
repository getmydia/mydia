defmodule Mydia.Health.Alerts.Observations do
  @moduledoc """
  Reads the fatal conditions `Mydia.Health.Alerts` watches, right now.

  Every source is already cached in memory or is a local filesystem check, so
  gathering makes no network calls:

    * the built-in torrent client's `Status` (VPN, engine, disk),
    * `ClientHealth.status_map/0` for every download client,
    * `Indexers.Health.status_map/0` merged with
      `CardigannSummary.status_map/0`, as the home dashboard does,
    * `File.dir?/1` on each enabled, local library root.

  Returns `%{key => nil | observation}`. The four fixed keys are always
  present; `{:library_root_missing, id}` appears only for a failing root.

  A source that raises or exits is logged at most once an hour and its
  conditions read as clear: a broken health check must never invent a fatal
  banner.
  """

  require Logger

  alias Mydia.Downloads.BuiltIn.Status
  alias Mydia.Downloads.ClientHealth
  alias Mydia.Health.Alerts.Evaluator
  alias Mydia.Indexers.CardigannSummary
  alias Mydia.Settings
  alias Mydia.Settings.LibraryPath

  @log_every_seconds 3600

  @spec gather(keyword()) :: Evaluator.observations()
  def gather(sources \\ default_sources()) do
    built_in = read(sources, :built_in_status, nil)
    clients = read(sources, :client_status, %{})
    indexers = read(sources, :indexer_status, %{})
    paths = read(sources, :library_paths, [])
    dir? = Keyword.fetch!(sources, :dir?)

    built_in_blocked = built_in_blocked(built_in)

    %{
      built_in_blocked: built_in_blocked,
      built_in_low_disk: built_in_low_disk(built_in),
      all_download_clients_down: all_clients_down(clients, built_in_blocked != nil),
      all_indexers_down: all_indexers_down(indexers)
    }
    |> Map.merge(missing_roots(paths, dir?))
  end

  @doc false
  def default_sources do
    [
      built_in_status: fn -> if Process.whereis(Status), do: Status.get() end,
      client_status: &ClientHealth.status_map/0,
      indexer_status: fn ->
        Map.merge(Mydia.Indexers.Health.status_map(), CardigannSummary.status_map())
      end,
      library_paths: fn -> Settings.list_library_paths() end,
      dir?: &File.dir?/1
    ]
  end

  defp built_in_blocked(nil), do: nil

  defp built_in_blocked(%Status{} = status) do
    case Status.blocking_reason(status) do
      nil ->
        nil

      reason ->
        %{
          title: "Downloads stopped: the built-in client is blocked",
          detail: Status.describe(reason),
          fix_path: "/admin/clients"
        }
    end
  end

  defp built_in_low_disk(%Status{disk: {:low, %{free: free, reserve: reserve}}}) do
    %{
      title: "Downloads paused: low disk space",
      detail: "Free space is #{free}, below the #{reserve} reserve. Downloads are paused.",
      fix_path: "/admin/clients"
    }
  end

  defp built_in_low_disk(_), do: nil

  # When the built-in client is blocked and it is the only enabled client, the
  # built-in alert already names the cause; a second banner would be noise.
  defp all_clients_down(clients, built_in_blocked?) do
    statuses = active_statuses(clients)

    cond do
      not all_unhealthy?(statuses) ->
        nil

      built_in_blocked? and length(statuses) == 1 ->
        nil

      true ->
        %{title: "Every download client is unreachable", detail: nil, fix_path: "/admin/clients"}
    end
  end

  defp all_indexers_down(indexers) do
    if all_unhealthy?(active_statuses(indexers)),
      do: %{title: "Every indexer is failing", detail: nil, fix_path: "/admin/indexers"}
  end

  defp missing_roots(paths, dir?) do
    for %LibraryPath{disabled: false, path: path} = lp <- paths,
        is_binary(path),
        not Mydia.Storage.s3?(path),
        not dir?.(path),
        into: %{} do
      {{:library_root_missing, lp.id || path},
       %{
         title: "A library folder is missing",
         detail: "#{path} does not exist or is not a folder.",
         fix_path: "/admin/library-paths"
       }}
    end
  end

  defp active_statuses(status_map) do
    status_map
    |> Map.values()
    |> Enum.map(fn
      %{status: status} -> status
      status when is_atom(status) -> status
    end)
    |> Enum.reject(&(&1 == :disabled))
  end

  defp all_unhealthy?([]), do: false
  defp all_unhealthy?(statuses), do: Enum.all?(statuses, &(&1 == :unhealthy))

  defp read(sources, name, fallback) do
    Keyword.fetch!(sources, name).()
  rescue
    e ->
      log_failure(name, Exception.message(e))
      fallback
  catch
    kind, reason ->
      log_failure(name, inspect({kind, reason}))
      fallback
  end

  defp log_failure(name, message) do
    key = {__MODULE__, :last_logged, name}
    now = System.monotonic_time(:second)
    last = :persistent_term.get(key, nil)

    if is_nil(last) or now - last >= @log_every_seconds do
      :persistent_term.put(key, now)
      Logger.warning("Health alerts could not read #{name}: #{message}")
    end
  end
end
