defmodule Mydia.Indexers.Cardigann.Parity.Recorder do
  @moduledoc """
  Collects the exchanges an engine performs so they can be written out as a
  `Capture`. Credential-bearing response headers are redacted on the way in,
  so nothing sensitive ever sits in the recorder.
  """

  use Agent

  alias Mydia.Indexers.Cardigann.Parity.Capture
  alias Mydia.Indexers.Cardigann.Parity.Capture.Exchange
  alias Mydia.Indexers.Cardigann.Parity.RequestKey

  @type response :: %{status: non_neg_integer(), headers: [map()], body: binary()}
  @type error_kind :: :timeout | :connect | :blocked | :other

  @spec start_link() :: {:ok, pid()}
  def start_link, do: Agent.start_link(fn -> [] end)

  @spec record(pid(), RequestKey.t(), {:ok, response()} | {:error, {error_kind(), String.t()}}) ::
          :ok
  def record(pid, %RequestKey{} = key, {:ok, %{status: status, headers: headers, body: body}}) do
    exchange = %Exchange{
      request: key,
      status: status,
      headers: headers |> Enum.map(&header_pair/1) |> Capture.redact_headers(),
      body: body
    }

    Agent.update(pid, &[exchange | &1])
  end

  def record(pid, %RequestKey{} = key, {:error, {kind, _message}}) when is_atom(kind) do
    Agent.update(pid, &[%Exchange{request: key, error: kind} | &1])
  end

  @doc "The recorded exchanges, in the order they were made."
  @spec exchanges(pid()) :: [Exchange.t()]
  def exchanges(pid), do: pid |> Agent.get(& &1) |> Enum.reverse()

  defp header_pair(%{name: name, value: value}), do: {name, value}
  defp header_pair({name, value}), do: {name, value}
end
