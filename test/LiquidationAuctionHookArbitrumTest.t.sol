// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import {IERC20} from "openzeppelin5/token/ERC20/IERC20.sol";
import {ISiloConfig} from "silo-contracts-v2/silo-core/contracts/interfaces/ISiloConfig.sol";
import {ISilo} from "silo-contracts-v2/silo-core/contracts/interfaces/ISilo.sol";
import {Hook} from "silo-contracts-v2/silo-core/contracts/lib/Hook.sol";
import {LiquidationAuctionHook} from "../contracts/LiquidationAuctionHook.sol";

import {DeploySilo} from "./common/DeploySilo.sol";
import {Labels} from "./common/Labels.sol";
import {ArbitrumLib} from "./common/ArbitrumLib.sol";

/**
 * @title LiquidationAuctionHookArbitrumTest
 * @notice Comprehensive test suite for the LiquidationAuctionHook contract
 * @dev Tests use Arbitrum fork to simulate real network conditions
 *
 * Test categories:
 * 1. Bidding functionality and edge cases
 * 2. Auction lifecycle and rollover
 * 3. Liquidation authorization
 * 4. Hook integration with Silo Protocol
 * 5. Refund mechanics
 * 6. Contract security
 */
contract LiquidationAuctionHookArbitrumTest is Labels {
    ISiloConfig public siloConfig;
    LiquidationAuctionHook public auctionHook;

    // Test addresses (using Foundry's makeAddr helper)
    address liquidityProvider = makeAddr("liquidityProvider");
    address bidderA = makeAddr("bidderA");
    address bidderB = makeAddr("bidderB");
    address borrower = makeAddr("borrower");

    // Error selectors for expectRevert testing
    bytes4 constant SelfBiddingNotAllowed =
        bytes4(keccak256("SelfBiddingNotAllowed()"));
    bytes4 constant BidTooLow = bytes4(keccak256("BidTooLow()"));
    bytes4 constant UnauthorizedLiquidator =
        bytes4(keccak256("UnauthorizedLiquidator()"));

    /**
     * @notice Set up the test environment
     * @dev Creates Arbitrum fork, deploys Silo protocol contracts,
     *      initializes auction hook, and sets up test accounts with WETH
     */
    function setUp() public {
        // Create a fork using the Arbitrum RPC defined in your environment.
        uint256 blockToFork = 302603188;
        string memory rpcUrl = vm.envOr(
            "RPC_ARBITRUM",
            string("https://arb1.arbitrum.io/rpc")
        );
        vm.createSelectFork(rpcUrl, blockToFork);

        DeploySilo deployer = new DeploySilo();
        // Initialize with (owner, feeReceiver, weth address).
        // For testing we set both owner and feeReceiver to this contract.
        bytes memory initData = abi.encode(
            address(this),
            address(this),
            ArbitrumLib.WETH
        );
        siloConfig = deployer.deploySilo(
            ArbitrumLib.SILO_DEPLOYER,
            address(new LiquidationAuctionHook()),
            initData
        );

        // Retrieve our hook from the silo config.
        auctionHook = LiquidationAuctionHook(_getHookAddress(siloConfig));

        // Label the silo config for clarity in trace outputs
        _setLabels(siloConfig);

        // Deal WETH to test accounts
        deal(ArbitrumLib.WETH, bidderA, 100 ether);
        deal(ArbitrumLib.WETH, bidderB, 100 ether);

        // Approve WETH for the auction hook
        vm.startPrank(bidderA);
        IERC20(ArbitrumLib.WETH).approve(
            address(auctionHook),
            type(uint256).max
        );
        vm.stopPrank();

        vm.startPrank(bidderB);
        IERC20(ArbitrumLib.WETH).approve(
            address(auctionHook),
            type(uint256).max
        );
        vm.stopPrank();
    }

    // --- Bidding Tests ---

    /**
     * @notice Test that the contract accepts minimum bid amounts
     * @dev Verifies that:
     *      1. The minimum possible bid (1 wei) is accepted
     *      2. Subsequent bids must be higher than current highest bid
     *      3. Even a 1 wei increase is considered a valid higher bid
     */
    function testMinimumBidAmount() public {
        vm.prank(bidderA);
        auctionHook.placeBid(borrower, 1); // Minimum possible bid (1 wei)

        (address bidder, uint256 amount) = auctionHook.getCurrentBidder(
            borrower
        );
        assertEq(bidder, bidderA, "Bidder should be bidderA");
        assertEq(amount, 1, "Bid amount should be 1 wei");

        // Even a 1 wei increase should be accepted
        vm.prank(bidderB);
        auctionHook.placeBid(borrower, 2);

        (bidder, amount) = auctionHook.getCurrentBidder(borrower);
        assertEq(bidder, bidderB, "Bidder should be bidderB");
        assertEq(amount, 2, "Bid amount should be 2 wei");
    }

    /**
     * @notice Test that the contract can handle extremely large bid amounts
     * @dev Verifies that the maximum uint128 value can be used as a bid amount
     *      without overflows or other issues
     */
    function testMaximumBidAmount() public {
        // Deal a massive amount of WETH
        deal(ArbitrumLib.WETH, bidderA, type(uint128).max);
        vm.prank(bidderA);
        auctionHook.placeBid(borrower, type(uint128).max);

        (address bidder, uint256 amount) = auctionHook.getCurrentBidder(
            borrower
        );
        assertEq(bidder, bidderA);
        assertEq(amount, type(uint128).max);
    }

    /**
     * @notice Test a bidder outbidding themselves
     * @dev Verifies that a bidder can increase their own bid if they're
     *      already the highest bidder
     */
    function testSelfOutbid() public {
        vm.startPrank(bidderA);

        // First bid
        auctionHook.placeBid(borrower, 1 ether);

        // Same bidder increases their own bid
        auctionHook.placeBid(borrower, 2 ether);
        vm.stopPrank();

        (address bidder, uint256 amount) = auctionHook.getCurrentBidder(
            borrower
        );
        assertEq(bidder, bidderA, "Bidder should still be bidderA");
        assertEq(amount, 2 ether, "Bid amount should be updated to 2 ether");
    }

    /**
     * @notice Test prevention of borrowers bidding on their own liquidation
     * @dev Verifies that the contract prevents self-bidding as a security
     *      measure to maintain auction integrity
     */
    function testSelfBiddingReverts() public {
        vm.prank(borrower);
        vm.expectRevert(SelfBiddingNotAllowed);
        auctionHook.placeBid(borrower, 1 ether);
    }

    /**
     * @notice Test bid placement and automatic refund when outbid
     * @dev Verifies that:
     *      1. Bidder's balance decreases when a bid is placed
     *      2. Previous bidder receives a full refund when outbid
     *      3. The contract properly tracks the current highest bidder
     */
    function testPlaceBidAndRefund() public {
        // Record bidderA's initial balance.
        uint256 initialBalance = IERC20(ArbitrumLib.WETH).balanceOf(bidderA);

        // bidderA places a bid.
        vm.prank(bidderA);
        auctionHook.placeBid(borrower, 1 ether);

        // Check that bidderA's balance has decreased.
        uint256 afterBidBalance = IERC20(ArbitrumLib.WETH).balanceOf(bidderA);
        assertEq(afterBidBalance, initialBalance - 1 ether);

        // bidderB places a higher bid, which should automatically refund bidderA
        vm.prank(bidderB);
        auctionHook.placeBid(borrower, 2 ether);

        // Check that bidderA's balance is fully refunded.
        uint256 finalBalance = IERC20(ArbitrumLib.WETH).balanceOf(bidderA);
        assertEq(finalBalance, initialBalance);
    }

    /**
     * @notice Test rejection of bids lower than current highest bid
     * @dev Verifies that the contract enforces bid amounts must be higher
     *      than the current highest bid
     */
    function testBidTooLow() public {
        vm.prank(bidderA);
        auctionHook.placeBid(borrower, 2 ether);

        vm.prank(bidderB);
        vm.expectRevert(BidTooLow);
        auctionHook.placeBid(borrower, 1 ether);
    }

    // --- Auction Rollover & Authorized Liquidator Tests ---

    /**
     * @notice Test progression of auction numbers over time
     * @dev Verifies that auction numbers increment correctly based on
     *      block number progression
     */
    function testAuctionNumberProgress() public {
        uint256 startingAuction = auctionHook.getCurrentAuctionNumber();

        // Move forward exactly one auction period
        vm.roll(block.number + auctionHook.AUCTION_BLOCKS());

        uint256 nextAuction = auctionHook.getCurrentAuctionNumber();
        assertEq(
            nextAuction,
            startingAuction + 1,
            "Auction number should increment by 1"
        );
    }

    /**
     * @notice Test accuracy of remaining blocks calculation
     * @dev Verifies that getBlocksRemaining returns the correct number
     *      of blocks left in the current auction at different points
     */
    function testBlocksRemainingCalculation() public {
        // Start at the beginning of a new auction
        uint256 auctionStart = auctionHook.getCurrentAuctionNumber() *
            auctionHook.AUCTION_BLOCKS();
        vm.roll(auctionStart);

        assertEq(
            auctionHook.getBlocksRemaining(),
            auctionHook.AUCTION_BLOCKS(),
            "Full auction period should remain"
        );

        // Move halfway through the auction
        vm.roll(auctionStart + auctionHook.AUCTION_BLOCKS() / 2);
        assertEq(
            auctionHook.getBlocksRemaining(),
            auctionHook.AUCTION_BLOCKS() / 2,
            "Half auction period should remain"
        );
    }

    /**
     * @notice Test authorized liquidator determination across auction boundaries
     * @dev Verifies that after an auction ends, the highest bidder becomes
     *      the authorized liquidator for the next period
     */
    function testAuthorizedLiquidator() public {
        // bidderA places a bid in the current auction.
        vm.prank(bidderA);
        auctionHook.placeBid(borrower, 1 ether);

        uint256 currentAuction = auctionHook.getCurrentAuctionNumber();
        // Advance block number to the next auction.
        vm.roll((currentAuction + 1) * auctionHook.AUCTION_BLOCKS());

        (address solver, uint256 bid) = auctionHook.getAuthorizedLiquidator(
            borrower
        );
        assertEq(solver, bidderA, "Authorized liquidator should be bidderA");
        assertEq(bid, 1 ether, "Authorized bid should be 1 ether");
    }

    // --- Hook (beforeAction) Tests ---

    /**
     * @notice Test hook allows authorized liquidator to perform liquidation
     * @dev Verifies that the beforeAction hook permits the auction winner
     *      to execute liquidation actions
     */
    function testBeforeActionAuthorized() public {
        // bidderA places a bid.
        vm.prank(bidderA);
        auctionHook.placeBid(borrower, 1 ether);

        // Advance to next auction so bidderA becomes the authorized liquidator.
        uint256 currentAuction = auctionHook.getCurrentAuctionNumber();
        vm.roll((currentAuction + 1) * auctionHook.AUCTION_BLOCKS());

        // Prepare a liquidation input.
        bytes memory liquidationInput = abi.encode(borrower);

        // Get the first silo address
        (address silo0, ) = siloConfig.getSilos();

        // Authorized call: bidderA (the winning bidder from the previous auction) calls beforeAction.
        vm.prank(bidderA);
        // Should execute without reverting.
        auctionHook.beforeAction(silo0, Hook.LIQUIDATION, liquidationInput);
    }

    /**
     * @notice Test hook prevents unauthorized liquidators
     * @dev Verifies that the beforeAction hook reverts when a non-authorized
     *      liquidator attempts to perform a liquidation
     */
    function testBeforeActionUnauthorized() public {
        // bidderA places a bid.
        vm.prank(bidderA);
        auctionHook.placeBid(borrower, 1 ether);

        // Advance to next auction.
        uint256 currentAuction = auctionHook.getCurrentAuctionNumber();
        vm.roll((currentAuction + 1) * auctionHook.AUCTION_BLOCKS());

        // Prepare liquidation input.
        bytes memory liquidationInput = abi.encode(borrower);

        // Get the first silo address
        (address silo0, ) = siloConfig.getSilos();

        // Unauthorized call: bidderB (not the authorized liquidator) attempts to call beforeAction.
        vm.prank(bidderB);
        vm.expectRevert(UnauthorizedLiquidator);
        auctionHook.beforeAction(silo0, Hook.LIQUIDATION, liquidationInput);
    }

    /**
     * @notice Test multiple borrowers with separate auctions
     * @dev Verifies that auctions for different borrowers are properly isolated
     *      and don't affect each other
     */
    function testMultipleBorrowerAuctions() public {
        address borrower1 = makeAddr("borrower1");
        address borrower2 = makeAddr("borrower2");

        // bidderA bids for borrower1
        vm.prank(bidderA);
        auctionHook.placeBid(borrower1, 1 ether);

        // bidderB bids for borrower2
        vm.prank(bidderB);
        auctionHook.placeBid(borrower2, 2 ether);

        // Check isolated auction state
        (address bidder1, uint256 amount1) = auctionHook.getCurrentBidder(
            borrower1
        );
        (address bidder2, uint256 amount2) = auctionHook.getCurrentBidder(
            borrower2
        );

        assertEq(bidder1, bidderA, "Bidder for borrower1 should be bidderA");
        assertEq(
            amount1,
            1 ether,
            "Bid amount for borrower1 should be 1 ether"
        );

        assertEq(bidder2, bidderB, "Bidder for borrower2 should be bidderB");
        assertEq(
            amount2,
            2 ether,
            "Bid amount for borrower2 should be 2 ether"
        );
    }

    /**
     * @notice Test auction history and liquidator reset behavior
     * @dev Verifies that:
     *      1. Auction history properly tracks winners across multiple auctions
     *      2. When an auction has no bids, the authorized liquidator is reset
     */
    function testAuctionHistoryPersistence() public {
        // bidderA wins auction 1
        vm.prank(bidderA);
        auctionHook.placeBid(borrower, 1 ether);

        // Move to auction 2
        uint256 currentAuction = auctionHook.getCurrentAuctionNumber();
        vm.roll((currentAuction + 1) * auctionHook.AUCTION_BLOCKS());

        // bidderB wins auction 2
        vm.prank(bidderB);
        auctionHook.placeBid(borrower, 2 ether);

        // Move to auction 3
        vm.roll((currentAuction + 2) * auctionHook.AUCTION_BLOCKS());

        // Check that the authorized liquidator is bidderB (winner of auction 2)
        (address solver, uint256 bid) = auctionHook.getAuthorizedLiquidator(
            borrower
        );
        assertEq(solver, bidderB, "Authorized liquidator should be bidderB");
        assertEq(bid, 2 ether, "Authorized bid should be 2 ether");

        // Move to auction 4
        vm.roll((currentAuction + 3) * auctionHook.AUCTION_BLOCKS());

        // No bids in auction 3, so no one is the authorized liquidator. Thus
        // the authorized liquidator should be the zero address, and anyone
        // can liquidate.
        (solver, bid) = auctionHook.getAuthorizedLiquidator(borrower);
        assertEq(
            solver,
            address(0),
            "Authorized liquidator should be reset to address(0)"
        );
        assertEq(bid, 0, "Authorized bid should be reset to 0");
    }

    /**
     * @notice Test behavior when no bids are placed in an auction
     * @dev Verifies that when no bids are placed:
     *      1. No authorized liquidator exists (address(0))
     *      2. Any address can perform liquidations
     */
    function testNoAuthorizedLiquidator() public {
        // No bids placed

        // Move to next auction
        uint256 currentAuction = auctionHook.getCurrentAuctionNumber();
        vm.roll((currentAuction + 1) * auctionHook.AUCTION_BLOCKS());

        // Check that there's no authorized liquidator
        (address solver, uint256 bid) = auctionHook.getAuthorizedLiquidator(
            borrower
        );
        assertEq(solver, address(0), "No authorized liquidator should exist");
        assertEq(bid, 0, "Authorized bid should be 0");

        // Prepare liquidation input
        bytes memory liquidationInput = abi.encode(borrower);
        (address silo0, ) = siloConfig.getSilos();

        // Anyone should be able to liquidate when there's no authorized liquidator
        vm.prank(bidderA);
        auctionHook.beforeAction(silo0, Hook.LIQUIDATION, liquidationInput);

        vm.prank(bidderB);
        auctionHook.beforeAction(silo0, Hook.LIQUIDATION, liquidationInput);
    }

    /**
     * @notice Test hook configuration with multiple actions
     * @dev Verifies that:
     *      1. The LIQUIDATION action bit is correctly set in the hooks bitmap
     *      2. The hook only affects liquidation actions and ignores others
     */
    function testHookConfigurationWithMultipleActions() public {
        // Get the hook configuration for the first silo
        (address silo0, ) = siloConfig.getSilos();
        (uint24 hooksBefore, uint24 hooksAfter) = auctionHook
            .hookReceiverConfig(silo0);

        // Check that the LIQUIDATION action bit is set in the before hooks
        assertTrue(
            (hooksBefore & uint24(Hook.LIQUIDATION)) != 0,
            "LIQUIDATION action should be configured in the before hooks"
        );

        // For non-liquidation actions, the hook should do nothing
        bytes memory randomInput = abi.encode(address(0));
        vm.prank(bidderA);
        // This should execute without reverting for non-LIQUIDATION actions
        auctionHook.beforeAction(silo0, Hook.BORROW, randomInput);
    }

    /**
     * @notice Test gas usage with multiple bidders
     * @dev Measures gas consumption across multiple sequential bids and
     *      verifies refund mechanics work for each previous bidder
     */
    function testGasUsageMultipleBidders() public {
        uint256 bidderCount = 5;
        address[] memory bidders = new address[](bidderCount);

        // Create and fund multiple bidders
        for (uint256 i = 0; i < bidderCount; i++) {
            bidders[i] = makeAddr(string(abi.encodePacked("bidder", i)));
            deal(ArbitrumLib.WETH, bidders[i], 100 ether);

            vm.startPrank(bidders[i]);
            IERC20(ArbitrumLib.WETH).approve(
                address(auctionHook),
                type(uint256).max
            );
            vm.stopPrank();
        }

        // Each bidder places a bid with incrementing amounts
        for (uint256 i = 0; i < bidderCount; i++) {
            uint256 bidAmount = (i + 1) * 1 ether;

            uint256 gasBefore = gasleft();
            vm.prank(bidders[i]);
            auctionHook.placeBid(borrower, bidAmount);
            uint256 gasUsed = gasBefore - gasleft();

            console.log("Gas used for bid %s: %s", i + 1, gasUsed);

            // Verify each refund occurs correctly
            if (i > 0) {
                // Previous bidder should be refunded
                uint256 balance = IERC20(ArbitrumLib.WETH).balanceOf(
                    bidders[i - 1]
                );
                assertEq(
                    balance,
                    100 ether,
                    "Previous bidder should be fully refunded"
                );
            }
        }

        // Last bidder should have their bid amount deducted
        uint256 finalBidderBalance = IERC20(ArbitrumLib.WETH).balanceOf(
            bidders[bidderCount - 1]
        );
        assertEq(
            finalBidderBalance,
            100 ether - bidderCount * 1 ether,
            "Final bidder's balance should be reduced"
        );
    }

    /**
     * @notice Test refund mechanism with extreme value differences
     * @dev Verifies refund mechanics work correctly with very small initial bids
     *      followed by very large bids
     */
    function testExtremeRefundScenarios() public {
        // Test very small initial bid followed by very large bid
        vm.prank(bidderA);
        auctionHook.placeBid(borrower, 1); // 1 wei

        // Deal a lot of WETH to bidderB
        deal(ArbitrumLib.WETH, bidderB, 1000000 ether);
        vm.prank(bidderB);
        auctionHook.placeBid(borrower, 1000000 ether);

        // Check bidderA was correctly refunded the small amount
        uint256 balanceA = IERC20(ArbitrumLib.WETH).balanceOf(bidderA);
        assertEq(balanceA, 100 ether, "bidderA should be refunded 1 wei");
    }

    /**
     * @notice Test behavior with insufficient token balance
     * @dev Verifies that attempting to bid without sufficient token balance
     *      results in revert
     */
    function testInsufficientWethBalance() public {
        // Create a bidder with no WETH
        address poorBidder = makeAddr("poorBidder");

        // Approve WETH spending (but have no balance)
        vm.startPrank(poorBidder);
        IERC20(ArbitrumLib.WETH).approve(
            address(auctionHook),
            type(uint256).max
        );

        // Attempt to place a bid (should revert due to insufficient balance)
        vm.expectRevert(); // SafeERC20: ERC20 operation did not succeed
        auctionHook.placeBid(borrower, 1 ether);
        vm.stopPrank();
    }

    /**
     * @notice Test handling of zero address and zero amount inputs
     * @dev Verifies appropriate error handling for invalid inputs:
     *      1. Zero borrower address
     *      2. Zero bid amount
     */
    function testZeroAddressHandling() public {
        // Test with zero borrower address
        vm.expectRevert("Borrower cannot be zero address");
        vm.prank(bidderA);
        auctionHook.placeBid(address(0), 1 ether);

        // Test zero bid amount
        vm.expectRevert("Bid amount must be positive");
        vm.prank(bidderA);
        auctionHook.placeBid(borrower, 0);
    }

    /**
     * @notice Test fee collection functionality
     * @dev Verifies that fee collection reverts as expected in the
     *      simplified model
     */
    function testCollectFeesReverts() public {
        vm.expectRevert("Fee collection not supported in simplified model");
        auctionHook.collectFees();
    }

    /**
     * @notice Test ownership transfer mechanism
     * @dev Verifies the two-step ownership transfer process:
     *      1. Current owner proposes a new owner
     *      2. New owner must accept ownership
     *      3. Only after acceptance is ownership transferred
     */
    function testOwnershipTransfer() public {
        address newOwner = makeAddr("newOwner");

        // Begin ownership transfer
        auctionHook.transferOwnership(newOwner);

        // Ownership should not be transferred yet
        assertEq(
            auctionHook.owner(),
            address(this),
            "Owner should not change before acceptance"
        );

        // Accept ownership
        vm.prank(newOwner);
        auctionHook.acceptOwnership();

        assertEq(
            auctionHook.owner(),
            newOwner,
            "Owner should be updated after acceptance"
        );

        // New owner should be able to call owner functions
        vm.prank(newOwner);
        vm.expectRevert("Fee collection not supported in simplified model");
        auctionHook.collectFees();
    }

    /**
     * @notice Test prevention of reinitialization
     * @dev Verifies that the initializer modifier prevents the contract
     *      from being initialized more than once
     */
    function testReinitializationPrevention() public {
        bytes memory initData = abi.encode(
            address(this),
            address(this),
            ArbitrumLib.WETH
        );

        vm.expectRevert();
        auctionHook.initialize(siloConfig, initData);
    }

    /**
     * @notice Test bidding pattern with small incremental bids
     * @dev Verifies contract behavior with many small incremental bids:
     *      1. Each new bid correctly updates the state
     *      2. Final state correctly reflects the expected winner
     */
    function testIncrementalBidding() public {
        uint256 initialBid = 1 ether;
        uint256 increment = 0.01 ether;
        uint256 numBids = 10;

        // Start with bidderA
        vm.prank(bidderA);
        auctionHook.placeBid(borrower, initialBid);

        // Alternate bids between bidderA and bidderB with small increments
        for (uint256 i = 1; i <= numBids; i++) {
            address bidder = i % 2 == 0 ? bidderA : bidderB;
            uint256 bidAmount = initialBid + (i * increment);

            vm.prank(bidder);
            auctionHook.placeBid(borrower, bidAmount);

            // Verify bid was recorded correctly
            (address currentBidder, uint256 currentBid) = auctionHook
                .getCurrentBidder(borrower);
            assertEq(currentBidder, bidder, "Current bidder should match");
            assertEq(currentBid, bidAmount, "Current bid amount should match");
        }

        // Final bidder should be bidderA or bidderB depending on the number of iterations
        address expectedFinalBidder = numBids % 2 == 0 ? bidderA : bidderB;
        (address finalBidder, ) = auctionHook.getCurrentBidder(borrower);
        assertEq(
            finalBidder,
            expectedFinalBidder,
            "Final bidder should match expected"
        );
    }

    /**
     * @notice Test liquidation permissions after multiple empty auctions
     * @dev Verifies:
     *      1. Liquidation rights reset after one empty auction
     *      2. Anyone can liquidate after authorized liquidator is reset
     */
    function testLiquidationAfterEmptyAuctions() public {
        // bidderA wins auction 1
        vm.prank(bidderA);
        auctionHook.placeBid(borrower, 1 ether);

        // Move through multiple auctions with no bids
        uint256 currentAuction = auctionHook.getCurrentAuctionNumber();
        uint256 emptyAuctions = 3;

        for (uint256 i = 1; i <= emptyAuctions; i++) {
            vm.roll((currentAuction + i) * auctionHook.AUCTION_BLOCKS());

            // Check authorized liquidator in each auction
            (address solver, uint256 bid) = auctionHook.getAuthorizedLiquidator(
                borrower
            );

            // After one auction passes, there should be no authorized liquidator
            if (i == 1) {
                assertEq(
                    solver,
                    bidderA,
                    "First auction should have bidderA as authorized liquidator"
                );
                assertEq(bid, 1 ether, "First auction should have 1 ether bid");
            } else {
                assertEq(
                    solver,
                    address(0),
                    "Subsequent auctions should have no authorized liquidator"
                );
                assertEq(bid, 0, "Subsequent auctions should have zero bid");
            }
        }

        // After several empty auctions, anyone should be able to liquidate
        (address silo0, ) = siloConfig.getSilos();
        bytes memory liquidationInput = abi.encode(borrower);

        vm.prank(makeAddr("randomLiquidator"));
        // Should not revert since there's no authorized liquidator
        auctionHook.beforeAction(silo0, Hook.LIQUIDATION, liquidationInput);
    }

    /**
     * @notice Test behavior at auction boundaries
     * @dev Verifies auction state transitions at boundary blocks:
     *      1. Bids in last block of an auction are still valid for that auction
     *      2. Auction winner becomes authorized liquidator in the next auction
     *      3. New auction starts with no bids
     */
    function testAuctionBoundaryBehavior() public {
        uint256 auctionBlocks = auctionHook.AUCTION_BLOCKS();
        uint256 auctionStart = auctionHook.getCurrentAuctionNumber() *
            auctionBlocks;

        // Test at the last block of auction 1
        vm.roll(auctionStart + auctionBlocks - 1);

        // Place bid as bidderA in last block of auction 1
        vm.prank(bidderA);
        auctionHook.placeBid(borrower, 1 ether);

        // Verify bidderA is highest bidder in auction 1
        (address bidder, uint256 amount) = auctionHook.getCurrentBidder(
            borrower
        );
        assertEq(bidder, bidderA, "Bidder should be bidderA");
        assertEq(amount, 1 ether, "Bid amount should be 1 ether");

        // Move to first block of auction 2
        vm.roll(auctionStart + auctionBlocks);

        // Verify bidderA is now the authorized liquidator
        (address solver, uint256 bid) = auctionHook.getAuthorizedLiquidator(
            borrower
        );
        assertEq(solver, bidderA, "Authorized liquidator should be bidderA");
        assertEq(bid, 1 ether, "Authorized bid should be 1 ether");

        // Current auction 2 should have no bidder yet
        (bidder, amount) = auctionHook.getCurrentBidder(borrower);
        assertEq(
            bidder,
            address(0),
            "New auction should have no bidder initially"
        );
        assertEq(amount, 0, "New auction should have no bid amount initially");
    }

    function test_LiquidationFromAuthorizedLiquidator() public {
        (address silo0, address silo1) = siloConfig.getSilos();

        // Deal tokens and approve them while under the same prank
        vm.startPrank(liquidityProvider);

        deal(ArbitrumLib.WETH, liquidityProvider, 1e22);
        deal(ArbitrumLib.USDC, liquidityProvider, 1e22);

        // Approve tokens for the silos
        IERC20(ArbitrumLib.WETH).approve(silo0, 1e22);
        IERC20(ArbitrumLib.USDC).approve(silo1, 1e22);

        // Attempt deposits
        ISilo(silo0).deposit(1e22, liquidityProvider);
        ISilo(silo1).deposit(1e22, liquidityProvider);

        vm.stopPrank();

        // Deal WETH to borrower BEFORE trying to deposit
        deal(ArbitrumLib.WETH, borrower, 1e21);

        // set up liquidatable position for borrower
        vm.startPrank(borrower);
        IERC20(ArbitrumLib.WETH).approve(silo0, 1e21);
        ISilo(silo0).deposit(1e21, borrower);

        // find out what's the max borrowable amount for borrower
        uint256 maxBorrowable = ISilo(silo1).maxBorrow(borrower);
        ISilo(silo1).borrow(maxBorrowable, borrower, borrower);
        vm.stopPrank();

        // bidderA wins auction 1
        vm.prank(bidderA);
        auctionHook.placeBid(borrower, 1 ether);

        vm.roll(block.number + auctionHook.AUCTION_BLOCKS());

        // bidderA should be the authorized liquidator
        (address solver, uint256 bid) = auctionHook.getAuthorizedLiquidator(
            borrower
        );
        assertEq(solver, bidderA, "Authorized liquidator should be bidderA");
        assertEq(bid, 1 ether, "Authorized bid should be 1 ether");

        vm.prank(bidderB);
        vm.expectRevert(UnauthorizedLiquidator);
        auctionHook.liquidationCall(
            ArbitrumLib.WETH,
            ArbitrumLib.USDC,
            borrower,
            1e18,
            true
        );
    }

    // --- Helper Function ---

    /**
     * @notice Retrieve the hook address from the silo configuration
     * @dev Extracts the hook receiver address from the first silo in the config
     * @param _siloConfig The Silo configuration contract
     * @return hook The address of the deployed hook
     */
    function _getHookAddress(
        ISiloConfig _siloConfig
    ) internal view returns (address hook) {
        (address silo, ) = _siloConfig.getSilos();
        hook = _siloConfig.getConfig(silo).hookReceiver;
    }
}
