// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { StakeAndAdvance } from "../src/StakeAndAdvance.sol";
import { IERC20 } from "../src/token/IERC20.sol";

interface Vm {
    function envAddress(string calldata name) external view returns (address);
    function envOr(string calldata name, uint256 defaultValue) external view returns (uint256);
    function startBroadcast() external;
    function stopBroadcast() external;
}

contract Deploy {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint64 internal constant DEFAULT_REPAYMENT_WINDOW = 30 days;
    uint64 internal constant DEFAULT_GRACE_PERIOD = 7 days;
    uint16 internal constant DEFAULT_MIN_RESERVE_BPS = 2000; // keep 20% liquid for redemptions

    function run() external returns (StakeAndAdvance deployed) {
        address usdc = vm.envAddress("USDC_ADDRESS");
        address keystoneForwarder = vm.envAddress("KEYSTONE_FORWARDER");
        uint64 repaymentWindow =
            uint64(vm.envOr("REPAYMENT_WINDOW_SECONDS", uint256(DEFAULT_REPAYMENT_WINDOW)));
        uint64 gracePeriod =
            uint64(vm.envOr("DEFAULT_GRACE_SECONDS", uint256(DEFAULT_GRACE_PERIOD)));
        uint16 minReserveBps =
            uint16(vm.envOr("MIN_RESERVE_BPS", uint256(DEFAULT_MIN_RESERVE_BPS)));

        vm.startBroadcast();
        // Deployer is the company (msg.sender), i.e. the single borrower of this pool.
        deployed = new StakeAndAdvance(
            IERC20(usdc), keystoneForwarder, repaymentWindow, gracePeriod, minReserveBps
        );
        vm.stopBroadcast();
    }
}
