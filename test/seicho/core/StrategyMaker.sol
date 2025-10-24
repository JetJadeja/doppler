// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IRegistry, IItem, VaultConfig, TacticConfig, IStrategyMaker} from "./Interfaces.sol";

contract StrategyMaker is IStrategyMaker {
    // Custom Errors
    error NoTacticsProvided();
    error TacticAllocationMismatch();
    error TacticDataMismatch();
    error ZeroTotalAllocation();

    // Events
    event StrategyCreated(address indexed vault, address[] tactics, uint256[] allocations);

    IRegistry internal immutable TACTIC_REGISTRY;
    IRegistry internal immutable VAULT_REGISTRY;

    constructor(IRegistry _tacticRegistry, IRegistry _vaultRegistry) {
        TACTIC_REGISTRY = _tacticRegistry;
        VAULT_REGISTRY = _vaultRegistry;
    }

    function createStrategy(
        uint256 _vaultIndex,
        bytes calldata _vaultData,
        uint256[] calldata _tacticIndexes,
        uint256[] calldata _allocations,
        bytes[] calldata _tacticDatas
    ) external override(IStrategyMaker) returns (address, address[] memory) {
        // Input validation: Ensure at least one tactic is provided
        if (_tacticIndexes.length == 0) revert NoTacticsProvided();

        // Input validation: Ensure array lengths match
        if (_tacticIndexes.length != _allocations.length) revert TacticAllocationMismatch();
        if (_tacticIndexes.length != _tacticDatas.length) revert TacticDataMismatch();

        // Input validation: Ensure total allocation is non-zero to prevent division by zero
        uint256 totalAllocation;
        for (uint256 i = 0; i < _allocations.length; i++) {
            totalAllocation += _allocations[i];
        }
        if (totalAllocation == 0) revert ZeroTotalAllocation();

        // Deploy vault and tactics
        IItem vault = IItem(VAULT_REGISTRY.deployClone(_vaultIndex, ""));

        address[] memory tactics = new address[](_tacticIndexes.length);
        for (uint256 i = 0; i < _tacticIndexes.length; i++) {
            bytes memory tacticData = abi.encode(TacticConfig({vault: address(vault), data: _tacticDatas[i]}));
            tactics[i] = TACTIC_REGISTRY.deployClone(_tacticIndexes[i], tacticData);
        }

        bytes memory vaultData =
            abi.encode(VaultConfig({tactics: tactics, allocations: _allocations, data: _vaultData}));
        vault.initialize(vaultData);

        emit StrategyCreated(address(vault), tactics, _allocations);

        return (address(vault), tactics);
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Returns the address of the TacticRegistry used by this StrategyMaker
     * @return Address of the TacticRegistry contract
     */
    function getTacticRegistry() external view returns (address) {
        return address(TACTIC_REGISTRY);
    }

    /**
     * @notice Returns the address of the VaultRegistry used by this StrategyMaker
     * @return Address of the VaultRegistry contract
     */
    function getVaultRegistry() external view returns (address) {
        return address(VAULT_REGISTRY);
    }
}
