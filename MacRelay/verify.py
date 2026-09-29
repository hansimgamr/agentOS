"""Check TLS pinning, relay denial, and the Mac-only Hermes key."""

import hashlib
import http.client
import ssl

from relay import listen_address, PRIVATE, api_key


cert = PRIVATE / "relay" / "relay.crt"
fingerprint = hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.read_text())).hexdigest()
assert fingerprint == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
def get(path, key=None):
    connection = http.client.HTTPSConnection(*listen_address(), context=ssl._create_unverified_context(), timeout=10)
    connection.connect()
    assert hashlib.sha256(connection.sock.getpeercert(binary_form=True)).hexdigest() == fingerprint
    connection.request("GET", path, headers={"Authorization": "Bearer " + key} if key else {})
    response = connection.getresponse()
    response.read()
    connection.close()
    return response.status


assert get("/health") == 401
assert get("/health", api_key()) == 401
direct = http.client.HTTPConnection("localhost", 8642, timeout=10)
direct.request("GET", "/api/sessions?limit=1", headers={"Authorization": "Bearer " + api_key()})
response = direct.getresponse()
assert response.status == 200
response.read()
direct.close()
print("TLS certificate verified; relay rejects missing and Mac-only credentials; Hermes API is healthy")
