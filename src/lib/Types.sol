// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

// BridgeV5
struct DepositRecordV3 {
    uint32 assetId;
    uint64 nonce;
    bytes32 txId;
    address account;
    uint256 value;
    uint256 blockNumber;
}

// BridgeV5
struct WasmDepositRecord {
    uint64 nonce;
    bool isGas;
    bytes32 from;
    uint256 value;
    address to;
    uint32 blockNumber;
}

// BridgeV5
struct GasFactor {
    uint64 mul;
    uint64 div;
}

// BridgeV5
struct PrepaidGasFeeInfo {
    // Withdraw token address
    address token;
    // Withdraw token amount
    uint256 amount;
    // The amount of fees charged for withdraw
    uint256 fee;
    // The type of fee. The values are only "btc" or "gas"
    string feeType;
    // The value that [msg.value] needs to pass when withdraw
    uint256 value;
    // The final estimate amount of tokens received
    uint256 estimateReceiveAmount;
    // Withdraw token is gas
    bool isGas;
    // The amount of gas to cold
    uint256 coldAmount;
    // The amount passed to wasm
    uint256 wasmAmount;
    // Record results, success or failure reasons
    string result;
}

// BridgeV5
struct InitialParameters {
    uint8 gasDecimalsOnBitcoin; // 1 byte
    address cold; // 20 bytes
    address owner; // 20 bytes
    uint64 gasFactorMul; // 8 bytes
    uint64 gasFactorDiv; // 8 bytes
    uint64 withdrawNonce; // 8 bytes
    uint64 depositNonce; // 8 bytes
    uint64 wasmWithdrawNonce; // 8 bytes
    uint64 wasmDepositNonce; // 8 bytes
    string gasType; // string
}
