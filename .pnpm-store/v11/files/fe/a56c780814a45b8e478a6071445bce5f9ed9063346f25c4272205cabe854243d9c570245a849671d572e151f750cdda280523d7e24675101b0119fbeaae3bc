'use strict';

var utils = require('@graphql-tools/utils');
var promiseHelpers = require('@whatwg-node/promise-helpers');
var DataLoader = require('dataloader');
var graphql = require('graphql');

function _interopDefault (e) { return e && e.__esModule ? e : { default: e }; }

var DataLoader__default = /*#__PURE__*/_interopDefault(DataLoader);

function createPrefix(index) {
  return `_v${index}_`;
}
function matchKey(prefixedKey) {
  const match = /^_v(\d+)_(.*)$/.exec(prefixedKey);
  if (match && match.length === 3 && !isNaN(Number(match[1])) && match[2]) {
    return { index: Number(match[1]), originalKey: match[2] };
  }
  return null;
}
function parseKey(prefixedKey) {
  const match = matchKey(prefixedKey);
  if (!match) {
    throw new Error(`Key ${prefixedKey} is not correctly prefixed`);
  }
  return match;
}
function parseKeyFromPath(path) {
  let keyOffset = 0;
  let match = null;
  for (; !match && keyOffset < path.length; keyOffset++) {
    const pathKey = path[keyOffset];
    if (typeof pathKey === "string") {
      match = matchKey(pathKey);
    }
  }
  if (!match) {
    throw new Error(
      `Path ${path.join(".")} does not contain correctly prefixed key`
    );
  }
  return {
    ...match,
    keyOffset
  };
}

