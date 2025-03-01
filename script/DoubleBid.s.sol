// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import {IERC20} from "openzeppelin5/token/ERC20/IERC20.sol";

// WETH interface
interface IWETH {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

// Define the interface for the auction hook to avoid dependency issues
interface IAuctionHook {
    function getCurrentBidder(
        address borrower
    ) external view returns (address, uint256);
    function placeBid(address borrower, uint256 amount) external;
}

/**
 * @title DoubleBid
 * @notice Simple script to double the current bid for a borrower
 * @dev Accepts the borrower address as a function parameter
 */
contract DoubleBid is Script {
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    function run() external {
        // Use environment variables for hook address
        address auctionHookAddress = vm.envOr(
            "AUCTION_HOOK_ADDRESS",
            address(0)
        );

        // Default borrower from environment if needed
        address borrowerAddress = vm.envOr("BORROWER_A", address(0));

        // Using the default run() function, so parameters will need to be set via environment variables
        _placeBid(auctionHookAddress, borrowerAddress);
    }

    // This function will be called with the borrower address as an argument
    function run(address borrowerAddress) external {
        // Get hook address from environment
        address auctionHookAddress = vm.envOr(
            "AUCTION_HOOK_ADDRESS",
            address(0)
        );

        _placeBid(auctionHookAddress, borrowerAddress);
    }

    // Common implementation to avoid code duplication
    function _placeBid(
        address auctionHookAddress,
        address borrowerAddress
    ) internal {
        // Log the addresses we're using
        console.log("Auction Hook Address:", auctionHookAddress);
        console.log("Borrower Address:", borrowerAddress);

        // Check for valid addresses
        require(
            auctionHookAddress != address(0),
            "Auction hook address not set"
        );
        require(borrowerAddress != address(0), "Borrower address not set");

        // Create contract instances
        IAuctionHook hook = IAuctionHook(auctionHookAddress);
        IWETH weth = IWETH(WETH);

        // Try to get the current bid with error handling
        address currentBidder;
        uint256 currentBidAmount;

        try hook.getCurrentBidder(borrowerAddress) returns (
            address bidder,
            uint256 amount
        ) {
            currentBidder = bidder;
            currentBidAmount = amount;
            console.log("Current bidder:", currentBidder);
            console.log("Current bid amount:", currentBidAmount);
        } catch Error(string memory reason) {
            console.log("Error getting current bidder:", reason);
            revert("Failed to get current bidder");
        } catch {
            console.log("Unknown error getting current bidder");
            revert("Failed to get current bidder - unknown error");
        }

        // Calculate new bid (double the current bid)
        uint256 newBidAmount;
        if (currentBidAmount == 0) {
            // If no current bid, start with 1 ether
            newBidAmount = 1 ether;
            console.log(
                "No current bid. Setting initial bid to:",
                newBidAmount
            );
        } else {
            // Double the current bid
            newBidAmount = currentBidAmount * 2;
            console.log("Placing new bid (double):", newBidAmount);
        }

        // Start transactions
        vm.startBroadcast();

        // Check if we need more WETH
        uint256 wethBalance = weth.balanceOf(msg.sender);
        console.log("Current WETH balance:", wethBalance);

        if (wethBalance < newBidAmount) {
            uint256 amountToDeposit = newBidAmount - wethBalance + 1 ether; // Add extra for buffer
            console.log("Depositing ETH to get WETH:", amountToDeposit);
            weth.deposit{value: amountToDeposit}();
            console.log("New WETH balance:", weth.balanceOf(msg.sender));
        }

        // Approve WETH spending
        console.log("Approving WETH spending");
        weth.approve(auctionHookAddress, newBidAmount);

        // Place the bid
        console.log("Placing bid of", newBidAmount, "WETH");
        hook.placeBid(borrowerAddress, newBidAmount);
        console.log("Successfully placed bid");

        vm.stopBroadcast();
    }
}
