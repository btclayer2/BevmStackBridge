# BevmStack Bridge
BevmStack Bridge is the system contract of BevmStack Chain and is an important component for the decentralization of Bitcoin assets to the BevmStack chain.

BevmStack Bridge is implemented using [UUPS proxy pattern](https://docs.openzeppelin.com/contracts/5.x/api/proxy#transparent-vs-uups)

## 1. Versions
- `nodejs`: `v22.6.0`
- `foundry`: `v0.2.0`
- `forge-std`: `v1.9.2`
- `openzeppelin-foundry-upgrades`: `v0.3.2`
- `openzeppelin-contracts-upgradeable`: `v5.0.2`

## 2. Envs

reset PRIVATE_KEY

```bash
cp .env-example .env
vi .env 
```

## 3. Scripts

### 3.1 Deploy implementation contract and uups-proxy contract

```bash
forge script ./script/Deploy.s.sol --broadcast -vvvv --rpc-url $RPC_URL

```
Based on the execution results of the previous step,

`Deploy.s.sol` will set `BRIDGE_PROXY` and `BRIDGE_IMPL` to `.env` file.


**verify the contracts**

```bash
source .env

forge verify-contract --verifier blockscout  --verifier-url $VERIFIER_URL $BRIDGE_PROXY lib/openzeppelin-contracts-upgradeable/lib/openzeppelin-contracts/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy --skip-is-verified-check --chain $CHAIN_ID

forge verify-contract --verifier blockscout  --verifier-url $VERIFIER_URL $BRIDGE_IMPL src/BridgeV6Proxiable.sol:BridgeV6Proxiable --chain $CHAIN_ID

```

### 3.2 Prepare upgrade new implementation contract
The upgrade of the `BevmStack Bridge` is governed by BevmStack's `council` vote. 
The `council` need to call `xAssetsBridge->callContract` to build an unsigned evm transaction(`from` is the system account `0x1111111111111111111111111111111111111111`).

```bash
forge script PrepareUpgradeScript --broadcast -vvvv --rpc-url $RPC_URL
```
Based on the execution results of the previous step,
`PrepareUpgradeScript.s.sol` will set `NEW_BRIDGE_IMPL` and `UPGRADE_CALLDATA` to `.env` file.

- The `contract` of `xAssetsBridge->callContract` is `BRIDGE_PROXY`.
- The `inputs` of `xAssetsBridge->callContract` is `UPGRADE_CALLDATA`.

**verify the contracts**
```bash
source .env
forge verify-contract --verifier blockscout  --verifier-url $VERIFIER_URL $NEW_BRIDGE_IMPL  src/BridgeV7TestProxiable.sol:BridgeV7TestProxiable --chain $CHAIN_ID
```

## Troubleshooting
### forge script issue
- issue: `Build info file ${buildInfoFilePath} is not from a full compilation.`
  resolved: run `forge clean` and rerun forge script
