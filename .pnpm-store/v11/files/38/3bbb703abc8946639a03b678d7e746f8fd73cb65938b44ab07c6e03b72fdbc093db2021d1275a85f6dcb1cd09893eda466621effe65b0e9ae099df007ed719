'use strict';

var core = require('@envelop/core');
var graphql = require('graphql');

function stripAndPrint(document) {
  return graphql.stripIgnoredCharacters(graphql.print(document));
}
const defaultPrintFn = function defaultPrintFn2(document) {
  return core.getDocumentString(document, stripAndPrint);
};
function serializeExecutionRequest({
  executionRequest,
  excludeQuery,
  printFn = defaultPrintFn
}) {
  return {
    query: excludeQuery ? void 0 : printFn(executionRequest.document),
    variables: (executionRequest.variables && Object.keys(executionRequest.variables).length) > 0 ? executionRequest.variables : void 0,
    operationName: executionRequest.operationName ? executionRequest.operationName : void 0,
    extensions: executionRequest.extensions && Object.keys(executionRequest.extensions).length > 0 ? executionRequest.extensions : void 0
  };
}

exports.defaultPrintFn = defaultPrintFn;
exports.serializeExecutionRequest = serializeExecutionRequest;
