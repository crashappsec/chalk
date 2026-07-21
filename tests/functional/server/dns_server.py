# Copyright (c) 2023-2026, Crash Override, Inc.
#
# This file is part of Chalk
# (see https://crashoverride.com/docs/chalk)
"""
Minimal UDP DNS server for functional tests.

Listens on UDP 5354 for DNS queries, records every queried hostname, and
returns NOERROR with no answer records (so chalk's DNS sink treats the lookup
as successful). Exposes an HTTP API on port 8054 so tests can retrieve and
clear the recorded queries.
"""
import asyncio
import struct

import uvicorn
from fastapi import FastAPI

app = FastAPI()
queries: list[str] = []


def _parse_qname(data: bytes, offset: int) -> str:
    labels = []
    while offset < len(data):
        length = data[offset]
        if length == 0:
            break
        if (length & 0xC0) == 0xC0:  # compression pointer — not expected in questions
            break
        offset += 1
        labels.append(data[offset : offset + length].decode("ascii", errors="replace"))
        offset += length
    return ".".join(labels)


class DnsProtocol(asyncio.DatagramProtocol):
    def connection_made(self, transport: asyncio.DatagramTransport) -> None:
        self.transport = transport

    def datagram_received(self, data: bytes, addr: tuple) -> None:
        if len(data) < 13:
            return
        name = _parse_qname(data, 12)
        if name:
            queries.append(name)
        # NOERROR with the question echoed back and no answer records
        response = (
            data[:2]  # copy query ID
            + b"\x81\x80"  # QR=1 RD=1 RA=1 RCODE=0
            + struct.pack(
                "!HHHH", 1, 0, 0, 0
            )  # QDCOUNT=1 ANCOUNT=0 NSCOUNT=0 ARCOUNT=0
            + data[12:]  # echo question section
        )
        self.transport.sendto(response, addr)


@app.get("/health")
def health() -> dict:
    return {}


@app.get("/queries")
def get_queries() -> list[str]:
    return list(queries)


@app.delete("/queries", status_code=204)
def clear_queries() -> None:
    queries.clear()


async def main() -> None:
    loop = asyncio.get_running_loop()
    await loop.create_datagram_endpoint(DnsProtocol, local_addr=("0.0.0.0", 5354))
    config = uvicorn.Config(app, host="0.0.0.0", port=8054, log_level="warning")
    server = uvicorn.Server(config)
    await server.serve()


if __name__ == "__main__":
    asyncio.run(main())
