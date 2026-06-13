// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

interface Vm {
    function prank(address msgSender) external;
    function startPrank(address msgSender) external;
    function stopPrank() external;
    function expectRevert(bytes4 revertData) external;
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData)
        external;
    function warp(uint256 newTimestamp) external;
    function sign(uint256 privateKey, bytes32 digest)
        external
        pure
        returns (uint8 v, bytes32 r, bytes32 s);
    function addr(uint256 privateKey) external pure returns (address keyAddr);
    function expectRevert() external;
}

contract TestBase {
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    function assertEq(uint256 actual, uint256 expected, string memory label) internal pure {
        if (actual != expected) {
            revert(string.concat(label, ": uint mismatch"));
        }
    }

    function assertEq(address actual, address expected, string memory label) internal pure {
        if (actual != expected) {
            revert(string.concat(label, ": address mismatch"));
        }
    }

    function assertEq(bool actual, bool expected, string memory label) internal pure {
        if (actual != expected) {
            revert(string.concat(label, ": bool mismatch"));
        }
    }
}
