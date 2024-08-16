// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {Script, console} from "forge-std/Script.sol";

import {Upgrades} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {Options} from "openzeppelin-foundry-upgrades/Options.sol";

import {IUpgradeableProxy} from "openzeppelin-foundry-upgrades/internal/interfaces/IUpgradeableProxy.sol";

import {BridgeV7TestProxiable} from "src/BridgeV7TestProxiable.sol";

// prepare upgrade script
// forge script PrepareUpgradeScript --broadcast -vvvv --rpc-url <rpc-url>

contract PrepareUpgradeScript is Script {
    // 0 is BEVM_TESTNET, 1 is BEVM_MAINNET, 2 is SATSCHAIN
    uint256 network = vm.envUint("NETWORK");

    address bridgeUupsProxy = vm.envAddress("BRIDGE_PROXY");
    string memo = "";

    function setUp() public {
        if (network == 0) {
            memo = "bevm-testnet";
        } else if (network == 2) {
            memo = "satschain";
        } else {
            memo = "bevm-mainnet";
        }
    }

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        address oldBridgeImpl = Upgrades.getImplementationAddress(bridgeUupsProxy);

        Options memory opts;
        opts.unsafeSkipStorageCheck = true;
        address newBridgeImpl = Upgrades.prepareUpgrade("BridgeV7TestProxiable.sol", opts);

        vm.stopBroadcast();

        console.log("Bridge Proxy Address", address(bridgeUupsProxy));
        console.log("Old Bridge Implementation Address", address(oldBridgeImpl));
        console.log("New Bridge Implementation Address", address(newBridgeImpl));

        // reinitializeCallData = $(cast calldata "reinitialize(string)" $memo)
        bytes memory reinitializeCallData = abi.encodeCall(BridgeV7TestProxiable.reinitialize, memo);
        console.log("Reinitialize Call Data:");
        console.logBytes(reinitializeCallData);

        // upgradeCallData = $(cast calldata "upgradeToAndCall(address,bytes)" $newBridgeImpl $reinitializeCallData)
        bytes memory upgradeCallData =
            abi.encodeCall(IUpgradeableProxy(bridgeUupsProxy).upgradeToAndCall, (newBridgeImpl, reinitializeCallData));

        console.log("To Propose a council motion(xAssetsBridge->callContract)");
        console.log("callContract contract:");
        console.logAddress(bridgeUupsProxy);
        console.log("callContract inputs:");
        console.logBytes(upgradeCallData);

        vm.writeLine(".env", "\n");
        string memory newBridgeImplPrefix = "NEW_BRIDGE_IMPL=";
        vm.writeLine(".env", string.concat(newBridgeImplPrefix, vm.toString(newBridgeImpl)));

        string memory upgradeCallDataPrefix = "UPGRADE_CALLDATA=";
        vm.writeLine(".env", string.concat(upgradeCallDataPrefix, vm.toString(upgradeCallData)));
    }
}
