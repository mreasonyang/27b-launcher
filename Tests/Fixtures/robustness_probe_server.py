#!/usr/bin/env python3
"""Local HTTP fixture used by InstallerRobustnessTests.

Exercises the paths a real CDN can take that the launcher must survive without
touching the public network: byte-range resume, transient 5xx/429 responses with
Retry-After, a captive-portal style HTML body returned with 200, a server that
ignores Range headers entirely, a server that honours Range but sends no validator
at all (`no_validator_206`), and a publisher re-uploading the artifact at the
same URL (`change_content`, which honours If-Range so the client can detect it).
"""
import argparse
import http.server
import socket
import socketserver
import sys
import time

PAYLOAD_SIZE = 8 * 1024 * 1024
CHUNK_SIZE = 64 * 1024
ETAG = '"launcher27b-robustness-fixture-v1"'
LAST_MODIFIED = "Tue, 22 Sep 2026 07:00:00 GMT"
# Content revision 2: same URL, same length, different bytes -- the state a
# re-uploaded model artifact leaves behind.
ETAG_V2 = '"launcher27b-robustness-fixture-v2"'
LAST_MODIFIED_V2 = "Wed, 23 Sep 2026 07:00:00 GMT"


def chunk_at(offset: int, length: int) -> bytes:
    pattern = bytes(range(256))
    prefix = offset % len(pattern)
    source = pattern[prefix:] + pattern[:prefix]
    repeats = (length + len(source) - 1) // len(source)
    return (source * repeats)[:length]


def chunk_v2_at(offset: int, length: int) -> bytes:
    """Revision 2's bytes: position-shaped, but inverted so a splice is visible."""
    return bytes(byte ^ 0xFF for byte in chunk_at(offset, length))


