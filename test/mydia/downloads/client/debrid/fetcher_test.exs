defmodule Mydia.Downloads.Client.Debrid.FetcherTest do
  use Mydia.DataCase, async: false

  alias Mydia.Downloads.Client.Debrid.{Fetcher, StubProvider}
  alias Mydia.Downloads.Download
  alias Mydia.Repo

  setup do
    StubProvider.ensure_started!()
    StubProvider.reset()
    on_exit(fn -> StubProvider.reset() end)

    # Start the registry + supervisor in the test if they aren't already
    # supervised (the application supervisor brings them up in dev/prod).
    ensure_started!(
      {Registry, [keys: :unique, name: Mydia.Downloads.Client.Debrid.FetcherRegistry]}
    )

    ensure_started!(
      {DynamicSupervisor,
       [name: Mydia.Downloads.Client.Debrid.FetcherSupervisor, strategy: :one_for_one]}
    )

    ensure_started!(Mydia.Downloads.Client.Debrid.RateLimiter)

    # Allow the Fetcher to stream against http://127.0.0.1:PORT URLs.
    prior = Application.get_env(:mydia, :debrid_relaxed_url_validation, false)
    Application.put_env(:mydia, :debrid_relaxed_url_validation, true)
    on_exit(fn -> Application.put_env(:mydia, :debrid_relaxed_url_validation, prior) end)

    staging = Path.join(System.tmp_dir!(), "fetcher_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(staging)
    on_exit(fn -> File.rm_rf!(staging) end)

    {:ok, staging: staging}
  end

  defp ensure_started!(child_spec) do
    case start_supervised(child_spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, :already_started} -> :ok
    end
  end

  defp insert_download(opts \\ []) do
    attrs =
      Keyword.merge(
        [
          title: "Some.Release.1080p",
          download_client: "my-rd",
          download_client_id: "rd-#{System.unique_integer([:positive])}",
          metadata: %{}
        ],
        opts
      )

    %Download{}
    |> Download.changeset(Map.new(attrs))
    |> Repo.insert!()
  end

  defp fake_provider_job(id) do
    %Mydia.Downloads.Client.Debrid.ProviderJob{
      provider_id: id,
      state: :ready,
      progress: 100.0,
      total_bytes: 100,
      files: [],
      hoster_links: []
    }
  end

  defp config(staging) do
    %{
      type: :debrid,
      api_key: "test-key",
      connection_settings: %{"provider" => "real_debrid"},
      download_directory: staging
    }
  end

  describe "happy path streaming" do
    test "streams a single file end-to-end, populates metadata, finalizes", %{staging: staging} do
      payload = String.duplicate("A", 50_000)

      bypass = Bypass.open()

      Bypass.expect(bypass, "GET", "/file.bin", fn conn ->
        Plug.Conn.resp(conn, 200, payload)
      end)

      download = insert_download()
      url = "http://127.0.0.1:#{bypass.port}/file.bin"
      StubProvider.set(:get_download_urls, {:ok, [url]})
      StubProvider.set(:rate_limit_budget, {100, 60})

      :ok =
        Fetcher.claim(
          download_id: download.id,
          config: config(staging),
          provider_job: fake_provider_job(download.download_client_id),
          provider_module: StubProvider,
          jitter_ms: 0,
          download_dir: staging
        )

      :ok = wait_for_fetcher_exit(download.id)

      reloaded = Repo.get!(Download, download.id)

      assert reloaded.bytes_pulled == 50_000

      # NOTE: completed_at is intentionally NOT set by the Fetcher's
      # finalize/2. The DownloadMonitor cron uses `is_nil(d.db_completed_at)`
      # as its "newly completed → enqueue MediaImport" filter; setting
      # completed_at here would short-circuit that and the import would
      # never run. The save_path write below is what signals completion
      # to the cron via the synthesize_status `:ready + save_path → :completed`
      # mapping.
      refute reloaded.completed_at

      save_path = reloaded.metadata["save_path"]
      assert is_binary(save_path)
      assert save_path == Path.join(staging, download.id)

      final_file = Path.join(save_path, "file.bin")
      assert File.exists?(final_file)
      assert byte_size(File.read!(final_file)) == 50_000

      assert [%{"url" => ^url, "resolved_at" => _}] = reloaded.metadata["debrid_urls"]
    end
  end

  describe "atomic claim" do
    test "two concurrent claim calls produce one running fetcher", %{staging: staging} do
      bypass = Bypass.open()

      # Slow down responses to give both claim calls time to race.
      Bypass.expect(bypass, "GET", "/file.bin", fn conn ->
        :timer.sleep(100)
        Plug.Conn.resp(conn, 200, "X")
      end)

      download = insert_download()
      url = "http://127.0.0.1:#{bypass.port}/file.bin"
      StubProvider.set(:get_download_urls, {:ok, [url]})
      StubProvider.set(:rate_limit_budget, {100, 60})

      opts = [
        download_id: download.id,
        config: config(staging),
        provider_job: fake_provider_job(download.download_client_id),
        provider_module: StubProvider,
        jitter_ms: 50,
        download_dir: staging
      ]

      [r1, r2] =
        [Task.async(fn -> Fetcher.claim(opts) end), Task.async(fn -> Fetcher.claim(opts) end)]
        |> Enum.map(&Task.await/1)

      assert r1 == :ok
      assert r2 == :ok

      # Only one registered fetcher pid; the other start_child returned
      # {:already_started, _} which `claim/1` collapses to :ok.
      {:ok, _pid} = Fetcher.whereis(download.id)

      :ok = wait_for_fetcher_exit(download.id)
    end
  end

  describe "SSRF guard" do
    test "rejects provider-returned URLs that fail validation", %{staging: staging} do
      # Disable relaxed validation just for this test so private_host check
      # still fires.
      Application.put_env(:mydia, :debrid_relaxed_url_validation, false)

      on_exit(fn ->
        Application.put_env(:mydia, :debrid_relaxed_url_validation, true)
      end)

      download = insert_download()
      StubProvider.set(:get_download_urls, {:ok, ["http://169.254.169.254/secret"]})
      StubProvider.set(:rate_limit_budget, {100, 60})

      :ok =
        Fetcher.claim(
          download_id: download.id,
          config: config(staging),
          provider_job: fake_provider_job(download.download_client_id),
          provider_module: StubProvider,
          jitter_ms: 0,
          download_dir: staging
        )

      :ok = wait_for_fetcher_exit(download.id)

      reloaded = Repo.get!(Download, download.id)
      assert reloaded.import_failed_at != nil
      assert reloaded.import_last_error =~ "fetch_failed"
    end
  end

  describe "rate limiting" do
    test "fetcher fails the download when rate limiter denies acquire", %{staging: staging} do
      download = insert_download()

      # Pre-fill the limiter at the budget. StubProvider's provider_atom
      # resolves to :unknown (it's not one of the four production modules),
      # so saturate that key.
      budget = {1, 60}
      Mydia.Downloads.Client.Debrid.RateLimiter.clear(:unknown, "saturated-key")
      Mydia.Downloads.Client.Debrid.RateLimiter.acquire(:unknown, "saturated-key", budget)

      StubProvider.set(:rate_limit_budget, budget)
      StubProvider.set(:get_download_urls, {:ok, ["https://example.com/x"]})

      :ok =
        Fetcher.claim(
          download_id: download.id,
          config: %{
            type: :debrid,
            api_key: "saturated-key",
            connection_settings: %{"provider" => "real_debrid"},
            download_directory: staging
          },
          provider_job: fake_provider_job(download.download_client_id),
          provider_module: StubProvider,
          jitter_ms: 0,
          download_dir: staging
        )

      :ok = wait_for_fetcher_exit(download.id)

      reloaded = Repo.get!(Download, download.id)
      assert reloaded.import_failed_at != nil

      assert reloaded.import_last_error =~ "rate-limited" or
               reloaded.import_last_error =~ "rate_limited"
    end
  end

  describe "jitter" do
    test "first call fires after the requested delay", %{staging: staging} do
      payload = "OK"
      bypass = Bypass.open()
      Bypass.expect(bypass, "GET", "/x.bin", fn conn -> Plug.Conn.resp(conn, 200, payload) end)

      download = insert_download()
      url = "http://127.0.0.1:#{bypass.port}/x.bin"
      StubProvider.set(:get_download_urls, {:ok, [url]})
      StubProvider.set(:rate_limit_budget, {100, 60})

      start = System.monotonic_time(:millisecond)

      :ok =
        Fetcher.claim(
          download_id: download.id,
          config: config(staging),
          provider_job: fake_provider_job(download.download_client_id),
          provider_module: StubProvider,
          jitter_ms: 200,
          download_dir: staging
        )

      :ok = wait_for_fetcher_exit(download.id)
      elapsed = System.monotonic_time(:millisecond) - start

      assert elapsed >= 200
    end
  end

  describe "the download row is deleted mid-fetch" do
    # Issue #281. A missing row must be terminal, not a retryable error: every
    # retry re-runs run/1 from the top, which makes a fresh provider call to
    # re-resolve URLs, and past finalize/2 would re-download the entire payload
    # — all against a row that no longer exists.
    test "stops instead of consuming the retry budget", %{staging: staging} do
      download = insert_download()

      StubProvider.set(:get_download_urls, {:ok, ["http://127.0.0.1:65535/never-fetched.bin"]})
      StubProvider.set(:rate_limit_budget, {100, 60})

      # persist_urls/2 runs before any streaming, so the URL above is never
      # fetched — the fetcher should be gone before it gets that far.
      Repo.delete!(download)

      :ok =
        Fetcher.claim(
          download_id: download.id,
          config: config(staging),
          provider_job: fake_provider_job(download.download_client_id),
          provider_module: StubProvider,
          jitter_ms: 0,
          download_dir: staging
        )

      # 20 attempts × 100ms = a 2s budget. The first retry sleeps 5s before
      # re-running, so exiting inside this window is the proof that the missing
      # row was treated as terminal rather than retried.
      :ok = wait_for_fetcher_exit(download.id, 20)
    end
  end

  # Polls the Fetcher's Registry entry until it's gone (or times out.)
  # Default budget is 30s — the Fetcher's retry-with-exponential-backoff
  # path (max_retries=3 with growing waits) needs more than the original
  # 3s budget. Polling stays at 100ms so successful tests still exit fast.
  defp wait_for_fetcher_exit(download_id, attempts \\ 300) do
    if attempts == 0 do
      flunk("fetcher for #{download_id} did not exit in time")
    else
      case Fetcher.whereis(download_id) do
        :error ->
          :ok

        {:ok, _pid} ->
          :timer.sleep(100)
          wait_for_fetcher_exit(download_id, attempts - 1)
      end
    end
  end
end
