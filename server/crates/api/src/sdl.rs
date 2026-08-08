//! Canonicalizes GraphQL SDL so two generators can be compared.
//!
//! Absinthe and async-graphql order definitions differently and wrap
//! descriptions differently. Comparing raw text would fail permanently on
//! cosmetic grounds, so both sides are reduced to a sorted, description-free
//! rendering before comparison.

use async_graphql_parser::types::{
    ConstDirective, DirectiveDefinition, DirectiveLocation, FieldDefinition, InputValueDefinition,
    SchemaDefinition, ServiceDocument, TypeDefinition, TypeKind, TypeSystemDefinition,
};
use async_graphql_parser::Positioned;

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
                rendered.push(render_directive_definition(&d.node));
            }
            TypeSystemDefinition::Schema(schema) => {
                rendered.push(render_schema(&schema.node));
            }
        }
    }

    rendered.sort();
    Ok(rendered.join("\n"))
}

fn render_schema(schema: &SchemaDefinition) -> String {
    let mut roots: Vec<String> = Vec::new();

    if let Some(query) = &schema.query {
        roots.push(format!("query:{}", query.node));
    }
    if let Some(mutation) = &schema.mutation {
        roots.push(format!("mutation:{}", mutation.node));
    }
    if let Some(subscription) = &schema.subscription {
        roots.push(format!("subscription:{}", subscription.node));
    }

    format!(
        "schema{} {{ {} }}",
        render_directives(&schema.directives),
        roots.join(" ")
    )
}

fn render_directive_definition(def: &DirectiveDefinition) -> String {
    let args = render_input_values(def.arguments.iter().map(|a| &a.node));
    let mut locations: Vec<String> = def
        .locations
        .iter()
        .map(|l| render_directive_location(l.node).to_string())
        .collect();
    locations.sort();

    let repeatable = if def.is_repeatable { " repeatable" } else { "" };

    format!(
        "directive @{}({}){} on {}",
        def.name.node,
        args,
        repeatable,
        locations.join("|")
    )
}

fn render_directive_location(loc: DirectiveLocation) -> &'static str {
    match loc {
        DirectiveLocation::Query => "QUERY",
        DirectiveLocation::Mutation => "MUTATION",
        DirectiveLocation::Subscription => "SUBSCRIPTION",
        DirectiveLocation::Field => "FIELD",
        DirectiveLocation::FragmentDefinition => "FRAGMENT_DEFINITION",
        DirectiveLocation::FragmentSpread => "FRAGMENT_SPREAD",
        DirectiveLocation::InlineFragment => "INLINE_FRAGMENT",
        DirectiveLocation::Schema => "SCHEMA",
        DirectiveLocation::Scalar => "SCALAR",
        DirectiveLocation::Object => "OBJECT",
        DirectiveLocation::FieldDefinition => "FIELD_DEFINITION",
        DirectiveLocation::ArgumentDefinition => "ARGUMENT_DEFINITION",
        DirectiveLocation::Interface => "INTERFACE",
        DirectiveLocation::Union => "UNION",
        DirectiveLocation::Enum => "ENUM",
        DirectiveLocation::EnumValue => "ENUM_VALUE",
        DirectiveLocation::InputObject => "INPUT_OBJECT",
        DirectiveLocation::InputFieldDefinition => "INPUT_FIELD_DEFINITION",
        DirectiveLocation::VariableDefinition => "VARIABLE_DEFINITION",
    }
}

fn render_type(def: &TypeDefinition) -> String {
    let name = def.name.node.as_str();
    let directives = render_directives(&def.directives);

    match &def.kind {
        TypeKind::Scalar => format!("scalar {name}{directives}"),
        TypeKind::Object(obj) => {
            let mut interfaces: Vec<String> =
                obj.implements.iter().map(|i| i.node.to_string()).collect();
            interfaces.sort();

            let fields = render_field_definitions(obj.fields.iter().map(|f| &f.node));

            format!(
                "type {name}{directives} implements [{}] {{{fields}}}",
                interfaces.join(",")
            )
        }
        TypeKind::Interface(iface) => {
            let fields = render_field_definitions(iface.fields.iter().map(|f| &f.node));
            format!("interface {name}{directives} {{{fields}}}")
        }
        TypeKind::Union(u) => {
            let mut members: Vec<String> = u.members.iter().map(|m| m.node.to_string()).collect();
            members.sort();
            format!("union {name}{directives} = {}", members.join("|"))
        }
        TypeKind::Enum(e) => {
            let mut values: Vec<String> = e
                .values
                .iter()
                .map(|v| {
                    format!(
                        "{}{}",
                        v.node.value.node,
                        render_directives(&v.node.directives)
                    )
                })
                .collect();
            values.sort();
            format!("enum {name}{directives} {{{}}}", values.join(","))
        }
        TypeKind::InputObject(input) => {
            let fields = render_input_values(input.fields.iter().map(|f| &f.node));
            format!("input {name}{directives} {{{fields}}}")
        }
    }
}

fn render_field_definitions<'a, I>(fields: I) -> String
where
    I: Iterator<Item = &'a FieldDefinition>,
{
    let mut rendered: Vec<String> = fields
        .map(|field| {
            let args = render_input_values(field.arguments.iter().map(|a| &a.node));
            format!(
                "{}({}):{}{}",
                field.name.node,
                args,
                field.ty.node,
                render_directives(&field.directives)
            )
        })
        .collect();

    rendered.sort();
    rendered.join(",")
}

