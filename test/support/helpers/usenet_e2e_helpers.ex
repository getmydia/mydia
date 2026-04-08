defmodule Mydia.Test.UsenetE2EHelpers do
  @moduledoc """
  Helper functions for E2E tests with mock SABnzbd/NZBGet services.

  These helpers call the test injection endpoints on the mock services
  to set up test data (completed downloads, files on disk, etc.).

  Requires the mock services to be running:
    docker compose -f compose.test.yml --profile usenet up -d
  """

  @sabnzbd_url System.get_env("MOCK_SABNZBD_URL", "http://localhost:18080")
  @nzbget_url System.get_env("MOCK_NZBGET_URL", "http://localhost:16789")

  @doc """
  Inject a completed item into SABnzbd history and create files on disk.

  ## Options
    - `:nzo_id` - SABnzbd NZO ID (auto-generated if nil)
    - `:filename` - Download name
    - `:storage` - Path where files are stored
    - `:files` - List of `%{path: path, size: size}` to create
    - `:size_mb` - Total size in MB (default 1000)
  """
  def inject_sabnzbd_completed(opts) do
    nzo_id = opts[:nzo_id] || "SABnzbd_nzo_e2e_#{:erlang.unique_integer([:positive])}"
    storage = opts[:storage] || "/downloads/#{nzo_id}"

    # Inject history item
    {:ok, %{status: 200}} =
      Req.post("#{@sabnzbd_url}/_test/inject-history",
        json: %{
          nzo_id: nzo_id,
          filename: opts[:filename] || "Test Download",
          storage: storage,
          status: "Completed",
          size_mb: opts[:size_mb] || 1000
        }
      )

    # Create files if specified
    if files = opts[:files] do
      {:ok, %{status: 200}} =
        Req.post("#{@sabnzbd_url}/_test/create-files",
          json: %{files: files}
        )
    end

    {:ok, nzo_id, storage}
  end

  @doc """
  Inject a completed item into NZBGet history and create files on disk.

  ## Options
    - `:nzb_id` - NZBGet NZB ID (auto-generated if nil)
    - `:name` - Download name
    - `:dest_dir` - Destination directory
    - `:files` - List of `%{path: path, size: size}` to create
    - `:size_mb` - Total size in MB (default 1000)
  """
  def inject_nzbget_completed(opts) do
    nzb_id = opts[:nzb_id] || :erlang.unique_integer([:positive])
    dest_dir = opts[:dest_dir] || "/downloads/nzbget_#{nzb_id}"

    # Inject history item
    {:ok, %{status: 200}} =
      Req.post("#{@nzbget_url}/_test/inject-history",
        json: %{
          NZBID: nzb_id,
          NZBName: opts[:name] || "Test Download",
          DestDir: dest_dir,
          Status: "SUCCESS",
          FileSizeMB: opts[:size_mb] || 1000
        }
      )

    # Create files if specified
    if files = opts[:files] do
      {:ok, %{status: 200}} =
        Req.post("#{@nzbget_url}/_test/create-files",
          json: %{files: files}
        )
    end

    {:ok, nzb_id, dest_dir}
  end

  @doc "Reset all state in both mock services."
  def reset_mock_services do
    Req.post("#{@sabnzbd_url}/_test/reset")
    Req.post("#{@nzbget_url}/_test/reset")
    :ok
  rescue
    _ -> :ok
  end

  @doc "Check if mock SABnzbd is reachable."
  def sabnzbd_available? do
    case Req.get("#{@sabnzbd_url}/health", connect_options: [timeout: 1000], max_retries: 0) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc "Check if mock NZBGet is reachable."
  def nzbget_available? do
    case Req.get("#{@nzbget_url}/health", connect_options: [timeout: 1000], max_retries: 0) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  @doc "Get the SABnzbd mock service URL."
  def sabnzbd_url, do: @sabnzbd_url

  @doc "Get the NZBGet mock service URL."
  def nzbget_url, do: @nzbget_url
end
