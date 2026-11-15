#!/usr/bin/env python3
# Parse the SWEET persistent console ring dumped to the tail of a partition.
# Usage: python3 read-ring.py ringtail.bin [out.txt]
# Input = the last 1025 x 4096 bytes of the partition (block 0 = header, 1..1024 = 4 MiB ring).
import sys, struct

BLK = 4096
RING = 4 << 20  # SWEET_LOG_SIZE

def main():
    if len(sys.argv) < 2:
        print("usage: read-ring.py ringtail.bin [out.txt]"); sys.exit(2)
    data = open(sys.argv[1], 'rb').read()
    if len(data) < BLK + RING:
        print(f"warning: file is {len(data)} bytes, expected >= {BLK+RING}", file=sys.stderr)
    magic = data[:8]
    if magic != b'SWEETLOG':
        print(f"NO SWEETLOG magic at tail (got {magic!r}). Wrong partition or never flushed.", file=sys.stderr)
        sys.exit(1)
    version, size = struct.unpack_from('<II', data, 8)
    total, seq = struct.unpack_from('<QQ', data, 16)
    panic = (seq == (1 << 64) - 1)
    print(f"# SWEETLOG v{version} size={size} total={total} seq={'PANIC' if panic else seq}", file=sys.stderr)
    ring = data[BLK:BLK + size]
    if total >= size:
        # oldest valid byte is at (total % size); text wraps
        start = total % size
        text = ring[start:] + ring[:start]
        valid = size
    else:
        text = ring[:total]
        valid = total
    out = text[:valid]
    # strip trailing NULs
    out = out.rstrip(b'\x00')
    sink = open(sys.argv[2], 'wb') if len(sys.argv) > 2 else sys.stdout.buffer
    sink.write(out)
    if len(sys.argv) > 2:
        print(f"# wrote {len(out)} bytes to {sys.argv[2]}", file=sys.stderr)

if __name__ == '__main__':
    main()
