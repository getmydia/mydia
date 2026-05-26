import { delegateToSchema, isExternalObject, getUnpathedErrors, getSubschema, resolveExternalValue, applySchemaTransforms, defaultMergedResolver, getTypeInfo, isPrototypePollutingKey } from '@graphql-tools/delegate';
import { getRootTypeMap, getResponseKeyFromInfo, memoize1, mapSchema, MapperKind, renameType, visitData, transformInputValue, visitResult, astFromValueUntyped, getOperationASTFromRequest, relocatedError, getArgumentValues, valueMatchesCriteria, getDirectives, pruneSchema, selectObjectFields, appendObjectFields, modifyObjectFields, removeObjectFields, isAsyncIterable, createGraphQLError, inspect } from '@graphql-tools/utils';
import { isSpecifiedScalarType, GraphQLScalarType, GraphQLUnionType, GraphQLInterfaceType, GraphQLObjectType, isScalarType, visit, Kind, visitWithTypeInfo, isObjectType, isInterfaceType, typeFromAST, isInputType, getNamedType, isLeafType, valueFromAST, valueFromASTUntyped, astFromValue, GraphQLNonNull, getNullableType, isListType, GraphQLList, BREAK, parse, getIntrospectionQuery, buildClientSchema } from 'graphql';
import { handleMaybePromise } from '@whatwg-node/promise-helpers';

function generateProxyingResolvers(subschemaConfig) {
  const targetSchema = subschemaConfig.schema;
  const createProxyingResolver = subschemaConfig.createProxyingResolver ?? defaultCreateProxyingResolver;
  const rootTypeMap = getRootTypeMap(targetSchema);
  const resolvers = {};
  for (const [operation, rootType] of rootTypeMap.entries()) {
    const typeName = rootType.name;
    const fields = rootType.getFields();
    resolvers[typeName] = {};
    for (const fieldName in fields) {
      const proxyingResolver = createProxyingResolver({
        subschemaConfig,
        operation,
        fieldName
      });
      const finalResolver = createPossiblyNestedProxyingResolver(
        subschemaConfig,
        proxyingResolver
      );
      if (operation === "subscription") {
        resolvers[typeName][fieldName] = {
          subscribe: finalResolver,
          resolve: identical
        };
      } else {
        resolvers[typeName][fieldName] = {
          resolve: finalResolver
        };
      }
    }
  }
  return resolvers;
}
function identical(value) {
  return value;
}
function createPossiblyNestedProxyingResolver(subschemaConfig, proxyingResolver) {
  return function possiblyNestedProxyingResolver(parent, args, context, info) {
    if (parent != null) {
      const responseKey = getResponseKeyFromInfo(info);
      if (isExternalObject(parent)) {
        const unpathedErrors = getUnpathedErrors(parent);
        const subschema = getSubschema(parent, responseKey);
        if (subschemaConfig === subschema && parent[responseKey] !== void 0) {
          return resolveExternalValue(
            parent[responseKey],
            unpathedErrors,
            subschema,
            context,
            info
          );
        }
      }
    }
    return proxyingResolver(parent, args, context, info);
  };
}
function defaultCreateProxyingResolver({
  subschemaConfig,
  operation
}) {
  return function proxyingResolver(rootValue, args, context, info) {
    return delegateToSchema({
      schema: subschemaConfig,
      operation,
      rootValue,
      args,
      context,
      info
    });
  };
}

const wrapSchema = memoize1(function wrapSchema2(subschemaConfig) {
  const targetSchema = subschemaConfig.schema;
  const proxyingResolvers = generateProxyingResolvers(subschemaConfig);
  const schema = createWrappingSchema(targetSchema, proxyingResolvers);
  const transformed = applySchemaTransforms(schema, subschemaConfig);
  return transformed;
});
function createWrappingSchema(schema, proxyingResolvers) {
  return mapSchema(schema, {
    [MapperKind.ROOT_FIELD]: (fieldConfig, fieldName, typeName) => {
      return {
        ...fieldConfig,
        ...proxyingResolvers[typeName]?.[fieldName]
      };
    },
    [MapperKind.OBJECT_FIELD]: (fieldConfig) => {
      return {
        ...fieldConfig,
        resolve: defaultMergedResolver,
        subscribe: void 0
      };
    },
    [MapperKind.OBJECT_TYPE]: (type) => {
      const config = type.toConfig();
      return new GraphQLObjectType({
        ...config,
        isTypeOf: void 0
      });
    },
    [MapperKind.INTERFACE_TYPE]: (type) => {
      const config = type.toConfig();
      return new GraphQLInterfaceType({
        ...config,
        resolveType: void 0
      });
    },
    [MapperKind.UNION_TYPE]: (type) => {
      const config = type.toConfig();
      return new GraphQLUnionType({
        ...config,
        resolveType: void 0
      });
    },
    [MapperKind.ENUM_VALUE]: (valueConfig) => {
      return {
        ...valueConfig,
        value: void 0
      };
    },
    [MapperKind.SCALAR_TYPE]: (type) => {
      if (isSpecifiedScalarType(type)) {
        return type;
      }
      return new GraphQLScalarType({
        ...type.toConfig(),
        serialize: void 0,
        parseValue: void 0,
        parseLiteral: void 0
      });
    }
  });
}

class RenameTypes {
  renamer;
  map;
  reverseMap;
  renameBuiltins;
  renameScalars;
  constructor(renamer, options) {
    this.renamer = renamer;
    this.map = /* @__PURE__ */ Object.create(null);
    this.reverseMap = /* @__PURE__ */ Object.create(null);
    const { renameBuiltins = false, renameScalars = true } = options != null ? options : {};
    this.renameBuiltins = renameBuiltins;
    this.renameScalars = renameScalars;
  }
  transformSchema(originalWrappingSchema, _subschemaConfig) {
    const typeNames = new Set(
      Object.keys(originalWrappingSchema.getTypeMap())
    );
    return mapSchema(originalWrappingSchema, {
      [MapperKind.TYPE]: (type) => {
        if (isSpecifiedScalarType(type) && !this.renameBuiltins) {
          return void 0;
        }
        if (isScalarType(type) && !this.renameScalars) {
          return void 0;
        }
        const oldName = type.name;
        const newName = this.renamer(oldName);
        if (newName !== void 0 && newName !== oldName) {
          if (typeNames.has(newName)) {
            console.warn(
              `New type name ${newName} for ${oldName} already exists in the schema. Skip renaming.`
            );
            return;
          }
          this.map[oldName] = newName;
          this.reverseMap[newName] = oldName;
          typeNames.delete(oldName);
          typeNames.add(newName);
          return renameType(type, newName);
        }
        return void 0;
      },
      [MapperKind.ROOT_OBJECT]() {
        return void 0;
      }
    });
  }
  transformRequest(originalRequest, _delegationContext, _transformationContext) {
    const document = visit(originalRequest.document, {
      [Kind.NAMED_TYPE]: (node) => {
        const name = node.name.value;
        if (name in this.reverseMap) {
          return {
            ...node,
            name: {
              kind: Kind.NAME,
              value: this.reverseMap[name]
            }
          };
        }
        return void 0;
      }
    });
    return {
      ...originalRequest,
      document
    };
  }
  transformResult(originalResult, _delegationContext, _transformationContext) {
    return {
      ...originalResult,
      data: visitData(originalResult.data, (object) => {
        const typeName = object?.__typename;
        if (typeName != null && typeName in this.map) {
          object.__typename = this.map[typeName];
        }
        return object;
      })
    };
  }
}

class FilterTypes {
  filter;
  constructor(filter) {
    this.filter = filter;
  }
  transformSchema(originalWrappingSchema, _subschemaConfig) {
    return mapSchema(originalWrappingSchema, {
      [MapperKind.TYPE]: (type) => {
        if (this.filter(type)) {
          return void 0;
        }
        return null;
      }
    });
  }
}

class RenameRootTypes {
  renamer;
  map;
  reverseMap;
  constructor(renamer) {
    this.renamer = renamer;
    this.map = /* @__PURE__ */ Object.create(null);
    this.reverseMap = /* @__PURE__ */ Object.create(null);
  }
  transformSchema(originalWrappingSchema, _subschemaConfig) {
    return mapSchema(originalWrappingSchema, {
      [MapperKind.ROOT_OBJECT]: (type) => {
        const oldName = type.name;
        const newName = this.renamer(oldName);
        if (newName !== void 0 && newName !== oldName) {
          this.map[oldName] = newName;
          this.reverseMap[newName] = oldName;
          return renameType(type, newName);
        }
        return void 0;
      }
    });
  }
  transformRequest(originalRequest, _delegationContext, _transformationContext) {
    const document = visit(originalRequest.document, {
      [Kind.NAMED_TYPE]: (node) => {
        const name = node.name.value;
        if (name in this.reverseMap) {
          return {
            ...node,
            name: {
              kind: Kind.NAME,
              value: this.reverseMap[name]
            }
          };
        }
        return void 0;
      }
    });
    return {
      ...originalRequest,
      document
    };
  }
  transformResult(originalResult, _delegationContext, _transformationContext) {
    return {
      ...originalResult,
      data: visitData(originalResult.data, (object) => {
        const typeName = object?.__typename;
        if (typeName != null && typeName in this.map) {
          object.__typename = this.map[typeName];
        }
        return object;
      })
    };
  }
}

