"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.toCamelCase = exports.toUpperFirst = exports.splitWords = exports.freeText = void 0;
// Will use the shortest indention as an axis
const freeText = (text, skipIndentation = false) => {
    if (text instanceof Array) {
        text = text.join('');
    }
    // This will allow inline text generation with external functions, same as ctrl+shift+c
    // As long as we surround the inline text with ==>text<==
    text = text.replace(/( *)==>((?:.|\n)*?)<==/g, (_match, baseIndent, content) => {
        return content
            .split('\n')
            .map(line => `${baseIndent}${line}`)
            .join('\n');
    });
    if (skipIndentation) {
        if (text.trim() === '') {
            return '';
        }
        return text;
    }
    const lines = text.split('\n');
    const minIndent = lines
        .filter(line => line.trim())
        .reduce((minIndent, line) => {
        const currIndent = line.match(/^ */)?.[0].length;
        if (currIndent == null) {
            return minIndent;
        }
        return currIndent < minIndent ? currIndent : minIndent;
    }, Infinity);
    return lines
        .map(line => line.slice(minIndent))
        .join('\n')
        .trim()
        .replace(/\n +\n/g, '\n\n');
};
exports.freeText = freeText;
// foo_barBaz -> ['foo', 'bar', 'Baz']
const splitWords = (str) => {
    return str.replace(/[A-Z]/, ' $&').split(/[^a-zA-Z0-9]+/);
};
exports.splitWords = splitWords;
// upper -> Upper
const toUpperFirst = (str) => {
    return str.slice(0, 1).toUpperCase() + str.slice(1).toLowerCase();
};
exports.toUpperFirst = toUpperFirst;
// foo-bar-baz -> fooBarBaz
const toCamelCase = (str) => {
    const words = (0, exports.splitWords)(str);
    const first = words.shift()?.toLowerCase() ?? '';
    const rest = words.map(exports.toUpperFirst);
    return [first, ...rest].join('');
};
exports.toCamelCase = toCamelCase;
