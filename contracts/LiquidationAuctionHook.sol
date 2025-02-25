// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IHookReceiver} from "silo-contracts-v2/silo-core/contracts/interfaces/IHookReceiver.sol";
import {ISiloConfig} from "silo-contracts-v2/silo-core/contracts/interfaces/ISiloConfig.sol";
import {ISilo} from "silo-contracts-v2/silo-core/contracts/interfaces/ISilo.sol";
import {IPartialLiquidation} from "silo-contracts-v2/silo-core/contracts/interfaces/IPartialLiquidation.sol";
import {Hook} from "silo-contracts-v2/silo-core/contracts/lib/Hook.sol";
import {BaseHookReceiver} from "silo-contracts-v2/silo-core/contracts/utils/hook-receivers/_common/BaseHookReceiver.sol";
import {PartialLiquidation} from "silo-contracts-v2/silo-core/contracts/utils/hook-receivers/liquidation/PartialLiquidation.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title LiquidationAuctionHook
 * @notice A block-based auction system for Silo Protocol liquidation rights using WETH
 * @dev This contract implements a competitive bidding system where users can bid for the
 * exclusive right to liquidate underwater positions in the Silo Protocol. Each auction
 * runs for a fixed number of blocks, and the highest bidder from the previous
 * auction becomes the authorized liquidator for the current period.
 *
 * Key features:
 *  - Auction periods based on block numbers (100 blocks)
 *  - Per-borrower auctions (each borrower has their own separate auction)
 *  - Immediate refunds via ERC20 safe transfers when outbid
 *  - Prevention of self-bidding (borrower cannot bid on its own liquidation)
 *  - Non-overwriting hook configuration (adds liquidation action bit to existing hooks)
 *  - Full compliance with Silo hook interface (hookReceiverConfig and afterAction)
 *
 * Security considerations:
 *  - Utilizes ReentrancyGuard for all state-changing external functions
 *  - Implements Ownable2Step for secure ownership transfers
 *  - Safe WETH transfers using OpenZeppelin's SafeERC20
 */
