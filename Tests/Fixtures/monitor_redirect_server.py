#!/usr/bin/env python3
"""Ephemeral loopback fixture; never records credential values."""
import http.server
import sys

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        with open(sys.argv[1], 'a') as log:
            log.write(self.path + ' auth=' + str('Authorization' in self.headers) + '\n')
        if self.path in ('/metrics', '/health'):
            self.send_response(302)
            self.send_header('Location', '/sink')
            self.send_header('Content-Length', '0')
            self.end_headers()
        else:
            payload = b'llamacpp:prompt_tokens_total 1\nllamacpp:tokens_predicted_total 1\nllamacpp:prompt_tokens_cached_total 0\nllamacpp:prompt_tokens_seconds 0\nllamacpp:predicted_tokens_seconds 0\nllamacpp:requests_processing 0\nllamacpp:requests_deferred 0\nllamacpp:n_tokens_max 0\n'
            self.send_response(200)
            self.send_header('Content-Length', str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
