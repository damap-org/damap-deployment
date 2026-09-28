#!/usr/bin/env python3
"""Diagnose TCP reachability and SSH identification without authenticating."""
import argparse
from datetime import datetime, timezone
import socket
import time


def log(message):
    print(f"{datetime.now(timezone.utc).isoformat(timespec='seconds')} {message}", flush=True)


def probe(family, address, timeout):
    destination = f"{address[0]}:{address[1]}"
    label = "IPv6" if family == socket.AF_INET6 else "IPv4"
    log(f"TCP CONNECT {label} {destination}; timeout={timeout}s")
    started = time.monotonic()
    with socket.socket(family, socket.SOCK_STREAM) as connection:
        connection.settimeout(timeout)
        try:
            connection.connect(address)
        except TimeoutError:
            log(f"TCP TIMEOUT {destination}: no connection established within {timeout}s; "
                "possible packet filtering/drop or an unreachable host.")
            return False
        except OSError as error:
            log(f"TCP FAILED {destination}: {type(error).__name__}: {error}")
            return False
        log(f"TCP CONNECTED {destination} in {time.monotonic() - started:.3f}s; "
            f"local socket={connection.getsockname()} (may be translated by NAT)")
        log(f"SSH BANNER WAIT {destination}; separate timeout={timeout}s")
        deadline = time.monotonic() + timeout
        pending = b""
        received = 0
        try:
            while received < 8192:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError
                connection.settimeout(remaining)
                chunk = connection.recv(min(1024, 8192 - received))
                if not chunk:
                    log(f"SSH CLOSED {destination}: TCP succeeded but peer closed before an SSH banner.")
                    return False
                received += len(chunk)
                pending += chunk
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    line = line.rstrip(b"\r")
                    if line.startswith((b"SSH-2.0-", b"SSH-1.99-")):
                        log(f"SSH BANNER RECEIVED {destination}: {line!r}; no authentication attempted.")
                        return True
                    log(f"SSH PRE-BANNER {destination}: {line!r}")
        except TimeoutError:
            log(f"SSH BANNER TIMEOUT {destination}: TCP connected, but no SSH identification "
                f"arrived within {timeout}s ({received} bytes received).")
            return False
        except OSError as error:
            log(f"SSH READ FAILED {destination}: TCP connected; {type(error).__name__}: {error}")
            return False
        log(f"SSH INVALID RESPONSE {destination}: received 8192 bytes without SSH identification.")
        return False


def check(host, port, timeout):
    log(f"DNS RESOLVE {host}; SSH destination port={port}")
    try:
        addresses = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    except socket.gaierror as error:
        log(f"DNS FAILED {host}: {error}")
        return 1
    seen = set()
    successes = 0
    for family, _, _, _, address in addresses:
        if (family, address) in seen:
            continue
        seen.add((family, address))
        successes += probe(family, address, timeout)
    log(f"RESULT: {successes}/{len(seen)} resolved addresses returned an SSH banner. "
        "At least one is required; this does not test SSH credentials or deployment permissions.")
    return 0 if successes else 1


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host")
    parser.add_argument("--port", type=int, default=22)
    parser.add_argument("--timeout", type=float, default=10)
    args = parser.parse_args()
    if not 0 < args.timeout <= 60 or not 0 < args.port <= 65535:
        parser.error("timeout must be in (0, 60] seconds and port in [1, 65535]")
    raise SystemExit(check(args.host, args.port, args.timeout))
