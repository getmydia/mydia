defmodule MetadataRelay.Backup do
  @moduledoc """
  End-to-end encrypted player backup: vaults, members and slot ciphertext.

  The relay never sees plaintext. A vault is a group of players, each member
  owning one slot it alone may write. Slot files live under `backup.dir` (see
  `MetadataRelay.Backup.Store`) and rows live in SQLite.

  Public keys, ids and envelopes come in as raw binaries (signers 32 bytes,
  ids lowercase hex) and are stored base64url. Functions that return keys or
  envelopes decode them back to raw binaries, so the HTTP layer base64url
  encodes them on the way out.
  """

  import Ecto.Query

  alias MetadataRelay.Backup.{Member, Slot, Store, Vault}
  alias MetadataRelay.RateLimiter
  alias MetadataRelay.Repo

  @max_slot_bytes 4_194_304
  @write_limit 120
  @write_window_ms 3_600_000

  @vault_id ~r/\A[0-9a-f]{32}\z/
  @slot_id ~r/\A[0-9a-f]{16}\z/
  @lookup_hash ~r/\A[0-9a-f]{64}\z/

  @type vault_id :: String.t()

  @doc """
  Creates a vault at epoch 1 with two members: the first device (`signer`,
  `slot_id`, `envelope`) and the recovery key (`recovery_signer`,
  `recovery_slot_id`, `recovery_envelope`). The recovery signer can
  authenticate but never writes a slot. `lookup_hash` is the lowercase hex
  SHA-256 of the lookup handle.
  """
  @spec create_vault(map()) :: {:ok, vault_id()} | {:error, :lookup_taken | :invalid}
  def create_vault(attrs) when is_map(attrs) do
    with {:ok, a} <- validate_create(attrs) do
      vault_id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
      now = DateTime.utc_now()

      Repo.transaction(fn ->
        vault =
          %Vault{
            id: vault_id,
            epoch: 1,
            lookup_hash: a.lookup_hash,
            recovery_signer: b64(a.recovery_signer),
            recovery_envelope: b64(a.recovery_envelope),
            last_write_at: now
          }
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.unique_constraint(:lookup_hash)

        case Repo.insert(vault) do
          {:ok, _} -> :ok
          {:error, _} -> Repo.rollback(:lookup_taken)
        end

        Repo.insert!(%Member{
          vault_id: vault_id,
          signer: b64(a.signer),
          slot_id: a.slot_id,
          envelope: b64(a.envelope)
        })

        Repo.insert!(%Member{
          vault_id: vault_id,
          signer: b64(a.recovery_signer),
          slot_id: a.recovery_slot_id,
          envelope: b64(a.recovery_envelope)
        })

        vault_id
      end)
    end
  end

  def create_vault(_), do: {:error, :invalid}

  @doc "Finds a vault id from the raw lookup handle."
  @spec lookup(binary()) :: {:ok, vault_id()} | {:error, :not_found}
  def lookup(handle) when is_binary(handle) do
    hash = Base.encode16(:crypto.hash(:sha256, handle), case: :lower)

    case Repo.one(from(v in Vault, where: v.lookup_hash == ^hash, select: v.id)) do
      nil -> {:error, :not_found}
      id -> {:ok, id}
    end
  end

  def lookup(_), do: {:error, :not_found}

  @doc "Whether `signer` (32 raw bytes) is a current member of the vault."
  @spec member?(String.t(), binary()) :: boolean()
  def member?(vault_id, signer) do
    valid_vault_id?(vault_id) and valid_signer?(signer) and
      Repo.exists?(from(m in Member, where: m.vault_id == ^vault_id and m.signer == ^b64(signer)))
  end

  @doc """
  The vault manifest for a member, plus an ETag that changes with every write.

  Shape (all keys and envelopes are raw binaries):

      %{epoch: integer,
        members: [%{signer: binary, slot_id: String.t()}],
        envelope: binary,           # the requester's own
        recovery_signer: binary,
        slots: [%{slot_id, seq, epoch, size, updated_at: DateTime.t()}]}

  `members` includes the recovery signer; `recovery_signer` identifies it.
  """
  @spec manifest(String.t(), binary()) ::
          {:ok, map(), String.t()} | {:error, :not_found}
  def manifest(vault_id, signer) do
    with true <- valid_vault_id?(vault_id) and valid_signer?(signer),
         %Member{} = me <- get_member(vault_id, signer),
         %Vault{} = vault <- Repo.get(Vault, vault_id) do
      members = Repo.all(from(m in Member, where: m.vault_id == ^vault_id, order_by: m.slot_id))
      slots = Repo.all(from(s in Slot, where: s.vault_id == ^vault_id, order_by: s.slot_id))

      manifest = %{
        epoch: vault.epoch,
        members: Enum.map(members, &%{signer: unb64(&1.signer), slot_id: &1.slot_id}),
        envelope: unb64(me.envelope),
        recovery_signer: unb64(vault.recovery_signer),
        slots:
          Enum.map(
            slots,
            &%{
              slot_id: &1.slot_id,
              seq: &1.seq,
              epoch: &1.epoch,
              size: &1.size,
              updated_at: &1.updated_at
            }
          )
      }

      {:ok, manifest, etag(vault, members, slots)}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Writes a slot's ciphertext. `if_match` is the current seq (nil for the
  first write) and `epoch` must equal the vault epoch. Returns the new seq.

  The row update is a conditional `update_all` (or an insert that does
  nothing on conflict) inside a transaction, and the file is written inside
  that same transaction after the row step succeeds. A concurrent writer
  with the same `if_match` therefore blocks on the row lock and then fails
  its condition without touching the file, and a reader (who only sees
  committed rows) never finds a row pointing at a missing file. If the file
  write fails the transaction rolls back (`{:error, :storage}`). The
  previous seq's file is deleted after commit.
  """
  @spec put_slot(String.t(), binary(), String.t(), binary(), integer() | nil, integer()) ::
          {:ok, pos_integer()}
          | {:error,
             :not_owner
             | :precondition_failed
             | :too_large
             | :stale_epoch
             | :rate_limited
             | :storage}
  def put_slot(vault_id, signer, slot_id, body, if_match, epoch) do
    cond do
      byte_size(body) > @max_slot_bytes ->
        {:error, :too_large}

      not (valid_vault_id?(vault_id) and valid_signer?(signer) and valid_slot_id?(slot_id)) ->
        {:error, :not_owner}

      not (is_nil(if_match) or is_integer(if_match)) ->
        {:error, :precondition_failed}

      true ->
        do_put_slot(vault_id, signer, slot_id, body, if_match, epoch)
    end
  end

  defp do_put_slot(vault_id, signer, slot_id, body, if_match, epoch) do
    result =
      Repo.transaction(fn ->
        check_owner!(vault_id, signer, slot_id)
        check_epoch!(vault_id, epoch)

        case RateLimiter.check_rate_limit("backup:vault:#{vault_id}",
               limit: @write_limit,
               window_ms: @write_window_ms
             ) do
          {:ok, _} -> :ok
          {:error, :rate_limited} -> Repo.rollback(:rate_limited)
        end

        new_seq = (if_match || 0) + 1
        path = Store.slot_path(vault_id, slot_id, new_seq)
        now = DateTime.utc_now()

        if cas_slot(vault_id, slot_id, if_match, new_seq, epoch, byte_size(body), path, now) != 1,
          do: Repo.rollback(:precondition_failed)

        case Store.write(path, body) do
          :ok -> :ok
          {:error, _} -> Repo.rollback(:storage)
        end

        Repo.update_all(from(v in Vault, where: v.id == ^vault_id), set: [last_write_at: now])
        new_seq
      end)

    with {:ok, new_seq} <- result do
      if if_match, do: Store.delete(Store.slot_path(vault_id, slot_id, if_match))
      {:ok, new_seq}
    end
  end

  defp check_owner!(vault_id, signer, slot_id) do
    case get_member(vault_id, signer) do
      %Member{slot_id: ^slot_id} -> :ok
      _ -> Repo.rollback(:not_owner)
    end
  end

  defp check_epoch!(vault_id, epoch) do
    case Repo.one(from(v in Vault, where: v.id == ^vault_id, select: v.epoch)) do
      ^epoch -> :ok
      _ -> Repo.rollback(:stale_epoch)
    end
  end

  defp cas_slot(vault_id, slot_id, nil, new_seq, epoch, size, path, now) do
    {count, _} =
      Repo.insert_all(
        Slot,
        [
          %{
            vault_id: vault_id,
            slot_id: slot_id,
            seq: new_seq,
            epoch: epoch,
            size: size,
            path: path,
            updated_at: now
          }
        ],
        on_conflict: :nothing
      )

    count
  end

  defp cas_slot(vault_id, slot_id, if_match, new_seq, epoch, size, path, now) do
    {count, _} =
      from(s in Slot,
        where: s.vault_id == ^vault_id and s.slot_id == ^slot_id and s.seq == ^if_match
      )
      |> Repo.update_all(
        set: [seq: new_seq, epoch: epoch, size: size, path: path, updated_at: now]
      )

    count
  end

  @doc "Reads a slot's current ciphertext and seq."
  @spec get_slot(String.t(), String.t()) :: {:ok, binary(), pos_integer()} | {:error, :not_found}
  def get_slot(vault_id, slot_id) do
    with true <- valid_vault_id?(vault_id) and valid_slot_id?(slot_id),
         %Slot{path: path, seq: seq} <-
           Repo.get_by(Slot, vault_id: vault_id, slot_id: slot_id),
         {:ok, body} <- Store.read(path) do
      {:ok, body, seq}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Deletes the vault row (members and slots cascade) and its files."
  @spec delete_vault(String.t()) :: :ok
  def delete_vault(vault_id) do
    if valid_vault_id?(vault_id) do
      Repo.delete_all(from(v in Vault, where: v.id == ^vault_id))
      Store.delete_vault_dir(vault_id)
    end

    :ok
  end

  defp validate_create(attrs) do
    a = Map.take(attrs, ~w(signer slot_id envelope recovery_signer recovery_slot_id
                           recovery_envelope lookup_hash)a)

    if map_size(a) == 7 and valid_signer?(a.signer) and valid_signer?(a.recovery_signer) and
         a.signer != a.recovery_signer and valid_slot_id?(a.slot_id) and
         valid_slot_id?(a.recovery_slot_id) and a.slot_id != a.recovery_slot_id and
         is_binary(a.envelope) and a.envelope != "" and is_binary(a.recovery_envelope) and
         a.recovery_envelope != "" and is_binary(a.lookup_hash) and
         Regex.match?(@lookup_hash, a.lookup_hash) do
      {:ok, a}
    else
      {:error, :invalid}
    end
  end

  defp get_member(vault_id, signer),
    do: Repo.get_by(Member, vault_id: vault_id, signer: b64(signer))

  defp etag(vault, members, slots) do
    seqs = slots |> Enum.map(& &1.seq) |> Enum.sum()

    newest =
      slots
      |> Enum.map(&DateTime.to_unix(&1.updated_at, :microsecond))
      |> Enum.max(fn -> 0 end)

    "\"#{vault.epoch}-#{seqs}-#{length(members)}-#{newest}\""
  end

  defp valid_vault_id?(id), do: is_binary(id) and Regex.match?(@vault_id, id)
  defp valid_slot_id?(id), do: is_binary(id) and Regex.match?(@slot_id, id)
  defp valid_signer?(s), do: is_binary(s) and byte_size(s) == 32

  defp b64(bin), do: Base.url_encode64(bin, padding: false)
  defp unb64(text), do: Base.url_decode64!(text, padding: false)
end
