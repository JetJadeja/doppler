// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Initializable} from "@openzeppelin/proxy/utils/Initializable.sol";
import {ECDSA} from "@openzeppelin/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/utils/cryptography/EIP712.sol";
import {MessageHashUtils} from "@openzeppelin/utils/cryptography/MessageHashUtils.sol";
import {BitMaps} from "@openzeppelin/utils/structs/BitMaps.sol";
import {IItem, TacticConfig, IVault} from "../core/Interfaces.sol";

struct Config {
    address bro;
    uint96 claimSize;
}

struct TrustMeBroStorage {
    IVault bank;
    address bro;
    uint96 claimSize;
    BitMaps.BitMap claimed;
}

/**
 * @title Trust Me Bro, First Come First Served
 * @notice  A first-come-first-served strategy for the distribution of incentives
 *          The only requirement is that we have a valid signature from the trust me bro
 *          and haven't claimed yet.
 */
contract TrustMeBro is IItem, Initializable, EIP712 {
    using BitMaps for BitMaps.BitMap;

    bytes32 public constant CLAIM_TYPEHASH = keccak256("claim(address claimant)");

    TrustMeBroStorage internal $tactic;

    constructor() EIP712("TrustMeBro", "1") {
        _disableInitializers();
    }

    function initialize(bytes calldata _data) external override(IItem) initializer {
        TacticConfig memory tacticConfig = abi.decode(_data, (TacticConfig));
        Config memory config = abi.decode(tacticConfig.data, (Config));

        $tactic.bank = IVault(tacticConfig.vault);
        $tactic.bro = config.bro;
        $tactic.claimSize = config.claimSize;
    }

    function claim(address _claimant, bytes calldata _signature) external {
        require(!$tactic.claimed.get(uint256(uint160(_claimant))), "Already claimed");

        bytes32 message = getClaimMessage(_claimant);
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(message);
        address recovered = ECDSA.recover(digest, _signature);

        // And bro said; "trust me"
        require(recovered == $tactic.bro, "Invalid signature");

        $tactic.claimed.set(uint256(uint160(_claimant)));

        $tactic.bank.withdraw(_claimant, $tactic.claimSize);
    }

    function getClaimSize() external view returns (uint256) {
        return uint256($tactic.claimSize);
    }

    function getClaimMessage(address _claimant) public view returns (bytes32) {
        return _hashTypedDataV4(keccak256(abi.encode(CLAIM_TYPEHASH, _claimant)));
    }
}
