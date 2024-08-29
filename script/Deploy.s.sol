// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script, console} from "forge-std/Script.sol";

import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";

import {InitialParameters} from "src/lib/Types.sol";
import {BridgeV7Proxiable} from "src/BridgeV7Proxiable.sol";

// deployment script
// forge script ./script/Deploy.s.sol --broadcast -vvvv --rpc-url <rpc-url>

contract DeployScript is Script {
    InitialParameters initialParameters;

    // 0 is BEVM_TESTNET, 1 is BEVM_MAINNET, 2 is SATSCHAIN
    uint256 network = vm.envUint("NETWORK");

    function setUp() public {
        if (network == 0) {
            initialParameters.gasDecimalsOnBitcoin = 8;
            initialParameters.gasType = "btc";
            initialParameters.cold = 0xcAF084133CBdBE27490d3afB0Da220a40C32E307;
            initialParameters.owner = 0xcAF084133CBdBE27490d3afB0Da220a40C32E307;

            initialParameters.gasFactorMul = 1;
            initialParameters.gasFactorDiv = 1;
            initialParameters.withdrawNonce = 0;
            initialParameters.depositNonce = 0;
            initialParameters.wasmWithdrawNonce = 0;
            initialParameters.wasmDepositNonce = 0;
        } else if (network == 2) {
            initialParameters.gasDecimalsOnBitcoin = 18;
            initialParameters.gasType = "brc20";
            initialParameters.cold = 0xfE5cc88AA48364271e4CD8DDecE6A045F609A00b;
            initialParameters.owner = 0xB45cf380FF9A33c2bf7c41043530dc8Bb2e5295B;

            initialParameters.gasFactorMul = 220000000000;
            initialParameters.gasFactorDiv = 1;
            initialParameters.withdrawNonce = 0;
            initialParameters.depositNonce = 0;
            initialParameters.wasmWithdrawNonce = 0;
            initialParameters.wasmDepositNonce = 0;
        } else {
            initialParameters.gasDecimalsOnBitcoin = 8;
            initialParameters.gasType = "btc";
            initialParameters.cold = 0x3FA60E476834068Ee20Ecfb0087DfE541DAf8840;
            initialParameters.owner = 0xB45cf380FF9A33c2bf7c41043530dc8Bb2e5295B;

            initialParameters.gasFactorMul = 1;
            initialParameters.gasFactorDiv = 1;
            initialParameters.withdrawNonce = 0;
            initialParameters.depositNonce = 0;
            initialParameters.wasmWithdrawNonce = 0;
            initialParameters.wasmDepositNonce = 0;
        }
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address bridgeUupsProxy = Upgrades.deployUUPSProxy(
            "BridgeV7Proxiable.sol", abi.encodeCall(BridgeV7Proxiable.initialize, initialParameters)
        );

        vm.stopBroadcast();

        address bridgeImplV7 = Upgrades.getImplementationAddress(bridgeUupsProxy);

        vm.writeLine(".env", "\n");
        string memory BridgeProxyPrefix = "BRIDGE_PROXY=";
        vm.writeLine(".env", string.concat(BridgeProxyPrefix, vm.toString(bridgeUupsProxy)));

        string memory BridgeImplPrefix = "BRIDGE_IMPL=";
        vm.writeLine(".env", string.concat(BridgeImplPrefix, vm.toString(bridgeImplV7)));

        console.log("Bridge Proxy Address", address(bridgeUupsProxy));
        console.log("Bridge Implementation Address", address(bridgeImplV7));
    }
}
