import argparse
import csv
import json
import logging
import os
import sys
import time
from datetime import datetime
from logging.handlers import RotatingFileHandler
import requests

api_key = None
organization_uuid = None
org_id = None
default_group_id = None
remove_unmatched_devices = True


class _HelpFormatter(argparse.ArgumentDefaultsHelpFormatter, argparse.RawDescriptionHelpFormatter):
    pass


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        prog="DynamicGrouping.py",
        description=(
            "Sync Automox saved searches to '<name> (Dynamic)' server groups. "
            "Creates missing dynamic groups, moves matched devices into them, "
            "and optionally evacuates devices that no longer match."
        ),
        epilog=(
            "example:\n"
            "  python3 DynamicGrouping.py \\\n"
            "      --api-key abc123 \\\n"
            "      --organization-uuid 11111111-2222-3333-4444-555555555555 \\\n"
            "      --org-id 67890 \\\n"
            "      --default-group-id 42 \\\n"
            "      --no-remove-unmatched-devices"
        ),
        formatter_class=_HelpFormatter,
    )
    parser.add_argument("--api-key", required=True, help="Automox API key (Bearer token).")
    parser.add_argument("--organization-uuid", required=True, help="Automox organization UUID.")
    parser.add_argument("--org-id", required=True, help="Automox organization id (used as the 'o' query param).")
    parser.add_argument("--default-group-id", required=True, type=int, help="Parent/fallback server group id.")
    parser.add_argument(
        "--remove-unmatched-devices",
        action=argparse.BooleanOptionalAction,
        default=True,
        help=(
            "When set, devices currently in a (Dynamic) group that no longer match its saved"
            "search are moved to the default group. Use --no-remove-unmatched-devices to leave them alone."
        ),
    )
    return parser.parse_args(argv)


_script_dir = os.path.dirname(os.path.abspath(__file__))
_log_path = os.path.join(_script_dir, "DynamicGrouping.log")
_log_format = "%(asctime)s [%(levelname)s] %(message)s"
_file_handler = RotatingFileHandler(_log_path, maxBytes=5 * 1024 * 1024, backupCount=5)
_file_handler.setFormatter(logging.Formatter(_log_format))
_stream_handler = logging.StreamHandler()
_stream_handler.setFormatter(logging.Formatter(_log_format))
logging.basicConfig(level=logging.INFO, handlers=[_file_handler, _stream_handler])
logger = logging.getLogger("DynamicGrouping")

stats = {
    "groups_created": 0,
    "groups_create_skipped": 0,
    "devices_added": 0,
    "devices_moved_to_default": 0,
    "orphan_groups_deleted": 0,
    "failures": 0,
}


def _request(method, url, max_attempts=3, **kwargs):
    """HTTP call with retry on 429, 5xx, and connection errors."""
    delay = 1.0
    for attempt in range(1, max_attempts + 1):
        try:
            r = requests.request(method, url, **kwargs)
        except (requests.ConnectionError, requests.Timeout) as e:
            if attempt >= max_attempts:
                raise
            logger.warning(
                "%s %s connection error: %s; retrying in %.1fs (attempt %d/%d)",
                method, url, e, delay, attempt, max_attempts,
            )
            time.sleep(delay)
            delay *= 2
            continue
        if r.status_code == 429 or r.status_code >= 500:
            if attempt >= max_attempts:
                return r
            logger.warning(
                "%s %s returned %d; retrying in %.1fs (attempt %d/%d)",
                method, url, r.status_code, delay, attempt, max_attempts,
            )
            time.sleep(delay)
            delay *= 2
            continue
        return r
    return r


def _paginate_flat(url, headers, params=None, page_size=500):
    """Page through an endpoint that returns a flat JSON array.

    Uses 'page' + 'limit' query params; stops on empty or short batch.
    """
    items = []
    page = 0
    base = dict(params or {})
    while True:
        p = {**base, "limit": str(page_size), "page": str(page)}
        response = _request("GET", url, headers=headers, params=p)
        if not response.ok:
            raise RuntimeError(
                f"GET {url} (page={page}) failed: {response.status_code} {response.text!r}"
            )
        if not response.content or not response.content.strip():
            break
        batch = response.json()
        if not batch:
            break
        if not isinstance(batch, list):
            raise RuntimeError(
                f"Expected list from {url} (page={page}), got {type(batch).__name__}: {batch!r}"
            )
        items.extend(batch)
        if len(batch) < page_size:
            break
        page += 1
    return items


