// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Ocean-UTOP — Ultra Tide Oracle Protocol
/// @author codename: abyssal kelp / sonar lattice seven
/// @notice Remix: compiler 0.8.28, optimizer 200 runs, deploy with zero args, then armPhoticStrata(true).
/// @dev Deep-current routing ledger for plankton attestations, kelp merkle batches, and sonar beacon pulses.

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IUTOPSonarSink {
    function onSonarPulse(
        bytes32 currentId,
        bytes32 echoHash,
        address relay,
        uint64 tideEpoch,
        uint64 pulseSeq
    ) external;
}

library UtopCodec {
    uint256 internal constant MASK64 = type(uint64).max;
    uint256 internal constant MASK32 = type(uint32).max;
    uint256 internal constant MASK16 = type(uint16).max;

    function packCurrentMeta(uint32 depth, uint32 salinity, uint16 channel, bool armed) internal pure returns (uint96) {
        uint96 packed = uint96(depth);
        packed |= uint96(salinity) << 32;
        packed |= uint96(channel) << 64;
        if (armed) packed |= uint96(1) << 80;
        return packed;
    }

    function unpackDepth(uint96 meta) internal pure returns (uint32) {
        return uint32(uint256(meta) & MASK32);
    }

    function unpackSalinity(uint96 meta) internal pure returns (uint32) {
        return uint32((uint256(meta) >> 32) & MASK32);
    }

    function unpackChannel(uint96 meta) internal pure returns (uint16) {
        return uint16((uint256(meta) >> 64) & MASK16);
    }

    function unpackArmed(uint96 meta) internal pure returns (bool) {
        return ((uint256(meta) >> 80) & 1) == 1;
    }

    function currentKey(string memory slug, uint32 depth) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("UTOP_CURRENT", slug, depth));
    }

    function echoDigest(
        bytes32 currentId,
        bytes32 payloadHash,
        address diver,
        uint64 tideEpoch,
        uint64 pulseSeq,
        uint64 sonarAt
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(currentId, payloadHash, diver, tideEpoch, pulseSeq, sonarAt));
    }

    function kelpLeaf(bytes32 left, bytes32 right) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(left, right));
    }

    function clampU64(uint256 v, uint64 lo, uint64 hi) internal pure returns (uint64) {
        if (v < lo) return lo;
        if (v > hi) return hi;
        return uint64(v);
    }

    function clampU32(uint256 v, uint32 lo, uint32 hi) internal pure returns (uint32) {
        if (v < lo) return lo;
        if (v > hi) return hi;
        return uint32(v);
    }

    function saturatingSub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    function planktonScore(uint32 depth, uint32 salinity, uint16 channel) internal pure returns (uint256) {
        uint256 base = uint256(depth) * 17 + uint256(salinity) * 11 + uint256(channel) * 23;
        return base ^ (base >> 7);
    }

    function undercurrentMemo(
        bytes32 currentId,
        bytes32 memoHash,
        uint64 tideEpoch
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("UTOP_MEMO", currentId, memoHash, tideEpoch));
    }

    function sonarBeaconKey(bytes32 seed, uint8 beaconType, uint64 tideEpoch) internal pure returns (bytes32) {
        return keccak256(abi.encode(seed, beaconType, tideEpoch, "UTOP_BEACON"));
    }

    function kelpLeafDigest(bytes32 kelpId, bytes32 payload, uint256 index) internal pure returns (bytes32) {
        return keccak256(abi.encode(kelpId, payload, index));
    }

    function mixSalinity(uint32 a, uint32 b) internal pure returns (uint32) {
        return uint32((uint256(a) + uint256(b)) >> 1);
    }

    function depthBand(uint32 depth) internal pure returns (uint8) {
        if (depth < 64) return 1;
        if (depth < 256) return 2;
        if (depth < 1024) return 3;
        if (depth < 2048) return 4;
        return 5;
    }
}
