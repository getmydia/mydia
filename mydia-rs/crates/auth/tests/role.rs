//! Role hierarchy + require_role check.

use mydia_rs_auth::role::{rank, require_role, satisfies};
use mydia_rs_auth::Role;

#[test]
fn admin_satisfies_every_role() {
    for required in [Role::Admin, Role::User, Role::Readonly, Role::Guest] {
        assert!(satisfies(Role::Admin, required));
        require_role(required, Role::Admin).expect("admin always passes");
    }
}

#[test]
fn user_does_not_satisfy_admin() {
    assert!(!satisfies(Role::User, Role::Admin));
    let err = require_role(Role::Admin, Role::User).expect_err("must reject");
    assert_eq!(err.required, "admin");
    assert_eq!(err.actual, "user");
}

#[test]
fn guest_satisfies_only_guest() {
    assert!(satisfies(Role::Guest, Role::Guest));
    assert!(!satisfies(Role::Guest, Role::Readonly));
    assert!(!satisfies(Role::Guest, Role::User));
    assert!(!satisfies(Role::Guest, Role::Admin));
}

#[test]
fn rank_order_is_admin_user_readonly_guest() {
    assert!(rank(Role::Admin) > rank(Role::User));
    assert!(rank(Role::User) > rank(Role::Readonly));
    assert!(rank(Role::Readonly) > rank(Role::Guest));
}
