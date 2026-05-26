'use strict';

var utils = require('@graphql-tools/utils');
var graphql = require('graphql');
var promiseHelpers = require('@whatwg-node/promise-helpers');
var executor = require('@graphql-tools/executor');
var batchExecute = require('@graphql-tools/batch-execute');
var repeater = require('@repeaterjs/repeater');

const applySchemaTransforms = utils.memoize2(function applySchemaTransforms2(originalWrappingSchema, subschemaConfig) {
  const schemaTransforms = subschemaConfig.transforms;
  if (schemaTransforms == null) {
    return originalWrappingSchema;
  }
  return schemaTransforms.reduce(
    (schema, transform) => transform.transformSchema?.(schema, subschemaConfig) || schema,
    originalWrappingSchema
  );
});

function isSubschema(value) {
  return Boolean(value.transformedSchema);
}
class Subschema {
  name;
  schema;
  executor;
  batch;
  batchingOptions;
  createProxyingResolver;
  transforms;
  _transformedSchema;
  merge;
  constructor(config) {
    this.name = config.name;
    this.schema = config.schema;
    this.executor = config.executor;
    this.batch = config.batch;
    this.batchingOptions = config.batchingOptions;
    this.createProxyingResolver = config.createProxyingResolver;
    this.transforms = config.transforms ?? [];
    this.merge = config.merge;
  }
  get transformedSchema() {
    if (!this._transformedSchema) {
      if (globalThis.process?.env?.["DEBUG"] != null) {
        console.warn(
          "Transformed schema is not set yet. Returning a dummy one."
        );
      }
      this._transformedSchema = applySchemaTransforms(this.schema, this);
    }
    return this._transformedSchema;
  }
  set transformedSchema(value) {
    this._transformedSchema = value;
  }
}

const prototypePollutingKeys = [
  "__proto__",
  "constructor",
  "prototype"
];
function isPrototypePollutingKey(key) {
  return prototypePollutingKeys.includes(key);
}

const leftOverByDelegationPlan = /* @__PURE__ */ new WeakMap();
const PLAN_LEFT_OVER = Symbol("PLAN_LEFT_OVER");
function getPlanLeftOverFromParent(parent) {
  if (parent != null && typeof parent === "object") {
    return parent[PLAN_LEFT_OVER];
  }
  return void 0;
}

const UNPATHED_ERRORS_SYMBOL = Symbol.for("subschemaErrors");
const OBJECT_SUBSCHEMA_SYMBOL = Symbol.for("initialSubschema");
const FIELD_SUBSCHEMA_MAP_SYMBOL = Symbol.for("subschemaMap");

function isExternalObject(data) {
  return data[UNPATHED_ERRORS_SYMBOL] !== void 0;
}
function annotateExternalObject(object, errors, subschema, subschemaMap) {
  Object.defineProperties(object, {
    [OBJECT_SUBSCHEMA_SYMBOL]: { value: subschema, writable: true },
    [FIELD_SUBSCHEMA_MAP_SYMBOL]: { value: subschemaMap, writable: true },
    [UNPATHED_ERRORS_SYMBOL]: { value: errors, writable: true }
  });
  return object;
}
function getSubschema(object, responseKey) {
  return object[FIELD_SUBSCHEMA_MAP_SYMBOL]?.[responseKey] ?? object[OBJECT_SUBSCHEMA_SYMBOL];
}
function getUnpathedErrors(object) {
  return object[UNPATHED_ERRORS_SYMBOL];
}
const EMPTY_ARRAY = [];
const EMPTY_OBJECT = /* @__PURE__ */ Object.create(null);
const getActualFieldNodes = utils.memoize1(function(fieldNode) {
  return [fieldNode];
});
function mergeFields(mergedTypeInfo, object, sourceSubschema, context, info) {
  const delegationMaps = mergedTypeInfo.delegationPlanBuilder(
    info.schema,
    sourceSubschema,
    info.variableValues != null && Object.keys(info.variableValues).length > 0 ? info.variableValues : EMPTY_OBJECT,
    info.fragments != null && Object.keys(info.fragments).length > 0 ? info.fragments : EMPTY_OBJECT,
    info.fieldNodes?.length ? info.fieldNodes.length === 1 && info.fieldNodes[0] ? getActualFieldNodes(info.fieldNodes[0]) : info.fieldNodes : EMPTY_ARRAY,
    context,
    info
  );
  const leftOver = leftOverByDelegationPlan.get(delegationMaps);
  if (leftOver) {
    object[PLAN_LEFT_OVER] = leftOver;
  }
  return promiseHelpers.handleMaybePromise(
    () => utils.promiseReduce(
      delegationMaps,
      (_, delegationMap) => executeDelegationStage(
        mergedTypeInfo,
        delegationMap,
        object,
        context,
        info
      ),
      void 0
    ),
    () => object
  );
}
function handleResolverResult(resolverResult, subschema, selectionSet, object, combinedFieldSubschemaMap, info, path, combinedErrors) {
  if (resolverResult instanceof Error || resolverResult == null) {
    const schema = subschema.transformedSchema || info.schema;
    const type = schema.getType(object.__typename);
    const { fields } = utils.collectFields(
      schema,
      info.fragments,
      info.variableValues,
      type,
      selectionSet
    );
    const nullResult = {};
    for (const [responseKey, fieldNodes] of fields) {
      const combinedPath = [...path, responseKey];
      if (resolverResult instanceof graphql.GraphQLError) {
        if (resolverResult.message.includes(
          "Cannot return null for non-nullable field"
        )) {
          nullResult[responseKey] = null;
        } else {
          nullResult[responseKey] = utils.relocatedError(
            resolverResult,
            combinedPath
          );
        }
      } else if (resolverResult instanceof Error) {
        nullResult[responseKey] = graphql.locatedError(
          resolverResult,
          fieldNodes,
          combinedPath
        );
      } else {
        nullResult[responseKey] = null;
      }
    }
    resolverResult = nullResult;
  } else {
    if (resolverResult[UNPATHED_ERRORS_SYMBOL]) {
      combinedErrors.push(...resolverResult[UNPATHED_ERRORS_SYMBOL]);
    }
  }
  const objectSubschema = resolverResult[OBJECT_SUBSCHEMA_SYMBOL];
  const fieldSubschemaMap = resolverResult[FIELD_SUBSCHEMA_MAP_SYMBOL];
  for (const responseKey in resolverResult) {
    if (isPrototypePollutingKey(responseKey)) {
      continue;
    }
    const existingPropValue = object[responseKey];
    const sourcePropValue = resolverResult[responseKey];
    if (responseKey === "__typename" && existingPropValue !== sourcePropValue && graphql.isAbstractType(subschema.transformedSchema.getType(sourcePropValue))) {
      continue;
    }
    if (sourcePropValue != null || existingPropValue == null) {
      if (existingPropValue != null && typeof existingPropValue === "object" && !(existingPropValue instanceof Error) && Object.keys(existingPropValue).length > 0) {
        if (Array.isArray(existingPropValue) && Array.isArray(sourcePropValue) && existingPropValue.length === sourcePropValue.length) {
          object[responseKey] = existingPropValue.map(
            (existingElement, index) => sourcePropValue instanceof Error ? existingElement : utils.mergeDeep(
              [existingElement, sourcePropValue[index]],
              void 0,
              true,
              true
            )
          );
        } else if (!(sourcePropValue instanceof Error)) {
          object[responseKey] = utils.mergeDeep(
            [existingPropValue, sourcePropValue],
            void 0,
            true,
            true
          );
        }
      } else {
        object[responseKey] = sourcePropValue;
      }
    }
    combinedFieldSubschemaMap[responseKey] = fieldSubschemaMap?.[responseKey] ?? objectSubschema ?? subschema;
  }
}
function executeDelegationStage(mergedTypeInfo, delegationMap, object, context, info) {
  const combinedErrors = object[UNPATHED_ERRORS_SYMBOL];
  const path = utils.pathToArray(info.path);
  const combinedFieldSubschemaMap = object[FIELD_SUBSCHEMA_MAP_SYMBOL];
  const jobs = [];
  for (const [subschema, selectionSet] of delegationMap) {
    const schema = subschema.transformedSchema || info.schema;
    const type = schema.getType(object.__typename);
    const resolver = mergedTypeInfo.resolvers.get(subschema);
    if (resolver) {
      try {
        const resolverResult$ = resolver(
          object,
          context,
          info,
          subschema,
          selectionSet,
          void 0,
          type
        );
        if (promiseHelpers.isPromise(resolverResult$)) {
          jobs.push(
            resolverResult$.then(
              (resolverResult) => handleResolverResult(
                resolverResult,
                subschema,
                selectionSet,
                object,
                combinedFieldSubschemaMap,
                info,
                path,
                combinedErrors
              ),
              (error) => handleResolverResult(
                error,
                subschema,
                selectionSet,
                object,
                combinedFieldSubschemaMap,
                info,
                path,
                combinedErrors
              )
            )
          );
        } else {
          handleResolverResult(
            resolverResult$,
            subschema,
            selectionSet,
            object,
            combinedFieldSubschemaMap,
            info,
            path,
            combinedErrors
          );
        }
      } catch (error) {
        handleResolverResult(
          error,
          subschema,
          selectionSet,
          object,
          combinedFieldSubschemaMap,
          info,
          path,
          combinedErrors
        );
      }
    }
  }
  if (jobs.length) {
    if (jobs.length === 1) {
      return jobs[0];
    }
    return Promise.all(jobs);
  }
}

function resolveExternalValue(result, unpathedErrors, subschema, context, info, returnType = getReturnType$1(info), skipTypeMerging) {
  const type = graphql.getNullableType(returnType);
  if (result instanceof Error) {
    return result;
  }
  if (result == null) {
    return reportUnpathedErrorsViaNull(unpathedErrors);
  }
  if (graphql.isLeafType(type)) {
    try {
      return type.parseValue(result);
    } catch {
      return null;
    }
  } else if (graphql.isCompositeType(type)) {
    return promiseHelpers.handleMaybePromise(
      () => resolveExternalObject(
        type,
        result,
        unpathedErrors,
        subschema,
        context,
        info,
        skipTypeMerging
      ),
      (result2) => {
        if (info && graphql.isAbstractType(type)) {
          if (result2.__typename != null) {
            const resolvedType = info.schema.getType(result2.__typename);
            if (!resolvedType) {
              return null;
            }
          }
          return result2;
        }
        return result2;
      }
    );
  } else if (graphql.isListType(type)) {
    if (Array.isArray(result)) {
      return resolveExternalList(
        type,
        result,
        unpathedErrors,
        subschema,
        context,
        info,
        skipTypeMerging
      );
    }
    return resolveExternalValue(
      result,
      unpathedErrors,
      subschema,
      context,
      info,
      type.ofType,
      skipTypeMerging
    );
  }
}
function resolveExternalObject(type, object, unpathedErrors, subschema, context, info, skipTypeMerging) {
  if (!isExternalObject(object)) {
    annotateExternalObject(
      object,
      unpathedErrors,
      subschema,
      /* @__PURE__ */ Object.create(null)
    );
  }
  if (skipTypeMerging || info == null) {
    return object;
  }
  const stitchingInfo = info.schema.extensions?.["stitchingInfo"];
  if (stitchingInfo == null) {
    return object;
  }
  let mergedTypeInfo;
  const possibleTypeNames = [object.__typename, type.name];
  for (const possibleTypeName of possibleTypeNames) {
    if (possibleTypeName != null && stitchingInfo.mergedTypes[possibleTypeName]?.targetSubschemas?.get(
      subschema
    )?.length) {
      mergedTypeInfo = stitchingInfo.mergedTypes[possibleTypeName];
      break;
    }
  }
  if (!mergedTypeInfo) {
    for (const possibleTypeName of possibleTypeNames) {
      const potentialMergedTypeInfo = stitchingInfo.mergedTypes[possibleTypeName];
      if (potentialMergedTypeInfo != null) {
        for (const [
          sourceSubschema,
          targetSubschemas
        ] of potentialMergedTypeInfo.targetSubschemas) {
          if (targetSubschemas.length && sourceSubschema.name != null && sourceSubschema.name === subschema.name) {
            subschema = sourceSubschema;
            mergedTypeInfo = potentialMergedTypeInfo;
          }
        }
        break;
      }
    }
  }
  if (!mergedTypeInfo) {
    return object;
  }
  return mergeFields(
    mergedTypeInfo,
    object,
    subschema,
    context,
    info
  );
}
function resolveExternalList(type, list, unpathedErrors, subschema, context, info, skipTypeMerging) {
  return list.map(
    (listMember) => resolveExternalValue(
      listMember,
      unpathedErrors,
      subschema,
      context,
      info,
      type.ofType,
      skipTypeMerging
    )
  );
}
const reportedErrors = /* @__PURE__ */ new WeakSet();
function reportUnpathedErrorsViaNull(unpathedErrors) {
  if (unpathedErrors.length) {
    const unreportedErrors = [];
    for (const error of unpathedErrors) {
      if (!reportedErrors.has(error)) {
        unreportedErrors.push(error);
        reportedErrors.add(error);
      }
    }
    if (unreportedErrors.length) {
      const unreportedError = unreportedErrors[0];
      if (unreportedErrors.length === 1 && unreportedError) {
        return graphql.locatedError(
          unreportedError,
          void 0,
          unreportedError.path
        );
      }
      return new AggregateError(
        unreportedErrors.map(
          (e) => (
            // We cast path as any for GraphQL.js 14 compat
            // locatedError path argument must be defined, but it is just forwarded to a constructor that allows a undefined value
            // https://github.com/graphql/graphql-js/blob/b4bff0ba9c15c9d7245dd68556e754c41f263289/src/error/locatedError.js#L25
            // https://github.com/graphql/graphql-js/blob/b4bff0ba9c15c9d7245dd68556e754c41f263289/src/error/GraphQLError.js#L19
            graphql.locatedError(e, void 0, unreportedError?.path)
          )
        ),
        unreportedErrors.map((error) => error.message).join(", \n")
      );
    }
  }
  return null;
}
function getReturnType$1(info) {
  if (info == null) {
    throw new Error(`Return type cannot be inferred without a source schema.`);
  }
  return info.returnType;
}

