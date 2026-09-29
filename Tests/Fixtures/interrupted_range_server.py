#!/usr/bin/env python3
"""Local HTTP fixture used by ArtifactDownloaderIntegrationTests.

The `drop_then_serve` mode exists to reproduce a CDN/LB cutting a connection
mid-body: the first response advertises the full payload, delivers a prefix and
then kills the socket, so the next request arrives as a `Range` request.

Dropping the socket while the truncated body is still in flight is inherently
racy: the kernel discards whatever the client has not read yet, so the client
can observe anywhere from 0 to DROP_AFTER bytes before the error. That made the
resume assertions flaky -- when the client happened to lose all of the prefix
the downloader correctly restarted from zero and the "resumed" assertion failed.

To make the drop deterministic the server holds the connection open after
writing the prefix until `--release-file` appears. The test writes that file
only once the downloader reports the prefix persisted to disk, which guarantees
the client's receive buffer is empty and the drop cannot discard anything.
"""
import argparse
import http.server
import os
import socket
import socketserver
import time

PAYLOAD_SIZE = 8 * 1024 * 1024
CHUNK_SIZE = 64 * 1024
DROP_AFTER = 1024 * 1024
ETAG = '"launcher27b-resume-fixture-v1"'
LAST_MODIFIED = "Tue, 22 Sep 2026 07:00:00 GMT"

# Safety valve: never let a broken test hang the fixture (and the suite) forever.
RELEASE_TIMEOUT_SECONDS = 30.0
RELEASE_POLL_SECONDS = 0.002


def chunk_at(offset: int, length: int) -> bytes:
    pattern = bytes(range(256))
    prefix = offset % len(pattern)
    source = pattern[prefix:] + pattern[:prefix]
    repeats = (length + len(source) - 1) // len(source)
    return (source * repeats)[:length]


class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def do_GET(self) -> None:
        range_header = self.headers.get("Range")
        start = 0
        if range_header and range_header.startswith("bytes="):
            start = int(range_header.removeprefix("bytes=").split("-", 1)[0])

        # Honour If-Range: a conditional range whose validator names a different
        # representation must be answered with the whole body, not a slice.
        if_range = self.headers.get("If-Range")
        if start and if_range is not None and if_range.strip() not in (
            ETAG,
            LAST_MODIFIED,
        ):
            start = 0

        if self.server.mode in ("drop", "drop_then_serve") and not self.server.dropped:
            self.server.dropped = True
            self.send_response(200)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(PAYLOAD_SIZE))
            self.send_header("ETag", ETAG)
            self.send_header("Last-Modified", LAST_MODIFIED)
            self.end_headers()
            self.wfile.write(chunk_at(0, DROP_AFTER))
            self.wfile.flush()
            self.await_release()
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return

        remaining = PAYLOAD_SIZE - start
        self.send_response(206 if start else 200)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(remaining))
        self.send_header("ETag", ETAG)
        self.send_header("Last-Modified", LAST_MODIFIED)
        if start:
            self.send_header(
                "Content-Range",
                f"bytes {start}-{PAYLOAD_SIZE - 1}/{PAYLOAD_SIZE}",
            )
        self.end_headers()

        offset = start
        while offset < PAYLOAD_SIZE:
            length = min(CHUNK_SIZE, PAYLOAD_SIZE - offset)
            self.wfile.write(chunk_at(offset, length))
            offset += length
            time.sleep(0.01)

    def await_release(self) -> None:
        """Block until the test signals that the prefix is persisted, or time out.

        Without `--release-file` the drop stays immediate, which is what the
        legacy `drop` mode wants.
        """
        release_file = self.server.release_file
        if not release_file:
            return
        deadline = time.monotonic() + RELEASE_TIMEOUT_SECONDS
        while time.monotonic() < deadline:
            if os.path.exists(release_file):
                return
            time.sleep(RELEASE_POLL_SECONDS)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--mode",
        choices=("drop", "serve", "drop_then_serve"),
        required=True,
    )
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument(
        "--release-file",
        default="",
        help="Hold a truncated response open until this path exists.",
    )
    args = parser.parse_args()

    with ReusableTCPServer(("127.0.0.1", args.port), Handler) as server:
        server.mode = args.mode
        server.dropped = False
        server.release_file = args.release_file
        print(server.server_address[1], flush=True)
        if args.mode == "drop":
            server.handle_request()
        else:
            server.serve_forever()


if __name__ == "__main__":
    main()
