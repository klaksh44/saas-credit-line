// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { StakeAndAdvance } from "../src/StakeAndAdvance.sol";
import { IERC20 } from "../src/token/IERC20.sol";

interface Vm {
    function envAddress(string calldata name) external view returns (address);
    function envOr(string calldata name, uint256 defaultValue) external view returns (uint256);
    function envOr(string calldata name, address defaultValue) external view returns (address);
    function startBroadcast() external;
    function stopBroadcast() external;
}

contract Deploy {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint16 internal constant DEFAULT_COLLATERAL_BPS = 6000;
    uint64 internal constant DEFAULT_DISPUTE_WINDOW = 10 minutes;

    function run() external returns (StakeAndAdvance deployed) {
        address usdc = vm.envAddress("USDC_ADDRESS");
        address arbiter = vm.envAddress("ARBITER_ADDRESS");
        address keystoneForwarder = vm.envAddress("KEYSTONE_FORWARDER");
        uint64 disputeWindow =
            uint64(vm.envOr("DISPUTE_WINDOW_SECONDS", uint256(DEFAULT_DISPUTE_WINDOW)));
        uint16 collateralBps = uint16(vm.envOr("COLLATERAL_BPS", uint256(DEFAULT_COLLATERAL_BPS)));
        address worldIdSigner = vm.envOr("WORLD_ID_SIGNER", address(0));

        vm.startBroadcast();
        deployed = new StakeAndAdvance(
            IERC20(usdc), arbiter, keystoneForwarder, disputeWindow, collateralBps
        );
        // Deployer is the vendor (msg.sender), so it can set the World ID backend signer.
        if (worldIdSigner != address(0)) {
            deployed.setWorldIdSigner(worldIdSigner);
        }
        vm.stopBroadcast();
    }
}