function checkResultAndHandleErrors(result = {
  data: null,
  errors: []
}, delegationContext) {
  const {
    context,
    info,
    fieldName: responseKey = getResponseKey(info),
    subschema,
    returnType = getReturnType(info),
    skipTypeMerging,
    onLocatedError
  } = delegationContext;
  const { data, unpathedErrors } = mergeDataAndErrors(
    result.data == null ? void 0 : result.data[responseKey],
    result.errors == null ? [] : result.errors,
    info != null && info.path ? graphql.responsePathAsArray(info.path) : void 0,
    onLocatedError
  );
  return resolveExternalValue(
    data,
    unpathedErrors,
    subschema,
    context,
    info,
    returnType,
    skipTypeMerging
  );
}
function mergeDataAndErrors(data, errors, path, onLocatedError, index = 1) {
  if (data == null) {
    if (!errors.length) {
      return { data: null, unpathedErrors: [] };
    }
    if (errors.length === 1 && errors[0]) {
      const error = onLocatedError ? onLocatedError(errors[0]) : errors[0];
      const newPath = path === void 0 ? error.path : !error.path ? path : path.concat(error.path.slice(1));
      return { data: utils.relocatedError(errors[0], newPath), unpathedErrors: [] };
    }
    const combinedError = new AggregateError(
      errors.map((e) => {
        const error = onLocatedError ? onLocatedError(e) : e;
        const newPath = path === void 0 ? error.path : !error.path ? path : path.concat(error.path.slice(1));
        return utils.relocatedError(error, newPath);
      }),
      errors.map((error) => error.message).join(",\n")
    );
    return { data: combinedError, unpathedErrors: [] };
  }
  if (!errors.length) {
    return { data, unpathedErrors: [] };
  }
  const unpathedErrors = [];
  const errorMap = /* @__PURE__ */ new Map();
  for (const error of errors) {
    const pathSegment = error.path?.[index];
    if (pathSegment != null) {
      let pathSegmentErrors = errorMap.get(pathSegment);
      if (pathSegmentErrors === void 0) {
        pathSegmentErrors = [error];
        errorMap.set(pathSegment, pathSegmentErrors);
      } else {
        pathSegmentErrors.push(error);
      }
    } else {
      unpathedErrors.push(error);
    }
  }
  for (const [pathSegment, pathSegmentErrors] of errorMap) {
    if (data[pathSegment] !== void 0) {
      const { data: newData, unpathedErrors: newErrors } = mergeDataAndErrors(
        data[pathSegment],
        pathSegmentErrors,
        path,
        onLocatedError,
        index + 1
      );
      data[pathSegment] = newData;
      unpathedErrors.push(...newErrors);
    } else {
      unpathedErrors.push(...pathSegmentErrors);
    }
  }
  return { data, unpathedErrors };
}
function getResponseKey(info) {
  if (info == null) {
    throw new Error(
      `Data cannot be extracted from result without an explicit key or source schema.`
    );
  }
  return utils.getResponseKeyFromInfo(info);
}
function getReturnType(info) {
  if (info == null) {
    throw new Error(`Return type cannot be inferred without a source schema.`);
  }
  return info.returnType;
}

function getDocumentMetadata(document) {
  const operations = [];
  const fragments = [];
  const fragmentNames = /* @__PURE__ */ new Set();
  for (let i = 0; i < document.definitions.length; i++) {
    const def = document.definitions[i];
    if (def?.kind === graphql.Kind.FRAGMENT_DEFINITION) {
      fragments.push(def);
      fragmentNames.add(def.name.value);
    } else if (def?.kind === graphql.Kind.OPERATION_DEFINITION) {
      operations.push(def);
    }
  }
  return {
    operations,
    fragments,
    fragmentNames
  };
}

const getTypeInfo = utils.memoize1(function getTypeInfo2(schema) {
  return new graphql.TypeInfo(schema);
});
const getTypeInfoWithType = utils.memoize2(function getTypeInfoWithType2(schema, type) {
  return graphql.versionInfo.major < 16 ? new graphql.TypeInfo(schema, void 0, type) : new graphql.TypeInfo(schema, type);
});

const handleOverrideByDelegation = utils.memoize3(
  function handleOverrideByDelegation2(info, context, overrideHandler) {
    return overrideHandler(context, info);
  }
);

