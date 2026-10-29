#!/usr/bin/env python3
"""Regenerate cubin_embed.h from the two probe tools (deterministic).

Usage:  ./embed_cubins.py            # build via nvcc/ptxas, write cubin_embed.h
Verified output hashes (nvcc/ptxas 13.1, same tools as 2026-10-29 runs):
  mma_probe.cubin  7f5aec64924846406952206518e4424e50fec2fdaf9b7cd35df934f66dd37a04
  vfy_probe.cubin  4fe8459d6a730af48329075ec74363d1ee70f94b515f4d5d4417d91c382e0e43
"""
import binascii
import hashlib
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.environ.get("GPU_UNLOCK_REPO") or os.path.expanduser("~/code/gpu-unlock-ada")
BENCH = os.path.join(ROOT, "diagnostics", "bench")

EXPECT = {
    "mma_probe.cubin": "7f5aec64924846406952206518e4424e50fec2fdaf9b7cd35df934f66dd37a04",
    "vfy_probe.cubin": "4fe8459d6a730af48329075ec74363d1ee70f94b515f4d5d4417d91c382e0e43",
}


def run(cmd):
    subprocess.run(cmd, check=True)


def sha(path):
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def main():
    run(["nvcc", "-cubin", "-arch=sm_89", "-O3", "-std=c++17",
         "-o", "mma_probe.cubin", os.path.join(BENCH, "mma_bench.cu")])
    run(["nvcc", "-ptx", "-arch=sm_89", "-O3", "-std=c++17",
         "-o", "vfy.ptx", os.path.join(BENCH, "tensor_modes_issue.cu")])
    run(["ptxas", "-arch=sm_89", "-O3", "-o", "vfy_probe.cubin", "vfy.ptx"])
    for name, want in EXPECT.items():
        got = sha(name)
        if got != want:
            sys.exit(f"hash drift {name}: {got} != {want}")
    with open("cubin_embed.h", "w") as f:
        for pre, p in (("MMA", "mma_probe.cubin"), ("VFY", "vfy_probe.cubin")):
            f.write(f'#define {pre}_CUBIN_SHA "{sha(p)}"\n')
        for name, var in (("mma_probe.cubin", "mma_cubin"),
                          ("vfy_probe.cubin", "vfy_cubin")):
            b = binascii.hexlify(open(name, "rb").read()).decode()
            body = ",".join("0x" + b[i:i + 2] for i in range(0, len(b), 2))
            f.write(f"static const unsigned char {var}[] = {{{body}}};\n")
    os.remove("vfy.ptx")
    print("cubin_embed.h regenerated and hash-verified")


if __name__ == "__main__":
    main()
