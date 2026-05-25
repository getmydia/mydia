import { useRef, useState, useCallback } from "react";
import { useQuery, useMutation } from "urql";
import {
  QualityProfilesDocument,
  CreateQualityProfileDocument,
  UpdateQualityProfileDocument,
  DeleteQualityProfileDocument,
} from "../../graphql/generated/graphql";
import { PageHeader } from "../../components/page-header";
import { Card } from "../../components/card";
import { Table } from "../../components/table";
import { Modal, type ModalHandle } from "../../components/modal";
import { Button } from "../../components/button";
import { Input } from "../../components/input";
import { StatusPill } from "../../components/status-pill";
import { Alert } from "../../components/feedback";

export function QualityProfilesPage() {
  const [result, refetch] = useQuery({ query: QualityProfilesDocument });
  const [, createMutation] = useMutation(CreateQualityProfileDocument);
  const [, updateMutation] = useMutation(UpdateQualityProfileDocument);
  const [, deleteMutation] = useMutation(DeleteQualityProfileDocument);

  const modalRef = useRef<ModalHandle>(null);
  const [formError, setFormError] = useState<string | null>(null);
  const [saving, setSaving] = useState(false);
  const [editingId, setEditingId] = useState<string | null>(null);

  const [name, setName] = useState("");
  const [upgradesAllowed, setUpgradesAllowed] = useState(true);
  const [upgradeUntilQuality, setUpgradeUntilQuality] = useState("");
  const [qualities, setQualities] = useState("");

  const data = result.data?.qualityProfiles ?? [];
  const error = result.error;

  const openCreate = useCallback(() => {
    setEditingId(null);
    setName("");
    setUpgradesAllowed(true);
    setUpgradeUntilQuality("");
    setQualities("");
    modalRef.current?.show();
  }, []);

  const openEdit = useCallback(
    (row: (typeof data)[0]) => {
      setEditingId(row.id);
      setName(row.name);
      setUpgradesAllowed(row.upgradesAllowed);
      setUpgradeUntilQuality(row.upgradeUntilQuality ?? "");
      setQualities(row.qualities);
      modalRef.current?.show();
    },
    [],
  );

  const handleSave = useCallback(async () => {
    setFormError(null);
    setSaving(true);
    const input = { name, upgradesAllowed, upgradeUntilQuality: upgradeUntilQuality || null, qualities };
    const res = editingId
      ? await updateMutation({ id: editingId, input })
      : await createMutation({ input });
    setSaving(false);
    if (res.error) {
      setFormError(res.error.message);
    } else {
      modalRef.current?.close();
      refetch();
    }
  }, [editingId, name, upgradesAllowed, upgradeUntilQuality, qualities, createMutation, updateMutation, refetch]);

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
        title="Quality Profiles"
        subtitle="Define quality preferences for media downloads"
        actions={<Button onClick={openCreate}>Add Profile</Button>}
      />

      {error && (
        <Alert kind="error" title="Failed to load quality profiles">
          {error.message}
        </Alert>
      )}

      <Card>
        <Table
          columns={[
            { key: "name", header: "Name", render: (row) => <span className="font-medium">{row.name}</span> },
            {
              key: "upgradesAllowed",
              header: "Upgrades Allowed",
              render: (row) =>
                row.upgradesAllowed ? (
                  <StatusPill status="active" label="Yes" />
                ) : (
                  <StatusPill status="inactive" label="No" />
                ),
            },
            {
              key: "upgradeUntilQuality",
              header: "Upgrade Until",
              render: (row) => <span>{row.upgradeUntilQuality ?? "--"}</span>,
            },
            {
              key: "isSystem",
              header: "System",
              render: (row) =>
                row.isSystem ? <StatusPill status="info" label="System" /> : null,
            },
            {
              key: "actions",
              header: "",
              render: (row) => (
                <div className="flex gap-1">
                  <Button size="sm" variant="ghost" onClick={() => openEdit(row)}>
                    Edit
                  </Button>
                  <Button size="sm" variant="error" onClick={() => handleDelete(row.id)}>
                    Delete
                  </Button>
                </div>
              ),
            },
          ]}
          rows={data}
          keyExtractor={(row) => row.id}
          emptyMessage="No quality profiles defined."
        />
      </Card>

      <Modal ref={modalRef} title={editingId ? "Edit Quality Profile" : "Add Quality Profile"} onClose={() => setFormError(null)}>
        <div className="flex flex-col gap-3">
          {formError && <Alert kind="error">{formError}</Alert>}
          <Input label="Name" placeholder="HD-1080p" value={name} onChange={(e) => setName(e.target.value)} />
          <Input
            label="Qualities"
            placeholder='["Bluray-1080p", "WEBRip-1080p"]'
            value={qualities}
            onChange={(e) => setQualities(e.target.value)}
          />
          <Input
            label="Upgrade Until Quality"
            placeholder="Bluray-2160p"
            value={upgradeUntilQuality}
            onChange={(e) => setUpgradeUntilQuality(e.target.value)}
          />
          <label className="flex items-center gap-2 cursor-pointer">
            <input
              type="checkbox"
              className="toggle toggle-primary"
              checked={upgradesAllowed}
              onChange={(e) => setUpgradesAllowed(e.target.checked)}
            />
            <span className="label-text">Upgrades Allowed</span>
          </label>
          <div className="flex justify-end gap-2 mt-2">
            <Button variant="ghost" onClick={() => modalRef.current?.close()}>Cancel</Button>
            <Button loading={saving} onClick={handleSave}>Save</Button>
          </div>
        </div>
      </Modal>
    </div>
  );
}