function mergeRequests(requests, extensionsReducer) {
  const firstRequest = requests[0];
  if (!firstRequest) {
    throw new Error("At least one request is required");
  }
  const requestCount = requests.length;
  if (requestCount === 1) {
    return firstRequest;
  }
  const mergedVariables = /* @__PURE__ */ Object.create(null);
  const mergedVariableDefinitions = [];
  const mergedSelections = [];
  const mergedFragmentDefinitions = [];
  let mergedExtensions = /* @__PURE__ */ Object.create(null);
  let subgraphName;
  let operationName;
  let operationType;
  let context;
  let info;
  let rootValue;
  for (let index = 0; index < requestCount; index++) {
    const request = requests[index];
    if (request) {
      subgraphName ??= request.subgraphName;
      operationName ??= request.operationName;
      operationType ??= request.operationType;
      context ??= request.context;
      info ??= request.info;
      rootValue ??= request.rootValue;
      const prefixedRequests = prefixRequest(createPrefix(index), request);
      for (const def of prefixedRequests.document.definitions) {
        if (isOperationDefinition(def)) {
          mergedSelections.push(...def.selectionSet.selections);
          operationType ??= def.operation;
          operationName ??= def.name?.value;
          if (def.variableDefinitions) {
            mergedVariableDefinitions.push(...def.variableDefinitions);
          }
        }
        if (isFragmentDefinition(def)) {
          mergedFragmentDefinitions.push(def);
        }
      }
      Object.assign(mergedVariables, prefixedRequests.variables);
      mergedExtensions = extensionsReducer(mergedExtensions, request);
    }
  }
  if (operationName == null) {
    operationName = info?.operation?.name?.value;
  }
  operationType ||= "query";
  const mergedOperationDefinition = {
    kind: graphql.Kind.OPERATION_DEFINITION,
    operation: operationType,
    variableDefinitions: mergedVariableDefinitions,
    selectionSet: {
      kind: graphql.Kind.SELECTION_SET,
      selections: mergedSelections
    },
    name: operationName ? {
      kind: graphql.Kind.NAME,
      value: operationName
    } : void 0
  };
  return {
    subgraphName,
    document: {
      kind: graphql.Kind.DOCUMENT,
      definitions: [mergedOperationDefinition, ...mergedFragmentDefinitions]
    },
    variables: mergedVariables,
    extensions: mergedExtensions,
    context,
    info,
    operationType,
    rootValue,
    operationName
  };
}
function prefixRequest(prefix, request) {
  function prefixNode(node) {
    return prefixNodeName(node, prefix);
  }
  let prefixedDocument = aliasTopLevelFields(prefix, request.document);
  let hasFragmentDefinitionsOrVariables = false;
  for (const def of prefixedDocument.definitions) {
    if (isFragmentDefinition(def) || isOperationDefinition(def) && !!def.variableDefinitions?.length) {
      hasFragmentDefinitionsOrVariables = true;
      break;
    }
  }
  const fragmentSpreadImpl = {};
  let hasFragments = false;
  if (hasFragmentDefinitionsOrVariables) {
    prefixedDocument = graphql.visit(prefixedDocument, {
      [graphql.Kind.VARIABLE]: prefixNode,
      [graphql.Kind.FRAGMENT_DEFINITION](node) {
        hasFragments = true;
        return prefixNode(node);
      },
      [graphql.Kind.FRAGMENT_SPREAD]: (node) => {
        node = prefixNodeName(node, prefix);
        fragmentSpreadImpl[node.name.value] = true;
        return node;
      }
    });
  }
  let prefixedVariables;
  const executionVariables = request.variables;
  if (executionVariables) {
    prefixedVariables = /* @__PURE__ */ Object.create(null);
    for (const variableName in executionVariables) {
      prefixedVariables[prefix + variableName] = executionVariables[variableName];
    }
  }
  if (hasFragments) {
    prefixedDocument = {
      ...prefixedDocument,
      definitions: prefixedDocument.definitions.filter(
        (def) => !isFragmentDefinition(def) || fragmentSpreadImpl[def.name.value]
      )
    };
  }
  return {
    document: prefixedDocument,
    variables: prefixedVariables
  };
}
function aliasTopLevelFields(prefix, document) {
  const transformer = {
    [graphql.Kind.OPERATION_DEFINITION]: (def) => {
      const { selections } = def.selectionSet;
      return {
        ...def,
        selectionSet: {
          ...def.selectionSet,
          selections: aliasFieldsInSelection(prefix, selections, document)
        }
      };
    }
  };
  return graphql.visit(document, transformer, {
    [graphql.Kind.DOCUMENT]: [`definitions`]
  });
}
function aliasFieldsInSelection(prefix, selections, document) {
  return selections.map((selection) => {
    switch (selection.kind) {
      case graphql.Kind.INLINE_FRAGMENT:
        return aliasFieldsInInlineFragment(prefix, selection, document);
      case graphql.Kind.FRAGMENT_SPREAD: {
        const inlineFragment = inlineFragmentSpread(selection, document);
        return aliasFieldsInInlineFragment(prefix, inlineFragment, document);
      }
      case graphql.Kind.FIELD:
      default:
        return aliasField(selection, prefix);
    }
  });
}
function aliasFieldsInInlineFragment(prefix, fragment, document) {
  const { selections } = fragment.selectionSet;
  return {
    ...fragment,
    selectionSet: {
      ...fragment.selectionSet,
      selections: aliasFieldsInSelection(prefix, selections, document)
    }
  };
}
function inlineFragmentSpread(spread, document) {
  const fragment = document.definitions.find(
    (def) => isFragmentDefinition(def) && def.name.value === spread.name.value
  );
  if (!fragment) {
    throw new Error(`Fragment ${spread.name.value} does not exist`);
  }
  const { typeCondition, selectionSet } = fragment;
  return {
    kind: graphql.Kind.INLINE_FRAGMENT,
    typeCondition,
    selectionSet,
    directives: spread.directives
  };
}
function prefixNodeName(namedNode, prefix) {
  return {
    ...namedNode,
    name: {
      ...namedNode.name,
      value: prefix + namedNode.name.value
    }
  };
}
function aliasField(field, aliasPrefix) {
  const aliasNode = field.alias ? field.alias : field.name;
  return {
    ...field,
    alias: {
      ...aliasNode,
      value: aliasPrefix + aliasNode.value
    }
  };
}
function isOperationDefinition(def) {
  return def.kind === graphql.Kind.OPERATION_DEFINITION;
}
function isFragmentDefinition(def) {
  return def.kind === graphql.Kind.FRAGMENT_DEFINITION;
}

