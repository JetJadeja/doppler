// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";
import {Initializable} from "@openzeppelin/proxy/utils/Initializable.sol";

import {VaultConfig, IVault} from "../core/Interfaces.sol";

struct TacticData {
    address tactic;
    uint96 allocation;
}

struct BankStorage {
    IERC20 token;
    TacticData[] tactics;
    uint256 totalAllocation;
    uint256 supply;
    mapping(address => uint256) balances;
}

struct Config {
    IERC20 token;
}

contract BankMan is Initializable, IVault {
    using SafeERC20 for IERC20;

    // Custom Errors
    error InvalidTacticIndex();

    BankStorage internal $bank;

    constructor() {
        _disableInitializers();
    }

    function initialize(bytes calldata _data) external initializer {
        VaultConfig memory config = abi.decode(_data, (VaultConfig));
        Config memory bankConfig = abi.decode(config.data, (Config));

        $bank.token = bankConfig.token;

        for (uint256 i = 0; i < config.tactics.length; i++) {
            $bank.tactics.push(
                TacticData({tactic: config.tactics[i], allocation: SafeCast.toUint96(config.allocations[i])})
            );
            $bank.totalAllocation += config.allocations[i];
        }
    }

    function deposit(uint256 _amount) external {
        $bank.token.safeTransferFrom(msg.sender, address(this), _amount);
        allocate();
    }

    function allocate() public {
        uint256 excess = $bank.token.balanceOf(address(this)) - $bank.supply;
        if (excess == 0) {
            return;
        }

        $bank.supply += excess;
        uint256 totalAllocation = $bank.totalAllocation;

        for (uint256 i = 0; i < $bank.tactics.length; i++) {
            TacticData storage tactic = $bank.tactics[i];
            $bank.balances[tactic.tactic] += excess * tactic.allocation / totalAllocation;
        }
    }

    function withdraw(address _to, uint256 _amount) external override(IVault) returns (bool) {
        $bank.balances[msg.sender] -= _amount;
        $bank.supply -= _amount;
        $bank.token.safeTransfer(_to, _amount);

        return true;
    }

    function balanceOf(address _tactic) external view override(IVault) returns (uint256) {
        return $bank.balances[_tactic];
    }

    function totalSupply() external view returns (uint256) {
        return $bank.supply;
    }

    // ============================================
    // VIEW FUNCTIONS
    // ============================================

    /**
     * @notice Returns the token address used by this vault
     * @return The IERC20 token address
     */
    function getToken() external view returns (IERC20) {
        return $bank.token;
    }

    /**
     * @notice Returns the sum of all tactic allocations
     * @return The total allocation across all tactics
     */
    function getTotalAllocation() external view returns (uint256) {
        return $bank.totalAllocation;
    }

    /**
     * @notice Returns the number of tactics registered in this vault
     * @return The count of tactics
     */
    function getTacticCount() external view returns (uint256) {
        return $bank.tactics.length;
    }

    /**
     * @notice Returns the tactic address and allocation at the specified index
     * @param _index The index of the tactic to retrieve
     * @return tactic The address of the tactic
     * @return allocation The allocation weight for the tactic
     * @dev Reverts with InvalidTacticIndex if index is out of bounds
     */
    function getTactic(uint256 _index) external view returns (address tactic, uint96 allocation) {
        if (_index >= $bank.tactics.length) revert InvalidTacticIndex();
        TacticData storage tacticData = $bank.tactics[_index];
        return (tacticData.tactic, tacticData.allocation);
    }

    /**
     * @notice Returns an array of all tactic addresses
     * @return An array containing all tactic addresses
     */
    function getTactics() external view returns (address[] memory) {
        address[] memory tactics = new address[]($bank.tactics.length);
        for (uint256 i = 0; i < $bank.tactics.length; i++) {
            tactics[i] = $bank.tactics[i].tactic;
        }
        return tactics;
    }

    /**
     * @notice Returns the allocation for a specific tactic
     * @param _tactic The address of the tactic to query
     * @return The allocation weight for the tactic, or 0 if not found
     */
    function getTacticAllocation(address _tactic) external view returns (uint256) {
        for (uint256 i = 0; i < $bank.tactics.length; i++) {
            if ($bank.tactics[i].tactic == _tactic) {
                return $bank.tactics[i].allocation;
            }
        }
        return 0;
    }
}
