import { Separator, type Theme } from '@inquirer/core';
import type { PartialDeep } from '@inquirer/type';
type Key = 'a' | 'b' | 'c' | 'd' | 'e' | 'f' | 'g' | 'i' | 'j' | 'k' | 'l' | 'm' | 'n' | 'o' | 'p' | 'q' | 'r' | 's' | 't' | 'u' | 'v' | 'w' | 'x' | 'y' | 'z' | '0' | '1' | '2' | '3' | '4' | '5' | '6' | '7' | '8' | '9';
type Choice<Value> = {
    key: Key;
    value: Value;
} | {
    key: Key;
    name: string;
    value: Value;
};
declare const expand: <const Value>(config: {
    message: string;
    choices: readonly (Separator | {
        key: Key;
        name: Value & string;
        value?: never;
    } | Choice<Value>)[];
    default?: (Key | "h") | undefined;
    expanded?: boolean | undefined;
    theme?: PartialDeep<Theme> | undefined;
}, context?: import("@inquirer/type").Context) => Promise<Value>;
export default expand;
export { Separator } from '@inquirer/core';
