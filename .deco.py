#!/usr/bin/env python3
# /// script
# requires-python = ">=3.11"
# dependencies = ["tplinkrouterc6u", "pyobjc-framework-CoreWLAN"]
# ///
"""Helper for deco.30s.sh: which TP-Link Deco node is this Mac associated with?

macOS hides the BSSID from any process without Location Services, so the Mac
cannot tell on its own which Deco it is talking to. The Deco controller knows,
but only per node: the global client list reports every client's access_host as
"1", so the node has to be found by asking each node for its own clients.

Logging in to the Deco is slow (RSA handshake, ~2s) and the controller allows a
single admin session, which also kicks Home Assistant's tplink_router poller.
So the answer is cached and only re-asked when the local radio fingerprint
changes (band, channel, or a large RSSI jump, i.e. a roam), when the cache is
older than CACHE_TTL, or when the user clicks Refresh. Everything shown about
the radio itself comes from CoreWLAN every tick and costs nothing.

The admin password is read from the login keychain:
  security add-generic-password -s deco -a admin -w

Site-specific values (hardcoded for one home network; edit for another):
  HOST        controller address, http://10.0.0.1 (also the ping target)
  NODE_ICONS  Deco nicknames as set in the Deco app -> menu bar SF Symbol
  keychain    service "deco", account "admin"
  en0         Wi-Fi interface toggled by Re-join (deco.30s.sh)
"""
import base64
import json
import os
import re
import signal
import subprocess
import sys
import time

HOST = "http://10.0.0.1"
CACHE_TTL = 300          # seconds before the node answer is re-asked
RSSI_JUMP = 12           # dB change treated as a probable roam
REQ_TIMEOUT = 6          # per HTTP request to the Deco
HARD_DEADLINE = 25       # whole helper, so a wedged Deco can never pile up runs
PING_COUNT = 5
PLUGIN = os.environ.get("DECO_PLUGIN", "")

CACHE_DIR = os.path.join(os.environ.get("TMPDIR", "/tmp"), f"xbar-deco.{os.getuid()}")
STATE = os.path.join(CACHE_DIR, "state.json")

BANDS = {1: "2.4", 2: "5", 3: "6"}
WIDTHS = {1: 20, 2: 40, 3: 80, 4: 160}
# Menu bar SF Symbol per Deco nickname; anything else falls back to "wifi".
NODE_ICONS = {"Main": "cable.connector", "Upstairs": "arrow.up", "Downstairs": "arrow.down"}


def radio():
    import CoreWLAN
    i = CoreWLAN.CWWiFiClient.sharedWiFiClient().interface()
    if i is None or not i.powerOn():
        return None
    ch = i.wlanChannel()
    if ch is None:
        return {"mac": (i.hardwareAddress() or "").upper().replace(":", "-"), "associated": False}
    return {
        "mac": (i.hardwareAddress() or "").upper().replace(":", "-"),
        "associated": True,
        "rssi": i.rssiValue(),
        "noise": i.noiseMeasurement(),
        "rate": i.transmitRate(),
        "channel": ch.channelNumber(),
        "band": BANDS.get(ch.channelBand(), "?"),
        "width": WIDTHS.get(ch.channelWidth(), 0),
    }


def gateway_ping():
    try:
        out = subprocess.run(
            ["/sbin/ping", "-c", str(PING_COUNT), "-i", "0.2", "-t", "3", "-q", HOST.split("//")[-1]],
            capture_output=True, text=True, timeout=5,
        ).stdout
    except Exception:
        return None
    for line in out.splitlines():
        if "min/avg/max" in line:
            mn, avg, mx, sd = line.split("=")[1].strip().split()[0].split("/")
            loss = next((l for l in out.splitlines() if "packet loss" in l), "")
            lost = loss.split(",")[2].strip().split("%")[0] if loss else "0"
            return {"avg": float(avg), "max": float(mx), "sd": float(sd), "loss": float(lost)}
    return {"avg": None, "loss": 100.0}


def password():
    try:
        return subprocess.run(
            ["/usr/bin/security", "find-generic-password", "-s", "deco", "-a", "admin", "-w"],
            capture_output=True, text=True, timeout=5, check=True,
        ).stdout.strip()
    except Exception:
        return None


def b64name(n):
    raw = n.get("custom_nickname")
    if raw:
        try:
            return base64.b64decode(raw).decode()
        except Exception:
            pass
    return n.get("nickname") or n.get("mac", "?")


