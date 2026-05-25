import { useRef, useState, useCallback } from "react";
import { useQuery, useMutation } from "urql";
import {
  ImportListsDocument,
  CreateImportListDocument,
  DeleteImportListDocument,
  ToggleImportListDocument,
} from "../../graphql/generated/graphql";
import { PageHeader } from "../../components/page-header";
import { Card } from "../../components/card";
import { Table } from "../../components/table";
import { Modal, type ModalHandle } from "../../components/modal";
import { Button } from "../../components/button";
import { Input } from "../../components/input";
import { StatusPill } from "../../components/status-pill";
import { Alert } from "../../components/feedback";

export function ImportListsPage() {
  const [result, refetch] = useQuery({ query: ImportListsDocument });
  const [, createMutation] = useMutation(CreateImportListDocument);
  const [, deleteMutation] = useMutation(DeleteImportListDocument);
  const [, toggleMutation] = useMutation(ToggleImportListDocument);

  const modalRef = useRef<ModalHandle>(null);
  const [formError, setFormError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const [name, setName] = useState("");
  const [type_, setType] = useState("tmdb");
  const [mediaType, setMediaType] = useState("movies");
  const [enabled, setEnabled] = useState(true);

  const data = result.data?.importLists ?? [];
  const error = result.error;

  const handleCreate = useCallback(async () => {
    setFormError(null);
    setSaving(true);
    const res = await createMutation({ input: { name, type: type_, mediaType, enabled } });
    setSaving(false);
    if (res.error) {
      setFormError(res.error.message);
    } else {
      modalRef.current?.close();
      setName("");
      setType("tmdb");
      setMediaType("movies");
      setEnabled(true);
      refetch();
    }
  }, [name, type_, mediaType, enabled, createMutation, refetch]);

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
        title="Import Lists"
        subtitle="Manage external media lists for syncing"
        actions={
          <Button onClick={() => modalRef.current?.show()}>Add List</Button>
        }
      />

      {error && (
        <Alert kind="error" title="Failed to load import lists">
          {error.message}
        </Alert>
      )}

      <Card>
        <Table
          columns={[
            { key: "name", header: "Name", render: (row) => <span className="font-medium">{row.name}</span> },
            { key: "type", header: "Type", render: (row) => <StatusPill status={row.type} /> },
            { key: "mediaType", header: "Media Type", render: (row) => <StatusPill status={row.mediaType} /> },
            {
              key: "enabled",
              header: "Enabled",
              render: (row) => (
                <input type="checkbox" className="toggle toggle-sm toggle-primary" checked={row.enabled}
                  onChange={(e) => handleToggle(row.id, e.target.checked)} />
              ),
            },
            {
              key: "syncInterval",
              header: "Sync Interval",
              render: (row) => <span>{row.syncInterval} min</span>,
            },
            {
              key: "autoAdd",
              header: "Auto Add",
              render: (row) =>
                row.autoAdd ? <StatusPill status="active" label="Yes" /> : <StatusPill status="inactive" label="No" />,
            },
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
          emptyMessage="No import lists configured."
        />
      </Card>

      <Modal ref={modalRef} title="Add Import List" onClose={() => setFormError(null)}>
        <div className="flex flex-col gap-3">
          {formError && <Alert kind="error">{formError}</Alert>}
          <Input label="Name" placeholder="My List" value={name} onChange={(e) => setName(e.target.value)} />
          <div className="form-control w-full">
            <label className="label py-1"><span className="label-text">Type</span></label>
            <select className="select select-bordered w-full" value={type_} onChange={(e) => setType(e.target.value)}>
              <option value="tmdb">TMDB</option>
              <option value="trakt">Trakt</option>
              <option value="imdb">IMDB</option>
              <option value="custom">Custom</option>
            </select>
          </div>
          <div className="form-control w-full">
            <label className="label py-1"><span className="label-text">Media Type</span></label>
            <select className="select select-bordered w-full" value={mediaType} onChange={(e) => setMediaType(e.target.value)}>
              <option value="movies">Movies</option>
              <option value="series">Series</option>
            </select>
          </div>
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
