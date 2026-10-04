import re, hashlib, hmac
P = 2**255 - 19
A24 = 121665

def x25519(k, u):
    k = bytearray(k); k[0] &= 248; k[31] &= 127; k[31] |= 64
    k = int.from_bytes(k, "little")
    u = int.from_bytes(u, "little") & ((1 << 255) - 1)
    x1, x2, z2, x3, z3 = u, 1, 0, u, 1
    swap = 0
    for t in range(254, -1, -1):
        kt = (k >> t) & 1
        swap ^= kt
        if swap:
            x2, x3 = x3, x2; z2, z3 = z3, z2
        swap = kt
        A = (x2 + z2) % P; AA = A * A % P
        B = (x2 - z2) % P; BB = B * B % P
        E = (AA - BB) % P
        C = (x3 + z3) % P; D = (x3 - z3) % P
        DA = D * A % P; CB = C * B % P
        x3 = pow(DA + CB, 2, P); z3 = x1 * pow(DA - CB, 2, P) % P
        x2 = AA * BB % P; z2 = E * ((AA + A24 * E) % P) % P
    return (x2 * pow(z2, P - 2, P) % P).to_bytes(32, "little")

def extract(salt, ikm):
    return hmac.new(salt, ikm, hashlib.sha256).digest()

def expand_label(secret, label, context, length):
    lbl = b"tls13 " + label
    info = length.to_bytes(2, "big") + bytes([len(lbl)]) + lbl + bytes([len(context)]) + context
    out, t, i = b"", b"", 1
    while len(out) < length:
        t = hmac.new(secret, t + info + bytes([i]), hashlib.sha256).digest()
        out += t; i += 1
    return out[:length]

txt = open("/tmp/run2.txt").read()
g = lambda p: bytes.fromhex(re.search(p, txt).group(1))
ch = g(r"CH hex:([0-9a-f]+)"); sh = g(r"SH=([0-9a-f]+)")
sec = g(r"my_secret=([0-9a-f]+)"); pub = g(r"peer_pub=([0-9a-f]+)")
ecdhe = g(r"ecdhe=([0-9a-f]+)")
key = g(r"key=([0-9a-f]+)"); iv = g(r" iv=([0-9a-f]+)")
ss = x25519(sec, pub)
print("X25519 python:", ss.hex())
print("X25519 zig   :", ecdhe.hex(), "->", "MATCH" if ss == ecdhe else "MISMATCH")
th = hashlib.sha256(ch + sh).digest()
print("transcript py:", th.hex())
early = extract(bytes(32), bytes(32))
d1 = expand_label(early, b"derived", hashlib.sha256(b"").digest(), 32)
hs = extract(d1, ss)
s_hs = expand_label(hs, b"s hs traffic", th, 32)
c_hs = expand_label(hs, b"c hs traffic", th, 32)
print("s_hs py      :", s_hs.hex())
print("c_hs py      :", c_hs.hex())
k_exp = expand_label(s_hs, b"key", b"", 16)
iv_exp = expand_label(s_hs, b"iv", b"", 12)
print("key py[:8]   :", k_exp[:8].hex())
print("key zig[:8]  :", key[:8].hex(), "->", "MATCH" if k_exp[:8] == key[:8] else "MISMATCH")
print("iv  py       :", iv_exp.hex())
print("iv  zig      :", iv.hex(), "->", "MATCH" if iv_exp == iv else "MISMATCH")
ck = g(r"ck=([0-9a-f]+)"); sk = g(r"sk=([0-9a-f]+)")
ckiv = g(r"ck_iv=([0-9a-f]+)"); skiv = g(r"sk_iv=([0-9a-f]+)")
k_c = expand_label(c_hs, b"key", b"", 16); iv_c = expand_label(c_hs, b"iv", b"", 12)
k_s = expand_label(s_hs, b"key", b"", 16); iv_s = expand_label(s_hs, b"iv", b"", 12)
print("ck py :", k_c[:8].hex(), "| zig:", ck[:8].hex(), "->", "MATCH" if k_c[:8] == ck[:8] else "MISMATCH")
print("sk py :", k_s[:8].hex(), "| zig:", sk[:8].hex(), "->", "MATCH" if k_s[:8] == sk[:8] else "MISMATCH")
print("ck_iv py:", iv_c.hex(), "| zig:", ckiv.hex(), "->", "MATCH" if iv_c == ckiv else "MISMATCH")
print("sk_iv py:", iv_s.hex(), "| zig:", skiv.hex(), "->", "MATCH" if iv_s == skiv else "MISMATCH")
