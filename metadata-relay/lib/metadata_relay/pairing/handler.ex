defmodule MetadataRelay.Pairing.Handler do
  @moduledoc """
  HTTP handler for iroh-based P2P pairing endpoints.

  Implements the simplified pairing API:
  - POST /pairing/claim - Create claim with node_addr, returns claim code
  - GET /pairing/claim/:code - Get node_addr for claim code
  - DELETE /pairing/claim/:code - Delete claim after successful pairing
  """

  alias MetadataRelay.Pairing

  @doc """
  Creates a new claim code for a node_addr.

  ## Request Body
  ```json
  {
    "node_addr": "<EndpointAddr JSON string>"
  }
  ```

  ## Response
  ```json
  {
    "claim_code": "ABC123"
  }
  ```
  """
  def create_claim(params) do
    node_addr = params["node_addr"]

    with :ok <- validate_node_addr(node_addr),
         {:ok, claim} <- Pairing.create_claim(node_addr) do
      {:ok, %{claim_code: claim.code}}
    end
  end

  @doc """
  Gets the node_addr for a claim code.

  ## Response
  ```json
  {
    "node_addr": "<EndpointAddr JSON string>"
  }
  ```

  Returns 404 if not found or expired.
  """
  def get_claim(code) do
    case Pairing.get_claim(code) do
      {:ok, node_addr} ->
        {:ok, %{node_addr: node_addr}}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Deletes a claim code.

  Called after successful pairing.

  ## Response
  204 No Content on success.
  """
  def delete_claim(code) do
    Pairing.delete_claim(code)
    {:ok, :no_content}
  end

  @lookup_key_pattern ~r/\A[0-9a-f]{64}\z/
  # A real payload is a few hundred bytes. The cap stops the store being used
  # as free blob hosting.
  @max_sealed_bytes 8192

  @doc """
  Stores a sealed claim under its blinded lookup key.

  ## Request Body
  ```json
  {"lookup_key": "<64 lowercase hex chars>", "sealed": "<base64url blob>"}
  ```

  Responds 204 with no body. The server generated the claim code itself, so
  there is nothing to hand back.
  """
  def store_sealed_claim(params) do
    with :ok <- validate_lookup_key(params["lookup_key"]),
         :ok <- validate_sealed(params["sealed"]),
         :ok <- Pairing.store_sealed(params["lookup_key"], params["sealed"]) do
      {:ok, :no_content}
    end
  end

  @doc """
  Returns the sealed blob for a lookup key, or 404 if it is unknown or expired.
  """
  def get_sealed_claim(lookup_key) do
    with :ok <- validate_lookup_key(lookup_key),
         {:ok, sealed} <- Pairing.fetch_sealed(lookup_key) do
      {:ok, %{sealed: sealed}}
    end
  end

  @doc """
  Deletes a sealed claim after a successful pairing.
  """
  def delete_sealed_claim(lookup_key) do
    with :ok <- validate_lookup_key(lookup_key) do
      Pairing.delete_sealed(lookup_key)
      {:ok, :no_content}
    end
  end

  defp validate_lookup_key(key) when is_binary(key) do
    if Regex.match?(@lookup_key_pattern, key) do
      :ok
    else
      {:error, {:validation, "lookup_key must be 64 lowercase hex characters"}}
    end
  end

  defp validate_lookup_key(_), do: {:error, {:validation, "lookup_key is required"}}

  defp validate_sealed(sealed) when is_binary(sealed) and byte_size(sealed) > 0 do
    if byte_size(sealed) <= @max_sealed_bytes do
      :ok
    else
      {:error, {:validation, "sealed exceeds #{@max_sealed_bytes} bytes"}}
    end
  end

  defp validate_sealed(_), do: {:error, {:validation, "sealed is required"}}

  # Private helpers

  defp validate_node_addr(nil), do: {:error, {:validation, "node_addr is required"}}
  defp validate_node_addr(""), do: {:error, {:validation, "node_addr is required"}}

  defp validate_node_addr(node_addr) when is_binary(node_addr) do
    case Jason.decode(node_addr) do
      {:ok, _} -> :ok
      {:error, _} -> {:error, {:validation, "node_addr must be valid JSON"}}
    end
  end

  defp validate_node_addr(_), do: {:error, {:validation, "node_addr must be a string"}}
end
