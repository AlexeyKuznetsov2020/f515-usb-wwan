#!/usr/bin/env python3
"""Convert a PKCS#8 RSA private key into the ADB public-key format (base64 blob).

ADB stores public keys as base64 of:
  struct RSAPublicKey {
      uint32 len;        // modulus length in 32-bit words (64)
      uint32 n0inv;      // -1 / n[0] mod 2^32
      uint32 n[64];      // modulus, little-endian words
      uint32 rr[64];     // R^2 mod n, little-endian words
      int32  exponent;   // 65537
  };
"""
import base64
import struct
import subprocess
import sys

KEY = sys.argv[1] if len(sys.argv) > 1 else "assets/adbkey"
NAME = sys.argv[2] if len(sys.argv) > 2 else "netkeeper@f515"

out = subprocess.check_output(["openssl", "rsa", "-in", KEY, "-noout", "-modulus"], text=True)
n = int(out.strip().split("=", 1)[1], 16)
e = 65537
words = 64
assert n.bit_length() == 2048, n.bit_length()

n0inv = (-pow(n, -1, 1 << 32)) % (1 << 32)
rr = pow(1 << (32 * words), 2, n)

blob = struct.pack("<II", words, n0inv)
blob += b"".join(struct.pack("<I", (n >> (32 * i)) & 0xFFFFFFFF) for i in range(words))
blob += b"".join(struct.pack("<I", (rr >> (32 * i)) & 0xFFFFFFFF) for i in range(words))
blob += struct.pack("<i", e)
assert len(blob) == 524, len(blob)

print(base64.b64encode(blob).decode() + " " + NAME)
