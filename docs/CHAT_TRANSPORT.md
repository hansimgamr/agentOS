# Chat transport

The Swift client sends text and images through the relay using Hermes's input schema. Images are encoded as base64 data URLs. Session creation omits an explicit default title to avoid uniqueness collisions.

## Connection security

Health, data, and streaming requests validate the exact endpoint host, port, and SHA-256 certificate pin. Streaming receives an explicit task authentication delegate. Redirects are rejected. The relay forwards only the app's allowed routes and substitutes the Mac-only Hermes credential after device authentication.

## Streaming and recovery

A bounded byte decoder preserves LF, CRLF, CR, split UTF-8 sequences, multiline server-sent events, and keepalive comments. A successful response requires Hermes's completion and terminal events. Truncation, malformed events, cancellation, and server errors are reported.

Recovery distinguishes rejected and accepted requests, retains available partial output, and ignores stale callbacks after selection or connection changes. Uncertain delivery is not retried automatically. Refresh the conversation before choosing whether to resend.

The relay closes an interrupted upstream response. It sends an HTTP error only before response headers have started, so it cannot append a second HTTP response to an existing stream.

## Message presentation

Assistant headers use model metadata reported by Hermes. A local cache retains model names for matched messages without storing message content. Older history with no model metadata stays unlabeled. Reopening a thread or sending targets the bottom; manual scrolling pauses following.

See [development checks](DEVELOPMENT.md) for transport fixtures and physical-device testing limits.
