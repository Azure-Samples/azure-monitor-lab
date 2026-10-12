import argparse
import json
import os
from pathlib import Path
import posixpath
import shlex
import sys
import uuid

import paramiko


def bootstrap(publish: Path, port: int, payload: bytes) -> None:
    decoded = json.loads(payload)
    if not decoded.get("AccessToken") or not decoded.get("Query") or not decoded.get("SqlServerName"):
        raise ValueError("An in-memory token, SQL server name and bootstrap query are required.")
    if not 1 <= port <= 65535:
        raise ValueError("SSH tunnel port must be between 1 and 65535.")
    if not (publish / "CustomerSqlBootstrap.dll").is_file():
        raise FileNotFoundError("The private bootstrap tool must be published first.")

    client = paramiko.SSHClient()
    # This loopback endpoint must be the authenticated Azure CLI App Service TLS tunnel.
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    remote_root = "/tmp/amlab-sql-bootstrap-" + uuid.uuid4().hex
    uploaded: list[str] = []
    directories: list[str] = []
    try:
        client.connect("127.0.0.1", port=port, username="root", password="Docker!",
                       timeout=20, banner_timeout=30, auth_timeout=30,
                       look_for_keys=False, allow_agent=False)
        with client.open_sftp() as sftp:
            sftp.mkdir(remote_root)
            directories.append(remote_root)
            for root, dirs, files in os.walk(publish):
                relative = Path(root).relative_to(publish)
                remote = remote_root if not relative.parts else posixpath.join(remote_root, *relative.parts)
                for directory in dirs:
                    path = posixpath.join(remote, directory)
                    sftp.mkdir(path)
                    directories.append(path)
                for file in files:
                    path = posixpath.join(remote, file)
                    sftp.put(str(Path(root) / file), path)
                    uploaded.append(path)
        command = "dotnet " + shlex.quote(posixpath.join(remote_root, "CustomerSqlBootstrap.dll"))
        stdin, stdout, stderr = client.exec_command(command, timeout=120)
        stdin.channel.sendall(payload)
        stdin.channel.shutdown_write()
        payload = b""
        decoded = None
        output = stdout.read().decode("utf-8")
        error = stderr.read().decode("utf-8")
        status = stdout.channel.recv_exit_status()
        print(output, end="")
        if status != 0:
            print(error, end="", file=sys.stderr)
            raise RuntimeError(f"Private SQL bootstrap exited with status {status}.")
    finally:
        payload = b""
        decoded = None
        try:
            if client.get_transport() and client.get_transport().is_active():
                with client.open_sftp() as sftp:
                    for path in reversed(uploaded):
                        sftp.remove(path)
                    for path in reversed(directories):
                        sftp.rmdir(path)
        finally:
            client.close()


def main() -> None:
    parser = argparse.ArgumentParser(description="Bootstrap SQL through an already-authenticated App Service SSH tunnel.")
    parser.add_argument("--publish", type=Path, required=True)
    parser.add_argument("--port", type=int, required=True)
    args = parser.parse_args()
    bootstrap(args.publish, args.port, sys.stdin.buffer.read())


if __name__ == "__main__":
    main()