class TransformCompositeFields {
  fieldTransformer;
  fieldNodeTransformer;
  dataTransformer;
  errorsTransformer;
  transformedSchema;
  typeInfo;
  mapping;
  subscriptionTypeName;
  constructor(fieldTransformer, fieldNodeTransformer, dataTransformer, errorsTransformer) {
    this.fieldTransformer = fieldTransformer;
    this.fieldNodeTransformer = fieldNodeTransformer;
    this.dataTransformer = dataTransformer;
    this.errorsTransformer = errorsTransformer;
    this.mapping = {};
  }
  _getTypeInfo() {
    const typeInfo = this.typeInfo;
    if (typeInfo === void 0) {
      throw new Error(
        `The TransformCompositeFields transform's  "transformRequest" and "transformResult" methods cannot be used without first calling "transformSchema".`
      );
    }
    return typeInfo;
  }
  transformSchema(originalWrappingSchema, _subschemaConfig) {
    this.transformedSchema = mapSchema(originalWrappingSchema, {
      [MapperKind.COMPOSITE_FIELD]: (fieldConfig, fieldName, typeName) => {
        const transformedField = this.fieldTransformer(
          typeName,
          fieldName,
          fieldConfig
        );
        if (Array.isArray(transformedField)) {
          const newFieldName = transformedField[0];
          if (newFieldName !== fieldName) {
            if (!this.mapping[typeName]) {
              this.mapping[typeName] = {};
            }
            this.mapping[typeName][newFieldName] = fieldName;
          }
        }
        return transformedField;
      }
    });
    this.typeInfo = getTypeInfo(this.transformedSchema);
    this.subscriptionTypeName = originalWrappingSchema.getSubscriptionType()?.name;
    return this.transformedSchema;
  }
  transformRequest(originalRequest, _delegationContext, transformationContext) {
    const document = originalRequest.document;
    return {
      ...originalRequest,
      document: this.transformDocument(document, transformationContext)
    };
  }
  transformResult(result, _delegationContext, transformationContext) {
    const dataTransformer = this.dataTransformer;
    if (dataTransformer != null) {
      result.data = visitData(
        result.data,
        (value) => dataTransformer(value, transformationContext)
      );
    }
    if (this.errorsTransformer != null && Array.isArray(result.errors)) {
      result.errors = this.errorsTransformer(
        result.errors,
        transformationContext
      );
    }
    return result;
  }
  transformDocument(document, transformationContext) {
    const fragments = /* @__PURE__ */ Object.create(null);
    for (const def of document.definitions) {
      if (def.kind === Kind.FRAGMENT_DEFINITION) {
        fragments[def.name.value] = def;
      }
    }
    return visit(
      document,
      visitWithTypeInfo(this._getTypeInfo(), {
        [Kind.SELECTION_SET]: {
          leave: (node) => this.transformSelectionSet(
            node,
            this._getTypeInfo(),
            fragments,
            transformationContext
          )
        }
      })
    );
  }
  transformSelectionSet(node, typeInfo, fragments, transformationContext) {
    const parentType = typeInfo.getParentType();
    if (parentType == null) {
      return void 0;
    }
    const parentTypeName = parentType.name;
    let newSelections = [];
    let isTypenameSelected = false;
    for (const selection of node.selections) {
      if (selection.kind !== Kind.FIELD) {
        newSelections.push(selection);
        continue;
      }
      if (selection.name.value === "__typename" && (!selection.alias || selection.alias.value === "__typename")) {
        isTypenameSelected = true;
      }
      const newName = selection.name.value;
      let transformedSelection;
      if (this.fieldNodeTransformer == null) {
        transformedSelection = selection;
      } else {
        transformedSelection = this.fieldNodeTransformer(
          parentTypeName,
          newName,
          selection,
          fragments,
          transformationContext
        );
        transformedSelection = transformedSelection === void 0 ? selection : transformedSelection;
      }
      if (transformedSelection == null) {
        continue;
      } else if (Array.isArray(transformedSelection)) {
        newSelections = newSelections.concat(transformedSelection);
        continue;
      } else if (transformedSelection.kind !== Kind.FIELD) {
        newSelections.push(transformedSelection);
        continue;
      }
      const typeMapping = this.mapping[parentTypeName];
      if (typeMapping == null) {
        newSelections.push(transformedSelection);
        continue;
      }
      const oldName = this.mapping[parentTypeName][newName];
      if (oldName == null) {
        newSelections.push(transformedSelection);
        continue;
      }
      newSelections.push({
        ...transformedSelection,
        name: {
          kind: Kind.NAME,
          value: oldName
        },
        alias: {
          kind: Kind.NAME,
          value: transformedSelection.alias?.value ?? newName
        }
      });
    }
    if (!isTypenameSelected && (this.dataTransformer != null || this.errorsTransformer != null) && (this.subscriptionTypeName == null || parentTypeName !== this.subscriptionTypeName)) {
      newSelections.push({
        kind: Kind.FIELD,
        name: {
          kind: Kind.NAME,
          value: "__typename"
        }
      });
    }
    return {
      ...node,
      selections: newSelections
    };
  }
}

class TransformObjectFields {
  objectFieldTransformer;
  fieldNodeTransformer;
  transformer;
  constructor(objectFieldTransformer, fieldNodeTransformer) {
    this.objectFieldTransformer = objectFieldTransformer;
    this.fieldNodeTransformer = fieldNodeTransformer;
  }
  _getTransformer() {
    const transformer = this.transformer;
    if (transformer === void 0) {
      throw new Error(
        `The TransformObjectFields transform's  "transformRequest" and "transformResult" methods cannot be used without first calling "transformSchema".`
      );
    }
    return transformer;
  }
  transformSchema(originalWrappingSchema, subschemaConfig) {
    const compositeToObjectFieldTransformer = (typeName, fieldName, fieldConfig) => {
      if (isObjectType(originalWrappingSchema.getType(typeName))) {
        return this.objectFieldTransformer(typeName, fieldName, fieldConfig);
      }
      return void 0;
    };
    this.transformer = new TransformCompositeFields(
      compositeToObjectFieldTransformer,
      this.fieldNodeTransformer
    );
    return this.transformer.transformSchema(
      originalWrappingSchema,
      subschemaConfig
    );
  }
  transformRequest(originalRequest, delegationContext, transformationContext) {
    return this._getTransformer().transformRequest(
      originalRequest,
      delegationContext,
      transformationContext
    );
  }
  transformResult(originalResult, delegationContext, transformationContext) {
    return this._getTransformer().transformResult(
      originalResult,
      delegationContext,
      transformationContext
    );
  }
}

class TransformRootFields {
  rootFieldTransformer;
  fieldNodeTransformer;
  transformer;
  constructor(rootFieldTransformer, fieldNodeTransformer) {
    this.rootFieldTransformer = rootFieldTransformer;
    this.fieldNodeTransformer = fieldNodeTransformer;
  }
  _getTransformer() {
    const transformer = this.transformer;
    if (transformer === void 0) {
      throw new Error(
        `The TransformRootFields transform's  "transformRequest" and "transformResult" methods cannot be used without first calling "transformSchema".`
      );
    }
    return transformer;
  }
  transformSchema(originalWrappingSchema, subschemaConfig) {
    const rootToObjectFieldTransformer = (typeName, fieldName, fieldConfig) => {
      if (typeName === originalWrappingSchema.getQueryType()?.name) {
        return this.rootFieldTransformer("Query", fieldName, fieldConfig);
      }
      if (typeName === originalWrappingSchema.getMutationType()?.name) {
        return this.rootFieldTransformer("Mutation", fieldName, fieldConfig);
      }
      if (typeName === originalWrappingSchema.getSubscriptionType()?.name) {
        return this.rootFieldTransformer(
          "Subscription",
          fieldName,
          fieldConfig
        );
      }
      return void 0;
    };
    this.transformer = new TransformObjectFields(
      rootToObjectFieldTransformer,
      this.fieldNodeTransformer
    );
    return this.transformer.transformSchema(
      originalWrappingSchema,
      subschemaConfig
    );
  }
  transformRequest(originalRequest, delegationContext, transformationContext) {
    return this._getTransformer().transformRequest(
      originalRequest,
      delegationContext,
      transformationContext
    );
  }
  transformResult(originalResult, delegationContext, transformationContext) {
    return this._getTransformer().transformResult(
      originalResult,
      delegationContext,
      transformationContext
    );
  }
}

