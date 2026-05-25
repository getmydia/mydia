import { useRef, useState, useCallback } from "react";
import { useQuery, useMutation } from "urql";
import {
  DownloadClientsDocument,
  CreateDownloadClientDocument,
  DeleteDownloadClientDocument,
  ToggleDownloadClientDocument,
  TestDownloadClientDocument,
} from "../../graphql/generated/graphql";
import { PageHeader } from "../../components/page-header";
import { Card } from "../../components/card";
import { Table } from "../../components/table";
import { Modal, type ModalHandle } from "../../components/modal";
import { Button } from "../../components/button";
import { Input } from "../../components/input";
import { StatusPill } from "../../components/status-pill";
import { Alert } from "../../components/feedback";

export function DownloadClientsPage() {
  const [result, refetch] = useQuery({ query: DownloadClientsDocument });
  const [, createMutation] = useMutation(CreateDownloadClientDocument);
  const [, deleteMutation] = useMutation(DeleteDownloadClientDocument);
  const [, toggleMutation] = useMutation(ToggleDownloadClientDocument);
  const [, testMutation] = useMutation(TestDownloadClientDocument);

  const modalRef = useRef<ModalHandle>(null);
  const [formError, setFormError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [testResult, setTestResult] = useState<Record<string, string | null>>({});

  const [name, setName] = useState("");
  const [type_, setType] = useState("qbittorrent");
  const [enabled, setEnabled] = useState(true);
  const [host, setHost] = useState("");
  const [port, setPort] = useState("");
  const [username, setUsername] = useState("");

  const data = result.data?.downloadClients ?? [];
  const error = result.error;

  const handleCreate = useCallback(async () => {
    setFormError(null);
    setSaving(true);
    const res = await createMutation({
      input: { name, type: type_, enabled, host: host || null, port: port ? parseInt(port, 10) : null, username: username || null },
    });
    setSaving(false);
    if (res.error) {
      setFormError(res.error.message);
    } else {
      modalRef.current?.close();
      setName("");
      setType("qbittorrent");
      setEnabled(true);
      setHost("");
      setPort("");
      setUsername("");
      refetch();
    }
  }, [name, type_, enabled, host, port, username, createMutation, refetch]);

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

  const handleTest = useCallback(
    async (id: string) => {
      const res = await testMutation({ id });
      setTestResult((prev) => ({ ...prev, [id]: res.error?.message ?? "ok" }));
    },
    [testMutation],
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
        title="Download Clients"
        subtitle="Manage torrent and Usenet download clients"
        actions={
          <Button onClick={() => modalRef.current?.show()}>Add Client</Button>
        }
      />

      {error && (
        <Alert kind="error" title="Failed to load download clients">
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
            { key: "host", header: "Host", render: (row) => <span>{row.host ?? "--"}</span> },
            {
              key: "test",
              header: "Test",
              render: (row) => (
                <div className="flex items-center gap-1">
                  <Button size="xs" variant="ghost" onClick={() => handleTest(row.id)}>Test</Button>
                  {testResult[row.id] && (
                    <StatusPill status={testResult[row.id] === "ok" ? "completed" : "failed"}
                      label={testResult[row.id] === "ok" ? "OK" : "Fail"} />
                  )}
                </div>
              ),
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
          emptyMessage="No download clients configured."
        />
      </Card>

      <Modal ref={modalRef} title="Add Download Client" onClose={() => setFormError(null)}>
        <div className="flex flex-col gap-3">
          {formError && <Alert kind="error">{formError}</Alert>}
          <Input label="Name" placeholder="My Client" value={name} onChange={(e) => setName(e.target.value)} />
          <div className="form-control w-full">
            <label className="label py-1"><span className="label-text">Type</span></label>
            <select className="select select-bordered w-full" value={type_} onChange={(e) => setType(e.target.value)}>
              <option value="qbittorrent">qBittorrent</option>
              <option value="transmission">Transmission</option>
              <option value="deluge">Deluge</option>
              <option value="sabnzbd">SABnzbd</option>
            </select>
          </div>
          <Input label="Host" placeholder="localhost" value={host} onChange={(e) => setHost(e.target.value)} />
          <Input label="Port" placeholder="8080" type="number" value={port} onChange={(e) => setPort(e.target.value)} />
          <Input label="Username" value={username} onChange={(e) => setUsername(e.target.value)} />
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
