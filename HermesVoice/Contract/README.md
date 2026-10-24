# Gateway contract

`gateway-contract.openrpc.json` is a pinned copy of Hermes' `apps/shared/src/gateway-contract.openrpc.json`:
the OpenRPC description of the `/api/ws` JSON-RPC gateway (client→server methods, `x-server-requests`,
`x-notifications`), generated in Hermes from `tui_gateway/contracts`.
`HermesVoice/tools/gen_swift_gateway.py` renders it into `HermesVoice/HermesVoice/Gateway/Generated/`.

| | |
|---|---|
| hermes-agent version (pyproject) | `0.0.0` |
| git describe | `v0.21.4+canary.20261001T070239Z-94-ge8c97320a` |
| commit | `e8c97320a` (2026-10-01) |
| SHA-256 | `fb99cca0dc4f79d4d0d1d2c0baa5eccc603504f6fcdbf436f0ad2ad3bdb8d0d2` |

Re-pin from a Hermes checkout (default `~/.hermes/hermes-agent`, or `--hermes DIR`) and regenerate:

```sh
python3 HermesVoice/tools/gen_swift_gateway.py --update
```

`--check` exits 1 when the generated Swift no longer matches this contract.