class RenameRootFields {
  transformer;
  constructor(renamer) {
    this.transformer = new TransformRootFields(
      (operation, fieldName, fieldConfig) => [renamer(operation, fieldName, fieldConfig), fieldConfig]
    );
  }
  transformSchema(originalWrappingSchema, subschemaConfig) {
    return this.transformer.transformSchema(
      originalWrappingSchema,
      subschemaConfig
    );
  }
  transformRequest(originalRequest, delegationContext, transformationContext) {
    return this.transformer.transformRequest(
      originalRequest,
      delegationContext,
      transformationContext
    );
  }
}

class FilterRootFields {
  transformer;
  constructor(filter) {
    this.transformer = new TransformRootFields(
      (operation, fieldName, fieldConfig) => {
        if (filter(operation, fieldName, fieldConfig)) {
          return void 0;
        }
        return null;
      }
    );
  }
  transformSchema(originalWrappingSchema, subschemaConfig) {
    return this.transformer.transformSchema(
      originalWrappingSchema,
      subschemaConfig
    );
  }
}

class RenameObjectFields {
  transformer;
  constructor(renamer) {
    this.transformer = new TransformObjectFields(
      (typeName, fieldName, fieldConfig) => [renamer(typeName, fieldName, fieldConfig), fieldConfig]
    );
  }
  transformSchema(originalWrappingSchema, subschemaConfig) {
    return this.transformer.transformSchema(
      originalWrappingSchema,
      subschemaConfig
    );
  }
  transformRequest(originalRequest, delegationContext, transformationContext) {
    return this.transformer.transformRequest(
      originalRequest,
      delegationContext,
      transformationContext
    );
  }
}

class RenameObjectFieldArguments {
  renamer;
  transformer;
  reverseMap;
  transformedSchema;
  constructor(renamer) {
    this.renamer = renamer;
    this.transformer = new TransformObjectFields(
      (typeName, fieldName, fieldConfig) => {
        const argsConfig = Object.fromEntries(
          Object.entries(fieldConfig.args || []).map(([argName, conf]) => {
            const newName = renamer(typeName, fieldName, argName);
            if (newName !== void 0 && newName !== argName) {
              if (newName != null) {
                return [newName, conf];
              }
            }
            return [argName, conf];
          })
        );
        return [fieldName, { ...fieldConfig, args: argsConfig }];
      },
      (typeName, fieldName, inputFieldNode) => {
        if (!(typeName in this.reverseMap)) {
          return inputFieldNode;
        }
        if (!(fieldName in this.reverseMap[typeName])) {
          return inputFieldNode;
        }
        const fieldNameMap = this.reverseMap[typeName][fieldName];
        return {
          ...inputFieldNode,
          arguments: (inputFieldNode.arguments || []).map((argNode) => {
            return argNode.name.value in fieldNameMap ? {
              ...argNode,
              name: {
                ...argNode.name,
                value: fieldNameMap[argNode.name.value]
              }
            } : argNode;
          })
        };
      }
    );
    this.reverseMap = /* @__PURE__ */ Object.create(null);
  }
  transformSchema(originalWrappingSchema, subschemaConfig) {
    mapSchema(originalWrappingSchema, {
      [MapperKind.OBJECT_FIELD]: (fieldConfig, fieldName, typeName) => {
        Object.entries(fieldConfig.args || {}).forEach(([argName]) => {
          const newName = this.renamer(typeName, fieldName, argName);
          if (newName !== void 0 && newName !== fieldName) {
            if (this.reverseMap[typeName] == null) {
              this.reverseMap[typeName] = /* @__PURE__ */ Object.create(null);
            }
            if (this.reverseMap[typeName][fieldName] == null) {
              this.reverseMap[typeName][fieldName] = /* @__PURE__ */ Object.create(null);
            }
            this.reverseMap[typeName][fieldName][newName] = argName;
          }
        });
        return void 0;
      },
      [MapperKind.ROOT_OBJECT]() {
        return void 0;
      }
    });
    this.transformedSchema = this.transformer.transformSchema(
      originalWrappingSchema,
      subschemaConfig
    );
    return this.transformedSchema;
  }
  transformRequest(originalRequest, delegationContext, transformationContext) {
    return this.transformer.transformRequest(
      originalRequest,
      delegationContext,
      transformationContext
    );
  }
}

class FilterObjectFields {
  transformer;
  constructor(filter) {
    this.transformer = new TransformObjectFields(
      (typeName, fieldName, fieldConfig) => filter(typeName, fieldName, fieldConfig) ? void 0 : null
    );
  }
  transformSchema(originalWrappingSchema, subschemaConfig) {
    return this.transformer.transformSchema(
      originalWrappingSchema,
      subschemaConfig
    );
  }
}

class TransformInterfaceFields {
  interfaceFieldTransformer;
  fieldNodeTransformer;
  transformer;
  constructor(interfaceFieldTransformer, fieldNodeTransformer) {
    this.interfaceFieldTransformer = interfaceFieldTransformer;
    this.fieldNodeTransformer = fieldNodeTransformer;
  }
  _getTransformer() {
    const transformer = this.transformer;
    if (transformer === void 0) {
      throw new Error(
        `The TransformInterfaceFields transform's  "transformRequest" and "transformResult" methods cannot be used without first calling "transformSchema".`
      );
    }
    return transformer;
  }
  transformSchema(originalWrappingSchema, subschemaConfig) {
    const compositeToObjectFieldTransformer = (typeName, fieldName, fieldConfig) => {
      if (isInterfaceType(originalWrappingSchema.getType(typeName))) {
        return this.interfaceFieldTransformer(typeName, fieldName, fieldConfig);
      }
      return void 0;
    };
    this.transformer = new TransformCompositeFields(
      compositeToObjectFieldTransformer,
      this.fieldNodeTransformer
    );
    return this.transformer.transformSchema(
      originalWrappingSchema,
      subschemaConfig
    );
  }
  transformRequest(originalRequest, delegationContext, transformationContext) {
    return this._getTransformer().transformRequest(
      originalRequest,
      delegationContext,
      transformationContext
    );
  }
  transformResult(originalResult, delegationContext, transformationContext) {
    return this._getTransformer().transformResult(
      originalResult,
      delegationContext,
      transformationContext
    );
  }
}

class RenameInterfaceFields {
  transformer;
  constructor(renamer) {
    this.transformer = new TransformInterfaceFields(
      (typeName, fieldName, fieldConfig) => [renamer(typeName, fieldName, fieldConfig), fieldConfig]
    );
  }
  transformSchema(originalWrappingSchema, subschemaConfig) {
    return this.transformer.transformSchema(
      originalWrappingSchema,
      subschemaConfig
    );
  }
  transformRequest(originalRequest, delegationContext, transformationContext) {
    return this.transformer.transformRequest(
      originalRequest,
      delegationContext,
      transformationContext
    );
  }
}

class FilterInterfaceFields {
  transformer;
  constructor(filter) {
    this.transformer = new TransformInterfaceFields(
      (typeName, fieldName, fieldConfig) => filter(typeName, fieldName, fieldConfig) ? void 0 : null
    );
  }
  transformSchema(originalWrappingSchema, subschemaConfig) {
    return this.transformer.transformSchema(
      originalWrappingSchema,
      subschemaConfig
    );
  }
}

