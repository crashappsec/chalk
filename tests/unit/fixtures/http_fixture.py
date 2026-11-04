from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import sys
import ssl
import time

routes = json.loads(open(sys.argv[1]).read())
hits_path = sys.argv[2]
port = int(sys.argv[3])


def route_body(route, request):
    if route.get("echo_host"):
        return request.headers.get("Host", "").encode()
    if route.get("echo_authorization"):
        return request.headers.get("Authorization", "").encode()
    if "body_repeat" in route:
        return route["body_repeat"]["byte"].encode() * route["body_repeat"]["count"]
    return route.get("body", "").encode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def respond(self, method):
        key = method + " " + self.path
        with open(hits_path, "a") as hits:
            hits.write(key + "\n")
        route = routes.get(key) or routes.get(method + " " + self.path.split("?", 1)[0])
        if route is None:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        auth = route.get("auth")
        if auth and self.headers.get("Authorization", "") != auth["header"]:
            body = b"denied"
            self.send_response(401)
            self.send_header("Www-Authenticate", auth["challenge"])
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            if method != "HEAD":
                self.wfile.write(body)
            return
        delay = route.get("delay_ms", 0)
        if delay:
            time.sleep(delay / 1000.0)
        body = route_body(route, self)
        self.send_response(int(route.get("status", 200)))
        headers = route.get("headers", {})
        for name, value in headers.items():
            self.send_header(name, value)
        if "Content-Type" not in headers:
            self.send_header("Content-Type", route.get("content_type", "application/json"))
        chunked = route.get("chunked", False)
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
        elif "Content-Length" not in headers:
            self.send_header("Content-Length", str(route.get("content_length", len(body))))
        self.end_headers()
        if method == "HEAD":
            return
        try:
            self.write_body(body, route.get("drip"), chunked)
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True

    def write_body(self, body, drip, chunked):
        chunk = int(drip["chunk"]) if drip else 65536
        delay = drip["delay_ms"] / 1000.0 if drip else 0
        for start in range(0, len(body), chunk):
            piece = body[start:start + chunk]
            if chunked:
                self.wfile.write(b"%x\r\n%s\r\n" % (len(piece), piece))
            else:
                self.wfile.write(piece)
            self.wfile.flush()
            if delay:
                time.sleep(delay)
        if chunked:
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()

    def do_GET(self):
        self.respond("GET")

    def do_HEAD(self):
        self.respond("HEAD")


server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
if len(sys.argv) > 4:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(sys.argv[4], sys.argv[5])
    def record_sni(connection, server_name, initial_context):
        with open(sys.argv[6], "a") as names:
            names.write((server_name or "") + "\n")
    context.set_servername_callback(record_sni)
    server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
