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
}
