// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import { ITokenFactory, DistributionData } from "src/interfaces/ITokenFactory.sol";
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
        // Decode parameters with backward compatibility
        (
            string memory name,
            string memory symbol,
            uint256 yearlyMintCap,
            uint256 vestingDuration,
            address[] memory vestRecipients,
            uint256[] memory vestAmounts,
            string memory tokenURI,
            DistributionData[] memory distributions
        ) = _decodeParameters(data);

        // Deploy token with TokenFactory as recipient for predictable CREATE2 addresses
        address token = address(
            new DERC20{ salt: salt }(
                name,
                symbol,
                initialSupply,
                address(this),
                owner,
                yearlyMintCap,
                vestingDuration,
                vestRecipients,
                vestAmounts,
                tokenURI
            )
        );

        // If no distributions, transfer all tokens to Airlock immediately
        if (distributions.length == 0) {
            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance > 0) {
                IERC20(token).safeTransfer(recipient, balance);
            }
        }

        return token;
    }

    /**
     * @notice Decodes token creation parameters with backward compatibility
     * @param data Encoded token configuration data
     * @return name Token name
     * @return symbol Token symbol
     * @return yearlyMintCap Yearly mint cap rate
     * @return vestingDuration Duration for vesting schedule
     * @return vestRecipients Array of vesting recipient addresses
     * @return vestAmounts Array of vesting amounts corresponding to recipients
     * @return tokenURI Token metadata URI
     * @return distributions Array of distribution configurations (empty if not provided)
     */
    function _decodeParameters(bytes calldata data)
        internal
        view
        returns (
            string memory name,
            string memory symbol,
            uint256 yearlyMintCap,
            uint256 vestingDuration,
            address[] memory vestRecipients,
            uint256[] memory vestAmounts,
            string memory tokenURI,
            DistributionData[] memory distributions
        )
    {
        // Use low-level staticcall to catch panics (panic 0x41 cannot be caught by try-catch)
        (bool success, bytes memory returnData) = address(this).staticcall(
            abi.encodeCall(this._decode8Params, (data))
        );

        if (success) {
            // Decode succeeded - extract 8 params from return data
            (name, symbol, yearlyMintCap, vestingDuration, vestRecipients, vestAmounts, tokenURI, distributions) =
                abi.decode(returnData, (string, string, uint256, uint256, address[], uint256[], string, DistributionData[]));
        } else {
            // Decode failed (panic caught) - use 7-param fallback for backward compatibility
            (name, symbol, yearlyMintCap, vestingDuration, vestRecipients, vestAmounts, tokenURI) =
                abi.decode(data, (string, string, uint256, uint256, address[], uint256[], string));
            distributions = new DistributionData[](0);
        }
    }

    /**
     * @notice External wrapper for decoding 8 parameters (used in staticcall)
     * @param data Encoded token configuration data
     * @return name Token name
     * @return symbol Token symbol
     * @return yearlyMintCap Yearly mint cap rate
     * @return vestingDuration Duration for vesting schedule
     * @return vestRecipients Array of vesting recipient addresses
     * @return vestAmounts Array of vesting amounts corresponding to recipients
     * @return tokenURI Token metadata URI
     * @return distributions Array of distribution configurations
     */
    function _decode8Params(bytes calldata data)
        external
        pure
        returns (
            string memory name,
            string memory symbol,
            uint256 yearlyMintCap,
            uint256 vestingDuration,
            address[] memory vestRecipients,
            uint256[] memory vestAmounts,
            string memory tokenURI,
            DistributionData[] memory distributions
        )
    {
        return abi.decode(
            data,
            (string, string, uint256, uint256, address[], uint256[], string, DistributionData[])
        );
    }
}
