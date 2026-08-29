defmodule Mydia.RelayGuard do
  @moduledoc """
  A Req adapter that refuses any request leaving this machine.

  Installed globally from `test/test_helper.exs` with
  `Req.default_options(adapter: __MODULE__)`. `Req.new/2` merges
  `default_options()` before splitting `:adapter` out into the request struct,
  so this reaches every `Req.new/1` call site with no change to `lib/`.

  Loopback traffic goes to the real `Req.Finch` adapter, which is what keeps
  Bypass working and leaves every `Mydia.MetadataCacheHelpers` warm call
  untouched. Everything else is recorded and refused.

  This exists because nothing else stopped it. `Mydia.Metadata.default_relay_config/0`
  falls back to `https://relay.mydia.dev` in test, and the cache warming that
  protects detail-page tests is opt-in and silent when forgotten (#530).
  `Mydia.MetadataStub` does not help: it swaps the provider in
  `Mydia.Metadata.Provider.Registry`, and these lookups call
  `Metadata.fetch_*_cached` against a config map directly.
  """

  alias Mydia.RelayGuard.BlockedError
  alias Mydia.RelayGuard.Escapes

  @loopback_hosts ~w(localhost 127.0.0.1 ::1)

  # RFC 2606 permanently reserves these TLDs for documentation and testing:
  # no registry will ever delegate them, so a request to a host under one can
  # never reach a real service. `example.com`/`.net`/`.org` are reserved
  # *names* under the ordinary `.com`/`.net`/`.org` TLDs and DO resolve to
  # real, internet-hosted servers today, so they are deliberately left off
  # this list — matching them here would let real traffic out.
  @reserved_tlds ~w(invalid test example)

  # RFC 5737 reserves these three /24s for documentation. They are guaranteed
  # non-routable, so a request to a literal address in one of them can never
  # reach a real service — the connection black-holes or is refused locally.
  # `Mydia.Plugins.Net.Gate.pin_url/2` rewrites a granted hostname to its
  # resolved IP before building the request, so a test that resolves into one
  # of these ranges (see `gate_test.exs`'s connect-timeout test) reaches this
  # guard as the bare IP, never the hostname.
  @reserved_ipv4_prefixes [{192, 0, 2}, {198, 51, 100}, {203, 0, 113}]

  @doc """
  The Req adapter callback.

  A reserved host (see `reserved?/1`) is handed to the real adapter alongside
  loopback traffic, on purpose: download-client and connect-timeout tests
  point at these hosts specifically to exercise real connection-error
  classification, and a genuine transport error is the whole point — which is
  exactly what `BlockedError` is designed not to be.
  """
  def run(%Req.Request{} = req) do
    if loopback?(req.url.host) or reserved?(req.url.host) do
      Req.Finch.run(req)
    else
      Escapes.record(req)
      {req, %BlockedError{url: req.url}}
    end
  end

  @doc "Whether `host` names this machine."
  def loopback?(host) when host in @loopback_hosts, do: true
  def loopback?(_host), do: false

  @doc """
  Whether `host` is a reserved, non-routable placeholder rather than a real
  destination: an RFC 2606 TLD (`.invalid`, `.test`, `.example`) or a literal
  address in an RFC 5737 documentation range.
  """
  def reserved?(host) when is_binary(host) do
    reserved_tld?(host) or reserved_ipv4?(host)
  end

  def reserved?(_host), do: false

  # Matches on the final dot-separated label so `.test` matches `host.test`
  # but not, say, "test.example.com" (whose final label is "com") or a host
  # that merely contains the word "test" somewhere else.
  defp reserved_tld?(host) do
    host
    |> String.split(".")
    |> List.last()
    |> then(&(&1 in @reserved_tlds))
  end

  defp reserved_ipv4?(host) do
    case :inet.parse_ipv4_address(String.to_charlist(host)) do
      {:ok, {a, b, c, _d}} -> {a, b, c} in @reserved_ipv4_prefixes
      {:error, _reason} -> false
    end
  end
end