class TransformInputObjectFields {
  inputFieldTransformer;
  inputFieldNodeTransformer;
  inputObjectNodeTransformer;
  transformedSchema;
  mapping;
  constructor(inputFieldTransformer, inputFieldNodeTransformer, inputObjectNodeTransformer) {
    this.inputFieldTransformer = inputFieldTransformer;
    this.inputFieldNodeTransformer = inputFieldNodeTransformer;
    this.inputObjectNodeTransformer = inputObjectNodeTransformer;
    this.mapping = {};
  }
  _getTransformedSchema() {
    const transformedSchema = this.transformedSchema;
    if (transformedSchema === void 0) {
      throw new Error(
        `The TransformInputObjectFields transform's  "transformRequest" and "transformResult" methods cannot be used without first calling "transformSchema".`
      );
    }
    return transformedSchema;
  }
  transformSchema(originalWrappingSchema, _subschemaConfig) {
    this.transformedSchema = mapSchema(originalWrappingSchema, {
      [MapperKind.INPUT_OBJECT_FIELD]: (inputFieldConfig, fieldName, typeName) => {
        const transformedInputField = this.inputFieldTransformer(
          typeName,
          fieldName,
          inputFieldConfig
        );
        if (Array.isArray(transformedInputField)) {
          const newFieldName = transformedInputField[0];
          if (newFieldName !== fieldName) {
            if (!this.mapping[typeName]) {
              this.mapping[typeName] = {};
            }
            this.mapping[typeName][newFieldName] = fieldName;
          }
        }
        return transformedInputField;
      }
    });
    return this.transformedSchema;
  }
  transformRequest(originalRequest, _delegationContext, _transformationContext) {
    const variableValues = originalRequest.variables ?? {};
    const fragments = /* @__PURE__ */ Object.create(null);
    const operations = [];
    for (const def of originalRequest.document.definitions) {
      if (def.kind === Kind.OPERATION_DEFINITION) {
        operations.push(def);
      } else if (def.kind === Kind.FRAGMENT_DEFINITION) {
        fragments[def.name.value] = def;
      }
    }
    for (const def of operations) {
      const variableDefs = def.variableDefinitions;
      if (variableDefs != null) {
        for (const variableDef of variableDefs) {
          const varName = variableDef.variable.name.value;
          if (!this.transformedSchema) {
            continue;
          }
          const varType = typeFromAST(
            this.transformedSchema,
            variableDef.type
          );
          if (!isInputType(varType)) {
            continue;
          }
          variableValues[varName] = transformInputValue(
            varType,
            variableValues[varName],
            void 0,
            (type, originalValue) => {
              const newValue = /* @__PURE__ */ Object.create(null);
              const fields = type.getFields();
              for (const key in originalValue) {
                const field = fields[key];
                if (field != null) {
                  const newFieldName = this.mapping[type.name]?.[field.name];
                  if (newFieldName != null) {
                    newValue[newFieldName] = originalValue[field.name];
                  } else {
                    newValue[field.name] = originalValue[field.name];
                  }
                }
              }
              return newValue;
            }
          );
        }
      }
    }
    for (const def of originalRequest.document.definitions.filter(
      (def2) => def2.kind === Kind.FRAGMENT_DEFINITION
    )) {
      fragments[def.name.value] = def;
    }
    const document = this.transformDocument(
      originalRequest.document,
      this.mapping,
      this.inputFieldNodeTransformer,
      this.inputObjectNodeTransformer,
      originalRequest
    );
    return {
      ...originalRequest,
      document,
      variables: variableValues
    };
  }
  transformDocument(document, mapping, inputFieldNodeTransformer, inputObjectNodeTransformer, request) {
    const typeInfo = getTypeInfo(this._getTransformedSchema());
    const newDocument = visit(
      document,
      visitWithTypeInfo(typeInfo, {
        [Kind.OBJECT]: {
          leave: (node) => {
            const parentType = typeInfo.getInputType();
            if (parentType != null) {
              const parentTypeName = getNamedType(parentType).name;
              const newInputFields = [];
              for (const inputField of node.fields) {
                const newName = inputField.name.value;
                const transformedInputField = inputFieldNodeTransformer != null ? inputFieldNodeTransformer(
                  parentTypeName,
                  newName,
                  inputField,
                  request
                ) : inputField;
                if (Array.isArray(transformedInputField)) {
                  for (const individualTransformedInputField of transformedInputField) {
                    const typeMapping2 = mapping[parentTypeName];
                    if (typeMapping2 == null) {
                      newInputFields.push(individualTransformedInputField);
                      continue;
                    }
                    const oldName2 = typeMapping2[newName];
                    if (oldName2 == null) {
                      newInputFields.push(individualTransformedInputField);
                      continue;
                    }
                    newInputFields.push({
                      ...individualTransformedInputField,
                      name: {
                        ...individualTransformedInputField.name,
                        value: oldName2
                      }
                    });
                  }
                  continue;
                }
                const typeMapping = mapping[parentTypeName];
                if (typeMapping == null) {
                  newInputFields.push(transformedInputField);
                  continue;
                }
                const oldName = typeMapping[newName];
                if (oldName == null) {
                  newInputFields.push(transformedInputField);
                  continue;
                }
                newInputFields.push({
                  ...transformedInputField,
                  name: {
                    ...transformedInputField.name,
                    value: oldName
                  }
                });
              }
              const newNode = {
                ...node,
                fields: newInputFields
              };
              return inputObjectNodeTransformer != null ? inputObjectNodeTransformer(parentTypeName, newNode, request) : newNode;
            }
          }
        }
      })
    );
    return newDocument;
  }
}

class RenameInputObjectFields {
  renamer;
  transformer;
  reverseMap;
  constructor(renamer) {
    this.renamer = renamer;
    this.transformer = new TransformInputObjectFields(
      (typeName, inputFieldName, inputFieldConfig) => {
        const newName = renamer(typeName, inputFieldName, inputFieldConfig);
        if (newName !== void 0 && newName !== inputFieldName) {
          const value = renamer(typeName, inputFieldName, inputFieldConfig);
          if (value != null) {
            return [value, inputFieldConfig];
          }
        }
        return void 0;
      },
      (typeName, inputFieldName, inputFieldNode) => {
        if (!(typeName in this.reverseMap)) {
          return inputFieldNode;
        }
        const inputFieldNameMap = this.reverseMap[typeName];
        if (!(inputFieldName in inputFieldNameMap)) {
          return inputFieldNode;
        }
        return {
          ...inputFieldNode,
          name: {
            ...inputFieldNode.name,
            value: inputFieldNameMap[inputFieldName]
          }
        };
      }
    );
    this.reverseMap = /* @__PURE__ */ Object.create(null);
  }
  transformSchema(originalWrappingSchema, subschemaConfig) {
    mapSchema(originalWrappingSchema, {
      [MapperKind.INPUT_OBJECT_FIELD]: (inputFieldConfig, fieldName, typeName) => {
        const newName = this.renamer(typeName, fieldName, inputFieldConfig);
        if (newName !== void 0 && newName !== fieldName) {
          if (this.reverseMap[typeName] == null) {
            this.reverseMap[typeName] = /* @__PURE__ */ Object.create(null);
          }
          this.reverseMap[typeName][newName] = fieldName;
        }
        return void 0;
      },
      [MapperKind.ROOT_OBJECT]() {
        return void 0;
      }
    });
    return this.transformer.transformSchema(
      originalWrappingSchema,
      subschemaConfig
    );
  }
  transformRequest(originalRequest, delegationContext, transformationContext) {
    return this.transformer.transformRequest(
      originalRequest,
      delegationContext,
      transformationContext
    );
  }
}

class FilterInputObjectFields {
  transformer;
  constructor(filter, inputObjectNodeTransformer) {
    this.transformer = new TransformInputObjectFields(
      (typeName, fieldName, inputFieldConfig) => filter(typeName, fieldName, inputFieldConfig) ? void 0 : null,
      void 0,
      inputObjectNodeTransformer
    );
  }
  transformSchema(originalWrappingSchema, subschemaConfig) {
    return this.transformer.transformSchema(
      originalWrappingSchema,
      subschemaConfig
    );
  }
  transformRequest(originalRequest, delegationContext, transformationContext) {
    return this.transformer.transformRequest(
      originalRequest,
      delegationContext,
      transformationContext
    );
  }
}

