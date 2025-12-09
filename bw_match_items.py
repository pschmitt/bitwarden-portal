#!/usr/bin/env python3
import json
import hashlib
import sys


def get_item_hash(item, debug=False):
    # Create a copy to modify
    item_copy = item.copy()
    # Remove fields that change or are irrelevant for content matching
    # id: changes on import
    # organizationId: might change
    # collectionIds: might change
    # revisionDate: changes
    # attachments: we are handling them separately, and they might not be present/same yet
    # folderId: changes on import if folders are recreated
    # creationDate: changes on import
    # deletedDate: might differ
    fields_to_remove = [
        "id",
        "organizationId",
        "collectionIds",
        "revisionDate",
        "attachments",
        "folderId",
        "creationDate",
        "deletedDate",
    ]
    for field in fields_to_remove:
        item_copy.pop(field, None)

    # Sort keys to ensure consistent JSON string
    item_str = json.dumps(item_copy, sort_keys=True)
    if debug:
        sys.stderr.write(f"DEBUG HASH INPUT for {item.get('id')}: {item_str}\n")
    return hashlib.sha256(item_str.encode("utf-8")).hexdigest()


def main(source_file, dest_file):
    try:
        with open(source_file, "r") as f:
            source_data = json.load(f)

        with open(dest_file, "r") as f:
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
    for item in dest_items:
        if "id" in item:
            h = get_item_hash(item)
            if h not in dest_map:
                dest_map[h] = []
            dest_map[h].append(item["id"])

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
                    sys.stderr.write(f"DEBUG: No match for source item {item['id']}\n")
                    get_item_hash(item, debug=True)
                    debug_count += 1


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python3 bw_match_items.py <source_json> <dest_json>")
        sys.exit(1)
    main(sys.argv[1], sys.argv[2])
