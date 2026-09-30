defmodule Mydia.Plugins.Notifier.Delivery do
  @moduledoc """
  Durable delivery for the bundled webhook/Discord notifier (U10).

  The notifier is a `:durable` plugin, so the dispatcher enqueues a job here
  instead of invoking the guest inline. The job runs the guest through
  `Mydia.Plugins.Host`; the guest formats a webhook payload and POSTs it via the
  gated `http_request` host function. If delivery fails (a non-2xx response, a
  blocked host, or a host error), the job returns an error so Oban retries on the
  `:notifications` queue — exactly the durability the inline path can't give.

  The webhook URL is per-instance config (`settings.webhook_url`), injected into
  the guest payload at delivery time. Because it is operator-editable, the gate
  re-validates its host against the granted `net:http` allowlist on **every**
  call (U6) — repointing the webhook to an unapproved or private host after
  approval is still blocked.
  """

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 5

  alias Mydia.Plugins.Host
  alias Mydia.Plugins.Instances

  @doc "Enqueues a durable delivery for one instance of `slug` with the event `payload`."
  @spec enqueue(String.t(), binary(), map()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(slug, instance_id, payload) do
    %{"slug" => slug, "instance_id" => instance_id, "payload" => payload}
    |> new()
    |> Oban.insert()
  end

  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"slug" => slug, "payload" => payload} = args}) do
    # Jobs enqueued before instances existed carry no instance_id; they belong
    # to the plugin's default instance.
    instance =
      (args["instance_id"] && Instances.get(args["instance_id"])) ||
        Instances.default_instance(slug)

    full_payload = Map.put(payload, "config", Instances.config_for(instance))

    case Host.call(slug, "handle", full_payload, instance_id: instance.id) do
      {:ok, %{"delivered" => true}} ->
        :ok

      {:ok, result} ->
        {:error, "notifier delivery failed: #{inspect(result)}"}

      {:error, error} ->
        {:error, "notifier host error: #{inspect(error)}"}
    end
  end
end
