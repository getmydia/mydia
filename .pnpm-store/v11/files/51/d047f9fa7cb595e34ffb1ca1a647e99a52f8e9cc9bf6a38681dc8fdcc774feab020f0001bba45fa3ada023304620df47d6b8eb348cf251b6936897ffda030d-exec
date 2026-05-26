#!/usr/bin/env node
"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const cli_js_1 = require("./cli.js");
const cli_error_js_1 = require("./utils/cli-error.js");
const [, , cmd] = process.argv;
(0, cli_js_1.runCli)(cmd)
    .then(returnCode => {
    process.exit(returnCode);
})
    .catch(error => {
    (0, cli_error_js_1.cliError)(error);
});
