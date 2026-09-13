#!/usr/bin/env python3
"""
Minimal Cisco-IOS-like SSH server used to run the network_baseline
playbooks genuinely end-to-end - real SSH, real
ansible.netcommon network_cli connection plugin, real cisco.ios
cliconf/terminal plugins, real ansible.netcommon.cli_config module -
without needing a real device or reachable network.

This is NOT a general IOS emulator. It understands exactly the command
sequence those plugins issue against a real device:

  - terminal setup: `terminal length 0`, `terminal width 512`,
    `terminal width 0`
  - privilege escalation: `enable` -> `Password: ` -> `show privilege`
  - `show running-config`
  - `configure terminal` + one config line per push, `end`
  - the special banner push path: `banner <name> @` / content / `@`
    (ansible.netcommon's default multiline delimiter is "@", not the
    "^C" that appears in `show running-config` output - see
    cisco.ios's cliconf plugin `edit_banner()` vs `_extract_banners()`;
    real Cisco IOS has exactly this asymmetry, it is not a bug here)

Run standalone for manual testing:

    python3 mock_ios_ssh_server.py --port 8022

Or via the Makefile targets in the parent project (`make mock-start`,
`make e2e`, `make mock-stop`).
"""
import argparse
import asyncio
import os
import re
import sys

import asyncssh

# Config lines where a new value replaces any existing line with the same
# prefix (mirrors real IOS "singleton" settings). Everything else is
# treated as an additive/list-style line (e.g. "ntp server ...",
# "logging host ...", "snmp-server community ...").
SINGLETON_PREFIXES = (
    "ntp source ",
    "snmp-server location ",
    "snmp-server contact ",
    "logging trap ",
    "logging facility ",
    "logging buffered ",
    "logging source-interface ",
)

BANNER_RE = re.compile(r"^banner (\w+) \^C\n(.*?)\n\^C\s*$", re.M | re.S)


class MockDevice:
    def __init__(self, hostname, seed_path=None, state_file=None):
        self.hostname = hostname
        self.lines = []
        self.banners = {}
        # Written on every config change, in the same format as a seed
        # file, so a later process (e.g. a different CI job/VM, which
        # can't share this process's memory) can start a fresh server
        # from exactly the state this one ended up in - see
        # `_persist()`.
        self.state_file = state_file
        if seed_path and os.path.exists(seed_path):
            self._load_seed(seed_path)
        self._persist()

    def _load_seed(self, path):
        with open(path) as f:
            text = f.read()

        for match in BANNER_RE.finditer(text):
            self.banners["banner " + match.group(1)] = match.group(2).strip()
        text = BANNER_RE.sub("", text)

        for line in text.splitlines():
            line = line.strip()
            if not line or line in ("!", "end") or line.startswith("hostname "):
                continue
            self.lines.append(line)

    def apply_line(self, line):
        line = line.rstrip()
        if not line:
            return
        for prefix in SINGLETON_PREFIXES:
            if line.startswith(prefix):
                self.lines = [existing for existing in self.lines if not existing.startswith(prefix)]
                self.lines.append(line)
                self._persist()
                return
        if line not in self.lines:
            self.lines.append(line)
            self._persist()

    def set_banner(self, key, content):
        self.banners[key] = content.strip()
        self._persist()

    def _persist(self):
        if not self.state_file:
            return
        with open(self.state_file, "w") as f:
            f.write(self.running_config_text())

    def running_config_text(self):
        parts = [f"hostname {self.hostname}", "!"]
        for key, content in self.banners.items():
            # Real IOS always DISPLAYS banners delimited with ^C in
            # `show running-config`, regardless of how they were pushed.
            parts.append(f"{key} ^C")
            parts.append(content)
            parts.append("^C")
            parts.append("!")
        parts.extend(self.lines)
        parts.append("!")
        parts.append("end")
        return "\n".join(parts)


