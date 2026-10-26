#!/usr/bin/env python3
"""Bounded, non-recursive DNS and nonce echo fixtures. Bind only to lab/tunnel IPs.

No packet forwarding, firewall changes, credential collection or public listener.
Run on the gateway's tunnel interface during an explicitly initiated experiment.
"""
import argparse
from contextlib import contextmanager
import ipaddress
import socket
import socketserver
import struct
import threading

MAX_PACKET = 512

def dns_reply(query, ipv4, ipv6):
    if not 12 <= len(query) <= MAX_PACKET:
        return None
    ident, flags, questions, answers, authority, additional = struct.unpack("!6H", query[:12])
    if flags & 0xF800 or questions != 1 or answers or authority or additional > 1:
        return None
    offset = 12
    labels = []
    while offset < len(query):
        length = query[offset]
        offset += 1
        if length == 0:
            break
        if length > 63 or offset + length > len(query):
            return None
        try:
            labels.append(query[offset:offset+length].decode("ascii").lower())
        except UnicodeDecodeError:
            return None
        offset += length
    else:
        return None
    if offset + 4 > len(query):
        return None
    qtype, qclass = struct.unpack("!HH", query[offset:offset+4])
    question_end = offset + 4
    if additional == 0:
        if question_end != len(query):
            return None
    else:
        # Accept one bounded EDNS OPT record used by real system resolvers.
        opt = query[question_end:]
        if len(opt) < 11 or opt[0] != 0:
            return None
        record_type, _, _, rdlength = struct.unpack("!HHIH", opt[1:11])
        if record_type != 41 or len(opt) != 11 + rdlength:
            return None
    name = ".".join(labels)
    if qclass != 1:
        return None
    records = {("npv-v4.test", 1): ipaddress.IPv4Address(ipv4).packed,
               ("npv-v6.test", 28): ipaddress.IPv6Address(ipv6).packed}
    data = records.get((name, qtype))
    rcode = 0 if name in {"npv-v4.test", "npv-v6.test"} else 3
    # Authoritative fixture, no recursion available; preserve only the RD bit.
    response = struct.pack("!6H", ident, 0x8400 | (flags & 0x0100) | rcode, 1, 1 if data else 0, 0, 0) + query[12:question_end]
    if data:
        response += b"\xc0\x0c" + struct.pack("!HHIH", qtype, 1, 1, len(data)) + data
    return response

def valid_marker(data):
    return 6 <= len(data) <= 128 and data.startswith(b"NPV/1 ") and data.endswith(b"\n")

class EchoTCP(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(3)
        data = b""
        try:
            while len(data) < 129 and not data.endswith(b"\n"):
                chunk = self.request.recv(129 - len(data))
                if not chunk:
                    break
                data += chunk
            if valid_marker(data):
                self.request.sendall(data)
        except (TimeoutError, OSError):
            pass

class EchoUDP(socketserver.BaseRequestHandler):
    def handle(self):
        data, transport = self.request
        if valid_marker(data):
            transport.sendto(data, self.client_address)

class DNSUDP(socketserver.BaseRequestHandler):
    def handle(self):
        data, transport = self.request
        reply = dns_reply(data, self.server.record4, self.server.record6)
        if reply:
            transport.sendto(reply, self.client_address)

class TCPServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

class UDPServer(socketserver.UDPServer):
    max_packet_size = MAX_PACKET + 1

def make_server(base, handler, host, port):
    family = socket.AF_INET6 if ipaddress.ip_address(host).version == 6 else socket.AF_INET
    class Server(base):
        address_family = family
        def server_bind(self):
            if family == socket.AF_INET6:
                self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            super().server_bind()
    return Server((host, port), handler)

@contextmanager
def serving(host4="10.77.0.1", host6="fd77::1", tcp_port=8080, udp_port=9000, dns_port=53):
    servers = []
    threads = []
    try:
        for host in (host4, host6):
            address = ipaddress.ip_address(host)
            if address.is_unspecified or address.is_multicast or not (address.is_private or address.is_loopback):
                raise ValueError("Use explicit private tunnel/lab addresses, never a wildcard/public address.")
            for base, handler, port in [(TCPServer, EchoTCP, tcp_port), (UDPServer, EchoUDP, udp_port), (UDPServer, DNSUDP, dns_port)]:
                server = make_server(base, handler, host, port)
                server.record4, server.record6 = host4, host6
                servers.append(server)
        for server in servers:
            thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval":0.05}, daemon=True)
            thread.start()
            threads.append(thread)
        yield servers
    finally:
        for server in servers[:len(threads)]:
            server.shutdown()
        for server in servers:
            server.server_close()
        for thread in threads:
            thread.join(timeout=2)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ipv4", default="10.77.0.1")
    parser.add_argument("--ipv6", default="fd77::1")
    args = parser.parse_args()
    with serving(args.ipv4, args.ipv6):
        print("NPV fixtures ready: TCP 8080, UDP 9000, DNS/UDP 53. Stop with Ctrl-C.", flush=True)
        try:
            threading.Event().wait()
        except KeyboardInterrupt:
            pass

if __name__ == "__main__":
    main()
