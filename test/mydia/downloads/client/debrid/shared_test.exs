defmodule Mydia.Downloads.Client.Debrid.SharedTest do
  use ExUnit.Case, async: true

  alias Mydia.Downloads.Client.Debrid.ProviderJob
  alias Mydia.Downloads.Client.Debrid.Shared
  alias Mydia.Downloads.Client.Error
  alias Mydia.Downloads.Download

  describe "redact_url/1" do
    test "strips token query param" do
      url =
        "https://api.torbox.app/v1/api/torrents/requestdl?token=ABC123&torrent_id=1&redirect=true"

      redacted = Shared.redact_url(url)

      assert redacted =~ "token=%5BREDACTED%5D"
      refute redacted =~ "ABC123"
      assert redacted =~ "torrent_id=1"
      assert redacted =~ "redirect=true"
    end

    test "strips multiple sensitive params in one URL" do
      url = "https://example.com/file?token=A&apikey=B&agent=C&auth=D&safe=keep"

      redacted = Shared.redact_url(url)

      refute redacted =~ "token=A"
      refute redacted =~ "apikey=B"
      refute redacted =~ "agent=C"
      refute redacted =~ "auth=D"
      assert redacted =~ "safe=keep"
    end

    test "returns nil for nil input" do
      assert Shared.redact_url(nil) == nil
    end

    test "passes through URLs with no query string" do
      assert Shared.redact_url("https://example.com/path") == "https://example.com/path"
    end

    test "is case-insensitive on the parameter name" do
      assert Shared.redact_url("https://example.com/?TOKEN=secret") =~ "%5BREDACTED%5D"
    end
  end

  describe "validate_download_url/1" do
    test "accepts an HTTPS URL on a public IPv4 host" do
      assert {:ok, "https://93.184.216.34/file.mkv"} =
               Shared.validate_download_url("https://93.184.216.34/file.mkv")
    end

    test "rejects HTTP" do
      assert {:error, %Error{type: :api_error, details: details}} =
               Shared.validate_download_url("http://example.com/file.mkv")

      assert details.reason == :non_https
    end

    test "rejects file://" do
      assert {:error, %Error{}} = Shared.validate_download_url("file:///etc/passwd")
    end

    test "rejects RFC1918 10.0.0.0/8" do
      assert {:error, %Error{details: %{reason: :private_host}}} =
               Shared.validate_download_url("https://10.0.0.5/secret")
    end

    test "rejects RFC1918 192.168.0.0/16" do
      assert {:error, %Error{details: %{reason: :private_host}}} =
               Shared.validate_download_url("https://192.168.1.1/secret")
    end

    test "rejects RFC1918 172.16.0.0/12 boundaries" do
      assert {:error, %Error{details: %{reason: :private_host}}} =
               Shared.validate_download_url("https://172.16.0.1/secret")

      assert {:error, %Error{details: %{reason: :private_host}}} =
               Shared.validate_download_url("https://172.31.255.254/secret")
    end

    test "accepts public IPs in 172.0.0.0/8 outside the /12 private range" do
      # 172.15.x.x and 172.32.x.x are public — must not be caught by the
      # 172.16/12 RFC1918 pattern.
      assert {:ok, _} = Shared.validate_download_url("https://172.15.0.1/file")
      assert {:ok, _} = Shared.validate_download_url("https://172.32.0.1/file")
    end

    test "accepts a typical public IPv4 (regression: prefix=0 tautology bug)" do
      # If `@rfc1918_patterns` has a pattern with prefix=0, matches_prefix?
      # with `Enum.take(_, 0)` returns `[] == []` → true, blocking every IP.
      # A regression here would reject all public download URLs (e.g. RD's
      # chi3-4.download.real-debrid.com CDN).
      assert {:ok, _} = Shared.validate_download_url("https://93.184.216.34/file")
      assert {:ok, _} = Shared.validate_download_url("https://8.8.8.8/file")
    end

    test "rejects link-local 169.254.0.0/16 (AWS metadata)" do
      assert {:error, %Error{details: %{reason: :private_host}}} =
               Shared.validate_download_url("https://169.254.169.254/latest/meta-data/")
    end

    test "rejects loopback 127.0.0.0/8" do
      assert {:error, %Error{details: %{reason: :private_host}}} =
               Shared.validate_download_url("https://127.0.0.1/")
    end

    test "rejects literal localhost" do
      assert {:error, %Error{details: %{reason: :private_host}}} =
               Shared.validate_download_url("https://localhost/")
    end

    test "rejects 0.0.0.0/8" do
      assert {:error, %Error{details: %{reason: :private_host}}} =
               Shared.validate_download_url("https://0.0.0.0/")
    end

    test "rejects IPv6 loopback" do
      assert {:error, %Error{details: %{reason: :private_host}}} =
               Shared.validate_download_url("https://[::1]/")
    end

    test "rejects URL with no host" do
      assert {:error, %Error{details: %{reason: :missing_host}}} =
               Shared.validate_download_url("https://")
    end
  end

  describe "sanitize_error_body/2" do
    test "drops top-level apikey key" do
      body = %{"status" => "error", "apikey" => "secret123"}

      assert Shared.sanitize_error_body(body, %{api_key: "secret123"}) ==
               %{"status" => "error"}
    end

    test "drops nested sensitive keys recursively" do
      body = %{
        "data" => %{
          "token" => "x",
          "inner" => %{"authorization" => "y", "safe" => "ok"}
        }
      }

      assert Shared.sanitize_error_body(body, %{}) ==
               %{"data" => %{"inner" => %{"safe" => "ok"}}}
    end

    test "replaces literal api_key occurrences in string fields" do
      body = %{"message" => "Bad apikey: secret123"}

      assert Shared.sanitize_error_body(body, %{api_key: "secret123"}) ==
               %{"message" => "Bad apikey: [REDACTED]"}
    end

    test "is case-insensitive on sensitive keys" do
      body = %{"APIKEY" => "x", "Token" => "y", "safe" => "keep"}

      assert Shared.sanitize_error_body(body, %{}) == %{"safe" => "keep"}
    end

    test "handles lists of maps" do
      body = %{"items" => [%{"apikey" => "x"}, %{"name" => "ok"}]}

      assert Shared.sanitize_error_body(body, %{}) ==
               %{"items" => [%{}, %{"name" => "ok"}]}
    end

    test "leaves non-string, non-collection values untouched" do
      body = %{"count" => 5, "ok?" => true, "nothing" => nil}

      assert Shared.sanitize_error_body(body, %{}) == body
    end

    test "handles a nil api_key without crashing" do
      assert Shared.sanitize_error_body(%{"message" => "ok"}, %{api_key: nil}) ==
               %{"message" => "ok"}
    end

    test "handles a config without an :api_key field" do
      assert Shared.sanitize_error_body(%{"message" => "ok"}, %{}) == %{"message" => "ok"}
    end
  end

  describe "synthesize_status/3" do
    defp job(state, extras \\ %{}) do
      base = %{
        provider_id: "job-1",
        state: state,
        progress: 0.0,
        name: "Release",
        total_bytes: 1_000_000,
        files: [],
        hoster_links: [],
        raw_status: nil
      }

      ProviderJob.new(Map.merge(base, extras))
    end

    test "maps :queued → :queued" do
      status = Shared.synthesize_status(job(:queued), :not_started, nil)
      assert status.state == :queued
    end

    test "maps :downloading → :downloading with mirrored downloaded bytes" do
      status = Shared.synthesize_status(job(:downloading, %{progress: 50.0}), :not_started, nil)
      assert status.state == :downloading
      assert status.downloaded == 500_000
    end

    test "maps :finalizing → :checking (provider is packaging/uploading, local has 0 bytes)" do
      status = Shared.synthesize_status(job(:finalizing, %{progress: 100.0}), :not_started, nil)
      # `:checking` distinguishes "provider verifying" from "local fetcher
      # actively pulling" — mirroring the provider's 100% as `:downloading`
      # would falsely show full progress before Mydia has any local bytes.
      assert status.state == :checking
      assert status.downloaded == 0
      assert status.progress == 0.0
    end

    test "maps :ready + fetcher running → :downloading using Download.bytes_pulled" do
      download = %Download{bytes_pulled: 250_000, metadata: %{}}

      status = Shared.synthesize_status(job(:ready, %{progress: 100.0}), :running, download)

      assert status.state == :downloading
      assert status.downloaded == 250_000
    end

    test "maps :ready + fetcher not started + no save_path → :queued at 0 bytes" do
      download = %Download{bytes_pulled: nil, metadata: %{}}

      status = Shared.synthesize_status(job(:ready, %{progress: 100.0}), :not_started, download)

      # Provider says "done on my side" but Mydia's local Fetcher hasn't
      # started yet — report `:queued`, NOT `:downloading` at 100%, so the
      # UI doesn't show "Downloading 100%" on a torrent with zero local
      # bytes. The :ready→:queued transition is the seam the cron flips
      # to :completed once save_path is written.
      assert status.state == :queued
      assert status.downloaded == 0
      assert status.progress == 0.0
    end

    test "maps :ready + fetcher completed + save_path present → :completed" do
      download = %Download{bytes_pulled: 1_000_000, metadata: %{"save_path" => "/tmp/x"}}

      status = Shared.synthesize_status(job(:ready, %{progress: 100.0}), :completed, download)

      assert status.state == :completed
      assert status.progress == 100.0
      assert status.save_path == "/tmp/x"
      assert status.completed_at != nil
    end

    test "maps :ready + fetcher failed → :error" do
      status = Shared.synthesize_status(job(:ready), :failed, %Download{metadata: %{}})
      assert status.state == :error
    end

    test "maps :error → :error" do
      status = Shared.synthesize_status(job(:error), :not_started, nil)
      assert status.state == :error
    end

    test "handles nil download in get_status/2-style synchronous path" do
      status = Shared.synthesize_status(job(:ready, %{progress: 100.0}), :not_started, nil)
      # Same as the `download` branch above — without a Download row we
      # can't see bytes_pulled or save_path, so the lifecycle phase is
      # the pre-local-fetch :queued state.
      assert status.state == :queued
      refute status.save_path
    end

    test "carries failure category and detail through the :error clause" do
      status =
        Shared.synthesize_status(
          job(:error, %{failure_category: :missing_files, failure_detail: "missingFiles"}),
          :not_started,
          nil
        )

      assert status.state == :error
      assert status.failure_category == :missing_files
      assert status.failure_detail == "missingFiles"
    end

    test "leaves failure fields nil on an unclassified error" do
      status = Shared.synthesize_status(job(:error), :not_started, nil)

      assert status.state == :error
      assert status.failure_category == nil
      assert status.failure_detail == nil
    end

    test "never sets failure fields on a non-error state" do
      for state <- [:queued, :downloading, :finalizing, :ready] do
        status = Shared.synthesize_status(job(state), :not_started, nil)

        assert status.failure_category == nil, "#{state} leaked a failure_category"
        assert status.failure_detail == nil, "#{state} leaked a failure_detail"
      end
    end
  end

  describe "map_error/2" do
    test "returns an :api_error with provider attribution for unknown codes" do
      error = Shared.map_error(:real_debrid, "weird_thing")

      assert %Error{type: :api_error, details: %{provider: :real_debrid, raw: "weird_thing"}} =
               error
    end
  end
end
