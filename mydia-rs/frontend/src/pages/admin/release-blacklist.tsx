import { useRef, useState, useCallback } from "react";
import { useQuery, useMutation } from "urql";
import {
  ReleaseBlacklistDocument,
  CreateReleaseBlacklistEntryDocument,
  DeleteReleaseBlacklistEntryDocument,
} from "../../graphql/generated/graphql";
import { PageHeader } from "../../components/page-header";
import { Card } from "../../components/card";
import { Table } from "../../components/table";
import { Modal, type ModalHandle } from "../../components/modal";
import { Button } from "../../components/button";
import { Input } from "../../components/input";
import { Alert } from "../../components/feedback";

export function ReleaseBlacklistPage() {
  const [result, refetch] = useQuery({ query: ReleaseBlacklistDocument });
  const [, createMutation] = useMutation(CreateReleaseBlacklistEntryDocument);
  const [, deleteMutation] = useMutation(DeleteReleaseBlacklistEntryDocument);

  const modalRef = useRef<ModalHandle>(null);
  const [formError, setFormError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);

  const [indexer, setIndexer] = useState("");
  const [guid, setGuid] = useState("");
  const [title, setTitle] = useState("");
  const [failureReason, setFailureReason] = useState("");

  const data = result.data?.releaseBlacklist ?? [];
  const error = result.error;

  const handleCreate = useCallback(async () => {
    setFormError(null);
    setSaving(true);
    const res = await createMutation({ input: { indexer, guid, title, failureReason } });
    setSaving(false);
    if (res.error) {
      setFormError(res.error.message);
    } else {
      modalRef.current?.close();
      setIndexer("");
      setGuid("");
      setTitle("");
      setFailureReason("");
      refetch();
    }
  }, [indexer, guid, title, failureReason, createMutation, refetch]);

  const handleDelete = useCallback(
    async (id: string) => {
      await deleteMutation({ id });
      refetch();
    },
    [deleteMutation, refetch],
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
        title="Release Blacklist"
        subtitle="Block unwanted releases from being downloaded"
        actions={
          <Button onClick={() => modalRef.current?.show()}>Add Entry</Button>
        }
      />

      {error && (
        <Alert kind="error" title="Failed to load release blacklist">
          {error.message}
        </Alert>
      )}

      <Card>
        <Table
          columns={[
            { key: "title", header: "Title", render: (row) => <span className="font-medium">{row.title}</span> },
            { key: "indexer", header: "Indexer", render: (row) => <span className="text-sm">{row.indexer}</span> },
            { key: "guid", header: "GUID", render: (row) => <span className="font-mono text-xs">{row.guid}</span> },
            { key: "failureReason", header: "Reason", render: (row) => <span className="text-sm text-base-content/70">{row.failureReason}</span> },
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
          emptyMessage="No blacklist entries."
        />
      </Card>

      <Modal ref={modalRef} title="Add Blacklist Entry" onClose={() => setFormError(null)}>
        <div className="flex flex-col gap-3">
          {formError && <Alert kind="error">{formError}</Alert>}
          <Input label="Indexer" placeholder="my-indexer" value={indexer} onChange={(e) => setIndexer(e.target.value)} />
          <Input label="GUID" placeholder="release-guid" value={guid} onChange={(e) => setGuid(e.target.value)} />
          <Input label="Title" placeholder="Bad.Release.2024.1080p" value={title} onChange={(e) => setTitle(e.target.value)} />
          <Input label="Failure Reason" placeholder="Bad quality" value={failureReason} onChange={(e) => setFailureReason(e.target.value)} />
          <div className="flex justify-end gap-2 mt-2">
            <Button variant="ghost" onClick={() => modalRef.current?.close()}>Cancel</Button>
            <Button loading={saving} onClick={handleCreate}>Save</Button>
          </div>
        </div>
      </Modal>
    </div>
  );
}
