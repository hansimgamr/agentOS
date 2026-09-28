"""Show a five-minute QR code for pairing, or list and revoke phones."""

import argparse
import subprocess
from pathlib import Path

import credentials


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("show", "list", "revoke"))
    parser.add_argument("device_id", nargs="?")
    args = parser.parse_args()
    if args.action == "show":
        code = credentials.create_pairing()
        image = credentials.PRIVATE / "pair.png"
        url = "hermespocket://pair?code=" + code
        subprocess.run(["swift", str(Path(__file__).with_name("qr.swift")), url, str(image)], check=True)
        image.chmod(0o600)
        subprocess.run(["open", str(image)], check=True)
        print("Scan the QR code with iPhone Camera within five minutes. It opens Hermes Pocket and pairs this device.")
    elif args.action == "list":
        for device in credentials.list_devices():
            print(device["id"], device["name"])
    else:
        if not args.device_id:
            parser.error("revoke requires a device ID from the list action")
        if not credentials.revoke(args.device_id):
            parser.error("device ID not found")
        print("Device access revoked.")


if __name__ == "__main__":
    main()
