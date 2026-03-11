#!/bin/bash
# Reads GITHUB_PAT from .env, XOR-obfuscates it, outputs Generated/GitHubToken.swift
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
ENV_FILE="${ROOT_DIR}/.env"
OUTPUT="${ROOT_DIR}/Murmur/Generated/GitHubToken.swift"

mkdir -p "$(dirname "$OUTPUT")"

# Read token from .env
if [ ! -f "$ENV_FILE" ]; then
    echo "Warning: .env not found, generating empty token"
    TOKEN=""
else
    TOKEN=$(grep '^GITHUB_PAT=' "$ENV_FILE" | cut -d= -f2- | tr -d '[:space:]')
fi

if [ -z "$TOKEN" ]; then
    cat > "$OUTPUT" << 'SWIFT'
// Auto-generated — do not edit
enum GitHubToken {
    static let obfuscated: [UInt8] = []
    static let key: [UInt8] = []
}
SWIFT
    echo "Generated empty token stub"
    exit 0
fi

# Generate random XOR key same length as token
python3 -c "
import os, sys

token = b'$TOKEN'
key = os.urandom(len(token))
obfuscated = bytes(t ^ k for t, k in zip(token, key))

def fmt(bs):
    return ', '.join(f'0x{b:02x}' for b in bs)

print('// Auto-generated — do not edit')
print('enum GitHubToken {')
print(f'    static let obfuscated: [UInt8] = [{fmt(obfuscated)}]')
print(f'    static let key: [UInt8] = [{fmt(key)}]')
print('}')
" > "$OUTPUT"

echo "Generated obfuscated token at $OUTPUT"