contract LiquidationAuctionHook is
    Initializable,
    ReentrancyGuard,
    Ownable2Step,
    BaseHookReceiver,
    PartialLiquidation
{
    using Hook for uint256;
    using Hook for uint24;
    using Hook for bytes;
    using SafeERC20 for IERC20;

    /* ========== CONSTANTS ========== */

    uint256 public constant AUCTION_BLOCKS = 100; // Blocks per auction

    /* ========== STRUCTURES ========== */

    /**
     * @notice Represents the state of an auction for a specific borrower
     * @dev Stored in the borrowerAuctions mapping
     * @param highestBidder The address of the current highest bidder (address(0) if no bids)
     * @param highestBid The amount of WETH bid by the highest bidder (0 if no bids)
     */
    struct BorrowerAuction {
        address highestBidder;
        uint256 highestBid;
    }

    /* ========== STATE VARIABLES ========== */

    // Mapping: borrower => auction number => auction details.
    mapping(address => mapping(uint256 => BorrowerAuction))
        public borrowerAuctions;

    // Fee receiver (set on initialization)
    address public feeReceiver;

    // WETH token used for bidding.
    IERC20 public weth;

    /* ========== EVENTS ========== */

    /**
     * @notice Emitted when a bid is placed
     * @param borrower The borrower address whose liquidation rights are being bid on
     * @param bidder The address that placed the bid
     * @param auctionNumber The auction number in which the bid was placed
     * @param bidAmount The amount of WETH bid
     */
    event BidPlaced(
        address indexed borrower,
        address indexed bidder,
        uint256 auctionNumber,
        uint256 bidAmount
    );

    /**
     * @notice Emitted when a previous bidder is refunded
     * @param user The address that received the refund
     * @param amount The amount of WETH refunded
     */
    event RefundIssued(address indexed user, uint256 amount);

    /**
     * @notice Emitted when a liquidation is executed
     * @param solver The address that executed the liquidation
     * @param borrower The borrower address that was liquidated
     * @param auctionNumber The auction number in which the liquidation occurred
     */
    event LiquidationExecuted(
        address indexed solver,
        address indexed borrower,
        uint256 auctionNumber
    );

    /**
     * @notice Emitted when fees are collected
     * @param feeReceiver The address that received the fees
     * @param amount The amount of fees collected
     */
    event FeesCollected(address indexed feeReceiver, uint256 amount);

    /* ========== ERRORS ========== */

    /**
     * @notice Thrown when a bidder attempts to place a bid that is not higher than the current highest bid
     */
    error BidTooLow();

    /**
     * @notice Thrown when an address attempts to liquidate a borrower without being the authorized liquidator
     */
    error UnauthorizedLiquidator();

    /**
     * @notice Thrown when a borrower attempts to bid on their own liquidation
     */
    error SelfBiddingNotAllowed();

    /* ========== CONSTRUCTOR ========== */

    // Use msg.sender as the initial owner to avoid the zero address error
    constructor() Ownable(msg.sender) {}

    /* ========== INITIALIZATION ========== */

    /**
     * @notice Initialize the hook with required parameters
     * @param _siloConfig The Silo configuration contract address
     * @param _data ABI encoded parameters: (address owner, address feeReceiver, address wethAddress)
     * @dev This function can only be called once due to the initializer modifier
     * Contract initialization performs the following:
     * 1. Decodes the initialization parameters
     * 2. Sets up the ownership, fee receiver and WETH token address
     * 3. Configures hooks for liquidation actions on both silos
     */
    function initialize(
        ISiloConfig _siloConfig,
        bytes calldata _data
    ) external override initializer {
        (address owner, address _feeReceiver, address _weth) = abi.decode(
            _data,
            (address, address, address)
        );
        require(owner != address(0), "Owner cannot be zero address");
        require(
            _feeReceiver != address(0),
            "Fee receiver cannot be zero address"
        );
        require(_weth != address(0), "WETH address cannot be zero");

        // Initialize BaseHookReceiver using SiloConfig.
        BaseHookReceiver.__BaseHookReceiver_init(_siloConfig);

        // Set owner, fee receiver, and WETH token.
        _transferOwnership(owner);
        feeReceiver = _feeReceiver;
        weth = IERC20(_weth);

        // Configure hooks for liquidation actions on both silos.
        _configureHooks();
    }

    /* ========== AUCTION LOGIC ========== */

    /**
     * @notice Get the current auction number based on block number
     * @return currentAuctionNumber The current auction number
     * @dev Auction numbers are deterministic and based on block.number / AUCTION_BLOCKS
     */
    function getCurrentAuctionNumber() public view returns (uint256) {
        return block.number / AUCTION_BLOCKS;
    }

    /**
     * @notice Get blocks remaining in the current auction
     * @return blocksRemaining Number of blocks until this auction ends
     * @dev Calculated as (AUCTION_BLOCKS - (block.number % AUCTION_BLOCKS))
     */
    function getBlocksRemaining() public view returns (uint256) {
        return AUCTION_BLOCKS - (block.number % AUCTION_BLOCKS);
    }

    /**
     * @notice Get the authorized liquidator for a borrower (winner of the previous auction)
     * @param _borrower The borrower address for which to check the authorized liquidator
     * @return solver The authorized liquidator address (zero address if no previous winner)
     * @return bidAmount The winning bid amount from the previous auction
     * @dev This function is used by the beforeAction hook to validate liquidation rights
     */
    function getAuthorizedLiquidator(
        address _borrower
    ) public view returns (address solver, uint256 bidAmount) {
        uint256 currentAuctionNumber = getCurrentAuctionNumber();
        uint256 previousAuctionNumber = currentAuctionNumber > 0
            ? currentAuctionNumber - 1
            : 0;
        BorrowerAuction storage auction = borrowerAuctions[_borrower][
            previousAuctionNumber
        ];
        return (auction.highestBidder, auction.highestBid);
    }

    /**
     * @notice Get the current auction's highest bidder for a borrower
     * @param _borrower The borrower address for which to check current bidding status
     * @return bidder The current highest bidder (zero address if no bids yet)
     * @return bidAmount The current highest bid amount
     * @dev This information is for the ongoing auction, not the authorized liquidator
     */
    function getCurrentBidder(
        address _borrower
    ) public view returns (address bidder, uint256 bidAmount) {
        uint256 auctionNumber = getCurrentAuctionNumber();
        BorrowerAuction storage auction = borrowerAuctions[_borrower][
            auctionNumber
        ];
        return (auction.highestBidder, auction.highestBid);
    }

    /**
     * @notice Place a bid for liquidation rights using WETH
     * @param _borrower The borrower address whose liquidation rights are being bid on
     * @param bidAmount The bid amount in WETH (in smallest unit)
     * @dev This function:
     * 1. Validates the borrower address is not zero
     * 2. Prevents borrowers from bidding on their own liquidation
     * 3. Ensures bid amount is positive and higher than current highest bid
     * 4. Transfers WETH from the bidder to this contract
     * 5. Updates auction state with new highest bidder
     * 6. Refunds the previous highest bidder if one exists
     *
     * @dev Emits {BidPlaced} and potentially {RefundIssued} events
     * @dev Protected by nonReentrant modifier to prevent reentrancy attacks
     */
    function placeBid(
        address _borrower,
        uint256 bidAmount
    ) external nonReentrant {
        require(_borrower != address(0), "Borrower cannot be zero address");
        if (msg.sender == _borrower) {
            revert SelfBiddingNotAllowed();
        }
        require(bidAmount > 0, "Bid amount must be positive");

        uint256 auctionNumber = getCurrentAuctionNumber();
        BorrowerAuction storage auction = borrowerAuctions[_borrower][
            auctionNumber
        ];

        // Ensure the new bid exceeds the current bid.
        if (bidAmount <= auction.highestBid) {
            revert BidTooLow();
        }

        // Transfer the bid amount in WETH from the bidder.
        weth.safeTransferFrom(msg.sender, address(this), bidAmount);

        // Save previous bid details for immediate refund.
        address previousBidder = auction.highestBidder;
        uint256 previousBid = auction.highestBid;

        // Update auction state.
        auction.highestBidder = msg.sender;
        auction.highestBid = bidAmount;

        // Immediately refund the previous bidder, if one exists.
        if (previousBidder != address(0)) {
            weth.safeTransfer(previousBidder, previousBid);
            emit RefundIssued(previousBidder, previousBid);
        }

        emit BidPlaced(_borrower, msg.sender, auctionNumber, bidAmount);
    }

    /**
     * @notice Collect fees.
     * @dev In this simplified model, the contract balance represents active bids,
     *      so fee collection is not supported.
     */
    function collectFees() external nonReentrant onlyOwner {
        revert("Fee collection not supported in simplified model");
    }

    /* ========== HOOK FUNCTIONS ========== */

    /**
     * @notice Hook called before a liquidation action in Silo Protocol
     * @dev Enforces exclusive liquidation rights for winning bidders
     * @param _silo The silo address where the action is being executed
     * @param _action The action being performed (only acts on Hook.LIQUIDATION)
     * @param _input The input data for the action, from which we decode the borrower address
     * @dev When a liquidation is attempted:
     * 1. This hook checks if there is an authorized liquidator for the borrower
     * 2. If an authorized liquidator exists, only they can perform the liquidation
     * 3. If no authorized liquidator exists (address(0)), anyone can perform the liquidation
     * @dev Will revert with {UnauthorizedLiquidator} if an unauthorized address attempts liquidation
     */
    function beforeAction(
        address _silo,
        uint256 _action,
        bytes calldata _input
    ) external override {
        // Only process actions that match the configured before hooks.
        if (!_getHooksBefore(_silo).matchAction(_action)) return;

        // Only act on liquidation actions.
        if (_action == Hook.LIQUIDATION) {
            // Manually decode the borrower address from the input
            address borrower = abi.decode(_input, (address));

            // Retrieve the authorized liquidator (winner of the previous auction).
            (address authorizedLiquidator, ) = getAuthorizedLiquidator(
                borrower
            );
            if (
                authorizedLiquidator != address(0) &&
                authorizedLiquidator != msg.sender
            ) {
                revert UnauthorizedLiquidator();
            }
        }
    }

    /**
     * @notice Hook called after an action in Silo Protocol
     * @dev No post-processing is needed for this hook, so this function is a no-op
     * @param _silo The silo address where the action was executed
     * @param _action The action that was performed
     * @param _inputAndOutput The input and output data from the action
     */
    function afterAction(
        address _silo,
        uint256 _action,
        bytes calldata _inputAndOutput
    ) external override {
        // No post-processing is required for this auction hook.
    }

    /**
     * @notice Return the hook configuration for a given silo
     * @dev Exposes both before and after hook settings
     * @param _silo The silo address for which to get hook configuration
     * @return hooksBefore The bitmap of actions intercepted before the action
     * @return hooksAfter The bitmap of actions intercepted after the action
     * @dev This function is part of the IHookReceiver interface required by Silo Protocol
     */
    function hookReceiverConfig(
        address _silo
    ) external view override returns (uint24 hooksBefore, uint24 hooksAfter) {
        (hooksBefore, hooksAfter) = _hookReceiverConfig(_silo);
    }

    /* ========== HELPER FUNCTIONS ========== */

    /**
     * @notice Configure the hooks for liquidation actions
     * @dev Adds the LIQUIDATION hook action to the existing configuration
     * for both silos without overwriting other hook settings
     * The process for each silo:
     * 1. Get current hook configuration
     * 2. Add LIQUIDATION action to the before-hooks bitmap
     * 3. Set the updated configuration while preserving existing after-hooks
     * @dev Called during contract initialization
     */
    function _configureHooks() internal {
        // Retrieve the addresses of both silos.
        (address silo0, address silo1) = siloConfig.getSilos();

        // For each silo, retrieve the current before-hooks bitmap, add the LIQUIDATION action,
        // and update the configuration without modifying the existing after-hooks.
        uint256 hooksBefore0 = _getHooksBefore(silo0);
        hooksBefore0 = hooksBefore0.addAction(Hook.LIQUIDATION);
        _setHookConfig(
            silo0,
            uint24(hooksBefore0),
            uint24(_getHooksAfter(silo0))
        );

        uint256 hooksBefore1 = _getHooksBefore(silo1);
        hooksBefore1 = hooksBefore1.addAction(Hook.LIQUIDATION);
        _setHookConfig(
            silo1,
            uint24(hooksBefore1),
            uint24(_getHooksAfter(silo1))
        );
    }
}
