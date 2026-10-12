# The builder's sandbox test: built with no IMAGE_REPOSITORY, it fails unless
# both mirrors and the open internet answer and every blocked target drops the
# connection. Dropped, not refused: a refusal means the packet reached a host.
FROM python:3.13-alpine
COPY --from=ghcr.io/astral-sh/uv:latest /uv /usr/local/bin/uv
RUN <<EOF python3
import socket, struct

def probe(host, port):
    try:
        socket.create_connection((host, port), timeout=5).close()
        return "open"
    except TimeoutError:
        return "dropped"
    except OSError as e:
        return f"failed: {e}"

# RUN shares BuildKit's network, so the default route is the build's docker0.
with open("/proc/net/route") as f:
    rows = [line.split() for line in f]
gateway = next(socket.inet_ntoa(struct.pack("<L", int(r[2], 16))) for r in rows if r[1] == "00000000")

assert probe("registry.npmjs.org", 443) == "open", "no egress at all"
for host, port in [("169.254.170.2", 80), ("169.254.169.254", 80), (gateway, 2375)]:
    result = probe(host, port)
    print(f"{host}:{port} {result}")
    assert result == "dropped", f"{host}:{port} not dropped"
EOF