def _paginate_content(url, headers, params=None, page_size=200):
    """Page through a Spring-style endpoint wrapped as {"content": [...]}.

    Uses 'page' + 'size' query params; stops on empty or short batch.
    """
    items = []
    page = 0
    base = dict(params or {})
    while True:
        p = {**base, "size": str(page_size), "page": str(page)}
        response = _request("GET", url, headers=headers, params=p)
        if not response.ok:
            raise RuntimeError(
                f"GET {url} (page={page}) failed: {response.status_code} {response.text!r}"
            )
        data = response.json()
        batch = data.get('content', [])
        if not batch:
            break
        items.extend(batch)
        if len(batch) < page_size:
            break
        page += 1
    return items


def get_saved_searches():
    """Return {name: saved_search_id} for all saved searches in the org."""
    url = f"https://console.automox.com/api/server-groups-api/v1/organizations/{organization_uuid}/device/saved-search/list"
    headers = {"Authorization": f"Bearer {api_key}"}
    items = _paginate_content(url, headers, params={"type": "search"})
    return {item['name']: item['id'] for item in items}


def get_devices_for_searches(search_ids):
    """Refresh each saved search, then return {saved_search_id: [device_uuids]}."""
    results = {}
    headers = {"Authorization": f"Bearer {api_key}"}
    for saved_search_id in search_ids:
        refresh_url = f"https://console.automox.com/api/server-groups-api/v1/organizations/{organization_uuid}/device/search/{saved_search_id}/refresh"
        r = _request("POST", refresh_url, headers=headers)
        if not r.ok:
            logger.warning(
                "refresh %s FAILED | Status: %d | Body: %s — proceeding with cached results",
                saved_search_id, r.status_code, r.text,
            )
        url = f"https://console.automox.com/api/server-groups-api/v1/organizations/{organization_uuid}/device/saved-search/{saved_search_id}/results"
        uuids = _paginate_flat(url, headers)
        logger.info("%s | devices: %d", saved_search_id, len(uuids))
        if uuids:
            results[saved_search_id] = uuids
    return results


def create_dynamic_groups(group_names):
    """Create a '<name> (Dynamic)' server group for each provided name."""
    url = "https://console.automox.com/api/servergroups"
    headers = {
        "Content-Type": "application/json",
        "Authorization": f"Bearer {api_key}",
    }
    query = {"o": org_id}
    for group in group_names:
        name = group + " (Dynamic)"
        payload = {
            "name": name,
            "refresh_interval": 240,
            "parent_server_group_id": default_group_id,
            "ui_color": "#3C78D8",
        }
        try:
            r = _request("POST", url, json=payload, headers=headers, params=query)
        except Exception as e:
            stats["failures"] += 1
            logger.exception("create group %r errored: %s", name, e)
            continue
        if r.ok:
            stats["groups_created"] += 1
            logger.info("create group %r | Status: %d", name, r.status_code)
        elif r.status_code == 400 and "already been taken" in r.text:
            stats["groups_create_skipped"] += 1
            logger.info("create group %r | already exists, skipping", name)
        else:
            stats["failures"] += 1
            logger.error("create group %r FAILED | Status: %d | Body: %s", name, r.status_code, r.text)


def get_all_servers(extra_params=None):
    """Return every server across all pages of /api/servers."""
    params = {"o": org_id}
    if extra_params:
        params.update(extra_params)
    return _paginate_flat(
        "https://console.automox.com/api/servers",
        headers={"Authorization": f"Bearer {api_key}"},
        params=params,
    )


def get_uuid_to_id_map():
    """Return {device_uuid: device_id} for all servers in the org."""
    return {device['uuid']: device['id'] for device in get_all_servers()}