function finalizeGatewayDocument(targetSchema, fragments, operations, onOverlappingAliases, delegationContext) {
  let usedVariables = [];
  let usedFragments = [];
  const newOperations = [];
  let newFragments = [];
  const validFragments = [];
  const validFragmentsWithType = /* @__PURE__ */ Object.create(null);
  for (const fragment of fragments) {
    if (fragment.selectionSet.selections.length === 0) {
      continue;
    }
    const typeName = fragment.typeCondition.name.value;
    const type = targetSchema.getType(typeName);
    if (type != null) {
      validFragments.push(fragment);
      validFragmentsWithType[fragment.name.value] = type;
    }
  }
  let fragmentSet = /* @__PURE__ */ Object.create(null);
  let selectionCnt = 0;
  for (const operation of operations) {
    const type = utils.getDefinedRootType(targetSchema, operation.operation);
    const {
      selectionSet,
      usedFragments: operationUsedFragments,
      usedVariables: operationUsedVariables
    } = finalizeSelectionSet(
      targetSchema,
      type,
      validFragmentsWithType,
      operation.selectionSet,
      onOverlappingAliases,
      delegationContext
    );
    usedFragments = union(usedFragments, operationUsedFragments);
    const {
      usedVariables: collectedUsedVariables,
      newFragments: collectedNewFragments,
      fragmentSet: collectedFragmentSet
    } = collectFragmentVariables(
      targetSchema,
      fragmentSet,
      validFragments,
      validFragmentsWithType,
      usedFragments,
      onOverlappingAliases,
      delegationContext
    );
    const operationOrFragmentVariables = union(
      operationUsedVariables,
      collectedUsedVariables
    );
    usedVariables = union(usedVariables, operationOrFragmentVariables);
    newFragments = collectedNewFragments;
    fragmentSet = collectedFragmentSet;
    const variableDefinitions = [];
    for (const variableName of operationOrFragmentVariables) {
      const variableDef = operation.variableDefinitions?.find(
        (varDef) => varDef.variable.name.value === variableName
      );
      if (variableDef != null) {
        variableDefinitions.push(variableDef);
      }
    }
    if (operation.operation === "subscription") {
      selectionSet.selections = selectionSet.selections.filter(
        (selection) => selection.kind !== graphql.Kind.FIELD || selection.name.value !== "__typename"
      );
    }
    if (selectionSet.selections.length === 1 && selectionSet.selections[0] && selectionSet.selections[0].kind === graphql.Kind.FIELD && selectionSet.selections[0].name.value === "__typename") {
      continue;
    }
    selectionCnt += selectionSet.selections.length;
    newOperations.push({
      kind: graphql.Kind.OPERATION_DEFINITION,
      operation: operation.operation,
      name: operation.name,
      directives: operation.directives,
      variableDefinitions,
      selectionSet
    });
  }
  if (!newOperations.length || selectionCnt === 0) {
    throw utils.createGraphQLError(
      "Failed to create a gateway request. The request must contain at least one operation.",
      {
        extensions: {
          [executor.CRITICAL_ERROR]: true
        }
      }
    );
  }
  let newDocument = {
    kind: graphql.Kind.DOCUMENT,
    definitions: [...newOperations, ...newFragments]
  };
  const stitchingInfo = delegationContext.info?.schema?.extensions?.["stitchingInfo"];
  if (stitchingInfo != null) {
    const typeInfo = getTypeInfo(targetSchema);
    newDocument = graphql.visit(
      newDocument,
      graphql.visitWithTypeInfo(typeInfo, {
        [graphql.Kind.FIELD](fieldNode) {
          const parentType = typeInfo.getParentType();
          if (parentType) {
            const parentTypeName = parentType.name;
            const typeConfig = stitchingInfo?.mergedTypes?.[parentTypeName];
            if (typeConfig) {
              const providedSelectionsByField = typeConfig?.providedSelectionsByField?.get(
                delegationContext.subschema
              );
              if (providedSelectionsByField) {
                const providedSelection = providedSelectionsByField[fieldNode.name.value];
                if (providedSelection) {
                  return {
                    ...fieldNode,
                    selectionSet: {
                      kind: graphql.Kind.SELECTION_SET,
                      selections: [
                        ...providedSelection.selections,
                        ...fieldNode.selectionSet?.selections ?? []
                      ]
                    }
                  };
                }
              }
            }
          }
          return fieldNode;
        }
      })
    );
  }
  return {
    usedVariables,
    newDocument
  };
}
function finalizeGatewayRequest(originalRequest, delegationContext, onOverlappingAliases) {
  let { operations, fragments } = getDocumentMetadata(originalRequest.document);
  const { targetSchema } = delegationContext;
  const { usedVariables, newDocument } = finalizeGatewayDocument(
    targetSchema,
    fragments,
    operations,
    onOverlappingAliases,
    delegationContext
  );
  const newVariables = {};
  const outerVariables = delegationContext.info?.variableValues;
  for (const varName of usedVariables) {
    const existingVar = originalRequest.variables?.[varName];
    const outerVar = outerVariables?.[varName];
    if (existingVar != null) {
      newVariables[varName] = existingVar;
    } else if (outerVar != null) {
      newVariables[varName] = outerVar;
    }
    if (existingVar === null || outerVar === null) {
      newVariables[varName] = null;
    }
  }
  return {
    ...originalRequest,
    document: newDocument,
    variables: newVariables
  };
}
function isTypeNameField(selection) {
  return selection.kind === graphql.Kind.FIELD && !selection.alias && selection.name.value === "__typename";
}
function filterTypenameFields(selections) {
  let hasTypeNameField = false;
  const filteredSelections = selections.filter((selection) => {
    if (isTypeNameField(selection)) {
      hasTypeNameField = true;
      return false;
    }
    return true;
  });
  return {
    hasTypeNameField,
    selections: filteredSelections
  };
}
function collectFragmentVariables(targetSchema, fragmentSet, validFragments, validFragmentsWithType, usedFragments, onOverlappingAliases, delegationContext) {
  let remainingFragments = usedFragments.slice();
  let usedVariables = [];
  const newFragments = [];
  while (remainingFragments.length !== 0) {
    const nextFragmentName = remainingFragments.pop();
    const fragment = validFragments.find(
      (fr) => fr.name.value === nextFragmentName
    );
    if (fragment != null) {
      const name = nextFragmentName;
      const typeName = fragment.typeCondition.name.value;
      const type = targetSchema.getType(typeName);
      if (type == null) {
        throw new Error(
          `Fragment reference type "${typeName}", but the type is not contained within the target schema.`
        );
      }
      const {
        selectionSet,
        usedFragments: fragmentUsedFragments,
        usedVariables: fragmentUsedVariables
      } = finalizeSelectionSet(
        targetSchema,
        type,
        validFragmentsWithType,
        fragment.selectionSet,
        onOverlappingAliases,
        delegationContext
      );
      remainingFragments = union(remainingFragments, fragmentUsedFragments);
      usedVariables = union(usedVariables, fragmentUsedVariables);
      if (name && !(name in fragmentSet)) {
        fragmentSet[name] = true;
        newFragments.push({
          kind: graphql.Kind.FRAGMENT_DEFINITION,
          name: {
            kind: graphql.Kind.NAME,
            value: name
          },
          typeCondition: fragment.typeCondition,
          selectionSet
        });
      }
    }
  }
  return {
    usedVariables,
    newFragments,
    fragmentSet
  };
}
const filteredSelectionSetVisitorKeys = {
  SelectionSet: ["selections"],
  Field: ["selectionSet"],
  InlineFragment: ["selectionSet"],
  FragmentDefinition: ["selectionSet"]
};
const variablesVisitorKeys = {
  SelectionSet: ["selections"],
  Field: ["arguments", "directives", "selectionSet"],
  Argument: ["value"],
  InlineFragment: ["directives", "selectionSet"],
  FragmentSpread: ["directives"],
  FragmentDefinition: ["selectionSet"],
  ObjectValue: ["fields"],
  ObjectField: ["name", "value"],
  Directive: ["arguments"],
  ListValue: ["values"]
};
function finalizeSelectionSet(schema, type, validFragments, selectionSet, onOverlappingAliases, delegationContext) {
  const usedFragments = [];
  const usedVariables = [];
  const typeInfo = getTypeInfoWithType(schema, type);
  const seenNonNullableMap = /* @__PURE__ */ new WeakMap();
  const seenNullableMap = /* @__PURE__ */ new WeakMap();
  const filteredSelectionSet = filterSelectionSet(
    schema,
    typeInfo,
    validFragments,
    selectionSet,
    onOverlappingAliases,
    usedFragments,
    seenNonNullableMap,
    seenNullableMap,
    delegationContext
  );
  graphql.visit(
    filteredSelectionSet,
    {
      [graphql.Kind.VARIABLE]: (variableNode) => {
        usedVariables.push(variableNode.name.value);
      }
    },
    // visitorKeys argument usage a la https://github.com/gatsbyjs/gatsby/blob/master/packages/gatsby-source-graphql/src/batching/merge-queries.js
    // empty keys cannot be removed only because of typescript errors
    // will hopefully be fixed in future version of graphql-js to be optional
    variablesVisitorKeys
  );
  return {
    selectionSet: filteredSelectionSet,
    usedFragments,
    usedVariables
  };
}
function filterSelectionSet(schema, typeInfo, validFragments, selectionSet, onOverlappingAliases, usedFragments, seenNonNullableMap, seenNullableMap, delegationContext) {
  return graphql.visit(
    selectionSet,
    graphql.visitWithTypeInfo(typeInfo, {
      [graphql.Kind.FIELD]: {
        enter: (node) => {
          const parentType = typeInfo.getParentType();
          const field = typeInfo.getFieldDef();
          if (delegationContext.context != null && delegationContext.info != null && parentType != null && field != null) {
            const parentTypeName = parentType.name;
            const overrideHandler = delegationContext.subschemaConfig?.merge?.[parentTypeName]?.fields?.[field.name]?.override;
            if (overrideHandler != null) {
              const overridden = handleOverrideByDelegation(
                delegationContext.info,
                delegationContext.context,
                overrideHandler
              );
              if (!overridden) {
                return null;
              }
            }
          }
          if (graphql.isObjectType(parentType) || graphql.isInterfaceType(parentType)) {
            if (!field) {
              return null;
            }
            const args = field.args != null ? field.args : [];
            const argsMap = /* @__PURE__ */ Object.create(null);
            for (const arg of args) {
              argsMap[arg.name] = arg;
            }
            if (node.arguments != null) {
              const newArgs = [];
              for (const arg of node.arguments) {
                if (arg.name.value in argsMap) {
                  newArgs.push(arg);
                }
              }
              if (newArgs.length !== node.arguments.length) {
                return {
                  ...node,
                  arguments: newArgs
                };
              }
            }
          }
          if (graphql.isUnionType(parentType) && typeInfo.getType() == null) {
            const possibleTypeNames = [];
            const fieldName = node.name.value;
            for (const memberType of parentType.getTypes()) {
              const memberFields = memberType.getFields();
              const possibleField = memberFields[fieldName];
              if (possibleField != null) {
                const namedType = graphql.getNamedType(possibleField.type);
                if (node.selectionSet?.selections?.length && graphql.isLeafType(namedType)) {
                  continue;
                }
                if (!node.selectionSet?.selections?.length && graphql.isCompositeType(namedType)) {
                  continue;
                }
                possibleTypeNames.push(memberType.name);
              }
            }
            if (possibleTypeNames.length > 0) {
              const spreads = possibleTypeNames.map((possibleTypeName) => {
                if (!node.selectionSet?.selections) {
                  return {
                    kind: graphql.Kind.INLINE_FRAGMENT,
                    typeCondition: {
                      kind: graphql.Kind.NAMED_TYPE,
                      name: {
                        kind: graphql.Kind.NAME,
                        value: possibleTypeName
                      }
                    },
                    selectionSet: {
                      kind: graphql.Kind.SELECTION_SET,
                      selections: [node]
                    }
                  };
                }
                const possibleType = schema.getType(
                  possibleTypeName
                );
                const possibleField = possibleType.getFields()[node.name.value];
                if (!possibleField) {
                  return void 0;
                }
                const fieldFilteredSelectionSet = filterSelectionSet(
                  schema,
                  getTypeInfoWithType(schema, possibleField.type),
                  validFragments,
                  node.selectionSet,
                  onOverlappingAliases,
                  usedFragments,
                  seenNonNullableMap,
                  seenNullableMap,
                  delegationContext
                );
                if (!fieldFilteredSelectionSet.selections.length) {
                  return void 0;
                }
                return {
                  kind: graphql.Kind.INLINE_FRAGMENT,
                  typeCondition: {
                    kind: graphql.Kind.NAMED_TYPE,
                    name: {
                      kind: graphql.Kind.NAME,
                      value: possibleTypeName
                    }
                  },
                  selectionSet: {
                    kind: graphql.Kind.SELECTION_SET,
                    selections: [
                      {
                        ...node,
                        selectionSet: fieldFilteredSelectionSet
                      }
                    ]
                  }
                };
              });
              const nonEmptySpreads = spreads.filter(Boolean);
              if (!nonEmptySpreads.length) {
                return void 0;
              }
              return nonEmptySpreads;
            }
          }
          return void 0;
        },
        leave: (node) => {
          const type = typeInfo.getType();
          if (type == null) {
            return null;
          }
          const namedType = graphql.getNamedType(type);
          if (schema.getType(namedType.name) == null) {
            return null;
          }
          if (graphql.isObjectType(namedType) || graphql.isInterfaceType(namedType)) {
            const selections = node.selectionSet != null ? node.selectionSet.selections : null;
            if (selections == null || selections.length === 0) {
              return null;
            }
          }
          return void 0;
        }
      },
      [graphql.Kind.FRAGMENT_SPREAD]: {
        enter: (node) => {
          if (!(node.name.value in validFragments)) {
            return null;
          }
          const parentType = typeInfo.getParentType();
          const innerType = validFragments[node.name.value];
          if (!utils.implementsAbstractType(schema, parentType, innerType)) {
            return null;
          }
          usedFragments.push(node.name.value);
          return void 0;
        }
      },
      [graphql.Kind.SELECTION_SET]: {
        enter: (node, _key, _parent, _path) => {
          const parentType = typeInfo.getParentType();
          const { hasTypeNameField, selections } = filterTypenameFields(
            node.selections
          );
          if (hasTypeNameField || parentType != null && graphql.isAbstractType(parentType)) {
            selections.unshift({
              kind: graphql.Kind.FIELD,
              name: {
                kind: graphql.Kind.NAME,
                value: "__typename"
              }
            });
          }
          return {
            ...node,
            selections
          };
        }
      },
      [graphql.Kind.INLINE_FRAGMENT]: {
        enter: (node) => {
          if (node.typeCondition != null) {
            const parentType = typeInfo.getParentType();
            const innerType = schema.getType(node.typeCondition.name.value);
            if (graphql.isUnionType(parentType) && parentType.getTypes().some((t) => t.name === innerType?.name)) {
              return node;
            }
            if (!utils.implementsAbstractType(schema, parentType, innerType)) {
              return null;
            }
          }
          return void 0;
        },
        leave: (selection, _key, parent) => {
          if (!selection.selectionSet?.selections?.length) {
            return null;
          }
          if (Array.isArray(parent)) {
            const selectionTypeName = selection.typeCondition?.name.value;
            if (selectionTypeName) {
              const selectionType = schema.getType(selectionTypeName);
              if (selectionType && "getFields" in selectionType) {
                const selectionTypeFields = selectionType.getFields();
                let seenNonNullable = seenNonNullableMap.get(parent);
                if (!seenNonNullable) {
                  seenNonNullable = /* @__PURE__ */ new Set();
                  seenNonNullableMap.set(parent, seenNonNullable);
                }
                let seenNullable = seenNullableMap.get(parent);
                if (!seenNullable) {
                  seenNullable = /* @__PURE__ */ new Set();
                  seenNullableMap.set(parent, seenNullable);
                }
                selection = {
                  ...selection,
                  selectionSet: {
                    ...selection.selectionSet,
                    selections: selection.selectionSet.selections.map(
                      (subSelection) => {
                        if (subSelection.kind === graphql.Kind.FIELD) {
                          const fieldName = subSelection.name.value;
                          if (!subSelection.alias) {
                            const field = selectionTypeFields[fieldName];
                            if (field) {
                              let currentNullable;
                              if (graphql.isNullableType(field.type)) {
                                seenNullable.add(fieldName);
                                currentNullable = true;
                              } else {
                                seenNonNullable.add(fieldName);
                                currentNullable = false;
                              }
                              if (seenNullable.has(fieldName) && seenNonNullable.has(fieldName)) {
                                onOverlappingAliases();
                                return {
                                  ...subSelection,
                                  alias: {
                                    kind: graphql.Kind.NAME,
                                    value: currentNullable ? `_nullable_${fieldName}` : `_nonNullable_${fieldName}`
                                  }
                                };
                              }
                            }
                          }
                        }
                        return subSelection;
                      }
                    )
                  }
                };
              }
            }
          }
          const { selections } = filterTypenameFields(
            selection.selectionSet.selections
          );
          if (selections.length === 0) {
            return null;
          }
          return {
            ...selection,
            selectionSet: {
              ...selection.selectionSet,
              selections
            },
            // @defer is not available for the communication between the gw and subgraph
            directives: selection.directives?.filter?.(
              (directive) => directive.name.value !== "defer"
            )
          };
        }
      }
    }),
    // visitorKeys argument usage a la https://github.com/gatsbyjs/gatsby/blob/master/packages/gatsby-source-graphql/src/batching/merge-queries.js
    // empty keys cannot be removed only because of typescript errors
    // will hopefully be fixed in future version of graphql-js to be optional
    filteredSelectionSetVisitorKeys
  );
}
function union(...arrays) {
  const cache = /* @__PURE__ */ Object.create(null);
  const result = [];
  for (const array of arrays) {
    for (const item of array) {
      if (!(item in cache)) {
        cache[item] = true;
        result.push(item);
      }
    }
  }
  return result;
}

