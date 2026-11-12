"""Minimal Redis (RESP2) client, standard library only, shared by the demo apps and
the dashboard. Every connection authenticates as an ACL user."""
import socket


class RedisError(Exception):
    pass


class Redis:
    def __init__(self, host, port, username=None, password=None, timeout=3.0):
        self.addr = (host, int(port))
        self.username, self.password, self.timeout = username, password, timeout
        self.sock = None
        self.buf = b""

    def connect(self):
        self.close()
        self.sock = socket.create_connection(self.addr, timeout=self.timeout)
        self.buf = b""
        if self.password is not None:
            if self.username:
                self.call("AUTH", self.username, self.password)
            else:
                self.call("AUTH", self.password)
        return self

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None

    def _line(self):
        while b"\r\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("connection closed by peer")
            self.buf += chunk
        line, self.buf = self.buf.split(b"\r\n", 1)
        return line

    def _exact(self, n):
        while len(self.buf) < n + 2:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("connection closed by peer")
            self.buf += chunk
        data, self.buf = self.buf[:n], self.buf[n + 2:]
        return data

    def _reply(self):
        line = self._line()
        t, rest = line[:1], line[1:]
        if t == b"+":
            return rest.decode()
        if t == b"-":
            raise RedisError(rest.decode())
        if t == b":":
            return int(rest)
        if t == b"$":
            n = int(rest)
            return None if n < 0 else self._exact(n).decode(errors="replace")
        if t == b"*":
            n = int(rest)
            return None if n < 0 else [self._reply_safe() for _ in range(n)]
        raise RedisError(f"protocol error: {line!r}")

    def _reply_safe(self):
        # errors nested in arrays (e.g. EXEC) are returned, not raised
        try:
            return self._reply()
        except RedisError as e:
            return f"(error) {e}"

    def call(self, *args):
        if self.sock is None:
            self.connect()
        parts = [b"*%d\r\n" % len(args)]
        for a in args:
            b = a if isinstance(a, bytes) else str(a).encode()
            parts.append(b"$%d\r\n%s\r\n" % (len(b), b))
        try:
            self.sock.sendall(b"".join(parts))
            return self._reply()
        except (OSError, ConnectionError):
            self.close()
            raise


def info(text):
    """Parse an INFO reply into a dict."""
    out = {}
    for line in (text or "").splitlines():
        if ":" in line and not line.startswith("#"):
            k, v = line.split(":", 1)
            out[k] = v
    return out


def read_secret(path, key):
    with open(f"{path}/{key}", encoding="utf-8") as f:
        return f.read().strip()
