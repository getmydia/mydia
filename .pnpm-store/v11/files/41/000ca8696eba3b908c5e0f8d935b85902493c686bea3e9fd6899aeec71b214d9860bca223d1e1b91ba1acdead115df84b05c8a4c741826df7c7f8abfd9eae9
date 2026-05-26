import { unlink as fsUnlink, promises } from 'fs';
const { access: fsAccess, writeFile: fsWriteFile, readFile: fsReadFile, mkdir } = promises;
export function access(...args) {
    return fsAccess(...args);
}
export function writeFile(filepath, content) {
    return fsWriteFile(filepath, content);
}
export function readFile(filepath) {
    return fsReadFile(filepath, 'utf-8');
}
export function unlinkFile(filePath, cb) {
    fsUnlink(filePath, cb);
}
export function mkdirp(filePath) {
    return mkdir(filePath, { recursive: true });
}
