import { useRef, useState, useCallback } from "react";
import { useQuery, useMutation } from "urql";
import {
  UsersDocument,
  CreateUserDocument,
  UpdateUserRoleDocument,
  DeleteUserDocument,
} from "../../graphql/generated/graphql";
import { PageHeader } from "../../components/page-header";
import { Card } from "../../components/card";
import { Modal, type ModalHandle } from "../../components/modal";
import { Button } from "../../components/button";
import { Input } from "../../components/input";
import { Alert } from "../../components/feedback";
import { useViewer } from "../../lib/auth";

const VALID_ROLES = ["admin", "user", "readonly", "guest"] as const;

export function UsersPage() {
  const { viewer } = useViewer();
  const [result, refetch] = useQuery({ query: UsersDocument });
  const [, createMutation] = useMutation(CreateUserDocument);
  const [, updateRoleMutation] = useMutation(UpdateUserRoleDocument);
  const [, deleteMutation] = useMutation(DeleteUserDocument);

  const createModalRef = useRef<ModalHandle>(null);
  const [formError, setFormError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const [username, setUsername] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [role, setRole] = useState("guest");

  const [deleteTarget, setDeleteTarget] = useState<{
    id: string;
    name: string;
  } | null>(null);
  const [deleteError, setDeleteError] = useState<string | null>(null);

  const [roleTarget, setRoleTarget] = useState<{
    id: string;
    name: string;
    currentRole: string;
  } | null>(null);
  const [newRole, setNewRole] = useState("");
  const [roleError, setRoleError] = useState<string | null>(null);

  const data = result.data?.users ?? [];
  const error = result.error;

  const viewerId = viewer?.id;

  const handleCreate = useCallback(async () => {
    setFormError(null);
    setSaving(true);
    const res = await createMutation({
      input: { username, email, password, role: role || null },
    });
    setSaving(false);
    if (res.error) {
      setFormError(res.error.message);
    } else {
      createModalRef.current?.close();
      setUsername("");
      setEmail("");
      setPassword("");
      setRole("guest");
      refetch();
    }
  }, [username, email, password, role, createMutation, refetch]);

  const handleDelete = useCallback(
    async (id: string) => {
      setDeleteError(null);
      const res = await deleteMutation({ id });
      if (res.error) {
        setDeleteError(res.error.message);
      } else {
        setDeleteTarget(null);
        refetch();
      }
    },
    [deleteMutation, refetch],
  );

  const handleRoleChange = useCallback(
    async (id: string) => {
      setRoleError(null);
      const res = await updateRoleMutation({
        input: { id, role: newRole },
      });
      if (res.error) {
        setRoleError(res.error.message);
      } else {
        setRoleTarget(null);
        refetch();
      }
    },
    [newRole, updateRoleMutation, refetch],
  );

  if (result.fetching && data.length === 0) {
    return (
      <div className="flex justify-center py-16">
        <span className="loading loading-spinner loading-lg" />
      </div>
    );
  }

  return (
    <div>
      <PageHeader
        title="Users"
        subtitle="Local accounts and OIDC-linked identities on this instance."
        actions={
          <>
            <Button
              size="sm"
              variant="ghost"
              onClick={() => refetch()}
            >
              Refresh
            </Button>
            <Button
              size="sm"
              variant="primary"
              onClick={() => createModalRef.current?.show()}
            >
              Add user
            </Button>
          </>
        }
      />

      {error && (
        <Alert kind="error" title="Failed to load users">
          {error.message}
        </Alert>
      )}

      <Card>
        <div className="overflow-x-auto">
          <table className="table">
            <thead>
              <tr>
                <th>User</th>
                <th>Role</th>
                <th>Last login</th>
                <th className="text-right">Actions</th>
              </tr>
            </thead>
            <tbody>
              {data.map((row) => {
                const displayName = row.username ?? row.email ?? row.id;
                const lastLogin = row.lastLoginAt ?? "Never";
                const isSelf = row.id === viewerId;

                return (
                  <tr key={row.id}>
                    <td>
                      <div className="font-medium">{displayName}</div>
                      {row.email && (
                        <div className="text-xs text-base-content/60">
                          {row.email}
                        </div>
                      )}
                      {row.isOidc && (
                        <span className="badge badge-ghost badge-xs mt-1">
                          OIDC
                        </span>
                      )}
                    </td>
                    <td className="capitalize">{row.role}</td>
                    <td className="text-sm">{lastLogin}</td>
                    <td className="text-right whitespace-nowrap">
                      <Button
                        size="sm"
                        variant="outline"
                        onClick={() => {
                          setRoleTarget({
                            id: row.id,
                            name: displayName,
                            currentRole: row.role,
                          });
                          setNewRole(row.role);
                          setRoleError(null);
                        }}
                      >
                        Change role
                      </Button>
                      <span className="mx-1" />
                      <Button
                        size="sm"
                        variant="error"
                        disabled={isSelf}
                        onClick={() => {
                          setDeleteTarget({ id: row.id, name: displayName });
                          setDeleteError(null);
                        }}
                      >
                        Delete
                      </Button>
                    </td>
                  </tr>
                );
              })}
              {data.length === 0 && (
                <tr>
                  <td colSpan={4} className="text-center py-8 text-base-content/60">
                    No users found.
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        </div>
      </Card>

      <Modal ref={createModalRef} title="Add user" onClose={() => setFormError(null)}>
        <div className="flex flex-col gap-3">
          {formError && <Alert kind="error">{formError}</Alert>}
          <Input
            label="Username"
            placeholder="jdoe"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
          />
          <Input
            label="Email"
            type="email"
            placeholder="jdoe@example.com"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
          />
          <Input
            label="Initial password (>= 8 chars)"
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
          <div className="form-control w-full">
            <label className="label py-1">
              <span className="label-text">Role</span>
            </label>
            <select
              className="select select-bordered w-full"
              value={role}
              onChange={(e) => setRole(e.target.value)}
            >
              {VALID_ROLES.map((r) => (
                <option key={r} value={r}>
                  {r.charAt(0).toUpperCase() + r.slice(1)}
                </option>
              ))}
            </select>
          </div>
          <div className="flex justify-end gap-2 mt-2">
            <Button
              variant="ghost"
              onClick={() => createModalRef.current?.close()}
            >
              Cancel
            </Button>
            <Button loading={saving} onClick={handleCreate}>
              Create
            </Button>
          </div>
        </div>
      </Modal>

      {deleteTarget && (
        <Modal
          id="delete-user-modal"
          title="Delete user"
          onClose={() => setDeleteTarget(null)}
        >
          <div className="flex flex-col gap-3">
            {deleteError && <Alert kind="error">{deleteError}</Alert>}
            <p className="text-sm">
              Permanently delete{" "}
              <strong>{deleteTarget.name}</strong>
              ? Their requests stay on the books but the account cannot be
              restored.
            </p>
            <div className="flex justify-end gap-2">
              <Button variant="ghost" onClick={() => setDeleteTarget(null)}>
                Cancel
              </Button>
              <Button
                variant="error"
                onClick={() => handleDelete(deleteTarget.id)}
              >
                Delete
              </Button>
            </div>
          </div>
        </Modal>
      )}

      {roleTarget && (
        <Modal
          id="change-role-modal"
          title="Change role"
          onClose={() => setRoleTarget(null)}
        >
          <div className="flex flex-col gap-3">
            {roleError && <Alert kind="error">{roleError}</Alert>}
            <p className="text-sm mb-2">
              Update the role for <strong>{roleTarget.name}</strong>.
            </p>
            <div className="form-control w-full">
              <label className="label py-1">
                <span className="label-text">Role</span>
              </label>
              <select
                className="select select-bordered w-full"
                value={newRole}
                onChange={(e) => setNewRole(e.target.value)}
              >
                {VALID_ROLES.map((r) => (
                  <option key={r} value={r}>
                    {r}
                  </option>
                ))}
              </select>
            </div>
            <div className="flex justify-end gap-2">
              <Button variant="ghost" onClick={() => setRoleTarget(null)}>
                Cancel
              </Button>
              <Button
                variant="primary"
                onClick={() => handleRoleChange(roleTarget.id)}
              >
                Save
              </Button>
            </div>
          </div>
        </Modal>
      )}
    </div>
  );
}
