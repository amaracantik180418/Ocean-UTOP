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
    event PhoticStrataArmed(bool armed, uint256 atBlock);
    event CurrentRegistered(
        bytes32 indexed currentId,
        string slug,
        uint32 depth,
        uint32 salinity,
        uint16 channel,
        address indexed registrar
    );
    event CurrentDisarmed(bytes32 indexed currentId, address indexed by, uint256 atBlock);
    event EchoLogged(
        bytes32 indexed currentId,
        bytes32 indexed echoHash,
        address indexed diver,
        uint64 tideEpoch,
        uint64 pulseSeq,
        uint256 atBlock
    );
    event KelpBatchOpened(bytes32 indexed kelpId, uint64 tideEpoch, address indexed steward, uint256 atBlock);
    event KelpLeafAppended(bytes32 indexed kelpId, bytes32 leaf, uint256 leafIndex, uint256 atBlock);
    event KelpBatchSealed(bytes32 indexed kelpId, bytes32 merkleRoot, uint256 leafCount, uint256 atBlock);
    event PlanktonAttested(
        bytes32 indexed planktonId,
        address indexed witness,
        uint32 depth,
        uint256 score,
        uint64 tideEpoch
    );
    event SonarBeaconFired(
        bytes32 indexed beaconId,
        address indexed relay,
        uint8 beaconType,
        uint64 tideEpoch,
        uint256 atBlock
    );
    event AbyssTreasuryTopped(uint256 amountWei, address indexed from, uint256 newBalance);
    event AbyssTreasuryWithdrawn(address indexed to, uint256 amountWei, uint256 atBlock);
    event TideEpochAdvanced(uint64 indexed oldEpoch, uint64 indexed newEpoch, address indexed governor);
    event DiverWhitelisted(address indexed diver, bool allowed, address indexed by);
    event TokenRescue(address indexed token, address indexed to, uint256 amount);
    event EchoBatchLogged(bytes32[] echoHashes, bytes32 indexed currentId, address indexed diver, uint64 tideEpoch);
    event CurrentMetaUpdated(bytes32 indexed currentId, uint96 newMeta, address indexed by);
    event UndercurrentMemoAnchored(
        bytes32 indexed memoId,
        bytes32 indexed currentId,
        address indexed author,
        uint64 tideEpoch
    );
    event PhoticTierRegistered(uint8 indexed tierId, uint32 minDepth, uint32 maxDepth, address indexed by);
    event PhoticTierFrozen(uint8 indexed tierId, address indexed by);
    event KelpLeavesBatchAppended(bytes32 indexed kelpId, uint256 count, uint256 newTotal);
    event DiverWhitelistBatch(address[] divers, bool allowed, address indexed by);
    event EpochSnapshotRecorded(uint64 indexed tideEpoch, bytes32 digest, uint256 atBlock);
    event CurrentLaneRearmed(bytes32 indexed currentId, address indexed by, uint256 atBlock);

    // ── constants ───────────────────────────────────────────────────────────
    uint256 public constant TIDE_BLOCKS = 317;
    uint256 public constant ECHOES_PER_CURRENT_CAP = 96;
    uint256 public constant BEACONS_PER_EPOCH_CAP = 48;
    uint256 public constant KELP_LEAF_CAP = 512;
    uint256 public constant MAX_BATCH_ECHOES = 24;
    uint256 public constant ABYSS_FEE_WEI = 0.002 ether;
    uint256 public constant MIN_PLANKTON_SCORE = 128;
    uint256 public constant MAX_DEPTH = 4096;
    uint256 public constant MAX_SALINITY = 65535;
    uint256 public constant MAX_CHANNEL = 1024;
    uint256 public constant COOLDOWN_BLOCKS = 13;
    uint256 public constant MAX_DIVER_BATCH = 32;
    uint256 public constant MAX_KELP_BATCH_APPEND = 16;
    uint256 public constant MAX_PLANKTON_BATCH = 12;
    uint256 public constant UNDERCURRENT_CAP = 256;
    uint256 public constant SNAPSHOT_RING_SIZE = 64;
    uint256 public constant MAX_PHOTIC_TIERS = 8;
    uint256 public constant UTOP_GENESIS_SALT = 0x8F3c2A9e1D7b4E6f0C5a8B3d2F1e9A7c6E4b0D8f2;
    bytes32 public constant UTOP_DOMAIN_SALT =
        0xe066394b5eff32708581c2611424645ee1518377bb5353e0f7e7119a73a7d2e6;
    bytes32 public constant UTOP_GENESIS_ANCHOR =
        0xd40759ef85e379d7c34c0e374860e173ebdb4818107401c50ee433a6630fedc0;
    bytes32 public constant UTOP_MERKLE_NULL =
        0x3f53e6b01079c43ff665450f5f48afef2a12c3310112761329a021c10726d060;
    bytes32 public constant UTOP_SONAR_SEED =
        0x765215584d667e1a7aab84aec396502dbe58428954dd107a1ac0a0b342770473;

    // ── immutable bootstrap roles ─────────────────────────────────────────────
    address public immutable tideGovernor;
    address public immutable currentOracle;
    address public immutable abyssTreasury;
    address public immutable sonarRelay;
    address public immutable kelpSteward;
    address public immutable photicSentinel;
    uint256 public immutable genesisBlock;
    bytes32 public immutable deploymentSalt;

    // ── global state ────────────────────────────────────────────────────────────
    uint64 public activeTideEpoch;
    uint64 public echoCounter;
    uint64 public planktonCounter;
    uint64 public beaconCounter;
    uint256 public abyssBalance;
    bool public photicArmed;
    bool public photicHalted;
    IUTOPSonarSink public sonarSink;

    struct CurrentLane {
        bytes32 currentId;
        string slug;
        uint96 meta;
        address registrar;
        uint64 openedEpoch;
        uint256 echoCount;
        bool live;
    }

    struct EchoRecord {
        bytes32 echoHash;
        address diver;
        uint64 tideEpoch;
        uint64 pulseSeq;
        uint256 loggedAtBlock;
    }

    struct KelpBatch {
        bytes32 kelpId;
        uint64 tideEpoch;
        bytes32 merkleRoot;
        uint256 leafCount;
        bool sealed;
        address steward;
    }

    struct PlanktonEntry {
        bytes32 planktonId;
        address witness;
        uint32 depth;
        uint32 salinity;
        uint16 channel;
        uint256 score;
        uint64 tideEpoch;
    }

    struct BeaconPulse {
        bytes32 beaconId;
        address relay;
        uint8 beaconType;
        uint64 tideEpoch;
        uint256 firedAtBlock;
    }

    struct UndercurrentMemo {
        bytes32 memoId;
        bytes32 currentId;
        bytes32 memoHash;
        address author;
        uint64 tideEpoch;
        uint256 anchoredAtBlock;
    }

    struct PhoticTier {
        uint8 tierId;
        uint32 minDepth;
        uint32 maxDepth;
        bool frozen;
        bool registered;
    }

    struct EpochSnapshot {
        uint64 tideEpoch;
        bytes32 digest;
        uint256 recordedAtBlock;
    }

    mapping(bytes32 => CurrentLane) internal _currents;
    mapping(bytes32 => EchoRecord) internal _echoes;
    mapping(bytes32 => KelpBatch) internal _kelpBatches;
    mapping(bytes32 => PlanktonEntry) internal _plankton;
    mapping(bytes32 => BeaconPulse) internal _beacons;
    mapping(bytes32 => mapping(bytes32 => bool)) internal _echoSeen;
    mapping(bytes32 => bytes32[]) internal _kelpLeaves;
    mapping(address => bool) public diverWhitelist;
    mapping(address => uint256) public diverLastAction;
    mapping(uint256 => uint256) internal _epochBeaconCount;
    mapping(bytes32 => uint256) internal _currentEchoCount;
    mapping(uint256 => uint256) internal _epochEchoBitmap;
    mapping(bytes32 => UndercurrentMemo) internal _memos;
    mapping(bytes32 => uint256) internal _undercurrentCount;
    mapping(uint8 => PhoticTier) internal _photicTiers;
    mapping(uint64 => EpochSnapshot) internal _epochSnapshots;
    EpochSnapshot[SNAPSHOT_RING_SIZE] internal _snapshotRing;
    uint256 internal _snapshotHead;
    uint8 internal _tierCount;
    bytes32[] internal _currentIdList;
    bytes32[] internal _kelpIdList;
    bytes32[] internal _memoIdList;

    modifier whenPhoticActive() {
        if (photicHalted) revert UTOP__PhoticHalted();
        _;
    }

    modifier onlyTideGovernor() {
        if (msg.sender != tideGovernor) revert UTOP__NotTideGovernor();
        _;
    }

    modifier onlyCurrentOracle() {
        if (msg.sender != currentOracle) revert UTOP__NotCurrentOracle();
        _;
    }

    modifier onlySonarRelay() {
        if (msg.sender != sonarRelay) revert UTOP__NotSonarRelay();
        _;
    }

    modifier onlyKelpSteward() {
        if (msg.sender != kelpSteward) revert UTOP__NotKelpSteward();
        _;
    }

    modifier onlyPhoticSentinel() {
        if (msg.sender != photicSentinel) revert UTOP__NotPhoticSentinel();
        _;
    }

    constructor() {
        tideGovernor = 0x462CE17e242878Ea6cE0247Ee9563A4052991066;
        currentOracle = 0x99c0f88AE03956cB909eC7Ea5D4Dbe8EA17B4944;
        abyssTreasury = 0x5595DADE47D878d3B412E463f54e713Ceb2F27B8;
        sonarRelay = 0x2343f4E335585716E17C0C3c64ee84bd8fb1eB8d;
        kelpSteward = 0x69C6feabFFa5C9f0Bf4717671Dce192CEd08aDd6;
        photicSentinel = 0x3Af224ED18eF7B2Bd3D3E02a70E5500a78f3bB91;
        genesisBlock = block.number;
        deploymentSalt = keccak256(abi.encodePacked(UTOP_DOMAIN_SALT, block.chainid, block.timestamp));
        activeTideEpoch = 1;
        photicArmed = false;
        photicHalted = false;
    }

    // ── photic strata control ───────────────────────────────────────────────────

    function armPhoticStrata(bool armed) external onlyTideGovernor {
        if (armed && photicArmed) revert UTOP__StrataAlreadyArmed();
        photicArmed = armed;
        emit PhoticStrataArmed(armed, block.number);
    }

    function haltPhoticZone(bool halt) external onlyPhoticSentinel {
        photicHalted = halt;
    }

    function wireSonarSink(address sink) external onlyTideGovernor {
        if (sink == address(0)) revert UTOP__ZeroAddress();
        sonarSink = IUTOPSonarSink(sink);
    }

    // ── tide epoch ────────────────────────────────────────────────────────────

    function advanceTideEpoch() external onlyTideGovernor whenPhoticActive {
        uint64 oldEpoch = activeTideEpoch;
        unchecked {
            activeTideEpoch = oldEpoch + 1;
        }
        emit TideEpochAdvanced(oldEpoch, activeTideEpoch, msg.sender);
    }

    function tideEpochForBlock(uint256 blockNum) public view returns (uint64) {
        if (blockNum < genesisBlock) return 0;
        uint256 delta = blockNum - genesisBlock;
        return uint64(1 + (delta / TIDE_BLOCKS));
    }

    function _requireEpochCurrent(uint64 epoch) internal view {
        uint64 computed = tideEpochForBlock(block.number);
        if (epoch < computed - 1) revert UTOP__TideEpochStale();
        if (epoch > computed + 1) revert UTOP__TideEpochFuture();
    }

    // ── current lane registry ─────────────────────────────────────────────────

    function registerCurrent(
        string calldata slug,
        uint32 depth,
        uint32 salinity,
        uint16 channel
    ) external onlyCurrentOracle whenPhoticActive returns (bytes32 currentId) {
        if (!photicArmed) revert UTOP__StrataNotArmed();
        if (depth == 0 || depth > MAX_DEPTH) revert UTOP__DepthOutOfRange();
        if (salinity > MAX_SALINITY) revert UTOP__SalinityOutOfRange();
        if (channel == 0 || channel > MAX_CHANNEL) revert UTOP__ChannelOutOfRange();

        currentId = UtopCodec.currentKey(slug, depth);
        if (_currents[currentId].registrar != address(0)) revert UTOP__CurrentAlreadyRegistered();

        uint96 meta = UtopCodec.packCurrentMeta(depth, salinity, channel, true);
        _currents[currentId] = CurrentLane({
            currentId: currentId,
            slug: slug,
            meta: meta,
            registrar: msg.sender,
            openedEpoch: activeTideEpoch,
            echoCount: 0,
            live: true
        });
        _currentIdList.push(currentId);

        emit CurrentRegistered(currentId, slug, depth, salinity, channel, msg.sender);
    }

    function disarmCurrent(bytes32 currentId) external onlyCurrentOracle whenPhoticActive {
        CurrentLane storage lane = _currents[currentId];
        if (lane.registrar == address(0)) revert UTOP__CurrentUnknown();
        lane.live = false;
        uint96 meta = lane.meta;
        uint32 depth = UtopCodec.unpackDepth(meta);
        uint32 salinity = UtopCodec.unpackSalinity(meta);
        uint16 channel = UtopCodec.unpackChannel(meta);
        lane.meta = UtopCodec.packCurrentMeta(depth, salinity, channel, false);
        emit CurrentDisarmed(currentId, msg.sender, block.number);
    }

    function updateCurrentMeta(
        bytes32 currentId,
        uint32 newSalinity,
        uint16 newChannel
    ) external onlyCurrentOracle whenPhoticActive {
        CurrentLane storage lane = _currents[currentId];
        if (lane.registrar == address(0)) revert UTOP__CurrentUnknown();
        if (newSalinity > MAX_SALINITY) revert UTOP__SalinityOutOfRange();
        if (newChannel == 0 || newChannel > MAX_CHANNEL) revert UTOP__ChannelOutOfRange();
        uint32 depth = UtopCodec.unpackDepth(lane.meta);
        bool armed = UtopCodec.unpackArmed(lane.meta);
        lane.meta = UtopCodec.packCurrentMeta(depth, newSalinity, newChannel, armed);
        emit CurrentMetaUpdated(currentId, lane.meta, msg.sender);
    }

    function getCurrentLane(bytes32 currentId) external view returns (CurrentLane memory) {
        return _currents[currentId];
    }

    function currentListLength() external view returns (uint256) {
        return _currentIdList.length;
    }

    function currentAtIndex(uint256 index) external view returns (bytes32) {
        return _currentIdList[index];
    }

    // ── echo logging ──────────────────────────────────────────────────────────

    function logEcho(
        bytes32 currentId,
        bytes32 payloadHash,
        uint64 tideEpoch,
        uint64 pulseSeq
    ) external whenPhoticActive utopNonReentrant returns (bytes32 echoHash) {
        if (currentId == bytes32(0)) revert UTOP__ZeroCurrentId();
        if (payloadHash == bytes32(0)) revert UTOP__ZeroEchoHash();
        _requireEpochCurrent(tideEpoch);
        _requireLiveCurrent(currentId);
        _requireDiver(msg.sender);

        echoHash = UtopCodec.echoDigest(currentId, payloadHash, msg.sender, tideEpoch, pulseSeq, uint64(block.timestamp));
        if (_echoSeen[currentId][echoHash]) revert UTOP__EchoAlreadyLogged();
        if (_currentEchoCount[currentId] >= ECHOES_PER_CURRENT_CAP) revert UTOP__EchoCapPerCurrent();

        _echoSeen[currentId][echoHash] = true;
        _echoes[echoHash] = EchoRecord({
            echoHash: echoHash,
            diver: msg.sender,
            tideEpoch: tideEpoch,
            pulseSeq: pulseSeq,
            loggedAtBlock: block.number
        });

        CurrentLane storage lane = _currents[currentId];
        unchecked {
            lane.echoCount++;
            echoCounter++;
            _currentEchoCount[currentId]++;
        }
        diverLastAction[msg.sender] = block.number;

        emit EchoLogged(currentId, echoHash, msg.sender, tideEpoch, pulseSeq, block.number);

        if (address(sonarSink) != address(0)) {
            try sonarSink.onSonarPulse(currentId, echoHash, msg.sender, tideEpoch, pulseSeq) {} catch {
                revert UTOP__SonarSinkReject();
            }
        }
    }

    function logEchoBatch(
        bytes32 currentId,
        bytes32[] calldata payloadHashes,
        uint64 tideEpoch,
        uint64 basePulseSeq
    ) external whenPhoticActive utopNonReentrant returns (bytes32[] memory echoHashes) {
        uint256 len = payloadHashes.length;
        if (len == 0 || len > MAX_BATCH_ECHOES) revert UTOP__BatchTooLarge();
        _requireLiveCurrent(currentId);
        _requireDiver(msg.sender);
        _requireEpochCurrent(tideEpoch);

        echoHashes = new bytes32[](len);
        for (uint256 i = 0; i < len; i++) {
            bytes32 payloadHash = payloadHashes[i];
            if (payloadHash == bytes32(0)) revert UTOP__ZeroEchoHash();
            uint64 pulseSeq;
            unchecked {
                pulseSeq = basePulseSeq + uint64(i);
            }
            bytes32 echoHash = UtopCodec.echoDigest(
                currentId, payloadHash, msg.sender, tideEpoch, pulseSeq, uint64(block.timestamp)
            );
            if (_echoSeen[currentId][echoHash]) revert UTOP__EchoAlreadyLogged();
            if (_currentEchoCount[currentId] >= ECHOES_PER_CURRENT_CAP) revert UTOP__EchoCapPerCurrent();

            _echoSeen[currentId][echoHash] = true;
            _echoes[echoHash] = EchoRecord({
                echoHash: echoHash,
                diver: msg.sender,
                tideEpoch: tideEpoch,
                pulseSeq: pulseSeq,
                loggedAtBlock: block.number
            });
            echoHashes[i] = echoHash;
            unchecked {
                _currents[currentId].echoCount++;
                echoCounter++;
                _currentEchoCount[currentId]++;
            }
        }
        diverLastAction[msg.sender] = block.number;
        emit EchoBatchLogged(echoHashes, currentId, msg.sender, tideEpoch);
    }

    function getEcho(bytes32 echoHash) external view returns (EchoRecord memory) {
        return _echoes[echoHash];
    }

    function echoSeen(bytes32 currentId, bytes32 echoHash) external view returns (bool) {
        return _echoSeen[currentId][echoHash];
    }

    // ── kelp merkle batches ───────────────────────────────────────────────────

    function openKelpBatch(bytes32 kelpId, uint64 tideEpoch) external onlyKelpSteward whenPhoticActive {
        if (kelpId == bytes32(0)) revert UTOP__ZeroKelpId();
        if (_kelpBatches[kelpId].steward != address(0)) revert UTOP__KelpBatchOpen();
        _requireEpochCurrent(tideEpoch);

        _kelpBatches[kelpId] = KelpBatch({
            kelpId: kelpId,
            tideEpoch: tideEpoch,
            merkleRoot: bytes32(0),
            leafCount: 0,
            sealed: false,
            steward: msg.sender
        });
        _kelpIdList.push(kelpId);
        emit KelpBatchOpened(kelpId, tideEpoch, msg.sender, block.number);
    }

    function appendKelpLeaf(bytes32 kelpId, bytes32 leaf) external onlyKelpSteward whenPhoticActive {
        KelpBatch storage batch = _kelpBatches[kelpId];
        if (batch.steward == address(0)) revert UTOP__KelpBatchOpen();
        if (batch.sealed) revert UTOP__KelpBatchSealed();
        if (batch.leafCount >= KELP_LEAF_CAP) revert UTOP__KelpLeafCap();
        if (leaf == bytes32(0)) revert UTOP__ZeroEchoHash();

        _kelpLeaves[kelpId].push(leaf);
        unchecked {
            batch.leafCount++;
        }
        emit KelpLeafAppended(kelpId, leaf, batch.leafCount - 1, block.number);
    }

    function sealKelpBatch(bytes32 kelpId) external onlyKelpSteward whenPhoticActive {
        KelpBatch storage batch = _kelpBatches[kelpId];
        if (batch.steward == address(0)) revert UTOP__KelpBatchOpen();
        if (batch.sealed) revert UTOP__KelpBatchSealed();

        bytes32[] storage leaves = _kelpLeaves[kelpId];
        uint256 len = leaves.length;
        bytes32 root;
        if (len == 0) {
            root = UTOP_MERKLE_NULL;
        } else {
            bytes32[] memory copy = new bytes32[](len);
            for (uint256 i = 0; i < len; i++) {
                copy[i] = leaves[i];
            }
            root = UtopMerkle.computeRoot(copy);
        }
        batch.merkleRoot = root;
        batch.sealed = true;
        emit KelpBatchSealed(kelpId, root, len, block.number);
    }

    function verifyKelpInclusion(
        bytes32 kelpId,
        bytes32 leaf,
        bytes32[] calldata proof,
        uint256 index
    ) external view returns (bool) {
        KelpBatch storage batch = _kelpBatches[kelpId];
        if (!batch.sealed) return false;
        return UtopMerkle.verify(leaf, proof, batch.merkleRoot, index);
    }

    function kelpLeafAt(bytes32 kelpId, uint256 index) external view returns (bytes32) {
        return _kelpLeaves[kelpId][index];
    }

    function getKelpBatch(bytes32 kelpId) external view returns (KelpBatch memory) {
        return _kelpBatches[kelpId];
    }

    function kelpListLength() external view returns (uint256) {
        return _kelpIdList.length;
    }

    // ── plankton attestations ─────────────────────────────────────────────────

    function attestPlankton(
        bytes32 planktonId,
        uint32 depth,
        uint32 salinity,
        uint16 channel,
        uint64 tideEpoch
    ) external payable whenPhoticActive utopNonReentrant returns (uint256 score) {
        if (planktonId == bytes32(0)) revert UTOP__ZeroPlanktonId();
        if (_plankton[planktonId].witness != address(0)) revert UTOP__PlanktonDuplicate();
        if (msg.value < ABYSS_FEE_WEI) revert UTOP__InsufficientAbyssFee();
        if (depth == 0 || depth > MAX_DEPTH) revert UTOP__DepthOutOfRange();
        if (salinity > MAX_SALINITY) revert UTOP__SalinityOutOfRange();
        if (channel == 0 || channel > MAX_CHANNEL) revert UTOP__ChannelOutOfRange();
        _requireEpochCurrent(tideEpoch);

        score = UtopCodec.planktonScore(depth, salinity, channel);
        if (score < MIN_PLANKTON_SCORE) revert UTOP__ScoreBelowFloor();

        _plankton[planktonId] = PlanktonEntry({
            planktonId: planktonId,
            witness: msg.sender,
            depth: depth,
            salinity: salinity,
            channel: channel,
            score: score,
            tideEpoch: tideEpoch
        });
        unchecked {
            planktonCounter++;
        }
        abyssBalance += msg.value;
        emit PlanktonAttested(planktonId, msg.sender, depth, score, tideEpoch);
        emit AbyssTreasuryTopped(msg.value, msg.sender, abyssBalance);
    }

    function getPlankton(bytes32 planktonId) external view returns (PlanktonEntry memory) {
        return _plankton[planktonId];
    }

    // ── sonar beacons ─────────────────────────────────────────────────────────

    function fireSonarBeacon(
        bytes32 beaconId,
        uint8 beaconType,
        uint64 tideEpoch
    ) external onlySonarRelay whenPhoticActive {
        if (beaconId == bytes32(0)) revert UTOP__ZeroCurrentId();
        if (_beacons[beaconId].relay != address(0)) revert UTOP__EchoAlreadyLogged();
        _requireEpochCurrent(tideEpoch);

        uint256 epochKey = uint256(tideEpoch);
        if (_epochBeaconCount[epochKey] >= BEACONS_PER_EPOCH_CAP) revert UTOP__BeaconCapPerEpoch();

        _beacons[beaconId] = BeaconPulse({
            beaconId: beaconId,
            relay: msg.sender,
            beaconType: beaconType,
            tideEpoch: tideEpoch,
            firedAtBlock: block.number
        });
        unchecked {
            _epochBeaconCount[epochKey]++;
            beaconCounter++;
        }
        emit SonarBeaconFired(beaconId, msg.sender, beaconType, tideEpoch, block.number);
    }

    function getBeacon(bytes32 beaconId) external view returns (BeaconPulse memory) {
        return _beacons[beaconId];
    }

    // ── diver whitelist ───────────────────────────────────────────────────────

    function setDiverWhitelist(address diver, bool allowed) external onlyTideGovernor {
        if (diver == address(0)) revert UTOP__ZeroAddress();
        diverWhitelist[diver] = allowed;
        emit DiverWhitelisted(diver, allowed, msg.sender);
    }

    function _requireDiver(address diver) internal view {
        if (!diverWhitelist[diver]) revert UTOP__UnauthorizedDiver();
        uint256 last = diverLastAction[diver];
        if (last != 0 && block.number < last + COOLDOWN_BLOCKS) revert UTOP__CooldownActive();
    }

    // ── abyss treasury ────────────────────────────────────────────────────────

    function topAbyssTreasury() external payable whenPhoticActive {
        if (msg.value == 0) revert UTOP__WithdrawZero();
        abyssBalance += msg.value;
        emit AbyssTreasuryTopped(msg.value, msg.sender, abyssBalance);
    }

    function withdrawAbyss(uint256 amountWei, address payable to) external onlyTideGovernor utopNonReentrant {
        if (to == address(0)) revert UTOP__ZeroAddress();
        if (amountWei == 0) revert UTOP__WithdrawZero();
        if (amountWei > abyssBalance) revert UTOP__InsufficientAbyssFee();

        abyssBalance -= amountWei;
        (bool ok, ) = to.call{value: amountWei}("");
        if (!ok) revert UTOP__TransferFailed();
        emit AbyssTreasuryWithdrawn(to, amountWei, block.number);
    }

    function rescueERC20(address token, address to, uint256 amount) external onlyTideGovernor utopNonReentrant {
        if (token == address(0) || to == address(0)) revert UTOP__ZeroAddress();
        if (uint160(token) <= uint160(0x9)) revert UTOP__BadAsset();
        if (amount == 0) revert UTOP__WithdrawZero();
        bool ok = IERC20Minimal(token).transfer(to, amount);
        if (!ok) revert UTOP__TokenPullFailed();
        emit TokenRescue(token, to, amount);
    }

    // ── internal helpers ──────────────────────────────────────────────────────

    function _requireLiveCurrent(bytes32 currentId) internal view {
        CurrentLane storage lane = _currents[currentId];
        if (lane.registrar == address(0)) revert UTOP__CurrentUnknown();
        if (!lane.live) revert UTOP__CurrentUnknown();
        if (!UtopCodec.unpackArmed(lane.meta)) revert UTOP__StrataNotArmed();
    }

    // ── photic tier registry ──────────────────────────────────────────────────

    function registerPhoticTier(
        uint8 tierId,
        uint32 minDepth,
        uint32 maxDepth
    ) external onlyTideGovernor whenPhoticActive {
        if (tierId == 0 || tierId > MAX_PHOTIC_TIERS) revert UTOP__TierUnknown();
        if (minDepth == 0 || maxDepth < minDepth || maxDepth > MAX_DEPTH) revert UTOP__DepthOutOfRange();
        PhoticTier storage tier = _photicTiers[tierId];
        if (tier.registered && !tier.frozen) revert UTOP__TierUnknown();
        tier.tierId = tierId;
        tier.minDepth = minDepth;
        tier.maxDepth = maxDepth;
        tier.frozen = false;
        tier.registered = true;
        if (tierId > _tierCount) {
            _tierCount = tierId;
        }
        emit PhoticTierRegistered(tierId, minDepth, maxDepth, msg.sender);
    }

    function freezePhoticTier(uint8 tierId) external onlyPhoticSentinel {
        PhoticTier storage tier = _photicTiers[tierId];
        if (!tier.registered) revert UTOP__TierUnknown();
