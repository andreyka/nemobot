#!/usr/bin/env python3
import base64
import json
import os
import random
import re
import string
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from kubernetes import client, config
from kubernetes.client.exceptions import ApiException


LISTEN_HOST = os.environ.get("LISTEN_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8090"))
LAB_NAMESPACE = os.environ.get("LAB_NAMESPACE", "openshell-lab")
LAB_APP_LABEL = os.environ.get("LAB_APP_LABEL", "openclaw-lab")
MAX_TIMEOUT_SECONDS = int(os.environ.get("MAX_TIMEOUT_SECONDS", "1800"))
DEFAULT_TIMEOUT_SECONDS = int(os.environ.get("DEFAULT_TIMEOUT_SECONDS", "900"))
VM_RUNNER_IMAGE = os.environ.get("VM_RUNNER_IMAGE", "openclaw-vm-runner:local")
MAX_VM_MEMORY_MIB = int(os.environ.get("MAX_VM_MEMORY_MIB", "4096"))
MAX_VM_VCPUS = int(os.environ.get("MAX_VM_VCPUS", "4"))

PROFILES = {
    "debian": {
        "image": "debian:12-slim",
        "requests": {"cpu": "250m", "memory": "256Mi"},
        "limits": {"cpu": "1000m", "memory": "1Gi"},
    },
    "ubuntu": {
        "image": "ubuntu:24.04",
        "requests": {"cpu": "250m", "memory": "256Mi"},
        "limits": {"cpu": "1000m", "memory": "1Gi"},
    },
    "python": {
        "image": "python:3.12-slim",
        "requests": {"cpu": "250m", "memory": "256Mi"},
        "limits": {"cpu": "1000m", "memory": "1Gi"},
    },
    "golang": {
        "image": "golang:1.24-bookworm",
        "requests": {"cpu": "500m", "memory": "512Mi"},
        "limits": {"cpu": "2000m", "memory": "2Gi"},
    },
    "rust": {
        "image": "rust:1.88-bookworm",
        "requests": {"cpu": "500m", "memory": "512Mi"},
        "limits": {"cpu": "2000m", "memory": "2Gi"},
    },
}

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

config.load_incluster_config()
batch = client.BatchV1Api()
core = client.CoreV1Api()


def sanitize_name(raw: str) -> str:
    text = raw.strip().lower()
    text = re.sub(r"[^a-z0-9-]+", "-", text)
    text = re.sub(r"-+", "-", text).strip("-")
    if not text:
        text = "job"
    return text[:32]


def rand_suffix(n: int = 6) -> str:
    return "".join(random.choice(string.ascii_lowercase + string.digits) for _ in range(n))


def resource(cpu_request: str, cpu_limit: str, mem_request: str, mem_limit: str):
    return client.V1ResourceRequirements(
        requests={"cpu": cpu_request, "memory": mem_request},
        limits={"cpu": cpu_limit, "memory": mem_limit},
    )


def list_jobs(kind: str | None = None):
    selector = f"app={LAB_APP_LABEL}"
    if kind:
        selector = f"{selector},kind={kind}"
    jobs = batch.list_namespaced_job(
        LAB_NAMESPACE,
        label_selector=selector,
    ).items
    rows = []
    for job in jobs:
        status = job.status
        labels = job.metadata.labels or {}
        rows.append(
            {
                "name": job.metadata.name,
                "kind": labels.get("kind", "container"),
                "profile": labels.get("profile"),
                "imageName": labels.get("imageName"),
                "succeeded": status.succeeded or 0,
                "failed": status.failed or 0,
                "active": status.active or 0,
                "createdAt": job.metadata.creation_timestamp.isoformat() if job.metadata.creation_timestamp else None,
            }
        )
    rows.sort(key=lambda row: row["createdAt"] or "", reverse=True)
    return rows


def job_logs(name: str) -> str:
    pods = core.list_namespaced_pod(
        LAB_NAMESPACE,
        label_selector=f"job-name={name}",
    ).items
    if not pods:
        raise FileNotFoundError(f"no pod found for job {name}")
    pod_name = pods[0].metadata.name
    return core.read_namespaced_pod_log(
        name=pod_name,
        namespace=LAB_NAMESPACE,
        timestamps=True,
        tail_lines=500,
    )