function prepareGatewayDocument(originalDocument, delegationContext) {
  const transformedSchema = delegationContext.transformedSchema;
  const returnType = delegationContext.returnType;
  const infoSchema = delegationContext.info?.schema;
  const wrappedConcreteTypesDocument = wrapConcreteTypes(
    returnType,
    transformedSchema,
    originalDocument
  );
  if (infoSchema == null) {
    return wrappedConcreteTypesDocument;
  }
  const visitedSelections = /* @__PURE__ */ new WeakSet();
  const {
    possibleTypesMap,
    reversePossibleTypesMap: reversePossibleTypesMap2,
    interfaceExtensionsMap,
    fieldNodesByType,
    fieldNodesByField,
    dynamicSelectionSetsByField
  } = getSchemaMetaData(infoSchema, transformedSchema);
  const { operations, fragments, fragmentNames } = getDocumentMetadata(
    wrappedConcreteTypesDocument
  );
  const { expandedFragments, fragmentReplacements } = getExpandedFragments(
    fragments,
    fragmentNames,
    possibleTypesMap
  );
  const typeInfo = getTypeInfo(transformedSchema);
  const expandedDocument = {
    kind: graphql.Kind.DOCUMENT,
    definitions: [...operations, ...fragments, ...expandedFragments]
  };
  const fragmentMap = /* @__PURE__ */ Object.create(null);
  for (const fragment of expandedDocument.definitions) {
    if (fragment.kind === graphql.Kind.FRAGMENT_DEFINITION) {
      fragmentMap[fragment.name.value] = fragment;
    }
  }
  const visitorKeyMap = {
    Document: ["definitions"],
    OperationDefinition: ["selectionSet"],
    SelectionSet: ["selections"],
    Field: ["selectionSet"],
    InlineFragment: ["selectionSet"],
    FragmentDefinition: ["selectionSet"]
  };
  return graphql.visit(
    expandedDocument,
    graphql.visitWithTypeInfo(typeInfo, {
      [graphql.Kind.SELECTION_SET]: (node) => visitSelectionSet(
        node,
        fragmentReplacements,
        transformedSchema,
        typeInfo,
        possibleTypesMap,
        reversePossibleTypesMap2,
        interfaceExtensionsMap,
        fieldNodesByType,
        fieldNodesByField,
        dynamicSelectionSetsByField,
        infoSchema,
        visitedSelections,
        fragmentMap,
        delegationContext
      )
    }),
    // visitorKeys argument usage a la https://github.com/gatsbyjs/gatsby/blob/master/packages/gatsby-source-graphql/src/batching/merge-queries.js
    // empty keys cannot be removed only because of typescript errors
    // will hopefully be fixed in future version of graphql-js to be optional
    visitorKeyMap
  );
}
const getExtraPossibleTypesFn = utils.memoize2(function getExtraPossibleTypes(transformedSchema, infoSchema) {
  const extraPossiblesTypesMap = /* @__PURE__ */ new Map();
  return function getExtraPossibleTypes2(typeName) {
    let extraTypesForSubschema = extraPossiblesTypesMap.get(typeName);
    if (!extraTypesForSubschema) {
      extraTypesForSubschema = /* @__PURE__ */ new Set();
      const gatewayType = infoSchema.getType(typeName);
      const subschemaType = transformedSchema.getType(typeName);
      if (graphql.isAbstractType(gatewayType) && graphql.isAbstractType(subschemaType)) {
        const possibleTypes = infoSchema.getPossibleTypes(gatewayType);
        const possibleTypesInSubschema = transformedSchema.getPossibleTypes(subschemaType);
        for (const possibleType of possibleTypes) {
          const possibleTypeInSubschema = transformedSchema.getType(
            possibleType.name
          );
          if (!possibleTypeInSubschema) {
            continue;
          }
          if (possibleTypeInSubschema && possibleTypesInSubschema.some((t) => t.name === possibleType.name)) {
            continue;
          }
          extraTypesForSubschema.add(possibleType.name);
        }
      }
      extraPossiblesTypesMap.set(typeName, extraTypesForSubschema);
    }
    return extraTypesForSubschema;
  };
});
function visitSelectionSet(node, fragmentReplacements, transformedSchema, typeInfo, possibleTypesMap, reversePossibleTypesMap2, interfaceExtensionsMap, fieldNodesByType, fieldNodesByField, dynamicSelectionSetsByField, infoSchema, visitedSelections, fragmentMap, delegationContext) {
  const newSelections = /* @__PURE__ */ new Set();
  const maybeType = typeInfo.getParentType();
  if (maybeType != null) {
    const parentType = graphql.getNamedType(maybeType);
    if (isSelectionSetSatisfiedBySchema(
      transformedSchema,
      parentType,
      node,
      fragmentMap,
      infoSchema,
      delegationContext
    )) {
      if (graphql.isAbstractType(delegationContext.returnType)) {
        addSelectionNodeToSelections(newSelections, {
          kind: graphql.Kind.FIELD,
          name: {
            kind: graphql.Kind.NAME,
            value: "__typename"
          }
        });
      }
      for (const selection of node.selections) {
        addSelectionNodeToSelections(newSelections, selection);
      }
      return {
        ...node,
        selections: Array.from(newSelections)
      };
    }
    const parentTypeName = parentType.name;
    const fieldNodes = fieldNodesByType[parentTypeName];
    if (fieldNodes) {
      for (const fieldNode of fieldNodes) {
        addSelectionNodeToSelections(newSelections, fieldNode);
      }
    }
    const interfaceExtensions = interfaceExtensionsMap[parentType.name];
    const interfaceExtensionFields = [];
    for (const selection of node.selections) {
      if (selection.kind === graphql.Kind.INLINE_FRAGMENT) {
        if (selection.typeCondition != null) {
          if (!visitedSelections.has(selection)) {
            visitedSelections.add(selection);
            const typeName = selection.typeCondition.name.value;
            const getExtraPossibleTypes2 = getExtraPossibleTypesFn(
              transformedSchema,
              infoSchema
            );
            const extraPossibleTypes = getExtraPossibleTypes2(typeName);
            for (const extraPossibleTypeName of extraPossibleTypes) {
              addSelectionNodeToSelections(newSelections, {
                ...selection,
                typeCondition: {
                  kind: graphql.Kind.NAMED_TYPE,
                  name: {
                    kind: graphql.Kind.NAME,
                    value: extraPossibleTypeName
                  }
                }
              });
            }
            const typeInSubschema = transformedSchema.getType(typeName);
            if (graphql.isObjectType(typeInSubschema) || graphql.isInterfaceType(typeInSubschema)) {
              const fieldMap = typeInSubschema.getFields();
              for (const subSelection of selection.selectionSet.selections) {
                if (subSelection.kind === graphql.Kind.FIELD) {
                  const fieldName = subSelection.name.value;
                  const field = fieldMap[fieldName];
                  if (!field) {
                    addSelectionNodeToSelections(newSelections, subSelection);
                  }
                }
              }
            } else if (!typeInSubschema) {
              for (const subSelection of selection.selectionSet.selections) {
                addSelectionNodeToSelections(newSelections, subSelection);
              }
            }
          }
          const possibleTypes = possibleTypesMap[selection.typeCondition.name.value];
          if (possibleTypes == null) {
            const fieldNodesForTypeName = fieldNodesByField[parentTypeName]?.["__typename"];
            if (fieldNodesForTypeName) {
              for (const fieldNode of fieldNodesForTypeName) {
                addSelectionNodeToSelections(newSelections, fieldNode);
              }
            }
            addSelectionNodeToSelections(newSelections, selection);
            continue;
          }
          for (const possibleTypeName of possibleTypes) {
            const maybePossibleType = transformedSchema.getType(possibleTypeName);
            if (maybePossibleType != null && utils.implementsAbstractType(
              transformedSchema,
              parentType,
              maybePossibleType
            )) {
              addSelectionNodeToSelections(
                newSelections,
                generateInlineFragment(
                  possibleTypeName,
                  selection.selectionSet
                )
              );
            }
          }
          if (possibleTypes.length === 0) {
            addSelectionNodeToSelections(newSelections, selection);
          }
        } else {
          addSelectionNodeToSelections(newSelections, selection);
        }
      } else if (selection.kind === graphql.Kind.FRAGMENT_SPREAD) {
        const fragmentName = selection.name.value;
        if (!fragmentReplacements[fragmentName]) {
          addSelectionNodeToSelections(newSelections, selection);
          continue;
        }
        for (const replacement of fragmentReplacements[fragmentName]) {
          const typeName = replacement.typeName;
          const maybeReplacementType = transformedSchema.getType(typeName);
          if (maybeReplacementType != null && utils.implementsAbstractType(transformedSchema, parentType, maybeType)) {
            addSelectionNodeToSelections(newSelections, {
              kind: graphql.Kind.FRAGMENT_SPREAD,
              name: {
                kind: graphql.Kind.NAME,
                value: replacement.fragmentName
              }
            });
          }
        }
      } else {
        const fieldName = selection.name.value;
        if (interfaceExtensions?.[fieldName]) {
          interfaceExtensionFields.push(selection);
        } else {
          addSelectionNodeToSelections(newSelections, selection);
        }
        if (graphql.isAbstractType(parentType)) {
          const fieldNodesForTypeName = fieldNodesByField[parentTypeName]?.["__typename"];
          if (fieldNodesForTypeName) {
            for (const fieldNode of fieldNodesForTypeName) {
              addSelectionNodeToSelections(newSelections, fieldNode);
            }
          }
        }
        const fieldNodesMapForType = fieldNodesByField[parentTypeName];
        if (fieldNodesMapForType) {
          addDependenciesNestedly(
            selection,
            /* @__PURE__ */ new Set(),
            fieldNodesMapForType,
            newSelections
          );
        }
        const dynamicSelectionSets = dynamicSelectionSetsByField[parentTypeName]?.[fieldName];
        if (dynamicSelectionSets != null) {
          for (const selectionSetFn of dynamicSelectionSets) {
            const selectionSet = selectionSetFn(selection);
            if (selectionSet != null) {
              for (const selection2 of selectionSet.selections) {
                addSelectionNodeToSelections(newSelections, selection2);
              }
            }
          }
        }
      }
    }
    if (reversePossibleTypesMap2[parentType.name]) {
      addSelectionNodeToSelections(newSelections, {
        kind: graphql.Kind.FIELD,
        name: {
          kind: graphql.Kind.NAME,
          value: "__typename"
        }
      });
    }
    if (interfaceExtensionFields.length) {
      const possibleTypes = possibleTypesMap[parentType.name];
      if (possibleTypes != null) {
        for (const possibleType of possibleTypes) {
          addSelectionNodeToSelections(
            newSelections,
            generateInlineFragment(possibleType, {
              kind: graphql.Kind.SELECTION_SET,
              selections: interfaceExtensionFields
            })
          );
        }
      }
    }
    return {
      ...node,
      selections: Array.from(newSelections)
    };
  }
  return node;
}
function isFieldNodeSatisfiedBySelections(fieldNode, existing) {
  for (const existingSelection of existing) {
    if (existingSelection.kind === graphql.Kind.FIELD && existingSelection.name.value === fieldNode.name.value && existingSelection.alias?.value === fieldNode.alias?.value) {
      if (fieldNode.selectionSet && !existingSelection.selectionSet) {
        return false;
      }
      if (fieldNode.selectionSet && existingSelection.selectionSet) {
        const satisfied = isSelectionSetSatisfied({
          incoming: fieldNode.selectionSet,
          existing: existingSelection.selectionSet.selections
        });
        if (!satisfied) {
          return false;
        }
      }
      return true;
    }
  }
  return false;
}
function isSelectionSetSatisfiedBySchema(schema, type, selectionSet, fragmentsMap, infoSchema, delegationContext) {
  const namedType = graphql.getNamedType(type);
  if (graphql.isLeafType(namedType)) {
    return true;
  }
  const fields = graphql.isObjectType(namedType) || graphql.isInterfaceType(namedType) ? namedType.getFields() : null;
  for (const selection of selectionSet.selections) {
    if (selection.kind === graphql.Kind.FIELD) {
      if (graphql.isAbstractType(namedType)) {
        return false;
      }
      const fieldName = selection.name.value;
      if (fieldName === "__typename") {
        continue;
      }
      if (fields) {
        const field = fields[fieldName];
        if (!field) {
          return false;
        }
        const typeInInfoSchema = infoSchema.getType(namedType.name);
        const fieldInInfoSchema = typeInInfoSchema?.getFields?.()?.[fieldName];
        const resolverInInfoSchema = fieldInInfoSchema?.resolve;
        if (resolverInInfoSchema != null && resolverInInfoSchema.name !== "defaultMergedResolver" && resolverInInfoSchema.name !== "defaultFieldResolver") {
          return false;
        }
        if (delegationContext.info) {
          const overrideHandler = delegationContext.subschemaConfig?.merge?.[namedType.name]?.fields?.[field.name]?.override;
          if (overrideHandler != null) {
            const overridden = handleOverrideByDelegation(
              delegationContext.info,
              delegationContext.context,
              overrideHandler
            );
            if (!overridden) {
              return false;
            }
          }
        }
        if (selection.selectionSet) {
          const fieldType = graphql.getNamedType(field.type);
          const satisfied = isSelectionSetSatisfiedBySchema(
            schema,
            fieldType,
            selection.selectionSet,
            fragmentsMap,
            infoSchema,
            delegationContext
          );
          if (!satisfied) {
            return false;
          }
        }
      } else {
        return false;
      }
    } else if (selection.kind === graphql.Kind.INLINE_FRAGMENT) {
      if (selection.typeCondition) {
        const typeConditionName = selection.typeCondition.name.value;
        const typeCondition = schema.getType(typeConditionName);
        if (!typeCondition) {
          return false;
        }
        const satisfied = isSelectionSetSatisfiedBySchema(
          schema,
          typeCondition,
          selection.selectionSet,
          fragmentsMap,
          infoSchema,
          delegationContext
        );
        if (!satisfied) {
          return false;
        }
      } else {
        const satisfied = isSelectionSetSatisfiedBySchema(
          schema,
          type,
          selection.selectionSet,
          fragmentsMap,
          infoSchema,
          delegationContext
        );
        if (!satisfied) {
          return false;
        }
      }
    } else if (selection.kind === graphql.Kind.FRAGMENT_SPREAD) {
      const fragmentName = selection.name.value;
      const fragment = fragmentsMap[fragmentName];
      if (!fragment) {
        return false;
      }
      const typeConditionName = fragment.typeCondition.name.value;
      const typeCondition = schema.getType(typeConditionName);
      if (!typeCondition) {
        return false;
      }
      const satisfied = isSelectionSetSatisfiedBySchema(
        schema,
        typeCondition,
        fragment.selectionSet,
        fragmentsMap,
        infoSchema,
        delegationContext
      );
      if (!satisfied) {
        return false;
      }
    }
  }
  return true;
}
function isSelectionSetSatisfied({
  incoming,
  existing
}) {
  for (const incomingSelection of incoming.selections) {
    if (incomingSelection.kind === graphql.Kind.FIELD) {
      const existingField = existing.find((selection) => {
        return selection.kind === graphql.Kind.FIELD && selection.name.value === incomingSelection.name.value && selection.alias?.value === incomingSelection.alias?.value;
      });
      if (!existingField) {
        return false;
      }
      if (incomingSelection.selectionSet && !existingField.selectionSet) {
        return false;
      }
      if (incomingSelection.selectionSet && existingField.selectionSet) {
        const satisfied = isSelectionSetSatisfied({
          incoming: incomingSelection.selectionSet,
          existing: existingField.selectionSet.selections
        });
        if (!satisfied) {
          return false;
        }
      }
    } else {
      return false;
    }
  }
  return true;
}
function addSelectionNodeToSelections(selections, selectionNode) {
  if (selectionNode.kind === graphql.Kind.FIELD && isFieldNodeSatisfiedBySelections(selectionNode, selections)) {
    return;
  }
  selections.add(selectionNode);
}
function addDependenciesNestedly(fieldNode, seenFieldNames, fieldNodesByField, newSelections) {
  if (seenFieldNames.has(fieldNode.name.value)) {
    return;
  }
  seenFieldNames.add(fieldNode.name.value);
  const fieldNodes = fieldNodesByField[fieldNode.name.value];
  if (fieldNodes != null) {
    for (const nestedFieldNode of fieldNodes) {
      addSelectionNodeToSelections(newSelections, nestedFieldNode);
      addDependenciesNestedly(
        nestedFieldNode,
        seenFieldNames,
        fieldNodesByField,
        newSelections
      );
    }
  }
}
function generateInlineFragment(typeName, selectionSet) {
  return {
    kind: graphql.Kind.INLINE_FRAGMENT,
    typeCondition: {
      kind: graphql.Kind.NAMED_TYPE,
      name: {
        kind: graphql.Kind.NAME,
        value: typeName
      }
    },
    selectionSet
  };
}
const getSchemaMetaData = utils.memoize2(
  (sourceSchema, targetSchema) => {
    const typeMap = sourceSchema.getTypeMap();
    const targetTypeMap = targetSchema.getTypeMap();
    const possibleTypesMap = /* @__PURE__ */ Object.create(null);
    const interfaceExtensionsMap = /* @__PURE__ */ Object.create(null);
    for (const typeName in typeMap) {
      const type = typeMap[typeName];
      if (graphql.isAbstractType(type)) {
        const targetType = targetTypeMap[typeName];
        if (graphql.isInterfaceType(type) && graphql.isInterfaceType(targetType)) {
          const targetTypeFields = targetType.getFields();
          const sourceTypeFields = type.getFields();
          const extensionFields = /* @__PURE__ */ Object.create(null);
          let isExtensionFieldsEmpty = true;
          for (const fieldName in sourceTypeFields) {
            if (!targetTypeFields[fieldName]) {
              extensionFields[fieldName] = true;
              isExtensionFieldsEmpty = false;
            }
          }
          if (!isExtensionFieldsEmpty) {
            interfaceExtensionsMap[typeName] = extensionFields;
          }
        }
        if (interfaceExtensionsMap[typeName] || !graphql.isAbstractType(targetType)) {
          const implementations = sourceSchema.getPossibleTypes(type);
          possibleTypesMap[typeName] = [];
          for (const impl of implementations) {
            if (targetTypeMap[impl.name]) {
              possibleTypesMap[typeName].push(impl.name);
            }
          }
        }
      }
    }
    const stitchingInfo = sourceSchema.extensions?.["stitchingInfo"];
    return {
      possibleTypesMap,
      reversePossibleTypesMap: reversePossibleTypesMap(possibleTypesMap),
      interfaceExtensionsMap,
      fieldNodesByType: stitchingInfo?.fieldNodesByType ?? {},
      fieldNodesByField: stitchingInfo?.fieldNodesByField ?? {},
      dynamicSelectionSetsByField: stitchingInfo?.dynamicSelectionSetsByField ?? {}
    };
  }
);
function reversePossibleTypesMap(possibleTypesMap) {
  const result = /* @__PURE__ */ Object.create(null);
  for (const typeName in possibleTypesMap) {
    const toTypeNames = possibleTypesMap[typeName];
    if (toTypeNames) {
      for (const toTypeName of toTypeNames) {
        if (!result[toTypeName]) {
          result[toTypeName] = [];
        }
        result[toTypeName].push(typeName);
      }
    }
  }
  return result;
}
function getExpandedFragments(fragments, fragmentNames, possibleTypesMap) {
  let fragmentCounter = 0;
  function generateFragmentName(typeName) {
    let fragmentName;
    do {
      fragmentName = `_${typeName}_Fragment${fragmentCounter.toString()}`;
      fragmentCounter++;
    } while (fragmentNames.has(fragmentName));
    return fragmentName;
  }
  const expandedFragments = [];
  const fragmentReplacements = /* @__PURE__ */ Object.create(null);
  for (const fragment of fragments) {
    const possibleTypes = possibleTypesMap[fragment.typeCondition.name.value];
    if (possibleTypes != null) {
      const fragmentName = fragment.name.value;
      fragmentReplacements[fragmentName] = [];
      for (const possibleTypeName of possibleTypes) {
        const name = generateFragmentName(possibleTypeName);
        fragmentNames.add(name);
        expandedFragments.push({
          kind: graphql.Kind.FRAGMENT_DEFINITION,
          name: {
            kind: graphql.Kind.NAME,
            value: name
          },
          typeCondition: {
            kind: graphql.Kind.NAMED_TYPE,
            name: {
              kind: graphql.Kind.NAME,
              value: possibleTypeName
            }
          },
          selectionSet: fragment.selectionSet
        });
        fragmentReplacements[fragmentName].push({
          fragmentName: name,
          typeName: possibleTypeName
        });
      }
    }
  }
  return {
    expandedFragments,
    fragmentReplacements
  };
}
function wrapConcreteTypes(returnType, targetSchema, document) {
  const namedType = graphql.getNamedType(returnType);
  if (graphql.isLeafType(namedType)) {
    return document;
  }
  let possibleTypes = graphql.isAbstractType(
    namedType
  ) ? targetSchema.getPossibleTypes(namedType) : [namedType];
  if (possibleTypes.length === 0) {
    possibleTypes = [namedType];
  }
  const rootTypeNames = utils.getRootTypeNames(targetSchema);
  const typeInfo = getTypeInfo(targetSchema);
  const visitorKeys = {
    Document: ["definitions"],
    OperationDefinition: ["selectionSet"],
    SelectionSet: ["selections"],
    InlineFragment: ["selectionSet"],
    FragmentDefinition: ["selectionSet"]
  };
  return graphql.visit(
    document,
    graphql.visitWithTypeInfo(typeInfo, {
      [graphql.Kind.FRAGMENT_DEFINITION]: (node) => {
        const typeName = node.typeCondition.name.value;
        if (!rootTypeNames.has(typeName)) {
          return false;
        }
        return void 0;
      },
      [graphql.Kind.FIELD]: (node) => {
        const fieldType = typeInfo.getType();
        if (fieldType) {
          const fieldNamedType = graphql.getNamedType(fieldType);
          if (graphql.isAbstractType(fieldNamedType) && fieldNamedType.name !== namedType.name && possibleTypes.length > 0) {
            return {
              ...node,
              selectionSet: {
                kind: graphql.Kind.SELECTION_SET,
                selections: possibleTypes.map((possibleType) => ({
                  kind: graphql.Kind.INLINE_FRAGMENT,
                  typeCondition: {
                    kind: graphql.Kind.NAMED_TYPE,
                    name: {
                      kind: graphql.Kind.NAME,
                      value: possibleType.name
                    }
                  },
                  selectionSet: node.selectionSet
                }))
              }
            };
          }
        }
        return void 0;
      }
    }),
    // visitorKeys argument usage a la https://github.com/gatsbyjs/gatsby/blob/master/packages/gatsby-source-graphql/src/batching/merge-queries.js
    // empty keys cannot be removed only because of typescript errors
    // will hopefully be fixed in future version of graphql-js to be optional
    visitorKeys
  );
}

