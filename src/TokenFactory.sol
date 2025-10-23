// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { ITokenFactory } from "src/interfaces/ITokenFactory.sol";
import { DERC20 } from "src/DERC20.sol";
import { ImmutableAirlock } from "src/base/ImmutableAirlock.sol";
import { IRegistry, IStrategyMaker, IVault } from "src/interfaces/ISeicho.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

/// @custom:security-contact security@whetstone.cc
contract TokenFactory is ITokenFactory, ImmutableAirlock {
    using SafeERC20 for IERC20;

    IStrategyMaker public immutable strategyMaker;
    IRegistry public immutable tacticRegistry;
    IRegistry public immutable vaultRegistry;

    /**
     * @param airlock_ Address of the Airlock contract
     * @param strategyMaker_ Address of Seicho StrategyMaker (address(0) if not using distributions)
     * @param tacticRegistry_ Address of Seicho TacticRegistry (address(0) if not using distributions)
     * @param vaultRegistry_ Address of Seicho VaultRegistry (address(0) if not using distributions)
     */
    constructor(
        address airlock_,
        address strategyMaker_,
        address tacticRegistry_,
        address vaultRegistry_
    ) ImmutableAirlock(airlock_) {
        strategyMaker = IStrategyMaker(strategyMaker_);
        tacticRegistry = IRegistry(tacticRegistry_);
        vaultRegistry = IRegistry(vaultRegistry_);
    }

    /**
     * @notice Creates a new DERC20 token
     * @param initialSupply Total supply of the token
     * @param recipient Address receiving the initial supply
     * @param owner Address receiving the ownership of the token
     * @param salt Salt used for the create2 deployment
     * @param data Creation parameters encoded as bytes
     */
    function create(
        uint256 initialSupply,
        address recipient,
        address owner,
        bytes32 salt,
        bytes calldata data
    ) external onlyAirlock returns (address) {
        (
            string memory name,
            string memory symbol,
            uint256 yearlyMintCap,
            uint256 vestingDuration,
            address[] memory recipients,
            uint256[] memory amounts,
            string memory tokenURI
        ) = abi.decode(data, (string, string, uint256, uint256, address[], uint256[], string));

        return address(
            new DERC20{ salt: salt }(
                name,
                symbol,
                initialSupply,
                recipient,
                owner,
                yearlyMintCap,
                vestingDuration,
                recipients,
                amounts,
                tokenURI
            )
        );
    }
}