fn render_input_values<'a, I>(values: I) -> String
where
    I: Iterator<Item = &'a InputValueDefinition>,
{
    let mut rendered: Vec<String> = values.map(render_input_value).collect();
    rendered.sort();
    rendered.join(",")
}

fn render_input_value(value: &InputValueDefinition) -> String {
    let default = value
        .default_value
        .as_ref()
        .map(|d| format!("={}", d.node))
        .unwrap_or_default();

    format!(
        "{}:{}{default}{}",
        value.name.node,
        value.ty.node,
        render_directives(&value.directives)
    )
}

fn render_directives(directives: &[Positioned<ConstDirective>]) -> String {
    if directives.is_empty() {
        return String::new();
    }

    let mut rendered: Vec<String> = directives
        .iter()
        .map(|d| render_directive(&d.node))
        .collect();
    rendered.sort();
    rendered.join("")
}

fn render_directive(directive: &ConstDirective) -> String {
    if directive.arguments.is_empty() {
        return format!(" @{}", directive.name.node);
    }

    let mut args: Vec<String> = directive
        .arguments
        .iter()
        .map(|(name, value)| format!("{}:{}", name.node, value.node))
        .collect();
    args.sort();

    format!(" @{}({})", directive.name.node, args.join(","))
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

    #[test]
    fn directive_definition_differences_survive_canonicalization() {
        let a = r#"directive @auth on FIELD_DEFINITION"#;
        let b = r#"directive @auth on OBJECT"#;

        assert_ne!(canonicalize(a).unwrap(), canonicalize(b).unwrap());
    }

    #[test]
    fn directive_definition_ordering_is_erased() {
        let a = r#"
            directive @auth(user: String = "guest") repeatable on FIELD_DEFINITION | OBJECT
        "#;
        let b = r#"
            "Checks auth"
            directive @auth(user: String = "guest") repeatable on OBJECT | FIELD_DEFINITION
        "#;

        assert_eq!(canonicalize(a).unwrap(), canonicalize(b).unwrap());
    }

    #[test]
    fn attached_type_directives_survive_canonicalization() {
        let a = r#"type Movie @deprecated { id: ID! }"#;
        let b = r#"type Movie { id: ID! }"#;

        assert_ne!(canonicalize(a).unwrap(), canonicalize(b).unwrap());
    }

    #[test]
    fn attached_field_directives_survive_canonicalization() {
        let a = r#"type Query { movie: Movie @deprecated }"#;
        let b = r#"type Query { movie: Movie }"#;

        assert_ne!(canonicalize(a).unwrap(), canonicalize(b).unwrap());
    }

    #[test]
    fn attached_argument_directives_survive_canonicalization() {
        let a = r#"type Query { movie(id: ID! @deprecated): Movie }"#;
        let b = r#"type Query { movie(id: ID!): Movie }"#;

        assert_ne!(canonicalize(a).unwrap(), canonicalize(b).unwrap());
    }

    #[test]
    fn attached_enum_value_directives_survive_canonicalization() {
        let a = r#"enum Role { ADMIN @deprecated USER }"#;
        let b = r#"enum Role { ADMIN USER }"#;

        assert_ne!(canonicalize(a).unwrap(), canonicalize(b).unwrap());
    }

    #[test]
    fn attached_input_field_directives_survive_canonicalization() {
        let a = r#"input Filter { term: String @deprecated }"#;
        let b = r#"input Filter { term: String }"#;

        assert_ne!(canonicalize(a).unwrap(), canonicalize(b).unwrap());
    }

    #[test]
    fn field_argument_defaults_survive_canonicalization() {
        let a = r#"type Query { movies(first: Int = 10): [Movie!]! }"#;
        let b = r#"type Query { movies(first: Int = 20): [Movie!]! }"#;

        assert_ne!(canonicalize(a).unwrap(), canonicalize(b).unwrap());
    }

    #[test]
    fn input_field_defaults_survive_canonicalization() {
        let a = r#"input Page { size: Int = 10 }"#;
        let b = r#"input Page { size: Int = 20 }"#;

        assert_ne!(canonicalize(a).unwrap(), canonicalize(b).unwrap());
    }

    #[test]
    fn default_value_ordering_is_erased() {
        let a = r#"input Page { size: Int = 10 offset: Int = 0 }"#;
        let b = r#"input Page { offset: Int = 0 size: Int = 10 }"#;

        assert_eq!(canonicalize(a).unwrap(), canonicalize(b).unwrap());
    }

    #[test]
    fn schema_block_differences_survive_canonicalization() {
        let a = r#"
            schema { query: QueryA }
            type QueryA { ok: Boolean! }
        "#;
        let b = r#"
            schema { query: QueryB }
            type QueryB { ok: Boolean! }
        "#;

        assert_ne!(canonicalize(a).unwrap(), canonicalize(b).unwrap());
    }

    #[test]
    fn schema_block_ordering_is_erased() {
        let a = r#"
            schema { query: Query mutation: Mutation subscription: Sub }
            type Query { ok: Boolean! }
            type Mutation { ok: Boolean! }
            type Sub { ok: Boolean! }
        "#;
        let b = r#"
            schema { subscription: Sub mutation: Mutation query: Query }
            type Sub { ok: Boolean! }
            type Mutation { ok: Boolean! }
            type Query { ok: Boolean! }
        "#;

        assert_eq!(canonicalize(a).unwrap(), canonicalize(b).unwrap());
    }
}
