import socket, struct, os

def ext(t, data):
    return struct.pack(">HH", t, len(data)) + data

def build(exts, sid=b"", suites=(0x1301, 0x1303)):
    body = b"\x03\x03" + os.urandom(32) + bytes([len(sid)]) + sid
    body += struct.pack(">H", len(suites) * 2) + b"".join(struct.pack(">H", s) for s in suites)
    body += b"\x01\x00"
    blob = b"".join(exts)
    body += struct.pack(">H", len(blob)) + blob
    return b"\x01" + struct.pack(">I", len(body))[1:] + body

def sni(host):
    n = host.encode()
    return ext(0, struct.pack(">H", 1 + 2 + len(n)) + b"\x00" + struct.pack(">H", len(n)) + n)

def alpn(name=b"http/1.1"):
    e = bytes([len(name)]) + name
    return ext(16, struct.pack(">H", len(e)) + e)

def keyshare(pub):
    e = struct.pack(">HH", 0x001d, len(pub)) + pub
    return ext(51, struct.pack(">H", len(e)) + e)

def groups(gs=(0x001d,)):
    return ext(10, struct.pack(">H", len(gs) * 2) + b"".join(struct.pack(">H", g) for g in gs))

def sigalgs(algs=(0x0403, 0x0503, 0x0603, 0x0804, 0x0805, 0x0806, 0x0401, 0x0501, 0x0601, 0x0807, 0x0809)):
    return ext(13, struct.pack(">H", len(algs) * 2) + b"".join(struct.pack(">H", a) for a in algs))

def versions(vs=(0x0304,)):
    return ext(43, bytes([len(vs) * 2]) + b"".join(struct.pack(">H", v) for v in vs))

def probe(port, exts, label):
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=5)
    except Exception as e:
        print(label, "connect fail", e); return
    ch = build(exts)
    s.sendall(b"\x16\x03\x01" + struct.pack(">H", len(ch)) + ch)
    try:
        d = s.recv(4096)
    except Exception as e:
        print(label, "recv fail", e); s.close(); return
    if not d:
        print(label, "empty"); s.close(); return
    if d[0] == 0x16:
        print(label, "OK -> handshake, msgtype=%d" % d[5])
    elif d[0] == 0x15:
        print(label, "ALERT desc=%d (50=decode_error)" % d[6])
    else:
        print(label, "type=%d %s" % (d[0], d[:10].hex()))
    s.close()

pub = os.urandom(32)
P = 8443
probe(P, [versions(), keyshare(pub), groups(), sigalgs()], "1 base            ")
probe(P, [versions(), keyshare(pub), groups(), sigalgs(), sni("localhost")], "2 base+sni        ")
probe(P, [versions(), keyshare(pub), groups(), sigalgs(), alpn()], "3 base+alpn       ")
probe(P, [versions(), keyshare(pub), groups(), sigalgs(), sni("localhost"), alpn()], "4 base+sni+alpn   ")
probe(P, [versions(), groups(), sigalgs(), sni("localhost"), alpn()], "5 no-keyshare     ")
probe(P, [versions(), keyshare(pub), sigalgs(), sni("localhost"), alpn()], "6 no-groups       ")
probe(P, [versions(), keyshare(pub), groups(), sni("localhost"), alpn()], "7 no-sigalgs      ")