def create_job(
    *,
    kind: str,
    profile_name: str,
    name_hint: str,
    timeout_seconds: int,
    image: str,
    command: list[str],
    resources: client.V1ResourceRequirements,
    env: list[client.V1EnvVar] | None = None,
    volume_mounts: list[client.V1VolumeMount] | None = None,
    volumes: list[client.V1Volume] | None = None,
):
    timeout_seconds = max(60, min(timeout_seconds, MAX_TIMEOUT_SECONDS))
    base_name = sanitize_name(name_hint or profile_name)
    prefix = "vm" if kind == "vm" else "lab"
    job_name = f"{prefix}-{base_name}-{rand_suffix()}"

    job = client.V1Job(
        metadata=client.V1ObjectMeta(
            name=job_name,
            namespace=LAB_NAMESPACE,
            labels={
                "app": LAB_APP_LABEL,
                "managed-by": "openclaw-lab-control",
                "kind": kind,
                "profile": profile_name,
                "imageName": profile_name,
            },
        ),
        spec=client.V1JobSpec(
            ttl_seconds_after_finished=3600,
            backoff_limit=0,
            active_deadline_seconds=timeout_seconds,
            template=client.V1PodTemplateSpec(
                metadata=client.V1ObjectMeta(
                    labels={
                        "app": LAB_APP_LABEL,
                        "kind": kind,
                        "profile": profile_name,
                    }
                ),
                spec=client.V1PodSpec(
                    automount_service_account_token=False,
                    restart_policy="Never",
                    security_context=client.V1PodSecurityContext(
                        seccomp_profile=client.V1SeccompProfile(type="RuntimeDefault")
                    ),
                    containers=[
                        client.V1Container(
                            name="runner",
                            image=image,
                            command=command,
                            working_dir="/workspace",
                            env=env or [],
                            resources=resources,
                            security_context=client.V1SecurityContext(
                                allow_privilege_escalation=False,
                                capabilities=client.V1Capabilities(drop=["ALL"]),
                            ),
                            volume_mounts=volume_mounts or [],
                        )
                    ],
                    volumes=volumes or [],
                ),
            ),
        ),
    )
    batch.create_namespaced_job(namespace=LAB_NAMESPACE, body=job)
    return {
        "ok": True,
        "name": job_name,
        "kind": kind,
        "profile": profile_name,
        "timeoutSeconds": timeout_seconds,
        "image": image,
    }


def create_container_job(profile_name: str, name_hint: str, command: str, timeout_seconds: int):
    if profile_name not in PROFILES:
        raise ValueError(f"unknown profile: {profile_name}")
    if not command.strip():
        raise ValueError("missing cmd")

    profile = PROFILES[profile_name]
    return create_job(
        kind="container",
        profile_name=profile_name,
        name_hint=name_hint,
        timeout_seconds=timeout_seconds,
        image=profile["image"],
        command=["/bin/sh", "-lc", command],
        resources=client.V1ResourceRequirements(
            requests=profile["requests"],
            limits=profile["limits"],
        ),
        volume_mounts=[
            client.V1VolumeMount(name="workspace", mount_path="/workspace"),
            client.V1VolumeMount(name="tmp", mount_path="/tmp"),
        ],
        volumes=[
            client.V1Volume(name="workspace", empty_dir=client.V1EmptyDirVolumeSource()),
            client.V1Volume(name="tmp", empty_dir=client.V1EmptyDirVolumeSource()),
        ],
    )


def create_vm_job(image_name: str, name_hint: str, script: str, timeout_seconds: int, memory_mib: int, vcpus: int):
    if image_name not in VM_IMAGES:
        raise ValueError(f"unknown VM image: {image_name}")
    if not script.strip():
        raise ValueError("missing script")

    memory_mib = max(1024, min(memory_mib, MAX_VM_MEMORY_MIB))
    vcpus = max(1, min(vcpus, MAX_VM_VCPUS))
    image_meta = VM_IMAGES[image_name]
    script_b64 = base64.b64encode(script.encode("utf-8")).decode("ascii")
    cpu_request = f"{max(500, min(vcpus * 500, vcpus * 1000))}m"
    cpu_limit = str(vcpus)
    mem_request = f"{max(1024, memory_mib)}Mi"
    mem_limit = f"{memory_mib + 512}Mi"

    return create_job(
        kind="vm",
        profile_name=image_name,
        name_hint=name_hint,
        timeout_seconds=timeout_seconds,
        image=VM_RUNNER_IMAGE,
        command=["python3", "/opt/openclaw/vm-runner.py"],
        resources=resource(cpu_request, cpu_limit, mem_request, mem_limit),
        env=[
            client.V1EnvVar(name="VM_IMAGE_NAME", value=image_name),
            client.V1EnvVar(name="VM_IMAGE_URL", value=image_meta["url"]),
            client.V1EnvVar(name="VM_GUEST_USER", value=image_meta["user"]),
            client.V1EnvVar(name="VM_SCRIPT_B64", value=script_b64),
            client.V1EnvVar(name="VM_TIMEOUT_SECONDS", value=str(timeout_seconds)),
            client.V1EnvVar(name="VM_MEMORY_MIB", value=str(memory_mib)),
            client.V1EnvVar(name="VM_VCPUS", value=str(vcpus)),
        ],
        volume_mounts=[
            client.V1VolumeMount(name="workspace", mount_path="/workspace"),
            client.V1VolumeMount(name="tmp", mount_path="/tmp"),
            client.V1VolumeMount(name="cache", mount_path="/cache"),
        ],
        volumes=[
            client.V1Volume(name="workspace", empty_dir=client.V1EmptyDirVolumeSource()),
            client.V1Volume(name="tmp", empty_dir=client.V1EmptyDirVolumeSource()),
            client.V1Volume(name="cache", empty_dir=client.V1EmptyDirVolumeSource()),
        ],
    )


