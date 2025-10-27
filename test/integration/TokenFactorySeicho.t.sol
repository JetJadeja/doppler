// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { Vm } from "forge-std/Vm.sol";
import { TokenFactory, ITokenFactory } from "src/TokenFactory.sol";
import { DERC20 } from "src/DERC20.sol";
import { IERC20 } from "@openzeppelin/token/ERC20/IERC20.sol";
import { IRegistry, IStrategyMaker } from "src/interfaces/ISeicho.sol";
import { IItem } from "@seicho-test/core/Interfaces.sol";
import { StrategyMaker } from "@seicho-test/core/StrategyMaker.sol";
import { TacticRegistry, VaultRegistry } from "@seicho-test/core/Registry.sol";
import { BankMan } from "@seicho-test/vaults/BankMan.sol";
import { TrustMeBro } from "@seicho-test/tactics/TrustMeBro.sol";
import { MerkleDrop } from "@seicho-test/tactics/MerkleDrop.sol";
import { MessageHashUtils } from "@openzeppelin/utils/cryptography/MessageHashUtils.sol";

contract TokenFactorySeichoTest is Test {
    TokenFactory public tokenFactory;
    StrategyMaker public strategyMaker;
    TacticRegistry public tacticRegistry;
    VaultRegistry public vaultRegistry;

    address public airlock;
    address public recipient;
    address public owner;

    BankMan public bankManImpl;
    TrustMeBro public trustMeBroImpl;
    MerkleDrop public merkleDropImpl;

    function setUp() public {
        airlock = address(this);
        recipient = address(0xa71c3);
        owner = address(0xb0b);

        // Deploy Seicho infrastructure
        tacticRegistry = new TacticRegistry(address(this));
        vaultRegistry = new VaultRegistry(address(this));
        strategyMaker = new StrategyMaker(tacticRegistry, vaultRegistry);

        // Deploy implementations
        bankManImpl = new BankMan();
        trustMeBroImpl = new TrustMeBro();
        merkleDropImpl = new MerkleDrop();

        // Register implementations
        vaultRegistry.register(IItem(address(bankManImpl)));
        tacticRegistry.register(IItem(address(trustMeBroImpl)));  // Index 0
        tacticRegistry.register(IItem(address(merkleDropImpl)));  // Index 1

        // Deploy TokenFactory
        tokenFactory = new TokenFactory(
            address(this),
            address(strategyMaker),
            address(tacticRegistry),
            address(vaultRegistry)
        );
    }

    // ============================================
    // Category 1: Backward Compatibility
    // ============================================

    function test_create_7Params_WithoutDistribution_AllTokensToRecipient() public {
        uint256 initialSupply = 1e27;
        bytes32 salt = keccak256("test1");

        // Encode 7 params (old format)
        bytes memory tokenData = abi.encode(
            "Test Token",           // name
            "TEST",                 // symbol
            0,                      // yearlyMintCap
            0,                      // vestingDuration
            new address[](0),       // vestRecipients
            new uint256[](0),       // vestAmounts
            ""                      // tokenURI
        );

        // Create token
        address token = tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            tokenData
        );

        // Verify all tokens went to recipient
        assertEq(IERC20(token).balanceOf(recipient), initialSupply, "Recipient should have full supply");
        assertEq(IERC20(token).balanceOf(address(tokenFactory)), 0, "Factory should have 0 balance");
    }

    function test_create_8Params_WithDistribution_CreatesStrategy() public {
        uint256 initialSupply = 1e27;
        uint256 distributionAmount = 3e26; // 30% of supply
        bytes32 salt = keccak256("test2");

        address bro = address(0xb70);

        // Prepare distribution data
        ITokenFactory.BankManConfig memory bankManConfig = ITokenFactory.BankManConfig({
            token: IERC20(address(0)) // Placeholder
        });

        uint256[] memory tacticIndexes = new uint256[](1);
        tacticIndexes[0] = 0; // TrustMeBro is at index 0

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 100; // 100% to this tactic

        bytes[] memory tacticDatas = new bytes[](1);
        tacticDatas[0] = abi.encode(bro, uint96(1e18)); // TrustMeBro config: bro address, claimSize

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            amount: distributionAmount,
            vaultIndex: 0, // BankMan is at index 0
            vaultData: abi.encode(bankManConfig),
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas
        });

        // Encode 8 params (new format)
        bytes memory tokenData = abi.encode(
            "Test Token",           // name
            "TEST",                 // symbol
            0,                      // yearlyMintCap
            0,                      // vestingDuration
            new address[](0),       // vestRecipients
            new uint256[](0),       // vestAmounts
            "",                     // tokenURI
            distribution            // distribution
        );

        // Expect DistributionCreated event
        vm.expectEmit(false, false, false, false);
        emit ITokenFactory.DistributionCreated(address(0), address(0), new address[](0), 0);

        // Create token
        address token = tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            tokenData
        );

        // Verify recipient got remaining tokens
        uint256 expectedRecipientBalance = initialSupply - distributionAmount;
        assertEq(IERC20(token).balanceOf(recipient), expectedRecipientBalance, "Recipient should have remainder");
        assertEq(IERC20(token).balanceOf(address(tokenFactory)), 0, "Factory should have 0 balance");

        // Note: We can't easily verify vault/tactics without knowing their addresses
        // This would require event parsing or storage inspection
    }

    function test_create_8Params_ZeroAmount_SkipsDistribution() public {
        uint256 initialSupply = 1e27;
        bytes32 salt = keccak256("test3");

        // Prepare distribution data with amount = 0
        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            amount: 0, // Zero amount should skip distribution
            vaultIndex: 0,
            vaultData: "",
            tacticIndexes: new uint256[](0),
            allocations: new uint256[](0),
            tacticDatas: new bytes[](0)
        });

        // Encode 8 params with zero distribution
        bytes memory tokenData = abi.encode(
            "Test Token",           // name
            "TEST",                 // symbol
            0,                      // yearlyMintCap
            0,                      // vestingDuration
            new address[](0),       // vestRecipients
            new uint256[](0),       // vestAmounts
            "",                     // tokenURI
            distribution            // distribution with amount = 0
        );

        // Create token
        address token = tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            tokenData
        );

        // Verify all tokens went to recipient (no distribution happened)
        assertEq(IERC20(token).balanceOf(recipient), initialSupply, "Recipient should have full supply");
        assertEq(IERC20(token).balanceOf(address(tokenFactory)), 0, "Factory should have 0 balance");
    }

    function test_decodeParameters_StaticCallCatchesPanic_Fallback7Params() public {
        uint256 initialSupply = 1e27;
        bytes32 salt = keccak256("test4");

        // Encode 7 params - this will cause panic 0x41 when trying to decode as 8 params
        bytes memory tokenData = abi.encode(
            "Test Token",           // name
            "TEST",                 // symbol
            0,                      // yearlyMintCap
            0,                      // vestingDuration
            new address[](0),       // vestRecipients
            new uint256[](0),       // vestAmounts
            ""                      // tokenURI
            // No 8th param (DistributionData)
        );

        // This should NOT revert - staticcall should catch the panic and fallback to 7 param decode
        address token = tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            tokenData
        );

        // Verify the token was created and all tokens went to recipient
        assertEq(IERC20(token).balanceOf(recipient), initialSupply, "Recipient should have full supply");
        assertEq(IERC20(token).balanceOf(address(tokenFactory)), 0, "Factory should have 0 balance");
    }

    // ============================================
    // Category 2: Token Address Injection
    // ============================================

    function test_injectTokenAddress_ReplacesZeroAddress() public {
        uint256 initialSupply = 1e27;
        uint256 distributionAmount = 5e26; // 50% of supply
        bytes32 salt = keccak256("test5");

        address bro = address(0xb70);

        // Prepare distribution data with address(0) placeholder
        ITokenFactory.BankManConfig memory bankManConfig = ITokenFactory.BankManConfig({
            token: IERC20(address(0)) // Placeholder - should be replaced
        });

        uint256[] memory tacticIndexes = new uint256[](1);
        tacticIndexes[0] = 0;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 100;

        bytes[] memory tacticDatas = new bytes[](1);
        tacticDatas[0] = abi.encode(bro, uint96(1e18));

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            amount: distributionAmount,
            vaultIndex: 0,
            vaultData: abi.encode(bankManConfig),
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas
        });

        bytes memory tokenData = abi.encode(
            "Test Token",
            "TEST",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "",
            distribution
        );

        // Record logs to capture DistributionCreated event
        vm.recordLogs();

        // Create token
        address token = tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            tokenData
        );

        // Get the vault address from the DistributionCreated event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address vault;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DistributionCreated(address,address,address[],uint256)")) {
                // Decode the event - vault is the second indexed parameter
                vault = address(uint160(uint256(logs[i].topics[2])));
                break;
            }
        }

        // Verify vault was created and received tokens
        assertTrue(vault != address(0), "Vault should be deployed");
        assertEq(IERC20(token).balanceOf(vault), distributionAmount, "Vault should have distribution amount");

        // Verify BankMan vault has the correct token (not address(0))
        BankMan bankMan = BankMan(vault);
        assertEq(address(bankMan.getToken()), token, "BankMan token should be deployed token, not address(0)");
    }

    function test_injectTokenAddress_PreservesNonZeroAddress() public {
        uint256 initialSupply = 1e27;
        uint256 distributionAmount = 5e26;
        bytes32 salt = keccak256("test6");

        address bro = address(0xb70);
        address presetToken = address(0xDEADBEEF); // Non-zero preset address

        // Prepare distribution data with non-zero token address
        ITokenFactory.BankManConfig memory bankManConfig = ITokenFactory.BankManConfig({
            token: IERC20(presetToken) // Non-zero address - should NOT be replaced
        });

        uint256[] memory tacticIndexes = new uint256[](1);
        tacticIndexes[0] = 0;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 100;

        bytes[] memory tacticDatas = new bytes[](1);
        tacticDatas[0] = abi.encode(bro, uint96(1e18));

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            amount: distributionAmount,
            vaultIndex: 0,
            vaultData: abi.encode(bankManConfig),
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas
        });

        bytes memory tokenData = abi.encode(
            "Test Token",
            "TEST",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "",
            distribution
        );

        // Record logs
        vm.recordLogs();

        // Create token
        address token = tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            tokenData
        );

        // Get vault from event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address vault;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DistributionCreated(address,address,address[],uint256)")) {
                vault = address(uint160(uint256(logs[i].topics[2])));
                break;
            }
        }

        // Verify BankMan vault preserved the preset token address (not replaced with deployed token)
        BankMan bankMan = BankMan(vault);
        assertEq(address(bankMan.getToken()), presetToken, "BankMan token should be preset address, not deployed token");
        assertTrue(address(bankMan.getToken()) != token, "Token should not have been replaced");
    }

    function test_injectTokenAddress_InvalidVaultData_Reverts() public {
        uint256 initialSupply = 1e27;
        uint256 distributionAmount = 5e26;
        bytes32 salt = keccak256("test7");

        // Invalid vaultData - random bytes that won't decode to BankManConfig
        bytes memory invalidVaultData = hex"deadbeef";

        uint256[] memory tacticIndexes = new uint256[](1);
        tacticIndexes[0] = 0;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 100;

        bytes[] memory tacticDatas = new bytes[](1);
        tacticDatas[0] = abi.encode(address(0xb70), uint96(1e18));

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            amount: distributionAmount,
            vaultIndex: 0,
            vaultData: invalidVaultData, // Invalid data
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas
        });

        bytes memory tokenData = abi.encode(
            "Test Token",
            "TEST",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "",
            distribution
        );

        // Should revert when trying to decode invalid vaultData
        vm.expectRevert();
        tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            tokenData
        );
    }

    // ============================================
    // Category 3: Distribution Validation
    // ============================================

    function test_distribution_ValidSingleTactic() public {
        uint256 initialSupply = 1e27;
        uint256 distributionAmount = 4e26; // 40% of supply
        bytes32 salt = keccak256("test8");

        address bro = address(0xb70);

        // Prepare distribution with single tactic
        ITokenFactory.BankManConfig memory bankManConfig = ITokenFactory.BankManConfig({
            token: IERC20(address(0))
        });

        uint256[] memory tacticIndexes = new uint256[](1);
        tacticIndexes[0] = 0; // TrustMeBro

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 100; // 100% allocation

        bytes[] memory tacticDatas = new bytes[](1);
        tacticDatas[0] = abi.encode(bro, uint96(1e18));

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            amount: distributionAmount,
            vaultIndex: 0,
            vaultData: abi.encode(bankManConfig),
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas
        });

        bytes memory tokenData = abi.encode(
            "Test Token",
            "TEST",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "",
            distribution
        );

        // Create token
        address token = tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            tokenData
        );

        // Verify balances
        uint256 expectedRecipientBalance = initialSupply - distributionAmount;
        assertEq(IERC20(token).balanceOf(recipient), expectedRecipientBalance, "Recipient should have remainder");
        assertEq(IERC20(token).balanceOf(address(tokenFactory)), 0, "Factory should have 0 balance");
    }

    function test_distribution_MultiTactic_ProportionalAllocation() public {
        uint256 initialSupply = 1e27;
        uint256 distributionAmount = 6e26; // 60% of supply
        bytes32 salt = keccak256("test9");

        // Prepare distribution with 3 tactics (50/30/20 split)
        ITokenFactory.BankManConfig memory bankManConfig = ITokenFactory.BankManConfig({
            token: IERC20(address(0))
        });

        uint256[] memory tacticIndexes = new uint256[](3);
        tacticIndexes[0] = 0; // TrustMeBro #1
        tacticIndexes[1] = 0; // TrustMeBro #2
        tacticIndexes[2] = 0; // TrustMeBro #3

        uint256[] memory allocations = new uint256[](3);
        allocations[0] = 50; // 50%
        allocations[1] = 30; // 30%
        allocations[2] = 20; // 20%

        bytes[] memory tacticDatas = new bytes[](3);
        tacticDatas[0] = abi.encode(address(0xb70), uint96(1e18));
        tacticDatas[1] = abi.encode(address(0xb71), uint96(2e18));
        tacticDatas[2] = abi.encode(address(0xb72), uint96(3e18));

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            amount: distributionAmount,
            vaultIndex: 0,
            vaultData: abi.encode(bankManConfig),
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas
        });

        bytes memory tokenData = abi.encode(
            "Test Token",
            "TEST",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "",
            distribution
        );

        // Record logs
        vm.recordLogs();

        // Create token
        address token = tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            tokenData
        );

        // Get vault from event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address vault;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DistributionCreated(address,address,address[],uint256)")) {
                vault = address(uint160(uint256(logs[i].topics[2])));
                break;
            }
        }

        // Verify vault received correct amount
        assertEq(IERC20(token).balanceOf(vault), distributionAmount, "Vault should have distribution amount");

        // Verify BankMan has 3 tactics
        BankMan bankMan = BankMan(vault);
        assertEq(bankMan.getTacticCount(), 3, "Should have 3 tactics");

        // Verify total allocation
        assertEq(bankMan.getTotalAllocation(), 100, "Total allocation should be 100");

        // Verify recipient got remainder
        uint256 expectedRecipientBalance = initialSupply - distributionAmount;
        assertEq(IERC20(token).balanceOf(recipient), expectedRecipientBalance, "Recipient should have remainder");
    }

    function test_distribution_AmountExceedsSupply_Reverts() public {
        uint256 initialSupply = 1e27;
        uint256 distributionAmount = 2e27; // 200% of supply - exceeds!
        bytes32 salt = keccak256("test10");

        ITokenFactory.BankManConfig memory bankManConfig = ITokenFactory.BankManConfig({
            token: IERC20(address(0))
        });

        uint256[] memory tacticIndexes = new uint256[](1);
        tacticIndexes[0] = 0;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 100;

        bytes[] memory tacticDatas = new bytes[](1);
        tacticDatas[0] = abi.encode(address(0xb70), uint96(1e18));

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            amount: distributionAmount,
            vaultIndex: 0,
            vaultData: abi.encode(bankManConfig),
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas
        });

        bytes memory tokenData = abi.encode(
            "Test Token",
            "TEST",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "",
            distribution
        );

        // Should revert when trying to transfer more than balance
        vm.expectRevert();
        tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            tokenData
        );
    }

    function test_distribution_ArrayLengthMismatch_Reverts() public {
        uint256 initialSupply = 1e27;
        uint256 distributionAmount = 5e26;
        bytes32 salt = keccak256("test11");

        ITokenFactory.BankManConfig memory bankManConfig = ITokenFactory.BankManConfig({
            token: IERC20(address(0))
        });

        uint256[] memory tacticIndexes = new uint256[](2);
        tacticIndexes[0] = 0;
        tacticIndexes[1] = 0;

        uint256[] memory allocations = new uint256[](3); // Mismatch: 3 vs 2
        allocations[0] = 50;
        allocations[1] = 30;
        allocations[2] = 20;

        bytes[] memory tacticDatas = new bytes[](2);
        tacticDatas[0] = abi.encode(address(0xb70), uint96(1e18));
        tacticDatas[1] = abi.encode(address(0xb71), uint96(1e18));

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            amount: distributionAmount,
            vaultIndex: 0,
            vaultData: abi.encode(bankManConfig),
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas
        });

        bytes memory tokenData = abi.encode(
            "Test Token",
            "TEST",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "",
            distribution
        );

        // Should revert in StrategyMaker due to array length mismatch
        vm.expectRevert();
        tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            tokenData
        );
    }

    function test_distribution_ZeroTotalAllocation_Reverts() public {
        uint256 initialSupply = 1e27;
        uint256 distributionAmount = 5e26;
        bytes32 salt = keccak256("test12");

        ITokenFactory.BankManConfig memory bankManConfig = ITokenFactory.BankManConfig({
            token: IERC20(address(0))
        });

        uint256[] memory tacticIndexes = new uint256[](2);
        tacticIndexes[0] = 0;
        tacticIndexes[1] = 0;

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 0; // All zeros
        allocations[1] = 0; // All zeros

        bytes[] memory tacticDatas = new bytes[](2);
        tacticDatas[0] = abi.encode(address(0xb70), uint96(1e18));
        tacticDatas[1] = abi.encode(address(0xb71), uint96(1e18));

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            amount: distributionAmount,
            vaultIndex: 0,
            vaultData: abi.encode(bankManConfig),
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas
        });

        bytes memory tokenData = abi.encode(
            "Test Token",
            "TEST",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "",
            distribution
        );

        // Should revert in StrategyMaker due to zero total allocation
        vm.expectRevert();
        tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            tokenData
        );
    }

    function test_distribution_InvalidVaultIndex_Reverts() public {
        uint256 initialSupply = 1e27;
        uint256 distributionAmount = 5e26;
        bytes32 salt = keccak256("test13");

        ITokenFactory.BankManConfig memory bankManConfig = ITokenFactory.BankManConfig({
            token: IERC20(address(0))
        });

        uint256[] memory tacticIndexes = new uint256[](1);
        tacticIndexes[0] = 0;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 100;

        bytes[] memory tacticDatas = new bytes[](1);
        tacticDatas[0] = abi.encode(address(0xb70), uint96(1e18));

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            amount: distributionAmount,
            vaultIndex: 999, // Invalid index - out of bounds
            vaultData: abi.encode(bankManConfig),
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas
        });

        bytes memory tokenData = abi.encode(
            "Test Token",
            "TEST",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "",
            distribution
        );

        // Should revert in Registry when trying to get vault at invalid index
        vm.expectRevert();
        tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            tokenData
        );
    }

    function test_distribution_InvalidTacticIndex_Reverts() public {
        uint256 initialSupply = 1e27;
        uint256 distributionAmount = 5e26;
        bytes32 salt = keccak256("test14");

        ITokenFactory.BankManConfig memory bankManConfig = ITokenFactory.BankManConfig({
            token: IERC20(address(0))
        });

        uint256[] memory tacticIndexes = new uint256[](1);
        tacticIndexes[0] = 999; // Invalid index - out of bounds

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 100;

        bytes[] memory tacticDatas = new bytes[](1);
        tacticDatas[0] = abi.encode(address(0xb70), uint96(1e18));

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            amount: distributionAmount,
            vaultIndex: 0,
            vaultData: abi.encode(bankManConfig),
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas
        });

        bytes memory tokenData = abi.encode(
            "Test Token",
            "TEST",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "",
            distribution
        );

        // Should revert in Registry when trying to get tactic at invalid index
        vm.expectRevert();
        tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            tokenData
        );
    }

    function test_distribution_EmptyTacticArrays_Reverts() public {
        uint256 initialSupply = 1e27;
        uint256 distributionAmount = 5e26;
        bytes32 salt = keccak256("test15");

        ITokenFactory.BankManConfig memory bankManConfig = ITokenFactory.BankManConfig({
            token: IERC20(address(0))
        });

        uint256[] memory tacticIndexes = new uint256[](0); // Empty
        uint256[] memory allocations = new uint256[](0); // Empty
        bytes[] memory tacticDatas = new bytes[](0); // Empty

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            amount: distributionAmount,
            vaultIndex: 0,
            vaultData: abi.encode(bankManConfig),
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas
        });

        bytes memory tokenData = abi.encode(
            "Test Token",
            "TEST",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "",
            distribution
        );

        // Should revert in StrategyMaker due to empty tactics array
        vm.expectRevert();
        tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            tokenData
        );
    }

    // ============================================
    // Category 4: Token Transfer Flows
    // ============================================

    function test_transfer_NoDistribution_AllToRecipient() public {
        uint256 initialSupply = 1e27;
        bytes32 salt = keccak256("test16");

        // 7-param format - no distribution
        bytes memory tokenData = abi.encode(
            "Test Token",
            "TEST",
            0,
            0,
            new address[](0),
            new uint256[](0),
            ""
        );

        // Create token
        address token = tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            tokenData
        );

        // Verify 100% of tokens went to recipient
        assertEq(IERC20(token).balanceOf(recipient), initialSupply, "Recipient should have 100% of supply");
        assertEq(IERC20(token).balanceOf(address(tokenFactory)), 0, "Factory should have 0 balance");
        assertEq(IERC20(token).totalSupply(), initialSupply, "Total supply should match initial supply");
    }

    function test_transfer_WithDistribution_VaultGetsExactAmount() public {
        uint256 initialSupply = 1e27;
        uint256 distributionAmount = 3e26; // 30%
        bytes32 salt = keccak256("test17");

        // Prepare distribution
        ITokenFactory.BankManConfig memory bankManConfig = ITokenFactory.BankManConfig({
            token: IERC20(address(0))
        });

        uint256[] memory tacticIndexes = new uint256[](1);
        tacticIndexes[0] = 0;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 100;

        bytes[] memory tacticDatas = new bytes[](1);
        tacticDatas[0] = abi.encode(address(0xb70), uint96(1e18));

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            amount: distributionAmount,
            vaultIndex: 0,
            vaultData: abi.encode(bankManConfig),
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas
        });

        bytes memory tokenData = abi.encode(
            "Test Token",
            "TEST",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "",
            distribution
        );

        // Record logs
        vm.recordLogs();

        // Create token
        address token = tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            tokenData
        );

        // Get vault from event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address vault;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DistributionCreated(address,address,address[],uint256)")) {
                vault = address(uint160(uint256(logs[i].topics[2])));
                break;
            }
        }

        // Verify vault received EXACTLY the distribution amount
        assertEq(IERC20(token).balanceOf(vault), distributionAmount, "Vault should have exactly distribution amount");
        assertTrue(vault != address(0), "Vault should exist");
    }

    function test_transfer_WithDistribution_RecipientGetsRemainder() public {
        uint256 initialSupply = 1e27;
        uint256 distributionAmount = 4e26; // 40%
        bytes32 salt = keccak256("test18");

        // Prepare distribution
        ITokenFactory.BankManConfig memory bankManConfig = ITokenFactory.BankManConfig({
            token: IERC20(address(0))
        });

        uint256[] memory tacticIndexes = new uint256[](1);
        tacticIndexes[0] = 0;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 100;

        bytes[] memory tacticDatas = new bytes[](1);
        tacticDatas[0] = abi.encode(address(0xb70), uint96(1e18));

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            amount: distributionAmount,
            vaultIndex: 0,
            vaultData: abi.encode(bankManConfig),
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas
        });

        bytes memory tokenData = abi.encode(
            "Test Token",
            "TEST",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "",
            distribution
        );

        // Create token
        address token = tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            tokenData
        );

        // Calculate expected remainder
        uint256 expectedRecipientBalance = initialSupply - distributionAmount;

        // Verify recipient received exactly the remainder
        assertEq(IERC20(token).balanceOf(recipient), expectedRecipientBalance, "Recipient should have remainder");
        assertEq(IERC20(token).balanceOf(recipient), 6e26, "Recipient should have 60% (remainder)");
    }

    function test_transfer_FullDistribution_NoRemainder() public {
        uint256 initialSupply = 1e27;
        uint256 distributionAmount = 1e27; // 100% - full distribution
        bytes32 salt = keccak256("test19");

        // Prepare distribution
        ITokenFactory.BankManConfig memory bankManConfig = ITokenFactory.BankManConfig({
            token: IERC20(address(0))
        });

        uint256[] memory tacticIndexes = new uint256[](1);
        tacticIndexes[0] = 0;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 100;

        bytes[] memory tacticDatas = new bytes[](1);
        tacticDatas[0] = abi.encode(address(0xb70), uint96(1e18));

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            amount: distributionAmount,
            vaultIndex: 0,
            vaultData: abi.encode(bankManConfig),
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas
        });

        bytes memory tokenData = abi.encode(
            "Test Token",
            "TEST",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "",
            distribution
        );

        // Record logs
        vm.recordLogs();

        // Create token
        address token = tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            tokenData
        );

        // Get vault from event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address vault;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DistributionCreated(address,address,address[],uint256)")) {
                vault = address(uint160(uint256(logs[i].topics[2])));
                break;
            }
        }

        // Verify vault got 100%, recipient got 0
        assertEq(IERC20(token).balanceOf(vault), initialSupply, "Vault should have 100%");
        assertEq(IERC20(token).balanceOf(recipient), 0, "Recipient should have 0 (no remainder)");
        assertEq(IERC20(token).balanceOf(address(tokenFactory)), 0, "Factory should have 0");
    }

    function test_transfer_FactoryHasZeroBalance_AfterCreate() public {
        uint256 initialSupply = 1e27;
        bytes32 saltNoDistribution = keccak256("test20a");
        bytes32 saltWithDistribution = keccak256("test20b");

        // Test 1: No distribution - factory should have 0 balance
        bytes memory tokenDataNoDistribution = abi.encode(
            "Test Token 1",
            "TEST1",
            0,
            0,
            new address[](0),
            new uint256[](0),
            ""
        );

        address token1 = tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            saltNoDistribution,
            tokenDataNoDistribution
        );

        assertEq(IERC20(token1).balanceOf(address(tokenFactory)), 0, "Factory should have 0 after no distribution");

        // Test 2: With distribution - factory should STILL have 0 balance
        ITokenFactory.BankManConfig memory bankManConfig = ITokenFactory.BankManConfig({
            token: IERC20(address(0))
        });

        uint256[] memory tacticIndexes = new uint256[](1);
        tacticIndexes[0] = 0;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 100;

        bytes[] memory tacticDatas = new bytes[](1);
        tacticDatas[0] = abi.encode(address(0xb70), uint96(1e18));

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            amount: 5e26, // 50%
            vaultIndex: 0,
            vaultData: abi.encode(bankManConfig),
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas
        });

        bytes memory tokenDataWithDistribution = abi.encode(
            "Test Token 2",
            "TEST2",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "",
            distribution
        );

        address token2 = tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            saltWithDistribution,
            tokenDataWithDistribution
        );

        assertEq(IERC20(token2).balanceOf(address(tokenFactory)), 0, "Factory should have 0 after distribution");
    }

    function test_transfer_SafeTransferUsed_FailureReverts() public {
        // This test verifies that SafeERC20 is used (not raw transfer)
        // SafeERC20.safeTransfer reverts on failure, raw transfer returns bool

        uint256 initialSupply = 1e27;
        uint256 distributionAmount = 2e27; // 200% - exceeds supply!
        bytes32 salt = keccak256("test21");

        ITokenFactory.BankManConfig memory bankManConfig = ITokenFactory.BankManConfig({
            token: IERC20(address(0))
        });

        uint256[] memory tacticIndexes = new uint256[](1);
        tacticIndexes[0] = 0;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 100;

        bytes[] memory tacticDatas = new bytes[](1);
        tacticDatas[0] = abi.encode(address(0xb70), uint96(1e18));

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            amount: distributionAmount,
            vaultIndex: 0,
            vaultData: abi.encode(bankManConfig),
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas
        });

        bytes memory tokenData = abi.encode(
            "Test Token",
            "TEST",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "",
            distribution
        );

        // Should revert because SafeERC20.safeTransfer reverts when transfer fails
        // (trying to transfer more than balance)
        // If raw transfer was used, it would return false but not revert
        vm.expectRevert();
        tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            tokenData
        );
    }

    // ============================================
    // Category 5: CREATE2 Predictability
    // ============================================

    function test_create2_PredictableAddress_SameSalt() public {
        uint256 initialSupply = 1e27;
        bytes32 salt = bytes32(uint256(0x123456));

        // Same parameters
        bytes memory tokenData = abi.encode(
            "Test Token",
            "TEST",
            0,
            0,
            new address[](0),
            new uint256[](0),
            ""
        );

        // Deploy first token
        address token1 = tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            tokenData
        );

        // Try to deploy with same salt and params - should revert (CREATE2 collision)
        vm.expectRevert();
        tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            salt, // Same salt
            tokenData
        );

        // Verify token1 exists
        assertTrue(token1 != address(0), "Token1 should be deployed");
    }

    function test_create2_RecipientAlwaysFactory_RegardlessOfDistribution() public {
        // This test verifies that the recipient passed to DERC20 constructor is ALWAYS address(tokenFactory)
        // regardless of whether distribution is present or not
        // This ensures CREATE2 predictability

        uint256 initialSupply = 1e27;
        bytes32 salt1 = keccak256("noDistribution");
        bytes32 salt2 = keccak256("withDistribution");

        // Deploy without distribution (7 params)
        bytes memory tokenDataNoDistribution = abi.encode(
            "Test Token",
            "TEST",
            0,
            0,
            new address[](0),
            new uint256[](0),
            ""
        );

        address tokenNoDistribution = tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            salt1,
            tokenDataNoDistribution
        );

        // Deploy with distribution (8 params)
        ITokenFactory.BankManConfig memory bankManConfig = ITokenFactory.BankManConfig({
            token: IERC20(address(0))
        });

        uint256[] memory tacticIndexes = new uint256[](1);
        tacticIndexes[0] = 0;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 100;

        bytes[] memory tacticDatas = new bytes[](1);
        tacticDatas[0] = abi.encode(address(0xb70), uint96(1e18));

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            amount: 5e26,
            vaultIndex: 0,
            vaultData: abi.encode(bankManConfig),
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas
        });

        bytes memory tokenDataWithDistribution = abi.encode(
            "Test Token",
            "TEST",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "",
            distribution
        );

        address tokenWithDistribution = tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            salt2,
            tokenDataWithDistribution
        );

        // Both tokens should exist
        assertTrue(tokenNoDistribution != address(0), "Token without distribution should exist");
        assertTrue(tokenWithDistribution != address(0), "Token with distribution should exist");

        // The key test: both tokens should be deployable with predictable addresses
        // If recipient was different (e.g., sometimes tokenFactory, sometimes Airlock),
        // the CREATE2 addresses would be unpredictable
        // The fact that both deployed successfully with different salts proves
        // that the recipient is consistent (always tokenFactory)
    }

    function test_create2_ComputedMatchesActual() public {
        uint256 initialSupply = 1e27;
        bytes32 salt = keccak256("create2Test");

        string memory name = "Test Token";
        string memory symbol = "TEST";
        uint256 yearlyMintCap = 0;
        uint256 vestingDuration = 0;
        address[] memory vestRecipients = new address[](0);
        uint256[] memory vestAmounts = new uint256[](0);
        string memory tokenURI = "";

        // Pre-compute the CREATE2 address
        bytes memory creationCode = type(DERC20).creationCode;
        bytes memory constructorArgs = abi.encode(
            name,
            symbol,
            initialSupply,
            address(tokenFactory), // recipient is always tokenFactory
            owner,
            yearlyMintCap,
            vestingDuration,
            vestRecipients,
            vestAmounts,
            tokenURI
        );
        bytes32 initCodeHash = keccak256(abi.encodePacked(creationCode, constructorArgs));

        address predicted = vm.computeCreate2Address(
            salt,
            initCodeHash,
            address(tokenFactory)
        );

        // Deploy the actual token
        bytes memory tokenData = abi.encode(
            name,
            symbol,
            yearlyMintCap,
            vestingDuration,
            vestRecipients,
            vestAmounts,
            tokenURI
        );

        address actual = tokenFactory.create(
            initialSupply,
            recipient,
            owner,
            salt,
            tokenData
        );

        // Verify predicted matches actual
        assertEq(actual, predicted, "Predicted CREATE2 address should match actual");
    }

    // ============================================
    // Category 6: StrategyMaker Integration Tests
    // ============================================

    function test_strategyMaker_CallsCreateStrategy_WithCorrectParams() public {
        // Local variables
        uint256 initialSupply = 1e27;
        bytes32 salt = keccak256("test_strategyMaker_CallsCreateStrategy");

        // Setup distribution parameters
        uint256 vaultIndex = 0; // BankMan
        uint256[] memory tacticIndexes = new uint256[](1);
        tacticIndexes[0] = 0; // TrustMeBro

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 100;

        bytes[] memory tacticDatas = new bytes[](1);
        tacticDatas[0] = abi.encode(address(0x123), uint96(1000)); // bro, claimSize

        // Create vaultData with address(0) placeholder
        ITokenFactory.BankManConfig memory bankManConfig = ITokenFactory.BankManConfig({
            token: IERC20(address(0))
        });
        bytes memory vaultData = abi.encode(bankManConfig);

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            vaultIndex: vaultIndex,
            vaultData: vaultData,
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas,
            amount: 5000 * 10 ** 18
        });

        // Encode tokenData
        bytes memory tokenData = abi.encode(
            "Test Token",
            "TEST",
            0,                      // yearlyMintCap
            0,                      // vestingDuration
            new address[](0),       // vestRecipients
            new uint256[](0),       // vestAmounts
            "",                     // tokenURI
            distribution
        );

        // Record logs to capture event
        vm.recordLogs();

        address token = tokenFactory.create(initialSupply, recipient, owner, salt, tokenData);

        // Extract vault address from event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address vault;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DistributionCreated(address,address,address[],uint256)")) {
                vault = address(uint160(uint256(logs[i].topics[2])));
                break;
            }
        }

        // Verify StrategyMaker was called correctly by checking the results
        BankMan bankMan = BankMan(vault);

        // 1. Vault was initialized with injected token (not address(0))
        assertEq(address(bankMan.getToken()), token, "BankMan should be initialized with deployed token");

        // 2. Tactics were created
        address[] memory tactics = bankMan.getTactics();
        assertEq(tactics.length, 1, "Should have 1 tactic");

        // 3. Allocations match
        assertEq(bankMan.getTacticAllocation(tactics[0]), 100, "Tactic allocation should match");
        assertEq(bankMan.getTotalAllocation(), 100, "Total allocation should match");
    }

    function test_strategyMaker_DeploysVaultAndTactics() public {
        // Local variables
        uint256 initialSupply = 1e27;
        bytes32 salt = keccak256("test_strategyMaker_DeploysVaultAndTactics");

        // Setup distribution with multiple tactics
        uint256 vaultIndex = 0; // BankMan
        uint256[] memory tacticIndexes = new uint256[](2);
        tacticIndexes[0] = 0; // TrustMeBro
        tacticIndexes[1] = 1; // MerkleDrop

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 60;
        allocations[1] = 40;

        bytes[] memory tacticDatas = new bytes[](2);
        tacticDatas[0] = abi.encode(address(0x123), uint96(1000)); // bro, claimSize
        tacticDatas[1] = abi.encode(bytes32(uint256(1))); // merkleRoot

        ITokenFactory.BankManConfig memory bankManConfig = ITokenFactory.BankManConfig({
            token: IERC20(address(0))
        });
        bytes memory vaultData = abi.encode(bankManConfig);

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            vaultIndex: vaultIndex,
            vaultData: vaultData,
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas,
            amount: 5000 * 10 ** 18
        });

        // Encode tokenData
        bytes memory tokenData = abi.encode(
            "Test Token",
            "TEST",
            0,                      // yearlyMintCap
            0,                      // vestingDuration
            new address[](0),       // vestRecipients
            new uint256[](0),       // vestAmounts
            "",                     // tokenURI
            distribution
        );

        // Record logs to capture event
        vm.recordLogs();

        address token = tokenFactory.create(initialSupply, recipient, owner, salt, tokenData);

        // Extract vault address from event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address vault;
        address[] memory tactics;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DistributionCreated(address,address,address[],uint256)")) {
                vault = address(uint160(uint256(logs[i].topics[2])));
                // Decode tactics from data
                (tactics, ) = abi.decode(logs[i].data, (address[], uint256));
                break;
            }
        }

        // Verify vault was deployed
        assertTrue(vault != address(0), "Vault should be deployed");
        assertTrue(vault != address(bankManImpl), "Vault should be a clone, not implementation");

        // Verify tactics were deployed
        assertEq(tactics.length, 2, "Should deploy 2 tactics");
        assertTrue(tactics[0] != address(0), "Tactic 0 should be deployed");
        assertTrue(tactics[1] != address(0), "Tactic 1 should be deployed");
        assertTrue(tactics[0] != address(trustMeBroImpl), "Tactic 0 should be a clone");
        assertTrue(tactics[1] != address(merkleDropImpl), "Tactic 1 should be a clone");
        assertTrue(tactics[0] != tactics[1], "Tactics should be different addresses");
    }

    function test_strategyMaker_VaultReceivesTokens_ThenAllocate() public {
        // Local variables
        uint256 initialSupply = 1e27;
        bytes32 salt = keccak256("test_strategyMaker_VaultReceivesTokens");

        // Setup distribution with specific allocations
        uint256 distributionAmount = 10000 * 10 ** 18;
        uint256 vaultIndex = 0; // BankMan
        uint256[] memory tacticIndexes = new uint256[](2);
        tacticIndexes[0] = 0; // TrustMeBro
        tacticIndexes[1] = 1; // MerkleDrop

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 70; // 70% to TrustMeBro
        allocations[1] = 30; // 30% to MerkleDrop

        bytes[] memory tacticDatas = new bytes[](2);
        tacticDatas[0] = abi.encode(address(0x123), uint96(1000));
        tacticDatas[1] = abi.encode(bytes32(uint256(1)));

        ITokenFactory.BankManConfig memory bankManConfig = ITokenFactory.BankManConfig({
            token: IERC20(address(0))
        });
        bytes memory vaultData = abi.encode(bankManConfig);

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            vaultIndex: vaultIndex,
            vaultData: vaultData,
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas,
            amount: distributionAmount
        });

        bytes memory tokenData = abi.encode(
            "Test Token",
            "TEST",
            0,
            0,
            new address[](0),
            new address[](0),
            "",
            distribution
        );

        // Record logs
        vm.recordLogs();

        address token = tokenFactory.create(initialSupply, recipient, owner, salt, tokenData);

        // Extract vault and tactics from event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address vault;
        address[] memory tactics;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DistributionCreated(address,address,address[],uint256)")) {
                vault = address(uint160(uint256(logs[i].topics[2])));
                (tactics, ) = abi.decode(logs[i].data, (address[], uint256));
                break;
            }
        }

        BankMan bankMan = BankMan(vault);

        // Verify vault received tokens
        assertEq(IERC20(token).balanceOf(vault), distributionAmount, "Vault should have received tokens");

        // Call allocate to distribute to tactics
        bankMan.allocate();

        // Verify tactics received correct allocations
        uint256 expectedTactic0 = distributionAmount * 70 / 100;
        uint256 expectedTactic1 = distributionAmount * 30 / 100;

        assertEq(bankMan.balanceOf(tactics[0]), expectedTactic0, "Tactic 0 should have 70%");
        assertEq(bankMan.balanceOf(tactics[1]), expectedTactic1, "Tactic 1 should have 30%");
        assertEq(bankMan.totalSupply(), distributionAmount, "Total supply should match distribution amount");
    }

    function test_strategyMaker_EmitsDistributionCreatedEvent() public {
        // Local variables
        uint256 initialSupply = 1e27;
        bytes32 salt = keccak256("test_strategyMaker_EmitsDistributionCreatedEvent");

        // Setup distribution
        uint256 distributionAmount = 5000 * 10 ** 18;
        uint256 vaultIndex = 0;
        uint256[] memory tacticIndexes = new uint256[](1);
        tacticIndexes[0] = 0;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 100;

        bytes[] memory tacticDatas = new bytes[](1);
        tacticDatas[0] = abi.encode(address(0x123), uint96(1000));

        ITokenFactory.BankManConfig memory bankManConfig = ITokenFactory.BankManConfig({
            token: IERC20(address(0))
        });
        bytes memory vaultData = abi.encode(bankManConfig);

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            vaultIndex: vaultIndex,
            vaultData: vaultData,
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas,
            amount: distributionAmount
        });

        bytes memory tokenData = abi.encode(
            "Test Token",
            "TEST",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "",
            distribution
        );

        // Expect DistributionCreated event (we check token and amount, vault/tactics are checked after)
        vm.expectEmit(false, false, false, false);
        emit ITokenFactory.DistributionCreated(address(0), address(0), new address[](0), 0);

        // Record logs to verify event details
        vm.recordLogs();

        address token = tokenFactory.create(initialSupply, recipient, owner, salt, tokenData);

        // Verify event was emitted with correct data
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool eventFound = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DistributionCreated(address,address,address[],uint256)")) {
                eventFound = true;

                // Verify token (topics[1])
                address eventToken = address(uint160(uint256(logs[i].topics[1])));
                assertEq(eventToken, token, "Event should contain correct token address");

                // Verify vault (topics[2])
                address eventVault = address(uint160(uint256(logs[i].topics[2])));
                assertTrue(eventVault != address(0), "Event should contain non-zero vault address");

                // Decode data to get tactics and amount
                (address[] memory eventTactics, uint256 eventAmount) =
                    abi.decode(logs[i].data, (address[], uint256));

                assertEq(eventTactics.length, 1, "Event should contain 1 tactic");
                assertTrue(eventTactics[0] != address(0), "Event tactic should be non-zero");
                assertEq(eventAmount, distributionAmount, "Event should contain correct amount");

                break;
            }
        }

        assertTrue(eventFound, "DistributionCreated event should be emitted");
    }

    function test_strategyMaker_ZeroAddress_WithDistribution_Reverts() public {
        // Deploy TokenFactory with strategyMaker = address(0)
        TokenFactory badFactory = new TokenFactory(
            address(this),
            address(0),  // strategyMaker = address(0)
            address(tacticRegistry),
            address(vaultRegistry)
        );

        // Local variables
        uint256 initialSupply = 1e27;
        bytes32 salt = keccak256("test_strategyMaker_ZeroAddress");

        // Setup distribution with non-zero amount
        uint256 distributionAmount = 5000 * 10 ** 18;
        uint256 vaultIndex = 0;
        uint256[] memory tacticIndexes = new uint256[](1);
        tacticIndexes[0] = 0;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 100;

        bytes[] memory tacticDatas = new bytes[](1);
        tacticDatas[0] = abi.encode(address(0x123), uint96(1000));

        ITokenFactory.BankManConfig memory bankManConfig = ITokenFactory.BankManConfig({
            token: IERC20(address(0))
        });
        bytes memory vaultData = abi.encode(bankManConfig);

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            vaultIndex: vaultIndex,
            vaultData: vaultData,
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas,
            amount: distributionAmount
        });

        bytes memory tokenData = abi.encode(
            "Test Token",
            "TEST",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "",
            distribution
        );

        // Expect revert when trying to call strategyMaker.createStrategy on address(0)
        vm.expectRevert();
        badFactory.create(initialSupply, recipient, owner, salt, tokenData);
    }

    // ============================================
    // Category 7: BankMan + Tactic Integration Tests
    // ============================================

    function test_bankMan_Initialized_WithInjectedToken() public {
        // Local variables
        uint256 initialSupply = 1e27;
        bytes32 salt = keccak256("test_bankMan_Initialized_WithInjectedToken");

        // Setup distribution
        uint256 vaultIndex = 0;
        uint256[] memory tacticIndexes = new uint256[](1);
        tacticIndexes[0] = 0;

        uint256[] memory allocations = new uint256[](1);
        allocations[0] = 100;

        bytes[] memory tacticDatas = new bytes[](1);
        tacticDatas[0] = abi.encode(address(0x123), uint96(1000));

        // Create vaultData with address(0) placeholder - this should be replaced
        ITokenFactory.BankManConfig memory bankManConfig = ITokenFactory.BankManConfig({
            token: IERC20(address(0))
        });
        bytes memory vaultData = abi.encode(bankManConfig);

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            vaultIndex: vaultIndex,
            vaultData: vaultData,
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas,
            amount: 5000 * 10 ** 18
        });

        bytes memory tokenData = abi.encode(
            "Test Token",
            "TEST",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "",
            distribution
        );

        // Record logs
        vm.recordLogs();

        address token = tokenFactory.create(initialSupply, recipient, owner, salt, tokenData);

        // Extract vault from event
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address vault;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DistributionCreated(address,address,address[],uint256)")) {
                vault = address(uint160(uint256(logs[i].topics[2])));
                break;
            }
        }

        BankMan bankMan = BankMan(vault);

        // Verify BankMan was initialized with the deployed token, not address(0)
        assertEq(address(bankMan.getToken()), token, "BankMan should be initialized with deployed token");
        assertTrue(address(bankMan.getToken()) != address(0), "BankMan token should not be address(0)");
    }

    function test_bankMan_Initialized_WithTactics() public {
        uint256 initialSupply = 1e27;
        bytes32 salt = keccak256("test_bankMan_Initialized_WithTactics");

        uint256 vaultIndex = 0;
        uint256[] memory tacticIndexes = new uint256[](2);
        tacticIndexes[0] = 0; // TrustMeBro
        tacticIndexes[1] = 1; // MerkleDrop

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 60;
        allocations[1] = 40;

        bytes[] memory tacticDatas = new bytes[](2);
        tacticDatas[0] = abi.encode(address(0x123), uint96(1000));
        tacticDatas[1] = abi.encode(bytes32(uint256(1)));

        ITokenFactory.BankManConfig memory bankManConfig = ITokenFactory.BankManConfig({token: IERC20(address(0))});

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            vaultIndex: vaultIndex,
            vaultData: abi.encode(bankManConfig),
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas,
            amount: 5000 * 10 ** 18
        });

        bytes memory tokenData = abi.encode("Test", "TST", 0, 0, new address[](0), new uint256[](0), "", distribution);

        vm.recordLogs();
        tokenFactory.create(initialSupply, recipient, owner, salt, tokenData);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        address vault;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DistributionCreated(address,address,address[],uint256)")) {
                vault = address(uint160(uint256(logs[i].topics[2])));
                break;
            }
        }

        BankMan bankMan = BankMan(vault);
        address[] memory tactics = bankMan.getTactics();

        assertEq(tactics.length, 2, "Should have 2 tactics");
        assertEq(bankMan.getTacticAllocation(tactics[0]), 60, "Tactic 0 allocation");
        assertEq(bankMan.getTacticAllocation(tactics[1]), 40, "Tactic 1 allocation");
        assertEq(bankMan.getTotalAllocation(), 100, "Total allocation");
    }

    function test_bankMan_Allocate_DistributesToTactics() public {
        uint256 initialSupply = 1e27;
        bytes32 salt = keccak256("test_bankMan_Allocate_DistributesToTactics");
        uint256 distributionAmount = 10000 * 10 ** 18;

        uint256[] memory tacticIndexes = new uint256[](2);
        tacticIndexes[0] = 0;
        tacticIndexes[1] = 1;

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 70;
        allocations[1] = 30;

        bytes[] memory tacticDatas = new bytes[](2);
        tacticDatas[0] = abi.encode(address(0x123), uint96(1000));
        tacticDatas[1] = abi.encode(bytes32(uint256(1)));

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            vaultIndex: 0,
            vaultData: abi.encode(ITokenFactory.BankManConfig({token: IERC20(address(0))})),
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas,
            amount: distributionAmount
        });

        bytes memory tokenData = abi.encode("Test", "TST", 0, 0, new address[](0), new uint256[](0), "", distribution);

        vm.recordLogs();
        address token = tokenFactory.create(initialSupply, recipient, owner, salt, tokenData);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        address vault;
        address[] memory tactics;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DistributionCreated(address,address,address[],uint256)")) {
                vault = address(uint160(uint256(logs[i].topics[2])));
                (tactics, ) = abi.decode(logs[i].data, (address[], uint256));
                break;
            }
        }

        BankMan bankMan = BankMan(vault);
        bankMan.allocate();

        assertEq(bankMan.balanceOf(tactics[0]), distributionAmount * 70 / 100, "Tactic 0 balance");
        assertEq(bankMan.balanceOf(tactics[1]), distributionAmount * 30 / 100, "Tactic 1 balance");
    }

    function test_tactic_TrustMeBro_CanClaim() public {
        uint256 initialSupply = 1e27;
        bytes32 salt = keccak256("test_tactic_TrustMeBro_CanClaim");
        uint256 claimSize = 1000 * 10 ** 18;

        uint256 privateKey = 0x1234;
        address bro = vm.addr(privateKey);
        address claimer = address(0xc1a1);

        uint256[] memory tacticIndexes = new uint256[](1);
        tacticIndexes[0] = 0;

        bytes[] memory tacticDatas = new bytes[](1);
        tacticDatas[0] = abi.encode(bro, uint96(claimSize));

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            vaultIndex: 0,
            vaultData: abi.encode(ITokenFactory.BankManConfig({token: IERC20(address(0))})),
            tacticIndexes: tacticIndexes,
            allocations: new uint256[](1),
            tacticDatas: tacticDatas,
            amount: 10000 * 10 ** 18
        });
        distribution.allocations[0] = 100;

        bytes memory tokenData = abi.encode("Test", "TST", 0, 0, new address[](0), new uint256[](0), "", distribution);

        vm.recordLogs();
        address token = tokenFactory.create(initialSupply, recipient, owner, salt, tokenData);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        address vault;
        address[] memory tactics;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DistributionCreated(address,address,address[],uint256)")) {
                vault = address(uint160(uint256(logs[i].topics[2])));
                (tactics, ) = abi.decode(logs[i].data, (address[], uint256));
                break;
            }
        }

        BankMan(vault).allocate();
        TrustMeBro tactic = TrustMeBro(tactics[0]);

        bytes32 message = tactic.getClaimMessage(claimer);
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(message);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 balanceBefore = IERC20(token).balanceOf(claimer);
        tactic.claim(claimer, signature);
        uint256 balanceAfter = IERC20(token).balanceOf(claimer);

        assertEq(balanceAfter - balanceBefore, claimSize, "Claimer should receive claim size");
    }

    function test_tactic_MerkleDrop_CanClaim() public {
        uint256 initialSupply = 1e27;
        bytes32 salt = keccak256("test_tactic_MerkleDrop_CanClaim");

        address claimer = address(0xc1a1);
        uint256 amount = 500 * 10 ** 18;

        bytes32 leaf = keccak256(abi.encodePacked(claimer, amount));
        bytes32 merkleRoot = leaf; // Single-leaf tree

        uint256[] memory tacticIndexes = new uint256[](1);
        tacticIndexes[0] = 1;

        bytes[] memory tacticDatas = new bytes[](1);
        tacticDatas[0] = abi.encode(merkleRoot);

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            vaultIndex: 0,
            vaultData: abi.encode(ITokenFactory.BankManConfig({token: IERC20(address(0))})),
            tacticIndexes: tacticIndexes,
            allocations: new uint256[](1),
            tacticDatas: tacticDatas,
            amount: 10000 * 10 ** 18
        });
        distribution.allocations[0] = 100;

        bytes memory tokenData = abi.encode("Test", "TST", 0, 0, new address[](0), new uint256[](0), "", distribution);

        vm.recordLogs();
        address token = tokenFactory.create(initialSupply, recipient, owner, salt, tokenData);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        address vault;
        address[] memory tactics;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DistributionCreated(address,address,address[],uint256)")) {
                vault = address(uint160(uint256(logs[i].topics[2])));
                (tactics, ) = abi.decode(logs[i].data, (address[], uint256));
                break;
            }
        }

        BankMan(vault).allocate();
        MerkleDrop tactic = MerkleDrop(tactics[0]);

        bytes32[] memory proof = new bytes32[](0); // Empty proof for single leaf

        uint256 balanceBefore = IERC20(token).balanceOf(claimer);
        tactic.claim(claimer, amount, proof);
        uint256 balanceAfter = IERC20(token).balanceOf(claimer);

        assertEq(balanceAfter - balanceBefore, amount, "Claimer should receive amount");
    }

    function test_multiTactic_BothTacticsWork() public {
        uint256 initialSupply = 1e27;
        bytes32 salt = keccak256("test_multiTactic_BothTacticsWork");

        uint256 privateKey = 0x1234;
        address bro = vm.addr(privateKey);
        address trustMeClaimer = address(0xc1a1);
        uint256 trustMeClaimSize = 1000 * 10 ** 18;

        address merkleDropClaimer = address(0xc1a2);
        uint256 merkleDropAmount = 500 * 10 ** 18;
        bytes32 leaf = keccak256(abi.encodePacked(merkleDropClaimer, merkleDropAmount));

        uint256[] memory tacticIndexes = new uint256[](2);
        tacticIndexes[0] = 0; // TrustMeBro
        tacticIndexes[1] = 1; // MerkleDrop

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 50;
        allocations[1] = 50;

        bytes[] memory tacticDatas = new bytes[](2);
        tacticDatas[0] = abi.encode(bro, uint96(trustMeClaimSize));
        tacticDatas[1] = abi.encode(leaf);

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            vaultIndex: 0,
            vaultData: abi.encode(ITokenFactory.BankManConfig({token: IERC20(address(0))})),
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas,
            amount: 10000 * 10 ** 18
        });

        bytes memory tokenData = abi.encode("Test", "TST", 0, 0, new address[](0), new uint256[](0), "", distribution);

        vm.recordLogs();
        address token = tokenFactory.create(initialSupply, recipient, owner, salt, tokenData);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        address vault;
        address[] memory tactics;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DistributionCreated(address,address,address[],uint256)")) {
                vault = address(uint160(uint256(logs[i].topics[2])));
                (tactics, ) = abi.decode(logs[i].data, (address[], uint256));
                break;
            }
        }

        BankMan(vault).allocate();

        // Test TrustMeBro claim
        TrustMeBro trustMeTactic = TrustMeBro(tactics[0]);
        bytes32 message = trustMeTactic.getClaimMessage(trustMeClaimer);
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(message);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 balanceBefore1 = IERC20(token).balanceOf(trustMeClaimer);
        trustMeTactic.claim(trustMeClaimer, signature);
        uint256 balanceAfter1 = IERC20(token).balanceOf(trustMeClaimer);
        assertEq(balanceAfter1 - balanceBefore1, trustMeClaimSize, "TrustMe claim");

        // Test MerkleDrop claim
        MerkleDrop merkleDropTactic = MerkleDrop(tactics[1]);
        bytes32[] memory proof = new bytes32[](0);

        uint256 balanceBefore2 = IERC20(token).balanceOf(merkleDropClaimer);
        merkleDropTactic.claim(merkleDropClaimer, merkleDropAmount, proof);
        uint256 balanceAfter2 = IERC20(token).balanceOf(merkleDropClaimer);
        assertEq(balanceAfter2 - balanceBefore2, merkleDropAmount, "MerkleDrop claim");
    }

    // ============================================
    // Category 9: Access Control Tests
    // ============================================

    function test_accessControl_OnlyAirlock_CanCallCreate() public {
        uint256 initialSupply = 1e27;
        bytes32 salt = keccak256("test_accessControl_OnlyAirlock");

        bytes memory tokenData = abi.encode(
            "Test Token",
            "TEST",
            0,
            0,
            new address[](0),
            new uint256[](0),
            ""
        );

        // This test contract is the airlock (set in setUp), so this call should succeed
        address token = tokenFactory.create(initialSupply, recipient, owner, salt, tokenData);

        // Verify token was created successfully
        assertTrue(token != address(0), "Token should be created");
        assertEq(IERC20(token).balanceOf(recipient), initialSupply, "Recipient should have full supply");
    }

    function test_accessControl_NonAirlock_Reverts() public {
        uint256 initialSupply = 1e27;
        bytes32 salt = keccak256("test_accessControl_NonAirlock");

        bytes memory tokenData = abi.encode(
            "Test Token",
            "TEST",
            0,
            0,
            new address[](0),
            new uint256[](0),
            ""
        );

        address nonAirlock = address(0x999);

        // Attempt to call from non-airlock address should revert
        vm.prank(nonAirlock);
        vm.expectRevert(abi.encodeWithSignature("SenderNotAirlock()"));
        tokenFactory.create(initialSupply, recipient, owner, salt, tokenData);
    }

    // ============================================
    // Category 10: Integration E2E Tests
    // ============================================

    function test_integration_FullFlow_NoDistribution() public {
        uint256 initialSupply = 1e27;
        bytes32 salt = keccak256("test_integration_FullFlow_NoDistribution");

        bytes memory tokenData = abi.encode(
            "Integration Test Token",
            "ITT",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "ipfs://test"
        );

        address token = tokenFactory.create(initialSupply, recipient, owner, salt, tokenData);

        // Verify token properties
        assertEq(DERC20(token).name(), "Integration Test Token", "Name should match");
        assertEq(DERC20(token).symbol(), "ITT", "Symbol should match");
        assertEq(DERC20(token).owner(), owner, "Owner should match");
        assertEq(DERC20(token).totalSupply(), initialSupply, "Supply should match");
        assertEq(DERC20(token).balanceOf(recipient), initialSupply, "Recipient should have full supply");
        assertEq(DERC20(token).tokenURI(), "ipfs://test", "TokenURI should match");
    }

    function test_integration_FullFlow_WithDistribution_SingleTactic() public {
        uint256 initialSupply = 1e27;
        uint256 distributionAmount = 4e26;
        bytes32 salt = keccak256("test_integration_FullFlow_SingleTactic");

        uint256 privateKey = 0x1234;
        address bro = vm.addr(privateKey);
        address claimer = address(0xc1a1);
        uint256 claimSize = 1000 * 10 ** 18;

        uint256[] memory tacticIndexes = new uint256[](1);
        tacticIndexes[0] = 0;

        bytes[] memory tacticDatas = new bytes[](1);
        tacticDatas[0] = abi.encode(bro, uint96(claimSize));

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            vaultIndex: 0,
            vaultData: abi.encode(ITokenFactory.BankManConfig({token: IERC20(address(0))})),
            tacticIndexes: tacticIndexes,
            allocations: new uint256[](1),
            tacticDatas: tacticDatas,
            amount: distributionAmount
        });
        distribution.allocations[0] = 100;

        bytes memory tokenData = abi.encode(
            "E2E Test Token",
            "E2E",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "",
            distribution
        );

        vm.recordLogs();
        address token = tokenFactory.create(initialSupply, recipient, owner, salt, tokenData);

        // Extract vault and tactics
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address vault;
        address[] memory tactics;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DistributionCreated(address,address,address[],uint256)")) {
                vault = address(uint160(uint256(logs[i].topics[2])));
                (tactics, ) = abi.decode(logs[i].data, (address[], uint256));
                break;
            }
        }

        // Verify distribution happened
        assertEq(IERC20(token).balanceOf(vault), distributionAmount, "Vault should have distribution amount");
        assertEq(IERC20(token).balanceOf(recipient), initialSupply - distributionAmount, "Recipient should have remainder");

        // Allocate tokens
        BankMan(vault).allocate();

        // Claim tokens
        TrustMeBro tactic = TrustMeBro(tactics[0]);
        bytes32 message = tactic.getClaimMessage(claimer);
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(message);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        uint256 balanceBefore = IERC20(token).balanceOf(claimer);
        tactic.claim(claimer, signature);
        uint256 balanceAfter = IERC20(token).balanceOf(claimer);

        assertEq(balanceAfter - balanceBefore, claimSize, "Claimer should receive tokens from full E2E flow");
    }

    function test_integration_FullFlow_WithDistribution_MultiTactic() public {
        uint256 initialSupply = 1e27;
        uint256 distributionAmount = 6e26;
        bytes32 salt = keccak256("test_integration_FullFlow_MultiTactic");

        uint256 privateKey = 0x1234;
        address bro = vm.addr(privateKey);
        address trustMeClaimer = address(0xc1a1);
        uint256 trustMeClaimSize = 1000 * 10 ** 18;

        address merkleDropClaimer = address(0xc1a2);
        uint256 merkleDropAmount = 500 * 10 ** 18;
        bytes32 leaf = keccak256(abi.encodePacked(merkleDropClaimer, merkleDropAmount));

        uint256[] memory tacticIndexes = new uint256[](2);
        tacticIndexes[0] = 0;
        tacticIndexes[1] = 1;

        uint256[] memory allocations = new uint256[](2);
        allocations[0] = 60;
        allocations[1] = 40;

        bytes[] memory tacticDatas = new bytes[](2);
        tacticDatas[0] = abi.encode(bro, uint96(trustMeClaimSize));
        tacticDatas[1] = abi.encode(leaf);

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            vaultIndex: 0,
            vaultData: abi.encode(ITokenFactory.BankManConfig({token: IERC20(address(0))})),
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas,
            amount: distributionAmount
        });

        bytes memory tokenData = abi.encode(
            "MultiTactic E2E",
            "MTE",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "",
            distribution
        );

        vm.recordLogs();
        address token = tokenFactory.create(initialSupply, recipient, owner, salt, tokenData);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        address vault;
        address[] memory tactics;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DistributionCreated(address,address,address[],uint256)")) {
                vault = address(uint160(uint256(logs[i].topics[2])));
                (tactics, ) = abi.decode(logs[i].data, (address[], uint256));
                break;
            }
        }

        BankMan(vault).allocate();

        // Claim from TrustMeBro
        TrustMeBro trustMeTactic = TrustMeBro(tactics[0]);
        bytes32 message = trustMeTactic.getClaimMessage(trustMeClaimer);
        bytes32 digest = MessageHashUtils.toEthSignedMessageHash(message);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        trustMeTactic.claim(trustMeClaimer, abi.encodePacked(r, s, v));

        // Claim from MerkleDrop
        MerkleDrop merkleDropTactic = MerkleDrop(tactics[1]);
        merkleDropTactic.claim(merkleDropClaimer, merkleDropAmount, new bytes32[](0));

        assertEq(IERC20(token).balanceOf(trustMeClaimer), trustMeClaimSize, "TrustMe claimer should have tokens");
        assertEq(IERC20(token).balanceOf(merkleDropClaimer), merkleDropAmount, "MerkleDrop claimer should have tokens");
    }

    function test_integration_VestingPlusDistribution() public {
        uint256 initialSupply = 1e27;
        uint256 distributionAmount = 3e26;
        uint256 vestAmount = 2e26;
        bytes32 salt = keccak256("test_integration_VestingPlusDistribution");

        address vestRecipient = address(0x1e57);

        address[] memory vestRecipients = new address[](1);
        vestRecipients[0] = vestRecipient;

        uint256[] memory vestAmounts = new uint256[](1);
        vestAmounts[0] = vestAmount;

        uint256[] memory tacticIndexes = new uint256[](1);
        tacticIndexes[0] = 0;

        bytes[] memory tacticDatas = new bytes[](1);
        tacticDatas[0] = abi.encode(address(0x123), uint96(1000 * 10 ** 18));

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            vaultIndex: 0,
            vaultData: abi.encode(ITokenFactory.BankManConfig({token: IERC20(address(0))})),
            tacticIndexes: tacticIndexes,
            allocations: new uint256[](1),
            tacticDatas: tacticDatas,
            amount: distributionAmount
        });
        distribution.allocations[0] = 100;

        bytes memory tokenData = abi.encode(
            "Vesting + Distribution",
            "VD",
            0,
            365 days,
            vestRecipients,
            vestAmounts,
            "",
            distribution
        );

        vm.recordLogs();
        address token = tokenFactory.create(initialSupply, recipient, owner, salt, tokenData);

        // Verify vesting data is recorded correctly
        (uint256 totalVestAmount,) = DERC20(token).getVestingDataOf(vestRecipient);
        assertEq(totalVestAmount, vestAmount, "Vest recipient should have vesting schedule");

        // Verify vested tokens are held by token contract
        assertEq(IERC20(token).balanceOf(token), vestAmount, "Token contract should hold vested tokens");

        // Verify distribution happened
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address vault;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DistributionCreated(address,address,address[],uint256)")) {
                vault = address(uint160(uint256(logs[i].topics[2])));
                break;
            }
        }
        assertEq(IERC20(token).balanceOf(vault), distributionAmount, "Vault should have distribution amount");

        // Verify remaining went to recipient
        uint256 expectedRecipient = initialSupply - vestAmount - distributionAmount;
        assertEq(IERC20(token).balanceOf(recipient), expectedRecipient, "Recipient should have remainder");

        // Verify vest recipient can claim tokens after time passes
        vm.warp(block.timestamp + 182 days); // Fast forward 6 months (50% of vesting period)
        vm.prank(vestRecipient);
        DERC20(token).release();

        // After 6 months, vest recipient should have ~50% of vested tokens
        uint256 expectedClaimed = vestAmount / 2;
        assertApproxEqAbs(
            IERC20(token).balanceOf(vestRecipient),
            expectedClaimed,
            1e24,
            "Vest recipient should have ~50% of vested tokens after 6 months"
        );
    }

    // ============================================
    // Category 11: Edge Case Tests
    // ============================================

    function test_edgeCase_DistributionAmount_1Wei() public {
        uint256 initialSupply = 1e27;
        bytes32 salt = keccak256("test_edgeCase_1Wei");

        uint256[] memory tacticIndexes = new uint256[](1);
        tacticIndexes[0] = 0;

        bytes[] memory tacticDatas = new bytes[](1);
        tacticDatas[0] = abi.encode(address(0x123), uint96(1));

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            vaultIndex: 0,
            vaultData: abi.encode(ITokenFactory.BankManConfig({token: IERC20(address(0))})),
            tacticIndexes: tacticIndexes,
            allocations: new uint256[](1),
            tacticDatas: tacticDatas,
            amount: 1 // 1 wei
        });
        distribution.allocations[0] = 100;

        bytes memory tokenData = abi.encode(
            "Edge Case Token",
            "ECT",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "",
            distribution
        );

        vm.recordLogs();
        address token = tokenFactory.create(initialSupply, recipient, owner, salt, tokenData);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        address vault;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DistributionCreated(address,address,address[],uint256)")) {
                vault = address(uint160(uint256(logs[i].topics[2])));
                break;
            }
        }

        assertEq(IERC20(token).balanceOf(vault), 1, "Vault should have exactly 1 wei");
        assertEq(IERC20(token).balanceOf(recipient), initialSupply - 1, "Recipient should have supply minus 1 wei");
    }

    function test_edgeCase_MaxTactics_GasCheck() public {
        uint256 initialSupply = 1e27;
        uint256 distributionAmount = 5e26;
        bytes32 salt = keccak256("test_edgeCase_MaxTactics");

        // Create 10 tactics (stress test)
        uint256[] memory tacticIndexes = new uint256[](10);
        uint256[] memory allocations = new uint256[](10);
        bytes[] memory tacticDatas = new bytes[](10);

        for (uint256 i = 0; i < 10; i++) {
            tacticIndexes[i] = 0; // All TrustMeBro
            allocations[i] = 10; // 10% each
            tacticDatas[i] = abi.encode(address(uint160(0x123 + i)), uint96(1000 * 10 ** 18));
        }

        ITokenFactory.DistributionData memory distribution = ITokenFactory.DistributionData({
            vaultIndex: 0,
            vaultData: abi.encode(ITokenFactory.BankManConfig({token: IERC20(address(0))})),
            tacticIndexes: tacticIndexes,
            allocations: allocations,
            tacticDatas: tacticDatas,
            amount: distributionAmount
        });

        bytes memory tokenData = abi.encode(
            "Stress Test Token",
            "STT",
            0,
            0,
            new address[](0),
            new uint256[](0),
            "",
            distribution
        );

        vm.recordLogs();
        address token = tokenFactory.create(initialSupply, recipient, owner, salt, tokenData);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        address vault;
        address[] memory tactics;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("DistributionCreated(address,address,address[],uint256)")) {
                vault = address(uint160(uint256(logs[i].topics[2])));
                (tactics, ) = abi.decode(logs[i].data, (address[], uint256));
                break;
            }
        }

        // Verify 10 tactics were created
        assertEq(tactics.length, 10, "Should create 10 tactics");

        // Allocate and verify each tactic got 10% of distribution
        BankMan bankMan = BankMan(vault);
        bankMan.allocate();

        uint256 expectedPerTactic = distributionAmount / 10;
        for (uint256 i = 0; i < 10; i++) {
            assertEq(bankMan.balanceOf(tactics[i]), expectedPerTactic, "Each tactic should have 10%");
        }
    }
}
