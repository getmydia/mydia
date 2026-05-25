import { useState, useCallback } from "react";
import { useQuery, useMutation } from "urql";
import {
  SettingsDocument,
  UpdateSettingDocument,
} from "../../graphql/generated/graphql";
import { PageHeader } from "../../components/page-header";
import { ConfigSection, ConfigRow } from "../../components/config-form";
import { Button } from "../../components/button";
import { Alert } from "../../components/feedback";

export function SettingsPage() {
  const [result, refetch] = useQuery({ query: SettingsDocument });
  const [, updateMutation] = useMutation(UpdateSettingDocument);

  const [editedValues, setEditedValues] = useState<Record<string, string>>({});
  const [editingKey, setEditingKey] = useState<string | null>(null);
  const [savingKey, setSavingKey] = useState<string | null>(null);
  const [saveError, setSaveError] = useState<string | null>(null);

  const data = result.data?.settings ?? [];
  const error = result.error;

  const grouped = data.reduce<Record<string, typeof data>>((acc, row) => {
    const cat = row.category || "Other";
    if (!acc[cat]) acc[cat] = [];
    acc[cat].push(row);
    return acc;
  }, {});

  const handleEdit = useCallback((key: string, currentValue: string) => {
    setEditedValues((prev) => ({ ...prev, [key]: currentValue }));
    setEditingKey(key);
    setSaveError(null);
  }, []);

  const handleCancel = useCallback(() => {
    setEditingKey(null);
  }, []);

  const handleChange = useCallback(
    (key: string, value: string) => {
      setEditedValues((prev) => ({ ...prev, [key]: value }));
    },
    [],
  );

  const handleSave = useCallback(
    async (key: string) => {
      const value = editedValues[key];
      if (value === undefined) return;
      setSavingKey(key);
      setSaveError(null);
      const res = await updateMutation({ key, value });
      setSavingKey(null);
      if (res.error) {
        setSaveError(res.error.message);
      } else {
        setEditingKey(null);
        refetch();
      }
    },
    [editedValues, updateMutation, refetch],
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
        title="Settings"
        subtitle="Manage application configuration"
        actions={
          <Button size="sm" variant="ghost" onClick={() => refetch()}>
            Refresh
          </Button>
        }
      />

      {error && (
        <Alert kind="error" title="Failed to load settings">
          {error.message}
        </Alert>
      )}

      {saveError && (
        <Alert kind="error" onClose={() => setSaveError(null)}>
          {saveError}
        </Alert>
      )}

      {Object.entries(grouped).map(([category, rows]) => (
        <ConfigSection
          key={category}
          title={category}
          id={`admin-settings-${category.toLowerCase().replace(/[^a-z0-9]/g, "-")}`}
        >
          {rows.map((row) => {
            const isEditing = editingKey === row.key;
            const currentValue =
              editedValues[row.key] !== undefined
                ? editedValues[row.key]
                : row.value;
            const isEnvLocked = row.source === "env";
            const isSaving = savingKey === row.key;

            return (
              <ConfigRow
                key={row.key}
                label={row.label}
                description={row.description ?? undefined}
                source={row.source}
              >
                <div className="flex flex-col gap-2">
                  <div className="flex flex-col sm:flex-row sm:items-end gap-2">
                    <div className="flex-1">
                      {isEditing ? (
                        row.kind === "boolean" ? (
                          <label className="flex items-center gap-2 cursor-pointer">
                            <input
                              type="checkbox"
                              className="toggle toggle-primary"
                              checked={["true", "1", "yes", "on"].includes(
                                currentValue.toLowerCase(),
                              )}
                              onChange={(e) =>
                                handleChange(
                                  row.key,
                                  e.target.checked ? "true" : "false",
                                )
                              }
                            />
                            <span className="label-text">
                              {["true", "1", "yes", "on"].includes(
                                currentValue.toLowerCase(),
                              )
                                ? "Enabled"
                                : "Disabled"}
                            </span>
                          </label>
                        ) : (
                          <input
                            type={row.kind === "integer" ? "number" : "text"}
                            className="input input-bordered w-full"
                            value={currentValue}
                            placeholder={row.placeholder ?? undefined}
                            onChange={(e) =>
                              handleChange(row.key, e.target.value)
                            }
                          />
                        )
                      ) : (
                        <span className="text-sm py-1.5">
                          {row.kind === "boolean"
                            ? [
                                "true",
                                "1",
                                "yes",
                                "on",
                              ].includes(currentValue.toLowerCase())
                              ? "Enabled"
                              : "Disabled"
                            : currentValue}
                        </span>
                      )}
                    </div>
                    {isEnvLocked ? (
                      <span className="text-xs text-base-content/60">
                        Locked by env var
                      </span>
                    ) : isEditing ? (
                      <div className="flex gap-1">
                        <Button
                          size="sm"
                          variant="primary"
                          loading={isSaving}
                          onClick={() => handleSave(row.key)}
                        >
                          Save
                        </Button>
                        <Button
                          size="sm"
                          variant="ghost"
                          onClick={handleCancel}
                        >
                          Cancel
                        </Button>
                      </div>
                    ) : (
                      <Button
                        size="sm"
                        variant="outline"
                        onClick={() => handleEdit(row.key, row.value)}
                      >
                        Edit
                      </Button>
                    )}
                  </div>
                </div>
              </ConfigRow>
            );
          })}
        </ConfigSection>
      ))}
    </div>
  );
}