def delete_job(name: str):
    batch.delete_namespaced_job(
        name=name,
        namespace=LAB_NAMESPACE,
        propagation_policy="Background",
    )
    return {"ok": True, "deleted": name}


class Handler(BaseHTTPRequestHandler):
    server_version = "openclaw-lab-control/1.1"

    def do_GET(self):
        parsed = urlparse(self.path)
        params = parse_qs(parsed.query, keep_blank_values=False)
        try:
            if parsed.path == "/healthz":
                self._json(
                    200,
                    {
                        "ok": True,
                        "namespace": LAB_NAMESPACE,
                        "profiles": sorted(PROFILES),
                        "vmImages": sorted(VM_IMAGES),
                    },
                )
                return
            if parsed.path == "/profiles":
                self._json(200, {"profiles": PROFILES})
                return
            if parsed.path == "/vm/images":
                self._json(200, {"images": VM_IMAGES})
                return
            if parsed.path == "/jobs":
                kind = (params.get("kind") or [""])[0].strip() or None
                self._json(200, {"jobs": list_jobs(kind=kind)})
                return
            if parsed.path == "/vm/jobs":
                self._json(200, {"jobs": list_jobs(kind="vm")})
                return
            if parsed.path == "/logs":
                name = (params.get("name") or [""])[0].strip()
                if not name:
                    self._json(400, {"ok": False, "error": "missing name"})
                    return
                self._text(200, job_logs(name))
                return
            if parsed.path == "/delete":
                name = (params.get("name") or [""])[0].strip()
                if not name:
                    self._json(400, {"ok": False, "error": "missing name"})
                    return
                self._json(200, delete_job(name))
                return
            if parsed.path == "/run":
                profile_name = (params.get("profile") or ["debian"])[0].strip()
                name_hint = (params.get("name") or [profile_name])[0]
                command = (params.get("cmd") or [""])[0]
                timeout_seconds = int((params.get("timeout") or [str(DEFAULT_TIMEOUT_SECONDS)])[0])
                self._json(200, create_container_job(profile_name, name_hint, command, timeout_seconds))
                return
            if parsed.path == "/vm/run":
                image_name = (params.get("image") or ["ubuntu-24.04"])[0].strip()
                name_hint = (params.get("name") or [image_name])[0]
                script = (params.get("script") or [""])[0]
                timeout_seconds = int((params.get("timeout") or [str(DEFAULT_TIMEOUT_SECONDS)])[0])
                memory_mib = int((params.get("memoryMiB") or ["2048"])[0])
                vcpus = int((params.get("vcpus") or ["2"])[0])
                self._json(
                    200,
                    create_vm_job(image_name, name_hint, script, timeout_seconds, memory_mib, vcpus),
                )
                return
            self._json(404, {"ok": False, "error": "not found"})
        except FileNotFoundError as exc:
            self._json(404, {"ok": False, "error": str(exc)})
        except ValueError as exc:
            self._json(400, {"ok": False, "error": str(exc)})
        except ApiException as exc:
            self._json(exc.status or 500, {"ok": False, "error": exc.reason, "body": exc.body})
        except Exception as exc:  # pragma: no cover
            self._json(500, {"ok": False, "error": str(exc)})

    def log_message(self, fmt, *args):
        return

    def _json(self, status: int, obj):
        data = json.dumps(obj).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _text(self, status: int, text: str):
        data = text.encode("utf-8", errors="replace")
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


if __name__ == "__main__":
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), Handler)
    server.serve_forever()
