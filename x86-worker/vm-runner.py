#!/usr/bin/env python3
import base64
import json
import os
import shutil
import subprocess
import sys
import textwrap
from pathlib import Path
from urllib.request import urlopen


VM_IMAGES = {
    "ubuntu-24.04": {
        "url": "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img",
        "user": "ubuntu",
    },
    "debian-12": {
        "url": "https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2",
        "user": "debian",
    },
}


def env_int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, str(default)))
    except ValueError:
        return default


def write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)


def run(*cmd: str) -> None:
    subprocess.run(cmd, check=True)


def download(url: str, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with urlopen(url) as resp, path.open("wb") as out:
        shutil.copyfileobj(resp, out)


def main() -> int:
    image_name = os.environ.get("VM_IMAGE_NAME", "ubuntu-24.04")
    if image_name not in VM_IMAGES:
        raise SystemExit(f"unsupported VM image: {image_name}")
    image_meta = VM_IMAGES[image_name]
    image_url = os.environ.get("VM_IMAGE_URL", image_meta["url"])
    guest_user = os.environ.get("VM_GUEST_USER", image_meta["user"])
    script_b64 = os.environ.get("VM_SCRIPT_B64", "")
    if not script_b64:
        raise SystemExit("VM_SCRIPT_B64 is required")

    script = base64.b64decode(script_b64).decode("utf-8")
    timeout_seconds = env_int("VM_TIMEOUT_SECONDS", 900)
    memory_mib = env_int("VM_MEMORY_MIB", 2048)
    vcpus = env_int("VM_VCPUS", 2)
    cache_dir = Path(os.environ.get("VM_CACHE_DIR", "/cache"))
    work_dir = Path(os.environ.get("VM_WORK_DIR", "/workspace/vm"))
    work_dir.mkdir(parents=True, exist_ok=True)
    cache_dir.mkdir(parents=True, exist_ok=True)

    base_image = cache_dir / f"{image_name}.qcow2"
    overlay_image = work_dir / "overlay.qcow2"
    seed_iso = work_dir / "seed.iso"
    user_data = work_dir / "user-data"
    meta_data = work_dir / "meta-data"

    if not base_image.exists():
        print(f"downloading base image {image_url}", flush=True)
        download(image_url, base_image)

    if overlay_image.exists():
        overlay_image.unlink()
    run(
        "qemu-img",
        "create",
        "-f",
        "qcow2",
        "-F",
        "qcow2",
        "-b",
        str(base_image),
        str(overlay_image),
    )

    wrapped_script = textwrap.indent(script.strip(), "      ")
    write(
        user_data,
        textwrap.dedent(
            f"""\
            #cloud-config
            users:
              - default
            ssh_pwauth: false
            disable_root: true
            output:
              all: '| tee -a /dev/ttyS0'
            write_files:
              - path: /opt/openclaw/run.sh
                permissions: '0755'
                content: |
                  #!/bin/bash
                  set -euo pipefail
                  exec > >(tee -a /dev/ttyS0) 2>&1
                  echo OPENCLAW_VM_START
            {wrapped_script}
                  status=$?
                  echo OPENCLAW_VM_EXIT=$status
                  sync || true
                  poweroff -f || shutdown -h now || true
            runcmd:
              - [ bash, /opt/openclaw/run.sh ]
            final_message: "openclaw-vm cloud-init finished"
            """
        ),
    )
    write(
        meta_data,
        textwrap.dedent(
            f"""\
            instance-id: openclaw-vm
            local-hostname: openclaw-vm
            """
        ),
    )

    run(
        "genisoimage",
        "-quiet",
        "-output",
        str(seed_iso),
        "-volid",
        "cidata",
        "-joliet",
        "-rock",
        str(user_data),
        str(meta_data),
    )

    qemu_cmd = [
        "timeout",
        str(timeout_seconds),
        "qemu-system-x86_64",
        "-machine",
        "q35,accel=tcg",
        "-cpu",
        "max",
        "-m",
        str(memory_mib),
        "-smp",
        str(vcpus),
        "-display",
        "none",
        "-monitor",
        "none",
        "-serial",
        "stdio",
        "-no-reboot",
        "-drive",
        f"if=virtio,format=qcow2,file={overlay_image}",
        "-drive",
        f"if=virtio,format=raw,file={seed_iso},readonly=on",
        "-nic",
        "user,model=virtio-net-pci",
    ]

    print(
        json.dumps(
            {
                "image": image_name,
                "guestUser": guest_user,
                "timeoutSeconds": timeout_seconds,
                "memoryMiB": memory_mib,
                "vcpus": vcpus,
            }
        ),
        flush=True,
    )
    completed = subprocess.run(qemu_cmd)
    return completed.returncode


if __name__ == "__main__":
    raise SystemExit(main())