class ReusableTCPServer(socketserver.TCPServer):
    allow_reuse_address = True


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, _format: str, *_args: object) -> None:
        pass

    def log_request_range(self) -> None:
        if not self.server.log_path:
            return
        range_header = self.headers.get("Range") or "-"
        if_range = self.headers.get("If-Range") or "-"
        with open(self.server.log_path, "a", encoding="utf-8") as handle:
            handle.write(
                f"{self.command} {self.path} Range:{range_header} If-Range:{if_range}\n"
            )

    def do_GET(self) -> None:
        self.server.request_count += 1
        self.log_request_range()

        mode = self.server.mode

        if mode == "always_503":
            self.send_response(503)
            self.send_header("Retry-After", "0")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if mode == "stall":
            # Complete the TCP handshake, then never answer. No URLSession delegate
            # callback ever fires for this shape, which is what made the retry cap
            # unreachable; the client must bound the attempt itself.
            time.sleep(3600)
            return

        if mode in ("flaky_503", "flaky_429") and self.server.request_count == 1:
            status = 503 if mode == "flaky_503" else 429
            self.send_response(status)
            self.send_header("Retry-After", "0")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if mode == "reject_range_416" and self.headers.get("Range"):
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{self.payload_size}")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return

        if mode == "html200":
            body = (
                b"<html><body>Sign in to the network to continue</body></html>"
            )
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self._write(body)
            return

        if mode == "truncate_body_200":
            # Advertises the full payload, delivers a fragment, then closes: every
            # attempt fails retryably (connection lost / short file), which is the
            # shape exercises the bounded retry policy.
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(self.payload_size))
            self.send_header("ETag", ETAG)
            self.send_header("Last-Modified", LAST_MODIFIED)
            self.end_headers()
            self._write(chunk_at(0, 256))
            self.wfile.flush()
            self.connection.shutdown(socket.SHUT_RDWR)
            self.connection.close()
            return

        if mode == "no_validator_206":
            self.serve_unvalidated_range()
            return

        if mode == "change_content":
            self.serve_changed_content()
            return

        start = 0
        range_header = self.headers.get("Range")
        if mode != "ignore_range" and range_header and range_header.startswith("bytes="):
            start = int(range_header.removeprefix("bytes=").split("-", 1)[0])

        # A conditional range whose validator does not match means the caller's
        # partial belongs to a different object: answer 200 with the whole body.
        if start and not self.if_range_matches(ETAG, LAST_MODIFIED):
            start = 0

        self.serve_payload(start, ETAG, LAST_MODIFIED, chunk_at)

    def serve_changed_content(self) -> None:
        """Revision 2 of the artifact at the same URL, honouring If-Range.

        A client that sends `If-Range: <v1 validator>` gets a full 200 because the
        object changed; a client that sends no `If-Range` (the old launcher) gets a
        206 and splices revision 2 onto its revision-1 prefix.
        """
        start = 0
        range_header = self.headers.get("Range")
        if range_header and range_header.startswith("bytes="):
            start = int(range_header.removeprefix("bytes=").split("-", 1)[0])
        if start and not self.if_range_matches(ETAG_V2, LAST_MODIFIED_V2):
            start = 0
        self.serve_payload(start, ETAG_V2, LAST_MODIFIED_V2, chunk_v2_at)

    def if_range_matches(self, etag: str, last_modified: str) -> bool:
        """Whether the caller's `If-Range` names the representation served now."""
        value = self.headers.get("If-Range")
        if value is None:
            return True
        stripped = value.strip()
        return stripped == etag or stripped == last_modified

    @property
    def payload_size(self) -> int:
        return self.server.payload_size

    def serve_unvalidated_range(self) -> None:
        """Honours `Range`, but never sends a validator and ignores `If-Range`.

        A non-conforming proxy/origin: it slices the object at the offset the client
        asked for, yet omits both `ETag` and `Last-Modified`. A client that trusts the
        resulting `206` blindly splices whatever the server is serving now onto its
        stored prefix, because there is nothing to compare the two against.
        """
        size = self.payload_size
        start = 0
        range_header = self.headers.get("Range")
        if range_header and range_header.startswith("bytes="):
            start = int(range_header.removeprefix("bytes=").split("-", 1)[0])

        remaining = size - start
        self.send_response(206 if start else 200)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(remaining))
        if start:
            self.send_header("Content-Range", f"bytes {start}-{size - 1}/{size}")
        self.end_headers()

        offset = start
        while offset < size:
            length = min(CHUNK_SIZE, size - offset)
            if not self._write(chunk_at(offset, length)):
                return
            offset += length
            time.sleep(self.server.chunk_delay)

    def serve_payload(self, start: int, etag: str, last_modified: str, content) -> None:
        size = self.payload_size
        remaining = size - start
        self.send_response(206 if start else 200)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(remaining))
        self.send_header("ETag", etag)
        self.send_header("Last-Modified", last_modified)
        if start:
            self.send_header(
                "Content-Range",
                f"bytes {start}-{size - 1}/{size}",
            )
        self.end_headers()

        offset = start
        while offset < size:
            length = min(CHUNK_SIZE, size - offset)
            if not self._write(content(offset, length)):
                return
            offset += length
            time.sleep(self.server.chunk_delay)

    def _write(self, data: bytes) -> bool:
        try:
            self.wfile.write(data)
            return True
        except (BrokenPipeError, ConnectionResetError):
            return False


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--mode",
        choices=(
            "serve",
            "flaky_503",
            "flaky_429",
            "always_503",
            "html200",
            "ignore_range",
            "reject_range_416",
            "truncate_body_200",
            "change_content",
            "no_validator_206",
            "stall",
        ),
        required=True,
    )
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--log", default="")
    parser.add_argument(
        "--chunk-delay",
        type=float,
        default=0.01,
        help="Seconds to sleep between 64 KiB chunks; raised to make the "
        "once-a-second client progress tick deterministic, or to model a "
        "slow-but-alive link.",
    )
    parser.add_argument(
        "--payload-size",
        type=int,
        default=PAYLOAD_SIZE,
        help="Size of the served object in bytes; shrunk by tests that need a "
        "slow transfer to still finish quickly.",
    )
    args = parser.parse_args()

    with ReusableTCPServer(("127.0.0.1", args.port), Handler) as server:
        server.mode = args.mode
        server.log_path = args.log
        server.chunk_delay = args.chunk_delay
        server.payload_size = args.payload_size
        server.request_count = 0
        print(server.server_address[1], flush=True)
        sys.stdout.flush()
        server.serve_forever()


if __name__ == "__main__":
    main()
