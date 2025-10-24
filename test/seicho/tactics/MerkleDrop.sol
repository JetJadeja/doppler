// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/proxy/utils/Initializable.sol";
import {BitMaps} from "@openzeppelin/utils/structs/BitMaps.sol";
import {MerkleProof} from "@openzeppelin/utils/cryptography/MerkleProof.sol";

import {IItem, TacticConfig, IVault} from "../core/Interfaces.sol";

struct Config {
    bytes32 merkleRoot;
}

struct MerkleDropStorage {
    IVault bank;
    bytes32 merkleRoot;
    BitMaps.BitMap claimed;
}

contract MerkleDrop is IItem, Initializable {
    using BitMaps for BitMaps.BitMap;

    // Events
    event Initialized(address indexed vault, bytes32 merkleRoot);
    event Claimed(address indexed claimer, uint256 amount, uint256 timestamp);

    MerkleDropStorage internal $tactic;

    constructor() {
        _disableInitializers();
    }

    function initialize(bytes calldata _data) external override(IItem) initializer {
        TacticConfig memory tacticConfig = abi.decode(_data, (TacticConfig));
        Config memory config = abi.decode(tacticConfig.data, (Config));

        $tactic.bank = IVault(tacticConfig.vault);
        $tactic.merkleRoot = config.merkleRoot;

        emit Initialized(address($tactic.bank), $tactic.merkleRoot);
    }

    function claim(address _claimer, uint256 _amount, bytes32[] calldata _proof) external {
        // Only one claim per address!
        require(!$tactic.claimed.get(uint256(uint160(_claimer))), "Already claimed");

        bytes32 leaf = keccak256(abi.encodePacked(_claimer, _amount));
        require(MerkleProof.verify(_proof, $tactic.merkleRoot, leaf), "Invalid proof");

        $tactic.claimed.set(uint256(uint160(_claimer)));
        $tactic.bank.withdraw(_claimer, _amount);

        emit Claimed(_claimer, _amount, block.timestamp);
    }

    function hasClaimed(address _claimer) external view returns (bool) {
        return $tactic.claimed.get(uint256(uint160(_claimer)));
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Returns the merkle root used for claim validation
     * @return The merkle root hash
     */
    function getMerkleRoot() external view returns (bytes32) {
        return $tactic.merkleRoot;
    }

    /**
     * @notice Returns the vault address that holds tokens for this tactic
     * @return The address of the vault
     */
    function getVault() external view returns (address) {
        return address($tactic.bank);
    }
}
