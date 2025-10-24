// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";

/**
 * @title Token Factory Interface
 * @notice Contracts deploying new asset token must implement this interface.
 */
interface ITokenFactory {
    /**
     * @notice Emitted when a distribution strategy is created for a token
     * @param token Address of the token being distributed
     * @param vault Address of the created vault holding the distribution tokens
     * @param tactics Array of tactic addresses deployed for this distribution
     * @param amount Amount of tokens allocated to this distribution
     */
    event DistributionCreated(address indexed token, address indexed vault, address[] tactics, uint256 amount);

    /**
     * @notice BankMan vault configuration structure
     * @dev Must exactly match Config struct in BankMan.sol (seicho-core/src/vaults/BankMan.sol:24-26)
     * @param token The ERC20 token that this vault will distribute
     */
    struct BankManConfig {
        IERC20 token;
    }

    /**
     * @notice Configuration for a single distribution strategy
     * @param amount Tokens allocated to this distribution (in token base units)
     * @param vaultIndex Index in Seicho VaultRegistry for vault implementation
     * @param vaultData Encoded vault configuration (should contain placeholder address(0) for token address)
     * @param tacticIndexes Array of indices in Seicho TacticRegistry (must match allocations/tacticDatas length)
     * @param allocations Array of allocation weights for tactics (must match tacticIndexes/tacticDatas length)
     * @param tacticDatas Array of tactic-specific configurations (must match tacticIndexes/allocations length)
     */
    struct DistributionData {
        uint256 amount;
        uint256 vaultIndex;
        bytes vaultData;
        uint256[] tacticIndexes;
        uint256[] allocations;
        bytes[] tacticDatas;
    }

    /**
     * @notice Deploys a new asset token.
     * @param initialSupply Initial supply that will be minted
     * @param recipient Address receiving the initial supply
     * @param owner Address receiving the ownership of the token
     * @param tokenData Extra data to be used by the factory
     * @param salt Salt used in create2 deployment to determine contract address
     * @return Address of the newly deployed token
     */
    function create(
        uint256 initialSupply,
        address recipient,
        address owner,
        bytes32 salt,
        bytes calldata tokenData
    ) external returns (address);
}
