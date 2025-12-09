#!/usr/bin/env python3
import argparse
import base64
import hashlib
import json
import sys
import difflib

# -----------------------------------------------------------------------------
# Master Password Hash Logic
# -----------------------------------------------------------------------------


def derive_master_key_pbkdf2(
    password: str, email: str, iterations: int, dklen: int = 32
) -> bytes:
    return hashlib.pbkdf2_hmac(
        "sha256",
        password.encode("utf-8"),
        email.strip().encode("utf-8"),
        iterations,
        dklen=dklen,
    )


def compute_master_password_auth_hash(
    master_key: bytes, password: str, iterations: int = 1, dklen: int = 32
) -> str:
    out = hashlib.pbkdf2_hmac(
        "sha256",
        master_key,
        password.encode("utf-8"),
        iterations,
        dklen=dklen,
    )
    return base64.b64encode(out).decode("ascii")


def action_hash(args):
    master_key = derive_master_key_pbkdf2(
        password=args.password,
        email=args.email,
        iterations=args.kdf_iterations,
    )

    final_iters = 2 if args.local else 1
    mph_b64 = compute_master_password_auth_hash(
        master_key, args.password, iterations=final_iters
    )
    print(mph_b64)


# -----------------------------------------------------------------------------
# Item Matching Logic
# -----------------------------------------------------------------------------


def get_clean_item(item):
    # Create a copy to modify
    item_copy = item.copy()
    # Remove fields that change or are irrelevant for content matching
    fields_to_remove = [
        "attachments",
        "collectionIds",
        "creationDate",
        "deletedDate",
        "folderId",
        "id",
        "object",
        "organizationId",
        "passwordHistory",
        "passwordRevisionDate",
        "revisionDate",
    ]
    for field in fields_to_remove:
        item_copy.pop(field, None)
    return item_copy


def get_item_hash(item, debug=False):
    item_copy = get_clean_item(item)
    # Sort keys to ensure consistent JSON string
    item_str = json.dumps(item_copy, sort_keys=True)
    if debug:
        sys.stderr.write(f"DEBUG HASH INPUT for {item.get('id')}: {item_str}\n")
    return hashlib.sha256(item_str.encode("utf-8")).hexdigest()


def action_match(args):
    try:
        with open(args.source_file, "r") as f:
            source_data = json.load(f)

        with open(args.dest_file, "r") as f:
            dest_data = json.load(f)
    except Exception as e:
        sys.stderr.write(f"Error reading JSON files: {e}\n")
        sys.exit(1)

    # Handle both wrapped {items: [...]} and raw array [...] formats
    source_items = (
        source_data.get("items", source_data)
        if isinstance(source_data, dict)
        else source_data
    )
    dest_items = (
        dest_data.get("items", dest_data) if isinstance(dest_data, dict) else dest_data
    )

    if not isinstance(source_items, list) or not isinstance(dest_items, list):
        sys.stderr.write("Error: JSON data does not contain a list of items.\n")
        sys.exit(1)

    dest_map = {}
    # Also keep a map of name -> list of items for fuzzy matching debugging
    dest_name_map = {}

    for item in dest_items:
        if "id" in item:
            h = get_item_hash(item)
            if h not in dest_map:
                dest_map[h] = []
            dest_map[h].append(item["id"])

            name = item.get("name")
            if name:
                if name not in dest_name_map:
                    dest_name_map[name] = []
                dest_name_map[name].append(item)

    debug_count = 0
    for item in source_items:
        if "id" in item:
            h = get_item_hash(item)
            if h in dest_map and dest_map[h]:
                # Pop the first matching ID to handle duplicates correctly
                dest_id = dest_map[h].pop(0)
                print(f"{item['id']}\t{dest_id}")
            else:
                if debug_count < 3:
                    sys.stderr.write(
                        f"DEBUG: No match for source item {item['id']} ({item.get('name')})\n"
                    )
                    # Try to find a candidate by name
                    name = item.get("name")
                    if name and name in dest_name_map:
                        candidates = dest_name_map[name]
                        sys.stderr.write(
                            f"DEBUG: Found {len(candidates)} candidates with same name.\n"
                        )
                        for cand in candidates:
                            src_clean = get_clean_item(item)
                            dst_clean = get_clean_item(cand)

                            src_str = json.dumps(src_clean, sort_keys=True, indent=2)
                            dst_str = json.dumps(dst_clean, sort_keys=True, indent=2)

                            # Only show diff if they are "close" enough?
                            # For now, just showing diff for same-named items is a good heuristic for "close"
                            diff = difflib.unified_diff(
                                src_str.splitlines(),
                                dst_str.splitlines(),
                                fromfile=f"Source {item['id']}",
                                tofile=f"Dest {cand['id']}",
                                lineterm="",
                            )
                            for line in diff:
                                sys.stderr.write(f"DIFF: {line}\n")
                    debug_count += 1


# -----------------------------------------------------------------------------
# Main Entry Point
# -----------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(description="Bitwarden Portal Helper Script")
    subparsers = parser.add_subparsers(
        dest="action", required=True, help="Action to perform"
    )

    # Subcommand: hash
    parser_hash = subparsers.add_parser("hash", help="Calculate master password hash")
    parser_hash.add_argument("--email", "-e", required=True, help="User email")
    parser_hash.add_argument("--password", "-p", required=True, help="Master password")
    parser_hash.add_argument(
        "--kdf-iterations", type=int, default=600000, help="KDF iterations"
    )
    parser_hash.add_argument(
        "--local", action="store_true", help="Calculate local hash"
    )
    parser_hash.set_defaults(func=action_hash)

    # Subcommand: match
    parser_match = subparsers.add_parser(
        "match", help="Match items between source and destination JSON"
    )
    parser_match.add_argument("source_file", help="Source JSON file")
    parser_match.add_argument("dest_file", help="Destination JSON file")
    parser_match.set_defaults(func=action_match)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
