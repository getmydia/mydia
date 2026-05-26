"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.isNativeNamedType = void 0;
const graphql_1 = require("graphql");
const isNativeNamedType = (namedType) => {
    // "Native" NamedType in this context means the following:
    // 1. introspection types i.e. with `__` prefixes
    // 2. base scalars e.g. Boolean, Int, etc.
    if ((0, graphql_1.isSpecifiedScalarType)(namedType) || (0, graphql_1.isIntrospectionType)(namedType)) {
        return true;
    }
    return false;
};
exports.isNativeNamedType = isNativeNamedType;
