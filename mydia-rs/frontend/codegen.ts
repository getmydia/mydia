import type { CodegenConfig } from "@graphql-codegen/cli";

const config: CodegenConfig = {
  schema: "./schema.graphql",
  documents: ["./src/**/*.gql"],
  generates: {
    "./src/graphql/generated/": {
      preset: "client",
      plugins: [
        {
          add: {
            content: "// @ts-nocheck\n/* eslint-disable */",
          },
        },
      ],
      config: {
        strictScalars: true,
        scalars: {
          DateTime: "string",
          NaiveDate: "string",
          UUID: "string",
          JSON: "unknown",
        },
      },
    },
  },
  hooks: {
    afterAllFileWrite: ["prettier --write"],
  },
};

export default config;