class Transformer {
  transformations = [];
  delegationContext;
  hasOverlappingAliases = false;
  constructor(context) {
    this.delegationContext = context;
    const transforms = context.transforms;
    const delegationTransforms = transforms.slice().reverse();
    for (const transform of delegationTransforms) {
      this.addTransform(transform);
    }
  }
  addTransform(transform, context = {}) {
    this.transformations.push({ transform, context });
  }
  transformRequest(originalRequest) {
    let request = {
      ...originalRequest,
      document: prepareGatewayDocument(
        originalRequest.document,
        this.delegationContext
      )
    };
    for (const transformation of this.transformations) {
      if (transformation.transform.transformRequest) {
        request = transformation.transform.transformRequest(
          request,
          this.delegationContext,
          transformation.context
        );
      }
    }
    return finalizeGatewayRequest(request, this.delegationContext, () => {
      this.hasOverlappingAliases = true;
    });
  }
  transformResult(originalResult) {
    let result = originalResult;
    for (let i = this.transformations.length - 1; i >= 0; i--) {
      const transformation = this.transformations[i];
      if (transformation?.transform.transformResult) {
        result = transformation.transform.transformResult(
          result,
          this.delegationContext,
          transformation.context
        );
      }
    }
    if (this.hasOverlappingAliases) {
      result = removeOverlappingAliases(result);
    }
    return checkResultAndHandleErrors(result, this.delegationContext);
  }
}
function removeOverlappingAliases(result) {
  if (result != null) {
    if (Array.isArray(result)) {
      return result.map(removeOverlappingAliases);
    } else if (typeof result === "object") {
      const newResult = {};
      for (const key in result) {
        if (key.startsWith("_nullable_") || key.startsWith("_nonNullable_")) {
          const newKey = key.replace(/^_nullable_/, "").replace(/^_nonNullable_/, "");
          newResult[newKey] = removeOverlappingAliases(result[key]);
        } else {
          newResult[key] = removeOverlappingAliases(result[key]);
        }
      }
      return newResult;
    }
  }
  return result;
}