def get_server_groups():
    """Return {group_name: group_id} for all server groups in the org."""
    items = _paginate_flat(
        "https://console.automox.com/api/servergroups",
        headers={"Authorization": f"Bearer {api_key}"},
        params={"o": org_id},
    )
    return {g['name']: g['id'] for g in items}


def get_devices_in_group(group_id, servers):
    """Return list of device ids in the given group, filtered from a cached server list."""
    return [d['id'] for d in servers if d.get('server_group_id') == group_id]


def set_device_group(device_id, group_id):
    """Move a single device into the given server group."""
    return _request(
        "PUT",
        f"https://console.automox.com/api/servers/{device_id}",
        headers={"Authorization": f"Bearer {api_key}", "Content-Type": "application/json"},
        params={"o": org_id},
        json={"server_group_id": group_id},
    )


def delete_server_group(group_id):
    """Delete a server group by id."""
    return _request(
        "DELETE",
        f"https://console.automox.com/api/servergroups/{group_id}",
        headers={"Authorization": f"Bearer {api_key}"},
        params={"o": org_id},
    )


def write_conflicts_csv(final, servers, path=None):
    """Write a CSV listing devices that matched 2+ saved searches.

    Columns: Device, Resulting Group, Other Matched Groups.
    "Resulting Group" is the (Dynamic) group sync_group will leave the device
    in — i.e. the last saved search in `final` that matched it (last-write-wins).
    """
    device_to_matched_groups = {}
    for group_name, device_ids in final.items():
        for did in device_ids:
            device_to_matched_groups.setdefault(did, []).append(group_name)

    conflicts = {d: g for d, g in device_to_matched_groups.items() if len(g) > 1}
    if not conflicts:
        logger.info("No device conflicts found.")
        return

    server_by_id = {s['id']: s for s in servers}

    if path is None:
        path = os.path.join(_script_dir, f"device_conflicts_{datetime.now().strftime('%Y-%m-%d_%H-%M-%S')}.csv")

    with open(path, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['Device', 'Resulting Group', 'Other Matched Groups'])
        for did, matched_groups in conflicts.items():
            server = server_by_id.get(did, {})
            device_name = server.get('name') or server.get('hostname') or str(did)
            winner = matched_groups[-1]
            resulting_group = f"{winner} (Dynamic)"
            others = [g for g in matched_groups if g != winner]
            logger.debug(
                "conflict row: device_id=%s name=%r -> %r | matches=%s",
                did, device_name, resulting_group, matched_groups,
            )
            writer.writerow([device_name, resulting_group, '; '.join(others)])

    logger.info("Wrote %d device conflicts to %s", len(conflicts), path)


def _device_label(server):
    """Build a 'hostname (id)' label from a server record."""
    name = server.get('name') or server.get('hostname') or str(server.get('id'))
    return f"{name} ({server.get('id')})"


def sync_group(name, desired_device_ids, group_name_to_id, fallback_group_id, servers):
    """Add desired devices to the (Dynamic) group; move the rest to fallback group.

    `servers` is the cached pre-sync server list — used to find current group members
    without re-fetching the org's device list per group.
    """
    dynamic_group_name = f"{name} (Dynamic)"
    group_id = group_name_to_id.get(dynamic_group_name)
    id_to_label = {s['id']: _device_label(s) for s in servers}
    logger.info("%s | group_id: %s | devices: %s", dynamic_group_name, group_id, desired_device_ids)

    if not group_id:
        logger.warning("Group not found: %s", dynamic_group_name)
        stats["failures"] += 1
        return

    for device_id in desired_device_ids:
        label = id_to_label.get(device_id, str(device_id))
        try:
            r = set_device_group(device_id, group_id)
        except Exception as e:
            stats["failures"] += 1
            logger.exception("%s -> %s errored: %s", label, dynamic_group_name, e)
            continue
        if r.ok:
            stats["devices_added"] += 1
            logger.info("%s -> %s | Status: %d", label, dynamic_group_name, r.status_code)
        else:
            stats["failures"] += 1
            logger.error("%s -> %s FAILED | Status: %d | Body: %s", label, dynamic_group_name, r.status_code, r.text)

    if not remove_unmatched_devices:
        return

    current_device_ids = get_devices_in_group(group_id, servers)
    to_remove = [d for d in current_device_ids if d not in desired_device_ids]
    for device_id in to_remove:
        label = id_to_label.get(device_id, str(device_id))
        try:
            r = set_device_group(device_id, fallback_group_id)
        except Exception as e:
            stats["failures"] += 1
            logger.exception("%s -> default group errored: %s", label, e)
            continue
        if r.ok:
            stats["devices_moved_to_default"] += 1
            logger.info("%s -> default group (%s) | Status: %d", label, fallback_group_id, r.status_code)
        else:
            stats["failures"] += 1
            logger.error("%s -> default group FAILED | Status: %d | Body: %s", label, r.status_code, r.text)


