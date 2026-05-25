import { useState, useCallback } from "react";
import { useQuery, useMutation } from "urql";
import {
  CurrentProfileDocument,
  UpdateProfileDocument,
  ChangePasswordDocument,
} from "../graphql/generated/graphql";
import { PageHeader } from "../components/page-header";
import { Card } from "../components/card";
import { Input } from "../components/input";
import { Button } from "../components/button";
import { Alert } from "../components/feedback";

export function ProfilePage() {
  const [{ data, fetching, error }] = useQuery({ query: CurrentProfileDocument });
  const [, updateProfile] = useMutation(UpdateProfileDocument);
  const [, changePassword] = useMutation(ChangePasswordDocument);

  const profile = data?.currentProfile;

  const [displayName, setDisplayName] = useState("");
  const [email, setEmail] = useState("");
  const [profileError, setProfileError] = useState<string | null>(null);
  const [profileSuccess, setProfileSuccess] = useState<string | null>(null);
  const [profileInitialized, setProfileInitialized] = useState(false);

  if (profile && !profileInitialized) {
    setDisplayName(profile.displayName ?? "");
    setEmail(profile.email ?? "");
    setProfileInitialized(true);
  }

  const [currentPassword, setCurrentPassword] = useState("");
  const [newPassword, setNewPassword] = useState("");
  const [passwordError, setPasswordError] = useState<string | null>(null);
  const [passwordSuccess, setPasswordSuccess] = useState<string | null>(null);

  const handleProfileSubmit = useCallback(
    async (e: React.FormEvent) => {
      e.preventDefault();
      setProfileError(null);
      setProfileSuccess(null);

      const res = await updateProfile({
        input: {
          displayName: displayName || null,
          email: email || null,
          username: null,
        },
      });

      if (res.error) {
        setProfileError(res.error.message);
      } else {
        setProfileSuccess("Profile updated.");
      }
    },
    [displayName, email, updateProfile],
  );

  const handlePasswordSubmit = useCallback(
    async (e: React.FormEvent) => {
      e.preventDefault();
      setPasswordError(null);
      setPasswordSuccess(null);

      if (!currentPassword || !newPassword) {
        setPasswordError("Both fields are required.");
        return;
      }
      if (newPassword.length < 8) {
        setPasswordError("New password must be at least 8 characters.");
        return;
      }

      const res = await changePassword({
        currentPassword,
        newPassword,
      });

      if (res.error) {
        setPasswordError(res.error.message);
      } else {
        setPasswordSuccess("Password changed successfully.");
        setCurrentPassword("");
        setNewPassword("");
      }
    },
    [currentPassword, newPassword, changePassword],
  );

  if (fetching && !profile) {
    return (
      <div className="flex justify-center py-16">
        <span className="loading loading-spinner loading-lg" />
      </div>
    );
  }

  if (error) {
    return (
      <div>
        <div className="alert alert-error">Failed to load profile.</div>
      </div>
    );
  }

  return (
    <div>
      <PageHeader title="Profile" subtitle="Manage your account settings" />

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <Card title="Account Details">
          {profileError && <Alert kind="error">{profileError}</Alert>}
          {profileSuccess && <Alert kind="success">{profileSuccess}</Alert>}

          <form onSubmit={handleProfileSubmit} className="space-y-4 mt-4">
            <div className="form-control">
              <label className="label py-1">
                <span className="label-text">Username</span>
              </label>
              <input
                type="text"
                className="input input-bordered w-full"
                value={profile?.username ?? ""}
                disabled
              />
              <label className="label py-1">
                <span className="label-text-alt text-base-content/60">
                  Username cannot be changed
                </span>
              </label>
            </div>

            <Input
              label="Display Name"
              value={displayName}
              onChange={(e) => setDisplayName(e.target.value)}
              placeholder="Display name"
            />

            <Input
              label="Email"
              value={email}
              onChange={(e) => setEmail(e.target.value)}
              placeholder="Email address"
              type="email"
            />

            <div className="form-control">
              <label className="label py-1">
                <span className="label-text">Role</span>
              </label>
              <input
                type="text"
                className="input input-bordered w-full"
                value={profile?.role ?? ""}
                disabled
              />
            </div>

            <Button type="submit" className="w-full">
              Save Changes
            </Button>
          </form>
        </Card>

        <Card title="Change Password">
          {passwordError && <Alert kind="error">{passwordError}</Alert>}
          {passwordSuccess && <Alert kind="success">{passwordSuccess}</Alert>}

          <form onSubmit={handlePasswordSubmit} className="space-y-4 mt-4">
            <Input
              label="Current Password"
              value={currentPassword}
              onChange={(e) => setCurrentPassword(e.target.value)}
              type="password"
              placeholder="Current password"
            />

            <Input
              label="New Password"
              value={newPassword}
              onChange={(e) => setNewPassword(e.target.value)}
              type="password"
              placeholder="At least 8 characters"
              hint="Minimum 8 characters"
            />

            <Button type="submit" variant="secondary" className="w-full">
              Change Password
            </Button>
          </form>
        </Card>
      </div>
    </div>
  );
}
