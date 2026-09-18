defmodule Mydia.Plugins.Notifier.Delivery do
  @moduledoc """
  Durable delivery for the bundled webhook/Discord notifier (U10).

  The notifier is a `:durable` plugin, so the dispatcher enqueues a job here
  instead of invoking the guest inline. The job runs the guest through
  `Mydia.Plugins.Host`; the guest formats a webhook payload and POSTs it via the
  gated `http_request` host function. If delivery fails (a non-2xx response, a
  blocked host, or a host error), the job returns an error so Oban retries on the
  `:notifications` queue — exactly the durability the inline path can't give.

  The webhook URL is per-plugin config (`settings.webhook_url`), injected into
  the guest payload at delivery time. Because it is operator-editable, the gate
  re-validates its host against the granted `net:http` allowlist on **every**
  call (U6) — repointing the webhook to an unapproved or private host after
  approval is still blocked.
  """

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 5

  alias Mydia.Plugins.Host
  alias Mydia.Settings

  @doc "Enqueues a durable delivery for `slug` with the event `payload`."
  @spec enqueue(String.t(), map()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(slug, payload) do
    %{"slug" => slug, "payload" => payload}
    |> new()
    |> Oban.insert()
  end

  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"slug" => slug, "payload" => payload}}) do
    settings =
      case Settings.get_plugin_config_by_slug(slug) do
        %{settings: %{} = s} -> s
        _ -> %{}
      end

    full_payload = Map.put(payload, "config", settings)

    case Host.call(slug, "handle", full_payload) do
      {:ok, %{"delivered" => true}} ->
        :ok

      {:ok, result} ->
        {:error, "notifier delivery failed: #{inspect(result)}"}

      {:error, error} ->
        {:error, "notifier host error: #{inspect(error)}"}
    end
  end
end
