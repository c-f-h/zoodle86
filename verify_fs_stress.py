import pathlib
import sys

CHUNK_SIZE = 640
CHUNK_COUNT = 6
TOTAL_BYTES = CHUNK_SIZE * CHUNK_COUNT
EXPECTED_FILES = {
    "fdstrs_a.txt": b"A",
    "fdstrs_b.txt": b"B",
}
SEEK_FILE = "seek.txt"
SEEK_EXPECTED = b"01234AB789XY\x00\x00Z"


def fill_chunk(file_tag: int, iteration: int) -> bytes:
    chunk = bytearray(CHUNK_SIZE)
    iter_byte = iteration
    for index in range(CHUNK_SIZE):
        idx_byte = index % 251
        selector = index % 8
        if selector == 0:
            value = file_tag
        elif selector == 1:
            value = ord("0") + iter_byte
        elif selector == 2:
            value = ord(":")
        elif selector == 3:
            value = ord("a") + iter_byte
        elif selector == 4:
            value = ord("0") + (iteration % 10)
        elif selector == 5:
            value = ord("A") + (idx_byte % 26)
        elif selector == 6:
            value = ord("0") + (idx_byte % 10)
        else:
            value = ord("#")
        chunk[index] = value
    return bytes(chunk)


def expected_bytes(file_tag: bytes) -> bytes:
    parts = [fill_chunk(file_tag[0], iteration) for iteration in range(CHUNK_COUNT)]
    return b"".join(parts)


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: verify_fs_stress.py <extracted-directory>")
        return 2

    root = pathlib.Path(sys.argv[1])
    if not root.is_dir():
        print(f"Expected directory, got: {root}")
        return 2

    for name, tag in EXPECTED_FILES.items():
        path = root / name
        if not path.is_file():
            print(f"Missing expected file: {path}")
            return 1

        data = path.read_bytes()
        expected = expected_bytes(tag)
        if len(data) != TOTAL_BYTES:
            print(f"Wrong size for {name}: expected {TOTAL_BYTES}, got {len(data)}")
            return 1
        if data != expected:
            print(f"Content mismatch for {name}")
            return 1

        print(f"Verified {name}: {len(data)} bytes")

    seek_path = root / SEEK_FILE
    if not seek_path.is_file():
        print(f"Missing expected file: {seek_path}")
        return 1

    seek_data = seek_path.read_bytes()
    if seek_data != SEEK_EXPECTED:
        print(f"Content mismatch for {SEEK_FILE}")
        return 1

    print(f"Verified {SEEK_FILE}: {len(seek_data)} bytes")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
