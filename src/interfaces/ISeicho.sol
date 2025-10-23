// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

/**
 * @title Seicho Protocol Interfaces
 * @notice Interface definitions for Seicho distribution protocol integration
 * @dev These interfaces are copied from seicho-core to avoid external dependencies
 */

/// @notice Type of registry - either for tactics or vaults
enum RegistryType {
    TACTIC,
    VAULT
}

/// @notice Configuration for vault initialization
struct VaultConfig {
    address[] tactics;
    uint256[] allocations;
    bytes data;
}

/// @notice Configuration for tactic initialization
struct TacticConfig {
    address vault;
    bytes data;
}

/// @notice Base interface for cloneable items (vaults and tactics)
interface IItem {
    function initialize(bytes calldata _data) external;
}

/// @notice Registry for managing vault and tactic implementations
interface IRegistry {
    function register(IItem _item) external;
    function deployClone(uint256 _index, bytes calldata _data) external returns (address);
    function get(uint256 _index) external view returns (IItem);
    function getCount() external view returns (uint256);
    function getType() external view returns (RegistryType);
}

/// @notice Factory for creating distribution strategies (vault + tactics)
interface IStrategyMaker {
    function createStrategy(
        uint256 _vaultIndex,
        bytes calldata _vaultData,
        uint256[] calldata _tacticIndexes,
        uint256[] calldata _allocations,
        bytes[] calldata _tacticDatas
    ) external returns (address, address[] memory);
}

/// @notice Interface for vaults that hold tokens for distribution
interface IVault {
    function withdraw(address _to, uint256 _amount) external returns (bool);
    function balanceOf(address _tactic) external view returns (uint256);
}