def main():
    global api_key, organization_uuid, org_id, default_group_id, remove_unmatched_devices
    args = parse_args()
    api_key = args.api_key
    organization_uuid = args.organization_uuid
    org_id = args.org_id
    default_group_id = args.default_group_id
    remove_unmatched_devices = args.remove_unmatched_devices

    logger.info("=== DynamicGrouping run starting ===")
    try:
        existing_groups = get_server_groups()
        if default_group_id not in set(existing_groups.values()):
            logger.error(
                "default_group_id %s is not a valid server group in this org — fix the USER INPUT block. Aborting.",
                default_group_id,
            )
            sys.exit(1)

        groups = get_saved_searches()
        newgroups = list(groups.keys())
        logger.info("Saved searches: %s", newgroups)

        results = get_devices_for_searches(list(groups.values()))
        logger.debug("Saved-search results: %s", results)

        create_dynamic_groups(newgroups)

        groups_by_id = {v: k for k, v in groups.items()}
        named_results = {groups_by_id[sid]: uuids for sid, uuids in results.items()}

        all_servers = get_all_servers()
        logger.info("Cached %d servers for this run.", len(all_servers))
        uuid_to_id = {device['uuid']: device['id'] for device in all_servers}
        final = {
            name: [uuid_to_id[uuid] for uuid in uuids if uuid in uuid_to_id]
            for name, uuids in named_results.items()
        }

        group_name_to_id = get_server_groups()
        fallback_group_id = default_group_id

        write_conflicts_csv(final, all_servers)

        id_to_label = {s['id']: _device_label(s) for s in all_servers}
        desired_dynamic_names = {f"{n} (Dynamic)" for n in groups.keys()}
        for group_name, group_id in group_name_to_id.items():
            if group_name.endswith(" (Dynamic)") and group_name not in desired_dynamic_names:
                for device_id in get_devices_in_group(group_id, all_servers):
                    label = id_to_label.get(device_id, str(device_id))
                    try:
                        r = set_device_group(device_id, fallback_group_id)
                    except Exception as e:
                        stats["failures"] += 1
                        logger.exception("evacuate %s from %r errored: %s", label, group_name, e)
                        continue
                    if r.ok:
                        stats["devices_moved_to_default"] += 1
                        logger.info("evacuate %s from %r -> default group | Status: %d", label, group_name, r.status_code)
                    else:
                        stats["failures"] += 1
                        logger.error("evacuate %s from %r FAILED | Status: %d | Body: %s", label, group_name, r.status_code, r.text)
                try:
                    r = delete_server_group(group_id)
                except Exception as e:
                    stats["failures"] += 1
                    logger.exception("delete orphan group %r errored: %s", group_name, e)
                    continue
                if r.ok:
                    stats["orphan_groups_deleted"] += 1
                    logger.info("delete orphan group %r (id=%s) | Status: %d", group_name, group_id, r.status_code)
                else:
                    stats["failures"] += 1
                    logger.error("delete orphan group %r FAILED | Status: %d | Body: %s", group_name, r.status_code, r.text)

        for name, device_ids in final.items():
            sync_group(name, device_ids, group_name_to_id, fallback_group_id, all_servers)
    except Exception:
        logger.exception("Unhandled error in main()")
        stats["failures"] += 1

    logger.info("=== Summary: %s ===", stats)
    if stats["failures"] > 0:
        sys.exit(1)


if __name__ == "__main__":
    main()
