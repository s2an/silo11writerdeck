#!/usr/bin/env python3
"""
Bluetooth Auto-Pair, Trust & Connect Agent (silo11writerdeck)
- Registers with BlueZ as a NoInputNoOutput agent
- Automatically trusts and connects devices without manual input
- Optionally disables discoverability/pairability/scan after a successful connect
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import time

try:
    import dbus
    import dbus.service
    import dbus.mainloop.glib
    from gi.repository import GLib
except Exception as e:  # pragma: no cover (environmental)
    sys.stderr.write(f"[startup] Required DBus/GLib modules unavailable: {e}\n")
    sys.exit(1)

AGENT_PATH = "/test/agent"


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="BlueZ auto-pair, trust & connect agent (NoInputNoOutput)"
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print intended bluetoothctl commands without executing them",
    )
    parser.add_argument(
        "--log",
        default="/tmp/bt-autopair-trust-connect.log",
        help="Path to a log file (default: /tmp/bt-autopair-trust-connect.log)",
    )
    parser.add_argument(
        "--wait-retries",
        type=int,
        default=10,
        help="Max attempts to wait for adapter Powered: yes (default: 10)",
    )
    parser.add_argument(
        "--wait-delay",
        type=float,
        default=1.0,
        help="Delay (s) between wait attempts (default: 1.0)",
    )
    parser.add_argument(
        "--no-post-connect-knobs",
        action="store_true",
        help="Do NOT disable discoverable/pairable/scan after connect",
    )
    return parser.parse_args()


def have_bluetoothctl() -> bool:
    return shutil.which("bluetoothctl") is not None


class Agent(dbus.service.Object):
    def __init__(self, bus, path, *, dry_run: bool = False, logfile: str | None = None, knobs: bool = True):
        super().__init__(bus, path)
        self.dry_run = dry_run
        self.logfile = logfile
        self.post_connect_knobs = knobs  # controls discoverable/pairable/scan toggles

    # ---------- logging ----------
    def log(self, msg: str) -> None:
        ts = time.strftime("%Y-%m-%d %H:%M:%S")
        line = f"[{ts}] {msg}"
        print(line)
        if self.logfile:
            try:
                with open(self.logfile, "a") as f:
                    f.write(line + "\n")
            except Exception as e:
                print(f"[LOGGING ERROR] {e}")

    # ---------- helpers ----------
    def extract_mac(self, device_path: str) -> str | None:
        """
        /org/bluez/hci0/dev_XX_XX_XX_XX_XX_XX  ->  XX:XX:XX:XX:XX:XX
        Case-insensitive; underscores are converted to colons.
        """
        m = re.search(r"dev_([0-9a-fA-F_]+)$", device_path)
        if not m:
            return None
        return m.group(1).replace("_", ":").upper()

    def run_bt(self, *args: str) -> tuple[int, str]:
        """
        Run `bluetoothctl <args...>` with a short timeout.
        Logs the command and output. Ignores nonzero exits (returns code + output).
        Respects --dry-run.
        """
        cmd = ["bluetoothctl", *args]
        self.log(f"$ {' '.join(cmd)}")
        if self.dry_run:
            self.log("[DRY RUN] Skipping execution")
            return 0, ""

        try:
            cp = subprocess.run(
                cmd,
                check=False,
                timeout=5,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            out = cp.stdout or ""
            if out.strip():
                for line in out.strip().splitlines():
                    self.log(f"[btctl] {line}")
            return cp.returncode, out
        except subprocess.TimeoutExpired:
            self.log("[btctl] ERROR: command timed out")
            return 124, ""
        except Exception as e:
            self.log(f"[btctl] ERROR: {e}")
            return 1, ""

    # ---------- org.bluez.Agent1 methods ----------
    @dbus.service.method("org.bluez.Agent1", in_signature="", out_signature="")
    def Release(self):
        self.log("Agent released")

    @dbus.service.method("org.bluez.Agent1", in_signature="os", out_signature="")
    def AuthorizeService(self, device, uuid):
        self.log(f"AuthorizeService for {device}, uuid {uuid}")

    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="s")
    def RequestPinCode(self, device):
        self.log(f"RequestPinCode for {device} -> returning 0000")
        return "0000"

    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="u")
    def RequestPasskey(self, device):
        self.log(f"RequestPasskey for {device} -> returning 123456")
        return dbus.UInt32(123456)

    @dbus.service.method("org.bluez.Agent1", in_signature="os", out_signature="")
    def DisplayPasskey(self, device, passkey):
        self.log(f"DisplayPasskey: {device} {passkey}")

    @dbus.service.method("org.bluez.Agent1", in_signature="os", out_signature="")
    def RequestConfirmation(self, device, passkey):
        """
        Auto-confirm numeric comparison pairing.
        - Trusts and connects the device.
        - Writes last MAC to /tmp/last_bluetooth_mac.
        - Optionally turns off discoverable/pairable/scan on success.
        """
        self.log(f"Auto-confirming {device} with passkey {passkey}")
        mac = self.extract_mac(device)
        self.log(f"Extracted MAC: {mac or '<none>'}")

        if self.dry_run:
            self.log("[DRY RUN] Would trust/connect and apply post-connect knobs")
            return

        if not mac:
            self.log(f"[ERROR] Could not parse MAC from: {device}")
            return

        self.log(f"Trusting {mac}")
        rc_t, _ = self.run_bt("trust", mac)

        self.log(f"Connecting {mac}")
        rc_c, _ = self.run_bt("connect", mac)

        # Only apply “knobs” after a successful CONNECT
        if rc_c == 0 and self.post_connect_knobs:
            self.log("Connect OK -> turning discoverable/pairable/scan OFF")
            self.run_bt("discoverable", "off")
            self.run_bt("pairable", "off")
            self.run_bt("scan", "off")
        elif rc_c != 0:
            self.log("Connect failed -> skipping post-connect knobs")

        try:
            with open("/tmp/last_bluetooth_mac", "w") as f:
                f.write(mac + "\n")
        except Exception as e:
            self.log(f"[MAC LOGGING ERROR] {e}")

    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="")
    def RequestAuthorization(self, device):
        self.log(f"RequestAuthorization for {device}")

    @dbus.service.method("org.bluez.Agent1", in_signature="o", out_signature="")
    def Cancel(self, device):
        self.log(f"Cancel for {device}")


# ---------- startup helpers ----------
def wait_for_bluetooth_powered(log, retries: int = 10, delay: float = 1.0) -> bool:
    """
    Wait until `bluetoothctl show` reports 'Powered: yes'.
    This avoids registering the agent before bluetoothd is ready.
    """
    for i in range(1, retries + 1):
        try:
            cp = subprocess.run(
                ["bluetoothctl", "show"],
                check=False,
                timeout=5,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
            )
            if "Powered: yes" in (cp.stdout or ""):
                log("Bluetooth adapter is powered: OK")
                return True
        except subprocess.TimeoutExpired:
            pass
        log(f"Adapter not powered yet (attempt {i}/{retries}) — waiting {delay:.1f}s")
        time.sleep(delay)
    log("WARNING: never saw Powered: yes; continuing anyway")
    return False


def register_agent(*, dry_run: bool = False, logfile: str | None = None, knobs: bool = True,
                   wait_retries: int = 10, wait_delay: float = 1.0) -> Agent:
    if not have_bluetoothctl():
        sys.stderr.write("[startup] bluetoothctl not found in PATH\n")
        sys.exit(1)

    bus = dbus.SystemBus()
    agent = Agent(bus, AGENT_PATH, dry_run=dry_run, logfile=logfile, knobs=knobs)

    # Wait for bluetoothd and adapter power before registering
    if not dry_run:
        wait_for_bluetooth_powered(agent.log, retries=wait_retries, delay=wait_delay)

    manager = dbus.Interface(
        bus.get_object("org.bluez", "/org/bluez"),
        "org.bluez.AgentManager1",
    )

    # Use NoInputNoOutput to align with shell wrapper behavior
    manager.RegisterAgent(AGENT_PATH, "NoInputNoOutput")
    manager.RequestDefaultAgent(AGENT_PATH)
    agent.log("Agent registered (NoInputNoOutput) and running…")
    return agent


def main() -> None:
    args = parse_arguments()
    dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
    register_agent(
        dry_run=args.dry_run,
        logfile=args.log,
        knobs=not args.no_post_connect_knobs,
        wait_retries=args.wait_retries,
        wait_delay=args.wait_delay,
    )
    GLib.MainLoop().run()


if __name__ == "__main__":
    main()
