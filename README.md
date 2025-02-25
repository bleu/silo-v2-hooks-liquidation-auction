# Silo Protocol Liquidation Auction Hook

A block-based auction system for Silo Protocol liquidation rights using WETH.

## Overview

This project implements a competitive auction system for Silo Protocol liquidations. Users bid for the exclusive right to liquidate underwater positions, with each auction running for 100 blocks. The highest bidder from the previous auction becomes the authorized liquidator for borrowers in the current period.

## Key Features

- Per-borrower auction system (each borrower has a separate auction)
- Block-based auction periods (100 blocks)
- Immediate refunds when outbid
- Prevention of self-bidding (borrowers cannot bid on their own liquidation)
- Integration with Silo Protocol via hook interface

## Repository Structure

- `/contracts`: Smart contract implementation
  - `LiquidationAuctionHook.sol`: Main auction contract
  - `/errors`: Custom error definitions
- `/test`: Comprehensive test suite
  - `LiquidationAuctionHookArbitrumTest.t.sol`: Main test file
  - `/common`: Shared testing utilities

## Getting Started

### Prerequisites

- Foundry
- Node.js and npm

### Installation

```bash
git clone https://github.com/your-username/silo-liquidation-auction-hook.git
cd silo-liquidation-auction-hook
forge install
```

### Running Tests

```bash
forge test
```

## How It Works

1. **Auction Periods**: Each auction runs for 100 blocks
2. **Bidding**: Users bid with WETH for the right to liquidate a specific borrower.
3. **Winning**: The highest bidder at the end of an auction becomes the authorized liquidator for the next period.
4. **Liquidation**: Only the authorized liquidator can perform liquidations for a borrower.
5. **No Winner Case**: If an auction has no bids, anyone can liquidate in the following period.

## Contract Documentation

See [CONTRACT_DOCS.md](./docs/CONTRACT_DOCS.md) for detailed contract documentation.

## Test Documentation

See [TEST_DOCS.md](./docs/TEST_DOCS.md) for details on the test suite and coverage.

## License

MIT

# Contract Documentation

## LiquidationAuctionHook

A block-based auction system for Silo Protocol liquidation rights using WETH.

### Inheritance

- `Initializable`: Prevents multiple initializations
- `ReentrancyGuard`: Prevents re-entrancy attacks
- `Ownable2Step`: Secure two-step ownership transfer
- `BaseHookReceiver`: Base functionality for Silo hooks
- `PartialLiquidation`: Support for partial liquidations in Silo

### Constants

- `AUCTION_BLOCKS`: Number of blocks per auction (100 blocks)

### State Variables

- `borrowerAuctions`: Mapping of borrower => auction number => auction details
- `feeReceiver`: Address that receives fees (set on initialization)
- `weth`: WETH token used for bidding

### Events

- `BidPlaced`: Emitted when a bid is placed
- `RefundIssued`: Emitted when a previous bidder is refunded
- `LiquidationExecuted`: Emitted when a liquidation is executed
- `FeesCollected`: Emitted when fees are collected

### Custom Errors

- `BidTooLow`: Thrown when a bid is not higher than the current highest bid
- `UnauthorizedLiquidator`: Thrown when an unauthorized address attempts liquidation
- `SelfBiddingNotAllowed`: Thrown when a borrower tries to bid on their own liquidation

### Functions

#### View Functions

- `getCurrentAuctionNumber()`: Returns the current auction number based on block number
- `getBlocksRemaining()`: Returns the number of blocks remaining in the current auction
- `getAuthorizedLiquidator(address _borrower)`: Returns the authorized liquidator for a borrower
- `getCurrentBidder(address _borrower)`: Returns the current highest bidder for a borrower

#### State-Changing Functions

- `initialize(ISiloConfig _siloConfig, bytes calldata _data)`: Initializes the contract
- `placeBid(address _borrower, uint256 bidAmount)`: Places a bid for liquidation rights
- `collectFees()`: Collects fees (not supported in the simplified model)

#### Hook Interface Functions

- `beforeAction(address _silo, uint256 _action, bytes calldata _input)`: Hook called before an action
- `afterAction(address _silo, uint256 _action, bytes calldata _inputAndOutput)`: Hook called after an action
- `hookReceiverConfig(address _silo)`: Returns the hook configuration for a silo

### Internal Functions

- `_configureHooks()`: Configures hooks for liquidation actions on both silos

### Security Considerations

- ReentrancyGuard is used for all state-changing external functions
- Ownable2Step is used for secure ownership transfers
- SafeERC20 is used for secure token transfers
- Zero-address checks are performed during initialization

# Test Documentation

## LiquidationAuctionHookArbitrumTest

Comprehensive test suite for the LiquidationAuctionHook contract using an Arbitrum fork.

### Test Categories

1. **Bidding Tests**: Verify basic and edge case bidding scenarios
2. **Auction Lifecycle Tests**: Test auction progression and state transitions
3. **Hook Integration Tests**: Verify correct interaction with Silo Protocol
4. **Refund Tests**: Ensure bid refunds work correctly
5. **Security Tests**: Verify contract security features

### Key Test Functions

#### Bidding Tests

- `testMinimumBidAmount()`: Tests minimum bid amounts (1 wei)
- `testMaximumBidAmount()`: Tests maximum possible bid amounts
- `testSelfOutbid()`: Tests bidder outbidding themselves
- `testSelfBiddingReverts()`: Tests prevention of borrowers bidding on their own liquidation
- `testPlaceBidAndRefund()`: Tests automatic refunds when outbid
- `testBidTooLow()`: Tests rejection of bids lower than current highest

#### Auction Lifecycle Tests

- `testAuctionNumberProgress()`: Tests auction number incrementation
- `testBlocksRemainingCalculation()`: Tests blocks remaining calculation
- `testAuthorizedLiquidator()`: Tests authorized liquidator determination
- `testAuctionHistoryPersistence()`: Tests auction history across multiple periods
- `testAuctionBoundaryBehavior()`: Tests behavior at auction period boundaries

#### Hook Integration Tests

- `testBeforeActionAuthorized()`: Tests authorized liquidator can liquidate
- `testBeforeActionUnauthorized()`: Tests unauthorized liquidators are prevented
- `testHookConfigurationWithMultipleActions()`: Tests hook configuration with multiple actions

#### Multiple Borrower Tests

- `testMultipleBorrowerAuctions()`: Tests multiple simultaneous borrower auctions
- `testNoAuthorizedLiquidator()`: Tests behavior with no authorized liquidator

#### Edge Case Tests

- `testGasUsageMultipleBidders()`: Tests gas usage with multiple bidders
- `testExtremeRefundScenarios()`: Tests refunds with extreme value differences
- `testInsufficientWethBalance()`: Tests behavior with insufficient token balance
- `testZeroAddressHandling()`: Tests handling of zero address inputs
- `testIncrementalBidding()`: Tests many small incremental bids
- `testLiquidationAfterEmptyAuctions()`: Tests liquidation after empty auctions

#### Security Tests

- `testCollectFeesReverts()`: Tests fee collection reversion
- `testOwnershipTransfer()`: Tests two-step ownership transfer
- `testReinitializationPrevention()`: Tests prevention of reinitialization

### Setup and Helpers

- `setUp()`: Sets up the test environment with Arbitrum fork
- `_getHookAddress()`: Helper to retrieve the hook address from configuration

### Gas Usage Tracking

The `testGasUsageMultipleBidders()` test measures and logs gas usage for different bidding scenarios to help optimize the contract.