function getDelegatingOperation(parentType, schema) {
  if (parentType === schema.getMutationType()) {
    return "mutation";
  } else if (parentType === schema.getSubscriptionType()) {
    return "subscription";
  }
  return "query";
}
function createRequest({
  subgraphName,
  fragments,
  rootValue,
  targetOperationName,
  targetOperation,
  targetSchema,
  targetFieldName,
  selectionSet,
  fieldNodes,
  context,
  info,
  args
}) {
  let newSelectionSet;
  if (selectionSet != null) {
    newSelectionSet = selectionSet;
  } else {
    const selections = [];
    for (const fieldNode2 of fieldNodes || []) {
      if (fieldNode2.selectionSet) {
        for (const selection of fieldNode2.selectionSet.selections) {
          selections.push(selection);
        }
      }
    }
    newSelectionSet = selections.length ? {
      kind: graphql.Kind.SELECTION_SET,
      selections
    } : void 0;
  }
  const fieldNode = fieldNodes?.[0];
  const rootFieldName = targetFieldName ?? fieldNode?.name.value;
  if (rootFieldName === void 0) {
    throw new Error(
      `Either "targetFieldName" or a non empty "fieldNodes" array must be provided.`
    );
  }
  const newVariables = info?.variableValues ? { ...info.variableValues } : {};
  const variableDefinitions = info?.operation.variableDefinitions ? [...info.operation.variableDefinitions] : [];
  const argNodes = [];
  if (args != null) {
    const rootType = targetSchema != null ? utils.getDefinedRootType(targetSchema, targetOperation) : void 0;
    const rootField = rootType?.getFields()[rootFieldName];
    const rootFieldArgs = rootField?.args;
    for (const argName in args) {
      const argValue = args[argName];
      const argInstance = rootFieldArgs?.find((arg) => arg.name === argName);
      const existingArgNode = fieldNode?.arguments?.find(
        (argNode) => argNode.name.value === argName
      );
      if (existingArgNode?.value.kind === graphql.Kind.VARIABLE) {
        const varName = existingArgNode.value.name.value;
        const varValue = newVariables[varName];
        if (varValue === argValue) {
          argNodes.push(existingArgNode);
          continue;
        }
      }
      if (argInstance) {
        const argAst = utils.astFromArg(argInstance, targetSchema);
        const varExists = (varName2) => variableDefinitions.some(
          (varDef) => varDef.variable.name.value === varName2
        ) || // It should not conflict with the variable on the gateway request
        // Because the gateway request can have a variable that has nothing to do with
        // this argument
        info?.variableValues?.[varName2] != null;
        let varName = argName;
        if (varExists(varName)) {
          varName = `_${rootFieldName}_${argName}`;
          let i = 0;
          while (varExists(varName)) {
            varName = `_${i++}_${rootFieldName}_${argName}`;
          }
        }
        variableDefinitions.push({
          kind: graphql.Kind.VARIABLE_DEFINITION,
          variable: {
            kind: graphql.Kind.VARIABLE,
            name: {
              kind: graphql.Kind.NAME,
              value: varName
            }
          },
          type: argAst.type
        });
        const varValue = projectArgumentValue(argValue, argInstance.type);
        if (varValue !== void 0) {
          newVariables[varName] = varValue;
        }
        argNodes.push({
          kind: graphql.Kind.ARGUMENT,
          name: {
            kind: graphql.Kind.NAME,
            value: argName
          },
          value: {
            kind: graphql.Kind.VARIABLE,
            name: {
              kind: graphql.Kind.NAME,
              value: varName
            }
          }
        });
      } else {
        const valueNode = utils.astFromValueUntyped(argValue);
        if (valueNode != null) {
          argNodes.push({
            kind: graphql.Kind.ARGUMENT,
            name: {
              kind: graphql.Kind.NAME,
              value: argName
            },
            value: valueNode
          });
        }
      }
    }
  }
  const rootfieldNode = {
    kind: graphql.Kind.FIELD,
    arguments: argNodes,
    name: {
      kind: graphql.Kind.NAME,
      value: rootFieldName
    },
    selectionSet: newSelectionSet,
    directives: fieldNode?.directives
  };
  const operationName = targetOperationName ? {
    kind: graphql.Kind.NAME,
    value: targetOperationName
  } : void 0;
  const operationDefinition = {
    kind: graphql.Kind.OPERATION_DEFINITION,
    name: operationName,
    operation: targetOperation,
    variableDefinitions,
    selectionSet: {
      kind: graphql.Kind.SELECTION_SET,
      selections: [rootfieldNode]
    }
  };
  const definitions = [operationDefinition];
  if (fragments != null) {
    definitions.push(...fragments);
  }
  const document = {
    kind: graphql.Kind.DOCUMENT,
    definitions
  };
  return {
    subgraphName,
    document,
    variables: newVariables,
    rootValue,
    operationName: targetOperationName,
    context,
    info,
    operationType: targetOperation
  };
}
function projectArgumentValue(argValue, argType) {
  if (argValue == null) {
    return argValue;
  }
  if (graphql.isNonNullType(argType)) {
    return projectArgumentValue(argValue, argType.ofType);
  }
  if (graphql.isListType(argType)) {
    return utils.asArray(argValue).map(
      (item) => projectArgumentValue(item, argType.ofType)
    );
  }
  if (graphql.isInputObjectType(argType) && typeof argValue === "object") {
    const projectedValue = {};
    const fields = argType.getFields();
    for (const key in argValue) {
      const field = fields[key];
      if (field) {
        const varValue = projectArgumentValue(argValue[key], field.type);
        if (varValue !== void 0) {
          projectedValue[key] = varValue;
        }
      }
    }
    return projectedValue;
  }
  if (argType.name === "Boolean") {
    return Boolean(argValue);
  }
  if (argType.name === "Int" || argType.name === "Float") {
    return Number(argValue);
  }
  if (argType.name === "String") {
    return String(argValue);
  }
  return argValue;
}

function defaultMergedResolver(parent, args, context, info) {
  if (!parent) {
    return null;
  }
  const responseKey = utils.getResponseKeyFromInfo(info);
  if (!isExternalObject(parent)) {
    return graphql.defaultFieldResolver(parent, args, context, info);
  }
  if (!Object.prototype.hasOwnProperty.call(parent, responseKey)) {
    const leftOver = getPlanLeftOverFromParent(parent);
    if (leftOver) {
      let missingFieldNodes = leftOver.missingFieldsParentMap.get(parent);
      if (!missingFieldNodes) {
        missingFieldNodes = [];
        leftOver.missingFieldsParentMap.set(parent, missingFieldNodes);
      }
      missingFieldNodes.push(
        ...info.fieldNodes.filter(
          (fieldNode) => leftOver.unproxiableFieldNodes.some(
            (unproxiableFieldNode) => unproxiableFieldNode === fieldNode
          )
        )
      );
      let missingDeferredFields = leftOver.missingFieldsParentDeferredMap.get(parent);
      if (!missingDeferredFields) {
        missingDeferredFields = /* @__PURE__ */ new Map();
        leftOver.missingFieldsParentDeferredMap.set(
          parent,
          missingDeferredFields
        );
      }
      const deferred = promiseHelpers.createDeferredPromise();
      missingDeferredFields.set(responseKey, deferred);
      const stitchingInfo = info.schema.extensions?.["stitchingInfo"];
      const parentTypeName = parent?.__typename || info.parentType.name;
      const fieldNodesByType = stitchingInfo?.fieldNodesByField?.[parentTypeName]?.[info.fieldName];
      if (fieldNodesByType?.every((fieldNode) => {
        const responseKey2 = fieldNode.alias?.value ?? fieldNode.name.value;
        return Object.prototype.hasOwnProperty.call(parent, responseKey2);
      })) {
        handleResult(parent, responseKey, context, info);
      } else {
        handleLeftOver(parent, context, info, leftOver);
      }
      return deferred.promise;
    }
    return void 0;
  }
  return handleResult(parent, responseKey, context, info);
}
function handleResult(parent, responseKey, context, info) {
  const subschema = getSubschema(parent, responseKey);
  const data = parent[responseKey];
  const unpathedErrors = getUnpathedErrors(parent);
  const resolvedData$ = resolveExternalValue(
    data,
    unpathedErrors,
    subschema,
    context,
    info
  );
  const leftOver = getPlanLeftOverFromParent(parent);
  if (leftOver) {
    return promiseHelpers.handleMaybePromise(
      () => resolvedData$,
      (resolvedData) => {
        parent[responseKey] = resolvedData;
        handleLeftOver(parent, context, info, leftOver);
        return resolvedData;
      }
    );
  }
  return resolvedData$;
}
function handleLeftOver(parent, context, info, leftOver) {
  const stitchingInfo = info.schema.extensions?.["stitchingInfo"];
  if (stitchingInfo) {
    for (const possibleSubschema of leftOver.nonProxiableSubschemas) {
      const parentTypeName = info.parentType.name;
      const selectionSets = /* @__PURE__ */ new Set();
      const mainSelectionSet = stitchingInfo.mergedTypes[parentTypeName]?.selectionSets.get(
        possibleSubschema
      );
      if (mainSelectionSet) {
        selectionSets.add(mainSelectionSet);
      }
      for (const fieldNode of leftOver.unproxiableFieldNodes) {
        const fieldName = fieldNode.name.value;
        const fieldSelectionSet = stitchingInfo.mergedTypes[parentTypeName]?.fieldSelectionSets.get(
          possibleSubschema
        )?.[fieldName];
        if (fieldSelectionSet) {
          selectionSets.add(fieldSelectionSet);
        }
      }
      if (selectionSets.size) {
        const selectionSet = {
          kind: graphql.Kind.SELECTION_SET,
          selections: Array.from(selectionSets).flatMap(
            (selectionSet2) => selectionSet2.selections
          )
        };
        promiseHelpers.handleMaybePromise(
          () => flattenPromise(parent),
          (flattenedParent) => {
            handleFlattenedParent(
              flattenedParent,
              parent,
              possibleSubschema,
              selectionSet,
              leftOver,
              stitchingInfo,
              parentTypeName,
              context,
              info
            );
          }
        );
      }
    }
  }
}
function handleFlattenedParent(flattenedParent, leftOverParent, possibleSubschema, selectionSet, leftOver, stitchingInfo, parentTypeName, context, info) {
  if (parentSatisfiedSelectionSet(flattenedParent, selectionSet)) {
    const missingFieldNodes = leftOver.missingFieldsParentMap.get(leftOverParent);
    if (missingFieldNodes) {
      const resolver = stitchingInfo.mergedTypes[parentTypeName]?.resolvers.get(
        possibleSubschema
      );
      if (resolver) {
        Object.assign(leftOverParent, flattenedParent);
        const selectionSet2 = {
          kind: graphql.Kind.SELECTION_SET,
          selections: missingFieldNodes
        };
        promiseHelpers.handleMaybePromise(
          () => resolver(
            leftOverParent,
            context,
            info,
            possibleSubschema,
            selectionSet2,
            info.parentType,
            info.parentType
          ),
          (resolverResult) => {
            handleDeferredResolverResult(
              resolverResult,
              possibleSubschema,
              selectionSet2,
              leftOverParent,
              leftOver,
              context,
              info
            );
          },
          (error) => handleDeferredResolverFailure(leftOver, leftOverParent, error)
        );
      }
    }
  } else {
    for (const selectionNode of selectionSet.selections) {
      if (selectionNode.kind === graphql.Kind.FIELD && selectionNode.selectionSet?.selections?.length) {
        const responseKey = selectionNode.alias?.value ?? selectionNode.name.value;
        const nestedParent = flattenedParent[responseKey];
        const nestedSelectionSet = selectionNode.selectionSet;
        if (nestedParent != null) {
          if (!parentSatisfiedSelectionSet(nestedParent, nestedSelectionSet)) {
            async function handleNestedParentItem(nestedParentItem, fieldNode) {
              const nestedTypeName = nestedParentItem["__typename"];
              const sourceSubschema = getSubschema(
                flattenedParent,
                responseKey
              );
              if (sourceSubschema && nestedTypeName) {
                const delegationPlan = stitchingInfo.mergedTypes[nestedTypeName]?.delegationPlanBuilder(
                  info.schema,
                  sourceSubschema,
                  info.variableValues != null && Object.keys(info.variableValues).length > 0 ? info.variableValues : EMPTY_OBJECT,
                  info.fragments != null && Object.keys(info.fragments).length > 0 ? info.fragments : EMPTY_OBJECT,
                  getActualFieldNodes(fieldNode),
                  context,
                  info
                );
                if (delegationPlan?.length) {
                  for (const delegationMap of delegationPlan) {
                    for (const [subschema, selectionSet2] of delegationMap) {
                      const resolver = stitchingInfo.mergedTypes[nestedTypeName]?.resolvers.get(subschema);
                      if (resolver) {
                        const subschemaTypes = stitchingInfo.mergedTypes[nestedTypeName].typeMaps.get(subschema);
                        const returnType = subschemaTypes[nestedTypeName];
                        const res = await resolver(
                          nestedParentItem,
                          context,
                          info,
                          subschema,
                          selectionSet2,
                          returnType,
                          // returnType
                          info.parentType
                        );
                        if (res) {
                          handleResolverResult(
                            res,
                            subschema,
                            selectionSet2,
                            nestedParentItem,
                            nestedParentItem[FIELD_SUBSCHEMA_MAP_SYMBOL] ||= /* @__PURE__ */ new Map(),
                            info,
                            graphql.responsePathAsArray(info.path),
                            nestedParentItem[UNPATHED_ERRORS_SYMBOL] ||= []
                          );
                        }
                      }
                    }
                  }
                }
                if (parentSatisfiedSelectionSet(nestedParent, nestedSelectionSet)) {
                  handleFlattenedParent(
                    flattenedParent,
                    leftOverParent,
                    possibleSubschema,
                    selectionSet,
                    leftOver,
                    stitchingInfo,
                    parentTypeName,
                    context,
                    info
                  );
                }
              }
            }
            if (Array.isArray(nestedParent)) {
              nestedParent.forEach(
                (nestedParentItem) => handleNestedParentItem(nestedParentItem, selectionNode)
              );
            } else {
              handleNestedParentItem(nestedParent, selectionNode);
            }
          }
        }
      }
    }
  }
}
function handleDeferredResolverResult(resolverResult, possibleSubschema, selectionSet, leftOverParent, leftOver, context, info) {
  handleResolverResult(
    resolverResult,
    possibleSubschema,
    selectionSet,
    leftOverParent,
    leftOverParent[FIELD_SUBSCHEMA_MAP_SYMBOL],
    info,
    graphql.responsePathAsArray(info.path),
    leftOverParent[UNPATHED_ERRORS_SYMBOL]
  );
  const deferredFields = leftOver.missingFieldsParentDeferredMap.get(leftOverParent);
  if (deferredFields) {
    const stitchingInfo = info.schema.extensions?.["stitchingInfo"];
    const parentTypeName = leftOverParent?.__typename || info.parentType.name;
    const resolvedKeys = /* @__PURE__ */ new Set();
    for (const [responseKey, deferred] of deferredFields) {
      if (Object.prototype.hasOwnProperty.call(leftOverParent, responseKey)) {
        deferred.resolve(
          handleResult(leftOverParent, responseKey, context, info)
        );
        resolvedKeys.add(responseKey);
      } else {
        const fieldNodesByType = stitchingInfo?.fieldNodesByField?.[parentTypeName]?.[responseKey];
        if (fieldNodesByType) {
          if (fieldNodesByType.every((fieldNode) => {
            const requiredKey = fieldNode.alias?.value ?? fieldNode.name.value;
            return Object.prototype.hasOwnProperty.call(
              leftOverParent,
              requiredKey
            );
          })) {
            setTimeout(() => {
              handleLeftOver(leftOverParent, context, info, leftOver);
            }, 0);
          }
        }
      }
    }
    for (const key of resolvedKeys) {
      deferredFields.delete(key);
    }
    if (deferredFields.size === 0) {
      leftOver.missingFieldsParentDeferredMap.delete(leftOverParent);
    }
  }
}
function handleDeferredResolverFailure(leftOver, leftOverParent, error) {
  const deferredFields = leftOver.missingFieldsParentDeferredMap.get(leftOverParent);
  if (deferredFields) {
    for (const [_responseKey, deferred] of deferredFields) {
      deferred.reject(error);
    }
    leftOver.missingFieldsParentDeferredMap.delete(leftOverParent);
  }
}
function parentSatisfiedSelectionSet(parent, selectionSet) {
  if (Array.isArray(parent)) {
    const subschemas2 = /* @__PURE__ */ new Set();
    for (const item of parent) {
      const satisfied = parentSatisfiedSelectionSet(item, selectionSet);
      if (satisfied === void 0) {
        return void 0;
      }
      for (const subschema of satisfied) {
        subschemas2.add(subschema);
      }
    }
    return subschemas2;
  }
  if (parent === null) {
    return /* @__PURE__ */ new Set();
  }
  if (parent === void 0) {
    return void 0;
  }
  const subschemas = /* @__PURE__ */ new Set();
  for (const selection of selectionSet.selections) {
    if (selection.kind === graphql.Kind.FIELD) {
      const responseKey = selection.alias?.value ?? selection.name.value;
      if (parent[responseKey] === void 0) {
        return void 0;
      }
      if (isExternalObject(parent)) {
        const subschema = getSubschema(parent, responseKey);
        if (subschema) {
          subschemas.add(subschema);
        }
      }
      if (parent[responseKey] === null) {
        continue;
      }
      if (selection.selectionSet != null) {
        const satisfied = parentSatisfiedSelectionSet(
          parent[responseKey],
          selection.selectionSet
        );
        if (satisfied === void 0) {
          return void 0;
        }
        for (const subschema of satisfied) {
          subschemas.add(subschema);
        }
      }
    } else if (selection.kind === graphql.Kind.INLINE_FRAGMENT) {
      const inlineSatisfied = parentSatisfiedSelectionSet(
        parent,
        selection.selectionSet
      );
      if (inlineSatisfied === void 0) {
        return void 0;
      }
      for (const subschema of inlineSatisfied) {
        subschemas.add(subschema);
      }
    }
  }
  return subschemas;
}
function flattenPromise(data) {
  if (promiseHelpers.isPromise(data)) {
    return data.then(flattenPromise);
  }
  if (Array.isArray(data)) {
    return Promise.all(data.map(flattenPromise));
  }
  if (data != null && typeof data === "object") {
    const jobs = [];
    const newData = {};
    for (const key in data) {
      const keyResult = flattenPromise(data[key]);
      if (promiseHelpers.isPromise(keyResult)) {
        jobs.push(
          keyResult.then((resolvedKeyResult) => {
            newData[key] = resolvedKeyResult;
          })
        );
      } else {
        newData[key] = keyResult;
      }
    }
    if (OBJECT_SUBSCHEMA_SYMBOL in data) {
      newData[OBJECT_SUBSCHEMA_SYMBOL] = data[OBJECT_SUBSCHEMA_SYMBOL];
    }
    if (FIELD_SUBSCHEMA_MAP_SYMBOL in data) {
      newData[FIELD_SUBSCHEMA_MAP_SYMBOL] = data[FIELD_SUBSCHEMA_MAP_SYMBOL];
    }
    if (UNPATHED_ERRORS_SYMBOL in data) {
      newData[UNPATHED_ERRORS_SYMBOL] = data[UNPATHED_ERRORS_SYMBOL];
    }
    if (jobs.length) {
      return Promise.all(jobs).then(() => newData);
    }
    return newData;
  }
  return data;
}

