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
  @read_attempts 3
  @max_members 16

  @vault_id ~r/\A[0-9a-f]{32}\z/
  @slot_id ~r/\A[0-9a-f]{16}\z/
  @lookup_hash ~r/\A[0-9a-f]{64}\z/

  @type vault_id :: String.t()

  @doc """
  Creates a vault at epoch 1 with two members: the first device (`signer`,
  `slot_id`, `envelope`, `box_pub`) and the recovery key (`recovery_signer`,
  `recovery_slot_id`, `recovery_envelope`, `recovery_box_pub`). Box keys are
  32-byte X25519 public keys. The recovery signer can
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
          {:error, %Ecto.Changeset{errors: [lookup_hash: _]}} -> Repo.rollback(:lookup_taken)
          {:error, _} -> Repo.rollback(:invalid)
        end

        Repo.insert!(%Member{
          vault_id: vault_id,
          signer: b64(a.signer),
          slot_id: a.slot_id,
          envelope: b64(a.envelope),
          box_pub: b64(a.box_pub)
        })

        Repo.insert!(%Member{
          vault_id: vault_id,
          signer: b64(a.recovery_signer),
          slot_id: a.recovery_slot_id,
          envelope: b64(a.recovery_envelope),
          box_pub: b64(a.recovery_box_pub)
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
        members: [%{signer: binary, box_pub: binary, slot_id: String.t(), recovery?: boolean}],
        envelope: binary,           # the requester's own
        recovery_signer: binary,
        slots: [%{slot_id, seq, epoch, size, updated_at: DateTime.t()}]}

  `members` includes the recovery signer (`recovery?: true`) and every member's
  X25519 `box_pub`, which devices seal a rotated vault key to.
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
        members:
          Enum.map(
            members,
            &%{
              signer: unb64(&1.signer),
              box_pub: unb64(&1.box_pub),
              slot_id: &1.slot_id,
              recovery?: &1.signer == vault.recovery_signer
            }
          ),
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

  Everything runs in one `:immediate` SQLite transaction, which takes the
  database write lock up front. Two overlapping writers therefore queue
  (SQLite has no row locks, and a deferred transaction that reads before
  writing would raise SQLITE_BUSY instead). Inside it the slot row changes by
  a conditional `update_all` (or an insert that does nothing on conflict), and
  only when that matches does the file get written. A loser of a race on the
  same `if_match` fails its condition without touching the file. Readers see
  only committed rows, and the file is written before commit, so a row never
  points at a missing file. A file write failure rolls back
  (`{:error, :storage}`); a failure after the write but before commit can
  leave an orphan file at the new seq, which the next write at that seq
  overwrites. The previous seq's file is deleted after commit.

  The rate limit is charged before the conditional update, so a write that
  then fails with `:precondition_failed` still counts. The recovery signer
  never owns a slot and always gets `:not_owner`.
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
      Repo.transaction(
        fn ->
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

          if cas_slot(vault_id, slot_id, if_match, new_seq, epoch, byte_size(body), path, now) !=
               1,
             do: Repo.rollback(:precondition_failed)

          case Store.write(path, body) do
            :ok -> :ok
            {:error, _} -> Repo.rollback(:storage)
          end

          Repo.update_all(from(v in Vault, where: v.id == ^vault_id), set: [last_write_at: now])
          new_seq
        end,
        mode: :immediate
      )

    with {:ok, new_seq} <- result do
      if if_match, do: Store.delete(Store.slot_path(vault_id, slot_id, if_match))
      {:ok, new_seq}
    end
  end

  defp check_owner!(vault_id, signer, slot_id) do
    recovery = Repo.one(from(v in Vault, where: v.id == ^vault_id, select: v.recovery_signer))

    case get_member(vault_id, signer) do
      %Member{slot_id: ^slot_id, signer: member_signer} when member_signer != recovery -> :ok
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

  @doc """
  Reads a slot's current ciphertext and seq.

  A write committing between the row read and the file read deletes the old
  file, so on a missing file the row is re-read and the read retried (up to
  #{@read_attempts} attempts) when its seq moved. `:not_found` is returned
  only when the row is gone or its seq is unchanged.

  `opts[:after_row]` is a test hook called after the first row read.
  """
  @spec get_slot(String.t(), String.t(), keyword()) ::
          {:ok, binary(), pos_integer()} | {:error, :not_found}
  def get_slot(vault_id, slot_id, opts \\ []) do
    if valid_vault_id?(vault_id) and valid_slot_id?(slot_id),
      do: read_slot(vault_id, slot_id, @read_attempts, opts),
      else: {:error, :not_found}
  end

  defp read_slot(vault_id, slot_id, attempts, opts) do
    case Repo.get_by(Slot, vault_id: vault_id, slot_id: slot_id) do
      nil ->
        {:error, :not_found}

      %Slot{path: path, seq: seq} ->
        if hook = opts[:after_row], do: hook.()

        case Store.read(path) do
          {:ok, body} ->
            {:ok, body, seq}

          {:error, :enoent} ->
            current =
              Repo.one(
                from(s in Slot,
                  where: s.vault_id == ^vault_id and s.slot_id == ^slot_id,
                  select: s.seq
                )
              )

            if attempts > 1 and current not in [nil, seq],
              do: read_slot(vault_id, slot_id, attempts - 1, Keyword.delete(opts, :after_row)),
              else: {:error, :not_found}
        end
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

  @doc """
  Adds members, removes members, replaces the recovery key, or rotates the
  vault key, in one call compare-and-swapped on the vault epoch.

  `change` keys (all binaries raw, as elsewhere in this module):

    * `:expected_epoch` - must equal the vault epoch, else `:conflict`.
    * `:new_epoch` - `expected_epoch` (no rotation) or `expected_epoch + 1`
      (rotation).
    * `:add` - `[%{signer, slot_id, box_pub}]`, new members.
    * `:remove` - `[signer]`. Their slot row and file are deleted. Removing a
      member, or replacing the recovery key, requires a rotation, otherwise
      the removed party would keep the current key (`:invalid`). The recovery
      signer can only leave through `:recovery`. A member may remove itself.
    * `:envelopes` - `%{signer => envelope}`. Without rotation it must hold
      exactly the added signers. On rotation it must cover every remaining
      member and the recovery member (a replaced recovery's envelope is
      `recovery.envelope`, so listing it here too is optional).
    * `:recovery` - `nil` or `%{signer, slot_id, envelope, lookup_hash, box_pub}`
      with a new signer (the current one is `:invalid`), replacing the recovery member, its envelope and the lookup hash at once.

  `signer` must be a current member (the recovery signer qualifies, which is
  how a restoring device adds itself), else `{:error, :not_member}`. The
  recovery member counts toward the 16 member limit. Returns the vault epoch
  after the change. Files of removed members are deleted after commit.
  """
  @spec update_members(String.t(), binary(), map()) ::
          {:ok, pos_integer()}
          | {:error, :conflict | :too_many_members | :invalid | :not_member}
  def update_members(vault_id, signer, change) when is_map(change) do
    if valid_vault_id?(vault_id) and valid_signer?(signer) do
      result =
        Repo.transaction(fn -> apply_member_change(vault_id, signer, change) end,
          mode: :immediate
        )

      with {:ok, {epoch, paths}} <- result do
        Enum.each(paths, &Store.delete/1)
        {:ok, epoch}
      end
    else
      {:error, :not_member}
    end
  end

  def update_members(_, _, _), do: {:error, :invalid}

  defp apply_member_change(vault_id, signer, change) do
    vault = Repo.get(Vault, vault_id) || Repo.rollback(:not_member)
    get_member(vault_id, signer) || Repo.rollback(:not_member)

    c = parse_change(change)
    if c.expected_epoch != vault.epoch, do: Repo.rollback(:conflict)

    members = Repo.all(from(m in Member, where: m.vault_id == ^vault_id))
    plan = plan_members(vault, members, c)

    if length(plan.final) > @max_members, do: Repo.rollback(:too_many_members)

    case from(v in Vault, where: v.id == ^vault_id and v.epoch == ^c.expected_epoch)
         |> Repo.update_all(set: [epoch: c.new_epoch]) do
      {1, _} -> :ok
      {0, _} -> Repo.rollback(:conflict)
    end

    paths = delete_members(vault_id, plan.removed)

    Enum.each(plan.added, fn m ->
      Repo.insert!(%Member{
        vault_id: vault_id,
        signer: m.signer,
        slot_id: m.slot_id,
        envelope: m.envelope,
        box_pub: m.box_pub
      })
    end)

    if c.rotate? do
      rotate_envelopes(vault_id, plan.envelopes)

      if is_nil(c.recovery) do
        from(v in Vault, where: v.id == ^vault_id)
        |> Repo.update_all(
          set: [recovery_envelope: Map.fetch!(plan.envelopes, vault.recovery_signer)]
        )
      end
    end

    if c.recovery, do: replace_recovery(vault_id, c.recovery)

    {c.new_epoch, paths}
  end

  # Validates the change against the current members and returns
  # %{removed: [b64 signer], added: [member map], final: [b64 signer],
  #   envelopes: %{b64 signer => b64 envelope}}.
  defp plan_members(vault, members, c) do
    rotate? = c.rotate?
    current = MapSet.new(members, & &1.signer)
    old_recovery = vault.recovery_signer
    new_recovery = if c.recovery, do: c.recovery.signer, else: old_recovery

    removed = Enum.uniq(c.remove)
    added = c.add
    added_signers = Enum.map(added, & &1.signer)

    replaced_recovery? = c.recovery != nil and new_recovery != old_recovery
    removed_all = if replaced_recovery?, do: [old_recovery | removed], else: removed

    survivors = MapSet.difference(current, MapSet.new(removed_all))

    incoming =
      MapSet.new(added_signers ++ if(c.recovery, do: [new_recovery], else: []))

    final = MapSet.union(survivors, incoming)

    slot_ids =
      (members
       |> Enum.reject(&(&1.signer in removed_all))
       |> Enum.map(& &1.slot_id)) ++
        Enum.map(added, & &1.slot_id) ++
        if(replaced_recovery?, do: [c.recovery.slot_id], else: [])

    cond do
      not Enum.all?(removed, &(&1 in current)) -> invalid()
      c.recovery != nil and not replaced_recovery? -> invalid()
      old_recovery in removed and not replaced_recovery? -> invalid()
      (removed != [] or c.recovery != nil) and not rotate? -> invalid()
      length(added_signers) != length(Enum.uniq(added_signers)) -> invalid()
      Enum.any?(added_signers, &(&1 in survivors or &1 == new_recovery)) -> invalid()
      replaced_recovery? and new_recovery in current -> invalid()
      length(slot_ids) != length(Enum.uniq(slot_ids)) -> invalid()
      true -> :ok
    end

    envelopes = c.envelopes

    expected_keys =
      cond do
        not rotate? -> MapSet.new(added_signers)
        c.recovery -> MapSet.delete(final, new_recovery)
        true -> final
      end

    given_keys = MapSet.new(Map.keys(envelopes))
    given_keys = if c.recovery, do: MapSet.delete(given_keys, new_recovery), else: given_keys

    if given_keys != expected_keys, do: invalid()

    envelopes =
      if c.recovery, do: Map.put(envelopes, new_recovery, c.recovery.envelope), else: envelopes

    added =
      if replaced_recovery?,
        do:
          added ++
            [%{signer: new_recovery, slot_id: c.recovery.slot_id, box_pub: c.recovery.box_pub}],
        else: added

    added =
      Enum.map(added, fn a -> Map.put(a, :envelope, Map.fetch!(envelopes, a.signer)) end)

    %{removed: removed_all, added: added, final: MapSet.to_list(final), envelopes: envelopes}
  end

  defp invalid, do: Repo.rollback(:invalid)

  defp delete_members(_vault_id, []), do: []

  defp delete_members(vault_id, removed_b64) do
    removed_members =
      Repo.all(from(m in Member, where: m.vault_id == ^vault_id and m.signer in ^removed_b64))

    slot_ids = Enum.map(removed_members, & &1.slot_id)

    paths =
      from(s in Slot, where: s.vault_id == ^vault_id and s.slot_id in ^slot_ids)
      |> Repo.all()
      |> Enum.map(&Store.slot_path(vault_id, &1.slot_id, &1.seq))

    Repo.delete_all(from(s in Slot, where: s.vault_id == ^vault_id and s.slot_id in ^slot_ids))

    Repo.delete_all(
      from(m in Member, where: m.vault_id == ^vault_id and m.signer in ^removed_b64)
    )

    paths
  end

  defp rotate_envelopes(vault_id, envelopes) do
    Enum.each(envelopes, fn {signer, envelope} ->
      from(m in Member, where: m.vault_id == ^vault_id and m.signer == ^signer)
      |> Repo.update_all(set: [envelope: envelope])
    end)
  end

  defp replace_recovery(vault_id, r) do
    changeset =
      Vault
      |> Repo.get!(vault_id)
      |> Ecto.Changeset.change(
        recovery_signer: r.signer,
        recovery_envelope: r.envelope,
        lookup_hash: r.lookup_hash
      )
      |> Ecto.Changeset.unique_constraint(:lookup_hash)

    case Repo.update(changeset) do
      {:ok, _} -> :ok
      {:error, _} -> Repo.rollback(:invalid)
    end
  end

  # Normalises the caller's change into base64url strings; anything malformed
  # rolls back as :invalid.
  defp parse_change(change) do
    expected = change[:expected_epoch]
    new = change[:new_epoch]

    unless is_integer(expected) and (new == expected or new == expected + 1), do: invalid()

    add = Enum.map(list(change[:add]), &parse_added/1)
    remove = Enum.map(list(change[:remove]), &signer_b64/1)

    envelopes =
      case change[:envelopes] do
        nil -> %{}
        m when is_map(m) -> Map.new(m, fn {s, e} -> {signer_b64(s), envelope_b64(e)} end)
        _ -> invalid()
      end

    recovery =
      case change[:recovery] do
        nil -> nil
        %{} = r -> parse_recovery(r)
        _ -> invalid()
      end

    %{
      expected_epoch: expected,
      new_epoch: new,
      rotate?: new == expected + 1,
      add: add,
      remove: remove,
      envelopes: envelopes,
      recovery: recovery
    }
  end

  defp parse_added(%{signer: s, slot_id: slot_id, box_pub: box_pub}) do
    unless valid_slot_id?(slot_id), do: invalid()
    %{signer: signer_b64(s), slot_id: slot_id, box_pub: signer_b64(box_pub)}
  end

  defp parse_added(_), do: invalid()

  defp parse_recovery(%{signer: s, slot_id: slot_id, envelope: e, lookup_hash: h, box_pub: bp}) do
    unless valid_slot_id?(slot_id) and is_binary(h) and Regex.match?(@lookup_hash, h),
      do: invalid()

    %{
      signer: signer_b64(s),
      slot_id: slot_id,
      envelope: envelope_b64(e),
      lookup_hash: h,
      box_pub: signer_b64(bp)
    }
  end

  defp parse_recovery(_), do: invalid()

  defp list(nil), do: []
  defp list(l) when is_list(l), do: l
  defp list(_), do: invalid()

  defp signer_b64(s), do: if(valid_signer?(s), do: b64(s), else: invalid())

  defp envelope_b64(e), do: if(is_binary(e) and e != "", do: b64(e), else: invalid())

  defp validate_create(attrs) do
    a = Map.take(attrs, ~w(signer slot_id envelope recovery_signer recovery_slot_id
                           recovery_envelope lookup_hash box_pub recovery_box_pub)a)

    if map_size(a) == 9 and valid_signer?(a.box_pub) and valid_signer?(a.recovery_box_pub) and
         valid_signer?(a.signer) and valid_signer?(a.recovery_signer) and
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