class MapLeafValues {
  inputValueTransformer;
  outputValueTransformer;
  resultVisitorMap;
  typeInfo;
  constructor(inputValueTransformer, outputValueTransformer) {
    this.inputValueTransformer = inputValueTransformer;
    this.outputValueTransformer = outputValueTransformer;
    this.resultVisitorMap = /* @__PURE__ */ Object.create(null);
  }
  originalWrappingSchema;
  transformSchema(originalWrappingSchema, _subschemaConfig) {
    this.originalWrappingSchema = originalWrappingSchema;
    const typeMap = originalWrappingSchema.getTypeMap();
    for (const typeName in typeMap) {
      const type = typeMap[typeName];
      if (!typeName.startsWith("__")) {
        if (isLeafType(type)) {
          this.resultVisitorMap[typeName] = (value) => this.outputValueTransformer(typeName, value);
        }
      }
    }
    this.typeInfo = getTypeInfo(originalWrappingSchema);
    return originalWrappingSchema;
  }
  transformRequest(originalRequest, _delegationContext, transformationContext) {
    const document = originalRequest.document;
    const variableValues = originalRequest.variables ?? {};
    const operations = document.definitions.filter(
      (def) => def.kind === Kind.OPERATION_DEFINITION
    );
    const fragments = document.definitions.filter(
      (def) => def.kind === Kind.FRAGMENT_DEFINITION
    );
    const newOperations = this.transformOperations(operations, variableValues);
    const transformedRequest = {
      ...originalRequest,
      document: {
        ...document,
        definitions: [...newOperations, ...fragments]
      },
      variables: variableValues
    };
    transformationContext.transformedRequest = transformedRequest;
    return transformedRequest;
  }
  transformResult(originalResult, _delegationContext, transformationContext) {
    if (!this.originalWrappingSchema) {
      throw new Error(
        `The MapLeafValues transform's  "transformRequest" and "transformResult" methods cannot be used without first calling "transformSchema".`
      );
    }
    return visitResult(
      originalResult,
      transformationContext.transformedRequest,
      this.originalWrappingSchema,
      this.resultVisitorMap
    );
  }
  transformOperations(operations, variableValues) {
    if (this.typeInfo == null) {
      throw new Error(
        `The MapLeafValues transform's "transformRequest" and "transformResult" methods cannot be used without first calling "transformSchema".`
      );
    }
    return operations.map((operation) => {
      return visit(
        operation,
        visitWithTypeInfo(this.typeInfo, {
          [Kind.FIELD]: (node) => this.transformFieldNode(node, variableValues)
        })
      );
    });
  }
  transformFieldNode(field, variableValues) {
    if (this.typeInfo == null) {
      throw new Error(
        `The MapLeafValues transform's "transformRequest" and "transformResult" methods cannot be used without first calling "transformSchema".`
      );
    }
    const targetField = this.typeInfo.getFieldDef();
    if (!targetField) {
      return;
    }
    if (!targetField.name.startsWith("__")) {
      const argumentNodes = field.arguments;
      if (argumentNodes != null) {
        const argumentNodeMap = argumentNodes.reduce(
          (prev, argument) => ({
            ...prev,
            [argument.name.value]: argument
          }),
          /* @__PURE__ */ Object.create(null)
        );
        for (const argument of targetField.args) {
          const argName = argument.name;
          const argType = argument.type;
          const argumentNode = argumentNodeMap[argName];
          let value;
          const argValue = argumentNode?.value;
          if (argValue != null) {
            value = valueFromAST(argValue, argType, variableValues);
            if (value == null) {
              value = valueFromASTUntyped(argValue, variableValues);
            }
          }
          const transformedValue = transformInputValue(
            argType,
            value,
            (t, v) => {
              const newValue = this.inputValueTransformer(t.name, v);
              return newValue === void 0 ? v : newValue;
            }
          );
          if (argValue?.kind === Kind.VARIABLE) {
            variableValues[argValue.name.value] = transformedValue;
          } else {
            let newValueNode;
            try {
              newValueNode = astFromValue(transformedValue, argType);
            } catch (e) {
              newValueNode = astFromValueUntyped(transformedValue);
            }
            if (newValueNode != null) {
              argumentNodeMap[argName] = {
                ...argumentNode,
                value: newValueNode
              };
            }
          }
        }
        return {
          ...field,
          arguments: Object.values(argumentNodeMap)
        };
      }
    }
    return void 0;
  }
}

class TransformEnumValues {
  enumValueTransformer;
  transformer;
  transformedSchema;
  mapping;
  reverseMapping;
  noTransformation = true;
  constructor(enumValueTransformer, inputValueTransformer, outputValueTransformer) {
    this.enumValueTransformer = enumValueTransformer;
    this.mapping = /* @__PURE__ */ Object.create(null);
    this.reverseMapping = /* @__PURE__ */ Object.create(null);
    this.transformer = new MapLeafValues(
      generateValueTransformer(inputValueTransformer, this.reverseMapping),
      generateValueTransformer(outputValueTransformer, this.mapping)
    );
  }
  transformSchema(originalWrappingSchema, subschemaConfig) {
    const mappingSchema = this.transformer.transformSchema(
      originalWrappingSchema,
      subschemaConfig
    );
    this.transformedSchema = mapSchema(mappingSchema, {
      [MapperKind.ENUM_VALUE]: (valueConfig, typeName, _schema, externalValue) => this.transformEnumValue(typeName, externalValue, valueConfig),
      [MapperKind.ARGUMENT]: (argConfig) => {
        if (argConfig.defaultValue != null) {
          const newValue = transformInputValue(
            argConfig.type,
            argConfig.defaultValue,
            (type, value) => {
              return this.mapping[type.name]?.[value] ?? value;
            }
          );
          return {
            ...argConfig,
            defaultValue: newValue
          };
        }
        return void 0;
      }
    });
    return this.transformedSchema;
  }
  transformRequest(originalRequest, delegationContext, transformationContext) {
    if (this.noTransformation) {
      return originalRequest;
    }
    return this.transformer.transformRequest(
      originalRequest,
      delegationContext,
      transformationContext
    );
  }
  transformResult(originalResult, delegationContext, transformationContext) {
    if (this.noTransformation) {
      return originalResult;
    }
    return this.transformer.transformResult(
      originalResult,
      delegationContext,
      transformationContext
    );
  }
  transformEnumValue(typeName, externalValue, enumValueConfig) {
    const transformedEnumValue = this.enumValueTransformer(
      typeName,
      externalValue,
      enumValueConfig
    );
    if (Array.isArray(transformedEnumValue)) {
      const newExternalValue = transformedEnumValue[0];
      if (newExternalValue !== externalValue) {
        if (!this.mapping[typeName]) {
          this.mapping[typeName] = /* @__PURE__ */ Object.create(null);
          this.reverseMapping[typeName] = /* @__PURE__ */ Object.create(null);
        }
        this.mapping[typeName][externalValue] = newExternalValue;
        this.reverseMapping[typeName][newExternalValue] = externalValue;
        this.noTransformation = false;
      }
      return [
        newExternalValue,
        {
          ...transformedEnumValue[1],
          value: void 0
        }
      ];
    }
    return {
      ...transformedEnumValue,
      value: void 0
    };
  }
}
function mapEnumValues(typeName, value, mapping) {
  const newExternalValue = mapping[typeName]?.[value];
  return newExternalValue != null ? newExternalValue : value;
}
function generateValueTransformer(valueTransformer, mapping) {
  if (valueTransformer == null) {
    return (typeName, value) => mapEnumValues(typeName, value, mapping);
  } else {
    return (typeName, value) => mapEnumValues(typeName, valueTransformer(typeName, value), mapping);
  }
}

class TransformQuery {
  path;
  queryTransformer;
  resultTransformer;
  errorPathTransformer;
  fragments;
  constructor({
    path,
    queryTransformer,
    resultTransformer = (result) => result,
    errorPathTransformer = (errorPath) => [...errorPath],
    fragments = {}
  }) {
    this.path = path;
    const pollutingKeys = this.path.filter(isPrototypePollutingKey);
    if (pollutingKeys.length > 0) {
      throw new TypeError(
        `Invalid path - cannot be a prototype polluting keys: ${pollutingKeys.join(".")}`
      );
    }
    this.queryTransformer = queryTransformer;
    this.resultTransformer = resultTransformer;
    this.errorPathTransformer = errorPathTransformer;
    this.fragments = fragments;
  }
  transformRequest(originalRequest, delegationContext, transformationContext) {
    const pathLength = this.path.length;
    let index = 0;
    const operationAst = getOperationASTFromRequest(originalRequest);
    const document = {
      kind: Kind.DOCUMENT,
      definitions: originalRequest.document.definitions.map((def) => {
        if (def === operationAst) {
          return visit(def, {
            [Kind.FIELD]: {
              enter: (node) => {
                if (index === pathLength || node.name.value !== this.path[index]) {
                  return false;
                }
                index++;
                if (index === pathLength) {
                  const selectionSet = this.queryTransformer(
                    node.selectionSet,
                    this.fragments,
                    delegationContext,
                    transformationContext
                  );
                  return {
                    ...node,
                    selectionSet
                  };
                }
                return void 0;
              },
              leave: () => {
                index--;
              }
            }
          });
        }
        return def;
      })
    };
    return {
      ...originalRequest,
      document
    };
  }
  transformResult(originalResult, delegationContext, transformationContext) {
    const data = this.transformData(
      originalResult.data,
      delegationContext,
      transformationContext
    );
    const errors = originalResult.errors;
    return {
      data,
      errors: errors != null ? this.transformErrors(errors) : void 0
    };
  }
  transformData(data, delegationContext, transformationContext) {
    const leafIndex = this.path.length - 1;
    let index = 0;
    let newData = data;
    if (newData) {
      let next = this.path[index];
      while (index < leafIndex) {
        if (data[next]) {
          newData = newData[next];
        } else {
          break;
        }
        index++;
        next = this.path[index];
      }
      newData[next] = this.resultTransformer(
        newData[next],
        delegationContext,
        transformationContext
      );
    }
    return data;
  }
  transformErrors(errors) {
    return errors.map((error) => {
      const path = error.path;
      if (path == null) {
        return error;
      }
      let match = true;
      let index = 0;
      while (index < this.path.length) {
        if (path[index] !== this.path[index]) {
          match = false;
          break;
        }
        index++;
      }
      const newPath = match ? path.slice(0, index).concat(this.errorPathTransformer(path.slice(index))) : path;
      return relocatedError(error, newPath);
    });
  }
}

