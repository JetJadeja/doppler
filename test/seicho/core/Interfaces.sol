// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

enum RegistryType {
    TACTIC,
    VAULT
}

struct VaultConfig {
    address[] tactics;
    uint256[] allocations;
    bytes data;
}

struct TacticConfig {
    address vault;
    bytes data;
}

interface IItem {
    function initialize(bytes calldata _data) external;
}

interface IRegistry {
    function register(IItem _item) external;
    function deployClone(uint256 _index, bytes calldata _data) external returns (address);
    function get(uint256 _index) external view returns (IItem);
    function getCount() external view returns (uint256);
    function getType() external view returns (RegistryType);
}

interface IStrategyMaker {
    function createStrategy(
        uint256 _vaultIndex,
        bytes calldata _vaultData,
        uint256[] calldata _tacticIndexes,
        uint256[] calldata _allocations,
        bytes[] calldata _tacticDatas
    ) external returns (address, address[] memory);
}

interface IVault {
    function withdraw(address _to, uint256 _amount) external returns (bool);
    function balanceOf(address _tactic) external view returns (uint256);
}
