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

library UtopMerkle {
    function verify(
        bytes32 leaf,
        bytes32[] memory proof,
        bytes32 root,
        uint256 index
    ) internal pure returns (bool) {
        bytes32 computed = leaf;
        uint256 ptr = proof.length;
        while (ptr > 0) {
            unchecked {
                ptr--;
            }
            bytes32 sibling = proof[ptr];
            if ((index & 1) == 0) {
                computed = keccak256(abi.encodePacked(computed, sibling));
            } else {
                computed = keccak256(abi.encodePacked(sibling, computed));
            }
            index >>= 1;
        }
        return computed == root;
    }

    function computeRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
        uint256 len = leaves.length;
        if (len == 0) return bytes32(0);
        if (len == 1) return leaves[0];
        while (len > 1) {
            uint256 next = 0;
            for (uint256 i = 0; i < len; i += 2) {
                if (i + 1 < len) {
                    leaves[next] = keccak256(abi.encodePacked(leaves[i], leaves[i + 1]));
                } else {
                    leaves[next] = keccak256(abi.encodePacked(leaves[i], leaves[i]));
                }
                unchecked {
                    next++;
                }
            }
            len = next;
        }
        return leaves[0];
    }

    function emptyKelpRoot() internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(bytes32(0), bytes32(0)));
    }

    function proofDepth(bytes32[] memory proof) internal pure returns (uint256) {
        return proof.length;
    }

    function isSingleLeafRoot(bytes32 leaf, bytes32 root) internal pure returns (bool) {
        return leaf == root;
    }

    function combinePair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        if (uint256(a) <= uint256(b)) {
            return keccak256(abi.encodePacked(a, b));
        }
        return keccak256(abi.encodePacked(b, a));
    }
}

library UtopSonar {
    function encodePulse(
        bytes32 currentId,
        uint64 tideEpoch,
        uint64 pulseSeq,
        uint8 band
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(currentId, tideEpoch, pulseSeq, band));
    }

    function decayScore(uint256 score, uint64 epochsElapsed) internal pure returns (uint256) {
        if (epochsElapsed == 0) return score;
        uint256 penalty = uint256(epochsElapsed) * 3;
        return UtopCodec.saturatingSub(score, penalty);
    }

    function beaconPriority(uint8 beaconType) internal pure returns (uint256) {
        if (beaconType == 0) return 10;
        if (beaconType == 1) return 25;
        if (beaconType == 2) return 50;
        if (beaconType == 3) return 100;
        return 5;
    }
}

library UtopBitmap {
    function get(mapping(uint256 => uint256) storage map, uint256 index) internal view returns (bool) {
        uint256 bucket = index >> 8;
        uint256 bit = 1 << (index & 0xff);
        return (map[bucket] & bit) != 0;
    }

    function set(mapping(uint256 => uint256) storage map, uint256 index) internal {
        uint256 bucket = index >> 8;
        uint256 bit = 1 << (index & 0xff);
        map[bucket] |= bit;
    }

    function clear(mapping(uint256 => uint256) storage map, uint256 index) internal {
        uint256 bucket = index >> 8;
        uint256 bit = 1 << (index & 0xff);
        map[bucket] &= ~bit;
    }

    function flip(mapping(uint256 => uint256) storage map, uint256 index) internal {
        uint256 bucket = index >> 8;
        uint256 bit = 1 << (index & 0xff);
        map[bucket] ^= bit;
    }
}

abstract contract UtopReentrancyShell {
    uint256 private _utopGate;

    modifier utopNonReentrant() {
        if (_utopGate != 0) revert UTOP__Reentrancy();
        _utopGate = 1;
        _;
        _utopGate = 0;
    }
}

contract OceanUTOP is UtopReentrancyShell {
    // ── custom errors ────────────────────────────────────────────────────────
    error UTOP__ZeroAddress();
    error UTOP__ZeroCurrentId();
    error UTOP__ZeroEchoHash();
    error UTOP__ZeroKelpId();
    error UTOP__ZeroPlanktonId();
    error UTOP__PhoticHalted();
    error UTOP__NotTideGovernor();
    error UTOP__NotCurrentOracle();
    error UTOP__NotSonarRelay();
    error UTOP__NotKelpSteward();
    error UTOP__NotPhoticSentinel();
    error UTOP__CurrentAlreadyRegistered();
    error UTOP__CurrentUnknown();
    error UTOP__EchoAlreadyLogged();
    error UTOP__KelpBatchSealed();
    error UTOP__KelpBatchOpen();
    error UTOP__KelpProofInvalid();
    error UTOP__PlanktonCapReached();
    error UTOP__PlanktonDuplicate();
    error UTOP__TideEpochStale();
    error UTOP__TideEpochFuture();
    error UTOP__DepthOutOfRange();
    error UTOP__SalinityOutOfRange();
    error UTOP__ChannelOutOfRange();
    error UTOP__TransferFailed();
    error UTOP__InsufficientAbyssFee();
    error UTOP__WithdrawZero();
    error UTOP__BatchTooLarge();
    error UTOP__ArrayLengthMismatch();
    error UTOP__Reentrancy();
    error UTOP__TokenPullFailed();
    error UTOP__AllowanceLow();
    error UTOP__SonarSinkReject();
    error UTOP__StrataNotArmed();
    error UTOP__StrataAlreadyArmed();
    error UTOP__BeaconCapPerEpoch();
    error UTOP__EchoCapPerCurrent();
    error UTOP__KelpLeafCap();
    error UTOP__BadAsset();
    error UTOP__CooldownActive();
    error UTOP__ScoreBelowFloor();
    error UTOP__UnauthorizedDiver();
    error UTOP__MemoAlreadyAnchored();
    error UTOP__MemoUnknown();
    error UTOP__TierUnknown();
    error UTOP__TierFrozen();
    error UTOP__UndercurrentCap();
    error UTOP__DiverBatchTooLarge();
    error UTOP__KelpLeavesMismatch();
    error UTOP__PlanktonBatchEmpty();
    error UTOP__SnapshotRingFull();

    // ── events ───────────────────────────────────────────────────────────────
