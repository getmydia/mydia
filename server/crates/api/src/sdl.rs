//! Canonicalizes GraphQL SDL so two generators can be compared.
//!
//! Absinthe and async-graphql order definitions differently and wrap
//! descriptions differently. Comparing raw text would fail permanently on
//! cosmetic grounds, so both sides are reduced to a sorted, description-free
//! rendering before comparison.

use async_graphql_parser::types::{ServiceDocument, TypeKind, TypeSystemDefinition};

#[derive(Debug, thiserror::Error)]
pub enum SdlError {
    #[error("could not parse SDL: {0}")]
    Parse(String),
}

/// Reduces SDL to a canonical string: definitions and their members sorted by
/// name, descriptions removed, whitespace normalized.
pub fn canonicalize(sdl: &str) -> Result<String, SdlError> {
    let doc: ServiceDocument =
        async_graphql_parser::parse_schema(sdl).map_err(|e| SdlError::Parse(e.to_string()))?;

    let mut rendered: Vec<String> = Vec::new();

    for definition in &doc.definitions {
        match definition {
            TypeSystemDefinition::Type(ty) => {
                rendered.push(render_type(&ty.node));
            }
            TypeSystemDefinition::Directive(d) => {
                rendered.push(format!("directive @{}", d.node.name.node));
            }
            // The `schema { query: ... }` block names root types that are
            // rendered on their own, so it carries no additional information.
            TypeSystemDefinition::Schema(_) => {}
        }
    }

    rendered.sort();
    Ok(rendered.join("\n"))
}

fn render_type(def: &async_graphql_parser::types::TypeDefinition) -> String {
    let name = def.name.node.as_str();

    match &def.kind {
        TypeKind::Scalar => format!("scalar {name}"),
        TypeKind::Object(obj) => {
            let mut interfaces: Vec<String> =
                obj.implements.iter().map(|i| i.node.to_string()).collect();
            interfaces.sort();

            let fields = render_fields(obj.fields.iter().map(|f| {
                (
                    f.node.name.node.to_string(),
                    f.node.ty.node.to_string(),
                    f.node
                        .arguments
                        .iter()
                        .map(|a| (a.node.name.node.to_string(), a.node.ty.node.to_string()))
                        .collect::<Vec<_>>(),
                )
            }));

            format!(
                "type {name} implements [{}] {{{fields}}}",
                interfaces.join(",")
            )
        }
        TypeKind::Interface(iface) => {
            let fields = render_fields(iface.fields.iter().map(|f| {
                (
                    f.node.name.node.to_string(),
                    f.node.ty.node.to_string(),
                    f.node
                        .arguments
                        .iter()
                        .map(|a| (a.node.name.node.to_string(), a.node.ty.node.to_string()))
                        .collect::<Vec<_>>(),
                )
            }));
            format!("interface {name} {{{fields}}}")
        }
        TypeKind::Union(u) => {
            let mut members: Vec<String> = u.members.iter().map(|m| m.node.to_string()).collect();
            members.sort();
            format!("union {name} = {}", members.join("|"))
        }
        TypeKind::Enum(e) => {
            let mut values: Vec<String> = e
                .values
                .iter()
                .map(|v| v.node.value.node.to_string())
                .collect();
            values.sort();
            format!("enum {name} {{{}}}", values.join(","))
        }
        TypeKind::InputObject(input) => {
            let fields = render_fields(input.fields.iter().map(|f| {
                (
                    f.node.name.node.to_string(),
                    f.node.ty.node.to_string(),
                    Vec::new(),
                )
            }));
            format!("input {name} {{{fields}}}")
        }
    }
}

fn render_fields<I>(fields: I) -> String
where
    I: Iterator<Item = (String, String, Vec<(String, String)>)>,
{
    let mut rendered: Vec<String> = fields
        .map(|(name, ty, args)| {
            let mut args: Vec<String> = args.into_iter().map(|(n, t)| format!("{n}:{t}")).collect();
            args.sort();
            format!("{name}({}):{ty}", args.join(","))
        })
        .collect();

    rendered.sort();
    rendered.join(",")
}

#[cfg(test)]
mod tests {
    use super::canonicalize;

    #[test]
    fn ordering_differences_are_erased() {
        let a = r#"
            type Movie { id: ID! title: String! }
            type Show { id: ID! }
        "#;
        let b = r#"
            type Show { id: ID! }
            type Movie { title: String! id: ID! }
        "#;

        assert_eq!(canonicalize(a).unwrap(), canonicalize(b).unwrap());
    }

    #[test]
    fn descriptions_are_ignored() {
        let a = r#"type Movie { id: ID! }"#;
        let b = r#""A movie" type Movie { "The id" id: ID! }"#;

        assert_eq!(canonicalize(a).unwrap(), canonicalize(b).unwrap());
    }

    #[test]
    fn a_missing_field_survives_canonicalization() {
        let a = r#"type Movie { id: ID! title: String! }"#;
        let b = r#"type Movie { id: ID! }"#;

        assert_ne!(canonicalize(a).unwrap(), canonicalize(b).unwrap());
    }

    #[test]
    fn a_changed_nullability_survives_canonicalization() {
        let a = r#"type Movie { title: String! }"#;
        let b = r#"type Movie { title: String }"#;

        assert_ne!(canonicalize(a).unwrap(), canonicalize(b).unwrap());
    }

    #[test]
    fn invalid_sdl_is_an_error() {
        assert!(canonicalize("type { }").is_err());
    }
}
