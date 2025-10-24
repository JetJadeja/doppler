// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/proxy/Clones.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {IItem, IRegistry, RegistryType} from "./Interfaces.sol";

abstract contract Registry is IRegistry, Ownable {
    IItem[] internal items;
    mapping(uint256 => bool) public disabledItems;

    event ItemRegistered(address indexed item, uint256 indexed index);
    event ItemDisabled(uint256 indexed index);

    constructor(address _owner) Ownable(_owner) {}

    function register(IItem _item) external override(IRegistry) onlyOwner {
        uint256 index = items.length;
        items.push(_item);
        emit ItemRegistered(address(_item), index);
    }

    function disableItem(uint256 _index) external onlyOwner {
        require(_index < items.length, "Invalid index");
        disabledItems[_index] = true;
        emit ItemDisabled(_index);
    }

    function deployClone(uint256 _index, bytes calldata _data) external override(IRegistry) returns (address) {
        require(_index < items.length, "Invalid index");
        require(!disabledItems[_index], "Item disabled");
        address clone = Clones.clone(address(items[_index]));
        if (_data.length > 0) {
            IItem(clone).initialize(_data);
        }
        return clone;
    }

    function get(uint256 _index) external view override(IRegistry) returns (IItem) {
        return items[_index];
    }

    function getCount() external view override(IRegistry) returns (uint256) {
        return items.length;
    }

    function getAllItems() external view returns (IItem[] memory) {
        return items;
    }

    function getType() external view virtual override(IRegistry) returns (RegistryType);
}

contract TacticRegistry is Registry {
    constructor(address _owner) Registry(_owner) {}

    function getType() external pure override(Registry) returns (RegistryType) {
        return RegistryType.TACTIC;
    }
}

contract VaultRegistry is Registry {
    constructor(address _owner) Registry(_owner) {}

    function getType() external pure override(Registry) returns (RegistryType) {
        return RegistryType.VAULT;
    }
}