class FilterObjectFieldDirectives {
  filter;
  constructor(filter) {
    this.filter = filter;
  }
  transformSchema(originalWrappingSchema, subschemaConfig) {
    const transformer = new TransformObjectFields(
      (_typeName, _fieldName, fieldConfig) => {
        const keepDirectives = fieldConfig.astNode?.directives?.filter((dir) => {
          const directiveDef = originalWrappingSchema.getDirective(
            dir.name.value
          );
          const directiveValue = directiveDef ? getArgumentValues(directiveDef, dir) : void 0;
          return this.filter(dir.name.value, directiveValue);
        }) ?? [];
        if (fieldConfig.astNode?.directives != null && keepDirectives.length !== fieldConfig.astNode.directives.length) {
          fieldConfig = {
            ...fieldConfig,
            astNode: {
              ...fieldConfig.astNode,
              directives: keepDirectives
            }
          };
          return fieldConfig;
        }
        return void 0;
      }
    );
    return transformer.transformSchema(originalWrappingSchema, subschemaConfig);
  }
}

class RemoveObjectFieldDirectives {
  transformer;
  constructor(directiveName, args = {}) {
    this.transformer = new FilterObjectFieldDirectives(
      (dirName, dirValue) => {
        return !(valueMatchesCriteria(dirName, directiveName) && valueMatchesCriteria(dirValue, args));
      }
    );
  }
  transformSchema(originalWrappingSchema, subschemaConfig) {
    return this.transformer.transformSchema(
      originalWrappingSchema,
      subschemaConfig
    );
  }
}

class RemoveObjectFieldsWithDirective {
  directiveName;
  args;
  constructor(directiveName, args = {}) {
    this.directiveName = directiveName;
    this.args = args;
  }
  transformSchema(originalWrappingSchema, subschemaConfig) {
    const transformer = new FilterObjectFields(
      (_typeName, _fieldName, fieldConfig) => {
        const directives = getDirectives(originalWrappingSchema, fieldConfig);
        return !directives.some(
          (directive) => valueMatchesCriteria(directive.name, this.directiveName) && valueMatchesCriteria(directive.args, this.args)
        );
      }
    );
    return transformer.transformSchema(originalWrappingSchema, subschemaConfig);
  }
}

class RemoveObjectFieldDeprecations {
  removeDirectives;
  removeDeprecations;
  constructor(reason) {
    const args = { reason };
    this.removeDirectives = new FilterObjectFieldDirectives(
      (dirName, dirValue) => {
        return !(dirName === "deprecated" && valueMatchesCriteria(dirValue, args));
      }
    );
    this.removeDeprecations = new TransformObjectFields(
      (_typeName, _fieldName, fieldConfig) => {
        if (fieldConfig.deprecationReason && valueMatchesCriteria(fieldConfig.deprecationReason, reason)) {
          fieldConfig = { ...fieldConfig };
          delete fieldConfig.deprecationReason;
        }
        return fieldConfig;
      }
    );
  }
  transformSchema(originalWrappingSchema, subschemaConfig) {
    return this.removeDeprecations.transformSchema(
      this.removeDirectives.transformSchema(
        originalWrappingSchema,
        subschemaConfig
      ),
      subschemaConfig
    );
  }
}

class RemoveObjectFieldsWithDeprecation {
  transformer;
  constructor(reason) {
    this.transformer = new FilterObjectFields(
      (_typeName, _fieldName, fieldConfig) => {
        if (fieldConfig.deprecationReason) {
          return !valueMatchesCriteria(fieldConfig.deprecationReason, reason);
        }
        return true;
      }
    );
  }
  transformSchema(originalWrappingSchema, subschemaConfig) {
    return this.transformer.transformSchema(
      originalWrappingSchema,
      subschemaConfig
    );
  }
}

class PruneTypes {
  options;
  constructor(options = {}) {
    this.options = options;
  }
  transformSchema(originalWrappingSchema, _subschemaConfig) {
    return pruneSchema(originalWrappingSchema, this.options);
  }
}

class MapFields {
  fieldNodeTransformerMap;
  objectValueTransformerMap;
  errorsTransformer;
  transformer;
  constructor(fieldNodeTransformerMap, objectValueTransformerMap, errorsTransformer) {
    this.fieldNodeTransformerMap = fieldNodeTransformerMap;
    this.objectValueTransformerMap = objectValueTransformerMap;
    this.errorsTransformer = errorsTransformer;
  }
  _getTransformer() {
    const transformer = this.transformer;
    if (transformer === void 0) {
      throw new Error(
        `The MapFields transform's  "transformRequest" and "transformResult" methods cannot be used without first calling "transformSchema".`
      );
    }
    return transformer;
  }
  transformSchema(originalWrappingSchema, subschemaConfig) {
    const subscriptionTypeName = originalWrappingSchema.getSubscriptionType()?.name;
    const objectValueTransformerMap = this.objectValueTransformerMap;
    this.transformer = new TransformCompositeFields(
      () => void 0,
      (typeName, fieldName, fieldNode, fragments, transformationContext) => {
        const typeTransformers = this.fieldNodeTransformerMap[typeName];
        if (typeTransformers == null) {
          return void 0;
        }
        const fieldNodeTransformer = typeTransformers[fieldName];
        if (fieldNodeTransformer == null) {
          return void 0;
        }
        return fieldNodeTransformer(
          fieldNode,
          fragments,
          transformationContext
        );
      },
      objectValueTransformerMap != null ? (data, transformationContext) => {
        if (data == null) {
          return data;
        }
        let typeName = data.__typename;
        if (typeName == null) {
          typeName = subscriptionTypeName;
          if (typeName == null) {
            return data;
          }
        }
        const transformer = objectValueTransformerMap[typeName];
        if (transformer == null) {
          return data;
        }
        return transformer(data, transformationContext);
      } : void 0,
      this.errorsTransformer != null ? this.errorsTransformer : void 0
    );
    return this.transformer.transformSchema(
      originalWrappingSchema,
      subschemaConfig
    );
  }
  transformRequest(originalRequest, delegationContext, transformationContext) {
    return this._getTransformer().transformRequest(
      originalRequest,
      delegationContext,
      transformationContext
    );
  }
  transformResult(originalResult, delegationContext, transformationContext) {
    return this._getTransformer().transformResult(
      originalResult,
      delegationContext,
      transformationContext
    );
  }
}

