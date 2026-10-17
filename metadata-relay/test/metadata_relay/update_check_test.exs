defmodule MetadataRelay.UpdateCheckTest do
  use ExUnit.Case, async: false

  alias MetadataRelay.{Repo, Router, UpdateCheck}
  alias MetadataRelay.UpdateCheck.{Record, Releases}

  @install_a String.duplicate("a", 64)
  @install_b String.duplicate("b", 64)

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Releases.put(%{stable: nil, any: nil})
    on_exit(fn -> Releases.put(%{stable: nil, any: nil}) end)
    :ok
  end

  defp check(overrides \\ %{}) do
    Map.merge(
      %{"install_id" => @install_a, "version" => "0.16.0", "arch" => "x86_64", "db" => "sqlite"},
      overrides
    )
  end

  defp post(body) do
    Plug.Test.conn(:post, "/update-check", Jason.encode!(body))
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Router.call(Router.init([]))
  end

  describe "record/2" do
    test "keeps one row per install per week, holding the latest check" do
      monday = ~U[2026-10-12 09:00:00Z]
      friday = ~U[2026-10-16 09:00:00Z]
      next_week = ~U[2026-10-19 09:00:00Z]

      {:ok, _} = UpdateCheck.record(check(), monday)
      {:ok, _} = UpdateCheck.record(check(%{"version" => "0.16.1"}), friday)
      {:ok, _} = UpdateCheck.record(check(%{"install_id" => @install_b}), friday)
      {:ok, _} = UpdateCheck.record(check(), next_week)

      assert [
               %{week: ~D[2026-10-19], installs: 1},
               %{week: ~D[2026-10-12], installs: 2}
             ] = UpdateCheck.weekly_counts()

      assert [{"0.16.0", 1}, {"0.16.1", 1}] = UpdateCheck.breakdown(~D[2026-10-12], :version)
    end

    test "rejects anything that is not the documented shape" do
      for bad <- [
            %{"install_id" => "not-hex"},
            %{"install_id" => String.duplicate("A", 64)},
            %{"version" => "latest"},
            %{"arch" => "x86 64; rm -rf"},
            %{"db" => "mysql"},
            %{"version" => 16}
          ] do
        assert {:error, %Ecto.Changeset{}} = UpdateCheck.record(check(bad)), inspect(bad)
      end

      assert Repo.aggregate(Record, :count) == 0
    end

    test "ignores fields it does not know" do
      {:ok, _} = UpdateCheck.record(check(%{"hostname" => "nas.local"}))
      assert [%Record{}] = Repo.all(Record)
    end
  end

  describe "POST /update-check" do
    test "records the check and offers the newest stable release to a stable install" do
      Releases.put(%{
        stable: %{version: "0.16.1", url: "https://example.test/v0.16.1"},
        any: %{version: "0.17.0-beta.2", url: "https://example.test/v0.17.0-beta.2"}
      })

      conn = post(check())

      assert conn.status == 200

      assert Jason.decode!(conn.resp_body) == %{
               "latest_version" => "0.16.1",
               "release_url" => "https://example.test/v0.16.1"
             }

      assert [%Record{install_id: @install_a, db: "sqlite"}] = Repo.all(Record)
    end

    test "offers the newest release of any kind to a beta install" do
      Releases.put(%{
        stable: %{version: "0.16.1", url: "https://example.test/v0.16.1"},
        any: %{version: "0.17.0-beta.2", url: "https://example.test/v0.17.0-beta.2"}
      })

      conn = post(check(%{"version" => "0.17.0-beta.1"}))

      assert %{"latest_version" => "0.17.0-beta.2"} = Jason.decode!(conn.resp_body)
    end

    test "answers with nulls while no release is known" do
      conn = post(check())

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body) == %{"latest_version" => nil, "release_url" => nil}
    end

    test "rejects an invalid body without recording it" do
      conn = post(check(%{"db" => "mysql"}))

      assert conn.status == 400
      assert %{"fields" => ["db"]} = Jason.decode!(conn.resp_body)
      assert Repo.aggregate(Record, :count) == 0
    end
  end

  describe "Releases.parse/1" do
    test "considers only v-prefixed server releases and skips drafts" do
      releases = [
        release("plugins-v2026.10.3"),
        release("metadata-relay-v0.20.0"),
        release("cardigann-guest-b5f4a2a9d0948caa", prerelease: true),
        release("v0.18.0", draft: true),
        release("v0.17.0-beta.2", prerelease: true),
        release("v0.17.0-beta.10", prerelease: true),
        release("v0.16.0"),
        release("v0.9.0")
      ]

      assert %{
               stable: %{version: "0.16.0", url: "https://example.test/v0.16.0"},
               any: %{version: "0.17.0-beta.10"}
             } = Releases.parse(releases)
    end

    test "a stable release outranks its own betas for a beta install" do
      latest = Releases.parse([release("v0.17.0-beta.2"), release("v0.17.0")])
      assert latest.any.version == "0.17.0"
    end

    test "an empty list knows nothing" do
      assert Releases.parse([]) == %{stable: nil, any: nil}
    end
  end

  describe "Releases.refresh/0" do
    setup do
      on_exit(fn -> Application.delete_env(:metadata_relay, :github_http_adapter) end)
    end

    test "stores the parsed answer" do
      stub_github(200, [release("v0.16.0")])

      assert :ok = Releases.refresh()
      assert %{version: "0.16.0"} = Releases.latest_for("0.15.0")
    end

    test "keeps the previous answer when GitHub fails" do
      Releases.put(%{stable: %{version: "0.16.0", url: "u"}, any: nil})
      stub_github(503, %{})

      assert {:error, {:http, 503}} = Releases.refresh()
      assert %{version: "0.16.0"} = Releases.latest_for("0.15.0")
    end
  end

  defp release(tag, opts \\ []) do
    %{
      "tag_name" => tag,
      "draft" => Keyword.get(opts, :draft, false),
      "prerelease" => Keyword.get(opts, :prerelease, false),
      "html_url" => "https://example.test/#{tag}"
    }
  end

  defp stub_github(status, body) do
    Application.put_env(:metadata_relay, :github_http_adapter, fn request ->
      {request, Req.Response.new(status: status, body: body)}
    end)
  end
end