def backhaul(n):
    # signal_level values are 0-3 per band; the master has none (it is the root).
    # Prefer the 5/6 GHz levels: that is the backhaul radio, and the 2.4 GHz
    # level reads better than the link actually carrying traffic.
    sl = n.get("signal_level") or {}
    lv = [int(v) for k, v in sl.items() if k != "band2_4" and str(v).isdigit() and int(v) > 0]
    lv = lv or [int(v) for v in sl.values() if str(v).isdigit()]
    return max(lv) if lv and n.get("role") != "master" else None


def identity(r):
    """Every address the Deco might list this Mac under.

    With Private Wi-Fi Address on, the Mac associates with a per-network
    random MAC, not the hardware one CoreWLAN reports; ifconfig shows the one
    actually in use. The IPv4 address is a last resort if both miss.
    """
    # CoreWLAN returns the placeholder 02:00:00:00:00:00 when macOS withholds
    # the address (no Location Services), so it cannot be the only key.
    macs, ip = {r["mac"]} - {"02-00-00-00-00-00", ""}, None
    try:
        out = subprocess.run(["/sbin/ifconfig", "en0"], capture_output=True, text=True, timeout=3).stdout
        for line in out.splitlines():
            parts = line.split()
            if parts[:1] == ["ether"]:
                macs.add(parts[1].upper().replace(":", "-"))
            elif parts[:1] == ["inet"]:
                ip = parts[1]
    except Exception:
        pass
    return macs, ip


def query_deco(me_ids, hint):
    """Return (nodes, current_node_mac, deco_band) from the controller."""
    from tplinkrouterc6u.client.deco import TPLinkDecoClient
    pw = password()
    if not pw:
        raise RuntimeError("no Deco password in keychain (service 'deco')")
    c = TPLinkDecoClient(HOST, pw, timeout=REQ_TIMEOUT)
    c.authorize()
    try:
        # Plain request() rather than the client's private helpers, which come
        # and go between library releases.
        raw = c.request("admin/device?form=device_list",
                        json.dumps({"operation": "read"})).get("device_list", [])
        nodes = [{
            "mac": n["mac"],
            "name": b64name(n),
            "model": n.get("device_model", ""),
            "ip": n.get("device_ip", ""),
            "role": n.get("role", ""),
            "online": n.get("group_status") == "connected" and n.get("inet_status") == "online",
            "backhaul": backhaul(n),
        } for n in raw]
        # Ask the last known node first: almost every refresh ends after one call.
        # A node that does not answer is skipped so it cannot hide the answer
        # from the others, then retried once at the end: satellites sometimes
        # time out a request and answer the next one fine.
        order = sorted(nodes, key=lambda n: n["mac"] != hint)
        failed = []
        for retry in (False, True):
            for n in (list(failed) if retry else order):
                try:
                    cl = c.request("admin/client?form=client_list", json.dumps(
                        {"operation": "read", "params": {"device_mac": n["mac"]}})).get("client_list", [])
                except Exception:
                    if not retry:
                        failed.append(n)
                    continue
                if retry:
                    failed.remove(n)
                n["clients"] = len(cl)
                macs, ip = me_ids
                me = next((x for x in cl if x.get("mac") in macs), None) \
                    or next((x for x in cl if ip and x.get("ip") == ip), None)
                if me:
                    return nodes, n["mac"], me.get("connection_type", "")
        if failed:
            raise RuntimeError(f"not found; no answer from {', '.join(n['name'] for n in failed)}")
        return nodes, None, ""
    finally:
        try:
            c.logout()
        except Exception:
            pass


def load_state():
    try:
        with open(STATE) as f:
            return json.load(f)
    except Exception:
        return {}


def save_state(s):
    os.makedirs(CACHE_DIR, exist_ok=True)
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(s, f)
    os.replace(tmp, STATE)


def roamed(r, fp):
    if not fp or not r.get("associated"):
        return True
    return (r["band"] != fp.get("band") or r["channel"] != fp.get("channel")
            or abs(r["rssi"] - fp.get("rssi", r["rssi"])) >= RSSI_JUMP)


def ago(ts):
    d = int(time.time() - ts)
    return f"{d}s ago" if d < 90 else f"{d // 60}m ago"


def bars(level):
    return {0: "▁___", 1: "▁▃__", 2: "▁▃▅_", 3: "▁▃▅▇"}.get(level, "")


