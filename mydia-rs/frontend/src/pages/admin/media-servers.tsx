import { useRef, useState, useCallback } from "react";
import { useQuery, useMutation } from "urql";
import {
  MediaServersDocument,
  CreateMediaServerDocument,
  DeleteMediaServerDocument,
  ToggleMediaServerDocument,
} from "../../graphql/generated/graphql";
import { PageHeader } from "../../components/page-header";
import { Card } from "../../components/card";
import { Table } from "../../components/table";
import { Modal, type ModalHandle } from "../../components/modal";
import { Button } from "../../components/button";
import { Input } from "../../components/input";
import { StatusPill } from "../../components/status-pill";
import { Alert } from "../../components/feedback";

export function MediaServersPage() {
  const [result, refetch] = useQuery({ query: MediaServersDocument });
  const [, createMutation] = useMutation(CreateMediaServerDocument);
  const [, deleteMutation] = useMutation(DeleteMediaServerDocument);
  const [, toggleMutation] = useMutation(ToggleMediaServerDocument);

  const modalRef = useRef<ModalHandle>(null);
  const [formError, setFormError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const [name, setName] = useState("");
  const [type_, setType] = useState("plex");
  const [url, setUrlVal] = useState("");
  const [token, setTokenVal] = useState("");
  const [enabled, setEnabled] = useState(true);

  const data = result.data?.mediaServers ?? [];
  const error = result.error;

  const handleCreate = useCallback(async () => {
    setFormError(null);
    setSaving(true);
    const res = await createMutation({ input: { name, type: type_, url, enabled, token: token || null } });
    setSaving(false);
    if (res.error) {
      setFormError(res.error.message);
    } else {
      modalRef.current?.close();
      setName("");
      setType("plex");
      setUrlVal("");
      setTokenVal("");
      setEnabled(true);
      refetch();
    }
  }, [name, type_, url, token, enabled, createMutation, refetch]);

  const handleDelete = useCallback(
    async (id: string) => {
      await deleteMutation({ id });
      refetch();
    },
    [deleteMutation, refetch],
  );

  const handleToggle = useCallback(
    async (id: string, val: boolean) => {
      await toggleMutation({ id, enabled: val });
      refetch();
    },
    [toggleMutation, refetch],
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
        title="Media Servers"
        subtitle="Manage Plex, Jellyfin, and Emby connections"
        actions={
          <Button onClick={() => modalRef.current?.show()}>Add Server</Button>
        }
      />

      {error && (
        <Alert kind="error" title="Failed to load media servers">
          {error.message}
        </Alert>
      )}

      <Card>
        <Table
          columns={[
            { key: "name", header: "Name", render: (row) => <span className="font-medium">{row.name}</span> },
            { key: "type", header: "Type", render: (row) => <StatusPill status={row.type} /> },
            {
              key: "enabled",
              header: "Enabled",
              render: (row) => (
                <input type="checkbox" className="toggle toggle-sm toggle-primary" checked={row.enabled}
                  onChange={(e) => handleToggle(row.id, e.target.checked)} />
              ),
            },
            { key: "url", header: "URL", render: (row) => <span className="font-mono text-xs">{row.url}</span> },
            {
              key: "actions",
              header: "",
              render: (row) => (
                <Button size="sm" variant="error" onClick={() => handleDelete(row.id)}>Delete</Button>
              ),
            },
          ]}
          rows={data}
          keyExtractor={(row) => row.id}
          emptyMessage="No media servers configured."
        />
      </Card>

      <Modal ref={modalRef} title="Add Media Server" onClose={() => setFormError(null)}>
        <div className="flex flex-col gap-3">
          {formError && <Alert kind="error">{formError}</Alert>}
          <Input label="Name" placeholder="My Server" value={name} onChange={(e) => setName(e.target.value)} />
          <div className="form-control w-full">
            <label className="label py-1"><span className="label-text">Type</span></label>
            <select className="select select-bordered w-full" value={type_} onChange={(e) => setType(e.target.value)}>
              <option value="plex">Plex</option>
              <option value="jellyfin">Jellyfin</option>
              <option value="emby">Emby</option>
            </select>
          </div>
          <Input label="URL" placeholder="http://localhost:32400" value={url} onChange={(e) => setUrlVal(e.target.value)} />
          <Input label="API Token" value={token} onChange={(e) => setTokenVal(e.target.value)} />
          <label className="flex items-center gap-2 cursor-pointer">
            <input type="checkbox" className="toggle toggle-primary" checked={enabled} onChange={(e) => setEnabled(e.target.checked)} />
            <span className="label-text">Enabled</span>
          </label>
          <div className="flex justify-end gap-2 mt-2">
            <Button variant="ghost" onClick={() => modalRef.current?.close()}>Cancel</Button>
            <Button loading={saving} onClick={handleCreate}>Save</Button>
          </div>
        </div>
      </Modal>
    </div>
  );
}
