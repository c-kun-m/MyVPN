import ipaddress
import socket
import struct
import unittest
from probe_server import dns_reply, serving

def query(name, kind=1):
    labels = b"".join(bytes([len(label)]) + label.encode() for label in name.split("."))
    return struct.pack("!6H", 1234, 0x0100, 1, 0, 0, 0) + labels + b"\0" + struct.pack("!HH", kind, 1)

class ProtocolTests(unittest.TestCase):
    def test_ipv4_record(self):
        reply = dns_reply(query("npv-v4.test"), "10.77.0.1", "fd77::1")
        self.assertEqual(reply[-4:], ipaddress.ip_address("10.77.0.1").packed)
        self.assertEqual(struct.unpack("!H", reply[6:8])[0], 1)

    def test_ipv6_record(self):
        reply = dns_reply(query("npv-v6.test", 28), "10.77.0.1", "fd77::1")
        self.assertEqual(reply[-16:], ipaddress.ip_address("fd77::1").packed)

    def test_edns_query_from_system_resolver(self):
        request = bytearray(query("npv-v4.test"))
        request[10:12] = b"\0\1"
        request += b"\0" + struct.pack("!HHIH", 41, 1232, 0, 0)
        reply = dns_reply(bytes(request), "10.77.0.1", "fd77::1")
        self.assertEqual(reply[-4:], ipaddress.ip_address("10.77.0.1").packed)
        self.assertEqual(struct.unpack("!H", reply[10:12])[0], 0)

    def test_no_recursion_or_external_resolution(self):
        reply = dns_reply(query("example.org"), "10.77.0.1", "fd77::1")
        flags = struct.unpack("!H", reply[2:4])[0]
        self.assertEqual(flags & 0xF, 3)
        self.assertFalse(flags & 0x0080)

    def test_invalid_queries_rejected(self):
        for data in [b"", b"x" * 513, query("npv-v4.test")[:-1], query("npv-v4.test") + b"x"]:
            self.assertIsNone(dns_reply(data, "10.77.0.1", "fd77::1"))

    def test_compression_pointers_rejected(self):
        data = struct.pack("!6H", 1, 0, 1, 0, 0, 0) + b"\xc0\x0c\0\x01\0\x01"
        self.assertIsNone(dns_reply(data, "10.77.0.1", "fd77::1"))

    def test_unexpected_question_type_returns_no_answer(self):
        reply = dns_reply(query("npv-v4.test", 28), "10.77.0.1", "fd77::1")
        self.assertEqual(struct.unpack("!H", reply[6:8])[0], 0)

    def test_wildcard_bind_rejected(self):
        with self.assertRaises(ValueError):
            with serving("0.0.0.0", "::1", 0, 0, 0):
                pass

class LocalSocketTests(unittest.TestCase):
    def test_tcp_udp_dns_over_both_loopback_families(self):
        # This validates fixtures only: no WireGuard or iPhone is involved.
        with serving("127.0.0.1", "::1", 0, 0, 0) as servers:
            marker = b"NPV/1 socket-fixture-test\n"
            for offset, host, family in [(0, "127.0.0.1", socket.AF_INET), (3, "::1", socket.AF_INET6)]:
                with socket.socket(family, socket.SOCK_STREAM) as client:
                    client.settimeout(2)
                    client.connect((host, servers[offset].server_address[1]))
                    client.sendall(marker)
                    self.assertEqual(client.recv(128), marker)
                with socket.socket(family, socket.SOCK_DGRAM) as client:
                    client.settimeout(2)
                    client.sendto(marker, (host, servers[offset+1].server_address[1]))
                    self.assertEqual(client.recv(128), marker)
                with socket.socket(family, socket.SOCK_DGRAM) as client:
                    client.settimeout(2)
                    request = query("npv-v4.test" if family == socket.AF_INET else "npv-v6.test", 1 if family == socket.AF_INET else 28)
                    client.sendto(request, (host, servers[offset+2].server_address[1]))
                    reply = client.recv(512)
                    self.assertTrue(reply.endswith(ipaddress.ip_address(host).packed))

if __name__ == "__main__": unittest.main()
