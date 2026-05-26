"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
exports.access = access;
exports.writeFile = writeFile;
exports.readFile = readFile;
exports.unlinkFile = unlinkFile;
exports.mkdirp = mkdirp;
const fs_1 = require("fs");
const { access: fsAccess, writeFile: fsWriteFile, readFile: fsReadFile, mkdir } = fs_1.promises;
function access(...args) {
    return fsAccess(...args);
}
function writeFile(filepath, content) {
    return fsWriteFile(filepath, content);
}
function readFile(filepath) {
    return fsReadFile(filepath, 'utf-8');
}
function unlinkFile(filePath, cb) {
    (0, fs_1.unlink)(filePath, cb);
}
function mkdirp(filePath) {
    return mkdir(filePath, { recursive: true });
}
