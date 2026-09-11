#!/usr/bin/env python3
import base64
import hashlib
import json
import os
import socket
import struct
import sys


socket_path = sys.argv[1]
try:
    os.unlink(socket_path)
except FileNotFoundError:
    pass

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(socket_path)
server.listen(1)
connection, _ = server.accept()

headers_raw = b""
while b"\r\n\r\n" not in headers_raw:
    headers_raw += connection.recv(4096)

headers = {}
for line in headers_raw.decode().split("\r\n")[1:]:
    if ":" in line:
        name, value = line.split(":", 1)
        headers[name.lower()] = value.strip()

accept = base64.b64encode(
    hashlib.sha1((headers["sec-websocket-key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
).decode()
connection.sendall(
    (
        "HTTP/1.1 101 Switching Protocols\r\n"
        "Connection: Upgrade\r\n"
        "Upgrade: websocket\r\n"
        f"Sec-WebSocket-Accept: {accept}\r\n\r\n"
    ).encode()
)


def receive_exact(length):
    result = b""
    while len(result) < length:
        chunk = connection.recv(length - len(result))
        if not chunk:
            raise EOFError("client disconnected")
        result += chunk
    return result


def receive_json():
    first, second = receive_exact(2)
    assert first & 0x0F == 1, "expected a text frame"
    assert second & 0x80, "client frames must be masked"
    length = second & 0x7F
    if length == 126:
        length = struct.unpack("!H", receive_exact(2))[0]
    elif length == 127:
        length = struct.unpack("!Q", receive_exact(8))[0]
    mask = receive_exact(4)
    payload = bytes(byte ^ mask[index % 4] for index, byte in enumerate(receive_exact(length)))
    return json.loads(payload)


def send_json(message):
    payload = json.dumps(message, separators=(",", ":")).encode()
    if len(payload) < 126:
        header = bytes((0x81, len(payload)))
    elif len(payload) <= 65535:
        header = bytes((0x81, 126)) + struct.pack("!H", len(payload))
    else:
        header = bytes((0x81, 127)) + struct.pack("!Q", len(payload))
    connection.sendall(header + payload)


initialize = receive_json()
assert initialize["method"] == "initialize"
send_json({"id": initialize["id"], "result": {}})

initialized = receive_json()
assert initialized["method"] == "initialized"

resume = receive_json()
assert resume["method"] == "thread/resume"
assert resume["params"] == {"threadId": "thr_test"}
send_json({"id": resume["id"], "result": {"thread": {"id": "thr_test", "preview": "x" * 70000}}})

turn = receive_json()
assert turn["method"] == "turn/start"
assert turn["params"]["threadId"] == "thr_test"
assert turn["params"]["input"] == [{"type": "text", "text": "x" * 70000}]
send_json({"id": turn["id"], "result": {"turn": {"id": "turn_test", "status": "inProgress"}}})

connection.close()
server.close()