class WrapFields {
  outerTypeName;
  wrappingFieldNames;
  wrappingTypeNames;
  numWraps;
  fieldNames;
  transformer;
  config;
  constructor(outerTypeName, wrappingFieldNames, wrappingTypeNames, fieldNames, prefix = "gqtld", config = { isNullable: false }) {
    this.outerTypeName = outerTypeName;
    this.wrappingFieldNames = wrappingFieldNames;
    this.wrappingTypeNames = wrappingTypeNames;
    this.numWraps = wrappingFieldNames.length;
    this.fieldNames = fieldNames;
    this.config = config;
    const remainingWrappingFieldNames = this.wrappingFieldNames.slice();
    const outerMostWrappingFieldName = remainingWrappingFieldNames.shift();
    if (outerMostWrappingFieldName == null) {
      throw new Error(`Cannot wrap fields, no wrapping field name provided.`);
    }
    this.transformer = new MapFields(
      {
        [outerTypeName]: {
          [outerMostWrappingFieldName]: (fieldNode, fragments, transformationContext) => hoistFieldNodes({
            fieldNode,
            path: remainingWrappingFieldNames,
            fieldNames,
            fragments,
            transformationContext,
            prefix
          })
        }
      },
      {
        [outerTypeName]: (value, context) => dehoistValue(value, context)
      },
      (errors, context) => dehoistErrors(errors, context)
    );
  }
  transformSchema(originalWrappingSchema, subschemaConfig) {
    const fieldNames = this.fieldNames;
    const targetFieldConfigMap = selectObjectFields(
      originalWrappingSchema,
      this.outerTypeName,
      !fieldNames ? () => true : (fieldName) => fieldNames.includes(fieldName)
    );
    const newTargetFieldConfigMap = /* @__PURE__ */ Object.create(null);
    for (const fieldName in targetFieldConfigMap) {
      const field = targetFieldConfigMap[fieldName];
      const newField = {
        ...field,
        resolve: defaultMergedResolver
      };
      newTargetFieldConfigMap[fieldName] = newField;
    }
    let wrapIndex = this.numWraps - 1;
    let wrappingTypeName = this.wrappingTypeNames[wrapIndex];
    let wrappingFieldName = this.wrappingFieldNames[wrapIndex];
    let newSchema = appendObjectFields(
      originalWrappingSchema,
      wrappingTypeName,
      newTargetFieldConfigMap
    );
    for (wrapIndex--; wrapIndex > -1; wrapIndex--) {
      const nextWrappingTypeName = this.wrappingTypeNames[wrapIndex];
      newSchema = appendObjectFields(newSchema, nextWrappingTypeName, {
        [wrappingFieldName]: {
          type: new GraphQLNonNull(
            newSchema.getType(wrappingTypeName)
          ),
          resolve: defaultMergedResolver
        }
      });
      wrappingTypeName = nextWrappingTypeName;
      wrappingFieldName = this.wrappingFieldNames[wrapIndex];
    }
    const targetSchema = subschemaConfig.schema;
    let wrappingOperation;
    switch (this.outerTypeName) {
      case targetSchema.getQueryType()?.name:
        wrappingOperation = "query";
        break;
      case targetSchema.getMutationType()?.name:
        wrappingOperation = "mutation";
        break;
      case targetSchema.getSubscriptionType()?.name:
        wrappingOperation = "subscription";
        break;
    }
    let resolve;
    if (wrappingOperation) {
      const createProxyingResolver = subschemaConfig.createProxyingResolver ?? defaultCreateProxyingResolver;
      resolve = createProxyingResolver({
        subschemaConfig,
        operation: wrappingOperation,
        fieldName: wrappingFieldName
      });
    } else {
      resolve = defaultMergedResolver;
    }
    const baseType = newSchema.getType(wrappingTypeName);
    const wrappingType = this.config.isNullable ? baseType : new GraphQLNonNull(baseType);
    const newFieldConfig = wrappingOperation === "subscription" ? {
      type: wrappingType,
      subscribe: resolve,
      resolve: (payload) => payload
    } : {
      type: wrappingType,
      resolve
    };
    [newSchema] = modifyObjectFields(
      newSchema,
      this.outerTypeName,
      (fieldName) => !!newTargetFieldConfigMap[fieldName],
      {
        [wrappingFieldName]: newFieldConfig
      }
    );
    return this.transformer.transformSchema(newSchema, subschemaConfig);
  }
  transformRequest(originalRequest, delegationContext, transformationContext) {
    transformationContext.nextIndex = 0;
    transformationContext.paths = /* @__PURE__ */ Object.create(null);
    return this.transformer.transformRequest(
      originalRequest,
      delegationContext,
      transformationContext
    );
  }
  transformResult(originalResult, delegationContext, transformationContext) {
    return this.transformer.transformResult(
      originalResult,
      delegationContext,
      transformationContext
    );
  }
}
function collectFields(selectionSet, fragments, fields = [], visitedFragmentNames = {}) {
  if (selectionSet != null) {
    for (const selection of selectionSet.selections) {
      switch (selection.kind) {
        case Kind.FIELD:
          fields.push(selection);
          break;
        case Kind.INLINE_FRAGMENT:
          collectFields(
            selection.selectionSet,
            fragments,
            fields,
            visitedFragmentNames
          );
          break;
        case Kind.FRAGMENT_SPREAD: {
          const fragmentName = selection.name.value;
          if (!visitedFragmentNames[fragmentName]) {
            visitedFragmentNames[fragmentName] = true;
            collectFields(
              fragments[fragmentName].selectionSet,
              fragments,
              fields,
              visitedFragmentNames
            );
          }
          break;
        }
      }
    }
  }
  return fields;
}
function aliasFieldNode(fieldNode, str) {
  return {
    ...fieldNode,
    alias: {
      kind: Kind.NAME,
      value: str
    }
  };
}
function hoistFieldNodes({
  fieldNode,
  fieldNames,
  path,
  fragments,
  transformationContext,
  prefix,
  index = 0,
  wrappingPath = []
}) {
  const alias = fieldNode.alias != null ? fieldNode.alias.value : fieldNode.name.value;
  let newFieldNodes = [];
  if (index < path.length) {
    const pathSegment = path[index];
    for (const possibleFieldNode of collectFields(
      fieldNode.selectionSet,
      fragments
    )) {
      if (possibleFieldNode.name.value === pathSegment) {
        const newWrappingPath = wrappingPath.concat([alias]);
        newFieldNodes = newFieldNodes.concat(
          hoistFieldNodes({
            fieldNode: possibleFieldNode,
            fieldNames,
            path,
            fragments,
            transformationContext,
            prefix,
            index: index + 1,
            wrappingPath: newWrappingPath
          })
        );
      }
    }
  } else {
    for (const possibleFieldNode of collectFields(
      fieldNode.selectionSet,
      fragments
    )) {
      if (!fieldNames || fieldNames.includes(possibleFieldNode.name.value)) {
        const nextIndex = transformationContext.nextIndex;
        transformationContext.nextIndex++;
        const indexingAlias = `__${prefix}${nextIndex}__`;
        transformationContext.paths[indexingAlias] = {
          pathToField: wrappingPath.concat([alias]),
          alias: possibleFieldNode.alias != null ? possibleFieldNode.alias.value : possibleFieldNode.name.value
        };
        newFieldNodes.push(aliasFieldNode(possibleFieldNode, indexingAlias));
      }
    }
  }
  return newFieldNodes;
}
function dehoistValue(originalValue, context) {
  if (originalValue == null) {
    return originalValue;
  }
  const newValue = /* @__PURE__ */ Object.create(null);
  for (const alias in originalValue) {
    let obj = newValue;
    const path = context.paths[alias];
    if (path == null) {
      newValue[alias] = originalValue[alias];
      continue;
    }
    const pathToField = path.pathToField;
    const fieldAlias = path.alias;
    for (const key of pathToField) {
      obj = obj[key] = obj[key] || /* @__PURE__ */ Object.create(null);
    }
    obj[fieldAlias] = originalValue[alias];
  }
  return newValue;
}
function dehoistErrors(errors, context) {
  if (errors === void 0) {
    return void 0;
  }
  return errors.map((error) => {
    const originalPath = error.path;
    if (originalPath == null) {
      return error;
    }
    let newPath = [];
    for (const pathSegment of originalPath) {
      if (typeof pathSegment !== "string") {
        newPath.push(pathSegment);
        continue;
      }
      const path = context.paths[pathSegment];
      if (path == null) {
        newPath.push(pathSegment);
        continue;
      }
      newPath = newPath.concat(path.pathToField, [path.alias]);
    }
    return relocatedError(error, newPath);
  });
}

class WrapType {
  transformer;
  constructor(outerTypeName, innerTypeName, fieldName) {
    this.transformer = new WrapFields(
      outerTypeName,
      [fieldName],
      [innerTypeName]
    );
  }
  transformSchema(originalWrappingSchema, subschemaConfig) {
    return this.transformer.transformSchema(
      originalWrappingSchema,
      subschemaConfig
    );
  }
  transformRequest(originalRequest, delegationContext, transformationContext) {
    return this.transformer.transformRequest(
      originalRequest,
      delegationContext,
      transformationContext
    );
  }
  transformResult(originalResult, delegationContext, transformationContext) {
    return this.transformer.transformResult(
      originalResult,
      delegationContext,
      transformationContext
    );
  }
}

