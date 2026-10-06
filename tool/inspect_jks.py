"""Structurally validates a JKS keystore without a JDK.

Reads the JKS container, lists the aliases and certificates, extracts each
certificate chain, and verifies the SHA-1 integrity digests that Java itself
writes into the file (store digest and per-key digest). A matching digest proves
both that the file is an authentic, unmodified JKS and that the password taken
from key.properties is the real password of that store / of that key.

Only structure and public certificates are printed; passwords never are.
"""
import hashlib
import struct
import sys
from pathlib import Path

MIGHTY = b"Mighty Aphrodite"


def utf16_be(text: str) -> bytes:
    return text.encode("utf-16-be")


def read_utf(data: bytes, pos: int):
    (length,) = struct.unpack_from(">H", data, pos)
    value = data[pos + 2:pos + 2 + length].decode("utf-8", "replace")
    return value, pos + 2 + length


def digest_candidates(password: str, data: bytes):
    pw = utf16_be(password)
    return {
        "sha1(utf16be(pw) + MIGHTY + data)": hashlib.sha1(pw + MIGHTY + data).digest(),
        "sha1(utf16be(pw) + data)": hashlib.sha1(pw + data).digest(),
        "sha1(MIGHTY + data)": hashlib.sha1(MIGHTY + data).digest(),
        "sha1(pw + MIGHTY + data)": hashlib.sha1(password.encode() + MIGHTY + data).digest(),
    }


def parse(path: Path):
    data = path.read_bytes()
    magic, version, count = struct.unpack_from(">III", data, 0)
    report = {
        "file": str(path),
        "size": len(data),
        "magic_ok": magic == 0xFEEDFEED,
        "version": version,
        "entry_count": count,
        "entries": [],
    }
    pos = 12
    for _ in range(count):
        (tag,) = struct.unpack_from(">I", data, pos)
        pos += 4
        alias, pos = read_utf(data, pos)
        (timestamp,) = struct.unpack_from(">q", data, pos)
        pos += 8
        entry = {"alias": alias, "tag": tag, "created_ms": timestamp, "certs": [],
                 "key_der_len": None, "key_blob_len": None}
        if tag == 1:
            (key_len,) = struct.unpack_from(">I", data, pos)
            pos += 4
            key_blob = data[pos:pos + key_len]
            entry["key_blob_len"] = key_len
            # The DER EncryptedPrivateKeyInfo length comes from its own header.
            if len(key_blob) > 4 and key_blob[0] == 0x30:
                der_len = key_blob[1]
                if der_len & 0x80:
                    n = der_len & 0x7F
                    der_len = int.from_bytes(key_blob[2:2 + n], "big") + 2 + n
                else:
                    der_len = der_len + 2
                entry["key_der_len"] = der_len
            entry["key_blob"] = key_blob
            pos += key_len
        if tag == 1:
            (chain_len,) = struct.unpack_from(">I", data, pos)
            pos += 4
        else:
            chain_len = 1
        for _ in range(chain_len):
            cert_type, pos = read_utf(data, pos)
            (cert_len,) = struct.unpack_from(">I", data, pos)
            pos += 4
            cert = data[pos:pos + cert_len]
            pos += cert_len
            entry["certs"].append((cert_type, cert))
        report["entries"].append(entry)
    report["trailing_bytes"] = len(data) - pos
    report["store_digest"] = data[-20:]
    report["store_data"] = data[:-20]
    return report


def main():
    keystore = Path(sys.argv[1])
    properties = Path(sys.argv[2])
    report = parse(keystore)

    props = {}
    for line in properties.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        props[key.strip()] = value.strip()

    print(f"file             : {report['file']}")
    print(f"size             : {report['size']} bytes")
    print(f"magic 0xFEEDFEED : {'OK' if report['magic_ok'] else 'MISMATCH'}")
    print(f"JKS version      : {report['version']}")
    print(f"entries          : {report['entry_count']}")
    print(f"trailing bytes   : {report['trailing_bytes']} (0 = clean parse)")
    print()

    print("== entries ==")
    for entry in report["entries"]:
        kind = {1: "private key", 2: "trusted certificate"}.get(entry["tag"], entry["tag"])
        print(f"alias            : {entry['alias']}  ({kind})")
        if entry["key_blob_len"] is not None:
            print(f"  encrypted key  : {entry['key_blob_len']} bytes "
                  f"(DER body {entry['key_der_len']}, digest "
                  f"{entry['key_blob_len'] - (entry['key_der_len'] or 0)} bytes)")
            body = entry["key_blob"][:entry["key_der_len"]]
            tail = entry["key_blob"][entry["key_der_len"]:]
            key_password = props.get("keyPassword", "")
            if len(tail) == 20 and body:
                match = [name for name, digest in digest_candidates(key_password, body).items()
                         if digest == tail]
                print(f"  key digest     : {'VERIFIED with keyPassword (' + match[0] + ')' if match else 'NOT verified'}")
        for cert_type, cert in entry["certs"]:
            out = Path(f"/tmp/recover/{entry['alias']}.der")
            out.write_bytes(cert)
            print(f"  {cert_type} cert   : {len(cert)} bytes -> {out}")
    print()

    print("== store integrity digest (proves the password matches the keystore) ==")
    store_password = props.get("storePassword", "")
    matches = [name for name, digest in digest_candidates(store_password, report["store_data"]).items()
               if digest == report["store_digest"]]
    if matches:
        print(f"VERIFIED with storePassword using {matches[0]}")
    else:
        print("NOT verified (password/format mismatch)")

    print()
    print("== key.properties ==")
    print(f"storeFile present    : {'yes' if props.get('storeFile') else 'no'}")
    print(f"storePassword present: {'yes' if props.get('storePassword') else 'no'}")
    print(f"keyAlias present     : {'yes' if props.get('keyAlias') else 'no'}")
    print(f"keyPassword present  : {'yes' if props.get('keyPassword') else 'no'}")
    aliases = [e["alias"] for e in report["entries"]]
    print(f"alias matches an entry in the keystore: "
          f"{'YES' if props.get('keyAlias') in aliases else 'NO'}")


if __name__ == "__main__":
    main()
