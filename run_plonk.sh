#!/usr/bin/env bash
#
# run_plonk.sh — compile a Circom circuit, generate a PLONK proof, and verify it.
#
# Usage:
#   ./run_plonk.sh <circuit_name> <input_file> [ptau_power]
#
# Example:
#   ./run_plonk.sh multiplier input.json 12
#
# Expects:
#   ./<circuit_name>.circom   — your circuit source in the current directory
#   ./<input_file>            — JSON file with your circuit's private/public inputs
#
# Requires: circom (v2), snarkjs, node — all on PATH.
# Install:  npm install -g snarkjs
#           https://docs.circom.io/getting-started/installation/

set -euo pipefail

# ---------- args ----------
CIRCUIT_NAME="${1:?Usage: $0 <circuit_name> <input_file> [ptau_power]}"
INPUT_FILE="${2:?Usage: $0 <circuit_name> <input_file> [ptau_power]}"
PTAU_POWER="${3:-12}"   # 2^12 constraints is enough for most small/medium circuits; raise if needed

BUILD_DIR="build"
PTAU_DIR="ptau"
CIRCUIT_FILE="${CIRCUIT_NAME}.circom"
R1CS_FILE="${BUILD_DIR}/${CIRCUIT_NAME}.r1cs"
WASM_DIR="${BUILD_DIR}/${CIRCUIT_NAME}_js"
WASM_FILE="${WASM_DIR}/${CIRCUIT_NAME}.wasm"
WITNESS_FILE="${BUILD_DIR}/witness.wtns"
PTAU_FINAL="${PTAU_DIR}/pot${PTAU_POWER}_final.ptau"
ZKEY_FILE="${BUILD_DIR}/${CIRCUIT_NAME}_plonk.zkey"
VKEY_FILE="${BUILD_DIR}/verification_key.json"
PROOF_FILE="${BUILD_DIR}/proof.json"
PUBLIC_FILE="${BUILD_DIR}/public.json"
VERIFIER_SOL="${BUILD_DIR}/${CIRCUIT_NAME}Verifier.sol"

# ---------- helpers ----------
log() { printf '\n\033[1;34m[run_plonk]\033[0m %s\n' "$1"; }
fail() { printf '\n\033[1;31m[run_plonk] ERROR:\033[0m %s\n' "$1" >&2; exit 1; }

command -v circom >/dev/null 2>&1 || fail "circom not found on PATH. Install: https://docs.circom.io/getting-started/installation/"
command -v snarkjs >/dev/null 2>&1 || fail "snarkjs not found on PATH. Install: npm install -g snarkjs"
[ -f "$CIRCUIT_FILE" ] || fail "Circuit file not found: $CIRCUIT_FILE"
[ -f "$INPUT_FILE" ] || fail "Input file not found: $INPUT_FILE"

mkdir -p "$BUILD_DIR" "$PTAU_DIR"

# ---------- 1. Compile the circuit ----------
log "Compiling $CIRCUIT_FILE"
circom "$CIRCUIT_FILE" --r1cs --wasm --sym -o "$BUILD_DIR"
[ -f "$R1CS_FILE" ] || fail "Compilation did not produce $R1CS_FILE"

# ---------- 2. Generate the witness ----------
log "Generating witness from $INPUT_FILE"
node "${WASM_DIR}/generate_witness.js" "$WASM_FILE" "$INPUT_FILE" "$WITNESS_FILE"

# ---------- 3. Powers of Tau (universal, reusable across circuits of same/lower power) ----------
if [ -f "$PTAU_FINAL" ]; then
  log "Reusing existing Powers of Tau file: $PTAU_FINAL"
else
  log "Generating new Powers of Tau (2^${PTAU_POWER}) — this is a one-time setup per power"
  PTAU_0000="${PTAU_DIR}/pot${PTAU_POWER}_0000.ptau"
  PTAU_0001="${PTAU_DIR}/pot${PTAU_POWER}_0001.ptau"

  snarkjs powersoftau new bn128 "$PTAU_POWER" "$PTAU_0000" -v

  snarkjs powersoftau contribute "$PTAU_0000" "$PTAU_0001" \
    --name="local contribution" -v -e="$(head -c 64 /dev/urandom | base64)"

  snarkjs powersoftau prepare phase2 "$PTAU_0001" "$PTAU_FINAL" -v

  rm -f "$PTAU_0000" "$PTAU_0001"
fi

# ---------- 4. PLONK setup (circuit-specific proving/verification key) ----------
log "Running PLONK setup"
snarkjs plonk setup "$R1CS_FILE" "$PTAU_FINAL" "$ZKEY_FILE"

# ---------- 5. Export verification key ----------
log "Exporting verification key"
snarkjs zkey export verificationkey "$ZKEY_FILE" "$VKEY_FILE"

# ---------- 6. Generate the proof ----------
log "Generating PLONK proof"
snarkjs plonk prove "$ZKEY_FILE" "$WITNESS_FILE" "$PROOF_FILE" "$PUBLIC_FILE"

# ---------- 7. Verify the proof ----------
log "Verifying PLONK proof"
if snarkjs plonk verify "$VKEY_FILE" "$PUBLIC_FILE" "$PROOF_FILE"; then
  log "✅ Proof is VALID"
else
  fail "❌ Proof verification FAILED"
fi

# ---------- 8. Export Solidity verifier ----------
log "Exporting Solidity verifier contract"
snarkjs zkey export solidityverifier "$ZKEY_FILE" "$VERIFIER_SOL"

log "Done. Artifacts written to ${BUILD_DIR}/:"
echo "  - Proof:              $PROOF_FILE"
echo "  - Public signals:     $PUBLIC_FILE"
echo "  - Verification key:   $VKEY_FILE"
echo "  - Solidity verifier:  $VERIFIER_SOL"
echo
echo "Drop ${VERIFIER_SOL} into your Foundry/Hardhat src/ to deploy and call verifyProof() on-chain."
