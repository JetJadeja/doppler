// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/proxy/utils/Initializable.sol";
import {IERC4626} from "@openzeppelin/interfaces/IERC4626.sol";

import {VaultConfig, IVault} from "../core/Interfaces.sol";

struct TacticData {
    address tactic;
    uint96 allocation;
}

struct BankStorage {
    address owner;
    IERC20 token;
    IERC4626 vault;
    TacticData[] tactics;
    uint256 totalAllocation;
    uint256 supply;
    mapping(address => uint256) balances;
}

struct Config {
    address owner;
    IERC20 token;
    IERC4626 vault;
}

/**
 * @title ERC4626Vault
 * @notice A vault that deposits into a ERC4626 vault, and keeps the yield for the owner
 */
contract ERC4626Vault is Initializable, IVault {
    using SafeERC20 for IERC20;

    BankStorage internal $bank;

    constructor() {
        _disableInitializers();
    }

    function initialize(bytes calldata _data) external initializer {
        VaultConfig memory config = abi.decode(_data, (VaultConfig));
        Config memory bankConfig = abi.decode(config.data, (Config));

        $bank.owner = bankConfig.owner;
        $bank.token = bankConfig.token;
        $bank.vault = bankConfig.vault;

        for (uint256 i = 0; i < config.tactics.length; i++) {
            $bank.tactics.push(
                TacticData({tactic: config.tactics[i], allocation: SafeCast.toUint96(config.allocations[i])})
            );
            $bank.totalAllocation += config.allocations[i];
        }
    }

    function deposit(uint256 _amount) external {
        $bank.token.safeTransferFrom(msg.sender, address(this), _amount);
        $bank.token.approve(address($bank.vault), _amount);

        // Deposit into ERC4626 vault, and compute value of shares,
        // we compute the values of the shares to account for rounding from _amount
        uint256 shares = $bank.vault.deposit(_amount, address(this));
        uint256 assets = $bank.vault.previewRedeem(shares);

        $bank.supply += assets;
        uint256 totalAllocation = $bank.totalAllocation;

        for (uint256 i = 0; i < $bank.tactics.length; i++) {
            TacticData storage tactic = $bank.tactics[i];
            $bank.balances[tactic.tactic] += assets * tactic.allocation / totalAllocation;
        }
    }

    function withdraw(address _to, uint256 _amount) external override(IVault) returns (bool) {
        $bank.balances[msg.sender] -= _amount;
        $bank.supply -= _amount;

        _exit(_to, _amount);

        return true;
    }

    function recoverYield(address _to) external {
        require(msg.sender == $bank.owner, "ERC4626Vault: only owner can recover yield");

        uint256 assets = $bank.vault.maxWithdraw(address(this));
        uint256 excess = assets - $bank.supply;

        _exit(_to, excess);
    }

    /**
     * @notice  Exit funds from the vault while ensuring that we are always fully backed
     * @dev     Will leave some funds out of the ERC4626 vault, but should be small enough
     *          to have been a rounding error in the ERC4626 vault.
     *
     *          BEWARE: the fucntion might transfer LESS than _amount
     */
    function _exit(address _to, uint256 _amount) internal {
        uint256 assets = $bank.vault.maxWithdraw(address(this));
        uint256 toWithdraw = Math.min(_amount, assets);

        // Withdraw from the vault to self
        $bank.vault.withdraw(toWithdraw, address(this), address(this));

        // Ensure that we leave enough tokens still be backed
        assets = $bank.vault.maxWithdraw(address(this)) + $bank.token.balanceOf(address(this));
        uint256 exitable = Math.min(assets - $bank.supply, _amount);

        $bank.token.safeTransfer(_to, exitable);
    }

    function balanceOf(address _tactic) external view override(IVault) returns (uint256) {
        return $bank.balances[_tactic];
    }

    function totalSupply() external view returns (uint256) {
        return $bank.supply;
    }

    function totalAssets() external view returns (uint256) {
        return $bank.vault.maxWithdraw(address(this)) + $bank.token.balanceOf(address(this));
    }
}
