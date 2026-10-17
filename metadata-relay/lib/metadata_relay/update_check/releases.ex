defmodule MetadataRelay.UpdateCheck.Releases do
  @moduledoc """
  The newest Mydia server release, read from GitHub every
  `update_check.releases_refresh_ms` and held in `:persistent_term`, so an
  update check never waits on GitHub.

  The repository's release list mixes the server's `vX.Y.Z` tags with
  `plugins-v*`, `cardigann-*` and `metadata-relay-v*` releases, and GitHub's
  "latest release" marker is whatever was last flagged, so neither
  `/releases/latest` nor the first entry can be trusted. Only drafts are
  skipped and only `v`-prefixed semantic versions are considered.

  Two answers are kept: the newest stable release, for installs on a stable
  version, and the newest release of any kind, for installs already on a
  beta. A beta tester is told about the next beta, and a stable install is
  never pushed onto one.

  When GitHub cannot be reached the last good answer stays in place. Before
  the first good answer there is none, and the handler replies without a
  version, which Mydia reads as "no update known".
  """

  use GenServer

  require Logger

  alias MetadataRelay.ReqAdapter

  @key {__MODULE__, :latest}
  @releases_url "https://api.github.com/repos/getmydia/mydia/releases"
  @tag ~r/\Av(\d+\.\d+\.\d+(?:-[0-9A-Za-z.\-]+)?)\z/

  @type release :: %{version: String.t(), url: String.t()}
  @type latest :: %{stable: release() | nil, any: release() | nil}

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  The release an install on `client_version` should be offered: the newest of
  any kind for a pre-release client, otherwise the newest stable one. `nil`
  when none is known.
  """
  @spec latest_for(term()) :: release() | nil
  def latest_for(client_version) do
    latest = :persistent_term.get(@key, %{stable: nil, any: nil})
    if prerelease?(client_version), do: latest.any, else: latest.stable
  end

  defp prerelease?(version) when is_binary(version) do
    match?({:ok, %Version{pre: [_ | _]}}, Version.parse(version))
  end

  defp prerelease?(_version), do: false

  @doc "Replaces the held answer. For tests, and for `refresh/0`."
  @spec put(latest()) :: :ok
  def put(latest), do: :persistent_term.put(@key, latest)

  @doc """
  Picks the newest stable and newest overall server release from a GitHub
  release list.
  """
  @spec parse([map()]) :: latest()
  def parse(releases) when is_list(releases) do
    candidates =
      for %{"tag_name" => tag, "draft" => false} = release <- releases,
          [_, version] <- [Regex.run(@tag, tag)],
          {:ok, parsed} <- [Version.parse(version)] do
        {parsed, %{version: version, url: release["html_url"]}}
      end

    %{
      stable: newest(Enum.filter(candidates, fn {v, _} -> v.pre == [] end)),
      any: newest(candidates)
    }
  end

  defp newest([]), do: nil
  defp newest(candidates), do: candidates |> Enum.max_by(&elem(&1, 0), Version) |> elem(1)

  @doc "Fetches the release list once and stores the answer. Keeps the old one on failure."
  @spec refresh() :: :ok | {:error, term()}
  def refresh do
    request =
      Req.new(
        url: @releases_url,
        params: [per_page: 50],
        headers: [{"accept", "application/vnd.github+json"}],
        receive_timeout: 10_000,
        retry: false
      )
      |> ReqAdapter.attach(Application.get_env(:metadata_relay, :github_http_adapter))

    case Req.get(request) do
      {:ok, %Req.Response{status: 200, body: body}} when is_list(body) ->
        put(parse(body))

      {:ok, %Req.Response{status: status}} ->
        Logger.warning("[UpdateCheck] GitHub releases returned HTTP #{status}")
        {:error, {:http, status}}

      {:error, reason} ->
        Logger.warning("[UpdateCheck] GitHub releases unreachable: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @impl true
  def init(_opts) do
    case interval() do
      nil -> :ok
      _ -> send(self(), :refresh)
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:refresh, state) do
    try do
      refresh()
    rescue
      error -> Logger.error("[UpdateCheck] Release refresh failed: " <> Exception.message(error))
    end

    case interval() do
      nil -> :ok
      ms -> Process.send_after(self(), :refresh, ms)
    end

    {:noreply, state}
  end

  # An unset interval, as in test, means never: tests call put/1 or refresh/0.
  defp interval do
    case Application.get_env(:metadata_relay, :update_check, [])[:releases_refresh_ms] do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> nil
    end
  end
end