function splitResult({ data, errors }, numResults) {
  const splitResults = new Array(numResults);
  if (data) {
    for (const prefixedKey in data) {
      if (prefixedKey === "__proto__" || prefixedKey === "constructor" || prefixedKey === "prototype") {
        continue;
      }
      const { index, originalKey } = parseKey(prefixedKey);
      const result = splitResults[index];
      if (result == null) {
        splitResults[index] = {
          data: {
            [originalKey]: data[prefixedKey]
          }
        };
      } else if (result.data == null) {
        result.data = { [originalKey]: data[prefixedKey] };
      } else {
        result.data[originalKey] = data[prefixedKey];
      }
    }
  }
  if (errors) {
    for (const error of errors) {
      if (error.path) {
        const { index, originalKey, keyOffset } = parseKeyFromPath(error.path);
        const newError = utils.relocatedError(error, [
          originalKey,
          ...error.path.slice(keyOffset)
        ]);
        const splittedResult = splitResults[index];
        if (splittedResult == null) {
          splitResults[index] = { errors: [newError] };
          continue;
        } else if (splittedResult.errors == null) {
          splittedResult.errors = [newError];
          continue;
        } else {
          splittedResult.errors.push(newError);
        }
      } else {
        for (let i = 0; i < numResults; i++) {
          const splittedResult = splitResults[i];
          if (splittedResult == null) {
            splitResults[i] = { errors: [error] };
            continue;
          } else if (splittedResult.errors == null) {
            splittedResult.errors = [error];
            continue;
          } else {
            splittedResult.errors.push(error);
          }
        }
      }
    }
  }
  return splitResults;
}

function createBatchingExecutor(executor, dataLoaderOptions, extensionsReducer = defaultExtensionsReducer) {
  const loadFn = createLoadFn(executor, extensionsReducer);
  const queryLoader = new DataLoader__default.default(loadFn, dataLoaderOptions);
  const mutationLoader = new DataLoader__default.default(loadFn, dataLoaderOptions);
  return function batchingExecutor(request) {
    const operationType = request.operationType ?? utils.getOperationASTFromRequest(request)?.operation;
    switch (operationType) {
      case "query":
        return queryLoader.load(request);
      case "mutation":
        return mutationLoader.load(request);
      case "subscription":
        return executor(request);
      default:
        throw new Error(`Invalid operation type "${operationType}"`);
    }
  };
}
function createLoadFn(executor, extensionsReducer) {
  return function batchExecuteLoadFn(requests) {
    if (requests.length === 1 && requests[0]) {
      const request = requests[0];
      return promiseHelpers.fakePromise().then(() => executor(request)).catch((err) => err).then((res) => [res]);
    }
    const mergedRequests = mergeRequests(requests, extensionsReducer);
    return promiseHelpers.fakePromise().then(() => executor(mergedRequests)).then(
      (resultBatches) => splitResult(resultBatches, requests.length)
    ).catch((err) => requests.map(() => err));
  };
}
function defaultExtensionsReducer(mergedExtensions, request) {
  const newExtensions = request.extensions;
  if (newExtensions != null) {
    Object.assign(mergedExtensions, newExtensions);
  }
  return mergedExtensions;
}

const getBatchingExecutor = utils.memoize2of4(function getBatchingExecutor2(_context, executor, dataLoaderOptions, extensionsReducer) {
  return createBatchingExecutor(executor, dataLoaderOptions, extensionsReducer);
});

exports.createBatchingExecutor = createBatchingExecutor;
exports.getBatchingExecutor = getBatchingExecutor;
