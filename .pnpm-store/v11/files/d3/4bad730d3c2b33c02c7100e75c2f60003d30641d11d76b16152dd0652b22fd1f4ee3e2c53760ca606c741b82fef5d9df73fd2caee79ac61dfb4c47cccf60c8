const SPLIT_LOWER_UPPER_RE = new RegExp("([\\p{Ll}\\d])(\\p{Lu})", "gu");
const SPLIT_UPPER_UPPER_RE = new RegExp("(\\p{Lu})([\\p{Lu}][\\p{Ll}])", "gu");
const SPLIT_NUMBER_LOWER_RE = new RegExp("(\\d)(\\p{Ll})", "gu");
const SPLIT_LETTER_NUMBER_RE = new RegExp("(\\p{L})(\\d)", "gu");
const DEFAULT_STRIP_REGEXP = /[^\p{L}\d]+/giu;
const SPLIT_REPLACE_VALUE = "$1\0$2";
const DEFAULT_PREFIX_CHARACTERS = "";
function split(input, options) {
  let result = input.trim();
  result = result.replace(SPLIT_LOWER_UPPER_RE, SPLIT_REPLACE_VALUE).replace(SPLIT_UPPER_UPPER_RE, SPLIT_REPLACE_VALUE);
  if (options == null ? void 0 : options.separateNumbers) {
    result = result.replace(SPLIT_NUMBER_LOWER_RE, SPLIT_REPLACE_VALUE).replace(SPLIT_LETTER_NUMBER_RE, SPLIT_REPLACE_VALUE);
  }
  result = result.replace(DEFAULT_STRIP_REGEXP, "\0");
  let start = 0;
  let end = result.length;
  while (result.charAt(start) === "\0")
    start++;
  if (start === end)
    return [];
  while (result.charAt(end - 1) === "\0")
    end--;
  return result.slice(start, end).split(/\0/g);
}
function noCase$1(input, options) {
  const prefix = getPrefix(input, options == null ? void 0 : options.prefixCharacters);
  return prefix + split(input, options).map(lowerFactory(options == null ? void 0 : options.locale)).join((options == null ? void 0 : options.delimiter) ?? " ");
}
function camelCase$1(input, options) {
  const prefix = getPrefix(input, options == null ? void 0 : options.prefixCharacters);
  const lower = lowerFactory(options == null ? void 0 : options.locale);
  const upper = upperFactory(options == null ? void 0 : options.locale);
  const transform = (options == null ? void 0 : options.mergeAmbiguousCharacters) ? capitalCaseTransformFactory(lower, upper) : pascalCaseTransformFactory(lower, upper);
  return prefix + split(input, options).map((word, index) => {
    if (index === 0)
      return lower(word);
    return transform(word, index);
  }).join((options == null ? void 0 : options.delimiter) ?? "");
}
function pascalCase$1(input, options) {
  const prefix = getPrefix(input, options == null ? void 0 : options.prefixCharacters);
  const lower = lowerFactory(options == null ? void 0 : options.locale);
  const upper = upperFactory(options == null ? void 0 : options.locale);
  const transform = (options == null ? void 0 : options.mergeAmbiguousCharacters) ? capitalCaseTransformFactory(lower, upper) : pascalCaseTransformFactory(lower, upper);
  return prefix + split(input, options).map(transform).join((options == null ? void 0 : options.delimiter) ?? "");
}
function capitalCase$1(input, options) {
  const prefix = getPrefix(input, options == null ? void 0 : options.prefixCharacters);
  const lower = lowerFactory(options == null ? void 0 : options.locale);
  const upper = upperFactory(options == null ? void 0 : options.locale);
  return prefix + split(input, options).map(capitalCaseTransformFactory(lower, upper)).join((options == null ? void 0 : options.delimiter) ?? " ");
}
function constantCase$1(input, options) {
  const prefix = getPrefix(input, options == null ? void 0 : options.prefixCharacters);
  return prefix + split(input, options).map(upperFactory(options == null ? void 0 : options.locale)).join((options == null ? void 0 : options.delimiter) ?? "_");
}
function dotCase$1(input, options) {
  return noCase$1(input, { delimiter: ".", ...options });
}
function kebabCase$1(input, options) {
  return noCase$1(input, { delimiter: "-", ...options });
}
function pathCase$1(input, options) {
  return noCase$1(input, { delimiter: "/", ...options });
}
function sentenceCase$1(input, options) {
  const prefix = getPrefix(input, options == null ? void 0 : options.prefixCharacters);
  const lower = lowerFactory(options == null ? void 0 : options.locale);
  const upper = upperFactory(options == null ? void 0 : options.locale);
  const transform = capitalCaseTransformFactory(lower, upper);
  return prefix + split(input, options).map((word, index) => {
    if (index === 0)
      return transform(word);
    return lower(word);
  }).join((options == null ? void 0 : options.delimiter) ?? " ");
}
function snakeCase$1(input, options) {
  return noCase$1(input, { delimiter: "_", ...options });
}
function trainCase$1(input, options) {
  return capitalCase$1(input, { delimiter: "-", ...options });
}
function lowerFactory(locale) {
  return locale === false ? (input) => input.toLowerCase() : (input) => input.toLocaleLowerCase(locale);
}
function upperFactory(locale) {
  return locale === false ? (input) => input.toUpperCase() : (input) => input.toLocaleUpperCase(locale);
}
function capitalCaseTransformFactory(lower, upper) {
  return (word) => `${upper(word[0])}${lower(word.slice(1))}`;
}
function pascalCaseTransformFactory(lower, upper) {
  return (word, index) => {
    const char0 = word[0];
    const initial = index > 0 && char0 >= "0" && char0 <= "9" ? "_" + char0 : upper(char0);
    return initial + lower(word.slice(1));
  };
}
function getPrefix(input, prefixCharacters = DEFAULT_PREFIX_CHARACTERS) {
  let prefix = "";
  for (let i = 0; i < input.length; i++) {
    const char = input.charAt(i);
    if (prefixCharacters.includes(char)) {
      prefix += char;
    } else {
      break;
    }
  }
  return prefix;
}
function spongeCase$1(input, locale) {
  let result = "";
  for (const char of input) {
    result += Math.random() > 0.5 ? char.toLocaleUpperCase(locale) : char.toLocaleLowerCase(locale);
  }
  return result;
}
function swapCase$1(input, locale) {
  let result = "";
  for (const char of input) {
    const lower = char.toLocaleLowerCase(locale);
    result += char === lower ? char.toLocaleUpperCase(locale) : lower;
  }
  return result;
}
var SMALL_WORDS = /\b(?:an?d?|a[st]|because|but|by|en|for|i[fn]|neither|nor|o[fnr]|only|over|per|so|some|tha[tn]|the|to|up|upon|vs?\.?|versus|via|when|with|without|yet)\b/i;
var TOKENS = /[^\s:–—-]+|./g;
var WHITESPACE = /\s/;
var IS_MANUAL_CASE = /.(?=[A-Z]|\..)/;
var ALPHANUMERIC_PATTERN = /[A-Za-z0-9\u00C0-\u00FF]/;
function titleCase$1(input) {
  var result = "";
  var m;
  while ((m = TOKENS.exec(input)) !== null) {
    var token = m[0], index = m.index;
    if (
      // Ignore already capitalized words.
      !IS_MANUAL_CASE.test(token) && // Ignore small words except at beginning or end.
      (!SMALL_WORDS.test(token) || index === 0 || index + token.length === input.length) && // Ignore URLs.
      (input.charAt(index + token.length) !== ":" || WHITESPACE.test(input.charAt(index + token.length + 1)))
    ) {
      result += token.replace(ALPHANUMERIC_PATTERN, function(m2) {
        return m2.toUpperCase();
      });
      continue;
    }
    result += token;
  }
  return result;
}
const camelCase = camelCase$1;
const capitalCase = capitalCase$1;
const constantCase = constantCase$1;
const dotCase = dotCase$1;
const noCase = noCase$1;
const pascalCase = pascalCase$1;
const pathCase = pathCase$1;
const sentenceCase = sentenceCase$1;
const snakeCase = snakeCase$1;
const headerCase = trainCase$1;
const trainCase = trainCase$1;
const paramCase = kebabCase$1;
const kebabCase = kebabCase$1;
const spongeCase = spongeCase$1;
const swapCase = swapCase$1;
const titleCase = titleCase$1;
const upperCase = (str) => str.toUpperCase();
const localeUpperCase = (str, locales) => str.toLocaleUpperCase(locales);
const lowerCase = (str) => str.toLowerCase();
const localeLowerCase = (str, locales) => str.toLocaleLowerCase(locales);
const lowerCaseFirst = (str) => str.charAt(0).toLowerCase() + str.slice(1);
const upperCaseFirst = (str) => str.charAt(0).toUpperCase() + str.slice(1);
const isUpperCase = (str) => str === str.toUpperCase();
const isLowerCase = (str) => str === str.toLowerCase();
const _Case = class _Case {
};
_Case.camel = camelCase;
_Case.capital = capitalCase;
_Case.constant = constantCase;
_Case.dot = dotCase;
_Case.kebab = kebabCase;
_Case.lower = lowerCase;
_Case.lowerFirst = lowerCaseFirst;
_Case.localeLower = localeLowerCase;
_Case.localeUpper = localeUpperCase;
_Case.no = noCase;
_Case.pascal = pascalCase;
_Case.path = pathCase;
_Case.sentence = sentenceCase;
_Case.snake = snakeCase;
_Case.sponge = spongeCase;
_Case.swap = swapCase;
_Case.title = titleCase;
_Case.train = trainCase;
_Case.upper = upperCase;
_Case.upperFirst = upperCaseFirst;
_Case.isUpper = isUpperCase;
_Case.isLower = isLowerCase;
let Case = _Case;
export {
  Case,
  camelCase,
  capitalCase,
  constantCase,
  dotCase,
  headerCase,
  isLowerCase,
  isUpperCase,
  kebabCase,
  localeLowerCase,
  localeUpperCase,
  lowerCase,
  lowerCaseFirst,
  noCase,
  paramCase,
  pascalCase,
  pathCase,
  sentenceCase,
  snakeCase,
  spongeCase,
  swapCase,
  titleCase,
  trainCase,
  upperCase,
  upperCaseFirst
};
