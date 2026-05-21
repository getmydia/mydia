//! Role-based authorization primitives.
//!
//! Re-exports [`mydia_rs_models::user::UserRole`] as [`Role`] so the
//! auth crate doesn't expose two parallel enums. [`require_role`] is
//! the shared check the request-level middleware (lands in U6's
//! follow-up with axum-login) and the GraphQL resolvers (U10+) both
//! call into.

pub use mydia_rs_models::user::UserRole as Role;

#[derive(Debug, thiserror::Error)]
#[error("forbidden: caller has role {actual} but {required} is required")]
pub struct RoleError {
    pub actual: &'static str,
    pub required: &'static str,
}

/// Privilege rank of a role. Higher is more privileged.
///
/// Hierarchy: `Admin > User > Readonly > Guest`. Operations that
/// need write privileges call `require_role(Role::User, caller)`;
/// admin-only operations call `require_role(Role::Admin, caller)`.
pub fn rank(role: Role) -> u8 {
    match role {
        Role::Admin => 3,
        Role::User => 2,
        Role::Readonly => 1,
        Role::Guest => 0,
    }
}

/// `true` when the caller's role meets or exceeds the required role.
pub fn satisfies(caller: Role, required: Role) -> bool {
    rank(caller) >= rank(required)
}

/// Verify the caller's role meets the requirement, returning a typed
/// [`RoleError`] when it doesn't. Suitable for use in async resolvers
/// and middleware.
pub fn require_role(required: Role, caller: Role) -> Result<(), RoleError> {
    if satisfies(caller, required) {
        Ok(())
    } else {
        Err(RoleError {
            actual: caller.as_str(),
            required: required.as_str(),
        })
    }
}
