# Test data and privacy

Fixtures use synthetic hostnames, generated temporary certificates, generated test credentials, and deliberately invalid tokens. Address-validation tests construct synthetic addresses at runtime. No literal IP addresses, personal names, personal email addresses, owner-specific paths, or production signing material belong in this directory.

`run_stream_transport_checks.py` runs an isolated localhost server and generates its certificates in a temporary directory. `run_pairing_state_checks.sh` substitutes a fixture device name and in-memory doubles. `test_relay_transport.py` uses temporary credentials and local test servers.

`PairingTransportChecks.swift` is an optional live diagnostic: its endpoint and public certificate fingerprint are supplied at runtime, never stored in the source. It sends only a deliberately invalid test token. Do not commit arguments, live logs, QR codes, or generated artifacts.
