"""Independent reference for the Longwave NS3 handshake and records
(NATIVE_V3_PROTOCOL.md section 3), on pyca/cryptography rather than
swift-crypto. Checks itself against the cacophony NNpsk0 vector, then prints
golden values for StreamCryptoTests."""
import hashlib, hmac, json, struct, sys
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305, AESGCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import hashes, serialization

def H(b): return hashlib.sha256(b).digest()
def HM(k, d): return hmac.new(k, d, hashlib.sha256).digest()
def noise_hkdf(ck, ikm, n):
    t = HM(ck, ikm); out = []; prev = b""
    for i in range(1, n + 1):
        prev = HM(t, prev + bytes([i])); out.append(prev)
    return out
def nonce(n): return b"\0" * 4 + struct.pack("<Q", n)
def pub(sk): return sk.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)

class Sym:
    def __init__(self, name):
        name = name.encode()
        self.h = name.ljust(32, b"\0") if len(name) <= 32 else H(name)
        self.ck = self.h; self.k = None; self.n = 0
    def mix_hash(self, d): self.h = H(self.h + d)
    def mix_key(self, ikm):
        self.ck, k = noise_hkdf(self.ck, ikm, 2); self.k, self.n = k, 0
    def mix_key_and_hash(self, ikm):
        self.ck, th, k = noise_hkdf(self.ck, ikm, 3); self.mix_hash(th); self.k, self.n = k, 0
    def enc(self, pt):
        ct = pt if self.k is None else ChaCha20Poly1305(self.k).encrypt(nonce(self.n), pt, self.h)
        if self.k is not None: self.n += 1
        self.mix_hash(ct); return ct
    def dec(self, ct):
        pt = ct if self.k is None else ChaCha20Poly1305(self.k).decrypt(nonce(self.n), ct, self.h)
        if self.k is not None: self.n += 1
        self.mix_hash(ct); return pt
    def split(self): return noise_hkdf(self.ck, b"", 2)

NAME = "Noise_NNpsk0_25519_ChaChaPoly_SHA256"

def nnpsk0(prologue, psk, ie, re, p1, p2):
    """Runs both sides; returns (msg1, msg2, k1, k2, h)."""
    i = Sym(NAME); r = Sym(NAME); i.mix_hash(prologue); r.mix_hash(prologue)
    # -> psk, e
    i.mix_key_and_hash(psk); e = pub(ie); m1 = e; i.mix_hash(e); i.mix_key(e); m1 += i.enc(p1)
    r.mix_key_and_hash(psk); rie = m1[:32]; r.mix_hash(rie); r.mix_key(rie); assert r.dec(m1[32:]) == p1
    # <- e, ee
    e2 = pub(re); m2 = e2; r.mix_hash(e2); r.mix_key(e2)
    r.mix_key(re.exchange(X25519PublicKey.from_public_bytes(rie))); m2 += r.enc(p2)
    rre = m2[:32]; i.mix_hash(rre); i.mix_key(rre)
    i.mix_key(ie.exchange(X25519PublicKey.from_public_bytes(rre))); assert i.dec(m2[32:]) == p2
    assert i.h == r.h and i.split() == r.split()
    k1, k2 = i.split()
    return m1, m2, k1, k2, i.h

def hkdf(ikm, salt, info, n=32):
    return HKDF(algorithm=hashes.SHA256(), length=n, salt=salt or None, info=info).derive(ikm)

# Self-check against cacophony.
v = [v for v in json.load(open(sys.argv[1]))["vectors"] if v["protocol_name"] == NAME][0]
x = bytes.fromhex
m1, m2, k1, k2, h = nnpsk0(x(v["init_prologue"]), x(v["init_psks"][0]),
                           X25519PrivateKey.from_private_bytes(x(v["init_ephemeral"])),
                           X25519PrivateKey.from_private_bytes(x(v["resp_ephemeral"])),
                           x(v["messages"][0]["payload"]), x(v["messages"][1]["payload"]))
assert m1.hex() == v["messages"][0]["ciphertext"] and m2.hex() == v["messages"][1]["ciphertext"]
assert h.hex() == v["handshake_hash"]
assert ChaCha20Poly1305(k1).encrypt(nonce(0), x(v["messages"][2]["payload"]), b"").hex() == v["messages"][2]["ciphertext"]
print("reference matches cacophony NNpsk0", file=sys.stderr)

# Longwave layer.
token, identity = "longwave-test-token", "device-1234"
psk = hkdf(token.encode(), b"Longwave-NS3-PSK", identity.encode())
kid = HM(psk, b"kid")[:8]
ie = X25519PrivateKey.from_private_bytes(x(v["init_ephemeral"]))
re = X25519PrivateKey.from_private_bytes(x(v["resp_ephemeral"]))
init_index, resp_index = 0x11223344, 0xAABBCCDD
clear = bytes([0x01, 3]) + kid
inner1 = struct.pack("<I", init_index) + bytes([0x03]) + b"hello"
inner2 = struct.pack("<I", resp_index) + bytes([0x00]) + b"hello-ack"
m1, m2, k1, k2, h = nnpsk0(b"Longwave-NS3" + clear, psk, ie, re, inner1, inner2)
initiation = clear + m1
response = bytes([0x02]) + struct.pack("<I", init_index) + m2

def record_key(split, cipher): return hkdf(split, b"", ("Longwave-NS3 record " + cipher).encode())
def rekey(k): return hkdf(k, b"", b"Longwave-NS3 rekey")
def record(key, aead, phase, receiver, pn, body):
    hdr = bytes([0x03 | (0x10 if phase else 0)]) + struct.pack("<IQ", receiver, pn)
    return hdr + aead(key).encrypt(nonce(pn), body, hdr)

c2s = record_key(k1, "AES-256-GCM"); s2c = record_key(k2, "AES-256-GCM")
out = {
    "psk": psk.hex(), "keyID": kid.hex(),
    "initiation": initiation.hex(), "response": response.hex(), "handshakeHash": h.hex(),
    "clientRecord0": record(c2s, AESGCM, False, resp_index, 0, b"ping").hex(),
    "hostRecord0": record(s2c, AESGCM, False, init_index, 0, b"pong").hex(),
    "clientRecordGen1": record(rekey(c2s), AESGCM, True, resp_index, 5, b"after rekey").hex(),
    "chachaClientRecord0": record(record_key(k1, "ChaCha20-Poly1305"), ChaCha20Poly1305, False, resp_index, 0, b"ping").hex(),
}
print(json.dumps(out, indent=1))