def main():
    signal.alarm(HARD_DEADLINE)
    force = "--refresh" in sys.argv
    r = radio()
    if r is None:
        print(" | sfimage=wifi.slash template=true")
        print("---")
        print("Wi-Fi is off")
        return
    if not r.get("associated"):
        print(" | sfimage=wifi.exclamationmark template=true")
        print("---")
        print("Not associated with any network")
        return

    s = load_state()
    err = None
    stale = time.time() - s.get("checked", 0) > CACHE_TTL
    # After a rejected password, only a manual Refresh tries again: the Deco
    # counts failed logins and locks the admin account (Home Assistant's
    # included) once they run out, so the bad password must not be replayed.
    due = stale or roamed(r, s.get("fp"))
    if force or (due and not s.get("auth_failed")):
        try:
            nodes, cur, dband = query_deco(identity(r), s.get("current"))
            s = {"nodes": nodes, "current": cur, "deco_band": dband, "checked": time.time(),
                 "fp": {k: r[k] for k in ("band", "channel", "rssi")}}
            save_state(s)
        except Exception as e:
            msg = str(e)
            err = msg.splitlines()[0][:120] if msg else type(e).__name__
            s["auth_failed"] = "Cannot authorize" in msg
            if s["auth_failed"]:
                left = re.search(r"attemptsAllowed'?\"?:\s*'?(\d+)", msg)
                err = ("Deco rejected the password in keychain item 'deco'"
                       + (f" ({left.group(1)} attempts left)" if left else "")
                       + "; fix it, then Refresh now")
            # Keep showing the last answer, but do not hammer a broken controller
            # every 30s: count the failure as a check.
            s["checked"] = time.time()
            s.setdefault("fp", {k: r[k] for k in ("band", "channel", "rssi")})
            s["error"] = err
            save_state(s)

    ping = gateway_ping()
    nodes = s.get("nodes", [])
    cur = next((n for n in nodes if n["mac"] == s.get("current")), None)
    name = cur["name"] if cur else "?"

    # 2.4 GHz alone is not a fault: the home Mac is pinned to 2.4 in the Deco
    # app, because on 5 GHz the firmware locks it to the farther Main node.
    weak = r["rssi"] < -70
    jittery = ping and ping.get("avg") is not None and (ping["sd"] > 20 or ping["loss"] > 0)
    # Icon only: the node's role, tinted orange when the link is bad
    # (weak signal or a jittery gateway) and theme-adaptive otherwise.
    # An unknown node gets a warning symbol, not plain "wifi": that one is
    # indistinguishable from macOS's own Wi-Fi menu extra.
    icon = NODE_ICONS.get(name, "wifi.exclamationmark")
    tint = " sfcolor=#e67e22" if weak or jittery else " template=true"
    print(f" | sfimage={icon}{tint}")
    print("---")

    print(f"Connected to: {name}" + (f" ({cur['model']}, {cur['ip']})" if cur else ""))
    if nodes and not cur and not s.get("error"):
        print("This Mac is not in any Deco's client list | color=#e67e22")
    print(f"Band: {r['band']} GHz · ch {r['channel']} · {r['width']} MHz")
    snr = r["rssi"] - r["noise"]
    print(f"Signal: {r['rssi']} dBm · SNR {snr} dB")
    print(f"Tx rate: {r['rate']:.0f} Mbps")
    if ping and ping.get("avg") is not None:
        print(f"Gateway ping: {ping['avg']:.0f} ± {ping['sd']:.0f} ms (max {ping['max']:.0f})"
              + (f" · {ping['loss']:.0f}% loss" if ping["loss"] else "")
              + (" | color=#e67e22" if jittery else ""))
    elif ping:
        print("Gateway ping: no reply | color=red")

    if nodes:
        print("---")
        print("Decos")
        for n in sorted(nodes, key=lambda n: (n["role"] != "master", n["name"])):
            mark = "✓ " if cur and n["mac"] == cur["mac"] else "    "
            bits = [n["model"], n["ip"]]
            if n["backhaul"] is not None:
                bits.append(f"backhaul {bars(n['backhaul'])}")
            if "clients" in n:
                bits.append(f"{n['clients']} clients")
            dot = "" if n["online"] else " | color=red"
            print(f"{mark}{n['name']}  —  {' · '.join(b for b in bits if b)}{dot}")

    print("---")
    if s.get("error"):
        print(f"Deco query failed: {s['error']} | color=red")
    if s.get("checked"):
        print(f"Node checked {ago(s['checked'])}")
    print(f"Re-join Wi-Fi | bash=\"{PLUGIN}\" param1=rejoin terminal=false refresh=true")
    print(f"Refresh now | bash=\"{PLUGIN}\" param1=refresh terminal=false refresh=true")


if __name__ == "__main__":
    main()
