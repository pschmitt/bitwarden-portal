#!/usr/bin/env python3
import argparse
import base64
import hashlib
import sys

def derive_master_key_pbkdf2(password: str, email: str, iterations: int, dklen: int = 32) -> bytes:
  return hashlib.pbkdf2_hmac(
    "sha256",
    password.encode("utf-8"),
    email.strip().encode("utf-8"),
    iterations,
    dklen=dklen,
  )

def compute_master_password_auth_hash(master_key: bytes, password: str, iterations: int = 1, dklen: int = 32) -> str:
  out = hashlib.pbkdf2_hmac(
    "sha256",
    master_key,
    password.encode("utf-8"),
    iterations,
    dklen=dklen,
  )
  return base64.b64encode(out).decode("ascii")

def main(argv):
  p = argparse.ArgumentParser()
  p.add_argument("--email", "-e", required=True)
  p.add_argument("--password", "-p", required=True)
  p.add_argument("--kdf-iterations", type=int, default=600000)
  p.add_argument("--local", action="store_true")
  args = p.parse_args(argv)

  master_key = derive_master_key_pbkdf2(
    password=args.password,
    email=args.email,
    iterations=args.kdf_iterations,
  )

  final_iters = 2 if args.local else 1
  mph_b64 = compute_master_password_auth_hash(master_key, args.password, iterations=final_iters)
  print(mph_b64)

if __name__ == "__main__":
  main(sys.argv[1:])

