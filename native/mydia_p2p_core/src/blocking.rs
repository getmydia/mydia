//! Synchronous wrappers over the async `Host` API.
//!
//! The Rustler NIF is called from Erlang scheduler threads and cannot be
//! async, so it drives the async `Host` through here. Native only: a browser
//! cannot block its only thread, and nothing in the wasm build needs to.

#![cfg(not(target_arch = "wasm32"))]

use crate::runtime::block_on;
use crate::{HlsResponseHeader, Host, MydiaResponse, NetworkStats};

pub fn dial(host: &Host, endpoint_addr_json: String) -> Result<(), String> {
    block_on(host.dial(endpoint_addr_json))
}

pub fn get_node_addr(host: &Host) -> String {
    block_on(host.get_node_addr())
}

pub fn get_network_stats(host: &Host) -> NetworkStats {
    block_on(host.get_network_stats())
}

pub fn send_response(
    host: &Host,
    request_id: String,
    response: MydiaResponse,
) -> Result<(), String> {
    block_on(host.send_response(request_id, response))
}

pub fn send_hls_header(
    host: &Host,
    stream_id: String,
    header: HlsResponseHeader,
) -> Result<(), String> {
    block_on(host.send_hls_header(stream_id, header))
}

pub fn send_hls_chunk(host: &Host, stream_id: String, data: Vec<u8>) -> Result<(), String> {
    block_on(host.send_hls_chunk(stream_id, data))
}

pub fn finish_hls_stream(host: &Host, stream_id: String) -> Result<(), String> {
    block_on(host.finish_hls_stream(stream_id))
}

pub fn stream_file_range(
    host: &Host,
    stream_id: String,
    file_path: String,
    offset: u64,
    length: u64,
) -> Result<(), String> {
    block_on(host.stream_file_range(stream_id, file_path, offset, length))
}