function isSubschemaConfig(value) {
  return Boolean(value?.schema);
}
function cloneSubschemaConfig(subschemaConfig) {
  const newSubschemaConfig = {
    ...subschemaConfig,
    transforms: subschemaConfig.transforms != null ? [...subschemaConfig.transforms] : void 0
  };
  if (newSubschemaConfig.merge != null) {
    newSubschemaConfig.merge = { ...subschemaConfig.merge };
    for (const typeName in newSubschemaConfig.merge) {
      const mergedTypeConfig = newSubschemaConfig.merge[typeName] = {
        ...subschemaConfig.merge?.[typeName] ?? {}
      };
      if (mergedTypeConfig.entryPoints != null) {
        mergedTypeConfig.entryPoints = mergedTypeConfig.entryPoints.map(
          (entryPoint) => ({
            ...entryPoint
          })
        );
      }
      if (mergedTypeConfig.fields != null) {
        const fields = mergedTypeConfig.fields = {
          ...mergedTypeConfig.fields
        };
        for (const fieldName in fields) {
          fields[fieldName] = { ...fields[fieldName] };
        }
      }
    }
  }
  return newSubschemaConfig;
}

const getFragmentDefinitions = utils.memoize1(
  (info) => {
    const fragmentMap = info.fragments;
    return Object.values(fragmentMap);
  }
);
function delegateToSchema(options) {
  const {
    info,
    schema,
    rootValue = schema.rootValue ?? info.rootValue,
    operationName = info.operation.name?.value,
    operation = getDelegatingOperation(info.parentType, info.schema),
    fieldName = info.fieldName,
    selectionSet,
    fieldNodes = info.fieldNodes,
    context,
    args
  } = options;
  let targetSchema;
  if (isSubschema(schema)) {
    targetSchema = schema.transformedSchema;
  } else if (graphql.isSchema(schema)) {
    targetSchema = schema;
  } else {
    const stitchingInfo = info.schema.extensions?.["stitchingInfo"];
    const subschema = stitchingInfo?.subschemaMap.get(schema);
    if (subschema != null) {
      targetSchema = subschema.transformedSchema;
    } else {
      targetSchema = applySchemaTransforms(schema.schema, schema);
    }
  }
  const fragments = info ? getFragmentDefinitions(info) : void 0;
  const request = createRequest({
    subgraphName: schema.name,
    fragments,
    targetSchema,
    rootValue,
    targetOperationName: operationName,
    targetOperation: operation,
    targetFieldName: fieldName,
    selectionSet,
    fieldNodes,
    context,
    info,
    args
  });
  return delegateRequest({
    ...options,
    targetSchema,
    request
  });
}
function getDelegationReturnType(targetSchema, operation, fieldName) {
  const rootType = utils.getDefinedRootType(targetSchema, operation);
  const rootFieldType = rootType.getFields()[fieldName];
  if (!rootFieldType) {
    throw new Error(
      `Unable to find field '${fieldName}' in type '${rootType}'.`
    );
  }
  return rootFieldType.type;
}
function delegateRequest(options) {
  const delegationContext = getDelegationContext(options);
  const transformer = new Transformer(delegationContext);
  const processedRequest = transformer.transformRequest(options.request);
  if (options.validateRequest) {
    validateRequest(delegationContext, processedRequest.document);
  }
  return promiseHelpers.handleMaybePromise(
    () => getExecutor(delegationContext)(processedRequest),
    function handleExecutorResult(executorResult) {
      if (utils.isAsyncIterable(executorResult)) {
        if (delegationContext.operation === "query" && graphql.isListType(graphql.getNullableType(delegationContext.returnType))) {
          return new repeater.Repeater(async (push, stop) => {
            let pushedCount = 0;
            let stopped = false;
            stop.finally(() => {
              stopped = true;
            });
            try {
              for await (const result of executorResult) {
                if (stopped) {
                  break;
                }
                if (result.incremental) {
                  const data = {};
                  for (const incrementalRes of result.incremental) {
                    if (incrementalRes.items?.length) {
                      for (const item of incrementalRes.items) {
                        setObjectKeyPath(
                          data,
                          (incrementalRes.path || []).slice(0, -1),
                          item
                        );
                      }
                      await push(await transformer.transformResult({ data }));
                    }
                  }
                  if (result.hasNext === false) {
                    break;
                  } else {
                    continue;
                  }
                }
                const transformedResult = await transformer.transformResult(result);
                if (Array.isArray(transformedResult)) {
                  for (let i = pushedCount; i < transformedResult.length; i++) {
                    if (stopped) {
                      break;
                    }
                    await push(await transformedResult[i]);
                    pushedCount = i + 1;
                  }
                } else {
                  await push(await transformedResult);
                }
              }
              stop();
            } catch (error) {
              stop(error);
            }
          });
        }
        return promiseHelpers.mapAsyncIterator(
          executorResult,
          (result) => transformer.transformResult(result)
        );
      }
      return transformer.transformResult(executorResult);
    }
  );
}
function getDelegationContext({
  request,
  schema,
  fieldName,
  returnType,
  info,
  args,
  transforms = [],
  targetSchema: transformedSchema,
  skipTypeMerging = false,
  onLocatedError
}) {
  const operationDefinition = utils.getOperationASTFromRequest(request);
  let targetFieldName;
  if (fieldName == null) {
    targetFieldName = operationDefinition.selectionSet.selections[0].name.value;
  } else {
    targetFieldName = fieldName;
  }
  const stitchingInfo = info?.schema.extensions?.["stitchingInfo"];
  const subschemaOrSubschemaConfig = stitchingInfo?.subschemaMap.get(schema) ?? schema;
  const operation = operationDefinition.operation;
  if (isSubschemaConfig(subschemaOrSubschemaConfig)) {
    const targetSchema = subschemaOrSubschemaConfig.schema;
    return {
      subschema: schema,
      subschemaConfig: subschemaOrSubschemaConfig,
      targetSchema,
      operation,
      fieldName: targetFieldName,
      context: request.context,
      info,
      returnType: returnType ?? info?.returnType ?? getDelegationReturnType(targetSchema, operation, targetFieldName),
      transforms: subschemaOrSubschemaConfig.transforms != null ? subschemaOrSubschemaConfig.transforms.concat(transforms) : transforms,
      transformedSchema,
      skipTypeMerging,
      onLocatedError,
      args
    };
  }
  return {
    subschema: schema,
    subschemaConfig: void 0,
    targetSchema: subschemaOrSubschemaConfig,
    operation,
    fieldName: targetFieldName,
    context: request.context,
    info,
    returnType: returnType ?? info?.returnType ?? getDelegationReturnType(
      subschemaOrSubschemaConfig,
      operation,
      targetFieldName
    ),
    transforms,
    transformedSchema: transformedSchema ?? subschemaOrSubschemaConfig,
    skipTypeMerging,
    onLocatedError,
    args
  };
}
function validateRequest(delegationContext, document) {
  const errors = graphql.validate(delegationContext.targetSchema, document);
  if (errors.length > 0) {
    if (errors.length > 1) {
      const combinedError = new AggregateError(
        errors,
        errors.map((error2) => error2.message).join(", \n")
      );
      throw combinedError;
    }
    const error = errors[0];
    if (error) {
      throw error.originalError || error;
    }
  }
}
const GLOBAL_CONTEXT = {};
function getExecutor(delegationContext) {
  const { subschemaConfig, targetSchema, context } = delegationContext;
  let executor$1 = subschemaConfig?.executor || executor.executorFromSchema(targetSchema);
  if (subschemaConfig?.batch) {
    const batchingOptions = subschemaConfig?.batchingOptions;
    executor$1 = batchExecute.getBatchingExecutor(
      context ?? GLOBAL_CONTEXT,
      executor$1,
      batchingOptions?.dataLoaderOptions,
      batchingOptions?.extensionsReducer
    );
  }
  return executor$1;
}
function setObjectKeyPath(obj, path, value) {
  let current = obj;
  for (let i = 0; i < path.length - 1; i++) {
    const key = path[i];
    if (key == null || key === "__proto__" || key === "constructor" || key === "prototype") {
      return;
    }
    if (current[key] == null) {
      current[key] = typeof path[i + 1] === "number" ? [] : {};
    }
    current = current[key];
  }
  const lastKey = path[path.length - 1];
  if (lastKey == null || lastKey === "__proto__" || lastKey === "constructor" || lastKey === "prototype") {
    return;
  }
  const existingValue = current[lastKey];
  current[lastKey] = existingValue ? utils.mergeDeep([existingValue, value]) : value;
}