class HoistField {
  typeName;
  newFieldName;
  pathToField;
  oldFieldName;
  argFilters;
  argLevels;
  transformer;
  constructor(typeName, pathConfig, newFieldName, alias = "__gqtlw__") {
    this.typeName = typeName;
    this.newFieldName = newFieldName;
    const path = pathConfig.map(
      (segment) => typeof segment === "string" ? segment : segment.fieldName
    );
    this.argFilters = pathConfig.map((segment, index) => {
      if (typeof segment === "string" || segment.argFilter == null) {
        return index === pathConfig.length - 1 ? () => true : () => false;
      }
      return segment.argFilter;
    });
    const pathToField = path.slice();
    const oldFieldName = pathToField.pop();
    if (oldFieldName == null) {
      throw new Error(
        `Cannot hoist field to ${newFieldName} on type ${typeName}, no path provided.`
      );
    }
    this.oldFieldName = oldFieldName;
    this.pathToField = pathToField;
    const argLevels = /* @__PURE__ */ Object.create(null);
    this.transformer = new MapFields(
      {
        [typeName]: {
          [newFieldName]: (fieldNode) => wrapFieldNode(
            renameFieldNode(fieldNode, oldFieldName),
            pathToField,
            alias,
            argLevels
          )
        }
      },
      {
        [typeName]: (value) => unwrapValue(value, alias)
      },
      (errors) => errors != null ? unwrapErrors(errors, alias) : void 0
    );
    this.argLevels = argLevels;
  }
  transformSchema(originalWrappingSchema, subschemaConfig) {
    const argsMap = /* @__PURE__ */ Object.create(null);
    let isList = false;
    const innerType = this.pathToField.reduce(
      (acc, pathSegment, index) => {
        const field = acc.getFields()[pathSegment];
        for (const arg of field.args) {
          if (this.argFilters[index](arg)) {
            argsMap[arg.name] = arg;
            this.argLevels[arg.name] = index;
          }
        }
        const nullableType = getNullableType(field?.type);
        if (isListType(nullableType)) {
          isList = true;
          return getNamedType(nullableType);
        }
        return nullableType;
      },
      originalWrappingSchema.getType(this.typeName)
    );
    let [newSchema, targetFieldConfigMap] = removeObjectFields(
      originalWrappingSchema,
      innerType.name,
      (fieldName) => fieldName === this.oldFieldName
    );
    const targetField = targetFieldConfigMap[this.oldFieldName];
    let resolve;
    const hoistingToRootField = this.typeName === originalWrappingSchema.getQueryType()?.name || this.typeName === originalWrappingSchema.getMutationType()?.name;
    if (hoistingToRootField) {
      const targetSchema = subschemaConfig.schema;
      const operation = this.typeName === targetSchema.getQueryType()?.name ? "query" : "mutation";
      const createProxyingResolver = subschemaConfig.createProxyingResolver ?? defaultCreateProxyingResolver;
      resolve = createProxyingResolver({
        subschemaConfig,
        operation,
        fieldName: this.newFieldName
      });
    } else {
      resolve = defaultMergedResolver;
    }
    const newTargetField = {
      ...targetField,
      resolve
    };
    const level = this.pathToField.length;
    const args = targetField?.args;
    if (args != null) {
      for (const argName in args) {
        const argConfig = args[argName];
        if (argConfig == null) {
          continue;
        }
        const arg = {
          ...argConfig,
          name: argName,
          description: argConfig.description,
          defaultValue: argConfig.defaultValue,
          extensions: argConfig.extensions,
          astNode: argConfig.astNode
        };
        if (this.argFilters[level]?.(arg)) {
          argsMap[argName] = arg;
          this.argLevels[arg.name] = level;
        }
      }
    }
    newTargetField.args = argsMap;
    if (isList) {
      newTargetField.type = new GraphQLList(newTargetField.type);
      const resolver = newTargetField.resolve;
      newTargetField.resolve = (parent, args2, context, info) => Promise.all(
        Object.keys(parent).filter((key) => !isNaN(parseInt(key, 10))).map((key) => resolver(parent[key], args2, context, info))
      );
    }
    newSchema = appendObjectFields(newSchema, this.typeName, {
      [this.newFieldName]: newTargetField
    });
    return this.transformer.transformSchema(newSchema, subschemaConfig);
  }
  transformRequest(originalRequest, delegationContext, transformationContext) {
    return this.transformer.transformRequest(
      originalRequest,
      delegationContext,
      transformationContext
    );
  }
  transformResult(originalResult, delegationContext, transformationContext) {
    return this.transformer.transformResult(
      originalResult,
      delegationContext,
      transformationContext
    );
  }
}
function wrapFieldNode(fieldNode, path, alias, argLevels) {
  return path.reduceRight(
    (acc, fieldName, index) => ({
      kind: Kind.FIELD,
      alias: {
        kind: Kind.NAME,
        value: alias
      },
      name: {
        kind: Kind.NAME,
        value: fieldName
      },
      selectionSet: {
        kind: Kind.SELECTION_SET,
        selections: [acc]
      },
      arguments: fieldNode.arguments != null ? fieldNode.arguments.filter(
        (arg) => argLevels[arg.name.value] === index
      ) : void 0
    }),
    {
      ...fieldNode,
      arguments: fieldNode.arguments != null ? fieldNode.arguments.filter(
        (arg) => argLevels[arg.name.value] === path.length
      ) : void 0
    }
  );
}
function renameFieldNode(fieldNode, name) {
  return {
    ...fieldNode,
    alias: {
      kind: Kind.NAME,
      value: fieldNode.alias != null ? fieldNode.alias.value : fieldNode.name.value
    },
    name: {
      kind: Kind.NAME,
      value: name
    }
  };
}
function unwrapValue(originalValue, alias) {
  let newValue = originalValue;
  let object = newValue[alias];
  while (object != null) {
    newValue = object;
    object = newValue[alias];
  }
  delete originalValue[alias];
  Object.assign(originalValue, newValue);
  return originalValue;
}
function unwrapErrors(errors, alias) {
  return errors.map((error) => {
    const originalPath = error.path;
    if (originalPath == null) {
      return error;
    }
    const newPath = originalPath.filter((pathSegment) => pathSegment !== alias);
    return relocatedError(error, newPath);
  });
}

class WrapQuery {
  constructor(path, wrapper, extractor) {
    this.path = path;
    this.wrapper = wrapper;
    this.extractor = extractor;
    const pollutingKeys = this.path.filter(isPrototypePollutingKey);
    if (pollutingKeys.length > 0) {
      throw new TypeError(
        `Invalid path - cannot be a prototype polluting keys: ${pollutingKeys.join(".")}`
      );
    }
  }
  transformRequest(originalRequest, _delegationContext, _transformationContext) {
    const fieldPath = [];
    const ourPath = JSON.stringify(this.path);
    const document = visit(originalRequest.document, {
      [Kind.FIELD]: {
        enter: (node) => {
          fieldPath.push(node.name.value);
          if (node.selectionSet != null && ourPath === JSON.stringify(fieldPath)) {
            const wrapResult = this.wrapper(node.selectionSet);
            const selectionSet = wrapResult != null && wrapResult.kind === Kind.SELECTION_SET ? wrapResult : {
              kind: Kind.SELECTION_SET,
              selections: [wrapResult]
            };
            return {
              ...node,
              selectionSet
            };
          }
          return void 0;
        },
        leave: () => {
          fieldPath.pop();
        }
      }
    });
    return {
      ...originalRequest,
      document
    };
  }
  transformResult(originalResult, _delegationContext, _transformationContext) {
    const rootData = originalResult.data;
    if (rootData != null) {
      let data = rootData;
      const path = [...this.path];
      while (path.length > 1) {
        const next = path.shift();
        if (data[next]) {
          data = data[next];
        }
      }
      const lastKey = path[0];
      data[lastKey] = this.extractor(data[lastKey]);
    }
    return {
      data: rootData,
      errors: originalResult.errors
    };
  }
}

class ExtractField {
  from;
  to;
  constructor({ from, to }) {
    this.from = from;
    this.to = to;
  }
  transformRequest(originalRequest, _delegationContext, _transformationContext) {
    let fromSelection;
    const ourPathFrom = JSON.stringify(this.from);
    const ourPathTo = JSON.stringify(this.to);
    let fieldPath = [];
    visit(originalRequest.document, {
      [Kind.FIELD]: {
        enter: (node) => {
          fieldPath.push(node.name.value);
          if (ourPathFrom === JSON.stringify(fieldPath)) {
            fromSelection = node.selectionSet;
            return BREAK;
          }
          return void 0;
        },
        leave: () => {
          fieldPath.pop();
        }
      }
    });
    fieldPath = [];
    const document = visit(originalRequest.document, {
      [Kind.FIELD]: {
        enter: (node) => {
          fieldPath.push(node.name.value);
          if (ourPathTo === JSON.stringify(fieldPath) && fromSelection != null) {
            return {
              ...node,
              selectionSet: fromSelection
            };
          }
          return void 0;
        },
        leave: () => {
          fieldPath.pop();
        }
      }
    });
    return {
      ...originalRequest,
      document
    };
  }
}

function getSchemaFromIntrospection(introspectionResult, options) {
  if (introspectionResult?.data?.__schema) {
    return buildClientSchema(introspectionResult.data, options);
  }
  if (introspectionResult?.errors) {
    const graphqlErrors = introspectionResult.errors.map(
      (error) => createGraphQLError(error.message, error)
    );
    if (introspectionResult.errors.length === 1) {
      throw graphqlErrors[0];
    } else {
      throw new AggregateError(
        graphqlErrors,
        "Could not obtain introspection result"
      );
    }
  }
  throw createGraphQLError(
    `Could not obtain introspection result, received the following as response; 
 ${inspect(
      introspectionResult
    )}`
  );
}
function schemaFromExecutor(executor, context, options) {
  const parsedIntrospectionQuery = parse(
    getIntrospectionQuery(options),
    options
  );
  return handleMaybePromise(
    () => handleMaybePromise(
      () => executor({
        document: parsedIntrospectionQuery,
        context
      }),
      (introspection) => {
        if (isAsyncIterable(introspection)) {
          const iterator = introspection[Symbol.asyncIterator]();
          return iterator.next().then(({ value }) => value);
        }
        return introspection;
      }
    ),
    (introspection) => getSchemaFromIntrospection(introspection, options)
  );
}

export { ExtractField, FilterInputObjectFields, FilterInterfaceFields, FilterObjectFieldDirectives, FilterObjectFields, FilterRootFields, FilterTypes, HoistField, MapFields, MapLeafValues, PruneTypes as PruneSchema, RemoveObjectFieldDeprecations, RemoveObjectFieldDirectives, RemoveObjectFieldsWithDeprecation, RemoveObjectFieldsWithDirective, RenameInputObjectFields, RenameInterfaceFields, RenameObjectFieldArguments, RenameObjectFields, RenameRootFields, RenameRootTypes, RenameTypes, TransformCompositeFields, TransformEnumValues, TransformInputObjectFields, TransformInterfaceFields, TransformObjectFields, TransformQuery, TransformRootFields, WrapFields, WrapQuery, WrapType, defaultCreateProxyingResolver, generateProxyingResolvers, schemaFromExecutor, wrapSchema };