class IOSServerSession(asyncssh.SSHServerSession):
    def __init__(self, device, enable_password):
        self.device = device
        self.enable_password = enable_password
        self.chan = None
        self.buf = b""
        self.mode = "user"  # user -> exec -> config
        self.pending_enable = False
        self.banner_capture = None  # (key, [content lines]) while inside banner push

    def connection_made(self, chan):
        self.chan = chan

    def pty_requested(self, term_type, term_size, term_modes):
        return True

    def shell_requested(self):
        return True

    def session_started(self):
        self.chan.write(self._prompt())

    def _prompt(self):
        marker = {"user": ">", "exec": "#", "config": "(config)#"}[self.mode]
        return f"\r\n{self.device.hostname}{marker}"

    def data_received(self, data, datatype):
        if isinstance(data, str):
            data = data.encode()
        self.buf += data
        while b"\n" in self.buf:
            raw, self.buf = self.buf.split(b"\n", 1)
            self._handle_line(raw.decode(errors="ignore").rstrip("\r"))

    def eof_received(self):
        return False

    def _handle_line(self, line):
        if self.pending_enable:
            self.pending_enable = False
            if line == self.enable_password:
                self.mode = "exec"
            else:
                self.chan.write("\r\n% Bad secret")
            self.chan.write(self._prompt())
            return

        if self.banner_capture is not None:
            key, content = self.banner_capture
            if line.strip() == "@":
                self.device.set_banner(key, "\n".join(content))
                self.banner_capture = None
            else:
                content.append(line)
            return

        self._dispatch(line.strip())

    def _dispatch(self, cmd):
        if cmd == "":
            self.chan.write(self._prompt())
            return

        if cmd in ("terminal length 0", "terminal width 512", "terminal width 0"):
            self.chan.write(self._prompt())
            return

        if cmd == "show privilege":
            level = 15 if self.mode in ("exec", "config") else 1
            self.chan.write(f"\r\nCurrent privilege level is {level}")
            self.chan.write(self._prompt())
            return

        if cmd == "enable":
            if self.mode == "user":
                self.chan.write("\r\nPassword: ")
                self.pending_enable = True
            else:
                self.chan.write(self._prompt())
            return

        if cmd == "disable":
            self.mode = "user"
            self.chan.write(self._prompt())
            return

        if cmd == "show version":
            # Just enough for cisco.ios's get_device_info()/get_capabilities()
            # (called automatically by ansible.netcommon modules) to parse
            # without raising - the regexes there are all optional-match.
            self.chan.write(
                "\r\nCisco IOS XE Software, Version 17.03.04a"
                "\r\nCisco IOS Software [Amsterdam], Version 17.3.4a"
                f"\r\n{self.device.hostname} uptime is 1 day, 0 hours, 0 minutes"
                '\r\nRunning default software, image file is "flash:mock-ios-xe.bin"'
                "\r\ncisco C8000V (VXE) processor with 1024K bytes of memory."
            )
            self.chan.write(self._prompt())
            return

        if cmd == "show vlan":
            self.chan.write("\r\n% Invalid input detected")
            self.chan.write(self._prompt())
            return

        if cmd == "show running-config":
            self.chan.write("\r\nBuilding configuration...\r\n\r\n" + self.device.running_config_text())
            self.chan.write(self._prompt())
            return

        if cmd in ("configure terminal", "config terminal"):
            self.mode = "config"
            self.chan.write("\r\nEnter configuration commands, one per line.  End with CNTL/Z.")
            self.chan.write(self._prompt())
            return

        if cmd == "end":
            self.mode = "exec"
            self.chan.write(self._prompt())
            return

        if cmd == "write memory":
            self.chan.write("\r\nBuilding configuration...\r\n[OK]")
            self.chan.write(self._prompt())
            return

        if cmd in ("exit", "quit"):
            self.chan.write("\r\n")
            self.chan.exit(0)
            return

        banner_start = re.match(r"^banner (\w+) @$", cmd)
        if banner_start and self.mode == "config":
            self.banner_capture = (f"banner {banner_start.group(1)}", [])
            return

        if self.mode == "config":
            self.device.apply_line(cmd)
            self.chan.write(self._prompt())
            return

        self.chan.write("\r\n% Invalid input detected")
        self.chan.write(self._prompt())


class IOSServer(asyncssh.SSHServer):
    def __init__(self, device, username, password, enable_password):
        self.device = device
        self.username = username
        self.password = password
        self.enable_password = enable_password

    def begin_auth(self, username):
        return True

    def password_auth_supported(self):
        return True

    def validate_password(self, username, password):
        return username == self.username and password == self.password

    def session_requested(self):
        return IOSServerSession(self.device, self.enable_password)


async def main_async(args):
    device = MockDevice(args.hostname, args.seed, args.state_file)

    def server_factory():
        return IOSServer(device, args.username, args.password, args.enable_password)

    await asyncssh.create_server(
        server_factory,
        host="127.0.0.1",
        port=args.port,
        server_host_keys=[asyncssh.generate_private_key("ssh-rsa")],
    )
    print(f"mock-ios-ssh listening on 127.0.0.1:{args.port}", flush=True)
    if args.ready_file:
        with open(args.ready_file, "w") as f:
            f.write("ready\n")
    await asyncio.Event().wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8022)
    parser.add_argument("--hostname", default="mock-sw01")
    parser.add_argument("--username", default=os.environ.get("MOCK_IOS_USER", "netops"))
    parser.add_argument("--password", default=os.environ.get("MOCK_IOS_PASSWORD", "C1sco12345"))
    parser.add_argument(
        "--enable-password",
        default=os.environ.get("MOCK_IOS_ENABLE_PASSWORD", "C1sco12345enable"),
    )
    parser.add_argument("--seed", default=None, help="path to a seed show-running-config text file")
    parser.add_argument(
        "--state-file",
        default=None,
        help="path to continuously write the device's current config to (same format as --seed, "
        "so a later process/CI job can start a fresh server from exactly this one's ending state)",
    )
    parser.add_argument("--ready-file", default=None, help="written once the server is listening")
    args = parser.parse_args()

    try:
        asyncio.run(main_async(args))
    except (OSError, asyncssh.Error) as exc:
        sys.exit(f"error starting mock IOS SSH server: {exc}")


if __name__ == "__main__":
    main()