function extractUnavailableFieldsFromSelectionSet(schema, fieldType, fieldSelectionSet, shouldAdd, fragments = {}) {
  if (graphql.isLeafType(fieldType)) {
    return [];
  }
  if (graphql.isUnionType(fieldType)) {
    const unavailableSelections2 = [];
    for (const type of fieldType.getTypes()) {
      const fieldSelectionExcluded = {
        ...fieldSelectionSet,
        selections: fieldSelectionSet.selections.filter(
          (selection) => selection.kind === graphql.Kind.INLINE_FRAGMENT ? selection.typeCondition ? selection.typeCondition.name.value === type.name : false : true
        )
      };
      unavailableSelections2.push(
        ...extractUnavailableFieldsFromSelectionSet(
          schema,
          type,
          fieldSelectionExcluded,
          shouldAdd,
          fragments
        )
      );
    }
    return unavailableSelections2;
  }
  const subFields = fieldType.getFields();
  const unavailableSelections = [];
  for (const selection of fieldSelectionSet.selections) {
    if (selection.kind === graphql.Kind.FIELD) {
      if (selection.name.value === "__typename") {
        continue;
      }
      const fieldName = selection.name.value;
      const selectionField = subFields[fieldName];
      if (!selectionField) {
        if (shouldAdd(fieldType, selection)) {
          unavailableSelections.push(selection);
        }
      } else {
        const unavailableSubFields = extractUnavailableFields(
          schema,
          selectionField,
          selection,
          shouldAdd,
          fragments
        );
        if (unavailableSubFields.length) {
          unavailableSelections.push({
            ...selection,
            selectionSet: {
              kind: graphql.Kind.SELECTION_SET,
              selections: unavailableSubFields
            }
          });
        }
      }
    } else if (selection.kind === graphql.Kind.INLINE_FRAGMENT) {
      const subFieldName = selection.typeCondition?.name.value || fieldType.name;
      const subFieldType = selection.typeCondition && schema.getType(subFieldName) || fieldType;
      if (subFieldName === fieldType.name || (graphql.isObjectType(subFieldType) || graphql.isInterfaceType(subFieldType)) && graphql.isAbstractType(fieldType) && schema.isSubType(fieldType, subFieldType)) {
        const unavailableFields = extractUnavailableFieldsFromSelectionSet(
          schema,
          subFieldType,
          selection.selectionSet,
          shouldAdd,
          fragments
        );
        if (unavailableFields.length) {
          unavailableSelections.push({
            ...selection,
            selectionSet: {
              kind: graphql.Kind.SELECTION_SET,
              selections: unavailableFields
            }
          });
        }
      } else if (graphql.isObjectType(subFieldType) || graphql.isInterfaceType(subFieldType)) {
        const subFieldTypeFields = subFieldType.getFields();
        for (const subSelection of selection.selectionSet.selections) {
          if (subSelection.kind === graphql.Kind.FIELD) {
            const subSelectionFieldName = subSelection.name.value;
            if (subSelectionFieldName === "__typename") {
              continue;
            }
            const subSelectionField = subFieldTypeFields[subSelection.name.value];
            if (!subSelectionField) {
              if (shouldAdd(subFieldType, subSelection)) {
                unavailableSelections.push(subSelection);
              }
            }
          }
        }
      }
    } else if (selection.kind === graphql.Kind.FRAGMENT_SPREAD) {
      const fragment = fragments[selection.name.value];
      if (fragment) {
        const fragmentUnavailableFields = extractUnavailableFieldsFromSelectionSet(
          schema,
          fieldType,
          {
            kind: graphql.Kind.SELECTION_SET,
            selections: [
              {
                kind: graphql.Kind.INLINE_FRAGMENT,
                typeCondition: {
                  kind: graphql.Kind.NAMED_TYPE,
                  name: {
                    kind: graphql.Kind.NAME,
                    value: fragment.typeCondition.name.value
                  }
                },
                selectionSet: fragment.selectionSet
              }
            ]
          },
          shouldAdd,
          fragments
        );
        if (fragmentUnavailableFields.length) {
          unavailableSelections.push(...fragmentUnavailableFields);
        }
      }
    }
  }
  return unavailableSelections;
}
function extractUnavailableFields(schema, field, fieldNode, shouldAdd, fragments = {}) {
  if (fieldNode.selectionSet) {
    const fieldType = graphql.getNamedType(field.type);
    return extractUnavailableFieldsFromSelectionSet(
      schema,
      fieldType,
      fieldNode.selectionSet,
      shouldAdd,
      fragments
    );
  }
  return [];
}
function subtractSelectionSets(selectionSetA, selectionSetB) {
  const newSelections = [];
  for (const selectionA of selectionSetA.selections) {
    switch (selectionA.kind) {
      case graphql.Kind.FIELD: {
        const fieldA = selectionA;
        const fieldsInOtherSelectionSet = selectionSetB.selections.filter(
          (subselectionB) => {
            if (subselectionB.kind !== graphql.Kind.FIELD) {
              return false;
            }
            return fieldA.name.value === subselectionB.name.value;
          }
        );
        if (fieldsInOtherSelectionSet.length > 0 && fieldA.selectionSet?.selections?.length) {
          const newSubSelection = fieldsInOtherSelectionSet.reduce(
            (acc, fieldB) => fieldB.selectionSet ? subtractSelectionSets(acc, fieldB.selectionSet) : acc,
            {
              kind: graphql.Kind.SELECTION_SET,
              selections: fieldA.selectionSet.selections
            }
          );
          if (newSubSelection.selections.length) {
            newSelections.push({
              ...fieldA,
              selectionSet: newSubSelection
            });
          }
        } else if (fieldsInOtherSelectionSet.length === 0) {
          newSelections.push(selectionA);
        }
        break;
      }
      case graphql.Kind.INLINE_FRAGMENT: {
        const inlineFragmentA = selectionA;
        const inlineFragmentsFromB = selectionSetB.selections.filter(
          (subselectionB) => {
            if (subselectionB.kind !== graphql.Kind.INLINE_FRAGMENT) {
              return false;
            }
            const inlineFragmentB = subselectionB;
            return inlineFragmentA.typeCondition?.name.value === inlineFragmentB.typeCondition?.name.value;
          }
        );
        if (inlineFragmentsFromB.length > 0) {
          const newSubSelection = inlineFragmentsFromB.reduce(
            (acc, subselectionB) => subselectionB.selectionSet ? subtractSelectionSets(acc, subselectionB.selectionSet) : acc,
            {
              kind: graphql.Kind.SELECTION_SET,
              selections: inlineFragmentA.selectionSet.selections
            }
          );
          if (newSubSelection.selections.length) {
            if (newSubSelection.selections.length === 1) {
              const onlySelection = newSubSelection.selections[0];
              if (onlySelection?.kind === graphql.Kind.FIELD) {
                const responseKey = onlySelection.alias?.value || onlySelection.name.value;
                if (responseKey === "__typename") {
                  continue;
                }
              }
            }
            newSelections.push({
              ...inlineFragmentA,
              selectionSet: newSubSelection
            });
          }
        } else {
          newSelections.push(selectionA);
        }
        break;
      }
      case graphql.Kind.FRAGMENT_SPREAD: {
        const fragmentSpreadA = selectionA;
        if (!selectionSetB.selections.some(
          (subselectionB) => subselectionB.kind === graphql.Kind.FRAGMENT_SPREAD && subselectionB.name.value === fragmentSpreadA.name.value
        )) {
          newSelections.push(selectionA);
        }
        break;
      }
    }
  }
  return {
    kind: graphql.Kind.SELECTION_SET,
    selections: newSelections
  };
}

Object.defineProperty(exports, "createDeferred", {
  enumerable: true,
  get: function () { return utils.createDeferred; }
});
Object.defineProperty(exports, "createDefaultExecutor", {
  enumerable: true,
  get: function () { return executor.executorFromSchema; }
});
exports.EMPTY_ARRAY = EMPTY_ARRAY;
exports.EMPTY_OBJECT = EMPTY_OBJECT;
exports.FIELD_SUBSCHEMA_MAP_SYMBOL = FIELD_SUBSCHEMA_MAP_SYMBOL;
exports.OBJECT_SUBSCHEMA_SYMBOL = OBJECT_SUBSCHEMA_SYMBOL;
exports.PLAN_LEFT_OVER = PLAN_LEFT_OVER;
exports.Subschema = Subschema;
exports.Transformer = Transformer;
exports.UNPATHED_ERRORS_SYMBOL = UNPATHED_ERRORS_SYMBOL;
exports.annotateExternalObject = annotateExternalObject;
exports.applySchemaTransforms = applySchemaTransforms;
exports.cloneSubschemaConfig = cloneSubschemaConfig;
exports.createRequest = createRequest;
exports.defaultMergedResolver = defaultMergedResolver;
exports.delegateRequest = delegateRequest;
exports.delegateToSchema = delegateToSchema;
exports.extractUnavailableFields = extractUnavailableFields;
exports.extractUnavailableFieldsFromSelectionSet = extractUnavailableFieldsFromSelectionSet;
exports.getActualFieldNodes = getActualFieldNodes;
exports.getDelegatingOperation = getDelegatingOperation;
exports.getPlanLeftOverFromParent = getPlanLeftOverFromParent;
exports.getSubschema = getSubschema;
exports.getTypeInfo = getTypeInfo;
exports.getTypeInfoWithType = getTypeInfoWithType;
exports.getUnpathedErrors = getUnpathedErrors;
exports.handleOverrideByDelegation = handleOverrideByDelegation;
exports.handleResolverResult = handleResolverResult;
exports.isExternalObject = isExternalObject;
exports.isPrototypePollutingKey = isPrototypePollutingKey;
exports.isSubschema = isSubschema;
exports.isSubschemaConfig = isSubschemaConfig;
exports.leftOverByDelegationPlan = leftOverByDelegationPlan;
exports.mergeFields = mergeFields;
exports.resolveExternalValue = resolveExternalValue;
exports.subtractSelectionSets = subtractSelectionSets;
