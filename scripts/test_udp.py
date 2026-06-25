import socket
import sys

print("Sending UDP ping to 127.0.0.1:6002...")
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.sendto(b"\xFF", ("127.0.0.1", 6002))
print("Sent. Checking if server prints incoming UDP connection detected.")
